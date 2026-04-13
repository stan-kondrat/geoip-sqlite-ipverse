#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"
DB_NAME="$BUILD_DIR/ip_to_country.db"
WORKDIR="$(mktemp -d)"
API_URL="https://api.github.com/repos/ipverse/country-ip-blocks/releases/latest"

echo "[+] Working dir: $WORKDIR"

# Fetch latest release metadata
echo "[+] Fetching release metadata..."
RELEASE=$(curl -s "$API_URL")
ZIPBALL=$(echo "$RELEASE" | jq -r '.zipball_url')
PUBLISHED_AT=$(echo "$RELEASE" | jq -r '.published_at')

if [[ -z "$ZIPBALL" || "$ZIPBALL" == "null" ]]; then
  echo "[!] Could not get zipball URL from release"
  echo "$RELEASE" | jq .
  exit 1
fi

echo "[+] IPverse published_at: $PUBLISHED_AT"

# Download and extract the release zipball
echo "[+] Downloading release zipball..."
curl -L -s -o "$WORKDIR/data.zip" "$ZIPBALL"
unzip -q "$WORKDIR/data.zip" -d "$WORKDIR/extracted"

# Find per-country txt files: country/{cc}/ipv4-aggregated.txt
mapfile -t V4_FILES < <(find "$WORKDIR/extracted" -name 'ipv4-aggregated.txt' | sort)
mapfile -t V6_FILES < <(find "$WORKDIR/extracted" -name 'ipv6-aggregated.txt' | sort)

if [[ ${#V4_FILES[@]} -eq 0 && ${#V6_FILES[@]} -eq 0 ]]; then
  echo "[!] No aggregated.txt files found in zipball"
  exit 1
fi

echo "[+] Found ${#V4_FILES[@]} IPv4 and ${#V6_FILES[@]} IPv6 country files"

# Create SQLite DB with split v4/v6 tables and integer ranges
echo "[+] Creating database..."

sqlite3 "$DB_NAME" <<EOF
PRAGMA journal_mode=WAL;

DROP TABLE IF EXISTS ip_blocks_v4;
DROP TABLE IF EXISTS ip_blocks_v6;

-- IPv4: store as 32-bit unsigned integers (fits in SQLite INTEGER)
CREATE TABLE ip_blocks_v4 (
  country_code TEXT NOT NULL,
  ip_start     INTEGER NOT NULL,
  ip_end       INTEGER NOT NULL
);

-- IPv6: store as zero-padded 32-char hex strings for lexicographic range queries
CREATE TABLE ip_blocks_v6 (
  country_code TEXT NOT NULL,
  ip_start     TEXT NOT NULL,
  ip_end       TEXT NOT NULL
);

CREATE INDEX idx_v4_start   ON ip_blocks_v4(ip_start);
CREATE INDEX idx_v4_country ON ip_blocks_v4(country_code);
CREATE INDEX idx_v6_start   ON ip_blocks_v6(ip_start);
CREATE INDEX idx_v6_country ON ip_blocks_v6(country_code);
EOF

# Python helper: reads plain CIDR lines, country code via env var COUNTRY
CONVERT_PY='
import sys, os, ipaddress

country = os.environ["COUNTRY"]
is_v6   = os.environ.get("IP_VERSION") == "6"

for line in sys.stdin:
    cidr = line.strip()
    if not cidr or cidr.startswith("#"):
        continue
    try:
        net   = ipaddress.ip_network(cidr, strict=False)
        start = int(net.network_address)
        end   = int(net.broadcast_address)
        if is_v6:
            print(f"{country}|{start:032x}|{end:032x}")
        else:
            print(f"{country}|{start}|{end}")
    except Exception:
        pass
'

# Import data
echo "[+] Importing data..."

for file in "${V4_FILES[@]}"; do
  country=$(basename "$(dirname "$file")" | tr '[:lower:]' '[:upper:]')
  COUNTRY="$country" IP_VERSION="4" python3 -c "$CONVERT_PY" < "$file" \
    | sqlite3 "$DB_NAME" ".mode csv" ".separator |" ".import /dev/stdin ip_blocks_v4"
done

for file in "${V6_FILES[@]}"; do
  country=$(basename "$(dirname "$file")" | tr '[:lower:]' '[:upper:]')
  COUNTRY="$country" IP_VERSION="6" python3 -c "$CONVERT_PY" < "$file" \
    | sqlite3 "$DB_NAME" ".mode csv" ".separator |" ".import /dev/stdin ip_blocks_v6"
done

echo "[+] Done: $DB_NAME created"

# Quick stats
sqlite3 "$DB_NAME" "SELECT 'IPv4 rows:', COUNT(*) FROM ip_blocks_v4 UNION ALL SELECT 'IPv6 rows:', COUNT(*) FROM ip_blocks_v6;"

# Cleanup
rm -rf "$WORKDIR"
