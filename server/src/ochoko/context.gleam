import gleam/time/timestamp.{type Timestamp}
import ochoko/config.{type Config}
import ochoko/crypto/rsa

/// Application context. `send` is added by later tasks.
pub type Context {
  Context(
    config: Config,
    db_path: String,
    now: fn() -> Timestamp,
    private_key: rsa.PrivateKey,
  )
}
