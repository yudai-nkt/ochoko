import gleam/time/timestamp.{type Timestamp}
import ochoko/config.{type Config}
import ochoko/crypto/rsa
import ochoko/http_transport.{type Send}

/// Application context.
pub type Context {
  Context(
    config: Config,
    db_path: String,
    now: fn() -> Timestamp,
    private_key: rsa.PrivateKey,
    send: Send,
  )
}
