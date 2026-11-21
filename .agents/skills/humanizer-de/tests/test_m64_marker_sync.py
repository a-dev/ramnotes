"""
Vertrag: references/patterns.md listet unter Muster 64 Indikator-Vokabeln in
drei Bullet-Zeilen (Verben/Adjektive/Abstrakta). Der deterministische Linter
`german_pattern_lint.AI_MARKERS` kennt nur eine Teilmenge davon. Jede Vokabel
aus dem Katalog muss entweder über AI_MARKERS erreichbar sein oder explizit
per `<!-- m64-judgment-only: ... -->` als bewusst judgment-only annotiert
werden. Aufnahme in AI_MARKERS läuft ausschließlich über
docs/marker-aufnahmeprotokoll.md (FP-Baseline) - die Annotation erzwingt
also eine bewusste Entscheidung statt stiller Drift zwischen Katalog und
Linter.
"""

import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "references" / "patterns.md"
SCRIPT = ROOT / "scripts" / "german_pattern_lint.py"

spec = importlib.util.spec_from_file_location("german_pattern_lint", SCRIPT)
german_pattern_lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(german_pattern_lint)

BULLET_PREFIXES = ("- Verben:", "- Adjektive:", "- Abstrakta:")
JUDGMENT_ONLY_RE = re.compile(r"<!-- m64-judgment-only:\s*(.+?)\s*-->")


def m64_section():
    text = CATALOG_PATH.read_text(encoding="utf-8")
    match = re.search(r"^#### 64\..*?(?=^#### |\Z)", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError("Muster 64 nicht in patterns.md gefunden")
    return match.group(0)


def normalize(term):
    term = term.lower()
    term = re.sub(r"\([^)]*\)", " ", term)
    term = re.sub(r"^(der|die|das)\s+", "", term.strip())
    return " ".join(term.split())


def indicator_terms(section):
    terms = set()
    for line in section.splitlines():
        stripped = line.strip()
        if stripped.startswith(BULLET_PREFIXES):
            for quoted in re.findall(r'"([^"]+)"', stripped):
                terms.add(normalize(quoted))
    return terms


def judgment_only_terms(section):
    match = JUDGMENT_ONLY_RE.search(section)
    if not match:
        raise AssertionError("Muster 64 hat keine m64-judgment-only-Annotation")
    return {normalize(term) for term in match.group(1).split(",")}


def reachable(term):
    return any(
        german_pattern_lint.marker_spans(term, marker)
        for marker in german_pattern_lint.AI_MARKERS
    )


class M64MarkerSyncTests(unittest.TestCase):
    def test_indicator_terms_are_reachable_or_annotated(self):
        section = m64_section()
        terms = indicator_terms(section)
        self.assertTrue(terms, "Keine Indikator-Vokabeln aus Muster 64 extrahiert")
        judgment_only = judgment_only_terms(section)

        orphans = {
            term for term in terms if not reachable(term) and term not in judgment_only
        }
        self.assertFalse(
            orphans,
            f"Vokabeln weder über AI_MARKERS erreichbar noch als judgment-only annotiert: {sorted(orphans)}",
        )

    def test_judgment_only_annotation_matches_catalog_terms(self):
        section = m64_section()
        terms = indicator_terms(section)
        judgment_only = judgment_only_terms(section)

        stale = judgment_only - terms
        self.assertFalse(
            stale,
            f"m64-judgment-only nennt Vokabeln, die nicht im Muster-64-Katalog stehen: {sorted(stale)}",
        )

    def test_judgment_only_annotation_has_no_reachable_entries(self):
        section = m64_section()
        judgment_only = judgment_only_terms(section)

        outdated = {term for term in judgment_only if reachable(term)}
        self.assertFalse(
            outdated,
            f"Als judgment-only annotierte Vokabeln sind bereits über AI_MARKERS erreichbar, "
            f"Annotation muss entfernt werden: {sorted(outdated)}",
        )


if __name__ == "__main__":
    unittest.main()
