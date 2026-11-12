#!/usr/bin/env python3
"""Validate the String Catalogs and report Chinese Swift literals.

  python3 scripts/check-l10n.py                       # 只查翻译完整性和占位符
  python3 scripts/check-l10n.py --derived-data <目录>  # 另外用 Xcode 抽取的 key 核对代码和 catalog

不传 --derived-data 时自动用 ~/Library/Developer/Xcode/DerivedData 里最近构建过的 mmBrowser。
"""

from dataclasses import dataclass
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
LANGS = ("en", "zh-Hans")
# 源码目录 → (String Catalog, 编译这些源码的 Xcode target)。
# mmctl 的 catalog 打进 App 里，Xcode 不会自动把 mmctl 代码里的新 key 加进去，要手动加；这里的核对兜底。
CATALOGS = {
    "MMCore": ("Sources/MMCore/Resources/Localizable.xcstrings", "MMCore"),
    "MMApp": ("Sources/MMApp/Resources/Localizable.xcstrings", "mmBrowser"),
    "mmctl": ("Sources/mmctl/Resources/mmctl.xcstrings", "mmctl"),
}
EXTRA_CATALOGS = ["Sources/MMApp/Resources/InfoPlist.xcstrings"]
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?([-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hlqztj])?[@diuoxXfFeEgGaAcCsSp%])")


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


def placeholders(text):
    """按参数位置比较，允许译文用 %2$@ 等形式调整顺序。"""
    result, nxt = [], 1
    for m in PLACEHOLDER.finditer(text):
        if m[2] == "%":
            continue
        if m[1]:
            position = int(m[1])
        else:
            position, nxt = nxt, nxt + 1
        result.append(f"{position}:{m[2]}")
    return sorted(result)


def units(localization):
    """一种语言下的所有 stringUnit（复数形式各算一个）。"""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, forms in localization.get("variations", {}).items():
        for form, value in forms.items():
            yield from ((f"{kind}.{form}{sub}", unit) for sub, unit in units(value))


def check_catalog(path, problems):
    strings = json.loads(path.read_text())["strings"]
    for key, entry in sorted(strings.items()):
        if entry.get("shouldTranslate") is False:
            continue
        expected = placeholders(key)
        for lang in LANGS:
            found = list(units(entry.get("localizations", {}).get(lang, {})))
            if not found:
                problems.append(f"{path.name}: {key!r} missing {lang}")
            for form, unit in found:
                where = f"{path.name}: {key!r} {lang}{' ' + form if form else ''}"
                if unit.get("state") != "translated":
                    problems.append(f"{where} is {unit.get('state')!r}, not translated")
                # 复数的 one 形式允许省略数字（如 "one profile"）
                elif placeholders(unit["value"]) != expected and not form.endswith(".one"):
                    problems.append(f"{where} placeholders {placeholders(unit['value'])} != key {expected}")
    return strings


def find_derived_data(root):
    """Xcode 为本仓库 mmBrowser.xcodeproj 建的 DerivedData（有多个时取最近的）。"""
    import plistlib
    project = str(root / "mmBrowser.xcodeproj")
    candidates = []
    for d in Path.home().glob("Library/Developer/Xcode/DerivedData/mmBrowser-*"):
        try:
            if plistlib.loads((d / "info.plist").read_bytes()).get("WorkspacePath") == project:
                candidates.append(d)
        except (OSError, plistlib.InvalidFileException):
            pass
    return max(candidates, key=lambda d: d.stat().st_mtime, default=None)


def check_extraction(root, derived, problems, warnings):
    """用 Xcode 构建时抽取的 .stringsdata 同步一份 catalog 副本，看代码里的 key 和 catalog 对不对得上。"""
    # 同一个 DerivedData 里可能有 Debug、Release 等多套中间产物，只看最近构建的那套，免得旧产物里的 key 误报
    configs = [d for d in derived.glob("Build/Intermediates.noindex/mmBrowser.build/*") if d.is_dir()]
    newest = lambda d: max((f.stat().st_mtime for f in d.rglob("*.stringsdata")), default=0)
    config = max(configs, key=newest, default=None)
    for name, (catalog, target) in CATALOGS.items():
        # ExtractedAppShortcutsMetadata 是 App Intents 工具生成的，不是从源码抽取的
        data = sorted(f for f in config.glob(f"{target}.build/**/*.stringsdata")
                      if f.name != "ExtractedAppShortcutsMetadata.stringsdata") if config else []
        if not data:
            problems.append(f"{name}: no .stringsdata for target {target} under {derived}; build first")
            continue
        built = min(f.stat().st_mtime for f in data)
        if any(f.stat().st_mtime > built for f in (root / "Sources" / name).rglob("*.swift")):
            problems.append(f"{name}: sources changed since the last build in {derived}; build again first")
            continue
        old = json.loads((root / catalog).read_text())["strings"]
        with tempfile.TemporaryDirectory() as tmp:
            # sync 按文件名匹配表名；代码里的 L() 一律被抽取到 Localizable 表
            copy = Path(tmp) / "Localizable.xcstrings"
            shutil.copy(root / catalog, copy)
            args = [arg for path in data for arg in ("--stringsdata", str(path))]
            subprocess.run(["xcrun", "xcstringstool", "sync", str(copy), *args], check=True)
            new = json.loads(copy.read_text())["strings"]
        for key in sorted(new.keys() - old.keys()):
            problems.append(f"{catalog}: {key!r} is used in code but missing from the catalog")
        for key, entry in sorted(new.items()):
            if entry.get("extractionState") == "stale" and old.get(key, {}).get("extractionState") != "manual":
                warnings.append(f"{catalog}: {key!r} is no longer used in code")


def check(root=ROOT, derived=None):
    problems, warnings, remaining = [], [], []
    for catalog, _ in CATALOGS.values():
        check_catalog(root / catalog, problems)
    for catalog in EXTRA_CATALOGS:
        check_catalog(root / catalog, problems)
    derived = derived or find_derived_data(root)
    if derived:
        print(f"Using build output in {derived}\n")
        check_extraction(root, derived, problems, warnings)
    else:
        warnings.append("no DerivedData found; skipped checking keys used in code (build in Xcode or pass --derived-data)")
    for path in sorted((root / "Sources").rglob("*.swift")):
        source = path.read_text()
        for token in literals(source):
            if any(HAN.search(part) for part in token.parts):
                line = source.count("\n", 0, token.start) + 1
                remaining.append(f"{path.relative_to(root)}:{line}: {source[token.start:token.end]}")
    print("Remaining Chinese string literals (report only):")
    print("\n".join(remaining) or "None")
    print("\nWarnings:")
    print("\n".join(warnings) or "None")
    print("\nLocalization errors:")
    print("\n".join(problems) or "None")
    return bool(problems)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", type=Path, help="xcodebuild -derivedDataPath 的目录")
    sys.exit(check(derived=parser.parse_args().derived_data))
