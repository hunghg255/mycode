package main

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"

	"github.com/egoist/mygo/ui"
)

// termProfile is a shell a terminal can start, as VS Code's terminal
// profiles: PowerShell, Command Prompt, Git Bash and the like. A command
// of nil starts the shell the terminal picks itself.
type termProfile struct {
	name    string
	command []string
}

// Commands of the profiles: a new terminal of one, and making one the
// default, followed by the profile's name.
const (
	newTermCommand     = "terminal.new:"
	defaultTermCommand = "terminal.default:"
)

// foundProfiles are the shells found on this machine, looked for once.
var foundProfiles = sync.OnceValue(func() []termProfile {
	if runtime.GOOS == "windows" {
		return windowsProfiles()
	}
	return unixProfiles()
})

// windowsProfiles finds the shells of Windows, in the order a terminal
// prefers them: PowerShell 7, Windows PowerShell, Command Prompt, then
// Git Bash and WSL.
func windowsProfiles() []termProfile {
	var out []termProfile
	exists := func(p string) bool {
		info, err := os.Stat(p)
		return err == nil && !info.IsDir()
	}
	look := func(name string, also ...string) string {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
		for _, p := range also {
			if p != "" && exists(p) {
				return p
			}
		}
		return ""
	}
	sys := filepath.Join(os.Getenv("SystemRoot"), "System32")
	if os.Getenv("SystemRoot") == "" {
		sys = `C:\Windows\System32`
	}
	progs := []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramW6432"), os.Getenv("ProgramFiles(x86)")}
	under := func(rel string) []string {
		var ps []string
		for _, d := range progs {
			if d != "" {
				ps = append(ps, filepath.Join(d, rel))
			}
		}
		return ps
	}
	if p := look("pwsh.exe", under(`PowerShell\7\pwsh.exe`)...); p != "" {
		out = append(out, termProfile{"PowerShell", []string{p}})
	}
	if p := look("powershell.exe", filepath.Join(sys, `WindowsPowerShell\v1.0\powershell.exe`)); p != "" {
		out = append(out, termProfile{"Windows PowerShell", []string{p}})
	}
	cmd := os.Getenv("ComSpec")
	if cmd == "" || !exists(cmd) {
		cmd = look("cmd.exe", filepath.Join(sys, "cmd.exe"))
	}
	if cmd != "" {
		out = append(out, termProfile{"Command Prompt", []string{cmd}})
	}
	if p := gitBash(look, under); p != "" {
		out = append(out, termProfile{"Git Bash", []string{p, "--login", "-i"}})
	}
	if p := filepath.Join(sys, "wsl.exe"); exists(p) {
		out = append(out, termProfile{"WSL", []string{p}})
	}
	return out
}

// gitBash finds the bash of Git for Windows: beside the git on the PATH,
// or where its installer puts it.
func gitBash(look func(string, ...string) string, under func(string) []string) string {
	var cands []string
	if git, err := exec.LookPath("git.exe"); err == nil {
		// git.exe is in <Git>\cmd or <Git>\bin, or <Git>\mingw64\bin.
		dir := filepath.Dir(git)
		for _, up := range []string{"..", filepath.Join("..", "..")} {
			cands = append(cands, filepath.Join(dir, up, "bin", "bash.exe"))
		}
	}
	cands = append(cands, under(`Git\bin\bash.exe`)...)
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		cands = append(cands, filepath.Join(local, `Programs\Git\bin\bash.exe`))
	}
	for _, c := range cands {
		if info, err := os.Stat(c); err == nil && !info.IsDir() {
			return filepath.Clean(c)
		}
	}
	return ""
}

// unixProfiles are the login shell first, as the terminal starts it, then
// the other shells /etc/shells lists, by name.
func unixProfiles() []termProfile {
	out := []termProfile{{name: shellName()}}
	seen := map[string]bool{shellName(): true}
	f, err := os.Open("/etc/shells")
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name := filepath.Base(line)
		if seen[name] || name == "sh" || name == "nologin" || name == "false" {
			continue
		}
		if _, err := os.Stat(line); err != nil {
			continue
		}
		seen[name] = true
		out = append(out, termProfile{name, []string{line, "-l"}})
	}
	return out
}

