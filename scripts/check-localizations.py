#!/usr/bin/env python3
"""Check the string catalogs for complete, well-formed translations.

Usage: scripts/check-localizations.py [catalog.xcstrings ...]

Without arguments it checks ramnotes/App/Localizable.xcstrings and
ramnotes/App/InfoPlist.xcstrings. It exits with status 1 when any check fails.

Checks per key and locale:
- every translatable key has a translation in each target locale;
- every string unit has state "translated" (no new, needs_review, or stale);
- plural variations have exactly the locale's CLDR categories;
- each value has the same format specifiers as English (count and type;
  positional reordering such as %2$@ ... %1$@ is allowed);
- multi-count formats keep each %#@token@ once and each substitution keeps %arg;
- the product name RAMnotes appears as often as in English;
- no value is identical to English unless the key is on the allowlist.
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOGS = [
    ROOT / "ramnotes/App/Localizable.xcstrings",
    ROOT / "ramnotes/App/InfoPlist.xcstrings",
]

PLURAL_CATEGORIES = {
    "en": {"one", "other"},
    "es": {"one", "many", "other"},
    "pt": {"one", "many", "other"},
    "de": {"one", "other"},
    "fr": {"one", "many", "other"},
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "ja": {"other"},
    "zh-Hans": {"other"},
}
TARGET_LOCALES = [locale for locale in PLURAL_CATEGORIES if locale != "en"]

# Values that may legitimately equal English, per locale ("*" means every locale).
SAME_AS_ENGLISH = {
    "*": {"%@ (%@)", "%@: %@", "OK", "esc", "pt", "A–Z", "Z–A", "Version %@"},
    "es": {"General", "Error"},
    "pt": {"Regular"},
    "de": {"Normal", "Export", "Startup", "Filename", "Support", "Status", "Windows", "System", "Control–Backslash"},
    "fr": {"Actions…", "Services", "Support", "Version %@", "Collection", "Notes"},
}

PRODUCT = "RAMnotes"
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(#@[A-Za-z0-9_]+@|lld|ld|lu|llu|d|i|u|f|@|s|arg|%)")


def specifiers(text):
    """Return a Counter of specifier types, ignoring positions and %%."""
    found = Counter()
    for _, kind in SPECIFIER.findall(text):
        if kind == "%":
            continue
        if kind.startswith("#@"):
            kind = "#@"
        found[kind] += 1
    return found


def tokens(text):
    return Counter(re.findall(r"%(?:\d+\$)?#@([A-Za-z0-9_]+)@", text))


def unit_value(node):
    unit = node.get("stringUnit")
    return (unit or {}).get("value"), (unit or {}).get("state")


class Checker:
    def __init__(self):
        self.errors = []

    def fail(self, catalog, key, locale, message):
        self.errors.append(f"{catalog.name}: [{locale}] {key!r}: {message}")

    def check_catalog(self, path):
        data = json.loads(path.read_text(encoding="utf-8"))
        for key, entry in data["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            english = entry.get("localizations", {}).get("en")
            for locale in TARGET_LOCALES:
                localized = entry.get("localizations", {}).get(locale)
                if localized is None:
                    self.fail(path, key, locale, "missing translation")
                    continue
                self.check_entry(path, key, locale, english, localized)

    def check_text(self, path, key, locale, english_text, text, where=""):
        label = f"{where}: " if where else ""
        if specifiers(text) != specifiers(english_text):
            self.fail(path, key, locale, f"{label}specifiers {dict(specifiers(text))} differ from English {dict(specifiers(english_text))}: {text!r}")
        if text.count(PRODUCT) != english_text.count(PRODUCT):
            self.fail(path, key, locale, f"{label}{PRODUCT} count differs: {text!r}")
        if not text.strip():
            self.fail(path, key, locale, f"{label}empty value")

    def check_same(self, path, key, locale, english_text, text):
        allowed = SAME_AS_ENGLISH["*"] | SAME_AS_ENGLISH.get(locale, set())
        if text == english_text and english_text not in allowed and english_text != PRODUCT:
            self.fail(path, key, locale, f"identical to English: {text!r}")

    def check_state(self, path, key, locale, state, where=""):
        if state != "translated":
            self.fail(path, key, locale, f"{where} state is {state!r}".strip())

    def check_plural(self, path, key, locale, english_plural, plural, where=""):
        expected = PLURAL_CATEGORIES[locale]
        if set(plural) != expected:
            self.fail(path, key, locale, f"{where} plural categories {sorted(plural)} != {sorted(expected)}".strip())
        english_other = english_plural["other"]["stringUnit"]["value"]
        for category, node in plural.items():
            text, state = unit_value(node)
            self.check_state(path, key, locale, state, f"{where} {category}")
            if text is not None:
                self.check_text(path, key, locale, english_other, text, f"{where} {category}".strip())

    def check_entry(self, path, key, locale, english, localized):
        if english is None:
            # Plain key: English is the key itself.
            text, state = unit_value(localized)
            if text is None:
                self.fail(path, key, locale, "expected a plain string unit")
                return
            self.check_state(path, key, locale, state)
            self.check_text(path, key, locale, key, text)
            self.check_same(path, key, locale, key, text)
            return

        if "substitutions" in english:
            english_format, _ = unit_value(english)
            text, state = unit_value(localized)
            if text is None:
                self.fail(path, key, locale, "expected a format with substitutions")
                return
            self.check_state(path, key, locale, state, "format")
            if tokens(text) != tokens(english_format):
                self.fail(path, key, locale, f"tokens {dict(tokens(text))} differ from English {dict(tokens(english_format))}")
            self.check_text(path, key, locale, english_format, text, "format")
            for name, english_sub in english["substitutions"].items():
                sub = localized.get("substitutions", {}).get(name)
                if sub is None:
                    self.fail(path, key, locale, f"missing substitution {name}")
                    continue
                if sub.get("argNum") != english_sub["argNum"] or sub.get("formatSpecifier") != english_sub["formatSpecifier"]:
                    self.fail(path, key, locale, f"substitution {name} argNum or formatSpecifier differs")
                self.check_plural(path, key, locale, english_sub["variations"]["plural"], sub.get("variations", {}).get("plural", {}), name)
            return

        if "variations" in english:
            plural = localized.get("variations", {}).get("plural")
            if plural is None:
                self.fail(path, key, locale, "expected plural variations")
                return
            self.check_plural(path, key, locale, english["variations"]["plural"], plural)
            return

        english_text, _ = unit_value(english)
        text, state = unit_value(localized)
        self.check_state(path, key, locale, state)
        if text is not None:
            self.check_text(path, key, locale, english_text, text)
            self.check_same(path, key, locale, english_text, text)


def main(argv):
    catalogs = [Path(arg) for arg in argv[1:]] or DEFAULT_CATALOGS
    checker = Checker()
    for catalog in catalogs:
        checker.check_catalog(catalog)
    for error in checker.errors:
        print(error)
    if checker.errors:
        print(f"FAILED: {len(checker.errors)} problem(s) in {len(catalogs)} catalog(s).")
        return 1
    print(f"OK: {len(catalogs)} catalog(s), {len(TARGET_LOCALES)} target locales.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
