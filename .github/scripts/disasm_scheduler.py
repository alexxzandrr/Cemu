#!/usr/bin/env python3
"""Diagnostic (multi-core investigation): disassemble Cemu's PPC scheduler fiber functions from the iOS build and
publish a compact view as GitHub annotations: branches, calls and thread-local (TLV) accesses with their offsets, so
it is visible whether thread_local addresses are computed once and reused across Fiber::Switch / loop iterations.

usage: disasm_scheduler.py <build dir> <output file for the full disassembly>
"""
import glob
import re
import subprocess
import sys

FUNCTIONS = ["__OSFiberThreadEntry", "__OSThreadSwitchToNext", "__OSThreadCoreIdle", "__OSSwitchToThreadFiber"]
MAX_CHARS = 3800
MAX_ANNOTATIONS = 9


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def escape(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main():
    build_dir, out_path = sys.argv[1], sys.argv[2]
    objs = glob.glob(f"{build_dir}/**/coreinit_Thread.cpp.o", recursive=True)
    if not objs:
        print("::warning::disasm: coreinit_Thread.cpp.o not found")
        return
    obj = objs[0]
    nm = run(["xcrun", "nm", obj])
    # "<address> <type> <name>"; keep defined text symbols
    symbols = [p[2] for p in (l.split() for l in nm.splitlines()) if len(p) == 3 and p[1] in ("T", "t")]
    print(f"disasm: {obj}: {len(nm.splitlines())} nm lines, {len(symbols)} text symbols")
    blocks = []
    full = []
    for fn in FUNCTIONS:
        matches = [s for s in symbols if fn in s and "cold" not in s]
        if not matches:
            blocks.append(f"{fn}: not found as a separate symbol (inlined)")
            continue
        for sym in matches:
            dis = run(["xcrun", "llvm-objdump", "-d", "-r", "--no-show-raw-insn", f"--disassemble-symbols={sym}", obj])
            full.append(dis)
            lines = dis.splitlines()
            insns = [l for l in lines if re.match(r"^\s*[0-9a-f]+:\s", l)]
            keep = []
            for i, l in enumerate(lines):
                s = l.strip()
                if re.search(r"TLVP|tlv|\bbl\b|\bblr\b|\bbr\b|\bb\b|\bb\.|\bcbn?z\b|\btbn?z\b|\bret\b", s) or "ARM64_RELOC_BRANCH26" in s:
                    keep.append(re.sub(r"\s+", " ", s))
            header = f"{sym}: {len(insns)} instructions, {sum('TLVP' in l for l in lines)} TLV relocations"
            blocks.append(header + "\n" + "\n".join(keep))
    with open(out_path, "w") as f:
        f.write("\n\n".join(full))
    # annotations, split on size
    text = "\n\n".join(blocks)
    chunks, cur = [], ""
    for line in text.splitlines():
        if len(cur) + len(line) + 1 > MAX_CHARS:
            chunks.append(cur)
            cur = ""
        cur += line + "\n"
    if cur:
        chunks.append(cur)
    for i, c in enumerate(chunks[:MAX_ANNOTATIONS]):
        print(f"::notice title=scheduler disassembly {i + 1}/{min(len(chunks), MAX_ANNOTATIONS)}::{escape(c)}")
    if len(chunks) > MAX_ANNOTATIONS:
        print(f"::notice title=scheduler disassembly::{len(chunks) - MAX_ANNOTATIONS} more chunks in the build-logs artifact")


if __name__ == "__main__":
    main()