// programPath is where a profile's program is: the path itself when it is
// a file, or the program of that name on the PATH; "" when this machine
// has neither, as for a shell the settings name but that is not
// installed.
func programPath(path string) string {
	path = os.ExpandEnv(strings.TrimSpace(path))
	if path == "" {
		return ""
	}
	if strings.ContainsAny(path, `/\`) {
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
		return ""
	}
	if p, err := exec.LookPath(path); err == nil {
		return p
	}
	return ""
}

// termProfiles are the shells new terminals can start: those found, and
// the user's own of the settings, which take the place of one of the same
// name. A profile of the settings whose program this machine does not
// have is left out, rather than fail as a terminal starts.
func (a *app) termProfiles() []termProfile {
	out := slices.Clone(foundProfiles())
	for _, up := range a.settings.TerminalProfiles {
		name := strings.TrimSpace(up.Name)
		path := programPath(up.Path)
		if name == "" || path == "" {
			continue
		}
		p := termProfile{name, append([]string{path}, up.Args...)}
		if i := slices.IndexFunc(out, func(o termProfile) bool { return o.name == name }); i >= 0 {
			out[i] = p
		} else {
			out = append(out, p)
		}
	}
	return out
}

// defaultProfile is the shell of a new terminal: the one the settings
// name, or else the first found.
func (a *app) defaultProfile() termProfile {
	ps := a.termProfiles()
	if i := slices.IndexFunc(ps, func(p termProfile) bool { return p.name == a.settings.TerminalProfile }); i >= 0 {
		return ps[i]
	}
	if len(ps) > 0 {
		return ps[0]
	}
	return termProfile{name: shellName()}
}

// profileNamed returns the profile of a name.
func (a *app) profileNamed(name string) (termProfile, bool) {
	ps := a.termProfiles()
	if i := slices.IndexFunc(ps, func(p termProfile) bool { return p.name == name }); i >= 0 {
		return ps[i], true
	}
	return termProfile{}, false
}

// profileCommands are the commands of the profiles, for the command
// palette: a new terminal of each, and making each the default.
func (a *app) profileCommands() []command {
	var out []command
	for _, p := range a.termProfiles() {
		out = append(out, command{id: newTermCommand + p.name, label: "New Terminal: " + p.name, run: func() {
			a.newTerminalWith(a.workDir(), p)
		}})
	}
	for _, p := range a.termProfiles() {
		out = append(out, command{id: defaultTermCommand + p.name, label: "Set Default Terminal: " + p.name, run: func() {
			a.setDefaultProfile(p.name)
		}})
	}
	return out
}

// setDefaultProfile makes a profile the one new terminals start.
func (a *app) setDefaultProfile(name string) {
	if a.settings.TerminalProfile == name {
		return
	}
	a.settings.TerminalProfile = name
	a.settings.Changed()
	a.host.recentChanged() // the menus check the new default
}

// newTerminalWith starts a terminal of a profile in the panel, in dir,
// and shows it.
func (a *app) newTerminalWith(dir string, p termProfile) {
	s := a.startTerminalWith(dir, p)
	if s == nil {
		return
	}
	a.panelTerm = s
	a.window.PanelOpen, a.window.TerminalOpen = true, true
	a.settings.Changed()
	a.focusTerminal()
}

// profileMenu is the menu of the panel's button by New Terminal: a new
// terminal of each profile, and the default one to choose.
func (a *app) profileMenu(m *ui.Menu) {
	ps := a.termProfiles()
	def := a.defaultProfile().name
	for _, p := range ps {
		label := p.name
		if p.name == def {
			label += " (Default)"
		}
		if m.Item(label).Chosen() {
			a.post(func() { a.newTerminalWith(a.workDir(), p) })
		}
	}
	m.Separator()
	m.Submenu("Select Default Profile", func(m *ui.Menu) {
		for _, p := range ps {
			if m.Item(p.name).Checked(p.name == def).Chosen() {
				a.post(func() { a.setDefaultProfile(p.name) })
			}
		}
	})
	if m.Item("Configure Terminal Profiles…").Chosen() {
		a.post(a.openSettings)
	}
}
