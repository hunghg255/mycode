package main

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"mayoi/internal/git"
	"mayoi/internal/linediff"
)

func TestOverlappingAndInverted(t *testing.T) {
	hs := []linediff.Hunk{hunk(2, 1, 2, 1), hunk(10, 0, 10, 2), hunk(20, 3, 22, 0)}
	cases := []struct {
		want []linediff.Hunk
		got  []linediff.Hunk
	}{
		{[]linediff.Hunk{hunk(2, 1, 2, 1)}, []linediff.Hunk{hunk(2, 1, 2, 1)}},
		{[]linediff.Hunk{hunk(10, 0, 11, 1)}, []linediff.Hunk{hunk(10, 0, 10, 2)}}, // a line of an addition
		{[]linediff.Hunk{hunk(20, 3, 22, 0)}, []linediff.Hunk{hunk(20, 3, 22, 0)}}, // a removal
		{[]linediff.Hunk{hunk(5, 1, 5, 1)}, nil},
		{[]linediff.Hunk{hunk(2, 1, 2, 1), hunk(20, 3, 22, 0)}, []linediff.Hunk{hunk(2, 1, 2, 1), hunk(20, 3, 22, 0)}},
	}
	for _, c := range cases {
		if got := overlapping(hs, c.want); !slices.Equal(got, c.got) {
			t.Errorf("overlapping %v: %v, want %v", c.want, got, c.got)
		}
	}
	a := strings.Split("one\ntwo\nthree\nfour", "\n")
	b := strings.Split("one\n2\nthree\nfour\nfive", "\n")
	fwd := linediff.Hunks(a, b)
	if got := linediff.Apply(b, a, inverted(fwd)); !slices.Equal(got, a) {
		t.Errorf("inverted hunks give %q, want %q", got, a)
	}
}

func TestShortAgo(t *testing.T) {
	now := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		d    time.Duration
		want string
	}{
		{10 * time.Second, "now"}, {5 * time.Minute, "5m"}, {3 * time.Hour, "3h"}, {2 * 24 * time.Hour, "2d"},
		{15 * 24 * time.Hour, "2w"}, {90 * 24 * time.Hour, "3mo"}, {800 * 24 * time.Hour, "2y"},
	} {
		if got := shortAgo(now.Add(-c.d), now); got != c.want {
			t.Errorf("%v: %q, want %q", c.d, got, c.want)
		}
	}
}

func TestEllipsizeAndInitials(t *testing.T) {
	if got := ellipsize("short", 10); got != "short" {
		t.Errorf("%q", got)
	}
	if got := ellipsize("迷い迷い迷い", 4); got != "迷い迷…" {
		t.Errorf("%q", got)
	}
	for name, want := range map[string]string{"ada lovelace": "AL", "Grace": "G", "": "?", "  ": "?", "émile zola x": "ÉZ"} {
		if got := initials(name); got != want {
			t.Errorf("initials(%q) = %q, want %q", name, got, want)
		}
	}
	if statusWord('R') != "Renamed" || statusWord('?') != "" {
		t.Errorf("status words")
	}
}

// The header of a file shows at the top of the view over its lines, and
// goes up with the end of its file.
func TestStickyHeaderPushedUp(t *testing.T) {
	v := newDiffView(layoutInline)
	v.files = []*diffFile{{path: "a"}, {path: "b"}}
	// a: header and 5 lines; the room; b: header and 5 lines.
	add := func(kind rowKind, file int) {
		v.rows = append(v.rows, diffRow{kind: kind, file: file, old: -1, new: -1, hunk: -1, peer: -1, gap: -1, h: 1})
	}
	add(rowSection, 0)
	v.heads = append(v.heads, len(v.rows))
	add(rowFile, 0)
	for range 5 {
		add(rowLine, 0)
	}
	add(rowSpace, 1)
	v.heads = append(v.heads, len(v.rows))
	add(rowFile, 1)
	for range 5 {
		add(rowLine, 1)
	}
	for i := range v.rows {
		v.tops = append(v.tops, i)
	}
	v.tops = append(v.tops, len(v.rows))
	const lineH = 10
	at := func(row float32) float32 { return editorPadY + row*lineH }
	// At the first line of a, its header (row 1) sticks at the top.
	v.scroll.Y = at(3)
	if h, y := v.stickyHeader(lineH); h != 1 || y != v.scroll.Y {
		t.Errorf("at a's lines: %d at %v", h, y)
	}
	// At a's last line, the header goes up with it: a ends at row 7.
	v.scroll.Y = at(6.5)
	if h, y := v.stickyHeader(lineH); h != 1 || y != at(6) {
		t.Errorf("at a's end: %d at %v, want %v", h, y, at(6))
	}
	// Over the room between them, none.
	v.scroll.Y = at(7)
	if h, _ := v.stickyHeader(lineH); h != -1 {
		t.Errorf("over the room: %d", h)
	}
}

func TestTreeRows(t *testing.T) {
	root := "/r"
	es := []git.Entry{
		{Path: "/r/a/b/c.go"}, {Path: "/r/a/b/d.go"}, {Path: "/r/a/e.go"}, {Path: "/r/main.go"}, {Path: "/r/x/y/z/w.go"},
	}
	show := func(rows []scmRow) string {
		var out []string
		for _, r := range rows {
			s := strings.Repeat(" ", r.depth)
			if r.dir != "" {
				s += r.name + "/"
			} else {
				s += filepath.Base(r.e.Path)
			}
			out = append(out, s)
		}
		return strings.Join(out, "|")
	}
	rows := treeRows(nil, groupChanges, es, root, nil)
	if got, want := show(rows), "a/| b/|  c.go|  d.go| e.go|x/y/z/| w.go|main.go"; got != want {
		t.Errorf("tree\n%s, want\n%s", got, want)
	}
	// A folder closed shows without its files.
	closed := map[string]bool{rows[1].key: true}
	if got, want := show(treeRows(nil, groupChanges, es, root, closed)), "a/| b/| e.go|x/y/z/| w.go|main.go"; got != want {
		t.Errorf("closed\n%s, want\n%s", got, want)
	}
}

func TestInHead(t *testing.T) {
	a := &app{}
	g := &a.git
	// d is a merge of b and c on main; e is on a branch off a.
	g.history = []git.Commit{
		{Hash: "e", Parents: []string{"a"}},
		{Hash: "d", Parents: []string{"b", "c"}},
		{Hash: "c", Parents: []string{"a"}},
		{Hash: "b", Parents: []string{"a"}},
		{Hash: "a"},
	}
	g.status = &git.Status{Head: "d"}
	for h, want := range map[string]bool{"a": true, "b": true, "c": true, "d": true, "e": false} {
		if got := a.inHead(h); got != want {
			t.Errorf("inHead(%s) = %v, want %v", h, got, want)
		}
	}
	g.status, g.historyGen = &git.Status{Head: "e"}, 1
	if !a.inHead("e") || a.inHead("d") {
		t.Error("not worked out again as HEAD moved")
	}
}
