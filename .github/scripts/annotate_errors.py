#!/usr/bin/env python3
"""Turn build-log errors into GitHub Actions annotations.

Annotations are readable through the GitHub API (check-runs/<job>/annotations), unlike the raw job
logs, so this lets a failed CI run be diagnosed without downloading logs.

usage: annotate_errors.py <title> <log-or-glob> [<log-or-glob> ...]
"""
import glob
import os
import re
import sys

ERROR_RE = re.compile(
    r"(error:|error [A-Z]+\d+|fatal error|CMake Error|FAILED:|Undefined symbols|undefined reference|"
    r"ld: |clang: error|\*\* BUILD FAILED|xcodebuild: error|Error: |building .* failed|"
    r"Could not find|Could NOT find|No such file)",
    re.IGNORECASE,
)
CONTEXT_AFTER = 3
MAX_CHARS = 3800          # per annotation, stay well below GitHub's limits
MAX_ANNOTATIONS = 9       # 10 error annotations per step; keep one spare


def escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


NOISE_RE = re.compile(r"^(/\S+/(c\+\+|clang\+\+|clang|cc)\s|FAILED: |\[\d+/\d+\] |ninja: build stopped)")
LOCATION_RE = re.compile(r"^(In file included from|\s+\d+ \|)")


def collect(paths):
    """One block per distinct error line (compiler errors repeat for every file including a header)."""
    blocks, seen = [], set()
    for path in paths:
        try:
            with open(path, errors="replace") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        for i, line in enumerate(lines):
            if NOISE_RE.search(line) or not ERROR_RE.search(line):
                continue
            key = line.strip()
            if key in seen:
                continue
            seen.add(key)
            context = [l for l in lines[i + 1:i + 1 + CONTEXT_AFTER] if not NOISE_RE.search(l)]
            blocks.append(line + ("\n" + "\n".join(context) if context else ""))
    return blocks


def tail(paths, n=60):
    out = []
    for path in paths:
        try:
            with open(path, errors="replace") as f:
                lines = f.read().splitlines()[-n:]
            out.append(f"[{os.path.basename(path)} | last {len(lines)} lines]\n" + "\n".join(lines))
        except OSError:
            pass
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    title = sys.argv[1]
    paths = []
    for pattern in sys.argv[2:]:
        paths.extend(sorted(glob.glob(pattern)) or ([pattern] if os.path.exists(pattern) else []))
    blocks = collect(paths) or tail(paths)
    if not blocks:
        print(f"::error title={title}::no log output found in {' '.join(sys.argv[2:])}")
        return

    chunks, current = [], ""
    for block in blocks:
        if len(current) + len(block) + 2 > MAX_CHARS and current:
            chunks.append(current)
            current = ""
        current += block[:MAX_CHARS] + "\n\n"
    if current:
        chunks.append(current)

    total = len(chunks)
    for idx, chunk in enumerate(chunks[:MAX_ANNOTATIONS]):
        print(f"::error title={title} ({idx + 1}/{total})::{escape(chunk)}")
    if total > MAX_ANNOTATIONS:
        print(f"::error title={title}::{total - MAX_ANNOTATIONS} more error blocks omitted (see uploaded logs)")


if __name__ == "__main__":
    main()
