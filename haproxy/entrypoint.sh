#!/bin/bash
# ===========================================================================
# Entrypoint: starts keepalived in background, then HAProxy in foreground
# ===========================================================================
set -e

echo "=== Starting keepalived ($(cat /etc/keepalived/keepalived.conf | grep 'state ' | awk '{print $2}')) ==="
keepalived --dont-fork --log-console --log-detail &
KEEPALIVED_PID=$!

echo "=== Starting HAProxy ==="
exec haproxy -f /usr/local/etc/haproxy/haproxy.cfg -W -db
