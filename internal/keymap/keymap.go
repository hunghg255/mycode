// Package keymap reads the keyboard shortcuts a person adds to Mayoi's, in
// keybindings.json, as VS Code writes them: a list of the keys, the
// command they run with its arguments, and when they apply.
package keymap

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/fsnotify/fsnotify"
)

// Stroke is a key pressed with its modifiers.
type Stroke struct {
	Mods ui.Modifiers
	Key  ui.Key
}

// Binding is a shortcut of the file: its strokes, more than one for a
// chord, and the command it runs. A command named with a "-" first takes
// the shortcut away from that command instead.
type Binding struct {
	Keys    []Stroke
	Command string
	Args    json.RawMessage
	When    *When
}

// Removal reports whether the binding takes a shortcut away.
func (b *Binding) Removal() bool { return strings.HasPrefix(b.Command, "-") }

// Map is the shortcuts of the file, in its order: a later one wins over
// an earlier one of the same keys.
type Map struct {
	Bindings []Binding
	// Errors say what of the file was left out, as a key with no name
	// Mayoi knows.
	Errors []string
}

// Path is the file of the shortcuts beside the settings' file.
func Path(settingsPath string) string {
	if settingsPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(settingsPath), "keybindings.json")
}

// Template is what a new file of shortcuts starts with.
const Template = `// Keyboard shortcuts, in VS Code's format: "key" is a key or a chord as
// "ctrl+. s", "command" is a command of Mayoi's or of VS Code's, and
// "when" when it applies, as "editorTextFocus" or "terminalFocus".
[
]
`

// Load reads the shortcuts of path: none when there is no file.
func Load(path string) (*Map, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return &Map{}, nil
	}
	if err != nil {
		return nil, err
	}
	return Parse(data)
}

type entry struct {
	Key     string          `json:"key"`
	Command string          `json:"command"`
	Args    json.RawMessage `json:"args"`
	When    string          `json:"when"`
}

// Parse reads shortcuts as VS Code writes them, with comments and commas
// after the last item.
func Parse(data []byte) (*Map, error) {
	var es []entry
	data = StripJSONC(data)
	if len(bytes.TrimSpace(data)) == 0 {
		return &Map{}, nil
	}
	if err := json.Unmarshal(data, &es); err != nil {
		return nil, err
	}
	m := &Map{}
	for _, e := range es {
		if e.Command == "" {
			continue
		}
		keys, err := ParseKeys(e.Key)
		if err != nil {
			m.Errors = append(m.Errors, fmt.Sprintf("%q: %v", e.Key, err))
			continue
		}
		b := Binding{Keys: keys, Command: e.Command, Args: e.Args}
		if strings.TrimSpace(e.When) != "" {
			w, err := ParseWhen(e.When)
			if err != nil {
				m.Errors = append(m.Errors, fmt.Sprintf("%q: %v", e.When, err))
				continue
			}
			b.When = w
		}
		m.Bindings = append(m.Bindings, b)
	}
	return m, nil
}

// Lookup returns the binding of the strokes pressed whose condition
// holds, the last of the file, or reports that they start a chord of a
// longer one, which wins over the binding of the strokes themselves.
// Removals take away the bindings before them of the same keys and
// command.
func (m *Map) Lookup(seq []Stroke, ctx func(string) bool) (b *Binding, prefix bool) {
	if m == nil {
		return nil, false
	}
	removed := map[string]bool{}
	for i := len(m.Bindings) - 1; i >= 0; i-- {
		bd := &m.Bindings[i]
		if bd.Removal() {
			if len(bd.Keys) == 0 || slices.Equal(bd.Keys, seq) {
				removed[bd.Command[1:]] = true
			}
			continue
		}
		if removed[bd.Command] || len(bd.Keys) < len(seq) || !slices.Equal(bd.Keys[:len(seq)], seq) || !bd.When.Eval(ctx) {
			continue
		}
		if len(bd.Keys) > len(seq) {
			prefix = true
		} else if b == nil {
			b = bd
		}
	}
	if prefix {
		return nil, true
	}
	return b, false
}

