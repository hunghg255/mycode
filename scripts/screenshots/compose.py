#!/usr/bin/env python3
"""Frame Mayoi's raw feature screenshots on gradient backdrops.

Usage: compose.py <raw dir> <framed dir>. Needs Pillow and macOS's fonts.
"""
import os, sys, re
from PIL import Image, ImageDraw, ImageFilter, ImageFont

if len(sys.argv) != 3:
    sys.exit("usage: compose.py <raw dir> <framed dir>")
RAW, OUT = sys.argv[1], sys.argv[2]
FONT = "/System/Library/Fonts/SFNS.ttf"

CAPTIONS = {
    "01-hero": ("Mayoi", "A small, fast code editor in Go — native GPU UI, no webview, no Electron"),
    "02-explorer": ("Explorer", "A live file tree with Git status letters and colors, and ignored files dimmed"),
    "03-reading-aids": ("Reading aids", "Indent guides, the caret's block brighter, and the word at the caret highlighted"),
    "03-selection": ("Selection", "Rounded selections that show their tabs and spaces"),
    "04-sticky-scroll": ("Sticky scroll & breadcrumbs", "The blocks around the caret stay pinned at the top, and the breadcrumbs name them"),
    "05-word-wrap": ("Word wrap", "Wrap long lines for every editor, or just one tab with ⌥Z"),
    "07-blame-gutter": ("Inline blame & gutter", "Who changed the line last, plus change marks in the gutter and the overview strip"),
    "07-change-peek": ("Peek a change", "Click a gutter mark to see the lines as they were at HEAD, then revert or stage them"),
    "08-scm-diff-inline": ("Source control", "Stage, commit and push, with every change in one diff tab"),
    "08-scm-diff-split": ("Side-by-side diff", "Removed and added lines across from each other, with changed words tinted"),
    "08-scm-hunk-actions": ("Stage a hunk", "Point at a run of changes to stage, unstage or discard just those lines"),
    "08-scm-tree": ("View as tree", "Changes grouped under their folders, with buttons for a whole folder"),
    "09-commits": ("Commit graph", "Branches, tags and merges on a graph, and each commit's changes in a tab"),
    "09-branch-picker": ("Switch branch", "Local and remote branches with their last commit; type a new name to create one"),
    "10-image-viewer": ("Image viewer", "PNG, JPEG, GIF, WebP and BMP, fitted on a checkerboard, with zoom and pan"),
    "10-svg-preview": ("Live SVG preview", "Edit an SVG on one side and watch it render on the other"),
    "11-markdown-preview": ("Markdown preview", "Headings, lists, task lists, tables, code and images, live beside the source"),
    "12-columns": ("Columns", "Split the editor side by side and drag tabs between columns"),
    "13-terminal-panel": ("Terminal", "Ghostty's emulator (libghostty-vt) in the bottom panel, in the theme's colors"),
    "13-terminal-tab": ("Terminal in a tab", "A terminal can sit in a column, right beside your code"),
    "14-quick-open": ("Quick open", "Fuzzy file search with ⌘P, recent files first"),
    "14-go-to-symbol": ("Go to symbol", "Type @ to list the file's functions, types and headings"),
    "14-command-palette": ("Command palette", "Run any command by name with ⇧⌘P, with its shortcut beside it"),
    "14-go-to-line": ("Go to line", "Type :120 to jump to a line"),
    "15-find-replace": ("Find & replace", "Match case, whole word and regex, with $1 groups in the replacement"),
    "16-search": ("Search in files", "⇧⌘F searches the folder as you type, with each match in context"),
    "16-replace-in-files": ("Replace in files", "Preview each replacement, filter files with include and exclude globs"),
    "17-project-tabs": ("Project tabs", "Every folder in one window, on a rail; a dot marks a project whose terminal rang"),
    "18-welcome": ("Welcome", "Start a project or reopen a recent folder"),
    "18-welcome-folder": ("Welcome", "A folder's start page, with the shortcuts that matter"),
    "18-open-recent": ("Open recent", "⌃R finds a recent folder by name; ⌘↵ opens it in a new window"),
    "21-theme-matrix-welcome": ("The Matrix", "Phosphor green on black, with digital rain behind the welcome page"),
    "21-theme-matrix-editor": ("The Matrix", "The whole window in the code's font"),
    "21-theme-claude-light-welcome": ("Claude · light", "Ivory and Claude's orange, with Clawd on the welcome page"),
    "21-theme-claude-light-editor": ("Claude · light", "Anthropic's ivory and warm near-black"),
    "21-theme-claude-dark-welcome": ("Claude · dark", "Clawd blinks now and then, and hops while Git runs"),
    "21-theme-claude-dark-editor": ("Claude · dark", "Warm near-black with Claude's orange"),
    "21-theme-qoder-light-welcome": ("Qoder · light", "Qoder's Forest theme, with Qoduck on the welcome page"),
    "21-theme-qoder-light-editor": ("Qoder · light", "Green-tinged greys and forest green"),
    "21-theme-qoder-dark-welcome": ("Qoder · dark", "Qoduck bobs and hops as Clawd does"),
    "21-theme-qoder-dark-editor": ("Qoder · dark", "Code in Forest's greens, blues, teals and ambers"),
    "22-settings-json": ("Settings", "settings.json applies as you save it, here with the sidebar on the right"),
    "22-keybindings-json": ("Keyboard shortcuts", "keybindings.json in VS Code's format, so you can paste in your own"),
}

