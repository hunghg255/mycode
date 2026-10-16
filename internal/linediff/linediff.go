// Package linediff compares two texts line by line, for the marks of the
// lines changed since a version of a file and for showing the changes.
package linediff

// Kind is how a line differs from the base text.
type Kind uint8

const (
	Same Kind = iota
	Added
	Modified
	// Deleted marks a line that base lines were removed above, or below
	// for the last line.
	Deleted
	DeletedBelow
)

// maxEdits is how many lines the diff follows changes of before it gives
// up and marks the whole changed run modified.
const maxEdits = 4000

// Hunk is a run of lines of base a replaced by lines of b: ALen lines
// from line A of a by BLen lines from line B of b. One of the lengths may
// be 0, for lines added or removed.
type Hunk struct{ A, ALen, B, BLen int }

// Hunks returns the runs of lines that differ between base a and b, in
// order.
func Hunks(a, b []string) []Hunk {
	// The lines the texts start and end with in common are the same; the
	// diff runs on the rest, which an edit mostly makes small.
	pre := 0
	for pre < len(a) && pre < len(b) && a[pre] == b[pre] {
		pre++
	}
	suf := 0
	for suf < len(a)-pre && suf < len(b)-pre && a[len(a)-1-suf] == b[len(b)-1-suf] {
		suf++
	}
	a, b = a[pre:len(a)-suf], b[pre:len(b)-suf]
	if len(a) == 0 && len(b) == 0 {
		return nil
	}
	ops, ok := myers(a, b)
	if !ok {
		return []Hunk{{pre, len(a), pre, len(b)}}
	}
	// Each run of removals and insertions between equal lines.
	var hunks []Hunk
	i, j := 0, 0 // in a and b
	for k := 0; k < len(ops); {
		if ops[k] == opEqual {
			i, j, k = i+1, j+1, k+1
			continue
		}
		del, ins := 0, 0
		for ; k < len(ops) && ops[k] != opEqual; k++ {
			if ops[k] == opDelete {
				del++
			} else {
				ins++
			}
		}
		hunks = append(hunks, Hunk{pre + i, del, pre + j, ins})
		i, j = i+del, j+ins
	}
	return hunks
}

// Lines returns the kind of each line of b, against base a.
func Lines(a, b []string) []Kind { return Marks(Hunks(a, b), len(b)) }

// Marks returns the kind of each of n lines of a text, of the hunks it
// differs from its base by: as many lines of a hunk as both sides have
// are modified, the rest added, or removed.
func Marks(hunks []Hunk, n int) []Kind {
	marks := make([]Kind, n)
	for _, h := range hunks {
		markRun(marks, h.B, h.ALen, h.BLen)
	}
	return marks
}

// Apply returns base a with the hunks of it chosen replaced by their
// lines of b.
func Apply(a, b []string, hunks []Hunk) []string {
	out := make([]string, 0, len(a))
	at := 0
	for _, h := range hunks {
		out = append(out, a[at:h.A]...)
		out = append(out, b[h.B:h.B+h.BLen]...)
		at = h.A + h.ALen
	}
	return append(out, a[at:]...)
}

// Span is a run of bytes of a line, from Start up to End.
type Span struct{ Start, End int }

// maxWordTokens is how long two lines are, in words, for Words to find
// the words that differ, rather than to say the whole lines do.
const maxWordTokens = 600

// Words returns the runs of line a and of line b that differ, word by
// word, of a line modified from a to b.
func Words(a, b string) (as, bs []Span) {
	ta, tb := tokens(a), tokens(b)
	if len(ta) > maxWordTokens || len(tb) > maxWordTokens {
		return []Span{{0, len(a)}}, []Span{{0, len(b)}}
	}
	sa, sb := make([]string, len(ta)), make([]string, len(tb))
	for i, t := range ta {
		sa[i] = a[t.Start:t.End]
	}
	for i, t := range tb {
		sb[i] = b[t.Start:t.End]
	}
	add := func(spans []Span, s Span) []Span {
		if n := len(spans); n > 0 && spans[n-1].End == s.Start {
			spans[n-1].End = s.End
			return spans
		}
		return append(spans, s)
	}
	for _, h := range Hunks(sa, sb) {
		for _, t := range ta[h.A : h.A+h.ALen] {
			as = add(as, t)
		}
		for _, t := range tb[h.B : h.B+h.BLen] {
			bs = add(bs, t)
		}
	}
	return as, bs
}

