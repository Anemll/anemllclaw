#!/usr/bin/env bash
# Re-pack a previously unpacked folder back into an .ocbackup file.
#
# Usage:  ./ocbackup-pack.sh <unpacked-dir> [output.ocbackup]
#
# Requires: lzfse (brew install lzfse), python3
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <unpacked-dir> [output.ocbackup]" >&2
  exit 1
fi

INDIR="$1"
ARCHIVE_JSON="$INDIR/archive.json"

if [[ ! -f "$ARCHIVE_JSON" ]]; then
  echo "Error: $ARCHIVE_JSON not found. Is this an unpacked backup folder?" >&2
  exit 1
fi

if ! command -v lzfse &>/dev/null; then
  echo "Error: lzfse not found. Install with: brew install lzfse" >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
OUTPUT="${2:-OpenClaw-Backup-repacked-$TIMESTAMP.ocbackup}"

TMPJSON="$(mktemp)"
TMPLZFSE="$(mktemp)"
trap 'rm -f "$TMPJSON" "$TMPLZFSE"' EXIT

# Rebuild archive JSON from the unpacked files, defaults, and keychain
INDIR="$INDIR" TMPJSON="$TMPJSON" python3 << 'PYEOF'
import json, base64, os

indir = os.environ["INDIR"]
outjson = os.environ["TMPJSON"]

with open(os.path.join(indir, "archive.json")) as f:
    archive = json.load(f)

# Re-read workspace files from files/ directory
files_dir = os.path.join(indir, "files")
new_files = []
if os.path.isdir(files_dir):
    for root, dirs, filenames in os.walk(files_dir):
        for fname in sorted(filenames):
            fpath = os.path.join(root, fname)
            token = os.path.relpath(fpath, files_dir)
            with open(fpath, "rb") as f:
                data = f.read()
            new_files.append({
                "pathToken": token,
                "data": base64.b64encode(data).decode()
            })
            print(f"  file: {token} ({len(data)} bytes)")
    new_files.sort(key=lambda e: e["pathToken"])
    archive["files"] = new_files

# Re-read defaults.plist if present
defaults_path = os.path.join(indir, "defaults.plist")
if os.path.isfile(defaults_path):
    with open(defaults_path, "rb") as f:
        archive["defaultsDomainPlist"] = base64.b64encode(f.read()).decode()
    print(f"  defaults: defaults.plist")

# Re-read keychain.json if present
keychain_path = os.path.join(indir, "keychain.json")
if os.path.isfile(keychain_path):
    with open(keychain_path) as f:
        archive["keychainItems"] = json.load(f)
    print(f"  keychain: {len(archive['keychainItems'])} items")

with open(outjson, "w") as f:
    json.dump(archive, f, sort_keys=True)
PYEOF

# Compress with LZFSE
lzfse -encode -i "$TMPJSON" -o "$TMPLZFSE"

# Prepend "OCB1" magic header
printf 'OCB1' > "$OUTPUT"
cat "$TMPLZFSE" >> "$OUTPUT"

SIZE="$(wc -c < "$OUTPUT" | tr -d ' ')"
echo ""
echo "Packed: $OUTPUT ($SIZE bytes)"
