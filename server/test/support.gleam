import argus
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/time/timestamp
import gleam/uri
import ochoko/config.{type Config, Config}
import ochoko/context.{type Context, Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/http_client.{type Send}
import ochoko/signature
import ochoko/store/oauth
import sqlight
import wisp
import wisp/simulate

pub fn test_config() -> Config {
  Config(
    account_domain: "ynkt.me",
    host: "ochoko.ynkt.me",
    handle: "yudai",
    listen_port: 8000,
    database_path: ":memory:",
    private_key_path: "key.pem",
    password_hash: "hash",
    secret_key_base: "secret",
  )
}

/// A fresh in-memory database with pragmas applied and migrations run.
pub fn fresh_db() -> sqlight.Connection {
  let assert Ok(conn) = db.open(":memory:")
  let assert Ok(Nil) = db.migrate(conn)
  conn
}

@external(erlang, "ochoko_rsa_test_ffi", "cached_key")
fn cached_key(make: fn() -> rsa.PrivateKey) -> rsa.PrivateKey

@external(erlang, "ochoko_rsa_test_ffi", "cached_key_named")
fn cached_key_named(
  name: String,
  make: fn() -> rsa.PrivateKey,
) -> rsa.PrivateKey

/// A second RSA key, standing in for remote actors' keys.
pub fn remote_key() -> rsa.PrivateKey {
  cached_key_named("remote", fn() { rsa.generate(2048) })
}

@external(erlang, "ochoko_test_ffi", "temp_path")
fn temp_path_ffi() -> String

/// The RSA key shared by all tests (generation is slow).
pub fn test_key() -> rsa.PrivateKey {
  cached_key(fn() { rsa.generate(2048) })
}

/// Create and migrate a unique SQLite file under the system temp directory.
pub fn temp_db_path() -> String {
  let path = temp_path_ffi()
  let assert Ok(conn) = db.open(path)
  let assert Ok(Nil) = db.migrate(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  path
}

/// A context with a fixed clock, the cached test key and a `send` that
/// answers 404 to everything.
pub fn test_context(db_path: String) -> Context {
  test_context_with_send(db_path, fake_send([]))
}

pub fn test_context_with_send(db_path: String, send: Send) -> Context {
  Context(
    config: test_config(),
    db_path:,
    now: fn() { timestamp.from_unix_seconds(1_700_000_000) },
    private_key: test_key(),
    send:,
    login_failure_delay_ms: 0,
  )
}

/// A `send` that answers from a table keyed by full URL; unknown URLs get 404.
pub fn fake_send(routes: List(#(String, Response(String)))) -> Send {
  fn(req: Request(String)) {
    let url = uri.to_string(request.to_uri(req))
    case list.key_find(routes, url) {
      Ok(res) -> Ok(res)
      Error(Nil) -> Ok(response.new(404) |> response.set_body(""))
    }
  }
}

/// A 200 response with a JSON body.
pub fn json_response(body: String) -> Response(String) {
  response.new(200)
  |> response.set_header("content-type", "application/activity+json")
  |> response.set_body(body)
}

@external(erlang, "ochoko_test_ffi", "cell_new")
fn cell_new(initial: a) -> cell

@external(erlang, "ochoko_test_ffi", "cell_get")
fn cell_get(cell: cell) -> a

@external(erlang, "ochoko_test_ffi", "cell_set")
fn cell_set(cell: cell, value: a) -> Nil

/// Wraps `send` so that every request is recorded. The second element
/// returns the recorded requests, oldest first.
pub fn recording_send(send: Send) -> #(Send, fn() -> List(Request(String))) {
  let cell = cell_new([])
  let recorded = fn(req: Request(String)) {
    cell_set(cell, [req, ..cell_get(cell)])
    send(req)
  }
  #(recorded, fn() { list.reverse(cell_get(cell)) })
}

/// A POST to `path` on our host, signed with `remote_key` as `key_id` at the
/// context's clock.
pub fn signed_post(
  ctx: Context,
  remote_key: rsa.PrivateKey,
  key_id: String,
  path: String,
  body: String,
) -> wisp.Request {
  let signed =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host(ctx.config.host)
    |> request.set_path(path)
    |> request.set_body(body)
    |> signature.sign(remote_key, key_id, ctx.now())
  let req = simulate.request(http.Post, path) |> simulate.string_body(body)
  list.fold(signed.headers, req, fn(req, h) {
    request.set_header(req, h.0, h.1)
  })
  |> request.set_header("content-type", "application/activity+json")
}

/// A minimal remote actor document for `uri` listing `key` as `uri#main-key`.
pub fn remote_actor_json(uri: String, key: rsa.PrivateKey) -> String {
  json.object([
    #("id", json.string(uri)),
    #("type", json.string("Person")),
    #("preferredUsername", json.string("remote")),
    #("inbox", json.string(uri <> "/inbox")),
    #(
      "endpoints",
      json.object([
        #("sharedInbox", json.string("https://" <> host_of(uri) <> "/inbox")),
      ]),
    ),
    #(
      "publicKey",
      json.object([
        #("id", json.string(uri <> "#main-key")),
        #("owner", json.string(uri)),
        #("publicKeyPem", json.string(rsa.public_pem(key))),
      ]),
    ),
  ])
  |> json.to_string
}

fn host_of(uri: String) -> String {
  let assert Ok(parsed) = uri.parse(uri)
  let assert Some(host) = parsed.host
  host
}

pub const test_password = "correct horse battery staple"

@external(erlang, "ochoko_rsa_test_ffi", "cached_key_named")
fn cached_string(name: String, make: fn() -> String) -> String

/// An argon2id hash of `test_password`, computed once with cheap parameters.
pub fn test_password_hash() -> String {
  cached_string("password_hash", fn() {
    let assert Ok(out) =
      argus.hasher()
      |> argus.algorithm(argus.Argon2id)
      |> argus.time_cost(1)
      |> argus.memory_cost(64)
      |> argus.hash(test_password)
    out.encoded_hash
  })
}

/// Like `test_context`, but `config.password_hash` verifies `test_password`.
pub fn login_context(db_path: String) -> Context {
  let ctx = test_context(db_path)
  Context(
    ..ctx,
    config: Config(..ctx.config, password_hash: test_password_hash()),
  )
}

/// Inserts an app and a user token directly; returns the bearer token.
pub fn user_token(ctx: Context) -> String {
  let assert Ok(token) =
    db.with_connection(ctx.db_path, fn(conn) {
      use app <- result.try(oauth.create_app(
        conn,
        "Elk",
        option.None,
        ["https://elk.example/cb"],
        "read write follow",
        ctx.now(),
      ))
      oauth.create_token(
        conn,
        app.id,
        oauth.UserKind,
        "read write follow",
        ctx.now(),
      )
    })
  token
}
