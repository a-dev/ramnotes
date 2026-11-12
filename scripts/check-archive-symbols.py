#!/usr/bin/env python3
"""Require matching archived crash symbols for every application executable."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

archive = Path(sys.argv[1])

def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    return set(re.findall(r'UUID: ([0-9A-F-]+) \(([^)]+)\)', output))

for app in sorted((archive / 'Products/Applications').rglob('*.app')):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = info['CFBundleExecutable']
    binary = app / 'Contents/MacOS' / executable
    symbols = archive / 'dSYMs' / (app.name + '.dSYM') / 'Contents/Resources/DWARF' / executable
    if not symbols.is_file():
        sys.exit(f'Missing archived symbols: {symbols}')
    expected = uuids(binary)
    if not expected or expected != uuids(symbols):
        sys.exit(f'Symbol UUID mismatch: {app.name}')
    print(f'Matching symbols: {app.name}')
