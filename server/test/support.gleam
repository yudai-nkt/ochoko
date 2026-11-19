import gleam/time/timestamp
import ochoko/config.{type Config, Config}
import ochoko/context.{type Context, Context}
import ochoko/crypto/rsa
import ochoko/db
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

/// A context with a fixed clock and the cached test key.
pub fn test_context(db_path: String) -> Context {
  Context(
    config: test_config(),
    db_path:,
    now: fn() { timestamp.from_unix_seconds(1_700_000_000) },
    private_key: test_key(),
  )
}
