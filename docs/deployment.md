# Deployment

ochoko is a single-user ActivityPub server. It runs as one Erlang VM behind a
reverse proxy that terminates TLS, so it works the same on a VPS or on a home
server (with port forwarding or a tunnel). The server binds to `127.0.0.1` only.

The examples use the account `@yudai@ynkt.me`, served from `ochoko.ynkt.me`.

## Build

```sh
aqua policy allow aqua-policy.yaml   # once
aqua i -l
cd server
gleam export erlang-shipment
```

The release is written to `server/build/erlang-shipment/`. Copy that directory
to the target machine (the machine needs no Gleam, but the same Erlang/OTP
major version and glibc/libc as the build machine, because `sqlight` and
`argus` ship NIFs).

Run commands through the shipment entrypoint:

```sh
build/erlang-shipment/entrypoint.sh run <command> ...
```

The examples below write `ochoko <command>` for that.

## Configuration

Copy `server/ochoko.example.toml` and edit it. Fields:

| Field | Meaning |
| --- | --- |
| `account_domain` | Domain in the handle (`ynkt.me` in `@yudai@ynkt.me`) |
| `host` | Host serving ActivityPub (`ochoko.ynkt.me`; actor id is `https://{host}/me`) |
| `handle` | Local part of the handle (`yudai`) |
| `listen_port` | Local TCP port (default 8000) |
| `database_path` | SQLite file |
| `private_key_path` | PEM RSA key used to sign outgoing requests |
| `password_hash` | Argon2id hash for the login password |
| `secret_key_base` | Long random string signing session cookies |

### First-time setup

```sh
# 1. Signing key (written with mode 0600; the public key is printed).
ochoko keygen /var/lib/ochoko/ochoko.pem

# 2. Password hash: reads the password from stdin, prints the hash.
ochoko hash-password

# 3. Put the hash and a random secret_key_base into the config, then set the profile.
ochoko profile --config /etc/ochoko/ochoko.toml \
  --display-name "Yudai" --note "Hello" --avatar-url https://example.com/a.png

# 4. Run.
ochoko serve --config /etc/ochoko/ochoko.toml
```

`serve` migrates the database on start, then runs the delivery worker and the
HTTP server under a supervisor. Requests are logged to stdout as
`INFO <status> <METHOD> <path>` (no query string), for example
`INFO 404 GET /api/v1/foo`; this is also how to spot unimplemented API
endpoints (see `elk-smoke-test.md`).

Failure behavior: if the port cannot be bound or the key, config or database
cannot be loaded, `serve` prints `error: ...` and exits with status 1. If the
supervisor later gives up (its restart intensity is exceeded), `serve` also
prints an error and exits with status 1, so `Restart=on-failure` in the systemd
unit below restarts it.

## Reverse proxy

Inbound HTTP Signatures from other servers sign the `host` and
`(request-target)` pseudo-header, so the proxy MUST:

- pass the original `Host` header unchanged (`ochoko.ynkt.me`), and
- not rewrite, normalize or percent-decode the request path.

### Caddy

```caddyfile
ochoko.ynkt.me {
    reverse_proxy 127.0.0.1:8000
}
```

`reverse_proxy` keeps the incoming `Host` header by default, and Caddy obtains
TLS certificates automatically. Do not add `header_up Host ...` and do not use
`rewrite`/`uri` directives on this site. Caddy also sets `X-Forwarded-For`,
`X-Forwarded-Proto` and `X-Forwarded-Host` itself. ochoko does not read them;
it builds all URLs from `host` in the config.

### nginx

```nginx
location / {
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_pass http://127.0.0.1:8000;   # no URI part, so the path is passed as sent
}
```

Writing `proxy_pass http://127.0.0.1:8000/;` (with a trailing slash or any URI)
makes nginx normalize and re-encode the path, which breaks signature
verification for such paths. Terminate TLS in nginx as usual.

### Path decoding finding

mist (6.x) parses the request target with Erlang's `uri_string:parse/1`, which
does not percent-decode the path, and wisp (2.x) `path_segments` splits the
raw path on `/` without decoding. So `req.path` reaches ochoko exactly as the
proxy sent it, and the string verified against the signature matches what the
remote server signed. (Checked with `uri_string:parse("/a%2Fb/%41")`, which
returns `"/a%2Fb/%41"`.) Consequence: a route segment containing an encoded
character is compared in its encoded form. This is harmless today because all
ids in ochoko's routes are plain ASCII, but any future route with encoded
characters in a signed path must decode explicitly. Dot segments (`..`) are
removed by `path_segments` for routing only; the signed string is untouched.

## WebFinger on `ynkt.me`

The handle is `@yudai@ynkt.me` but the server lives at `ochoko.ynkt.me`, so
`ynkt.me` must answer `/.well-known/webfinger` and point to the actor. Serve
this JRD statically from `ynkt.me` at `/.well-known/webfinger` with
`Content-Type: application/jrd+json`:

```json
{
  "subject": "acct:yudai@ynkt.me",
  "aliases": ["https://ochoko.ynkt.me/me"],
  "links": [
    {
      "rel": "self",
      "type": "application/activity+json",
      "href": "https://ochoko.ynkt.me/me"
    }
  ]
}
```

Remote servers request `/.well-known/webfinger?resource=acct:yudai@ynkt.me`.
A static file ignores the query string, which is fine because there is exactly
one user on the domain.

Alternative: redirect to ochoko, which answers the same query itself
(it also knows `acct:yudai@ynkt.me`):

```caddyfile
ynkt.me {
    redir /.well-known/webfinger https://ochoko.ynkt.me{uri} 302
}
```

(nginx: `location = /.well-known/webfinger { return 302 https://ochoko.ynkt.me$request_uri; }`.)
Some servers follow redirects less reliably than a direct answer, so the
static JRD is preferred.

## Logging in with Elk

At <https://elk.zone>, enter `ochoko.ynkt.me` as the server (not `ynkt.me`),
then approve the authorization on ochoko's login page with the password whose
hash is in the config.

## systemd

```ini
# /etc/systemd/system/ochoko.service
[Unit]
Description=ochoko ActivityPub server
After=network-online.target
Wants=network-online.target

[Service]
User=ochoko
Group=ochoko
WorkingDirectory=/opt/ochoko
ExecStart=/opt/ochoko/erlang-shipment/entrypoint.sh run serve --config /etc/ochoko/ochoko.toml
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/ochoko

[Install]
WantedBy=multi-user.target
```

```sh
sudo useradd --system --home /var/lib/ochoko --create-home ochoko
sudo systemctl daemon-reload
sudo systemctl enable --now ochoko
journalctl -u ochoko -f
```

Keep `database_path` and `private_key_path` under `/var/lib/ochoko`, and make
the config readable only by the `ochoko` user (it holds the password hash and
`secret_key_base`).

## Backups

The database is SQLite in WAL mode: do not copy the `.db` file alone while the
server runs (the `-wal` file holds recent writes). Use one of:

- [Litestream](https://litestream.io/) for continuous replication of the
  database to object storage or another disk.
- A periodic consistent snapshot: `sqlite3 /var/lib/ochoko/ochoko.db ".backup '/backups/ochoko-$(date +%F).db'"`.

The private key file (`private_key_path`) must be backed up too. It is not in
the database, and losing it changes the actor's public key: remote servers
that cached the old key will reject your activities, which effectively breaks
the federation identity. Store it somewhere separate from the database backups
and treat it as a secret.
