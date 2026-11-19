# ochoko MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single-user ActivityPub server that lets its owner follow remote people, read their posts in Elk, post text, and be followed.

**Architecture:** One Gleam OTP application (Erlang target) serving HTTP with mist + wisp, persisting to SQLite via sqlight, and draining a SQLite-backed delivery queue with OTP workers. Mastodon API entity types live in a separate `shared` package (Erlang + JavaScript targets) so a future Lustre client can import them. Inbound ActivityPub JSON goes through hand-written lenient decoders into normalised internal types.

**Tech Stack:** Gleam 1.19.2, Erlang/OTP 28, rebar3, gleam_stdlib, gleam_erlang, gleam_otp, gleam_http, gleam_httpc, gleam_json, gleam_crypto, gleam_time, wisp 2, mist 6, sqlight, tom, simplifile, argus, gleeunit; Erlang `public_key`, `inets` (`httpd_util`) and `mochiweb` (`mochiweb_html`) via FFI.

**Spec:** `docs/superpowers/specs/2026-11-19-ochoko-design.md`

## Global Constraints

- Exactly one user. No `users` table, no `user_id` column, no "owner" foreign key anywhere.
- Identity values come from config: account domain `ynkt.me`, host `ochoko.ynkt.me`, handle `yudai`. Never hard-code them outside tests.
- Actor ID is `https://{host}/me`; key ID `https://{host}/me#main-key`; inbox `https://{host}/me/inbox`; shared inbox `https://{host}/inbox`; followers `https://{host}/me/followers`; following `https://{host}/me/following`; outbox `https://{host}/me/outbox`; own note IDs `https://{host}/statuses/{id}`. These URL shapes are permanent once deployed.
- `/me` serves ActivityPub JSON only; requests whose `Accept` prefers `text/html` get `302` to the actor's `url`, which is `https://{host}/profile` (the page itself is after the MVP; `/profile` may 404 for now).
- WebFinger subject is `acct:{handle}@{account_domain}` on `ochoko.ynkt.me` too.
- Outgoing posts: `public` and `unlisted` only. Anything else (and `in_reply_to_id`, `media_ids`, `poll`) → `422` with Mastodon error JSON `{"error": "..."}`.
- Incoming follows are auto-accepted; actor document has `manuallyApprovesFollowers: false`.
- HTTP Signatures are draft-cavage, `rsa-sha256` (accept `hs2019` as RSA-SHA256 on verify). RFC 9421 is out of scope.
- No authorized fetch: GETs of actor and objects are unauthenticated; our own outbound GETs are signed anyway.
- SQLite opens in WAL mode with `foreign_keys = ON` and `busy_timeout = 5000`.
- Mastodon entities: nullable fields are emitted as JSON `null`; optional fields are omitted. Never collapse one into the other.
- All API responses carry CORS headers (Elk runs on another origin).
- Commit messages follow Conventional Commits and end with the attribution trailer required by the session.

## Review Focus

1. **Signature edge cases** — a POST whose `Date` is older than 12 h or more than 1 h in the future, whose `Digest` doesn't match the body, or whose key was rotated since we cached it. Expected: the first two → `401`; rotation → re-fetch the key once and accept if it now verifies. (Task 9)
2. **Spoofed actors** — a validly signed activity whose `actor` (or a note's `attributedTo`, or a `Delete`'s target) belongs to someone other than the signer. Expected: rejected with `401` / silently ignored, never stored. (Tasks 9, 11)
3. **Duplicate deliveries** — the same activity or the same note arriving twice (retries are normal on the Fediverse), or a repeat `Follow` from an existing follower. Expected: no duplicate statuses, followers or notifications; a repeat `Follow` is re-`Accept`ed. (Tasks 9, 11)
4. **Dead or hostile remote servers** — an inbox answering `410`/`404`, timing out, or answering `500` forever. Expected: permanent 4xx dropped at once, retryable failures given up after the backoff schedule, and one slow host never blocks deliveries to others. (Task 8)
5. **Hostile HTML** — `<script>`, `javascript:` links, inline event handlers or `style` in remote `content`/`summary`; `<`, `&` in the owner's own text. Expected: sanitised/escaped before reaching Elk. (Task 10)

---

## File Structure

```
mise.toml                          toolchain pins
README.md                          dev setup + commands
docs/deployment.md                 reverse proxy, ynkt.me WebFinger, backups, Elk login
shared/                            gleam package `ochoko_shared` (erlang + javascript)
  src/ochoko_shared/mastodon.gleam entity types + JSON encoders
  test/...
server/                            gleam package `ochoko` (erlang)
  gleam.toml                       depends on shared via path
  src/ochoko.gleam                 CLI entry: serve | keygen | hash-password | profile | fetch
  src/ochoko/config.gleam          TOML config
  src/ochoko/context.gleam         Context record passed to handlers
  src/ochoko/db.gleam              open/with_connection, migrate
  src/ochoko/db/migrations.gleam   ordered SQL migrations
  src/ochoko/id.gleam              time-sortable IDs
  src/ochoko/crypto/rsa.gleam      + ochoko_rsa_ffi.erl
  src/ochoko/http_date.gleam       + ochoko_http_date_ffi.erl
  src/ochoko/http_client.gleam     Send type + httpc impl
  src/ochoko/signature.gleam       HTTP Signatures + Digest
  src/ochoko/html.gleam            text→HTML, sanitise; + ochoko_html_ffi.erl
  src/ochoko/federation/ap_decode.gleam     lenient decode helpers
  src/ochoko/federation/remote_actor.gleam  decode, fetch, cache, webfinger lookup
  src/ochoko/federation/local_actor.gleam   our Person / WebFinger / collections JSON
  src/ochoko/federation/activities.gleam    outbound activity JSON builders
  src/ochoko/federation/note.gleam          inbound Note decode + visibility
  src/ochoko/federation/inbox.gleam         verify + dispatch
  src/ochoko/federation/delivery.gleam      queue + worker actor
  src/ochoko/store/*.gleam         one module per table group (profile, remote_actors,
                                   follows, statuses, notifications, oauth, deliveries)
  src/ochoko/web/router.gleam      routing, CORS, content negotiation
  src/ochoko/web/federation.gleam  /.well-known, /me*, /inbox, /statuses/:id
  src/ochoko/api/*.gleam           Mastodon API handlers (oauth, apps, instance,
                                   accounts, statuses, timelines, notifications,
                                   search, stubs, auth, pagination, present)
  priv/static/avatar.png           default avatar/header
  test/fixtures/ap/                real inbound payloads + SOURCES.md
  test/...                         mirrors src/
```

Shared test helpers (written in Task 3, extended later): `test/support.gleam` with `fresh_db() -> sqlight.Connection` (in-memory, migrated), `test_config() -> Config`, `test_context(db, send) -> Context` with a fixed clock, and `fake_send(routes: List(#(String, Response(String)))) -> http_client.Send`.

---

### Task 1: Toolchain, monorepo scaffold, health endpoint

**Files:**
- Create: `mise.toml`, `.gitignore`, `README.md`, `shared/gleam.toml`, `shared/src/ochoko_shared.gleam`, `shared/test/ochoko_shared_test.gleam`, `server/gleam.toml`, `server/src/ochoko.gleam`, `server/src/ochoko/web/router.gleam`, `server/test/ochoko_test.gleam`, `server/test/ochoko/web/router_test.gleam`

**Interfaces:**
- Produces: `router.handle_request(req: wisp.Request, ctx: Context) -> wisp.Response` (Context is a placeholder `Nil`-free record until Task 2; use a temporary `pub type Context { Context }` in `ochoko/context.gleam`).

