FROM python:3.12.16-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

# Debian security floor for CVE-2026-85091. Fail the build if the signed
# repositories cannot supply the fix or a newer version.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends --only-upgrade zlib1g; \
    dpkg --compare-versions "$(dpkg-query -W -f='${Version}' zlib1g)" ge '1:1.3.dfsg+really1.3.1-1+deb13u1'; \
    rm -rf /var/lib/apt/lists/*
