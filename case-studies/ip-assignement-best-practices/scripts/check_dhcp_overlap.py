#!/usr/bin/env python3
"""
check_dhcp_overlap.py

Detects overlap between a statically-assigned IP range and a DHCP scope --
the exact misconfiguration described in ip-assignement-best-practices/readme.md
("Example misconfiguration" section): a static block was accidentally left
inside the DHCP scope, causing intermittent ARP collisions on critical servers.

This script turns that manual "did I overlap my static range with my DHCP
scope?" check into something you can run before deploying a scope change,
or as a periodic audit against a list of known static allocations.

Usage:
    python3 check_dhcp_overlap.py --static 10.10.20.10-10.10.20.30 --dhcp 10.10.20.1-10.10.20.50
    python3 check_dhcp_overlap.py --static 10.10.20.0/27 --dhcp 10.10.20.0/24
    python3 check_dhcp_overlap.py --config allocations.csv

CSV mode (--config) expects a file with columns: name,type,start,end
where type is either "static" or "dhcp". Every static range is checked
against every dhcp range; all conflicts are reported.

Exit codes:
    0  -- no overlaps found
    1  -- one or more overlaps found (useful for CI/scripted checks)
    2  -- input error
"""

import argparse
import csv
import ipaddress
import sys
from dataclasses import dataclass


@dataclass
class IPRange:
    name: str
    start: ipaddress.IPv4Address
    end: ipaddress.IPv4Address

    def overlaps(self, other: "IPRange") -> bool:
        return self.start <= other.end and other.start <= self.end

    def __str__(self):
        return f"{self.name} [{self.start} - {self.end}]"


def parse_range(text: str, name: str = "range") -> IPRange:
    """Accepts either 'start-end' or CIDR notation and returns an IPRange."""
    text = text.strip()
    if "/" in text:
        net = ipaddress.ip_network(text, strict=False)
        return IPRange(name, net.network_address, net.broadcast_address)
    if "-" in text:
        start_s, end_s = text.split("-", 1)
        start = ipaddress.ip_address(start_s.strip())
        end = ipaddress.ip_address(end_s.strip())
        if start > end:
            raise ValueError(f"Range start {start} is after end {end} in '{text}'")
        return IPRange(name, start, end)
    raise ValueError(f"Could not parse '{text}' as CIDR or start-end range")


def load_csv(path: str):
    static_ranges, dhcp_ranges = [], []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        required = {"name", "type", "start", "end"}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError(
                f"CSV must have columns: {', '.join(sorted(required))} "
                f"(found: {reader.fieldnames})"
            )
        for row in reader:
            rng = IPRange(
                row["name"],
                ipaddress.ip_address(row["start"].strip()),
                ipaddress.ip_address(row["end"].strip()),
            )
            kind = row["type"].strip().lower()
            if kind == "static":
                static_ranges.append(rng)
            elif kind == "dhcp":
                dhcp_ranges.append(rng)
            else:
                raise ValueError(f"Unknown type '{row['type']}' for row {row['name']} (expected 'static' or 'dhcp')")
    return static_ranges, dhcp_ranges


def main():
    parser = argparse.ArgumentParser(
        description="Check for overlap between static IP allocations and DHCP scopes."
    )
    parser.add_argument("--static", help="Static range: 'start-end' or CIDR")
    parser.add_argument("--dhcp", help="DHCP scope range: 'start-end' or CIDR")
    parser.add_argument("--config", help="CSV file with columns: name,type,start,end (type = static|dhcp)")
    args = parser.parse_args()

    if args.config:
        try:
            static_ranges, dhcp_ranges = load_csv(args.config)
        except (ValueError, OSError) as e:
            print(f"Error reading {args.config}: {e}", file=sys.stderr)
            sys.exit(2)
        if not static_ranges or not dhcp_ranges:
            print("Warning: need at least one static and one dhcp row to compare.", file=sys.stderr)
    elif args.static and args.dhcp:
        try:
            static_ranges = [parse_range(args.static, "static")]
            dhcp_ranges = [parse_range(args.dhcp, "dhcp")]
        except ValueError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(2)
    else:
        parser.print_help()
        sys.exit(2)

    conflicts = []
    for s in static_ranges:
        for d in dhcp_ranges:
            if s.overlaps(d):
                conflicts.append((s, d))

    if conflicts:
        print(f"❌ {len(conflicts)} overlap(s) found:\n")
        for s, d in conflicts:
            print(f"  STATIC {s}  overlaps  DHCP {d}")
        print(
            "\nThis is the exact failure mode described in ip-assignement-best-practices: "
            "a static block sitting inside a live DHCP scope can hand out an address "
            "already in use, producing intermittent ARP collisions.\n"
            "Fix: exclude the static range from the DHCP scope, or shrink/relocate the scope."
        )
        sys.exit(1)
    else:
        print("✅ No overlap detected between static ranges and DHCP scopes.")
        sys.exit(0)


if __name__ == "__main__":
    main()
