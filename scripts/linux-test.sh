#!/usr/bin/env bash
# Builds and tests the platform-independent core (MacSecurityCore) inside the
# official Swift 6.0 Linux image. Apple-only files compile to empty units; the
# macOS-specific tests are skipped. Use `swift test` on a Mac for full coverage.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${*:-swift test}"
EXTRA=()
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  EXTRA+=(-e "HTTPS_PROXY=${HTTPS_PROXY}" -e "https_proxy=${HTTPS_PROXY}")
fi
if [[ -f /root/.ccr/ca-bundle.crt ]]; then
  EXTRA+=(-v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/proxy-ca.crt:ro -e GIT_SSL_CAINFO=/etc/ssl/certs/proxy-ca.crt -e SSL_CERT_FILE=/etc/ssl/certs/proxy-ca.crt)
fi
docker run --rm --network host "${EXTRA[@]}" \
  -v "$ROOT/MacSecurityAgent:/work" -w /work swift:6.0-noble bash -lc "$CMD"
