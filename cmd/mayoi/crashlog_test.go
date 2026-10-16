package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"testing"
	"time"
)

func TestKeepCrashes(t *testing.T) {
	defer debug.SetCrashOutput(nil, debug.CrashOptions{})
	dir := t.TempDir()
	crashes := filepath.Join(dir, "crashes")
	os.MkdirAll(crashes, 0o755)
	for i := range maxCrashes {
		os.WriteFile(filepath.Join(crashes, fmt.Sprintf("2020-01-%02d-000000.log", i+1)), []byte("old"), 0o644)
	}
	path := filepath.Join(dir, "crash.log")
	os.WriteFile(path, []byte("panic: boom"), 0o644)
	when := time.Date(2026, 10, 14, 9, 30, 5, 0, time.Local)
	os.Chtimes(path, when, when)

	keepCrashes(dir)

	if b, err := os.ReadFile(filepath.Join(crashes, "2026-10-14-093005.log")); string(b) != "panic: boom" {
		t.Fatalf("moved crash = %q, %v", b, err)
	}
	if _, err := os.Stat(filepath.Join(crashes, "2020-01-01-000000.log")); !os.IsNotExist(err) {
		t.Errorf("oldest crash kept: %v", err)
	}
	if entries, _ := os.ReadDir(crashes); len(entries) != maxCrashes {
		t.Errorf("%d crashes kept, want %d", len(entries), maxCrashes)
	}
	if fi, err := os.Stat(path); err != nil || fi.Size() != 0 {
		t.Errorf("crash.log after launch: %v, %v", fi, err)
	}

	// An empty crash.log, from a launch that did not crash, stays put.
	keepCrashes(dir)
	if entries, _ := os.ReadDir(crashes); len(entries) != maxCrashes {
		t.Errorf("empty crash.log moved: %d crashes", len(entries))
	}
}