- [ ] **Step 1:** `mise.toml` pins `gleam = "1.19.2"`, `erlang = "28"`, `rebar3 = "latest"`; run `mise install`. Expected: `gleam --version` prints `gleam 1.19.2`.
- [ ] **Step 2:** `gleam new shared --name ochoko_shared` and `gleam new server --name ochoko`. In `shared/gleam.toml` leave `target` unset (both targets). In `server/gleam.toml` set `target = "erlang"` and add `ochoko_shared = { path = "../shared" }` plus the Tech Stack deps (`gleam add` each in `server/`).
- [ ] **Step 3: Write the failing test** `router_test.health_test`:

```gleam
pub fn health_test() {
  let res = router.handle_request(simulate.request(http.Get, "/health"), test_ctx())
  assert res.status == 200
  assert simulate.read_body(res) == "ok"
}
```

- [ ] **Step 4:** `cd server && gleam test` → FAIL (module missing).
- [ ] **Step 5:** Implement `handle_request` with `wisp.path_segments` routing; `/health` → `200 "ok"`, everything else → `404`.
- [ ] **Step 6:** `gleam test` in `server/` and `gleam test --target javascript` + `gleam test` in `shared/` → PASS.
- [ ] **Step 7:** Commit `chore: scaffold gleam monorepo with health endpoint`.

---

### Task 2: Config, Context and CLI skeleton

**Files:**
- Create: `server/src/ochoko/config.gleam`, `server/test/ochoko/config_test.gleam`, `server/ochoko.example.toml`
- Modify: `server/src/ochoko/context.gleam`, `server/src/ochoko.gleam`

**Interfaces:**
- Produces:
  ```gleam
  pub type Config {
    Config(account_domain: String, host: String, handle: String,
           listen_port: Int, database_path: String, private_key_path: String,
           password_hash: String, secret_key_base: String)
  }
  pub fn parse(toml: String) -> Result(Config, String)
  pub fn load(path: String) -> Result(Config, String)
  pub fn actor_id(c: Config) -> String        // "https://{host}/me"
  pub fn key_id(c: Config) -> String          // actor_id <> "#main-key"
  pub fn acct(c: Config) -> String            // "{handle}@{account_domain}"
  ```
  `Context(config: Config, db_path: String, send: http_client.Send, now: fn() -> Timestamp, private_key: rsa.PrivateKey)` — the `send`/`private_key` fields are added in Tasks 4/7 when their types exist; declare them then.
- CLI (`ochoko.main`, args via `argv` package or `erlang:init:get_plain_arguments` FFI): `serve --config PATH`, `keygen OUT_PATH`, `hash-password`, `profile --config PATH [--display-name S] [--note S] [--avatar-url S]`, `fetch --config PATH URL`. In this task only argument parsing and `serve` stub exist; each command is filled in by the task that owns it.

