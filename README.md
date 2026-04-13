# geoip-sqlite-ipverse

Automatically builds a SQLite database from IP range data published by IPverse.

## Source

Data comes from: https://github.com/ipverse/country-ip-blocks

## How it works

- GitHub Actions runs every 30 minutes
- Checks latest release from IPverse
- If new version detected:
  - Downloads CSV files
  - Converts to SQLite database
  - Commits updated `ipverse.db`

## Database Schema

```sql
-- IPv4: ranges stored as 32-bit unsigned integers
ip_blocks_v4 (
  country_code TEXT NOT NULL,
  ip_start     INTEGER NOT NULL,
  ip_end       INTEGER NOT NULL
)

-- IPv6: ranges stored as zero-padded 32-char hex strings (lexicographic comparison)
ip_blocks_v6 (
  country_code TEXT NOT NULL,
  ip_start     TEXT NOT NULL,
  ip_end       TEXT NOT NULL
)
```

Indexes on `ip_start` and `country_code` for both tables.

## Usage

**Look up country by IPv4 address**

Convert the IP to a 32-bit integer and query `ip_blocks_v4`:

```sql
-- Example: look up 8.8.8.8  (integer value = 134744072)
SELECT country_code
FROM ip_blocks_v4
WHERE 134744072 BETWEEN ip_start AND ip_end
LIMIT 1;
```

To convert an IPv4 address to its integer value in Python:

```python
import ipaddress
int(ipaddress.ip_address("8.8.8.8"))  # → 134744072
```

Or as a one-liner directly against the database:

```sh
export IP=8.8.8.8 && sqlite3 build/ip_to_country.db "SELECT country_code FROM ip_blocks_v4 WHERE $(python3 -c "import ipaddress,os; print(int(ipaddress.ip_address(os.environ['IP'])))" ) BETWEEN ip_start AND ip_end LIMIT 1;"
# → 'US'
```

**Look up country by IPv6 address**

IPv6 ranges are stored as zero-padded 32-character hex strings for lexicographic comparison:

```sql
-- Example: look up 2001:4860:4860::8888
SELECT country_code
FROM ip_blocks_v6
WHERE '20014860486000000000000000008888' BETWEEN ip_start AND ip_end
LIMIT 1;
```

To convert an IPv6 address to the 32-char hex key in Python:

```python
import ipaddress
f"{int(ipaddress.ip_address('2001:4860:4860::8888')):032x}"
# → '20014860486000000000000000008888'
```

**List all blocks for a country**

```sql
SELECT country_code, ip_start, ip_end FROM ip_blocks_v4 WHERE country_code = 'US' LIMIT 10;
SELECT country_code, ip_start, ip_end FROM ip_blocks_v6 WHERE country_code = 'US' LIMIT 10;
```

**Count blocks per country**

```sql
SELECT country_code, COUNT(*) AS blocks
FROM ip_blocks_v4
GROUP BY country_code
ORDER BY blocks DESC;
```

## Update Strategy

This repo uses polling (cron) because GitHub Actions cannot directly
trigger on releases from external repositories.

## Local Build

```sh
chmod +x geoip-sqlite-ipverse.sh
./geoip-sqlite-ipverse.sh
```

## Notes

- Requires `sqlite3`, `jq`, `curl`
- Works on macOS and Linux
- Uses GitHub API (rate limits apply)

## License

This data is released under CC0 1.0 Universal.
