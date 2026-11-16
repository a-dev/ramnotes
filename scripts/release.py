#!/usr/bin/env python3
"""Local Developer ID release pipeline for the direct channel. No publishing capability.

All subprocesses use argument vectors. Dry run performs only local reads and
prints the plan; it neither accesses Keychain nor creates output directories.
The Sparkle private key stays in the login Keychain; only its account name is used.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'RAMnotes.xcodeproj'
FEED_URL = 'https://a-dev.github.io/ramnotes/appcast.xml'
PUBLIC_KEY = 'PTnXhFSvIhMUagqM5mA3++Aemj0iLDfLFN77xty6RL8='
DOWNLOAD_URL_ROOT = 'https://github.com/a-dev/ramnotes/releases/download'
KEY_ACCOUNT = 'com.ramnotes.RAMnotes'
BUNDLE_ID = 'com.ramnotes.RAMnotes'
MINIMUM_SYSTEM = '27.0'
SPARKLE_VERSION = '2.10.0'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
_CONFIG_SPEC = importlib.util.spec_from_file_location('direct_update_config', ROOT / 'scripts/validate-direct-update-config.py')
_UPDATE_CONFIG = importlib.util.module_from_spec(_CONFIG_SPEC)
_CONFIG_SPEC.loader.exec_module(_UPDATE_CONFIG)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args):
    args = list(map(str, args))
    print('+ ' + shlex.join(args), flush=True)
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def versions(pbxproj):
    text = pbxproj.read_text()
    values = {}
    for key in ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'):
        found = set(re.findall(r'^\s*' + key + r'\s*=\s*"?([^";\s]+)"?;', text, re.M))
        require(len(found) == 1, f'{pbxproj.name}: every target needs the same {key}, found {sorted(found)}')
        values[key] = found.pop()
    require(re.fullmatch(r'\d+\.\d+\.\d+', values['MARKETING_VERSION']), 'marketing version must be X.Y.Z')
    require(re.fullmatch(r'[1-9]\d*', values['CURRENT_PROJECT_VERSION']), 'build must be a positive integer')
    return values['MARKETING_VERSION'], values['CURRENT_PROJECT_VERSION']


def history(path, build):
    data = json.loads(path.read_text())
    require(isinstance(data, dict) and isinstance(data.get('published_builds'), list), 'history requires published_builds array (explicit [] for first release)')
    builds = data['published_builds']
    require(all(type(n) is int and n > 0 for n in builds), 'history builds must be positive integers')
    require(len(builds) == len(set(builds)), 'history has duplicate builds')
    require(int(build) > max(builds, default=0), 'build must exceed every published build')


def https(url):
    p = urlsplit(url)
    require(p.scheme == 'https' and p.hostname and not p.username and not p.password and not p.query and not p.fragment and not any(c.isspace() for c in url), 'release URLs must be absolute HTTPS without credentials/query/fragment')


def tree_manifest(app):
    result = {}
    for p in sorted(app.rglob('*')):
        rel = str(p.relative_to(app))
        mode = stat.S_IMODE(p.lstat().st_mode)
        if p.is_symlink():
            require(p.resolve().is_relative_to(app.resolve()) and p.exists(), f'escaping or dangling symlink: {rel}')
            result[rel] = ('link', os.readlink(p))
        elif p.is_file():
            require(not mode & 0o022, f'group/world writable bundle entry: {rel}')
            result[rel] = ('file', mode, hashlib.sha256(p.read_bytes()).hexdigest())
        else:
            result[rel] = ('dir', mode)
    return result


def verify_app(app, version, build, feed, key):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = dict(CFBundleShortVersionString=version, CFBundleVersion=build,
                    LSMinimumSystemVersion=MINIMUM_SYSTEM, CFBundleIdentifier=BUNDLE_ID,
                    SUFeedURL=feed, SUPublicEDKey=key)
    for name, value in expected.items():
        require(info.get(name) == value, f'wrong app {name}: expected {value}, found {info.get(name)}')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    require(os.access(executable, os.X_OK), 'app executable lost execute permission')
    signed = subprocess.run(['codesign', '-d', '--verbose=4', str(app)], capture_output=True, text=True, check=True)
    details = signed.stdout + signed.stderr
    require('runtime' in details and 'Timestamp=' in details and 'Authority=Developer ID Application:' in details, 'app needs timestamped Developer ID and Hardened Runtime')
    run(['codesign', '--verify', '--deep', '--strict', app])
    run([sys.executable, ROOT / 'scripts/inspect-update-bundle.py', 'release', app])
    tree_manifest(app)


def verify_feed(path, archive, version, build, prefix):
    root = ET.parse(path).getroot()
    items = root.findall('./channel/item')
    require(len(items) == 1, 'candidate feed must contain exactly one item')
    item = items[0]
    enclosure = item.find('enclosure')
    require(enclosure is not None, 'feed missing enclosure')
    def value(name):
        return enclosure.get(f'{{{SPARKLE}}}{name}') or item.findtext(f'{{{SPARKLE}}}{name}')
    require(value('version') == build and value('shortVersionString') == version, 'feed version mismatch')
    require(item.findtext(f'{{{SPARKLE}}}minimumSystemVersion') == MINIMUM_SYSTEM, 'feed minimum OS mismatch')
    require(enclosure.get('url') == prefix.rstrip('/') + '/' + archive.name, 'feed download URL mismatch')
    require(enclosure.get('length') == str(archive.stat().st_size), 'feed archive length mismatch')
    signature = enclosure.get(f'{{{SPARKLE}}}edSignature', '')
    require(len(base64.b64decode(signature, validate=True)) == 64, 'missing EdDSA signature')
    require(item.find('description') is not None or item.find(f'{{{SPARKLE}}}releaseNotesLink') is not None, 'feed missing release notes')
    return signature


def prerequisites(a, build):
    history(a.history, build)
    https(a.feed_url)
    _UPDATE_CONFIG.validate('Release', a.feed_url, a.public_key, 'NO')
    https(a.download_url_prefix)
    require(a.notes.is_file() and a.notes.stat().st_size > 0, 'nonempty HTML release notes required')
    require(not a.output.exists(), 'output must not exist; use a fresh candidate directory')
    pins = json.loads((PROJECT / 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
    sparkle_pins = [p for p in pins if p.get('identity') == 'sparkle']
    require(len(sparkle_pins) == 1 and sparkle_pins[0]['state']['version'] == SPARKLE_VERSION, f'review pipeline before changing the Sparkle {SPARKLE_VERSION} pin')
    plists = list(a.sparkle_bin.parent.glob('Sparkle.xcframework/**/Resources/Info.plist'))
    require(any(plistlib.loads(p.read_bytes()).get('CFBundleShortVersionString') == SPARKLE_VERSION for p in plists), f'Sparkle tools must be version {SPARKLE_VERSION}; build once or pass --sparkle-bin')
    for name in ('sign_update', 'generate_appcast'):
        require(os.access(a.sparkle_bin / name, os.X_OK), f'missing Sparkle {name}')
    require(a.identity.startswith('Developer ID Application:'), 'Developer ID Application identity required')
    require(re.fullmatch(r'[A-Z0-9]{10}', a.team), 'team must be a 10-character Apple Team ID')
    require(bool(a.notary_profile.strip()), 'notarytool keychain profile required')
    if a.dry_run:
        return
    require(not run(['git', '-C', ROOT, 'status', '--porcelain']), 'release requires a clean working tree')
    for tool in ('xcodebuild', 'xcrun', 'codesign', 'security', 'ditto', 'create-dmg', 'spctl', 'swift'):
        require(shutil.which(tool), f'missing tool: {tool}')
    require(a.identity in run(['security', 'find-identity', '-v', '-p', 'codesigning']), 'signing identity unavailable')
    try:
        run(['osascript', '-e', 'with timeout of 20 seconds', '-e', 'tell application "Finder" to get name of startup disk', '-e', 'end timeout'])
    except subprocess.CalledProcessError as e:
        raise ValueError('create-dmg needs Finder automation: allow this terminal app to control Finder in '
                         'System Settings > Privacy & Security > Automation, and keep the Mac unlocked') from e
    run(['xcrun', 'notarytool', 'history', '--keychain-profile', a.notary_profile, '--output-format', 'json'])
    with tempfile.TemporaryDirectory(prefix='ramnotes-key-probe-') as d:
        probe = Path(d) / 'probe'
        probe.write_bytes(b'RAMnotes release key preflight')
        sig = run([a.sparkle_bin / 'sign_update', '--account', KEY_ACCOUNT, '-p', probe])
        verify_public(a.public_key, probe, sig)


def verify_public(key, path, signature):
    # CryptoKit checks against the configured public key, independently of Sparkle's own --verify.
    with tempfile.TemporaryDirectory(prefix='ramnotes-swift-cache-') as cache:
        run(['swift', '-module-cache-path', cache, ROOT / 'scripts/verify-release-signature.swift', key, path, signature])


def paths(out, version, build):
    return dict(archive=out / 'RAMnotes.xcarchive', app=out / 'export/RAMnotes.app',
                zip=out / 'updates' / f'RAMnotes-{version}-{build}.zip', dmg=out / f'RAMnotes-{version}-{build}.dmg')


def commands(a, version, build):
    out = a.output
    p = paths(out, version, build)
    return [
        ['env', f'DEVELOPMENT_TEAM={a.team}', f'SPARKLE_FEED_URL={a.feed_url}', f'SPARKLE_PUBLIC_ED_KEY={a.public_key}',
         'bash', ROOT / 'scripts/archive-build.sh', 'direct', p['archive']],
        ['xcodebuild', '-exportArchive', '-archivePath', p['archive'], '-exportPath', out / 'export', '-exportOptionsPlist', out / 'ExportOptions.plist'],
        ['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', p['app'], out / 'notarize-app.zip'],
        ['xcrun', 'notarytool', 'submit', out / 'notarize-app.zip', '--keychain-profile', a.notary_profile, '--wait', '--output-format', 'json'],
        ['xcrun', 'stapler', 'staple', p['app']], ['xcrun', 'stapler', 'validate', p['app']],
        ['spctl', '--assess', '--type', 'execute', '--verbose=4', p['app']],
        ['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', p['app'], p['zip']],
        ['bash', ROOT / 'scripts/package-dmg.sh', p['app'], p['dmg']],
        ['codesign', '--sign', a.identity, '--timestamp', p['dmg']],
        ['xcrun', 'notarytool', 'submit', p['dmg'], '--keychain-profile', a.notary_profile, '--wait', '--output-format', 'json'],
        ['xcrun', 'stapler', 'staple', p['dmg']], ['xcrun', 'stapler', 'validate', p['dmg']],
        ['codesign', '--verify', '--strict', p['dmg']],
        ['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', p['dmg']],
        [a.sparkle_bin / 'generate_appcast', '--account', KEY_ACCOUNT, '--download-url-prefix', a.download_url_prefix.rstrip('/') + '/',
         '--embed-release-notes', '--maximum-deltas', '0', '-o', out / 'updates/appcast.xml', out / 'updates'],
    ]


def execute(a, version, build, plan):
    p = paths(a.output, version, build)
    a.output.mkdir(parents=True, mode=0o700)
    (a.output / 'updates').mkdir()
    (a.output / 'ExportOptions.plist').write_bytes(plistlib.dumps(dict(method='developer-id', teamID=a.team, signingStyle='automatic')))
    for cmd in plan:
        if cmd[0] == 'ditto' and cmd[-1] == a.output / 'notarize-app.zip':
            verify_app(p['app'], version, build, a.feed_url, a.public_key)
        if str(cmd[0]).endswith('generate_appcast'):
            run(['ditto', '-x', '-k', p['zip'], a.output / 'roundtrip'])
            restored = a.output / 'roundtrip/RAMnotes.app'
            require(tree_manifest(p['app']) == tree_manifest(restored), 'ZIP changed bytes, modes, or symlinks')
            verify_app(restored, version, build, a.feed_url, a.public_key)
            p['zip'].with_suffix('.html').write_bytes(a.notes.read_bytes())
        result = run(cmd)
        if cmd[:3] == ['xcrun', 'notarytool', 'submit']:
            submission = json.loads(result)
            (a.output / (Path(cmd[3]).name + '.notary.json')).write_text(result + '\n')
            require(submission.get('status') == 'Accepted', 'notarization was not Accepted')
            if submission.get('id'):
                log = run(['xcrun', 'notarytool', 'log', submission['id'], '--keychain-profile', a.notary_profile])
                (a.output / (Path(cmd[3]).name + '.notary-log.json')).write_text(log + '\n')
    signature = verify_feed(a.output / 'updates/appcast.xml', p['zip'], version, build, a.download_url_prefix)
    run([a.sparkle_bin / 'sign_update', '--account', KEY_ACCOUNT, '--verify', p['zip'], signature])
    verify_public(a.public_key, p['zip'], signature)
    (a.output / 'publication.json').write_text(json.dumps({'version': version, 'build': int(build), 'feed_url': a.feed_url, 'download_url_prefix': a.download_url_prefix.rstrip('/'), 'public_key': a.public_key}, indent=2) + '\n')
    hashes = {str(f.relative_to(a.output)): hashlib.sha256(f.read_bytes()).hexdigest() for f in (p['zip'], p['dmg'], a.output / 'updates/appcast.xml')}
    (a.output / 'SHA256.json').write_text(json.dumps(hashes, indent=2) + '\n')
    print('Local candidate verified. Nothing published. Preserve exact bytes for later publication.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dry-run', action='store_true')
    for name in ('history', 'notes', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--sparkle-bin', type=Path, default=ROOT / 'build/Archive/SourcePackages/artifacts/sparkle/Sparkle/bin')
    p.add_argument('--feed-url', default=FEED_URL)
    p.add_argument('--public-key', default=PUBLIC_KEY)
    p.add_argument('--download-url-prefix', help=f'default: {DOWNLOAD_URL_ROOT}/<VERSION>-<BUILD>')
    for name in ('identity', 'team', 'notary-profile'):
        p.add_argument('--' + name, required=True)
    a = p.parse_args()
    try:
        version, build = versions(PROJECT / 'project.pbxproj')
        a.download_url_prefix = a.download_url_prefix or f'{DOWNLOAD_URL_ROOT}/{version}-{build}'
        prerequisites(a, build)
        plan = commands(a, version, build)
        if a.dry_run:
            print(f'DRY RUN: {version} ({build}); local candidate only. Credential/toolchain checks deferred; no writes or network.')
            for cmd in plan:
                print(shlex.join(list(map(str, cmd))))
        else:
            execute(a, version, build, plan)
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as e:
        print(f'error: {getattr(e, "stderr", None) or e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
