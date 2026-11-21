# End-to-end tests

Two suites run ochoko against real software in Docker (`e2e/`). Design:
`docs/superpowers/specs/2026-11-21-e2e-federation-design.md`.

| Suite | Command | Driver | What it proves |
| --- | --- | --- | --- |
| federation | `e2e/run.sh federation` | `e2e/runner` (Gleam) | ochoko and Mastodon follow, post, delete and unfollow each other through their APIs |
| elk | `e2e/run.sh elk` | `e2e/elk` (Playwright) | a self-hosted Elk works as ochoko's client, automating most of `elk-smoke-test.md` |

Both need Docker and mkcert (from aqua). `KEEP=1` leaves the stack running;
inspect it with `docker compose -f e2e/compose.yaml --profile elk logs`. CI
runs both suites in `.github/workflows/e2e.yml`; a failed Elk run uploads the
Playwright report, traces and screenshots as the `elk-test-results` artifact.

## Stack

| Name | Service |
| --- | --- |
| `ynkt.test` | account domain; Caddy redirects `/.well-known/webfinger` to ochoko |
| `ochoko.ynkt.test` | ochoko, `@yudai@ynkt.test` (password `e2e-password`) |
| `mastodon.test` | Mastodon v4.7.6, `@alice@mastodon.test` |
| `elk.test` | Elk v1.0.1 (elk suite only) |

Caddy terminates TLS for every name with a certificate from a throwaway CA in
`e2e/certs/` (never added to the host trust store) and carries all names as
network aliases. Each container trusts the CA its own way: Mastodon through
`SSL_CERT_FILE`, Elk and Playwright's Node side through
`NODE_EXTRA_CA_CERTS`, Chromium through its NSS database, ochoko and the Gleam
driver through the OS store.

## Findings

### mist rejected raw `[` `]` in the query

Found by the elk suite on 2026-11-21: Elk's Follow button spun forever.

**What happened.** Elk (through masto.js) requests
`GET /api/v1/accounts/relationships?id[]=1` with the brackets unencoded. mist
6.0.3 parses the request target with Erlang's `uri_string:parse/1`, which
returns `{error, invalid_uri, "["}`; mist logs "Received invalid HTTP path"
and closes the connection without a response, so the CORS preflight failed in
the browser and Caddy answered 502. The same code is on mist's main branch.

**RFC 3986.** The request is non-conforming. RFC 3986 §3.4 defines
`query = *( pchar / "/" / "?" )` and `pchar` admits only unreserved,
pct-encoded, sub-delims, `:` and `@`; `[` and `]` are gen-delims (§2.2) and
must be sent as `%5B` / `%5D` in a query. RFC 9112's origin-form reuses that
`query` rule, so the request line is outside HTTP/1.1's grammar too, and
`uri_string` is right by the letter.

**Why it happens anyway.** Browsers implement the WHATWG URL Standard, whose
query percent-encode set does not contain `[` or `]`, so `fetch()` sends them
as written. masto.js builds `id[]=` (the Rack/Rails convention the Mastodon
API documents) and passes it to `fetch()`. Every Mastodon client running in a
browser can therefore send raw brackets.

**Other servers and proxies** (checked 2026-11-21 with `curl -g`, which sends
the brackets raw):

| Software | Result |
| --- | --- |
| mist 6.0.3 (Hex) | connection closed, no response |
| Puma 8.0.4 (Mastodon v4.7.6) | accepted (401 from the app: no token) |
| nginx 1.29.8 | accepted (200) |
| Caddy v2.10.2 | accepted and forwarded unchanged |
| Node.js v26.13.0 `http` | accepted (200), `req.url` keeps the brackets |

**Fix.** ochoko depends on a fork, `yudai-nkt/mist` (branch
`fix/raw-brackets-in-query`, pinned by commit in `server/gleam.toml`). When
`uri_string:parse/1` fails on an origin-form target it splits at the first
`?` and keeps both parts byte for byte, which also keeps HTTP Signature
`(request-target)` strings intact. The fork carries a mist test; ochoko's
`app_test.accepts_raw_brackets_in_query_test` sends the raw request over a
socket and fails on the Hex release. An upstream PR to `rawhat/mist` is
prepared but not opened yet; return to the Hex release once a fixed version
is published.

When switching back, run `gleam clean` in `server/`: the fork and the Hex
release both say 6.0.3, and Gleam keeps the cached package of the same
version, so the regression test can pass against stale code.

A proxy-side workaround also works (Caddy:
`@raw_brackets expression {query}.contains("[") || {query}.contains("]")`
plus `uri @raw_brackets query -unused`, since any `uri query` operation
re-encodes the query). It was not adopted because it ties correctness to the
proxy configuration.

### Elk took the handle's domain from the server host

Elk seeds its instance record with `accountDomain` set to the server it logged
in to and only overwrites it with a fetched `account_domain`, a GoToSocial
extension. Without it Elk showed `@yudai@ochoko.ynkt.test` on first login and
`@yudai@ynkt.test` only after a reload. The instance endpoints now return
`account_domain` (the account domain).

### Elk without streaming

Elk removes a deleted post from a timeline on streaming `delete` events. ochoko
has no streaming API, so a post deleted in Elk stays on screen until the next
load; the deletion itself works and federates. New posts likewise appear on
reload. This is the current answer to checklist item 11 of
`elk-smoke-test.md`.

### Posts right after a new follower

Mastodon records a follow as a request until our Accept arrives and drops
posts it receives in that window. Both suites wait for Mastodon to report the
follow before posting.

### Endpoints Elk calls that ochoko answers with 404

The elk suite prints them at the end and writes
`e2e/elk/test-results/ochoko-404.txt`.

| Method and path | Called by | Decision |
| --- | --- | --- |
| `GET /api/v1/push/subscription` | login (web push state) | keep 404; Elk treats it as "no subscription" |
| `GET /nodeinfo/2.0` | login (GoToSocial detection) | keep 404 until NodeInfo is implemented |

### Not yet fixed

- Elk shows a remote account's join date as January 1, 1970: ochoko does not
  record `created_at` for remote actors.
