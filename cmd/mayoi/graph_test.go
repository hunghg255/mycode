package main

import (
	"strings"
	"testing"

	"mayoi/internal/git"
)

// commitsOf makes commits from lines of "hash parent…", newest first.
func commitsOf(lines ...string) []git.Commit {
	var cs []git.Commit
	for _, l := range lines {
		f := strings.Fields(l)
		cs = append(cs, git.Commit{Hash: f[0], Parents: f[1:]})
	}
	return cs
}

// lanesOf names the commits a row's lanes lead to, "-" for one free.
func lanesOf(ls []graphLane) string {
	var s []string
	for _, l := range ls {
		if l.hash == "" {
			s = append(s, "-")
		} else {
			s = append(s, l.hash)
		}
	}
	return strings.Join(s, " ")
}

func TestLayoutGraphLine(t *testing.T) {
	rows := layoutGraph(commitsOf("c b", "b a", "a"))
	for i, r := range rows {
		if r.lane != 0 || r.color != 0 || r.merge {
			t.Errorf("row %d %+v", i, r)
		}
	}
	if len(rows[0].above) != 0 || lanesOf(rows[0].below) != "b" || len(rows[2].below) != 0 {
		t.Errorf("edges %+v %+v", rows[0], rows[2])
	}
	if graphLanes(rows) != 1 {
		t.Errorf("lanes %d", graphLanes(rows))
	}
}

func TestLayoutGraphMerge(t *testing.T) {
	// m merges s, made on b, into c.
	rows := layoutGraph(commitsOf("m c s", "s b", "c b", "b a", "a"))
	m, s, c, b := rows[0], rows[1], rows[2], rows[3]
	if !m.merge || m.lane != 0 || lanesOf(m.below) != "c s" || !m.from[0] || !m.from[1] {
		t.Errorf("merge %+v", m)
	}
	if s.lane != 1 || s.color != 1 || lanesOf(s.below) != "c b" || s.from[0] || !s.from[1] {
		t.Errorf("side %+v", s)
	}
	if c.lane != 0 || c.color != 0 || lanesOf(c.below) != "b b" {
		t.Errorf("c %+v", c)
	}
	// Both lanes join at b, the side's freed.
	if b.lane != 0 || lanesOf(b.above) != "b b" || lanesOf(b.below) != "a" {
		t.Errorf("fork %+v", b)
	}
	if graphLanes(rows) != 2 {
		t.Errorf("lanes %d", graphLanes(rows))
	}
}

func TestLayoutGraphBranches(t *testing.T) {
	// Two branch tips, x and y, then an octopus o of three, and a lane
	// freed taken again from the left.
	rows := layoutGraph(commitsOf("x a", "y b", "a o", "b o", "o p q r", "q", "p", "r"))
	if rows[0].lane != 0 || rows[1].lane != 1 || rows[1].color != 1 {
		t.Errorf("tips %+v %+v", rows[0], rows[1])
	}
	o := rows[4]
	if !o.merge || o.lane != 0 || lanesOf(o.below) != "p q r" {
		t.Errorf("octopus %+v", o)
	}
	// q ends its lane; p keeps the first, and r the third.
	if lanesOf(rows[5].below) != "p - r" || rows[6].lane != 0 || rows[7].lane != 2 {
		t.Errorf("after %q %+v %+v", lanesOf(rows[5].below), rows[6], rows[7])
	}
	// A commit whose parents are past the page leaves its lane open.
	cut := layoutGraph(commitsOf("b a"))
	if lanesOf(cut[0].below) != "a" {
		t.Errorf("cut %+v", cut[0])
	}
}
