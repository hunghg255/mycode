package keymap

import (
	"fmt"
	"strings"
	"unicode"
)

// When is the condition of a binding, as VS Code writes it: names of
// contexts with !, &&, || and parentheses. A comparison, as
// "resourceExtname == .go", holds for != only: Mayoi's contexts have no
// values.
type When struct {
	op       string // "name", "!", "&&", "||", "==", "!="
	name     string
	children []*When
}

// Eval reports whether the condition holds, ctx telling which names do.
// A nil condition always holds.
func (w *When) Eval(ctx func(string) bool) bool {
	if w == nil {
		return true
	}
	switch w.op {
	case "name":
		return ctx != nil && ctx(w.name)
	case "!":
		return !w.children[0].Eval(ctx)
	case "&&":
		for _, c := range w.children {
			if !c.Eval(ctx) {
				return false
			}
		}
		return true
	case "||":
		for _, c := range w.children {
			if c.Eval(ctx) {
				return true
			}
		}
		return false
	case "!=":
		return true
	}
	return false
}

// ParseWhen reads a condition.
func ParseWhen(s string) (*When, error) {
	p := &whenParser{toks: tokenize(s)}
	w, err := p.or()
	if err != nil {
		return nil, err
	}
	if p.i < len(p.toks) {
		return nil, fmt.Errorf("unexpected %q", p.toks[p.i])
	}
	return w, nil
}

func tokenize(s string) []string {
	var toks []string
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case strings.HasPrefix(s[i:], "&&"), strings.HasPrefix(s[i:], "||"),
			strings.HasPrefix(s[i:], "=="), strings.HasPrefix(s[i:], "!="),
			strings.HasPrefix(s[i:], "=~"):
			toks = append(toks, s[i:i+2])
			i += 2
		case c == '!' || c == '(' || c == ')':
			toks = append(toks, s[i:i+1])
			i++
		case c == '\'' || c == '"':
			j := strings.IndexByte(s[i+1:], c)
			if j < 0 {
				j = len(s) - i - 1
			}
			toks = append(toks, s[i:min(i+j+2, len(s))])
			i += j + 2
		default:
			j := i
			for j < len(s) && !unicode.IsSpace(rune(s[j])) && strings.IndexByte("!()&|=", s[j]) < 0 {
				j++
			}
			toks = append(toks, s[i:j])
			i = j
		}
	}
	return toks
}

type whenParser struct {
	toks []string
	i    int
}

func (p *whenParser) peek() string {
	if p.i < len(p.toks) {
		return p.toks[p.i]
	}
	return ""
}

func (p *whenParser) or() (*When, error) {
	return p.list("||", p.and)
}

func (p *whenParser) and() (*When, error) {
	return p.list("&&", p.unary)
}

func (p *whenParser) list(op string, next func() (*When, error)) (*When, error) {
	first, err := next()
	if err != nil {
		return nil, err
	}
	w := &When{op: op, children: []*When{first}}
	for p.peek() == op {
		p.i++
		c, err := next()
		if err != nil {
			return nil, err
		}
		w.children = append(w.children, c)
	}
	if len(w.children) == 1 {
		return first, nil
	}
	return w, nil
}

func (p *whenParser) unary() (*When, error) {
	switch t := p.peek(); t {
	case "":
		return nil, fmt.Errorf("condition ends early")
	case "!":
		p.i++
		c, err := p.unary()
		if err != nil {
			return nil, err
		}
		return &When{op: "!", children: []*When{c}}, nil
	case "(":
		p.i++
		w, err := p.or()
		if err != nil {
			return nil, err
		}
		if p.peek() != ")" {
			return nil, fmt.Errorf("missing )")
		}
		p.i++
		return w, nil
	case ")", "&&", "||", "==", "!=", "=~":
		return nil, fmt.Errorf("unexpected %q", t)
	default:
		p.i++
		name := &When{op: "name", name: t}
		if op := p.peek(); op == "==" || op == "!=" || op == "=~" {
			p.i++
			if p.peek() == "" {
				return nil, fmt.Errorf("%s needs a value", op)
			}
			p.i++
			if op == "=~" {
				op = "=="
			}
			return &When{op: op, name: t}, nil
		}
		return name, nil
	}
}
