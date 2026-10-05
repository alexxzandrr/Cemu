#!/bin/bash
# Diagnostic: what runs before main() in the WiiPad executable.
# Maps every static initializer (__init_offsets / __mod_init_func) to the object file that contributed it,
# using the linker map, and lists Objective-C classes / +load methods.
# Writes a full report file and publishes a compact summary as notice annotations (readable via the API).
# usage: list_initializers.sh <path/to/WiiPad.app/WiiPad> <linker-map> <report-file>
set -uo pipefail
BIN="$1"
MAP="$2"
OUT="$3"

xcrun dyld_info -inits "$BIN" > "$OUT.inits" 2>&1 || true
otool -l "$BIN" > "$OUT.loadcmds" 2>&1 || true

python3 - "$BIN" "$MAP" "$OUT" <<'EOF'
import bisect, collections, os, re, sys
binpath, mappath, outpath = sys.argv[1:4]
inits_txt = open(outpath + ".inits", errors="replace").read()
loadcmds = open(outpath + ".loadcmds", errors="replace").read()
offsets = [int(m, 16) for m in re.findall(r"^\s+0x([0-9A-Fa-f]+)\s", inits_txt, re.M)]

# image base = vmaddr of __TEXT
m = re.search(r"segname __TEXT\n\s+vmaddr (0x[0-9a-f]+)", loadcmds)
base = int(m.group(1), 16) if m else 0x100000000

objects, symbols = {}, []
section = None
for line in open(mappath, errors="replace"):
    if line.startswith("# Object files:"): section = "obj"; continue
    if line.startswith("# Sections:"): section = "sect"; continue
    if line.startswith("# Symbols:"): section = "sym"; continue
    if line.startswith("# Dead Stripped Symbols:"): section = None; continue
    if section == "obj":
        mm = re.match(r"\[\s*(\d+)\]\s+(.*)", line.strip())
        if mm: objects[int(mm.group(1))] = mm.group(2)
    elif section == "sym":
        mm = re.match(r"0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]\s+(.*)", line.strip())
        if mm: symbols.append((int(mm.group(1), 16), int(mm.group(2), 16), int(mm.group(3)), mm.group(4)))
symbols.sort()
starts = [s[0] for s in symbols]

def short(path):
    mm = re.search(r"([^/()]+)\(([^()]+)\)$", path)   # libX.a(member.o)
    return f"{mm.group(1)}({mm.group(2)})" if mm else os.path.basename(path)

per_obj = collections.Counter()
detail = []
for off in offsets:
    addr = base + off
    i = bisect.bisect_right(starts, addr) - 1
    if i >= 0 and symbols[i][0] <= addr < symbols[i][0] + max(symbols[i][1], 1):
        _, _, fidx, name = symbols[i]
        obj = short(objects.get(fidx, f"file#{fidx}"))
    else:
        name, obj = "?", "?"
    per_obj[obj] += 1
    detail.append(f"0x{off:08X}  {obj}  {name}")

with open(outpath, "w") as f:
    f.write(f"total initializers: {len(offsets)} (image base 0x{base:x})\n\n== initializers per object file ==\n")
    for obj, n in per_obj.most_common():
        f.write(f"{n:5d}  {obj}\n")
    f.write("\n== every initializer in run order (offset, object, symbol) ==\n")
    f.write("\n".join(detail) + "\n")

summary = [f"total initializers: {len(offsets)}; object files with initializers: {len(per_obj)}"]
summary += [f"{n:5d}  {obj}" for obj, n in per_obj.most_common()]
summary += ["", "first 25 initializers in run order:"] + detail[:25]
flag = [d for d in detail if re.search(r"BackendAArch64|xbyak|MetalCppImpl|util_impl", d)]
summary += ["", "initializers from BackendAArch64 / xbyak / metal-cpp impl:"] + (flag or ["(none)"])
text = "\n".join(summary)
chunks, cur = [], ""
for line in text.splitlines():
    if len(cur) + len(line) + 1 > 3800:
        chunks.append(cur); cur = ""
    cur += line + "\n"
chunks.append(cur)
esc = lambda s: s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
for i, c in enumerate(chunks[:8]):
    print(f"::notice title=Startup initializers ({i+1}/{len(chunks)})::{esc(c)}")
EOF

{
  echo; echo "== Objective-C: non-lazy classes (+load) / categories =="
  grep -A3 -E "sectname (__objc_nlclslist|__objc_nlcatlist|__objc_catlist)" "$OUT.loadcmds" || echo "(no __objc_nlclslist / __objc_nlcatlist / __objc_catlist sections)"
  echo; echo "== Objective-C classes defined (from linker map) =="
  grep -E "_OBJC_CLASS_\\\$_" "$MAP" | sed -E 's/.*_OBJC_CLASS_\$_//' | sort -u
} >> "$OUT"
objc=$(sed -n '/== Objective-C/,$p' "$OUT" | tr '\n' ' ' | cut -c1-3500)
echo "::notice title=Startup ObjC metadata::$objc"
# JIT backend check: is any AArch64 recompiler / xbyak object linked into the app?
jit_objs=$(sed -n '/^# Object files:/,/^# Sections:/p' "$MAP" | grep -E "BackendAArch64|xbyak" | sed -E 's/.*\(([^)]*)\)$/\1/' | tr '\n' ' ')
echo "::notice title=JIT backend objects linked::${jit_objs:-none (BackendAArch64 / xbyak not linked)}"
head -120 "$OUT" || true
exit 0 # diagnostics must never fail the build
