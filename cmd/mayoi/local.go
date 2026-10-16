package main

import (
	"slices"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
)

// dropDocTabs closes the tabs that show a document.
func (a *app) dropDocTabs(d *document) {
	for _, col := range slices.Clone(a.cols) {
		for _, t := range slices.Clone(col.tabs) {
			if t.ed != nil && t.ed.document == d {
				a.dropTab(t)
			}
		}
	}
	a.rememberTabs()
}

// askSavePath asks where to save a document, in the native dialog.
func (a *app) askSavePath(name string, done func(path string)) {
	a.host.saveAs(name, done)
}

// barButton is a compact button of a bar.
func (a *app) barButton(c *ui.Context, key, label string) ui.Element {
	p := a.pal
	b := ui.ButtonBase(c.Key(key)).Height(24).Padding(0, 10).Radius(5).AlignItems(ui.Center).Label(label).
		Background(p.surface).Border(1, p.border)
	switch {
	case b.Pressed():
		b.Background(p.surfacePressed)
	case b.Hovered():
		b.Background(p.surfaceHover)
	}
	b.Children(func() {
		ui.Text(c, label).FontSize(12).FontWeight(500).TextColor(p.text).SingleLine()
	})
	return b
}

// shutdown stops watching the folder, as the project closes for good.
func (a *app) shutdown() {
	if a.tree != nil {
		a.tree.Close()
	}
}

// terminalExited takes the end of a terminal's program, which closes it.
func (a *app) terminalExited(s *session, t *terminal.Terminal, code int) {
	if s.term != t {
		return // one restarted in its place
	}
	a.removeTerminal(s)
}