// tokens splits a line into words, runs of blanks, and other characters
// one each.
func tokens(s string) []Span {
	var out []Span
	class := func(c byte) int {
		switch {
		case c == ' ' || c == '\t':
			return 1
		case c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80:
			return 2
		}
		return 0
	}
	for i := 0; i < len(s); {
		k, j := class(s[i]), i+1
		if k != 0 {
			for j < len(s) && class(s[j]) == k {
				j++
			}
		}
		out = append(out, Span{i, j})
		i = j
	}
	return out
}

// markRun marks a run of del lines of the base replaced by ins lines at
// line at of the text.
func markRun(marks []Kind, at, del, ins int) {
	mod := min(del, ins)
	for n := range ins {
		if n < mod {
			marks[at+n] = Modified
		} else {
			marks[at+n] = Added
		}
	}
	if del > ins && len(marks) > 0 {
		switch at := at + ins; {
		case at < len(marks):
			if marks[at] == Same {
				marks[at] = Deleted
			}
		default:
			if marks[len(marks)-1] == Same {
				marks[len(marks)-1] = DeletedBelow
			}
		}
	}
}

type op uint8

const (
	opEqual op = iota
	opDelete
	opInsert
)

// myers returns the shortest edit script from a to b, by Myers' greedy
// algorithm, or false when it takes more than maxEdits.
func myers(a, b []string) ([]op, bool) {
	n, m := len(a), len(b)
	maxD := min(n+m, maxEdits)
	off := maxD + 1
	v := make([]int, 2*maxD+3)
	// trace keeps v of each step, the part of it in use, to walk back.
	var trace [][]int
	for d := 0; d <= maxD; d++ {
		for k := -d; k <= d; k += 2 {
			var x int
			if k == -d || k != d && v[off+k-1] < v[off+k+1] {
				x = v[off+k+1] // down: an insertion
			} else {
				x = v[off+k-1] + 1 // right: a deletion
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x, y = x+1, y+1
			}
			v[off+k] = x
			if x >= n && y >= m {
				trace = append(trace, append([]int(nil), v[off-d-1:off+d+2]...))
				return backtrack(trace, n, m), true
			}
		}
		trace = append(trace, append([]int(nil), v[off-d-1:off+d+2]...))
	}
	return nil, false
}

// backtrack walks the trace of myers back from the end, and returns the
// script from the start.
func backtrack(trace [][]int, n, m int) []op {
	var ops []op
	x, y := n, m
	for d := len(trace) - 1; d > 0; d-- {
		prev := trace[d-1] // v of step d-1, from k = -d to d
		at := func(k int) int { return prev[k+d] }
		k := x - y
		var pk int
		if k == -d || k != d && at(k-1) < at(k+1) {
			pk = k + 1
		} else {
			pk = k - 1
		}
		px := at(pk)
		py := px - pk
		for x > px && y > py {
			ops = append(ops, opEqual)
			x, y = x-1, y-1
		}
		if x == px {
			ops = append(ops, opInsert)
		} else {
			ops = append(ops, opDelete)
		}
		x, y = px, py
	}
	for x > 0 && y > 0 {
		ops = append(ops, opEqual)
		x, y = x-1, y-1
	}
	for i, j := 0, len(ops)-1; i < j; i, j = i+1, j-1 {
		ops[i], ops[j] = ops[j], ops[i]
	}
	return ops
}