- [ ] **Step 1: Write failing tests** `parse_ok_test` (full example TOML → `Config` with `account_domain: "ynkt.me"`, `host: "ochoko.ynkt.me"`, `handle: "yudai"`), `parse_missing_key_test` (missing `host` → `Error` mentioning `host`), `derived_urls_test` (`actor_id` = `"https://ochoko.ynkt.me/me"`, `key_id` = `"https://ochoko.ynkt.me/me#main-key"`, `acct` = `"yudai@ynkt.me"`).
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement with `tom`. `ochoko.example.toml` documents every key.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: load configuration from TOML`.

---

### Task 3: Database, migrations, single-row profile, IDs

**Files:**
- Create: `server/src/ochoko/db.gleam`, `server/src/ochoko/db/migrations.gleam`, `server/src/ochoko/id.gleam`, `server/src/ochoko/store/profile.gleam`, `server/test/support.gleam`, `server/test/ochoko/db_test.gleam`, `server/test/ochoko/id_test.gleam`
- Modify: `server/src/ochoko.gleam` (`profile` command)

**Interfaces:**
- Produces:
  ```gleam
  // db
  pub fn open(path: String) -> Result(sqlight.Connection, sqlight.Error)  // applies pragmas
  pub fn with_connection(path: String, f: fn(sqlight.Connection) -> a) -> a
  pub fn migrate(conn: sqlight.Connection) -> Result(Nil, sqlight.Error)  // uses PRAGMA user_version
  // id
  pub fn generate(at: Timestamp) -> Int     // (unix_ms << 16) | low 16 bits from erlang:unique_integer
  pub fn floor(at: Timestamp) -> Int        // (unix_ms << 16), for since/max comparisons by time
  // store/profile
  pub type Profile { Profile(display_name: String, note: String, avatar_url: Option(String), header_url: Option(String)) }
  pub fn get(conn) -> Result(Profile, sqlight.Error)
  pub fn update(conn, p: Profile) -> Result(Nil, sqlight.Error)
  ```
- Migration 1 creates (unix seconds as INTEGER for times; every FK to `remote_actors` is `ON DELETE CASCADE`):
  - `profile` exactly as in the spec plus `header_url TEXT`, a seed row `(1, '', '', NULL, NULL)`, and `CREATE TRIGGER profile_no_delete BEFORE DELETE ON profile BEGIN SELECT RAISE(ABORT, 'profile row cannot be deleted'); END;`
  - `remote_actors(id INTEGER PRIMARY KEY, uri TEXT UNIQUE NOT NULL, username TEXT NOT NULL, domain TEXT NOT NULL, display_name TEXT NOT NULL, summary_html TEXT NOT NULL, avatar_url TEXT, header_url TEXT, url TEXT, inbox TEXT NOT NULL, shared_inbox TEXT, followers_uri TEXT, public_key_id TEXT NOT NULL, public_key_pem TEXT NOT NULL, bot INTEGER NOT NULL, locked INTEGER NOT NULL, fetched_at INTEGER NOT NULL)`
  - `following(actor_id INTEGER PRIMARY KEY REFERENCES remote_actors, state TEXT NOT NULL CHECK (state IN ('pending','accepted')), follow_uri TEXT NOT NULL, created_at INTEGER NOT NULL)`
  - `followers(actor_id INTEGER PRIMARY KEY REFERENCES remote_actors, follow_uri TEXT NOT NULL, created_at INTEGER NOT NULL)`
  - `statuses(id INTEGER PRIMARY KEY, uri TEXT UNIQUE NOT NULL, actor_id INTEGER REFERENCES remote_actors /* NULL = own */, content_html TEXT NOT NULL, text TEXT /* own only */, spoiler_text TEXT NOT NULL, sensitive INTEGER NOT NULL, visibility TEXT NOT NULL CHECK (visibility IN ('public','unlisted','private','direct')), url TEXT, in_reply_to_uri TEXT, language TEXT, published_at INTEGER NOT NULL, deleted_at INTEGER)`
  - `media_attachments(id INTEGER PRIMARY KEY, status_id INTEGER NOT NULL REFERENCES statuses ON DELETE CASCADE, remote_url TEXT NOT NULL, media_type TEXT, description TEXT, blurhash TEXT, position INTEGER NOT NULL)`
  - `notifications(id INTEGER PRIMARY KEY, type TEXT NOT NULL CHECK (type IN ('follow')), actor_id INTEGER NOT NULL REFERENCES remote_actors, activity_uri TEXT UNIQUE NOT NULL, created_at INTEGER NOT NULL)`
  - `oauth_apps(id INTEGER PRIMARY KEY, client_id TEXT UNIQUE NOT NULL, client_secret TEXT NOT NULL, name TEXT NOT NULL, website TEXT, redirect_uris TEXT NOT NULL, scopes TEXT NOT NULL, created_at INTEGER NOT NULL)`
  - `oauth_codes(code_hash TEXT PRIMARY KEY, app_id INTEGER NOT NULL REFERENCES oauth_apps ON DELETE CASCADE, redirect_uri TEXT NOT NULL, scopes TEXT NOT NULL, code_challenge TEXT, expires_at INTEGER NOT NULL)`
  - `oauth_tokens(token_hash TEXT PRIMARY KEY, app_id INTEGER NOT NULL REFERENCES oauth_apps ON DELETE CASCADE, kind TEXT NOT NULL CHECK (kind IN ('user','app')), scopes TEXT NOT NULL, created_at INTEGER NOT NULL)`
  - `deliveries(id INTEGER PRIMARY KEY, inbox TEXT NOT NULL, body TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL, locked_until INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)`
  - `processed_activities(uri TEXT PRIMARY KEY, received_at INTEGER NOT NULL)`

- [ ] **Step 1: Write failing tests** in `db_test`:
  - `migrate_is_idempotent_test` — `migrate` twice → `Ok(Nil)`, `PRAGMA user_version` = `1`.
  - `profile_has_exactly_one_row_test` — `SELECT count(*) FROM profile` = `1`.
  - `profile_rejects_second_row_test` — `INSERT INTO profile (id, display_name, note) VALUES (2, 'x', 'y')` → `Error`.
  - `profile_rejects_delete_test` — `DELETE FROM profile` → `Error` whose message contains `profile row cannot be deleted`.
  - `no_user_tables_test` — no table name in `sqlite_master` contains `user`, and no column (via `pragma_table_info`) is named `user_id`.
  - `profile_update_roundtrip_test`.
  - `id_test.ids_are_time_ordered_test` — `generate(t1) < generate(t2)` when `t1` is 1 ms before `t2`; `floor(t) <= generate(t)`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement `db`, `migrations` (a `List(String)` of migration SQL, index+1 = version, each run in a transaction), `id`, `store/profile`, and `support.fresh_db()`.
- [ ] **Step 4:** Wire the `profile` CLI command to `store/profile.update` (this is how the owner sets name/bio/avatar during the MVP; no `Update(Person)` is delivered).
- [ ] **Step 5:** `gleam test` → PASS.
- [ ] **Step 6:** Commit `feat: add SQLite schema with single-row profile`.

---

### Task 4: RSA keys and HTTP dates (FFI)

**Files:**
- Create: `server/src/ochoko/crypto/rsa.gleam`, `server/src/ochoko_rsa_ffi.erl`, `server/src/ochoko/http_date.gleam`, `server/src/ochoko_http_date_ffi.erl`, tests for both
- Modify: `server/src/ochoko.gleam` (`keygen`)

**Interfaces:**
- Produces:
  ```gleam
  pub type PrivateKey   // opaque, wraps the decoded Erlang record
  pub type PublicKey
  pub fn generate(bits: Int) -> PrivateKey                       // 2048 used by keygen
  pub fn private_from_pem(pem: String) -> Result(PrivateKey, Nil)
  pub fn public_from_pem(pem: String) -> Result(PublicKey, Nil)  // accepts "PUBLIC KEY" (SPKI) and "RSA PUBLIC KEY"
  pub fn private_to_pem(k: PrivateKey) -> String
  pub fn public_pem(k: PrivateKey) -> String                     // SPKI "-----BEGIN PUBLIC KEY-----"
  pub fn sign_sha256(k: PrivateKey, data: BitArray) -> BitArray
  pub fn verify_sha256(k: PublicKey, data: BitArray, sig: BitArray) -> Bool
  // http_date
  pub fn format(t: Timestamp) -> String           // IMF-fixdate, e.g. "Sun, 05 Jan 2014 21:31:40 GMT"
  pub fn parse(s: String) -> Result(Timestamp, Nil)
  ```
  FFI uses `public_key:generate_key({rsa, Bits, 65537})`, `public_key:pem_decode/pem_entry_decode/pem_encode`, `public_key:sign/verify` with `sha256`; dates use `httpd_util:rfc1123_date/1` and `httpd_util:convert_request_date/1` (add `inets` to `extra_applications` if needed).

- [ ] **Step 1: Write failing tests:** `sign_verify_roundtrip_test`, `verify_rejects_tampered_data_test`, `pem_roundtrip_test` (private → PEM → private signs the same; `public_pem` parses with `public_from_pem`), `public_from_pem_accepts_pkcs1_test`, `http_date_format_test` (Unix 1388957500 → `"Sun, 05 Jan 2014 21:31:40 GMT"`), `http_date_parse_test` (inverse), `http_date_parse_garbage_test` → `Error(Nil)`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement. `keygen OUT_PATH` writes `private_to_pem(generate(2048))` with mode `0600`.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: add RSA and HTTP date primitives`.

---

### Task 5: HTTP Signatures and Digest

**Files:**
- Create: `server/src/ochoko/signature.gleam`, `server/test/ochoko/signature_test.gleam`

**Interfaces:**
- Consumes: `rsa.*`, `http_date.*`.
- Produces:
  ```gleam
  pub type Parsed { Parsed(key_id: String, algorithm: String, headers: List(String), signature: BitArray) }
  pub type VerifyError { MissingSignature  Malformed  MissingHeader(String)  DateOutOfWindow  DigestMismatch  BadSignature }
  pub fn digest(body: String) -> String                         // "SHA-256=" <> base64(sha256(body))
  pub fn signing_string(req: Request(String), headers: List(String)) -> Result(String, VerifyError)
  pub fn sign(req: Request(String), key: PrivateKey, key_id: String, now: Timestamp) -> Request(String)
     // sets `date`, `host`, and for bodies `digest`; signs "(request-target) host date" (+ " digest" when body non-empty)
  pub fn parse_header(req: Request(String)) -> Result(Parsed, VerifyError)
  pub fn verify(req: Request(String), parsed: Parsed, key: PublicKey, now: Timestamp) -> Result(Nil, VerifyError)
     // checks Date window (now-12h .. now+1h), Digest equals digest(body) when body non-empty,
     // POST must sign "(request-target)", "host", "date", "digest"; then RSA-SHA256
  ```
  `(request-target)` is `lowercase(method) <> " " <> path <> maybe("?" <> query)`. Header names in the signing string are lower-case; values are trimmed.

