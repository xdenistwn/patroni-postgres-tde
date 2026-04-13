# ===========================================================================
# HAProxy + Keepalived — HA-ready image
# ===========================================================================
# Extends the official HAProxy Alpine image with keepalived for VIP failover.
# Both the master and standby containers use this same image.
# ===========================================================================
FROM haproxy:3.1-alpine

USER root

# Install keepalived + tools for health-check scripts
RUN apk add --no-cache \
    keepalived \
    bash \
    curl

# Copy the entrypoint that starts both keepalived and haproxy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
