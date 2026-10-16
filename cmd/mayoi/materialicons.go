package main

import (
	"embed"
	"encoding/json"
	"strings"
	"sync"

	"github.com/egoist/mygo/ui"
)

// The icons of files and folders from the Material Icon Theme (MIT
// license, see materialicons/LICENSE), with the manifest that maps names
// and extensions to them as the theme does in VS Code. Regenerate both
// with scripts/materialicons/update.sh.
//
//go:embed materialicons/*.svg materialicons/manifest.json
var materialFS embed.FS

type materialMaps struct {
	FileExtensions      map[string]string `json:"fileExtensions"`
	FileNames           map[string]string `json:"fileNames"`
	FolderNames         map[string]string `json:"folderNames"`
	FolderNamesExpanded map[string]string `json:"folderNamesExpanded"`
}

type materialManifest struct {
	materialMaps
	File           string       `json:"file"`
	Folder         string       `json:"folder"`
	FolderExpanded string       `json:"folderExpanded"`
	Light          materialMaps `json:"light"`
}

var (
	materialOnce  sync.Once
	materialMan   materialManifest
	materialMu    sync.Mutex
	materialCache = map[string]*ui.SVG{}
	materialSet   = map[*ui.SVG]bool{}
)

// isMaterial tells an icon of the Material Icon Theme, which draws in its
// own colors, from one drawn in the color of the text.
func isMaterial(s *ui.SVG) bool {
	materialMu.Lock()
	defer materialMu.Unlock()
	return materialSet[s]
}

// fileIconEl shows the icon of a file or a folder size high: a Material
// one in its own colors, another in col.
func fileIconEl(c *ui.Context, s *ui.SVG, col ui.Color, size float32) ui.Element {
	if isMaterial(s) {
		return ui.Image(c, s).Size(size, size).Fit(ui.Contain)
	}
	return ui.Icon(c, s).FontSize(size).TextColor(col)
}

// paintFileIcon paints the icon of a file in r, as fileIconEl shows it.
func paintFileIcon(pt *ui.Painter, s *ui.SVG, r ui.Rect, col ui.Color) {
	if isMaterial(s) {
		pt.Image(s, r, ui.Contain)
		return
	}
	pt.Icon(s, r, col)
}

func materialManifestData() *materialManifest {
	materialOnce.Do(func() {
		data, err := materialFS.ReadFile("materialicons/manifest.json")
		if err == nil {
			err = json.Unmarshal(data, &materialMan)
		}
		if err != nil {
			panic("material icons: " + err.Error())
		}
	})
	return &materialMan
}

// materialSVG is the icon of that name, parsed the first time it is asked
// for. Nil if it is not there or does not parse.
func materialSVG(name string) *ui.SVG {
	materialMu.Lock()
	defer materialMu.Unlock()
	if s, ok := materialCache[name]; ok {
		return s
	}
	var s *ui.SVG
	if data, err := materialFS.ReadFile("materialicons/" + name + ".svg"); err == nil {
		s, _ = ui.ParseSVG(data)
	}
	materialCache[name] = s
	if s != nil {
		materialSet[s] = true
	}
	return s
}

// lookup finds key in the light map in a light window, then in the dark one.
func materialLookup(dark bool, light, base map[string]string, key string) (string, bool) {
	if !dark {
		if v, ok := light[key]; ok {
			return v, true
		}
	}
	v, ok := base[key]
	return v, ok
}

// materialFileName is the name of the icon of a file: by its whole name
// first, then by its longest extension (".d.ts" before ".ts").
func materialFileName(name string, dark bool) string {
	m := materialManifestData()
	lower := strings.ToLower(name)
	if v, ok := materialLookup(dark, m.Light.FileNames, m.FileNames, lower); ok {
		return v
	}
	for i := 0; i < len(lower); i++ {
		if lower[i] != '.' {
			continue
		}
		if v, ok := materialLookup(dark, m.Light.FileExtensions, m.FileExtensions, lower[i+1:]); ok {
			return v
		}
	}
	return m.File
}

// materialFileIcon is the icon of a file by its name.
func materialFileIcon(name string, dark bool) *ui.SVG {
	if s := materialSVG(materialFileName(name, dark)); s != nil {
		return s
	}
	return materialSVG(materialManifestData().File)
}

// materialFolderIcon is the icon of a folder by its name, open or closed.
func materialFolderIcon(name string, open, dark bool) *ui.SVG {
	m := materialManifestData()
	lower := strings.ToLower(name)
	icon, def := m.Folder, m.Folder
	light, base := m.Light.FolderNames, m.FolderNames
	if open {
		icon, def = m.FolderExpanded, m.FolderExpanded
		light, base = m.Light.FolderNamesExpanded, m.FolderNamesExpanded
	}
	if v, ok := materialLookup(dark, light, base, lower); ok {
		icon = v
	}
	if s := materialSVG(icon); s != nil {
		return s
	}
	return materialSVG(def)
}
