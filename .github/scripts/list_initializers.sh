#!/bin/bash
# Diagnostic: list everything that runs before main() in the WiiPad executable.
#   - static initializers (__mod_init_func / __init_offsets), symbolized
#   - Objective-C classes/categories defined in the binary and +load methods
# Writes a report file and publishes it as notice annotations (readable via the GitHub API).
# usage: list_initializers.sh <path/to/WiiPad.app/WiiPad> <report-file>
set -uo pipefail
BIN="$1"
OUT="$2"

{
  echo "== init sections =="
  otool -l "$BIN" | grep -B1 -A3 -E "sectname (__mod_init_func|__init_offsets)" || echo "(no init sections)"

  echo; echo "== initializers (dyld_info -inits) =="
  xcrun dyld_info -inits "$BIN" 2>&1 || echo "(dyld_info -inits unavailable)"

  echo; echo "== C++ global-init functions defined in the binary (nm) =="
  nm -m "$BIN" 2>/dev/null | grep -E "_GLOBAL__sub_I_|__cxx_global_var_init" | sed 's/^[0-9a-f]* //' | sort | uniq -c | sort -rn | head -400

  echo; echo "== Objective-C classes defined in the binary =="
  nm -m "$BIN" 2>/dev/null | grep -E "\(__DATA[^)]*,__objc_data\).*_OBJC_CLASS_\\\$_" | sed 's/.*_OBJC_CLASS_\$_//' | sort

  echo; echo "== +load methods / non-lazy classes / categories =="
  otool -l "$BIN" | grep -A2 -E "sectname (__objc_nlclslist|__objc_nlcatlist|__objc_catlist)" || echo "(none)"
  nm -m "$BIN" 2>/dev/null | grep -E "\+\[.* load\]" || echo "(no +load methods)"
} > "$OUT" 2>&1

echo "report: $(wc -l < "$OUT") lines"
cat "$OUT"

# publish as notices (max ~9 per step, ~3800 chars each)
python3 - "$OUT" <<'EOF'
import sys
text = open(sys.argv[1], errors="replace").read()
chunks, cur = [], ""
for line in text.splitlines():
    if len(cur) + len(line) + 1 > 3800:
        chunks.append(cur); cur = ""
    cur += line + "\n"
if cur:
    chunks.append(cur)
esc = lambda s: s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
for i, c in enumerate(chunks[:9]):
    print(f"::notice title=Startup initializers ({i+1}/{len(chunks)})::{esc(c)}")
if len(chunks) > 9:
    print(f"::notice title=Startup initializers::{len(chunks)-9} more chunks in the build-logs artifact")
EOF
