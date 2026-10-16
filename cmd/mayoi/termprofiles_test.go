package main

import (
	"slices"
	"testing"
	"time"

	"mayoi/internal/settings"
)

func TestTerminalProfiles(t *testing.T) {
	s := settings.Default()
	a := newApp(&fakeHost{}, s, s.NewWindow())
	found := foundProfiles()
	if len(found) == 0 {
		t.Fatal("no shell found")
	}
	// The first found is the default until the settings name another.
	if got := a.defaultProfile().name; got != found[0].name {
		t.Errorf("default %q, want the first found, %q", got, found[0].name)
	}
	// A profile of the user's own joins those found, and one of a found
	// name takes its place.
	// Programs this machine has: the shells found.
	shell := found[len(found)-1].command[0]
	other := found[0].command
	if len(other) == 0 {
		other = []string{shell}
	}
	s.TerminalProfiles = []settings.TerminalProfile{
		{Name: "My Shell", Path: shell, Args: []string{"-x"}},
		{Name: found[0].name, Path: other[0]},
		{Name: "", Path: shell},
	}
	ps := a.termProfiles()
	if len(ps) != len(found)+1 {
		t.Fatalf("got %d profiles, want %d", len(ps), len(found)+1)
	}
	if ps[0].name != found[0].name || !slices.Equal(ps[0].command, []string{other[0]}) {
		t.Errorf("a profile of a found name did not replace it: %+v", ps[0])
	}
	if p := ps[len(ps)-1]; p.name != "My Shell" || !slices.Equal(p.command, []string{shell, "-x"}) {
		t.Errorf("the user's profile: %+v", p)
	}
	// Choosing the default, by its command as the palette and menus run it.
	a.run(defaultTermCommand + "My Shell")
	if s.TerminalProfile != "My Shell" || a.defaultProfile().name != "My Shell" {
		t.Errorf("default is %q after choosing My Shell", s.TerminalProfile)
	}
	// Each profile has its commands, for the command palette.
	var labels []string
	for _, c := range a.commands() {
		labels = append(labels, c.label)
	}
	for _, want := range []string{"New Terminal: My Shell", "Set Default Terminal: My Shell"} {
		if !slices.Contains(labels, want) {
			t.Errorf("no command %q", want)
		}
	}
	// A default no longer there falls back to the first.
	s.TerminalProfile = "Gone"
	if got := a.defaultProfile().name; got != ps[0].name {
		t.Errorf("default %q for a missing profile", got)
	}
}

func TestTerminalLabel(t *testing.T) {
	onOS(t, "darwin")
	for _, c := range []struct{ title, profile, want string }{
		{`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`, "Windows PowerShell", "Windows PowerShell"},
		{"", "Command Prompt", "Command Prompt"},
		{"~/src", "zsh", "~/src"},
	} {
		s := &session{title: c.title, profile: c.profile}
		if got := s.label(); got != c.want {
			t.Errorf("label of %q (%s) = %q, want %q", c.title, c.profile, got, c.want)
		}
	}
	// On Windows, the profile's name, whatever the shell titles itself.
	onOS(t, "windows")
	if got := (&session{title: "MINGW64:/d/projects/Mayoi", profile: "Git Bash"}).label(); got != "Git Bash" {
		t.Errorf("label on Windows = %q", got)
	}
}

// A shell of the settings that this machine does not have is left out,
// and the default falls back to one found, rather than fail as a
// terminal starts.
func TestTerminalProfileMissing(t *testing.T) {
	s := settings.Default()
	a := newApp(&fakeHost{}, s, s.NewWindow())
	s.TerminalProfiles = []settings.TerminalProfile{
		{Name: "Nowhere", Path: `C:\no\such\shell.exe`},
		{Name: "Nothing", Path: "no-such-shell-mayoi"},
	}
	s.TerminalProfile = "Nowhere"
	for _, p := range a.termProfiles() {
		if p.name == "Nowhere" || p.name == "Nothing" {
			t.Errorf("a missing shell is offered: %+v", p)
		}
	}
	if got := a.defaultProfile().name; got == "Nowhere" {
		t.Error("the default is a missing shell")
	}
	if programPath("") != "" || programPath(`C:\no\such\shell.exe`) != "" {
		t.Error("programPath found a missing program")
	}
}

// The arrows of the panel go round its terminals, and a chip's cross
// closes its terminal.
func TestTerminalStepAndClose(t *testing.T) {
	if testing.Short() {
		t.Skip("starts a shell")
	}
	hs := newHarness(t, true)
	a, tt := hs.a, hs.tt
	a.run("view.terminal")
	a.run("view.newTerminal")
	a.run("view.newTerminal")
	hs.settle()
	terms := a.panelTerms()
	if len(terms) != 3 || a.panelTerm != terms[2] {
		t.Fatalf("%d terminals", len(terms))
	}
	// Once the shells are up, which then let go of the folder as they end.
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) && slices.ContainsFunc(terms, func(s *session) bool { return s.term.Text() == "" }) {
		hs.settle()
	}
	a.run("view.nextTerminal")
	if a.panelTerm != terms[0] {
		t.Error("Next Terminal did not go round to the first")
	}
	a.run("view.prevTerminal")
	if a.panelTerm != terms[2] {
		t.Error("Previous Terminal did not go round to the last")
	}
	hs.settle()
	if err := tt.Click("Next Terminal"); err != nil {
		t.Fatal(err)
	}
	hs.settle()
	if a.panelTerm != terms[0] {
		t.Error("the arrow did not show the next terminal")
	}
	if err := tt.Click("Close 2: " + terms[1].label()); err != nil {
		t.Fatalf("no cross: %v %q", err, tt.Texts())
	}
	hs.settle()
	if slices.Contains(a.terms, terms[1]) || len(a.panelTerms()) != 2 {
		t.Errorf("the cross left %d terminals", len(a.panelTerms()))
	}
	a.closeTerminals()
	time.Sleep(2 * time.Second) // Windows keeps the folder until the shells are gone
}

// The Manage button sits on the rail, or, without it, in the status bar.
func TestManageButton(t *testing.T) {
	hs := newHarness(t, true)
	hs.settle()
	if !hs.tt.HasText("Manage") {
		t.Errorf("no Manage button: %q", hs.tt.Texts())
	}
}
