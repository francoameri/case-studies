#!/bin/bash
#
# test-multiwan-paths.sh
#
# Automates the diagnostic process from rustdesk-connectivity-failure-in-production.md:
# with multiple ISPs in HA, one had faulty routing to the target service. The manual
# fix was disconnecting ISPs sequentially to isolate which path was broken. This script
# does the same isolation, but by testing each gateway/path directly instead of
# physically disconnecting links -- safe to run against a live HA setup without
# actually dropping any path.
#
# For each gateway supplied, it sources traffic out that specific gateway (via `ip route
# get ... via <gw>` policy, or a source-routed ping if `ip rule`/multiple tables are set
# up) and reports latency + packet loss to the target through that path specifically.
#
# Usage:
#   ./test-multiwan-paths.sh -t <target_host> -g <gw1,gw2,gw3,...> [-c <ping_count>]
#
# Example (matching the case study: 3 ISPs in HA):
#   ./test-multiwan-paths.sh -t rustdesk.example.com -g 192.0.2.1,198.51.100.1,203.0.113.1
#
# Requirements: iproute2 (ip), iputils (ping), traceroute. Run as a user/context with
# permission to add/remove temporary routes (root, or NET_ADMIN capability), since
# testing "via this specific gateway" requires briefly manipulating the route table.
#
# This is read/test only in intent -- it restores the original route after each test --
# but because it does touch routing temporarily, review it before running unattended
# on a production gateway, and prefer a maintenance window.

set -euo pipefail

TARGET=""
GATEWAYS=""
PING_COUNT=4

usage() {
    echo "Usage: $0 -t <target_host_or_ip> -g <gw1,gw2,gw3,...> [-c <ping_count>]"
    echo "Example: $0 -t rustdesk.example.com -g 192.0.2.1,198.51.100.1,203.0.113.1"
    exit 2
}

while getopts "t:g:c:h" opt; do
    case $opt in
        t) TARGET="$OPTARG" ;;
        g) GATEWAYS="$OPTARG" ;;
        c) PING_COUNT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$TARGET" || -z "$GATEWAYS" ]]; then
    usage
fi

if [[ $EUID -ne 0 ]]; then
    echo "Warning: this script adds/removes temporary routes and typically needs root. Re-run with sudo if the route commands below fail." >&2
fi

IFS=',' read -ra GW_ARRAY <<< "$GATEWAYS"

echo "Testing ${#GW_ARRAY[@]} path(s) to $TARGET"
echo "============================================================"

declare -A RESULTS

for gw in "${GW_ARRAY[@]}"; do
    gw="$(echo "$gw" | xargs)"  # trim whitespace
    echo ""
    echo "--- Path via gateway $gw ---"

    # Resolve target to an IP once so ping/traceroute and the temp route agree on the same address
    TARGET_IP=$(getent hosts "$TARGET" | awk '{print $1; exit}')
    if [[ -z "$TARGET_IP" ]]; then
        TARGET_IP="$TARGET"  # assume it was already an IP
    fi

    # Add a temporary host route forcing this specific target through this specific gateway,
    # test, then always clean it up -- even if the test fails.
    ROUTE_ADDED=0
    if ip route add "$TARGET_IP" via "$gw" 2>/dev/null; then
        ROUTE_ADDED=1
    else
        echo "  (could not add a temporary route via $gw -- testing with default routing instead; results may not isolate this path cleanly)"
    fi

    PING_OUTPUT=$(ping -c "$PING_COUNT" -W 2 "$TARGET_IP" 2>&1) || true
    LOSS=$(echo "$PING_OUTPUT" | grep -oP '\d+(?=% packet loss)' || echo "100")
    AVG_RTT=$(echo "$PING_OUTPUT" | grep -oP '(?<=/)[0-9.]+(?=/[0-9.]+/[0-9.]+ ms)' || echo "N/A")

    if [[ "$ROUTE_ADDED" -eq 1 ]]; then
        ip route del "$TARGET_IP" via "$gw" 2>/dev/null || true
    fi

    RESULTS["$gw"]="loss=${LOSS}% avg_rtt=${AVG_RTT}ms"

    if [[ "$LOSS" == "100" ]]; then
        echo "  ❌ FAILED -- 100% packet loss via $gw"
    elif [[ "$LOSS" != "0" ]]; then
        echo "  ⚠️  DEGRADED -- ${LOSS}% packet loss via $gw (avg RTT: ${AVG_RTT} ms)"
    else
        echo "  ✅ OK -- 0% packet loss via $gw (avg RTT: ${AVG_RTT} ms)"
    fi
done

echo ""
echo "============================================================"
echo "Summary:"
for gw in "${!RESULTS[@]}"; do
    echo "  $gw : ${RESULTS[$gw]}"
done

echo ""
echo "The path reporting 100% loss (or high packet loss / RTT relative to the others) is your"
echo "likely broken-routing ISP -- the same signal that, in the case study, was found by"
echo "physically disconnecting each ISP in turn. Confirm with the ISP or your BGP/OSPF table"
echo "before making the HA failover permanent."
