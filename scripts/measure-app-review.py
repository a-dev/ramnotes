#!/usr/bin/env python3
"""Compile instrumented disposable copies of app sources; never launch normal startup."""
import pathlib
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit('Usage: python3 scripts/measure-app-review.py /private/tmp/ramnotes-benchmark-*')
repo = pathlib.Path(__file__).resolve().parent.parent
out = repo / 'build/AR01/probe'
out.mkdir(parents=True, exist_ok=True)
# Each anchor must match exactly once so source drift cannot silently invalidate counts.
hooks = {
 'Storage/StorageFiles.swift': [
 ('        SHA256.hash(data: data)', '        ProbeMetrics.hit("hash")\n        return SHA256.hash(data: data)'),
 ('        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey', '        ProbeMetrics.hit("resource_identity")\n        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey'),
 ('        let coordinator = NSFileCoordinator(filePresenter: nil)', '        ProbeMetrics.hit("body_read")\n        let coordinator = NSFileCoordinator(filePresenter: nil)')],
 'Storage/NoteStore.swift': [
 ('        let children = try FileManager.default.contentsOfDirectory', '        ProbeMetrics.hit("enumeration")\n        let children = try FileManager.default.contentsOfDirectory'),
 ('            var match: Identity?', '            ProbeMetrics.hit("identity_resolution")\n            var match: Identity?'),
 ('        try JSONEncoder().encode(updated).write', '        ProbeMetrics.hit("identity_write")\n        try JSONEncoder().encode(updated).write')],
 'Storage/NoteStore+Saving.swift': [
 ('                let original = try readBody(safeURL)', '                ProbeMetrics.hit("save_original_read")\n                let original = try readBody(safeURL)'),
 ('                guard try readBody(safeURL) == data', '                ProbeMetrics.hit("save_verify_read")\n                guard try readBody(safeURL) == data')],
 'Settings/MetadataStore.swift': [('        try JSONEncoder().encode(Envelope(version: 1, value: value)).write', '        ProbeMetrics.hit("metadata_write")\n        try JSONEncoder().encode(Envelope(version: 1, value: value)).write')],
 'Search/SearchIndex.swift': [('        let rawTokens = query.split', '        ProbeMetrics.hit("query_execution")\n        let rawTokens = query.split')],
 'Search/NoteListController.swift': [
 ('        task?.cancel()', '        ProbeMetrics.hit("query_request")\n        task?.cancel()'),
 ('            table.reloadData()', '            ProbeMetrics.hit("table_reload")\n            if table.window?.isVisible == true { ProbeMetrics.hit("visible_table_reload") }\n            table.reloadData()')],
 'App/main.swift': [
 ('        // Window state must track storage', '        ProbeMetrics.hit("refresh_list")\n        // Window state must track storage'),
 ('        for view in stack.arrangedSubviews', '        ProbeMetrics.hit("recovery_rebuild")\n        for view in stack.arrangedSubviews')]
}
paths = []
for source in sorted((repo / 'ramnotes').rglob('*.swift')):
    relative = str(source.relative_to(repo / 'ramnotes'))
    text = source.read_text()
    for anchor, replacement in hooks.get(relative, []):
        expected = 2 if anchor in ['        try JSONEncoder().encode(updated).write', '        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey'] else 1
        if text.count(anchor) != expected:
            raise SystemExit(f'Instrumentation anchor drift: {relative}: {anchor}')
        text = text.replace(anchor, replacement)
    # Only generated copies expose state to the harness. Production access stays intact.
    text = text.replace('private ', '')
    if relative == 'App/main.swift':
        text = text[:text.index('let application = NSApplication.shared')]
    target = out / (relative.replace('/', '_'))
    target.write_text(text)
    paths.append(str(target))
subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-parse-as-library', '-target', 'arm64-apple-macos27.0', '-module-cache-path', str(out / 'ModuleCache'), *paths, str(repo / 'scripts/app-review-baseline.swift'), '-o', str(out / 'baseline')], check=True)
subprocess.run([str(out / 'baseline'), sys.argv[1]], check=True)
