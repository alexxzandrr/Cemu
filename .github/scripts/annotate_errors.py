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
CONTEXT_AFTER = 4
MAX_CHARS = 3800          # per annotation, stay well below GitHub's limits
MAX_ANNOTATIONS = 9       # 10 error annotations per step; keep one spare


def escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def collect(paths):
    blocks, seen = [], set()
    for path in paths:
        try:
            with open(path, errors="replace") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        i = 0
        while i < len(lines):
            if ERROR_RE.search(lines[i]):
                block = lines[i:i + 1 + CONTEXT_AFTER]
                key = lines[i].strip()
                if key not in seen:
                    seen.add(key)
                    blocks.append(f"[{os.path.basename(path)}] " + "\n".join(block))
                i += 1 + CONTEXT_AFTER
            else:
                i += 1
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
