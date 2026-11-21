import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


evidence_lint = load("evidence_lint")
spell_lint = load("spell_lint")

HUNSPELL_DE_AVAILABLE = spell_lint.availability_reason() is None

CASES = {
    "wirtschaftsbericht": "Der Umsatz ist gestiegen, die Kosten sind gesunken.",
    "statistischer_sachtext": (
        "Die Nachfrage stieg um 12 Prozent, zugleich sank die Fehlerquote um 3 Prozent."
    ),
    "technikdokumentation": (
        "Version `2.1` verbessert die Ladezeit; der Cache senkt den Speicherbedarf."
    ),
    "rechtstext_mit_ankern": (
        "Nach § 12 Abs. 3 gilt der Wert von 25 Prozent seit dem 2. August 2026."
    ),
    "zitat_und_url": (
        "Im Bericht steht: „Alles bleibt gleich“. Details: https://example.org/bericht"
    ),
}


class NullEditContractTests(unittest.TestCase):
    """Ein unveränderter Text darf in keinem Before/After-Linter einen Befund erzeugen.

    Nur evidence_lint und spell_lint nehmen ein Paar entgegen; die übrigen Linter
    bewerten einen Einzeltext und kennen den Vertrag deshalb nicht.
    """

    def test_evidence_lint_reports_nothing_on_identical_text(self):
        for case, text in CASES.items():
            with self.subTest(case=case):
                self.assertEqual(evidence_lint.lint(text, text), [])

    @unittest.skipUnless(HUNSPELL_DE_AVAILABLE, "hunspell de_DE not installed")
    def test_spell_lint_reports_nothing_on_identical_text(self):
        for case, text in CASES.items():
            with self.subTest(case=case):
                self.assertEqual(spell_lint.lint(text, text)["findings"], [])


if __name__ == "__main__":
    unittest.main()
