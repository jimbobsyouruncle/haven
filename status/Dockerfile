FROM python:3.15.2-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928

# Debian security floor for CVE-2026-85091. Fail the build if the signed
# repositories cannot supply the fix or a newer version.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends --only-upgrade zlib1g; \
    dpkg --compare-versions "$(dpkg-query -W -f='${Version}' zlib1g)" ge '1:1.3.dfsg+really1.3.1-1+deb13u1'; \
    rm -rf /var/lib/apt/lists/*