# Backdrop gradients: (top-left, bottom-right).
DARK_BG = [((32, 20, 74), (96, 30, 92)), ((14, 34, 72), (60, 22, 96)), ((18, 46, 62), (34, 24, 80))]
LIGHT_BG = [((226, 220, 255), (255, 214, 232)), ((214, 232, 255), (236, 220, 255)), ((222, 246, 236), (214, 228, 255))]
THEME_BG = {
    "matrix": ((2, 20, 8), (6, 54, 22)),
    "claude-light": ((250, 232, 214), (238, 196, 170)),
    "claude-dark": ((64, 34, 22), (150, 74, 44)),
    "qoder-light": ((222, 240, 228), (196, 226, 206)),
    "qoder-dark": ((10, 44, 30), (32, 88, 60)),
}


def font(size, weight="Regular"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def gradient(w, h, c0, c1):
    # A diagonal gradient, with a soft light in the top left corner.
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126
            px[x, y] = tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))
    img = small.resize((w, h), Image.BICUBIC)
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse((-w * 0.25, -h * 0.55, w * 0.65, h * 0.55), fill=60)
    glow = glow.filter(ImageFilter.GaussianBlur(w // 10))
    return Image.composite(Image.new("RGB", (w, h), (255, 255, 255)), img, glow)


def rounded_mask(size, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), r, fill=255)
    return m


def compose(src, dst, title, caption, dark, bg):
    shot = Image.open(src).convert("RGB")
    sw, sh = shot.size
    pad_x, top, bottom = 220, 330, 200
    W, H = sw + pad_x * 2, sh + top + bottom
    canvas = gradient(W, H, *bg).convert("RGBA")

    r = 26
    # Shadow.
    sh_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh_layer).rounded_rectangle((pad_x, top + 30, pad_x + sw, top + sh + 30), r, fill=(0, 0, 0, 150 if dark else 80))
    sh_layer = sh_layer.filter(ImageFilter.GaussianBlur(50))
    canvas = Image.alpha_composite(canvas, sh_layer)
    # The window, rounded, with a hairline border.
    win = shot.convert("RGBA")
    win.putalpha(rounded_mask((sw, sh), r))
    canvas.alpha_composite(win, (pad_x, top))
    border = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle((pad_x - 1, top - 1, pad_x + sw, top + sh), r + 1,
                                             outline=(255, 255, 255, 60) if dark else (0, 0, 0, 40), width=2)
    canvas = Image.alpha_composite(canvas, border)

    lum = sum(bg[0]) / 3
    ink = (255, 255, 255) if lum < 140 else (28, 22, 48)
    sub = (255, 255, 255, 190) if lum < 140 else (40, 34, 70, 190)
    d = ImageDraw.Draw(canvas)
    tf, cf = font(96, "Bold"), font(46, "Regular")
    tw = d.textlength(title, font=tf)
    d.text(((W - tw) / 2, 92), title, font=tf, fill=ink)
    cw = d.textlength(caption, font=cf)
    d.text(((W - cw) / 2, 210), caption, font=cf, fill=sub)
    # A small wordmark at the bottom.
    mf = font(34, "Semibold")
    mark = "Mayoi"
    mw = d.textlength(mark, font=mf)
    x = (W - mw) / 2
    y = H - bottom / 2 - 10
    d.text((x, y), mark, font=mf, fill=sub)
    canvas.convert("RGB").save(dst, optimize=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    files = sorted(f for f in os.listdir(RAW) if f.endswith(".png"))
    done = []
    for i, f in enumerate(files):
        name = f[:-4]
        m = re.match(r"(.*)-(dark|light)$", name)
        key, mode = (m.group(1), m.group(2)) if m else (name, None)
        if key not in CAPTIONS:
            key = name
        title, caption = CAPTIONS[key]
        theme = re.match(r"21-theme-(matrix|claude-light|claude-dark|qoder-light|qoder-dark)", name)
        if theme:
            bg = THEME_BG[theme.group(1)]
            dark = "light" not in theme.group(1)
        else:
            dark = mode != "light"
            pal = DARK_BG if dark else LIGHT_BG
            bg = pal[int(name[:2]) % len(pal)]
        compose(os.path.join(RAW, f), os.path.join(OUT, f), title, caption, dark, bg)
        done.append((f, title, caption, dark))
        print("framed", f)
    return done


if __name__ == "__main__":
    main()
