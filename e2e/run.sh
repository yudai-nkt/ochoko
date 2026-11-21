#!/usr/bin/env bash
# Run an e2e suite against ochoko and Mastodon in Docker:
#   run.sh federation   Gleam driver talking to both APIs (default)
#   run.sh elk          Playwright driving a self-hosted Elk against ochoko
# Leaves the stack running when KEEP=1 (inspect with `docker compose logs`).
set -euo pipefail
cd "$(dirname "$0")"

suite=${1:-federation}
case "$suite" in
  federation) profile=runner; driver=runner; extra=() ;;
  elk) profile=elk; driver=browser; extra=(elk) ;;
  *) echo "usage: $0 [federation|elk]" >&2; exit 2 ;;
esac

compose() { docker compose --profile "$profile" "$@"; }

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- e2e failed; service logs follow ---" >&2
    compose logs --no-color --tail=200 proxy ochoko mastodon-web mastodon-sidekiq ${extra[@]+"${extra[@]}"} >&2 || true
  fi
  if [ "${KEEP:-0}" != 1 ]; then
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

# Certificates from a throwaway CA; CAROOT keeps mkcert away from the host
# trust store (we never run `mkcert -install`).
if [ ! -f certs/cert.pem ]; then
  mkdir -p certs
  CAROOT="$PWD/certs" mkcert -cert-file certs/cert.pem -key-file certs/key.pem \
    ynkt.test ochoko.ynkt.test mastodon.test elk.test
  chmod 644 certs/*.pem
fi

compose build
compose up -d --wait proxy ochoko mastodon-db mastodon-redis ${extra[@]+"${extra[@]}"}
echo "Preparing Mastodon..."
MASTODON_TOKEN=$(compose run --rm --no-deps mastodon-web /setup.sh | tail -n 1)
export MASTODON_TOKEN
compose up -d --wait mastodon-web mastodon-sidekiq
compose run --rm "$driver"
