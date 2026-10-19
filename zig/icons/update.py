"""Copies the Material Icon Theme's icons from the Go app
(cmd/mayoi/materialicons, made by scripts/materialicons/update.sh) and
writes material.zig, which embeds them: run it again after updating them.

    python zig/icons/update.py
"""
import os
import shutil

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, '..', '..', 'cmd', 'mayoi', 'materialicons')
dst = os.path.join(here, 'material')
if os.path.isdir(dst):
    shutil.rmtree(dst)
os.makedirs(dst)
names = []
for f in sorted(os.listdir(src)):
    if f.endswith('.svg') or f in ('manifest.json', 'LICENSE'):
        shutil.copy(os.path.join(src, f), os.path.join(dst, f))
    if f.endswith('.svg'):
        names.append(f[:-4])
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