// Binds reports whether a binding of the file starts with s, or takes s
// away from a command: the shortcuts of Mayoi's own on s let it be.
func (m *Map) Binds(s Stroke) bool {
	if m == nil {
		return false
	}
	for _, b := range m.Bindings {
		if len(b.Keys) > 0 && b.Keys[0] == s {
			return true
		}
	}
	return false
}

// Removes reports whether the file takes away the shortcut of a command,
// any of its names.
func (m *Map) Removes(names ...string) bool {
	if m == nil {
		return false
	}
	for _, b := range m.Bindings {
		if b.Removal() && slices.Contains(names, b.Command[1:]) {
			return true
		}
	}
	return false
}

// Last returns the keys of the last binding of any of the commands names,
// as the shortcut to show for it: nil for none.
func (m *Map) Last(names ...string) []Stroke {
	if m == nil {
		return nil
	}
	for i := len(m.Bindings) - 1; i >= 0; i-- {
		b := m.Bindings[i]
		if b.When == nil && len(b.Args) == 0 && slices.Contains(names, b.Command) {
			return b.Keys
		}
	}
	return nil
}

// StripJSONC drops the comments of JSON, and the commas before a closing
// bracket or brace.
func StripJSONC(data []byte) []byte {
	return dropTrailingCommas(dropComments(data))
}

func dropComments(data []byte) []byte {
	out := make([]byte, 0, len(data))
	for i := 0; i < len(data); i++ {
		c := data[i]
		switch {
		case c == '"':
			j := skipString(data, i)
			out = append(out, data[i:j]...)
			i = j - 1
		case c == '/' && i+1 < len(data) && data[i+1] == '/':
			for i < len(data) && data[i] != '\n' {
				i++
			}
			if i < len(data) {
				out = append(out, '\n')
			}
		case c == '/' && i+1 < len(data) && data[i+1] == '*':
			end := bytes.Index(data[i+2:], []byte("*/"))
			if end < 0 {
				return out
			}
			i += 2 + end + 1
		default:
			out = append(out, c)
		}
	}
	return out
}

func dropTrailingCommas(data []byte) []byte {
	out := make([]byte, 0, len(data))
	for i := 0; i < len(data); i++ {
		c := data[i]
		switch c {
		case '"':
			j := skipString(data, i)
			out = append(out, data[i:j]...)
			i = j - 1
			continue
		case ',':
			rest := bytes.TrimLeft(data[i+1:], " \t\r\n")
			if len(rest) > 0 && (rest[0] == ']' || rest[0] == '}') {
				continue
			}
		}
		out = append(out, c)
	}
	return out
}

// skipString returns the end of the string that starts at i, after its
// closing quote.
func skipString(data []byte, i int) int {
	j := i + 1
	for j < len(data) && data[j] != '"' {
		if data[j] == '\\' {
			j++
		}
		j++
	}
	return min(j+1, len(data))
}

// Watch calls changed, on a goroutine of its own, with the shortcuts of
// path each time it is saved, or with the error it does not parse with.
// stop stops watching.
func Watch(path string, changed func(*Map, error)) (stop func(), err error) {
	if path == "" {
		return func() {}, nil
	}
	dir := filepath.Dir(path)
	os.MkdirAll(dir, 0o755)
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	// The folder rather than the file, which editors' saves replace.
	if err := w.Add(dir); err != nil {
		w.Close()
		return nil, err
	}
	go func() {
		var settle <-chan time.Time
		for {
			select {
			case ev, ok := <-w.Events:
				if !ok {
					return
				}
				if filepath.Clean(ev.Name) == filepath.Clean(path) {
					settle = time.After(80 * time.Millisecond)
				}
			case _, ok := <-w.Errors:
				if !ok {
					return
				}
			case <-settle:
				settle = nil
				changed(Load(path))
			}
		}
	}()
	return func() { w.Close() }, nil
}
