#!/usr/bin/env bash
# Run the federation e2e tests: certificates, stack, Mastodon setup, driver.
# Leaves the stack running when KEEP=1 (inspect with `docker compose logs`).
set -euo pipefail
cd "$(dirname "$0")"

compose() { docker compose "$@"; }

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- e2e failed; service logs follow ---" >&2
    compose logs --no-color --tail=200 proxy ochoko mastodon-web mastodon-sidekiq >&2 || true
  fi
  if [ "${KEEP:-0}" != 1 ]; then
    compose --profile runner down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

# Certificates from a throwaway CA; CAROOT keeps mkcert away from the host
# trust store (we never run `mkcert -install`).
if [ ! -f certs/cert.pem ]; then
  mkdir -p certs
  CAROOT="$PWD/certs" mkcert -cert-file certs/cert.pem -key-file certs/key.pem \
    ynkt.test ochoko.ynkt.test mastodon.test
  chmod 644 certs/*.pem
fi

compose --profile runner build
compose up -d --wait proxy ochoko mastodon-db mastodon-redis
echo "Preparing Mastodon..."
MASTODON_TOKEN=$(compose run --rm --no-deps mastodon-web /setup.sh | tail -n 1)
export MASTODON_TOKEN
compose up -d --wait mastodon-web mastodon-sidekiq
compose run --rm runner
