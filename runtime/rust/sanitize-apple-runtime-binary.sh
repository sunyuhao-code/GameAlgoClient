#!/usr/bin/env bash
set -euo pipefail

binary="${1:-}"
if [[ -z "$binary" || ! -f "$binary" ]]; then
  echo "usage: $0 <runtime-binary>" >&2
  exit 2
fi

# Keep replacements byte-for-byte the same length so Mach-O offsets and code
# signatures added later by the consuming application remain unaffected.
LC_ALL=C perl -0pi -e '
  s/QuickJS/GAlgoVM/g;
  s/quickjs/galgovm/g;
  s/QUICKJS/GALGOVM/g;
' "$binary"

if LC_ALL=C grep -a -i -q 'quickjs' "$binary"; then
  echo "runtime implementation identifier remains in $binary" >&2
  exit 1
fi
