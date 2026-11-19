# Elk smoke test

Manual end-to-end check of ochoko with the Elk web client against a deployed
server (see `deployment.md`). It needs a public deployment, so **none of these
steps has been run yet**. Fill in the results table as you go.

Prerequisites: ochoko running at `https://ochoko.ynkt.me`, WebFinger for
`acct:yudai@ynkt.me` served from `ynkt.me`, and a Mastodon account on another
server (the "remote account") for the steps that need one.

## Checklist

1. Not yet run. Log in at <https://elk.zone> with server `ochoko.ynkt.me`.
2. Not yet run. Open the home timeline, notifications and own profile; all load without errors.
3. Not yet run. Search `@Gargron@mastodon.social` and follow.
4. Not yet run. Confirm the Accept arrives (the relationship flips to following).
5. Not yet run. Post a public status and an unlisted status.
6. Not yet run. See both statuses from the remote account (the unlisted one by direct URL).
7. Not yet run. Follow ochoko from the remote account and confirm the notification in Elk.
8. Not yet run. Delete a status and confirm it disappears remotely.
9. Not yet run. Search `@yudai@ynkt.me` from the remote account's Mastodon search and confirm it resolves.
10. Not yet run. Record every endpoint Elk calls that returns 404 (see below); add it to the stubs (`server/src/ochoko/api/stubs.gleam`) or note why not.
11. Not yet run. **Confirm whether Elk is usable without streaming.** If it is not, stop: streaming must be pulled forward into a new plan.

## Results

| # | Step | Result | Date | Notes |
| --- | --- | --- | --- | --- |
| 1 | Log in with `ochoko.ynkt.me` | not yet run | | |
| 2 | Home, notifications, profile load | not yet run | | |
| 3 | Search and follow `@Gargron@mastodon.social` | not yet run | | |
| 4 | Accept arrives, relationship is following | not yet run | | |
| 5 | Post public and unlisted statuses | not yet run | | |
| 6 | Statuses visible from remote account | not yet run | | |
| 7 | Remote follow and notification | not yet run | | |
| 8 | Delete propagates | not yet run | | |
| 9 | `@yudai@ynkt.me` resolves from Mastodon search | not yet run | | |
| 10 | 404 endpoints recorded | not yet run | | |
| 11 | Elk usable without streaming | not yet run | | |

### 404 endpoints

| Method and path | Called by (Elk screen) | Decision (stub added / why not) |
| --- | --- | --- |
| | | |

## Finding 404'd endpoints in the server log

`serve` logs every request to stdout through wisp's request logger, one line
per request in the form `INFO <status> <METHOD> <path>` (no query string),
for example `INFO 404 GET /api/v1/foo`. While exercising Elk, filter the log
for 404s:

```sh
journalctl -u ochoko --since "10 min ago" | grep -E 'INFO 404 '
# or, when run in a terminal:
ochoko serve --config ochoko.toml 2>&1 | tee ochoko.log
grep -E 'INFO 404 ' ochoko.log
```

Ignore paths unrelated to the client API (for example `/favicon.ico`, scanners
and bots). For each `/api/...` path that Elk requests, check whether the
response matters to the screen that triggered it. Empty-but-valid stubs (an
empty array or object) are usually enough; record the decision in the table.
Paths under `/api` that are not routed explicitly fall through to the stub
handler, so a 404 there means the stub handler deliberately declined it.
