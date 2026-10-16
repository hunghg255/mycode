package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A first start under the new name takes the old name's settings; one
// with settings of its own keeps them.
func TestMigrateData(t *testing.T) {
	base := t.TempDir()
	old, dir := filepath.Join(base, oldAppName), filepath.Join(base, appName)
	os.MkdirAll(old, 0o755)
	os.WriteFile(filepath.Join(old, "settings.json"), []byte(`{"fontSize": 15}`), 0o644)
	os.WriteFile(filepath.Join(old, "state.json"), []byte(`{}`), 0o644)
	os.WriteFile(filepath.Join(old, "crash.log"), []byte("x"), 0o644)
	migrateData(dir)
	if b, _ := os.ReadFile(filepath.Join(dir, "settings.json")); string(b) != `{"fontSize": 15}` {
		t.Errorf("settings %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "state.json")); err != nil {
		t.Error("the state did not move")
	}
	if _, err := os.Stat(filepath.Join(dir, "crash.log")); err == nil {
		t.Error("the crash log moved")
	}
	os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"fontSize": 20}`), 0o644)
	os.WriteFile(filepath.Join(old, "settings.json"), []byte(`{"fontSize": 9}`), 0o644)
	migrateData(dir)
	if b, _ := os.ReadFile(filepath.Join(dir, "settings.json")); string(b) != `{"fontSize": 20}` {
		t.Errorf("settings of its own were replaced: %q", b)
	}
	// Without the old folder, nothing happens.
	migrateData(filepath.Join(t.TempDir(), appName))
}
