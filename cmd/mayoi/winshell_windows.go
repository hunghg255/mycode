//go:build windows

package main

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// The shell integration of Windows, as VS Code's installer sets it up: a
// mycode command on the PATH of the user, which opens a folder or a file
// in MyCode as `code` does, and "Open with MyCode" in File Explorer's
// menu of a folder, of the inside of a folder, of a drive and of a file.
// It is all the user's (HKCU), which needs no administrator.

// shellSupported reports whether the app sets up its shell integration.
const shellSupported = true

// shellBinDir is the folder of the mycode command, which goes on the PATH.
func shellBinDir() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, "AppData", "Local")
	}
	return filepath.Join(base, appName, "bin")
}

// menuKeys are the keys of File Explorer's menus that get "Open with
// MyCode", and the argument each passes: the folder or the file.
var menuKeys = []struct{ key, arg string }{
	{`Software\Classes\Directory\shell\` + appName, "%V"},
	{`Software\Classes\Directory\Background\shell\` + appName, "%V"},
	{`Software\Classes\Drive\shell\` + appName, "%V"},
	{`Software\Classes\*\shell\` + appName, "%1"},
}

// installShell puts the mycode command, for exe, on the user's PATH and
// "Open with MyCode" in File Explorer's menus, and returns the folder of
// the command. Running it again brings them up to date, as for an app
// that moved.
func installShell(exe string) (string, error) {
	dir := shellBinDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	// For PowerShell and Command Prompt: start returns at once, and the
	// app, already running or not, opens the paths from this folder.
	cmd := "@echo off\r\nstart \"\" \"" + exe + "\" %*\r\n"
	if err := os.WriteFile(filepath.Join(dir, cliName+".cmd"), []byte(cmd), 0o644); err != nil {
		return "", err
	}
	// For Git Bash, whose bash runs no .cmd by its bare name.
	sh := "#!/usr/bin/env sh\n\"" + msysPath(exe) + "\" \"$@\" >/dev/null 2>&1 &\n"
	if err := os.WriteFile(filepath.Join(dir, cliName), []byte(sh), 0o755); err != nil {
		return "", err
	}
	if err := addToPath(dir); err != nil {
		return dir, err
	}
	for _, m := range menuKeys {
		if err := setMenu(m.key, exe, m.arg); err != nil {
			return dir, err
		}
	}
	return dir, nil
}

// uninstallShell takes the mycode command and the menus away again.
func uninstallShell() error {
	dir := shellBinDir()
	var errs []error
	for _, m := range menuKeys {
		for _, k := range []string{m.key + `\command`, m.key} {
			if err := registry.DeleteKey(registry.CURRENT_USER, k); err != nil && !errors.Is(err, registry.ErrNotExist) {
				errs = append(errs, err)
			}
		}
	}
	if err := removeFromPath(dir); err != nil {
		errs = append(errs, err)
	}
	os.RemoveAll(dir)
	return errors.Join(errs...)
}

// setMenu makes key an item of File Explorer's menu that opens its folder
// or file, arg, in exe.
func setMenu(key, exe, arg string) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, key, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if err := k.SetStringValue("", "Open with "+appName); err != nil {
		return err
	}
	if err := k.SetStringValue("Icon", exe); err != nil {
		return err
	}
	c, _, err := registry.CreateKey(registry.CURRENT_USER, key+`\command`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer c.Close()
	return c.SetStringValue("", `"`+exe+`" "`+arg+`"`)
}

// userPath returns the PATH of the user, as the registry keeps it, and its
// kind of value.
func userPath(k registry.Key) ([]string, uint32, error) {
	s, kind, err := k.GetStringValue("Path")
	if errors.Is(err, registry.ErrNotExist) {
		return nil, registry.EXPAND_SZ, nil
	}
	if err != nil {
		return nil, 0, err
	}
	var parts []string
	for _, p := range strings.Split(s, ";") {
		if strings.TrimSpace(p) != "" {
			parts = append(parts, p)
		}
	}
	return parts, kind, nil
}

func samePath(a, b string) bool {
	clean := func(p string) string {
		return strings.ToLower(filepath.Clean(os.ExpandEnv(strings.TrimSpace(p))))
	}
	return clean(a) == clean(b)
}

// addToPath adds dir to the user's PATH, unless it has it, and tells the
// programs that start new ones, as File Explorer, that it changed.
func addToPath(dir string) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, "Environment", registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	parts, kind, err := userPath(k)
	if err != nil {
		return err
	}
	if slices.ContainsFunc(parts, func(p string) bool { return samePath(p, dir) }) {
		return nil
	}
	if err := writePath(k, append(parts, dir), kind); err != nil {
		return err
	}
	broadcastEnvironment()
	return nil
}

// removeFromPath takes dir off the user's PATH.
func removeFromPath(dir string) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, "Environment", registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	parts, kind, err := userPath(k)
	if err != nil {
		return err
	}
	kept := slices.DeleteFunc(slices.Clone(parts), func(p string) bool { return samePath(p, dir) })
	if len(kept) == len(parts) {
		return nil
	}
	if err := writePath(k, kept, kind); err != nil {
		return err
	}
	broadcastEnvironment()
	return nil
}

func writePath(k registry.Key, parts []string, kind uint32) error {
	v := strings.Join(parts, ";")
	if kind == registry.SZ {
		return k.SetStringValue("Path", v)
	}
	return k.SetExpandStringValue("Path", v)
}

// broadcastEnvironment tells the windows that the environment changed, so
// that terminals started from then on have the new PATH.
func broadcastEnvironment() {
	const (
		hwndBroadcast   = 0xffff
		wmSettingChange = 0x001A
		smtoAbortIfHung = 0x0002
	)
	env, err := windows.UTF16PtrFromString("Environment")
	if err != nil {
		return
	}
	proc := windows.NewLazySystemDLL("user32.dll").NewProc("SendMessageTimeoutW")
	if proc.Find() != nil {
		return
	}
	var result uintptr
	proc.Call(hwndBroadcast, wmSettingChange, 0, uintptr(unsafe.Pointer(env)), smtoAbortIfHung, 3000, uintptr(unsafe.Pointer(&result)))
}

// msysPath is a Windows path as Git Bash spells it: C:\a\b is /c/a/b.
func msysPath(p string) string {
	p = filepath.ToSlash(p)
	if len(p) >= 2 && p[1] == ':' {
		p = "/" + strings.ToLower(p[:1]) + p[2:]
	}
	return p
}
