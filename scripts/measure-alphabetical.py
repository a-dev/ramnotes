#!/usr/bin/env python3
"""Compare optimized pre-AR10/current search components on the unchanged AR-01 corpus."""
import pathlib
import subprocess
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    raise SystemExit(f'Usage: {pathlib.Path(sys.argv[0]).name} /private/tmp/ramnotes-benchmark-*')
corpus = pathlib.Path(sys.argv[1]).resolve()
if corpus.parent != pathlib.Path('/private/tmp') or not corpus.name.startswith('ramnotes-benchmark-'):
    raise SystemExit('Use a disposable /private/tmp/ramnotes-benchmark-* corpus')
baseline_ref = 'a07956c15c0b09f904ca3770d25a8c99dfd19516'
try:
    before_text = subprocess.check_output(['git', 'show', f'{baseline_ref}:ramnotes/Search/SearchIndex.swift'], cwd=repo, text=True, stderr=subprocess.PIPE)
except subprocess.CalledProcessError as error:
    detail = error.stderr.decode().strip() if isinstance(error.stderr, bytes) else str(error.stderr).strip()
    raise SystemExit(f'Historical alphabetical baseline {baseline_ref} is unavailable; cannot produce a before/after comparison. {detail}')
out = repo / 'build/AR10/search-probe'
out.mkdir(parents=True, exist_ok=True)
domain = out / 'Domain'
domain.mkdir(parents=True, exist_ok=True)
module_cache = out / 'ModuleCache'
subprocess.run([
    'xcrun', 'swiftc', '-O', '-swift-version', '6', '-target', 'arm64-apple-macos27.0',
    '-module-cache-path', str(module_cache), '-emit-library', '-static', '-emit-module',
    '-module-name', 'ramnotesDomain', '-emit-module-path', str(domain / 'ramnotesDomain.swiftmodule'),
    str(repo / 'ramnotes/Domain/NoteValues.swift'), '-o', str(domain / 'libramnotesDomain.a'),
], check=True)
probe = (repo / 'scripts/alphabetical-probe.swift').read_text()
if 'folderGeneration: generation' not in probe or 'let generation = FolderGeneration()' not in probe:
    raise SystemExit('alphabetical-probe.swift no longer matches the known legacy API adapter; update its NoteSnapshot fixture before measuring')
probe = probe.replace('let generation = FolderGeneration()', 'let generation = CollectionToken()')
probe = probe.replace('folderGeneration: generation', 'collectionToken: generation')
if 'import ramnotesDomain' not in probe:
    probe = 'import ramnotesDomain\n' + probe
generated_probe = out / 'alphabetical-probe.swift'
generated_probe.write_text(probe)
domain_records = repo / 'ramnotes/Infrastructure/Persistence/NoteRecords.swift'
application_contracts = repo / 'ramnotes/Application/NoteContracts.swift'
for variant in ['before', 'after']:
    source = repo / 'ramnotes/Search/SearchIndex.swift'
    text = before_text if variant == 'before' else source.read_text()
    for counted in [False, True]:
        candidate = text
        if counted:
            candidate = candidate.replace('        let beginning =', '        Probe.previews += 1\n        let beginning =')
            candidate = candidate.replace('                comparison = $0.', '                Probe.comparisons += 1\n                let comparisonStart = ContinuousClock.now\n                comparison = $0.')
            anchor = '\n            }\n            if comparison'
            candidate = candidate.replace(anchor, '\n                Probe.comparisonMS += elapsed(comparisonStart)' + anchor)
        if 'import ramnotesDomain' not in candidate:
            candidate = 'import ramnotesDomain\n' + candidate
        generated = out / 'SearchIndex.swift'
        generated.write_text(candidate)
        binary = out / (variant + ('-counted' if counted else ''))
        subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-parse-as-library', '-target', 'arm64-apple-macos27.0', '-module-cache-path', str(module_cache), '-I', str(domain), '-L', str(domain), '-lramnotesDomain', str(domain_records), str(application_contracts), str(generated), str(generated_probe), '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(corpus), variant, str(counted)], check=True)
