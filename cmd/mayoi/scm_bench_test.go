package main

import (
	"fmt"
	"os"
	"testing"
)

// benchScm has n files changed, the source control view shown and the
// diff of every file open, for the cost of a frame of them:
// go test -short -run XXX -bench Scm
func benchScm(b *testing.B, n int) *harness {
	hs := newHarness(b, true)
	git := hs.gitRepo()
	os.MkdirAll(hs.path("many"), 0o755)
	for i := range n {
		os.WriteFile(hs.path(fmt.Sprintf("many/f%04d.go", i)), []byte("package many\n\nfunc f() {\n\tprintln(1)\n}\n"), 0o644)
	}
	git("add", ".")
	git("commit", "-qm", "many")
	for i := range n {
		os.WriteFile(hs.path(fmt.Sprintf("many/f%04d.go", i)), []byte(fmt.Sprintf("package many\n\nfunc f() {\n\tprintln(%d)\n}\n", i)), 0o644)
	}
	hs.a.run("view.scm")
	hs.settleGit()
	hs.a.openChangesTab(false)
	hs.settleGit()
	return hs
}

func BenchmarkScmIdleFrame(b *testing.B) {
	hs := benchScm(b, 2000)
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		hs.tt.Frame()
	}
}

func BenchmarkScmScrollFrame(b *testing.B) {
	hs := benchScm(b, 2000)
	b.ReportAllocs()
	b.ResetTimer()
	for i := range b.N {
		dy := float32(60)
		if i/200%2 == 1 {
			dy = -60
		}
		hs.tt.Scroll(700, 400, 0, dy)
		hs.tt.Frame()
	}
}

// BenchmarkScmStatusFrame reads the status again, as every few seconds,
// though nothing changed.
func BenchmarkScmStatusFrame(b *testing.B) {
	hs := benchScm(b, 2000)
	st := *hs.a.git.status
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		cp := st
		hs.a.setStatus(&cp)
		hs.tt.Frame()
	}
}
