#!/bin/bash
# ===========================================================================
# Keepalived health-check script for HAProxy
# ===========================================================================
# Called by keepalived's vrrp_script. Returns 0 if HAProxy is healthy,
# non-zero otherwise. On failure, keepalived lowers this node's priority
# so the VIP floats to the standby.
# ===========================================================================

# Check 1: is the haproxy process alive?
if ! pgrep -x haproxy > /dev/null 2>&1; then
    echo "FAIL: haproxy process not found"
    exit 1
fi

# Check 2: is the stats endpoint responding?
if ! curl -sf -o /dev/null http://localhost:8404/stats; then
    echo "FAIL: haproxy stats endpoint not responding"
    exit 1
fi

exit 0