- [ ] **Step 1: Write failing tests:**
  - `cavage_basic_vector_test` — copy the test private/public key (Appendix C.1) and the "Basic Test" request and expected `signature` (Appendix C.2) **verbatim** from draft-cavage-http-signatures-12; assert `signing_string` matches the draft's text and `sign` produces exactly the draft's signature. Fix the clock to the vector's `Date`.
  - `sign_then_verify_test` (POST with body, generated key).
  - `digest_mismatch_test` — tamper body after signing → `Error(DigestMismatch)`.
  - `date_too_old_test` (now = Date + 12h + 1s → `DateOutOfWindow`), `date_in_future_test` (now = Date − 1h − 1s → `DateOutOfWindow`), `date_at_edge_test` (exactly −12h → `Ok`).
  - `post_without_digest_in_headers_test` → `Error(MissingHeader("digest"))`.
  - `hs2019_algorithm_accepted_test`.
  - `parse_header_malformed_test` → `Error(Malformed)`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: implement draft-cavage HTTP signatures`.

---

### Task 6: Local actor, WebFinger, collections, router basics

**Files:**
- Create: `server/src/ochoko/federation/local_actor.gleam`, `server/src/ochoko/web/federation.gleam`, `server/src/ochoko/store/follows.gleam` (followers count/list only for now), tests
- Modify: `server/src/ochoko/web/router.gleam`, `server/src/ochoko/context.gleam`

**Interfaces:**
- Produces:
  ```gleam
  pub fn actor_json(c: Config, p: Profile, public_pem: String) -> json.Json
  pub fn webfinger_json(c: Config) -> json.Json
  pub fn collection_json(id: String, total: Int) -> json.Json   // OrderedCollection, totalItems only, no items
  // router middleware
  pub fn cors(req, next) -> Response      // OPTIONS → 204; always sets
     // access-control-allow-origin: *, -methods: GET, POST, PUT, PATCH, DELETE, OPTIONS,
     // -headers: Authorization, Content-Type, Idempotency-Key, -expose-headers: Link
  pub fn wants_html(req) -> Bool          // Accept contains text/html and no activity+json / ld+json
  ```
  Actor JSON fields: `@context` `["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"]`, `type: "Person"`, `id`, `preferredUsername` (handle), `name` (display_name, falling back to handle when empty), `summary` (note), `url` (`https://{host}/profile`), `inbox`, `outbox`, `followers`, `following`, `endpoints.sharedInbox`, `manuallyApprovesFollowers: false`, `discoverable: true`, `publicKey {id, owner, publicKeyPem}`, `icon {type: Image, url}` when avatar set.
  WebFinger: `GET /.well-known/webfinger?resource=acct:yudai@ynkt.me` (also accept `acct:yudai@ochoko.ynkt.me` and the actor URL) → `200 application/jrd+json` `{"subject": "acct:yudai@ynkt.me", "aliases": [actor_id], "links": [{"rel": "self", "type": "application/activity+json", "href": actor_id}]}`; any other resource → `404`; missing → `400`.
  Content type for AP responses: `application/activity+json; charset=utf-8`.

- [ ] **Step 1: Write failing tests** (`web/federation_test`): `webfinger_subject_uses_account_domain_test`, `webfinger_accepts_host_domain_test`, `webfinger_unknown_404_test`, `webfinger_missing_400_test`, `actor_json_test` (id, inbox, publicKey.owner, manuallyApprovesFollowers false, url `https://ochoko.ynkt.me/profile`), `actor_name_falls_back_to_handle_test`, `me_redirects_browsers_test` (`Accept: text/html` → `302`, `location: https://ochoko.ynkt.me/profile`), `followers_collection_total_test` (2 followers inserted → `totalItems: 2`), `cors_preflight_test` (`OPTIONS /api/v1/apps` → `204` with the four headers), `cors_on_normal_response_test`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement; `/me/outbox` and `/me/following` return `collection_json` with real/zero counts.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: serve actor, webfinger and collections`.

---

### Task 7: Lenient AP decoding, fixtures, remote actor fetch and cache

**Files:**
- Create: `server/src/ochoko/http_client.gleam`, `server/src/ochoko/federation/ap_decode.gleam`, `server/src/ochoko/federation/remote_actor.gleam`, `server/src/ochoko/store/remote_actors.gleam`, `server/test/fixtures/ap/SOURCES.md`, fixture JSON files, tests
- Modify: `server/src/ochoko.gleam` (`fetch` command), `server/src/ochoko/context.gleam` (`send`, `private_key`)

**Interfaces:**
- Produces:
  ```gleam
  // http_client
  pub type Send = fn(Request(String)) -> Result(Response(String), HttpError)
  pub type HttpError { Timeout  Unreachable(String) }
  pub fn httpc_send(timeout_ms: Int) -> Send                 // gleam_httpc; 10_000 ms used everywhere
  pub fn signed_get(ctx: Context, url: String) -> Result(Response(String), HttpError)
     // Accept: application/activity+json, signed with config.key_id; User-Agent "ochoko/0.1.0 (+https://{host}/)"
  // ap_decode — all decoders tolerate null/missing where noted
  pub fn iri() -> decode.Decoder(String)                     // "x" | {"id": "x"} | {"href": "x"}
  pub fn iri_list() -> decode.Decoder(List(String))          // null | iri | [iri...]  → list
  pub fn type_names() -> decode.Decoder(List(String))        // "Note" | ["Note", ...]
  pub fn image_url() -> decode.Decoder(Option(String))       // "u" | {url: "u"|{href}} | [..] → first
  pub fn localized(field: String) -> decode.Decoder(Option(String))  // field, else first value of fieldMap
  // remote_actor
  pub type RemoteActor { RemoteActor(id: Int, uri: String, username: String, domain: String,
      display_name: String, summary_html: String, avatar_url: Option(String),
      header_url: Option(String), url: Option(String), inbox: String,
      shared_inbox: Option(String), followers_uri: Option(String),
      public_key_id: String, public_key_pem: String, bot: Bool, locked: Bool) }
  pub fn decode(json: String) -> Result(RemoteActor, String)  // id = 0 before storage; domain = host of uri
  pub fn get_or_fetch(ctx, uri: String) -> Result(RemoteActor, String)   // cache hit if fetched within 24 h
  pub fn refetch(ctx, uri: String) -> Result(RemoteActor, String)
  pub fn by_key_id(ctx, key_id: String) -> Result(RemoteActor, String)
     // strip fragment and fetch; if the document is a key ({owner, publicKeyPem}) fetch `owner`
  pub fn resolve_acct(ctx, username: String, domain: String) -> Result(RemoteActor, String)
     // WebFinger https://{domain}/.well-known/webfinger, follow rel=self with AP type; store `domain` = the acct domain
  // store/remote_actors: upsert(conn, RemoteActor) -> Result(RemoteActor, _)  (returns row with id),
  //   get(conn, id), get_by_uri(conn, uri), search_prefix(conn, q, limit)
  ```
  `publicKey` may be an object or an array of objects; pick the one whose `id` equals the signature's key ID when known, else the first. `bot` = type contains `Service` or `Application`. `summary_html` goes through `html.sanitize` once Task 10 exists — until then store raw and add the call in Task 10.

- [ ] **Step 1: Collect fixtures.** Save real actor and note JSON for Mastodon, Misskey, GoToSocial and Akkoma into `test/fixtures/ap/{impl}_{actor|note}.json`. Use `curl -H 'Accept: application/activity+json'` against public accounts where unauthenticated fetch works; for servers that require signed fetch (GoToSocial does), copy sample payloads from that project's own test data. Record each file's source URL/commit and date in `SOURCES.md`. Strip nothing except personal data you don't want committed.
- [ ] **Step 2: Write failing tests:**
  - `ap_decode_test`: `iri` on `"https://a"`, `{"id":"https://a"}`, `{"href":"https://a"}`; `iri_list` on `null`, a string, a mixed array; `type_names` on string and array; `image_url` on string, object, array of objects; `localized("content")` falls back to `contentMap`.
  - `remote_actor_test`: one `decode_{impl}_actor_test` per fixture asserting `uri`, `username`, `inbox`, a non-empty `public_key_pem`, and `shared_inbox` where the fixture has one; `decode_publickey_array_test`; `decode_missing_inbox_error_test`.
  - `get_or_fetch_caches_test` — fake `send` counts calls; two calls within 24 h → one fetch.
  - `by_key_id_follows_owner_test` — key document → owner actor fetched.
  - `resolve_acct_test` — fake WebFinger + actor; stored `domain` is the acct domain even when the actor lives on another host.
  - `signed_get_is_signed_test` — captured request has `signature` with `keyId="https://ochoko.ynkt.me/me#main-key"` and verifies with our public key.
- [ ] **Step 3:** `gleam test` → FAIL.
- [ ] **Step 4:** Implement. Decoders read compacted AS2 key names only (all four implementations in the corpus use them); unknown keys are ignored.
- [ ] **Step 5:** `fetch --config PATH URL` prints the signed-fetch response body (debug aid for collecting more fixtures).
- [ ] **Step 6:** `gleam test` → PASS.
- [ ] **Step 7:** Commit `feat: decode and cache remote actors`.

---

### Task 8: Delivery queue and worker

**Files:**
- Create: `server/src/ochoko/store/deliveries.gleam`, `server/src/ochoko/federation/delivery.gleam`, tests

**Interfaces:**
- Consumes: `signature.sign`, `Context.send`.
- Produces:
  ```gleam
  pub fn enqueue(conn, inboxes: List(String), body: String, now: Timestamp) -> Result(Nil, _)
     // de-duplicates inboxes; one row per inbox
  pub fn inboxes_for_followers(conn) -> List(String)   // shared_inbox when present else inbox, deduped
  pub fn run_once(ctx: Context) -> Int                 // claims ≤16 due rows (locked_until = now+60s),
                                                      // delivers each in its own process, returns count claimed
  pub fn start(ctx: Context) -> Result(actor.Started(Subject(Msg)), actor.StartError)
                                                      // gleam_otp actor ticking run_once every 5 s
  pub const backoff_seconds = [60, 300, 1800, 7200, 21600, 43200, 86400, 86400, 86400]
  ```
  Outcome rules: 2xx → delete row. `408`, `429`, 5xx, `Timeout`, `Unreachable` → `attempts + 1`, `next_attempt_at = now + backoff_seconds[attempts]`, unlock; when `attempts` reaches `list.length(backoff_seconds)` → delete and log. Any other 4xx (incl. `404`, `410`) → delete and log. Each POST is signed at send time (fresh `Date`), `content-type: application/activity+json`.

- [ ] **Step 1: Write failing tests:** `enqueue_dedupes_inboxes_test`, `inboxes_prefer_shared_inbox_test`, `success_deletes_row_test`, `server_error_reschedules_with_backoff_test` (attempts 0 → next_attempt_at = now+60), `gone_drops_immediately_test` (410), `too_many_requests_retries_test` (429), `gives_up_after_schedule_test` (attempts = 9 then 500 → row gone), `not_due_rows_are_skipped_test`, `locked_rows_are_skipped_test`, `slow_host_does_not_block_others_test` (fake send sleeps for host A; host B's row completes within the same `run_once`), `posted_request_is_signed_test`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement; per-delivery work runs in an unlinked spawned process that opens its own DB connection.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: persistent delivery queue with retry`.

