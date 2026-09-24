#!/usr/bin/env bash
# Guards the three skip paths. Each must exit 0 with empty JSON: a skipped audit
# that looked like a failure would poison the loop's "clean" signal, and one that
# looked like zero findings would silently vouch for an unaudited page.
set -uo pipefail
RUN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

check() { # <label> <expected-stderr-fragment>
  out="$("$RUN" 2>"$TMP/err")"; rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: $1 exited $rc, want 0"; exit 1; }
  [ "$out" = "[]" ] || { echo "FAIL: $1 emitted '$out', want []"; exit 1; }
  grep -q "$2" "$TMP/err" || { echo "FAIL: $1 stderr missing '$2'"; exit 1; }
}

check "no config" "no .pa11yci.json"
echo '{"defaults":{"standard":"WCAG2AA"}}' > .pa11yci.json
check "config without urls" "declares no urls"
# Pairing a live loopback url[0] with an off-box url[1..n] was a real bypass:
# pa11y-ci re-reads the config and visits the whole list, so a probe of the first
# url alone let a repo under review aim our headless Chrome off-box.
echo '{"urls":["http://localhost:49999/","http://169.254.169.254/latest/meta-data/"]}' > .pa11yci.json
check "non-loopback url" "non-loopback url"
echo '{"urls":["http://localhost:49999/"]}' > .pa11yci.json
check "nothing listening" "nothing listening"
echo "ok: pa11y skips cleanly (no config / no urls / non-loopback / no server)"
