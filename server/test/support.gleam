import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/time/timestamp
import gleam/uri
import ochoko/config.{type Config, Config}
import ochoko/context.{type Context, Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/http_client.{type Send}
import sqlight

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
