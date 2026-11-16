#!/usr/bin/env python3
"""Offline tests for the local release pipeline's input checks, feed checks, and step order."""

import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

PREFIX = 'https://github.com/a-dev/ramnotes/releases/download/1.2.3-7'


def feed(archive, build='7', url=None, notes='<description>n</description>', signature=None):
    signature = signature or base64.b64encode(bytes(64)).decode()
    return f'''<rss xmlns:sparkle="{release.SPARKLE}"><channel><item>
<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>{notes}
<enclosure url="{url or PREFIX + '/' + archive.name}" length="{archive.stat().st_size}" sparkle:edSignature="{signature}"/>
</item></channel></rss>'''


class VersionTests(unittest.TestCase):
    def check(self, text):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'project.pbxproj'
            path.write_text(text)
            return release.versions(path)

    def test_reads_shared_version(self):
        text = 'MARKETING_VERSION = 1.2.3;\nCURRENT_PROJECT_VERSION = 7;\n' * 3
        self.assertEqual(self.check(text), ('1.2.3', '7'))

    def test_refuses_helper_build_mismatch(self):
        with self.assertRaisesRegex(ValueError, 'same CURRENT_PROJECT_VERSION'):
            self.check('MARKETING_VERSION = 1.2.3;\nCURRENT_PROJECT_VERSION = 7;\nCURRENT_PROJECT_VERSION = 6;\n')


class HistoryTests(unittest.TestCase):
    def check(self, data, build):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'history.json'
            path.write_text(json.dumps(data))
            release.history(path, build)

    def test_first_release_needs_explicit_empty_list(self):
        self.check({'published_builds': []}, '1')
        with self.assertRaisesRegex(ValueError, 'published_builds'):
            self.check({}, '1')

    def test_refuses_reused_build(self):
        with self.assertRaisesRegex(ValueError, 'exceed'):
            self.check({'published_builds': [1, 7]}, '7')


class FeedTests(unittest.TestCase):
    def check(self, **kwargs):
        with tempfile.TemporaryDirectory() as d:
            archive = Path(d) / 'RAMnotes-1.2.3-7.zip'
            archive.write_bytes(b'zip')
            path = Path(d) / 'appcast.xml'
            path.write_text(feed(archive, **kwargs))
            return release.verify_feed(path, archive, '1.2.3', '7', PREFIX)

    def test_accepts_matching_feed(self):
        self.assertEqual(len(base64.b64decode(self.check())), 64)

    def test_refuses_mismatches(self):
        for kwargs, message in (({'build': '6'}, 'version'), ({'url': 'https://ramnotes.com/updates/RAMnotes-1.2.3-7.zip'}, 'download URL'),
                                ({'notes': ''}, 'release notes'), ({'signature': 'AA=='}, 'EdDSA')):
            with self.subTest(kwargs), self.assertRaisesRegex(ValueError, message):
                self.check(**kwargs)


class DryRunTests(unittest.TestCase):
    def test_dry_run_writes_nothing_and_orders_steps(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            bin_dir = root / 'Sparkle/bin'
            plist = root / 'Sparkle/Sparkle.xcframework/macos/Resources/Info.plist'
            plist.parent.mkdir(parents=True)
            plist.write_bytes(release.plistlib.dumps({'CFBundleShortVersionString': release.SPARKLE_VERSION}))
            bin_dir.mkdir()
            for tool in ('sign_update', 'generate_appcast'):
                (bin_dir / tool).write_text('#!/bin/sh\n')
                (bin_dir / tool).chmod(0o755)
            (root / 'history.json').write_text('{"published_builds": []}')
            (root / 'notes.html').write_text('<p>Notes</p>')
            output = root / 'candidate'
            argv = ['release.py', '--dry-run', '--history', str(root / 'history.json'), '--notes', str(root / 'notes.html'),
                    '--output', str(output), '--sparkle-bin', str(bin_dir), '--identity', 'Developer ID Application: Test (ABCDE12345)',
                    '--team', 'ABCDE12345', '--notary-profile', 'profile']
            out = io.StringIO()
            with patch.object(release.sys, 'argv', argv), patch.object(release, 'run', side_effect=AssertionError('no commands in dry run')), \
                 contextlib.redirect_stdout(out):
                self.assertEqual(release.main(), 0)
            self.assertFalse(output.exists())
            lines = out.getvalue().splitlines()[1:]
            order = [next(i for i, line in enumerate(lines) if needle in line)
                     for needle in ('archive-build.sh', '-exportArchive', 'notarize-app.zip', 'package-dmg.sh', 'generate_appcast')]
            self.assertEqual(order, sorted(order))
            self.assertIn(f'--download-url-prefix {release.DOWNLOAD_URL_ROOT}/', lines[-1])
            self.assertIn(f'--account {release.KEY_ACCOUNT}', lines[-1])


if __name__ == '__main__':
    unittest.main()
