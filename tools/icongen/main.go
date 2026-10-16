// Command icongen scales Mayoi's app icon art, cmd/mayoi/icon-art.png,
// to 1024 px and writes resources/icon.png:
//
//	go run ./tools/icongen
package main

import (
	"image/png"
	"log"
	"os"

	"github.com/egoist/mygo/ui"
)

func main() {
	f, err := os.Open("cmd/mayoi/icon-art.png")
	if err != nil {
		log.Fatal(err)
	}
	art, err := png.Decode(f)
	f.Close()
	if err != nil {
		log.Fatal(err)
	}
	bitmap := ui.NewBitmap(art)
	view := func(c *ui.Context) {
		c.Root().Background(ui.Transparent)
		ui.Image(c, bitmap).Size(1024, 1024)
	}
	img := ui.Render(view, 1024, 1024, 1)
	out, err := os.Create("resources/icon.png")
	if err != nil {
		log.Fatal(err)
	}
	defer out.Close()
	// An *image.RGBA encodes as an 8-bit PNG.
	if err := png.Encode(out, img); err != nil {
		log.Fatal(err)
	}
}
