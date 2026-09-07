#!/usr/bin/env bash
# Upload local image(s) to a stable surge.sh static site and print public URLs.
#
# The uploads folder is the source of truth: files are content-addressed
# (sha256-prefixed names) and the whole folder is mirrored to one surge domain
# on every run. Re-uploading the same bytes yields the same URL (idempotent),
# and previously-uploaded images keep working as long as the folder is kept.
#
# Usage:   upload.sh <image> [image...]
# Output:  one public https URL per input file, on stdout (surge's own chatter
#          goes to stderr so stdout stays pipe-clean).
#
# Config (env, optional):
#   SURGE_UPLOAD_DIR     persistent uploads folder
#                        (default: ${XDG_DATA_HOME:-~/.local/share}/surge-uploads)
#   SURGE_UPLOAD_DOMAIN  surge domain to publish to
#                        (default: value in <dir>/CNAME, else narthur-uploads.surge.sh)
set -euo pipefail

# surge is a pnpm/npm global; make sure those bin dirs are reachable.
export PATH="$HOME/Library/pnpm:$HOME/.local/bin:$(npm prefix -g 2>/dev/null)/bin:$PATH"

if ! command -v surge >/dev/null 2>&1; then
  echo "error: surge CLI not found. Install it with: pnpm add -g surge   (or: npm i -g surge)" >&2
  exit 1
fi
if ! surge whoami >/dev/null 2>&1; then
  echo "error: surge is not logged in. Run: surge login   (credentials are stored in ~/.netrc)" >&2
  exit 1
fi
if [ "$#" -eq 0 ]; then
  echo "usage: upload.sh <image> [image...]" >&2
  exit 2
fi

UPLOAD_DIR="${SURGE_UPLOAD_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/surge-uploads}"
mkdir -p "$UPLOAD_DIR"

# Resolve the domain: explicit env > persisted CNAME > built-in default.
if [ -n "${SURGE_UPLOAD_DOMAIN:-}" ]; then
  DOMAIN="$SURGE_UPLOAD_DOMAIN"
elif [ -f "$UPLOAD_DIR/CNAME" ]; then
  DOMAIN="$(tr -d '[:space:]' < "$UPLOAD_DIR/CNAME")"
else
  DOMAIN="narthur-uploads.surge.sh"
fi
printf '%s\n' "$DOMAIN" > "$UPLOAD_DIR/CNAME"  # persist + let surge read it

# A root page so the domain's "/" isn't an ugly 404; harmless for direct file URLs.
[ -f "$UPLOAD_DIR/index.html" ] || printf '<!doctype html><meta charset=utf-8><title>uploads</title>\n' > "$UPLOAD_DIR/index.html"

urls=()
for f in "$@"; do
  [ -f "$f" ] || { echo "error: no such file: $f" >&2; exit 1; }
  ext="$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    png|jpg|jpeg|gif|webp|svg) ;;
    *) echo "warning: $f has unusual image extension '.$ext'; uploading anyway" >&2 ;;
  esac
  hash="$(shasum -a 256 "$f" | cut -c1-12)"
  name="${hash}.${ext}"
  cp -f "$f" "$UPLOAD_DIR/$name"
  urls+=("https://${DOMAIN}/${name}")
done

# Publish the whole folder (CNAME in it pins the domain).
surge "$UPLOAD_DIR" "$DOMAIN" >&2

printf '%s\n' "${urls[@]}"
