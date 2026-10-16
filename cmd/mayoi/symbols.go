package main

import (
	"strings"

	"github.com/egoist/mygo/ui"

	"mayoi/internal/highlight"
	"mayoi/internal/symbols"
)

// symbolCache keeps the symbols of the version of a document go to
// symbol listed last.
type symbolCache struct {
	doc     int
	version uint64
	symbols []symbols.Symbol
	names   []string
}

// documentSymbols returns the symbols of the document shown.
func (a *app) documentSymbols() ([]symbols.Symbol, []string) {
	d := a.activeEditor()
	sc := &a.quick.syms
	if d == nil {
		return nil, nil
	}
	if sc.doc == d.id && sc.version == d.buf.Version() && sc.symbols != nil {
		return sc.symbols, sc.names
	}
	sc.doc, sc.version = d.id, d.buf.Version()
	sc.symbols = symbols.Find(d.buf.Snapshot(), d.hl != nil && strings.EqualFold(highlight.Name(d.hl.Lexer()), "markdown"))
	if sc.symbols == nil {
		sc.symbols = []symbols.Symbol{}
	}
	sc.names = make([]string, len(sc.symbols))
	for i, s := range sc.symbols {
		sc.names[i] = s.Name
	}
	return sc.symbols, sc.names
}

// symbolIcon is the mark of a kind of symbol, and its color.
func (a *app) symbolIcon(kind string) (*ui.SVG, ui.Color) {
	p := a.pal
	switch kind {
	case "function", "method":
		return iconFunction, p.syntax[highlight.Function]
	case "class":
		return iconBox, p.syntax[highlight.Type]
	case "interface":
		return iconBraces, p.syntax[highlight.Type]
	case "type", "enum":
		return iconType, p.syntax[highlight.Type]
	case "heading":
		return iconHash, p.syntax[highlight.Heading]
	}
	return iconHash, p.muted
}
