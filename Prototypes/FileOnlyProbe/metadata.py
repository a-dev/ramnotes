#!/usr/bin/env python3
"""Seed or inspect only a disposable probe fixture; never authorize the probe app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('operation', choices=['seed', 'inspect'])
parser.add_argument('directory', type=Path)
args = parser.parse_args()
root = args.directory
if not root.name.startswith('ramnotes-file-only-'):
    parser.error('Use a disposable ramnotes-file-only-* directory.')
file = root / 'probe-target.txt'
if args.operation == 'seed':
    root.mkdir(parents=True, exist_ok=False)
    file.write_bytes(b'\xef\xbb\xbfdisposable fixture\r\n')
    (root / 'sibling-sentinel.txt').write_text('Unrelated disposable sibling.\n')
    file.chmod(0o640)
    subprocess.run(['xattr', '-wx', 'dev.ramnotes.probe', b'preserve this attribute'.hex(), str(file)], check=True)
    subprocess.run(['xattr', '-wx', 'com.apple.metadata:_kMDItemUserTags', plistlib.dumps(['RAMnotesProbe-' + root.name + '\n2'], fmt=plistlib.FMT_BINARY).hex(), str(file)], check=True)
    subprocess.run(['chmod', '+a', 'everyone allow read,readattr,readextattr,readsecurity', str(file)], check=True)
stat = file.stat()
metadata = {'mode': oct(stat.st_mode & 0o7777), 'uid': stat.st_uid, 'gid': stat.st_gid,
            'acl': subprocess.check_output(['ls', '-len', str(file)], text=True).splitlines()[1:],
            'xattrs': {name: subprocess.check_output(['xattr', '-px', name, str(file)], text=True).replace(' ', '').replace('\n', '')
                       for name in ['dev.ramnotes.probe', 'com.apple.metadata:_kMDItemUserTags']
                       if name in subprocess.check_output(['xattr', str(file)], text=True).splitlines()}}
print(json.dumps({'metadata': metadata, 'bytes': file.stat().st_size,
                  'sha256': hashlib.sha256(file.read_bytes()).hexdigest()}, indent=2))
