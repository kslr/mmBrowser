#!/usr/bin/env python3
"""Report Chinese Swift literals and validate per-target localization keys."""

from dataclasses import dataclass
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")


@dataclass
class Literal:
    start: int
    end: int
    parts: list[str]

    @property
    def interpolated(self):
        return len(self.parts) > 1


def unescape(text):
    escapes = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", '"': '"', "\\": "\\"}
    return re.sub(r"\\(?:u\{([0-9a-fA-F]+)\}|(.))",
                  lambda m: chr(int(m[1], 16)) if m[1] else escapes.get(m[2], m[2]), text)


def literals(source):
    """Scan Swift strings, including nested interpolation; skip nested comments.

    Parts contain literal text between interpolations, so unknown expression types
    can be checked by the prefix without guessing their printf representation.
    """
    found = []

    def code(i, interpolation=False):
        depth = 1
        while i < len(source):
            if source.startswith("//", i):
                end = source.find("\n", i)
                i = len(source) if end == -1 else end + 1
            elif source.startswith("/*", i):
                level = 1
                i += 2
                while i < len(source) and level:
                    if source.startswith("/*", i):
                        level += 1
                        i += 2
                    elif source.startswith("*/", i):
                        level -= 1
                        i += 2
                    else:
                        i += 1
            elif match := re.match(r'(#*)("""|")', source[i:]):
                i = string(i, match[1], match[2])
            elif interpolation and source[i] == "(":
                depth += 1
                i += 1
            elif interpolation and source[i] == ")":
                depth -= 1
                i += 1
                if depth == 0:
                    return i
            else:
                i += 1
        return i

    def string(start, hashes, quote):
        i = start + len(hashes) + len(quote)
        chunk = i
        parts = []
        escape = "\\" + hashes
        close = quote + hashes
        while i < len(source):
            if source.startswith(close, i):
                parts.append(unescape(source[chunk:i].replace(escape, "\\")))
                i += len(close)
                found.append(Literal(start, i, parts))
                return i
            if source.startswith(escape + "(", i):
                parts.append(unescape(source[chunk:i].replace(escape, "\\")))
                expression_start = i + len(escape) + 1
                i = code(expression_start, interpolation=True)
                chunk = i
            elif source.startswith(escape, i):
                i += len(escape) + 1
            else:
                i += 1
        raise ValueError(f"Unterminated string at offset {start}")

    code(0)
    return sorted(found, key=lambda s: s.start)


def read_strings(path):
    source = path.read_text(encoding="utf-8-sig")
    tokens = literals(source)
    if len(tokens) % 2:
        raise ValueError(f"{path}: incomplete strings entry")
    entries = {}
    for key, value in zip(tokens[::2], tokens[1::2]):
        if source[key.end:value.start].strip() != "=" or not source[value.end:].lstrip().startswith(";"):
            raise ValueError(f"{path}: invalid strings entry at offset {key.start}")
        name = key.parts[0]
        if name in entries:
            raise ValueError(f"{path}: duplicate key {name}")
        entries[name] = value.parts[0]
    return entries


def check(root=ROOT):
    problems = []
    remaining = []
    for target in sorted((root / "Sources").iterdir()):
        if not target.is_dir():
            continue
        tables = {lang: read_strings(target / "Resources" / f"{lang}.lproj" / "Localizable.strings")
                  for lang in ("en", "zh-Hans")}
        for lang, other in (("en", "zh-Hans"), ("zh-Hans", "en")):
            for key in sorted(tables[lang].keys() - tables[other].keys()):
                problems.append(f"{target.name}: {key!r} exists in {lang}, missing in {other}")
        for path in sorted(target.rglob("*.swift")):
            source = path.read_text()
            for token in literals(source):
                line = source.count("\n", 0, token.start) + 1
                location = f"{path.relative_to(root)}:{line}"
                if any(HAN.search(part) for part in token.parts):
                    remaining.append(f"{location}: {source[token.start:token.end]}")
                if re.search(r"\bL\s*\(\s*$", source[:token.start]):
                    for lang, entries in tables.items():
                        exists = (any(key.startswith(token.parts[0]) for key in entries)
                                  if token.interpolated else token.parts[0] in entries)
                        if not exists:
                            problems.append(f"{location}: missing {lang} key {token.parts[0]!r}"
                                            + (" (interpolation prefix)" if token.interpolated else ""))
    print("Remaining Chinese string literals (report only):")
    print("\n".join(remaining) or "None")
    print("\nLocalization key errors:")
    print("\n".join(problems) or "None")
    return bool(problems)


if __name__ == "__main__":
    sys.exit(check())
