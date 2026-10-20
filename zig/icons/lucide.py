"""Writes lucide.zig: the Go app's Lucide icons (cmd/mayoi/icons.go), drawn
in the text's color, and the names the Zig app calls them by.

    python icons/lucide.py
"""
import os
import re

here = os.path.dirname(os.path.abspath(__file__))
go = open(os.path.join(here, '..', '..', 'cmd', 'mayoi', 'icons.go'), encoding='utf-8').read()
icons = re.findall(r'\n\ticon(\w+)\s*=\s*lucide\(`(.*?)`\)', go)

# The names the app's code uses (myzig's, after SF Symbols) for the Go
# app's icons.
names = {
    'xmark': 'X', 'plus': 'Plus', 'minus': 'Minus',
    'chevron.down': 'ChevronDown', 'chevron.up': 'ChevronUp', 'chevron.left': 'ChevronLeft', 'chevron.right': 'ChevronRight',
    'folder': 'Folder', 'folder.open': 'FolderOpen', 'doc': 'File', 'doc.text': 'OpenFile', 'doc.on.doc': 'Files',
    'plus.square': 'FilePlus', 'folder.badge.plus': 'FolderPlus', 'photo': 'Image',
    'terminal': 'Terminal', 'trash': 'Trash', 'magnifyingglass': 'Search', 'arrow.up': 'ArrowUp', 'arrow.down': 'ArrowDown',
    'arrow.triangle.branch': 'Branch', 'globe': 'Branch', 'arrow.clockwise': 'Refresh', 'arrow.uturn.backward': 'Undo',
    'rectangle.on.rectangle': 'Collapse', 'pencil': 'Pencil', 'checkmark': 'Check', 'hand.raised': 'Lock', 'lock': 'Lock',
    'wrench.and.screwdriver': 'Gear', 'gear': 'Gear', 'arrow.up.right': 'ToEditor',
    'arrow.up.left.and.arrow.down.right': 'Maximize', 'arrow.down.right.and.arrow.up.left': 'Minimize',
    'cube': 'Box', 'textformat': 'Type', 'chevron.left.forwardslash.chevron.right': 'Function', 'circle': 'Hash',
    'clock': 'Clock', 'tag': 'Tag', 'ellipsis': 'More', 'square.and.arrow.up': 'Push', 'square.and.arrow.down': 'Pull',
    'icloud.and.arrow.down': 'Fetch', 'text.bubble': 'Comment', 'paperplane': 'Send', 'sidebar.left': 'Sidebar',
    'sidebar.right': 'SidebarRight', 'rectangle.bottomthird.inset.filled': 'Panel', 'wrap': 'Wrap', 'diff': 'Diff',
    'columns': 'Columns', 'rows': 'Rows', 'keyboard': 'Keyboard', 'commit': 'Commit', 'unfold': 'Unfold',
}
have = {n for n, _ in icons}
for k, v in names.items():
    assert v in have, (k, v)

def snake(n):
    return re.sub(r'(?<!^)([A-Z])', r'_\1', n).lower()

out = ['//! The Go app\'s icons, from Lucide (ISC license): cmd/mayoi/icons.go, written',
       '//! here by `icons/lucide.py`. Drawn in the color given, as the text\'s.',
       'pub const Icon = enum {']
out += ['    %s,' % snake(n) for n, _ in icons]
out += ['};', '', '/// An icon\'s SVG document.', 'pub fn svg(i: Icon) []const u8 {', '    return switch (i) {']
head = '<svg xmlns=\\"http://www.w3.org/2000/svg\\" width=\\"24\\" height=\\"24\\" viewBox=\\"0 0 24 24\\" fill=\\"none\\" stroke=\\"currentColor\\" stroke-width=\\"2\\" stroke-linecap=\\"round\\" stroke-linejoin=\\"round\\">'
for n, body in icons:
    out.append('        .%s => "%s%s</svg>",' % (snake(n), head, body.replace('"', '\\"')))
out += ['    };', '}', '', '/// The icon of a name the app calls it by (myzig\'s), or null.',
        'pub fn named(name: []const u8) ?Icon {', '    const map = [_]struct { []const u8, Icon }{']
for k, v in names.items():
    out.append('        .{ "%s", .%s },' % (k, snake(v)))
out += ['    };', '    for (map) |e| if (@import("std").mem.eql(u8, e[0], name)) return e[1];', "    // Else the Go app's own name, as `replace_all`.", '    return @import("std").meta.stringToEnum(Icon, name);', '}', '']
open(os.path.join(here, '..', 'src', 'lucide.zig'), 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
print(len(icons), 'icons')
