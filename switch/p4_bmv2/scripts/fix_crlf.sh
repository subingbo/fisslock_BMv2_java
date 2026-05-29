#!/bin/bash
# Fix Windows CRLF in shell scripts. Run: bash scripts/fix_crlf.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for f in "$ROOT"/scripts/*.sh "$ROOT"/run_bmv2.sh "$ROOT"/scripts/env.server*; do
  [[ -f "$f" ]] || continue
  sed -i 's/\r$//' "$f" 2>/dev/null || sed -i '' 's/\r$//' "$f"
  echo "fixed: $f"
done
chmod +x "$ROOT"/scripts/*.sh "$ROOT"/run_bmv2.sh 2>/dev/null || true
echo "Done. Use: bash scripts/start_switch.sh"
