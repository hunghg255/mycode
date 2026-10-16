package keymap

import (
	"slices"
	"testing"

	"github.com/egoist/mygo/ui"
)

const cursorFile = `// Place your key bindings in this file to override the defaults
[
	{ "key": "ctrl+. s", "command": "editor.action.indentUsingSpaces" },
	{
		"key": "ctrl+. g c",
		"command": "runCommands",
		"args": { "commands": ["workbench.action.files.save", "git.push",] }, // trailing
	},
	{ "key": "d", "command": "deleteFile", "when": "filesExplorerFocus && !inputFocus" },
	/* a block
	   comment */
	{ "key": "cmd+1", "command": "workbench.action.toggleSidebarVisibility" },
	{ "key": "cmd+1", "command": "-workbench.action.focusFirstEditorGroup" },
	{ "key": "alt+,", "command": "type", "args": { "text": "a // b, ]" } },
	{ "key": "hyper+x", "command": "nothing" },
]
`

func TestParse(t *testing.T) {
	m, err := Parse([]byte(cursorFile))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Bindings) != 6 || len(m.Errors) != 1 {
		t.Fatalf("%d bindings, errors %q", len(m.Bindings), m.Errors)
	}
	gc := m.Bindings[1]
	if want := []Stroke{{ui.Ctrl, ui.KeyPeriod}, {0, ui.KeyG}, {0, ui.KeyC}}; !slices.Equal(gc.Keys, want) {
		t.Errorf("chord %v", gc.Keys)
	}
	if string(m.Bindings[5].Args) != `{ "text": "a // b, ]" }` {
		t.Errorf("args of a string with a comment and a comma: %s", m.Bindings[5].Args)
	}
}

func TestLookup(t *testing.T) {
	m, _ := Parse([]byte(cursorFile))
	none := func(string) bool { return false }
	explorer := func(n string) bool { return n == "filesExplorerFocus" }
	prefix := Stroke{ui.Ctrl, ui.KeyPeriod}
	if b, more := m.Lookup([]Stroke{prefix}, none); b != nil || !more {
		t.Errorf("ctrl+. starts a chord: %v %v", b, more)
	}
	if b, more := m.Lookup([]Stroke{prefix, {0, ui.KeyG}}, none); b != nil || !more {
		t.Errorf("ctrl+. g goes on: %v %v", b, more)
	}
	if b, _ := m.Lookup([]Stroke{prefix, {0, ui.KeyS}}, none); b == nil || b.Command != "editor.action.indentUsingSpaces" {
		t.Errorf("ctrl+. s: %v", b)
	}
	if b, more := m.Lookup([]Stroke{prefix, {0, ui.KeyX}}, none); b != nil || more {
		t.Errorf("ctrl+. x is no binding: %v %v", b, more)
	}
	if b, _ := m.Lookup([]Stroke{{0, ui.KeyD}}, none); b != nil {
		t.Error("d outside the explorer")
	}
	if b, _ := m.Lookup([]Stroke{{0, ui.KeyD}}, explorer); b == nil || b.Command != "deleteFile" {
		t.Errorf("d in the explorer: %v", b)
	}
	if b, _ := m.Lookup([]Stroke{{ui.Super, ui.Key1}}, none); b == nil || b.Command != "workbench.action.toggleSidebarVisibility" {
		t.Errorf("cmd+1: %v", b)
	}
	if !m.Binds(Stroke{ui.Super, ui.Key1}) || !m.Binds(prefix) || m.Binds(Stroke{0, ui.KeyG}) {
		t.Error("Binds")
	}
	if !m.Removes("workbench.action.focusFirstEditorGroup") {
		t.Error("Removes")
	}
}

func TestRemovalTakesAwayEarlier(t *testing.T) {
	m, err := Parse([]byte(`[
		{ "key": "cmd+k", "command": "a" },
		{ "key": "cmd+k", "command": "-a" },
		{ "key": "cmd+j", "command": "b" },
		{ "key": "cmd+j", "command": "c" },
	]`))
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := m.Lookup([]Stroke{{ui.Super, ui.KeyK}}, nil); b != nil {
		t.Errorf("removed: %v", b)
	}
	if b, _ := m.Lookup([]Stroke{{ui.Super, ui.KeyJ}}, nil); b == nil || b.Command != "c" {
		t.Errorf("the last wins: %v", b)
	}
}

func TestWhen(t *testing.T) {
	ctx := func(n string) bool { return n == "a" || n == "b" }
	for expr, want := range map[string]bool{
		"a":                        true,
		"c":                        false,
		"!c":                       true,
		"a && b":                   true,
		"a && c":                   false,
		"c || b":                   true,
		"!(a && c) && b":           true,
		"c || a && !b":             false,
		"resourceExtname == .go":   false,
		"resourceExtname != '.go'": true,
		"terminalFocus && terminalHasBeenCreated || terminalFocus && terminalProcessSupported": false,
	} {
		w, err := ParseWhen(expr)
		if err != nil {
			t.Errorf("%s: %v", expr, err)
			continue
		}
		if got := w.Eval(ctx); got != want {
			t.Errorf("%s = %v", expr, got)
		}
	}
	for _, bad := range []string{"a &&", "(a", "a )", "&& a"} {
		if _, err := ParseWhen(bad); err == nil {
			t.Errorf("%q parsed", bad)
		}
	}
}

func TestStrokes(t *testing.T) {
	for in, want := range map[string]Stroke{
		"shift+cmd+p": {ui.Shift | ui.Super, ui.KeyP},
		"ctrl+`":      {ui.Ctrl, ui.KeyBackquote},
		", ":          {0, ui.KeyComma},
		"alt+shift+,": {ui.Alt | ui.Shift, ui.KeyComma},
		"space":       {0, ui.KeySpace},
		"F5":          {0, ui.KeyF5},
	} {
		got, err := ParseKeys(in)
		if err != nil || len(got) != 1 || got[0] != want {
			t.Errorf("%q: %v %v", in, got, err)
		}
	}
	if st, ok := ParseAccel("Shift+CmdOrCtrl+S"); !ok || st != (Stroke{ui.Shift | ui.Cmd, ui.KeyS}) {
		t.Errorf("accel %v", st)
	}
	if got := (Stroke{ui.Ctrl | ui.Shift, ui.KeyPeriod}).Accel(); got != "Ctrl+Shift+." {
		t.Errorf("Accel %q", got)
	}
}
