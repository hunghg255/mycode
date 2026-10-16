package main

import (
	"slices"
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestScopes(t *testing.T) {
	src := ui.NewTextBuffer(`package main

func f(
	a int,
) {
	if a > 0 {

		g()
	} else {
		h()
	}
}
`).Snapshot()
	for _, tc := range []struct {
		line int
		want []int
	}{
		{0, nil},
		{2, nil},
		{7, []int{2, 5}}, // g(): in func f, named by its first line, and if
		{6, []int{2, 5}}, // a blank line is as deep as the line below it
		{9, []int{2, 8}}, // h(): in else
		{11, nil},
	} {
		if got := scopes(src, tc.line); !slices.Equal(got, tc.want) {
			t.Errorf("scopes of line %d: %v, want %v", tc.line, got, tc.want)
		}
	}
	// The lines that stick are above the place they cover.
	// Over the line of else, if sticks no more.
	if got := stickyLines(src, 7, 5, scopes); !slices.Equal(got, []int{2}) {
		t.Errorf("sticky at 7: %v", got)
	}
	// With if at the top, it sticks below func, over the line it covers.
	if got := stickyLines(src, 5, 5, scopes); !slices.Equal(got, []int{2, 5}) {
		t.Errorf("sticky at 5: %v", got)
	}
	if got := stickyLines(src, 3, 5, scopes); !slices.Equal(got, []int{2}) {
		t.Errorf("sticky at 3: %v", got)
	}
	if got := stickyLines(src, 1, 5, scopes); len(got) != 0 {
		t.Errorf("sticky at 1: %v", got)
	}
	if got := scopeLabel(src, 8); got != "} else" {
		t.Errorf("label %q", got)
	}
}
