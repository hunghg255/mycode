package workspace

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

func BenchmarkFuzzy100k(b *testing.B) {
	files := make([]string, 0, 100_000)
	for i := range 100_000 {
		files = append(files, fmt.Sprintf("packages/mod%d/src/components/widget_%d/index_%d.tsx", i%300, i%1000, i))
	}
	for _, q := range []string{"w", "widg", "compidx", "mod12widget"} {
		b.Run(q, func(b *testing.B) {
			for b.Loop() {
				Fuzzy(files, q, 60)
			}
		})
	}
}

// TestFuzzyRanksAsAFullSort checks the top-limit selection, in parallel
// parts, against scoring every file and sorting them all.
func TestFuzzyRanksAsAFullSort(t *testing.T) {
	files := make([]string, 0, 30_000)
	for i := range 30_000 {
		files = append(files, fmt.Sprintf("pkg%d/Src/widgetFoo_%d/Main%d.go", i%37, i%101, i%997))
	}
	for _, query := range []string{"m", "main", "wf", "pkg3main", "SRCmain9", "zzz"} {
		got := Fuzzy(files, query, 60)
		q := []rune(strings.ToLower(query))
		var all []Match
		for i, f := range files {
			pos := make([]int, len(q))
			if sc, ok := score(f, q, pos); ok {
				all = append(all, Match{Index: i, Score: sc, Positions: pos})
			}
		}
		slices.SortStableFunc(all, func(a, b Match) int {
			if a.Score != b.Score {
				return b.Score - a.Score
			}
			return len(files[a.Index]) - len(files[b.Index])
		})
		all = all[:min(len(all), 60)]
		if len(got) != len(all) {
			t.Fatalf("%q: %d results, want %d", query, len(got), len(all))
		}
		for i := range got {
			if got[i].Index != all[i].Index || !slices.Equal(got[i].Positions, all[i].Positions) {
				t.Fatalf("%q: result %d is %v, want %v", query, i, got[i], all[i])
			}
		}
	}
}
