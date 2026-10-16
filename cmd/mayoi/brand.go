package main

import (
	"os"
	"path/filepath"
)

// The app's name, its shell command and its author.
const (
	appName   = "MyCode"
	cliName   = "mycode"
	appAuthor = "hunghg255"
	// oldAppName is the name the app had, whose settings a first start
	// under the new name takes.
	oldAppName = "Mayoi"
)

// The commands that put the mycode command on the shell's PATH: on
// Windows also File Explorer's Open with MyCode.
var (
	installCLILabel   = "Install '" + cliName + "' Command"
	uninstallCLILabel = "Uninstall '" + cliName + "' Command"
)

func init() {
	if shellSupported {
		installCLILabel = "Install '" + cliName + "' Command and Explorer Menu"
		uninstallCLILabel = "Uninstall '" + cliName + "' Command and Explorer Menu"
	}
}

// dataFiles are the files of the user data folder that move with a new
// name: the settings, the shortcuts and the state of the windows.
var dataFiles = []string{"settings.json", "keybindings.json", "state.json", "window-state.json"}

// migrateData copies the settings of the app under its old name into the
// user data folder dir, when dir has none yet: a first start of MyCode
// keeps what Mayoi had.
func migrateData(dir string) {
	if _, err := os.Stat(filepath.Join(dir, "settings.json")); err == nil {
		return
	}
	old := filepath.Join(filepath.Dir(dir), oldAppName)
	if filepath.Clean(old) == filepath.Clean(dir) {
		return
	}
	if info, err := os.Stat(old); err != nil || !info.IsDir() {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	for _, name := range dataFiles {
		data, err := os.ReadFile(filepath.Join(old, name))
		if err != nil {
			continue
		}
		os.WriteFile(filepath.Join(dir, name), data, 0o644)
	}
}
