package workspace

import "testing"

func TestGlobs(t *testing.T) {
	cases := []struct {
		globs string
		rel   string
		want  bool
	}{
		{"", "main.go", false},
		{"*.go", "main.go", true},
		{"*.go", "internal/a/a.go", true},
		{"*.go", "web/index.html", false},
		{"*.{ts,tsx}", "src/app.tsx", true},
		{"*.{ts,tsx}", "src/app.js", false},
		{"node_modules", "node_modules/x/x.js", true},
		{"node_modules", "web/node_modules/y.js", true},
		{"internal/**", "internal/a/a.go", true},
		{"internal/**", "cmd/internal.go", false},
		{"internal", "internal/a/a.go", true},
		{"/main.go", "main.go", true},
		{"/main.go", "cmd/main.go", false},
		{"web/*.css", "web/style.css", true},
		{"web/*.css", "web/sub/style.css", false},
		{"**/a/*.go", "internal/a/a.go", true},
		{"*.md, *.css", "web/style.css", true},
		{" *.md ,", "README.md", true},
		{"./web/", "web/index.html", true},
		{"internal/**/*.go", "internal/a/a.go", true},
		{"internal/**/*.go", "internal/x.go", true},
		{"{internal,web}/**", "web/style.css", true},
		{"{internal,web}/**", "cmd/x.go", false},
	}
	for _, tc := range cases {
		if got := ParseGlobs(tc.globs).Match(tc.rel); got != tc.want {
			t.Errorf("ParseGlobs(%q).Match(%q) = %v, want %v", tc.globs, tc.rel, got, tc.want)
		}
	}
}
