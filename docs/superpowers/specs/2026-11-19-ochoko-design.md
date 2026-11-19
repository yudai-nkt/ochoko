# ochoko — Design

Date: 2026-11-19
Status: Awaiting approval

## Intent

ochoko is a lightweight, **single-user** ActivityPub server for microblogging,
written from scratch by its only user.

Why it exists:

- **Learning.** The owner wants to understand ActivityPub, its de-facto
  conventions (WebFinger, HTTP Signatures, Mastodon quirks), and the Mastodon
  client API by implementing them.
- **Self-hosting something you fully understand.** If the owner is going to
  self-host, they prefer software they wrote.

It will be the owner's **main Fediverse identity**, not a throwaway
experiment. The owner has no active Fediverse account to migrate from (a
dormant Mastodon account exists; migrating it is not a goal for now).

Roadmap: build the server first and use [Elk](https://elk.zone) as the client.
Once the server matures, build an own client so the project becomes full-stack.

## Goals

- Federate with mainstream Fediverse software (Mastodon first; Misskey,
  GoToSocial, Akkoma, etc. should work through lenient parsing).
- Be usable from Elk through the subset of the Mastodon client API Elk needs.
- Exactly one user, enforced by design.
- Durable enough for a main account: no lost outgoing deliveries across
  restarts, data that can be backed up.

## Non-goals

- Multiple users, sign-up, admin/moderation UI.
- Relays.
- ActivityPub C2S (client-to-server) API. Clients talk the Mastodon API.
- Full Mastodon API compatibility. Only what Elk (and later the own client)
  needs.
- TypeSpec or any other external IDL (see "Type strategy").

## Anti-goals

- A "users" concept anywhere in the database. No `users` table, no `user_id`
  columns.
- Hiding the protocol behind a framework. Implementing it is the point.
- Heavy infrastructure (Redis, separate worker services, Postgres).

## Identity

| Item | Value |
|------|-------|
| Account handle (what people see/type) | `@yudai@ynkt.me` |
| Account domain (WebFinger `acct:` domain) | `ynkt.me` |
| Server host | `ochoko.ynkt.me` |
| Actor ID | `https://ochoko.ynkt.me/users/yudai` |

- Account domain and server host are **separate configuration values**
  (Mastodon's `LOCAL_DOMAIN` / `WEB_DOMAIN` split).
- `ynkt.me` will host a personal site later. Whatever serves it must answer
  `/.well-known/webfinger` for `acct:yudai@ynkt.me`, either by redirecting to
  `ochoko.ynkt.me` or by serving a static JRD file (possible because there is
  only one user). This is outside ochoko's codebase but must be documented in
  the deployment notes.
- `ochoko.ynkt.me` itself must also answer WebFinger and return
  `subject: acct:yudai@ynkt.me`, because Mastodon does a reverse WebFinger
  lookup against the actor's host to verify the handle.
- Actor IDs and object IDs are permanent once federated. The host, handle and
  URL scheme must be treated as immutable after first deployment.

## Constraints

- Language: **Gleam**, Erlang (BEAM) target for the server.
- Storage: **SQLite**.
- Runs as a single long-lived process. Hosting is undecided (a VPS or a home
  server); the design must not depend on either.
- Public HTTPS is required for federation; TLS termination is expected to be
  handled by a reverse proxy in front of ochoko (builder's call on specifics).

## Approaches considered

1. **Single BEAM application + monorepo (chosen).** HTTP handling and
   delivery workers run in one OTP application. The outgoing delivery queue is
   persisted in SQLite and drained by OTP workers.
2. **Separate web and worker processes.** Rejected: SQLite allows a single
   writer, so splitting processes adds coordination for no gain; BEAM already
   provides safe in-process concurrency and supervision.
3. **External queue (Redis etc.).** Rejected: too much infrastructure for a
   lightweight single-user server.
4. **In-memory-only queue.** Rejected: pending deliveries would be lost on
   restart, unacceptable for a main account.

Language review (recorded for context): Gleam was chosen over TypeScript +
Fedify (fast, but hides the protocol, defeating the learning goal) and Go/Rust
(richer libraries, but no path to a same-language client). Gleam's strengths
here are BEAM/OTP for queues, retries and streaming connections, and Lustre
for a future client sharing types with the server. Known costs: no
ActivityPub library, no RSA signing in `gleam_crypto` (use Erlang
`:public_key` via FFI), verbose decoding of irregular JSON, low-level SQLite
access via `sqlight`, few libraries for OAuth2 server / HTML sanitising /
image processing.

## Architecture

### Repository layout

A monorepo with Gleam packages:

- `shared/` — Mastodon API entity types and their JSON encoders/decoders.
  Must compile for both Erlang and JavaScript targets.
- `server/` — the ochoko server (Erlang target). Depends on `shared`.
- `client/` — future Lustre client (JavaScript target). Not part of this
  design's scope; the layout reserves the slot.

### Runtime

- HTTP: `mist` + `wisp`.
- Database: SQLite via `sqlight`. Schema managed by hand-written migrations
  (builder's call on the mechanism).
- Delivery: an `outbox_deliveries`-style table holds pending deliveries
  (target inbox, signed payload or reference, attempt count, next attempt
  time). OTP workers pick due rows, sign and POST, and reschedule failures
  with backoff. Exact backoff schedule and give-up threshold are the
  builder's call.

### Type strategy

There are two JSON boundaries, handled differently:

1. **Mastodon client API (ochoko → Elk / own client).** The Gleam types in
   `shared` are the single source of truth. The own Lustre client will import
   the same package, so server/client mismatches are compile errors.
   Compatibility with Elk is verified by tests against reality: the types in
   masto.js (the library Elk uses) and real Mastodon responses.
   [abraham/mastodon-openapi](https://github.com/abraham/mastodon-openapi) may
   be used as a reference, not as a code-generation source. Note the
   Mastodon API distinguishes `null` from an absent key; encoders must
   preserve this where Elk depends on it.
2. **ActivityPub objects from other servers (inbound).** There is no
   authoritative schema: implementations add extensions, a field may be an
   IRI string, an object, or an array, and JSON-LD contexts change key
   names. Inbound JSON is parsed by **hand-written lenient decoders** into
   **normalised internal Gleam types** (e.g. always lists, IRIs resolved).
   The internal types are the source of truth. Ground truth for "what others
   actually send" is a **fixture corpus of real payloads** collected from
   Mastodon, Misskey, GoToSocial, Akkoma and others, used in tests.

TypeSpec was considered and rejected: it adds no accuracy (correctness comes
from verification against real behaviour), there is no TypeSpec→Gleam
emitter, and shared Gleam types already prevent client/server drift.
Revisit only if a non-Gleam consumer of ochoko's API appears.

### Single-user data model

- **Configuration file (immutable identity):** account domain, server host,
  handle, path to the actor's RSA key pair, and the owner's login credential
  (builder's call on the format, e.g. a password hash).
- **`profile` table (mutable profile), exactly one row:**

  ```sql
  CREATE TABLE profile (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    display_name TEXT NOT NULL,
    note TEXT NOT NULL,
    avatar_url TEXT,
    -- profile metadata fields, header, etc. as needed
    ...
  );
  ```

  The row is inserted by a migration; a `BEFORE DELETE` trigger forbids
  deleting it.
- Every other table holds data that is not "about a user": OAuth apps and
  tokens, own statuses, remote actors, follow relationships, received
  statuses, notifications, the delivery queue. No table references a user.
- Account endpoints of the Mastodon API build the local account from config +
  `profile`.

## MVP scope

The MVP is: **follow remote people, read their posts in Elk, post text, and
be followed.**

### Federation

- WebFinger (on `ochoko.ynkt.me`; see Identity for `ynkt.me`).
- Actor document (`Person`) with public key.
- HTTP Signatures: verify inbound requests, sign outbound requests and
  signed fetches of remote actors/objects. Mastodon-compatible
  (draft-cavage) signatures are required; RFC 9421 support is the builder's
  call.
- Inbox (shared inbox may point to the same endpoint).
- Followers collection.
- `Follow` / `Accept` / `Undo(Follow)` in both directions.
- Incoming follows are **accepted automatically** (`manuallyApprovesFollowers:
  false`). The owner can remove a follower, which sends `Reject(Follow)`.
- `Create(Note)` / `Delete` for own text posts, delivered to followers.
- Receiving `Create(Note)` from followed actors into the home timeline.
- Receiving `Delete` of notes and of actors (remove the post / the actor's
  posts and relationships). *(Builder-check call: a main account should not
  keep deleted posts on its timeline.)*
- Signatures are verified on inbound inbox POSTs. **Authorized fetch
  ("secure mode") is not in the MVP**: GETs of the actor and own objects are
  served unauthenticated, which is acceptable because only public and
  unlisted posts are published (see Visibility).
- Persistent delivery queue with retry.

### Visibility

- **Outgoing:** only `public` and `unlisted`. `unlisted` differs only in
  addressing (`as:Public` in `cc` instead of `to`). Requests for `private` or
  `direct` visibility from the client are rejected with an error.
- **Incoming:** every received post is stored with its visibility. The home
  timeline shows `public`, `unlisted` and `private` (followers-only) posts
  from followed actors. `direct` posts are stored but not shown until DM
  support lands.

### Mastodon client API (for Elk)

- App registration (`POST /api/v1/apps`), OAuth authorization with a
  server-rendered login page, token endpoint.
- `GET /api/v1/accounts/verify_credentials`.
- Instance endpoints Elk requires (`/api/v1/instance` and/or
  `/api/v2/instance`).
- Home timeline.
- Post and delete a status (text only).
- Follow / unfollow, account lookup, relationships as needed by Elk's
  follow UI.
- `GET /api/v2/search?resolve=true` to resolve `@user@host` for following.
- Notifications for new followers (`follow` type only).
- Remove from followers (`POST /api/v1/accounts/:id/remove_from_followers`).
- Any further endpoint Elk calls on startup that would otherwise break the
  UI should return a valid empty response.

Streaming is not in the MVP. Elk is expected to work with manual refresh;
the builder should confirm this early, and pull streaming forward if it
does not.

### Operations

- Backups are handled outside the app (e.g. Litestream or periodic SQLite
  backups). The app must not prevent this (e.g. use WAL mode).

## After the MVP (rough order, not committed)

- Replies: `inReplyTo`, mentions, mention notifications, thread view
  (`/api/v1/statuses/:id/context`).
- Profile editing from Elk (`update_credentials`) and delivering
  `Update(Person)` to followers. The `profile` table exists from the MVP.
- Streaming API.
- Likes and boosts (receiving, then sending).
- Block, mute, domain block.
- Followers-only and direct posting, together with authorized fetch (secure
  mode) and an instance/server actor for signing its own fetches.
- NodeInfo, outbox contents.
- Media attachments (storage choice, thumbnails, EXIF stripping; likely via
  an external tool such as libvips). Until then, remote media is displayed
  via the remote URLs.
- Edits, content warnings, hashtags, custom emoji, bookmarks, DMs, lists,
  filters, polls.
- `Move` from the dormant Mastodon account.
- The own Lustre client.

## Left to the builder

- Module structure inside `server/`, routing, and error handling style.
- Migration mechanism, exact table schemas beyond `profile`.
- Retry/backoff policy and delivery give-up threshold.
- Configuration file format and secrets handling.
- OAuth details beyond what Elk needs (scopes can be accepted and largely
  ignored for a single user).
- Reverse proxy / TLS / deployment packaging (Erlang release, container,
  etc.), as long as it runs on either a VPS or a home server.
- Test tooling, and how the inbound fixture corpus is collected and stored.
- Status ID format and ordering for timeline pagination.
- Plain text → HTML conversion for own posts; sanitising inbound HTML.
- Whether to backfill older posts when following someone.
- Verifying early how Elk handles the `ynkt.me` / `ochoko.ynkt.me` split.