---

### Task 9: Inbox — verification, dedup, follow lifecycle

**Files:**
- Create: `server/src/ochoko/federation/inbox.gleam`, `server/src/ochoko/federation/activities.gleam`, `server/src/ochoko/store/notifications.gleam`, tests
- Modify: `server/src/ochoko/store/follows.gleam`, `server/src/ochoko/web/federation.gleam`

**Interfaces:**
- Produces:
  ```gleam
  // activities (outbound JSON; ids are https://{host}/activities/{id.generate})
  pub fn follow(c: Config, object: String) -> #(String, json.Json)             // (activity id, json)
  pub fn undo(c: Config, inner: json.Json) -> json.Json
  pub fn accept(c: Config, follow_id: String, follower_uri: String) -> json.Json
     // object = {id: follow_id, type: "Follow", actor: follower_uri, object: actor_id}
  pub fn reject(c: Config, follow_uri: String, follower_uri: String) -> json.Json
  // inbox
  pub fn handle(ctx: Context, req: wisp.Request) -> wisp.Response
  // store/follows
  pub fn add_follower(conn, actor_id, follow_uri, now) ; remove_follower(conn, actor_id)
  pub fn add_following(conn, actor_id, follow_uri, now) ; set_following_accepted(conn, actor_id)
  pub fn remove_following(conn, actor_id) ; is_following(conn, actor_id) -> Option(State)
  pub fn is_follower(conn, actor_id) -> Bool ; followers(conn) ; following(conn)
  // store/notifications
  pub fn add_follow(conn, actor_id, activity_uri, now) -> Result(Nil, _)  // INSERT OR IGNORE
  ```
  `handle` steps, in order:
  1. Read body (limit 1 MiB → `413`). `signature.parse_header` → on error `401`.
  2. Decode `id`, `type`, `actor` with `ap_decode`. Malformed → `400`.
  3. `remote_actor.by_key_id` → if fetch fails and type is `Delete` → `202` and drop; other failures → `401`.
  4. `signature.verify`; on `BadSignature`, `remote_actor.refetch` once and retry; still failing → `401`.
  5. Activity `actor` must equal the key owner's `uri` → else `401`.
  6. If `id` is in `processed_activities` → `202`. Otherwise record it, dispatch, return `202`.
  Dispatch (this task): `Follow` whose object is our actor → upsert follower (storing this Follow's id as `follow_uri`), enqueue `Accept` to the actor's inbox, add a notification only if the actor was not already a follower. A repeat `Follow` with a new id from an existing follower is re-`Accept`ed without a new notification. `Undo{Follow}` by the same actor → remove follower. `Accept{Follow}` from an actor we have `pending` → `accepted` (match by actor; object may be an IRI or embedded). `Reject{Follow}` → remove following. Everything else → ignored (Task 11 adds notes/deletes). Both `/me/inbox` and `/inbox` route here.

- [ ] **Step 1: Write failing tests** (`inbox_test`, using a test-signed request helper `support.signed_post(ctx, remote_key, key_id, path, body)` and fake remote actor documents):
  - `unsigned_401_test`, `bad_signature_401_test`, `stale_date_401_test`, `digest_mismatch_401_test`.
  - `actor_mismatch_401_test` — signed by actor A, `actor` = B.
  - `key_rotation_refetches_once_test` — cached key old, fresh actor document has the new key → `202`, two fetches total.
  - `delete_from_unfetchable_actor_202_test` — key fetch → 410, type `Delete` → `202`, nothing stored.
  - `follow_creates_follower_accept_and_notification_test` — followers row, one `deliveries` row to the actor's inbox whose body has `type: "Accept"` and `object.id` equal to the Follow's id, one notification.
  - `duplicate_activity_is_ignored_test` — same Follow id twice → one notification, one delivery.
  - `repeat_follow_with_new_id_reaccepts_test` — already a follower, new Follow id → second Accept enqueued, still one followers row, still one notification.
  - `undo_follow_removes_follower_test`; `undo_by_other_actor_ignored_test`.
  - `accept_marks_following_accepted_test`; `reject_removes_following_test`.
  - `oversized_body_413_test`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: verify inbox requests and handle follows`.

---

### Task 10: HTML — own text to HTML, sanitising remote HTML

**Files:**
- Create: `server/src/ochoko/html.gleam`, `server/src/ochoko_html_ffi.erl`, `server/test/ochoko/html_test.gleam`
- Modify: `server/gleam.toml` (add `mochiweb`), `server/src/ochoko/federation/remote_actor.gleam` (sanitise `summary_html`)

**Interfaces:**
- Produces:
  ```gleam
  pub fn text_to_html(text: String) -> String
  pub fn sanitize(html: String) -> String
  pub fn to_plain_text(html: String) -> String      // for display_name-like fields if needed
  ```
  `text_to_html`: escape `& < > " '`; split paragraphs on blank lines into `<p>…</p>`; single newlines → `<br>`; `http(s)://` URLs → `<a href="URL" rel="nofollow noopener noreferrer" target="_blank">URL</a>`. Empty text → `""`.
  `sanitize` (parse with `mochiweb_html:parse/1` wrapped in a `<div>`): keep `p br a span strong em b i u s del code pre blockquote ul ol li`; `a` keeps only `href` (http/https only, else drop the attribute) and `class`, and always gets `rel="nofollow noopener noreferrer" target="_blank"`; `span`/`a` `class` keeps only tokens in `mention hashtag u-url h-card invisible ellipsis`; every other attribute dropped; `script`, `style`, `iframe`, `object`, `embed`, `template` removed with their contents; other unknown elements unwrapped (children kept). Output re-serialised with text and attribute values escaped.

- [ ] **Step 1: Write failing tests:**
  - `text_escapes_test` — `"a < b & c"` → `"<p>a &lt; b &amp; c</p>"`.
  - `text_paragraphs_and_breaks_test` — `"l1\nl2\n\nl3"` → `"<p>l1<br>l2</p><p>l3</p>"`.
  - `text_linkifies_test`.
  - `sanitize_removes_script_test` — `"<p>hi<script>alert(1)</script></p>"` → `"<p>hi</p>"`.
  - `sanitize_drops_js_href_test` — `<a href="javascript:alert(1)">x</a>` keeps no `href`.
  - `sanitize_drops_event_handlers_and_style_test` — `<p onclick="x" style="y">t</p>` → `<p>t</p>`.
  - `sanitize_keeps_mastodon_mention_markup_test` — `<span class="h-card"><a href="https://m/@a" class="u-url mention">@<span>a</span></a></span>` survives with classes and gains `rel`/`target`.
  - `sanitize_unwraps_unknown_test` — `<marquee>t</marquee>` → `t`.
  - `sanitize_fixture_notes_test` — every fixture note's `content` sanitises without crashing and contains no `<script`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: convert own text to HTML and sanitise remote HTML`.

---

### Task 11: Inbox — notes and deletes

**Files:**
- Create: `server/src/ochoko/federation/note.gleam`, `server/src/ochoko/store/statuses.gleam`, tests
- Modify: `server/src/ochoko/federation/inbox.gleam`

**Interfaces:**
- Produces:
  ```gleam
  pub type Visibility { Public  Unlisted  Private  Direct }
  pub type InboundNote { InboundNote(uri: String, attributed_to: String, content_html: String,
      spoiler_text: String, sensitive: Bool, url: Option(String), in_reply_to: Option(String),
      language: Option(String), published: Option(Timestamp), to: List(String), cc: List(String),
      attachments: List(Attachment)) }
  pub type Attachment { Attachment(url: String, media_type: Option(String), description: Option(String), blurhash: Option(String)) }
  pub fn decode(dynamic) -> Result(InboundNote, String)     // content via localized("content"), sanitized here
  pub fn visibility(n: InboundNote, followers_uri: Option(String)) -> Visibility
     // Public if as:Public (or "as:Public"/"Public") in `to`; Unlisted if in `cc`;
     // Private if followers_uri in to/cc; else Direct
  // store/statuses
  pub type StatusRow { StatusRow(id: Int, uri: String, actor_id: Option(Int), content_html: String,
      text: Option(String), spoiler_text: String, sensitive: Bool, visibility: Visibility,
      url: Option(String), in_reply_to_uri: Option(String), language: Option(String),
      published_at: Timestamp, deleted_at: Option(Timestamp), attachments: List(Attachment)) }
  pub fn insert_remote(conn, actor_id: Int, n: InboundNote, v: Visibility, now: Timestamp) -> Result(Nil, _)
     // INSERT OR IGNORE on uri; id = id.generate(min(published, now))
  pub fn delete_remote(conn, uri: String, actor_id: Int) -> Result(Nil, _)
  pub fn insert_own(...)  get(...)  home_timeline(...)  // defined in Tasks 15/16
  ```
  Dispatch additions: `Create` with an embedded `Note` (or `Question`/`Article`/`Page` treated as Note) → accept only when the sender is `accepted` in `following` **and** `attributedTo` equals the sender; otherwise ignore. If the object is an IRI, fetch it with `signed_get` and apply the same checks. `Delete` → if object IRI (or Tombstone `id`) equals the sender's `uri`, delete the `remote_actors` row (cascade removes statuses, follows, notifications); else `delete_remote(object_id, sender_id)`. `Announce`, `Like`, `Update` and others → ignored.

- [ ] **Step 1: Write failing tests:**
  - `note_test`: `decode_{impl}_note_test` per fixture; `visibility_public_test`, `visibility_unlisted_test`, `visibility_private_test`, `visibility_direct_test`, `visibility_accepts_short_public_forms_test` (`"as:Public"`, `"Public"`); `content_is_sanitized_test`; `content_map_fallback_test`.
  - `inbox_test`: `create_from_followed_stored_test`, `create_from_unfollowed_ignored_test`, `create_with_pending_follow_ignored_test`, `create_attributed_to_other_ignored_test`, `duplicate_note_stored_once_test` (same note in two Create activities with different ids), `direct_note_stored_with_direct_visibility_test`, `future_published_is_clamped_test`, `delete_note_removes_status_test`, `delete_note_of_other_actor_ignored_test`, `delete_actor_cascades_test` (status, follower, following, notification gone).
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: receive notes and deletes`.

---

### Task 12: Shared Mastodon entities

**Files:**
- Create: `shared/src/ochoko_shared/mastodon.gleam`, `shared/test/ochoko_shared/mastodon_test.gleam`

**Interfaces:**
- Produces (types + `*_to_json` encoders; decoders come with the client, not now):
  `Account`, `Field`, `Status`, `MediaAttachment`, `Notification`, `Relationship`, `Application`, `Token`, `InstanceV1`, `InstanceV2`, `SearchResults`, `Context`, `Error`, and `Visibility { Public Unlisted Private Direct }` with `visibility_to_string`.
  Required keys (cross-check each list against masto.js `src/mastodon/entities/v1/*.ts` before writing; add any newly required key you find there):
  - Account: `id username acct url display_name note avatar avatar_static header header_static locked fields emojis bot group discoverable created_at last_status_at statuses_count followers_count following_count` (`discoverable`, `last_status_at` nullable).
  - Status: `id uri created_at account content visibility sensitive spoiler_text media_attachments mentions tags emojis reblogs_count favourites_count replies_count url in_reply_to_id in_reply_to_account_id reblog poll card language edited_at favourited reblogged muted bookmarked` (`url in_reply_to_id in_reply_to_account_id reblog poll card language edited_at` nullable); `text` optional (only on delete responses).
  - Notification: `id type created_at account`.
  - Relationship: `id following showing_reblogs notifying followed_by blocking blocked_by muting muting_notifications requested requested_by domain_blocking endorsed note languages` (`languages` nullable).
  Timestamps are ISO 8601 with milliseconds and `Z` (`2026-11-19T12:34:56.000Z`).

- [ ] **Step 1: Write failing tests:** one `*_has_required_keys_test` per entity above, decoding the encoded JSON into `dict.Dict(String, Dynamic)` and asserting every listed key is present; `status_nullable_keys_are_null_test` (`in_reply_to_id` present and `null`); `status_text_omitted_by_default_test`; `timestamp_format_test`.
- [ ] **Step 2:** `gleam test` and `gleam test --target javascript` in `shared/` → FAIL.
- [ ] **Step 3:** Implement. Keep the module free of Erlang-only dependencies.
- [ ] **Step 4:** Both targets → PASS.
- [ ] **Step 5:** Commit `feat(shared): add Mastodon API entities`.

---

### Task 13: OAuth, login page, bearer auth, apps

**Files:**
- Create: `server/src/ochoko/store/oauth.gleam`, `server/src/ochoko/api/apps.gleam`, `server/src/ochoko/api/oauth.gleam`, `server/src/ochoko/api/auth.gleam`, tests
- Modify: `server/src/ochoko/web/router.gleam`, `server/src/ochoko.gleam` (`hash-password`)

**Interfaces:**
- Produces:
  ```gleam
  pub type Auth { UserToken  AppToken }
  pub fn require_user(ctx, req, next: fn() -> Response) -> Response   // 401 {"error":"The access token is invalid"}
  pub fn require_any(ctx, req, next: fn(Auth) -> Response) -> Response
  ```
  Endpoints (bodies accepted as JSON, form-urlencoded, or query for GET):
  - `POST /api/v1/apps` (`client_name`, `redirect_uris` string or array, `scopes` default `read`, `website`) → `200` `{id, name, website, redirect_uri, redirect_uris, client_id, client_secret, vapid_key: ""}`. Secrets are 32 random bytes base64url.
  - `GET /api/v1/apps/verify_credentials` (any token) → `{name, website}`.
  - `GET /oauth/authorize` (`response_type=code`, `client_id`, `redirect_uri` must be one of the app's, `scope`, `state`, optional `code_challenge` + `code_challenge_method=S256`) → HTML login form (password field + hidden params). Unknown client / mismatched redirect → `400` HTML error, never redirect.
  - `POST /oauth/authorize` → `argus` verify against `config.password_hash`. Wrong → `process.sleep(1000)` then the form again with an error, status `401`. Right → code (expires 10 min, stored as sha256 hash) and `302` to `redirect_uri?code=…&state=…`; for `urn:ietf:wg:oauth:2.0:oob` render the code.
  - `POST /oauth/token`: `authorization_code` (client auth, code single-use and unexpired, redirect_uri match, PKCE verified when a challenge was stored) → `{access_token, token_type: "Bearer", scope, created_at}`; `client_credentials` → app token. Errors → `400 {"error": "invalid_grant", "error_description": …}` / `401 invalid_client`.
  - `POST /oauth/revoke` → `200 {}`.
  Tokens are 32 random bytes base64url; only sha256 hashes are stored.
  `hash-password` reads a password from stdin (no echo) and prints an argon2id hash for the config.

- [ ] **Step 1: Write failing tests:** `register_app_test`, `authorize_unknown_client_400_test`, `authorize_redirect_mismatch_400_test`, `authorize_renders_form_test`, `wrong_password_401_test`, `login_redirects_with_code_and_state_test`, `token_exchange_test`, `code_is_single_use_test`, `expired_code_rejected_test`, `pkce_s256_test` (RFC 7636 Appendix B verifier/challenge pair), `pkce_wrong_verifier_rejected_test`, `client_credentials_app_token_test`, `require_user_rejects_app_token_test`, `require_user_rejects_missing_token_test`, `revoke_invalidates_token_test`, `tokens_stored_hashed_test` (raw token string never appears in `oauth_tokens`).
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: OAuth authorization for Mastodon clients`.

---

### Task 14: Instance, accounts, relationships, follow actions, search

**Files:**
- Create: `server/src/ochoko/api/present.gleam`, `server/src/ochoko/api/instance.gleam`, `server/src/ochoko/api/accounts.gleam`, `server/src/ochoko/api/search.gleam`, `server/src/ochoko/api/pagination.gleam`, `server/priv/static/avatar.png`, tests
- Modify: router (static files under `/static`)

**Interfaces:**
- Consumes: `ochoko_shared/mastodon`, `store/*`, `remote_actor.*`, `activities.*`, `delivery.enqueue`.
- Produces:
  ```gleam
  pub const local_account_id = "0"     // remote account id = remote_actors.id as string
  pub fn local_account(ctx, conn) -> mastodon.Account      // acct = handle, url = actor url, avatar fallback /static/avatar.png
  pub fn remote_account(a: RemoteActor, conn) -> mastodon.Account  // acct = "username@domain"
  pub fn relationship(conn, remote_id: Int) -> mastodon.Relationship
  // pagination
  pub type Page { Page(max_id: Option(Int), since_id: Option(Int), min_id: Option(Int), limit: Int) } // limit default 20, max 40
  pub fn parse(req) -> Page
  pub fn link_header(base_url: String, first: Option(Int), last: Option(Int)) -> Option(String)
     // <base?max_id=last>; rel="next", <base?min_id=first>; rel="prev"
  ```
  Endpoints: `GET /api/v1/instance`, `GET /api/v2/instance` (`version: "4.3.0 (compatible; ochoko 0.1.0)"`, `domain`/`uri` = host, `title: "ochoko"`, registrations closed, `configuration.statuses.max_characters: 500`, `max_media_attachments: 0`, `characters_reserved_per_url: 23`, contact account = local account, no streaming URL); `GET /api/v1/accounts/verify_credentials` (local account + `source {privacy: "public", sensitive: false, language: "", note, fields: []}`); `GET /api/v1/accounts/:id`; `GET /api/v1/accounts/lookup?acct=`; `GET /api/v1/accounts/:id/statuses` (own statuses for `0`, stored statuses for remote; paginated); `GET /api/v1/accounts/:id/followers` and `/following` (local only; remote → `[]`); `GET /api/v1/accounts/relationships?id[]=`; `POST /api/v1/accounts/:id/follow` (add `pending` following, enqueue Follow; already following → no-op); `POST /api/v1/accounts/:id/unfollow` (enqueue `Undo{Follow}` with stored `follow_uri`, delete row); `POST /api/v1/accounts/:id/remove_from_followers` (enqueue `Reject` of stored `follow_uri`, delete follower); `GET /api/v2/search?q=&resolve=&type=` (`@user@host`, `user@host` or an actor URL → with `resolve=true` `resolve_acct`/`get_or_fetch`; without, `search_prefix` on cached actors; `statuses` and `hashtags` always `[]`). Unknown account id → `404 {"error":"Record not found"}`. All except instance require a user token.

- [ ] **Step 1: Write failing tests:** `instance_v2_test` (version string, domain `ochoko.ynkt.me`), `instance_v1_test`, `verify_credentials_test` (`id: "0"`, `acct: "yudai"`, `display_name` from profile), `local_account_default_avatar_test`, `remote_account_acct_test`, `lookup_remote_test`, `follow_enqueues_follow_and_marks_requested_test` (relationship `requested: true`), `follow_twice_is_noop_test`, `unfollow_enqueues_undo_with_original_follow_id_test`, `remove_from_followers_enqueues_reject_test`, `relationships_followed_by_test`, `search_resolve_acct_test`, `search_with_leading_at_test`, `search_resolve_url_test`, `search_without_resolve_uses_cache_test`, `search_unresolvable_returns_empty_test`, `unknown_account_404_test`, `pagination_parse_limits_test` (limit 100 → 40), `link_header_test`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: account, relationship and search endpoints`.

---

### Task 15: Own statuses — post, delete, serve

**Files:**
- Create: `server/src/ochoko/api/statuses.gleam`, tests
- Modify: `server/src/ochoko/store/statuses.gleam`, `server/src/ochoko/federation/activities.gleam`, `server/src/ochoko/web/federation.gleam`

**Interfaces:**
- Produces:
  ```gleam
  pub fn insert_own(conn, text: String, html: String, v: Visibility, spoiler: String, sensitive: Bool, language: Option(String), now) -> Result(StatusRow, _)
     // uri = "https://{host}/statuses/{id}"
  pub fn mark_deleted(conn, id: Int, now) -> Result(Nil, _)
  pub fn note_json(c: Config, s: StatusRow) -> json.Json
     // Note: id, type, attributedTo = actor_id, content, published (RFC 3339), url = uri,
     // to/cc: public → to [as:Public] cc [followers]; unlisted → to [followers] cc [as:Public];
     // sensitive, summary (null when empty)
  pub fn create(c, s) -> json.Json      // id = uri <> "/activity", same to/cc as the note
  pub fn delete(c, s) -> json.Json      // object = Tombstone {id: uri}, to [as:Public]
  pub fn present_status(ctx, conn, s: StatusRow) -> mastodon.Status
  ```
  Endpoints: `POST /api/v1/statuses` (`status` required non-empty after trim, ≤ 500 chars; `visibility` default `public`; `spoiler_text`, `sensitive`, `language` accepted; `private`/`direct`/`in_reply_to_id`/non-empty `media_ids`/`poll` → `422`; honour `Idempotency-Key` header by caching the response for 1 hour in an ETS table or the DB) → insert, enqueue `Create` to `inboxes_for_followers`, return Status. `GET /api/v1/statuses/:id` (own or stored remote, excluding `deleted_at`). `DELETE /api/v1/statuses/:id` (own only, else `404`) → `mark_deleted`, enqueue `Delete`, return Status with `text`. `GET /api/v1/statuses/:id/context` → `{"ancestors": [], "descendants": []}`. AP: `GET /statuses/:id` → `note_json`; deleted → `410`; remote or unknown → `404`.

- [ ] **Step 1: Write failing tests:** `post_public_status_test` (Status `visibility: "public"`, content `<p>hello</p>`, one delivery per follower inbox with `type: "Create"` and `to` containing `https://www.w3.org/ns/activitystreams#Public`), `post_unlisted_addressing_test`, `post_private_422_test`, `post_direct_422_test`, `post_reply_422_test`, `post_media_422_test`, `post_empty_422_test`, `post_too_long_422_test`, `idempotency_key_returns_same_status_test`, `post_without_followers_enqueues_nothing_test`, `delete_own_status_test` (Delete delivery with Tombstone, response has `text`), `delete_remote_status_404_test`, `get_note_json_test`, `get_deleted_note_410_test`, `context_is_empty_test`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: post and delete own statuses`.

---

### Task 16: Home timeline, notifications, startup stubs

**Files:**
- Create: `server/src/ochoko/api/timelines.gleam`, `server/src/ochoko/api/notifications.gleam`, `server/src/ochoko/api/stubs.gleam`, tests
- Modify: `server/src/ochoko/store/statuses.gleam`, `server/src/ochoko/store/notifications.gleam`

**Interfaces:**
- Produces:
  ```gleam
  pub fn home_timeline(conn, page: Page) -> List(StatusRow)
     // own non-deleted statuses + remote statuses from accepted following,
     // visibility in (public, unlisted, private); ORDER BY id DESC, min_id → ascending window then reversed
  pub fn list(conn, page: Page) -> List(NotificationRow)
  ```
  Endpoints: `GET /api/v1/timelines/home`, `GET /api/v1/notifications` (`types[]`/`exclude_types[]` filter applied, only `follow` exists), `GET /api/v1/notifications/:id`, `POST /api/v1/notifications/clear`, `POST /api/v1/notifications/:id/dismiss` — all with `Link` headers where paginated. Stubs returning a valid empty body (user token required): `GET /api/v1/custom_emojis` `[]`, `/api/v1/filters` `[]`, `/api/v2/filters` `[]`, `/api/v1/lists` `[]`, `/api/v1/markers` `{}`, `POST /api/v1/markers` `{}`, `/api/v1/preferences` (`{"posting:default:visibility": "public", "posting:default:sensitive": false, "posting:default:language": null, "reading:expand:media": "default", "reading:expand:spoilers": false}`), `/api/v1/announcements` `[]`, `/api/v1/trends/*` `[]`, `/api/v1/followed_tags` `[]`, `/api/v1/conversations` `[]`, `/api/v1/timelines/public` `[]`, `/api/v1/timelines/tag/:tag` `[]`, `/api/v1/favourites` `[]`, `/api/v1/bookmarks` `[]`, `/api/v1/blocks` `[]`, `/api/v1/mutes` `[]`, `/api/v1/domain_blocks` `[]`, `/api/v1/follow_requests` `[]`, `/api/v1/featured_tags` `[]`, `/api/v1/accounts/:id/featured_tags` `[]`, `/api/v1/accounts/:id/lists` `[]`, `/api/v1/push/subscription` `404`. Extend this list during Task 17's smoke test.

- [ ] **Step 1: Write failing tests:** `home_includes_own_and_followed_test`, `home_excludes_unfollowed_and_pending_test`, `home_excludes_direct_test`, `home_excludes_deleted_own_test`, `home_max_id_test`, `home_min_id_returns_closest_newer_test`, `home_since_id_test`, `home_link_header_test`, `home_requires_user_token_test`, `notifications_list_test`, `notifications_exclude_follow_test`, `notifications_clear_test`, `stubs_return_valid_json_test` (table-driven over the stub list: status 200 and body parses as JSON).
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Commit `feat: home timeline, notifications and client stubs`.

---

### Task 17: Wire-up, deployment notes, Elk smoke test

**Files:**
- Modify: `server/src/ochoko.gleam` (`serve`), `README.md`
- Create: `server/src/ochoko/app.gleam` (supervision), `docs/deployment.md`, `docs/elk-smoke-test.md`

**Interfaces:**
- Produces: `app.start(config: Config) -> Result(Nil, String)` — loads key, `db.open` + `migrate`, builds `Context` (`httpc_send(10_000)`, `timestamp.system_time`), starts a static supervisor with the delivery worker and the mist server (`wisp_mist.handler(router.handle_request(_, ctx), config.secret_key_base)` on `listen_port`), then sleeps forever.

- [ ] **Step 1: Write failing test** `app_test.serves_health_test` — start the app on port 0/free port with a temp DB and generated key, `GET /health` via httpc → `200`.
- [ ] **Step 2:** `gleam test` → FAIL.
- [ ] **Step 3:** Implement `app.start` and `serve`.
- [ ] **Step 4:** `gleam test` → PASS.
- [ ] **Step 5:** Write `docs/deployment.md`: building (`gleam export erlang-shipment`), config + `keygen` + `hash-password` + `profile` commands, reverse proxy example (Caddy, TLS, `X-Forwarded-*`), the `ynkt.me` WebFinger requirement with a ready-to-copy static JRD for `acct:yudai@ynkt.me` and the redirect alternative, Litestream/`sqlite3 .backup` note (WAL), running under systemd on a VPS or home server.
- [ ] **Step 6: Elk smoke test (manual, against the deployed server).** Record results in `docs/elk-smoke-test.md`: log in at elk.zone with `ochoko.ynkt.me`; open home, notifications, own profile; search `@Gargron@mastodon.social` and follow; confirm Accept arrives (relationship flips to following); post a public and an unlisted status and see them from a Mastodon account; follow ochoko from that Mastodon account and confirm the notification; delete a status and confirm it disappears remotely; check that `@yudai@ynkt.me` resolves from Mastodon search. Note every endpoint Elk calls that returns `404` (server log) and either add it to the stubs (Task 16 list) or record why not. **Confirm whether Elk is usable without streaming;** if not, stop and report — streaming must be pulled forward (new plan).
- [ ] **Step 7:** Commit `feat: wire up application and document deployment`.
