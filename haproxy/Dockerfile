FROM haproxy:3.0-alpine

USER root

# Install postgresql-client for health check scripts (optional)
RUN apk add --no-cache \
    bash \
    curl \
    openssl \
    postgresql-client \
    socat

# Create necessary directories
RUN mkdir -p /var/lib/haproxy /run/haproxy /usr/local/etc/haproxy

# Copy configuration files (paths are relative to the compose build context `.`)
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Copy SSL certificates (optional - used when HAPROXY_ENABLE_SSL=1)
RUN mkdir -p /etc/ssl/haproxy
COPY ssl/server.crt /etc/ssl/haproxy/server.crt
COPY ssl/server.key /etc/ssl/haproxy/server.key
RUN chmod 600 /etc/ssl/haproxy/server.key || true && chmod 644 /etc/ssl/haproxy/server.crt || true

RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose ports
# 5432 - PostgreSQL protocol (primary port for clients)
# 5433 - PostgreSQL read-only port (optional, for explicit RO queries)
# 8404 - HAProxy stats page
EXPOSE 5432 5433 8404

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
