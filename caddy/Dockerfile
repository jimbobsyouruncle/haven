# syntax=docker/dockerfile:1.7
# Caddy + the ACME DNS provider modules. The stock caddy:2.11-alpine image has
# no DNS providers, and the Caddyfile refuses to load without them.
ARG CADDY_VERSION=2.11.9
# Docker Official Image index for 2.11.9-builder-alpine.
FROM caddy@sha256:646fee578e680989ca5c7fd1ce6f1de574d19fd71ef2221810cc0510a9f40c86 AS builder

ARG CADDY_VERSION
ARG CLOUDFLARE_DNS_VERSION=v0.2.4
ARG RFC2136_DNS_VERSION=v1.0.0

RUN xcaddy build "v${CADDY_VERSION}" \
      --with github.com/caddy-dns/cloudflare@${CLOUDFLARE_DNS_VERSION} \
      --with github.com/caddy-dns/rfc2136@${RFC2136_DNS_VERSION}

# Docker Official Image index for 2.11.9-alpine.
FROM caddy@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
ARG CADDY_VERSION
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
RUN version="$(caddy version)" \
 && test "${version%% *}" = "v${CADDY_VERSION}" \
 && modules="$(caddy list-modules)" \
 && printf '%s\n' "$modules" | grep -Fx 'dns.providers.cloudflare' \
 && printf '%s\n' "$modules" | grep -Fx 'dns.providers.rfc2136'
