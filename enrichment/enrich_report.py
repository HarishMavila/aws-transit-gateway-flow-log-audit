#!/usr/bin/env python3
"""
Resolve the IP addresses in a flow log report to named cloud resources.

A report of 10.20.4.11 -> 10.40.11.132 is correct and useless. Nobody can act
on it. This script adds Type and Name columns for both ends of every row, so a
row becomes something like:

    catalog-indexer-dev-3 (VIRTUAL_MACHINE) -> orders-db-primary (DATABASE)

Usage
-----
    ./enrich_report.py report.csv [report2.csv ...]
    ./enrich_report.py --cache-only report.csv     # no API calls, cache only
    ./enrich_report.py --dry-run report.csv        # show what would be looked up

Behaviour
---------
  * Idempotent. Re-running only looks up IPs that are still unresolved, so an
    interrupted run can be resumed for free.
  * Cached. Every lookup is written to ip-cache.json immediately, so a crash or
    an API error never costs you completed work.
  * Retries with backoff on transient API failures.

Requires a Wiz API client by default. See README.md for the AWS Config
alternative if you do not have Wiz.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

import pandas

CACHE_PATH = Path(__file__).parent / "ip-cache.json"

# Columns the script maintains, and the column each is inserted after.
DERIVED_COLUMNS = {
    "Source Type": "Source IP",
    "Source Name": "Source IP",
    "Destination Type": "Destination IP",
    "Destination Name": "Destination IP",
}

MAX_RETRIES = 4
RETRY_BASE_SECONDS = 2


# ---------------------------------------------------------------------------
# Resource lookup
# ---------------------------------------------------------------------------

WIZ_QUERY = """
query GraphSearch($query: GraphEntityQueryInput) {
  graphSearch(first: 1, quick: true, query: $query, projectId: "*") {
    nodes { entities { name, type } }
  }
}
"""


def wiz_variables(ip):
    """Traverse network address -> network interface -> owning cloud resource.

    The middle hop is what makes this work for Kubernetes. A pod IP belongs to
    an interface that belongs to a workload, so the traversal lands on the pod
    rather than on the node. AWS Config cannot do this: it inventories ENIs,
    not pods.
    """
    return {
        "query": {
            "type": ["NETWORK_ADDRESS"],
            "where": {"address": {"EQUALS": [ip]}},
            "relationships": [
                {
                    "type": [{"type": "OWNS", "reverse": True}],
                    "with": {
                        "type": ["NETWORK_INTERFACE"],
                        "relationships": [
                            {
                                "type": [{"type": "CONTAINS", "reverse": True}],
                                "with": {
                                    "select": True,
                                    "type": ["CLOUD_RESOURCE"],
                                    "where": {
                                        "nativeType": {
                                            "NOT_EQUALS": [
                                                "account",
                                                "project#instance",
                                                "Microsoft.Subscription",
                                            ]
                                        }
                                    },
                                },
                            }
                        ],
                    },
                }
            ],
        }
    }


def build_client():
    # Must be set before importing the SDK.
    os.environ.setdefault("WIZ_USE_DEVICE_CODE", "true")
    from wiz_sdk import WizAPIClient

    return WizAPIClient()


def lookup(client, ip):
    """Return {'name': ..., 'type': ...} for an IP, or None if not found."""
    for attempt in range(MAX_RETRIES):
        try:
            response = client.query(WIZ_QUERY, wiz_variables(ip))
            nodes = json.loads(response.to_json()).get("nodes") or []
            if not nodes:
                return None
            entities = nodes[-1].get("entities") or []
            if not entities:
                return None
            entity = entities[0]
            return {"name": entity.get("name", ""), "type": entity.get("type", "")}
        except Exception as exc:  # transient API/network failure
            if attempt == MAX_RETRIES - 1:
                print(f"  {ip}: giving up after {MAX_RETRIES} attempts ({exc})")
                return None
            delay = RETRY_BASE_SECONDS ** (attempt + 1)
            print(f"  {ip}: {exc} - retrying in {delay}s")
            time.sleep(delay)
    return None


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------


def load_cache():
    if not CACHE_PATH.exists():
        return {}
    try:
        return json.loads(CACHE_PATH.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        print(f"Ignoring unreadable cache at {CACHE_PATH}: {exc}")
        return {}


def save_cache(cache):
    tmp = CACHE_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(cache, indent=2, sort_keys=True))
    tmp.replace(CACHE_PATH)


# ---------------------------------------------------------------------------
# Report handling
# ---------------------------------------------------------------------------


def read_report(path):
    frame = pandas.read_csv(path, low_memory=False, dtype=str)

    for column, anchor in DERIVED_COLUMNS.items():
        if column not in frame.columns:
            if anchor not in frame.columns:
                raise SystemExit(
                    f"{path}: expected a '{anchor}' column, found: "
                    f"{', '.join(frame.columns)}"
                )
            frame.insert(frame.columns.get_loc(anchor) + 1, column, "")

    # read_csv turns empty cells into NaN, and NaN is truthy in Python, so a
    # plain "if not row[col]" test treats a blank cell as already resolved and
    # silently skips it. That makes the script non-idempotent: gaps left by an
    # earlier run are never filled. Normalising to empty strings here is the fix.
    for column in DERIVED_COLUMNS:
        frame[column] = frame[column].fillna("").astype(str)

    return frame


def unresolved_ips(frame):
    """IPs on rows whose Name column is still blank."""
    found = set()
    for ip_column, name_column in (
        ("Source IP", "Source Name"),
        ("Destination IP", "Destination Name"),
    ):
        blank = frame[name_column].str.strip() == ""
        found.update(frame.loc[blank, ip_column].dropna().unique())
    found.discard("")
    return found


def apply_cache(frame, cache):
    """Fill the derived columns from the cache.

    Uses a vectorised map rather than iterating rows. On a 700k row report the
    row-by-row version takes minutes; this takes under a second.
    """
    names = {ip: info["name"] for ip, info in cache.items()}
    types = {ip: info["type"] for ip, info in cache.items()}

    for ip_column, name_column, type_column in (
        ("Source IP", "Source Name", "Source Type"),
        ("Destination IP", "Destination Name", "Destination Type"),
    ):
        resolved_name = frame[ip_column].map(names).fillna("")
        resolved_type = frame[ip_column].map(types).fillna("")
        blank = frame[name_column].str.strip() == ""
        frame.loc[blank, name_column] = resolved_name[blank]
        frame.loc[blank, type_column] = resolved_type[blank]

    return frame


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", help="CSV report files to enrich")
    parser.add_argument(
        "--cache-only",
        action="store_true",
        help="apply the existing cache without making any API calls",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report how many IPs need looking up, then stop",
    )
    args = parser.parse_args()

    cache = load_cache()
    print(f"Cache holds {len(cache)} resolved IPs")

    reports = {}
    for path in args.reports:
        reports[path] = read_report(path)
        print(f"Read {path}: {len(reports[path]):,} rows")

    # Apply what we already know before deciding what to look up.
    for frame in reports.values():
        apply_cache(frame, cache)

    pending = set()
    for frame in reports.values():
        pending.update(unresolved_ips(frame))
    pending -= cache.keys()

    print(f"\n{len(pending)} unique IPs still need resolving")

    if args.dry_run:
        for ip in sorted(pending)[:20]:
            print(f"  {ip}")
        if len(pending) > 20:
            print(f"  ... and {len(pending) - 20} more")
        return

    if pending and not args.cache_only:
        client = build_client()
        for index, ip in enumerate(sorted(pending), start=1):
            info = lookup(client, ip)
            # Cache misses too, as an empty record, so the next run does not
            # retry every unresolvable IP (regional NAT gateways, deleted
            # interfaces, on-prem addresses).
            cache[ip] = info or {"name": "", "type": ""}
            save_cache(cache)
            label = f"{info['type']} / {info['name']}" if info else "not found"
            print(f"  [{index}/{len(pending)}] {ip}: {label}")

        for frame in reports.values():
            apply_cache(frame, cache)

    for path, frame in reports.items():
        frame.to_csv(path, index=False)
        resolved = (frame["Source Name"].str.strip() != "").mean()
        print(f"Wrote {path} - {resolved:.1%} of source IPs named")


if __name__ == "__main__":
    sys.exit(main())
