#!/usr/bin/env bash
# Unpack an AnemllClaw .ocbackup file into a folder.
#
# Usage:  ./ocbackup-unpack.sh <backup.ocbackup> [output-dir]
#
# Requires: lzfse (brew install lzfse), python3
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup.ocbackup> [output-dir]" >&2
  exit 1
fi

BACKUP="$1"
OUTDIR="${2:-$(basename "$BACKUP" .ocbackup)}"

if [[ ! -f "$BACKUP" ]]; then
  echo "Error: file not found: $BACKUP" >&2
  exit 1
fi

if ! command -v lzfse &>/dev/null; then
  echo "Error: lzfse not found. Install with: brew install lzfse" >&2
  exit 1
fi

# Strip 4-byte "OCB1" magic header and decompress LZFSE
TMPJSON="$(mktemp)"
trap 'rm -f "$TMPJSON"' EXIT

tail -c +5 "$BACKUP" | lzfse -decode -o "$TMPJSON"

mkdir -p "$OUTDIR"

# Extract metadata
python3 -c "
import json, sys
with open('$TMPJSON') as f:
    a = json.load(f)
print(f\"Archive version : {a['version']}\")
print(f\"Created         : {a['createdAtISO8601']}\")
print(f\"Bundle ID       : {a['appBundleIdentifier']}\")
print(f\"App version     : {a['appVersion']}\")
print(f\"Files           : {len(a['files'])}\")
print(f\"Settings keys   : (in defaults.plist)\")
print(f\"Keychain items  : {len(a['keychainItems'])}\")
"

# Extract workspace files
TMPJSON="$TMPJSON" OUTDIR="$OUTDIR" python3 << 'PYEOF'
import json, base64, os, sys

tmpjson = os.environ["TMPJSON"]
outdir = os.environ["OUTDIR"]

with open(tmpjson) as f:
    archive = json.load(f)

# Write workspace files
files_dir = os.path.join(outdir, "files")
os.makedirs(files_dir, exist_ok=True)
real_files_dir = os.path.realpath(files_dir)
for entry in archive["files"]:
    token = entry["pathToken"]
    data = base64.b64decode(entry["data"])
    # Normalise first to collapse ../ before creating dirs, then verify
    # the resolved real path stays inside the extraction root.
    candidate = os.path.normpath(os.path.join(real_files_dir, token))
    if not (candidate == real_files_dir or candidate.startswith(real_files_dir + os.sep)):
        print(f"  SKIPPED (path traversal): {token}", file=sys.stderr)
        continue
    parent = os.path.dirname(candidate)
    os.makedirs(parent, exist_ok=True)
    # Re-resolve after mkdir to catch symlink races
    dest = os.path.realpath(candidate)
    if not (dest == real_files_dir or dest.startswith(real_files_dir + os.sep)):
        print(f"  SKIPPED (symlink escape): {token}", file=sys.stderr)
        continue
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(data)
    print(f"  file: {token} ({len(data)} bytes)")

# Write defaults plist
defaults_data = base64.b64decode(archive["defaultsDomainPlist"])
defaults_path = os.path.join(outdir, "defaults.plist")
with open(defaults_path, "wb") as out:
    out.write(defaults_data)
print(f"  defaults: defaults.plist ({len(defaults_data)} bytes)")

# Write keychain items as JSON (CAUTION: contains secrets)
keychain_path = os.path.join(outdir, "keychain.json")
fd = os.open(keychain_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as out:
    json.dump(archive["keychainItems"], out, indent=2)
print(f"  keychain: keychain.json ({len(archive['keychainItems'])} items)")

# Write raw archive JSON for reference
raw_path = os.path.join(outdir, "archive.json")
with open(raw_path, "w") as out:
    json.dump(archive, out, indent=2)
print(f"  raw: archive.json")
PYEOF

echo ""
echo "Unpacked to: $OUTDIR/"
echo "  files/        -- workspace files (SOUL.md, MEMORY.md, skills/, etc.)"
echo "  defaults.plist -- UserDefaults (binary plist, use 'plutil -p' to inspect)"
echo "  keychain.json  -- keychain credentials (contains API keys!)"
echo "  archive.json   -- full raw archive for reference"
