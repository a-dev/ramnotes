#!/usr/bin/env python3
"""Create a disposable NoteStore copy that omits presenter setup for sensitivity probes."""
from pathlib import Path
import sys

source = Path("ramnotes/Storage/NoteStore.swift")
destination = Path(sys.argv[1])
text = source.read_text()
start = text.index("    func startObserving() {")
end = text.index("\n    func customExternalEvent", start)
text = text[:start] + "    func startObserving() {}\n" + text[end:]
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(text)
