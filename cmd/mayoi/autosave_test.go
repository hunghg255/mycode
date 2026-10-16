package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestAutoSaveAfterAPause(t *testing.T) {
	hs := newHarness(t, false)
	a, tt := hs.a, hs.tt
	a.openFile(hs.path("README.md"), true)
	hs.settle()
	tt.Type("Hello ")
	tt.Frame()
	d := a.activeEditor()
	if !d.dirty() {
		t.Fatal("not changed")
	}
	time.Sleep(autoSaveDelay + 200*time.Millisecond)
	hs.settle()
	data, _ := os.ReadFile(hs.path("README.md"))
	if !strings.HasPrefix(string(data), "Hello # Mayoi") || d.dirty() {
		t.Fatalf("after the pause: saved %q, dirty %v", data, d.dirty())
	}
}

func TestAutoSaveAsTheTabChanges(t *testing.T) {
	hs := newHarness(t, false)
	a, tt := hs.a, hs.tt
	a.openFile(hs.path("README.md"), true)
	hs.settle()
	tt.Type("Hello ")
	tt.Frame()
	readme := a.activeEditor().document
	a.openFile(hs.path("go.mod"), true)
	tt.Frame()
	tt.Frame()
	data, _ := os.ReadFile(hs.path("README.md"))
	if !strings.HasPrefix(string(data), "Hello # Mayoi") || readme.dirty() {
		t.Fatalf("after showing another tab: saved %q, dirty %v", data, readme.dirty())
	}
}

func TestAutoSaveClosesWithoutAsking(t *testing.T) {
	hs := newHarness(t, false)
	a, tt := hs.a, hs.tt
	a.openFile(hs.path("README.md"), true)
	hs.settle()
	tt.Type("Hello ")
	tt.Frame()
	a.run("file.close")
	hs.settle()
	data, _ := os.ReadFile(hs.path("README.md"))
	if len(a.docs) != 0 || len(hs.h.asked) != 0 || !strings.HasPrefix(string(data), "Hello # Mayoi") {
		t.Fatalf("%d docs, asked %v, saved %q", len(a.docs), hs.h.asked, data)
	}
}

func TestAutoSaveLeavesUntitledAndTurnsOff(t *testing.T) {
	hs := newHarness(t, false)
	a, tt := hs.a, hs.tt
	a.run("file.new")
	hs.settle()
	tt.Type("draft")
	tt.Frame()
	untitled := a.activeEditor().document
	a.openFile(hs.path("README.md"), true)
	hs.settle()
	a.run("file.autoSave")
	if a.settings.AutoSave {
		t.Fatal("still on")
	}
	tt.Type("Hello ")
	tt.Frame()
	readme := a.activeEditor().document
	a.openFile(hs.path("go.mod"), true)
	time.Sleep(autoSaveDelay + 200*time.Millisecond)
	hs.settle()
	if len(hs.h.asked) != 0 || !untitled.dirty() {
		t.Fatalf("untitled: asked %v, dirty %v", hs.h.asked, untitled.dirty())
	}
	if !readme.dirty() {
		t.Fatal("saved while off")
	}
	// Turning it on saves what changed meanwhile.
	a.run("file.autoSave")
	if readme.dirty() || !untitled.dirty() {
		t.Fatalf("on again: readme dirty %v, untitled dirty %v", readme.dirty(), untitled.dirty())
	}
}

func TestAutoSaveFailureSaysOnce(t *testing.T) {
	hs := newHarness(t, false)
	a, tt := hs.a, hs.tt
	a.openFile(hs.path("README.md"), true)
	hs.settle()
	tt.Type("Hello ")
	tt.Frame()
	d := a.activeEditor().document
	os.Chmod(hs.path("README.md"), 0o444)
	os.Chmod(hs.root, 0o555)
	t.Cleanup(func() { os.Chmod(hs.root, 0o755) })
	a.errors = nil
	a.autoSaveDoc(d)
	a.autoSaveDoc(d)
	if len(a.errors) != 1 || !d.dirty() {
		t.Fatalf("errors %q, dirty %v", a.errors, d.dirty())
	}
	os.Chmod(hs.root, 0o755)
	os.Chmod(hs.path("README.md"), 0o644)
	a.autoSaveDoc(d)
	if d.dirty() || d.autoSave.failed {
		t.Fatalf("after the fix: dirty %v, failed %v", d.dirty(), d.autoSave.failed)
	}
}
