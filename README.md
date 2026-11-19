# ochoko

A single-user ActivityPub server written in Gleam (Erlang target), with a
`shared` package holding Mastodon API types that compile to both Erlang and
JavaScript.

## Overview

ochoko serves one account (for example `@yudai@ynkt.me`) with ActivityPub
federation, the subset of the Mastodon client API that web clients such as Elk
need, an OAuth login, SQLite storage and a background delivery queue. Run it
with `ochoko serve --config ochoko.toml` behind a TLS-terminating reverse proxy.

- [docs/deployment.md](docs/deployment.md): build, configuration, reverse proxy, WebFinger, systemd, backups
- [docs/elk-smoke-test.md](docs/elk-smoke-test.md): manual end-to-end checklist with Elk (not yet run)

## Layout

- `server/` - the ActivityPub / Mastodon API server (Erlang target)
- `shared/` - Mastodon API types shared between targets

## Setup

Tools (Gleam, Erlang/OTP, rebar3, Node.js for the JavaScript-target tests) are managed with [aqua](https://aquaproj.github.io/):

```sh
aqua policy allow aqua-policy.yaml   # once, to permit the local registry
aqua i -l
```

Editing `aqua-policy.yaml` invalidates the approval, so re-run `aqua policy allow aqua-policy.yaml` afterwards.

A C compiler (Xcode Command Line Tools on macOS) is required to build NIF
dependencies such as `sqlight` and `argus`.

## Development

```sh
cd server && gleam test
cd shared && gleam test && gleam test --target javascript
```

The JavaScript test run uses Node.js, provided by aqua.
