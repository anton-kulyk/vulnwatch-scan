# VulnWatch Scan GitHub Action
# Minimal runtime: Debian-slim + curl + jq + ca-certificates. No Node runtime needed.

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        jq \
        ca-certificates \
        bash \
        coreutils \
    && rm -rf /var/lib/apt/lists/*

# Ensure we use HTTPS and trust the cert bundle
ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
