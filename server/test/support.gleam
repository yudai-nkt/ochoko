import ochoko/config.{type Config, Config}
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
