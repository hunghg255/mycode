package main

import (
	"io/fs"
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"
)

// Every icon of the Material Icon Theme parses.
func TestMaterialIconsParse(t *testing.T) {
	names, err := fs.Glob(materialFS, "materialicons/*.svg")
	if err != nil || len(names) < 1000 {
		t.Fatalf("%d icons, %v", len(names), err)
	}
	for _, n := range names {
		data, _ := materialFS.ReadFile(n)
		if _, err := ui.ParseSVG(data); err != nil {
			t.Errorf("%s: %v", n, err)
		}
	}
	// Every name of the manifest has its icon.
	m := materialManifestData()
	for _, maps := range []materialMaps{m.materialMaps, m.Light} {
		for _, mp := range []map[string]string{maps.FileExtensions, maps.FileNames, maps.FolderNames, maps.FolderNamesExpanded} {
			for k, v := range mp {
				if _, err := materialFS.Open("materialicons/" + v + ".svg"); err != nil {
					t.Errorf("%s: no icon %s", k, v)
				}
			}
		}
	}
}

func TestMaterialIconNames(t *testing.T) {
	for _, tc := range []struct{ name, icon string }{
		{"main.go", "go"},
		{"go.mod", "go-mod"},
		{"App.tsx", "react_ts"},
		{"index.d.ts", "typescript-def"},
		{"package.json", "nodejs"},
		{"README.md", "readme"},
		{"Dockerfile", "docker"},
		{"what.unknownext", "file"},
	} {
		if got := materialFileName(tc.name, true); got != tc.icon {
			t.Errorf("%s: %s, want %s", tc.name, got, tc.icon)
		}
	}
	if !strings.HasSuffix(materialFileName("toml.toml", false), "_light") {
		t.Error("a TOML file in a light window has not the light icon")
	}
	if materialFolderIcon("src", true, true) != materialSVG("folder-src-open") {
		t.Error("an open src folder has not its icon")
	}
	if materialFolderIcon("whatever", false, true) != materialSVG("folder") {
		t.Error("a folder has not the folder icon")
	}
}

// The iconTheme setting chooses Lucide's icons or the Material ones.
func TestIconThemeSetting(t *testing.T) {
	hs := newHarness(t, true)
	a := hs.a
	defer applyIconTheme("")
	if icon, _ := fileIcon(a.pal, "main.go"); !isMaterial(icon) {
		t.Fatal("the icons are not Material ones by default")
	}
	a.setIconTheme(iconThemeLucide)
	hs.settle()
	if a.settings.IconTheme != iconThemeLucide || !a.commandOn("view.iconTheme.lucide") || a.commandOn("view.iconTheme.material") {
		t.Errorf("the setting is %q", a.settings.IconTheme)
	}
	if icon, _ := fileIcon(a.pal, "main.go"); isMaterial(icon) {
		t.Error("a file has a Material icon with Lucide's chosen")
	}
	if icon, _ := folderIcon(a.pal, "src", false); icon != iconFolder {
		t.Error("a folder has not Lucide's icon")
	}
	a.setIconTheme("")
	hs.settle()
	if icon, _ := folderIcon(a.pal, "src", false); !isMaterial(icon) {
		t.Error("a folder has not the Material icon again")
	}
}
