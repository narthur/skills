#!/usr/bin/env bash
# Guards the silent-zero failure: an eslint/plugin major bump that breaks flat-config
# glob matching or `flatConfigs.recommended` makes this tool report 0 findings forever
# instead of erroring. Asserts a known-bad file is caught and a clean one is not.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf 'export const Bad = () => <img src="x" />;\n' > "$TMP/bad.tsx"
printf 'export const Ok = () => <img src="x" alt="a kitten" />;\n' > "$TMP/ok.jsx"

out="$(cd "$TMP" && "$HERE/run" \
  -f json bad.tsx ok.jsx || true)"

grep -q 'jsx-a11y/alt-text' <<<"$out" || { echo "FAIL: .tsx violation not caught"; exit 1; }
[ "$(python3 -c 'import json,sys; print(sum(f["errorCount"] for f in json.load(sys.stdin) if f["filePath"].endswith("ok.jsx")))' <<<"$out")" = "0" ] \
  || { echo "FAIL: clean .jsx reported findings"; exit 1; }
echo "ok: a11y linter live (.tsx caught, .jsx clean)"
