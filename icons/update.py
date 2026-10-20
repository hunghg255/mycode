"""Writes material.zig, which embeds the Material Icon Theme's icons in
icons/material (made by scripts/materialicons/update.sh): run it again after
updating them.

    python icons/update.py
"""
import os

here = os.path.dirname(os.path.abspath(__file__))
names = [f[:-4] for f in sorted(os.listdir(os.path.join(here, 'material'))) if f.endswith('.svg')]
# By the bare name, as the binary search in icons.zig compares them.
names.sort(key=lambda n: n.encode())

with open(os.path.join(here, 'material.zig'), 'w', newline='\n') as out:
    out.write('//! The Material Icon Theme\'s icons (MIT license, material/LICENSE), and its\n')
    out.write('//! manifest. Made by update.py: do not edit.\n\n')
    out.write('pub const manifest = @embedFile("material/manifest.json");\n\n')
    out.write('/// Sorted, for a binary search.\n')
    out.write('pub const names = [_][]const u8{\n')
    for n in names:
        out.write(f'    "{n}",\n')
    out.write('};\n\n')
    out.write('pub const svgs = [_][]const u8{\n')
    for n in names:
        out.write(f'    @embedFile("material/{n}.svg"),\n')
    out.write('};\n')
print(f'{len(names)} icons')
