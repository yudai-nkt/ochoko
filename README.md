# ochoko

A single-user ActivityPub server written in Gleam (Erlang target), with a
`shared` package holding Mastodon API types that compile to both Erlang and
JavaScript.

## Layout

- `server/` - the ActivityPub / Mastodon API server (Erlang target)
- `shared/` - Mastodon API types shared between targets

## Setup

Tools (Gleam, Erlang/OTP, rebar3, Node.js for the JavaScript-target tests) are managed with [aqua](https://aquaproj.github.io/):

```sh
aqua policy allow aqua-policy.yaml   # once, to permit the local registry
aqua i -l
```

A C compiler (Xcode Command Line Tools on macOS) is required to build NIF
dependencies such as `sqlight` and `argus`.

## Development

```sh
cd server && gleam test
cd shared && gleam test && gleam test --target javascript
```

The JavaScript test run uses Node.js, provided by aqua.
