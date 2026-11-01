#!/usr/bin/env python3
"""Checks that every tr("...") string in App/ has a translation in each Localizable.strings.

Usage: python3 Scripts/check_localization.py [--list]
  --list   print all keys found in the source (handy when adding a new language)

Exits with status 1 when a translation is missing, so CI catches it.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TR_CALL = re.compile(r'\btr\(\s*"((?:[^"\\]|\\.)*)"')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?@")
STRINGS_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)


def source_keys():
    keys = {}
    for path in sorted((ROOT / "App").glob("*.swift")):
        for n, line in enumerate(path.read_text().splitlines(), 1):
            for key in TR_CALL.findall(line):
                keys.setdefault(key, f"{path.relative_to(ROOT)}:{n}")
    return keys


def main():
    keys = source_keys()
    if "--list" in sys.argv:
        for key in sorted(keys):
            print(key)
        return 0

    failed = False
    for strings in sorted((ROOT / "Resources").glob("*.lproj/Localizable.strings")):
        lang = strings.parent.stem
        if lang == "en":
            continue  # English is the source language; keys are their own translation
        entries = dict(STRINGS_ENTRY.findall(strings.read_text()))
        missing = [k for k in keys if k not in entries]
        unused = [k for k in entries if k not in keys]
        bad = [k for k, v in entries.items() if len(PLACEHOLDER.findall(k)) != len(PLACEHOLDER.findall(v))]
        for k in missing:
            print(f"{lang}: missing translation for \"{k}\" ({keys[k]})")
        for k in bad:
            print(f"{lang}: placeholder count differs for \"{k}\"")
        for k in unused:
            print(f"{lang}: unused key \"{k}\" (warning)")
        failed |= bool(missing or bad)
        print(f"{lang}: {len(keys) - len(missing)}/{len(keys)} strings translated")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
