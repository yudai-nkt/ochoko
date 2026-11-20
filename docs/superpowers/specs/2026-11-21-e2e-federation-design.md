# Federation e2e tests with Mastodon — Design

Date: 2026-11-21
Status: Approved

## Intent

Prove that ochoko federates with a real Mastodon before the first deployment,
and keep proving it in CI. Unit tests use recorded fixtures; they cannot show
that Mastodon accepts our signatures, resolves our split handle, or delivers
to us.

References: mkizka's Playwright + Docker setup
(<https://zenn.dev/mkizka/articles/0fffa3b147c72a>) for TLS via a local CA and
a hostname-routing proxy, and anqou's KinD setup
(<https://blog.anqou.net/2025/02/activity-pub-e2e-test-in-local/>) for the
Mastodon trust-store and private-address settings.

## Approaches

1. **Docker Compose with a TLS proxy and a Gleam test driver inside the
   network (chosen).** Everything resolves by network aliases, so no host DNS
   or SOCKS proxy is needed.
2. KinD + cert-manager + SOCKS (anqou). Rejected: Kubernetes adds nothing for
   two servers.
3. Browser-driven tests (Playwright, mkizka). Rejected: both servers have
   APIs; UI driving adds flakiness without testing more federation.

## Topology

| Name | Role |
|------|------|
| `ynkt.test` | Account domain. Caddy redirects `/.well-known/webfinger` to ochoko, as `docs/deployment.md` describes for `ynkt.me`. |
| `ochoko.ynkt.test` | ochoko (`@yudai@ynkt.test`), mirroring `ochoko.ynkt.me`. |
| `mastodon.test` | Mastodon (`@alice@mastodon.test`), web + sidekiq + postgres + redis. |

- Caddy terminates TLS for all three names with a certificate from mkcert
  (installed via aqua, never added to the host trust store) and carries all
  three as network aliases.
- Mastodon trusts the CA via `SSL_CERT_FILE` and allows the Docker subnet via
  `ALLOWED_PRIVATE_ADDRESSES`. ochoko and the driver add the CA to the OS
  store at container start.
- ochoko needs to bind a non-loopback interface: `listen_address` (default
  `127.0.0.1`) is added to the config.

## Driver

A separate Gleam package, `e2e/runner`, run with `gleam run` in a container
on the network. It obtains an ochoko token through the real OAuth flow (app
registration, login form, PKCE) and a Mastodon token from `rails runner`.
Each step polls with a deadline instead of fixed sleeps; the first failure
exits non-zero. gleeunit is not used because its per-test timeout is too
short for federation round trips.

Scenario, in order:

1. ochoko resolves `@alice@mastodon.test` and follows; Mastodon's Accept
   arrives; Mastodon lists `yudai@ynkt.test` as a follower.
2. A Mastodon post reaches ochoko's home timeline; its deletion removes it.
3. Mastodon resolves `@yudai@ynkt.test` (split domain) and follows; ochoko
   auto-accepts and shows a follow notification.
4. ochoko's public and unlisted posts reach Mastodon's home timeline with the
   right visibility; deleting one removes it there.
5. ochoko removes alice from its followers; Mastodon no longer follows.
6. ochoko unfollows alice; Mastodon no longer lists the follower.

## Operation

- `e2e/run.sh` generates certificates, builds and starts the stack, prepares
  Mastodon, runs the driver, dumps logs on failure, and tears down.
- A separate GitHub Actions workflow runs it; actions are pinned with pinact,
  images by digest.
