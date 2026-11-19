import gleam/time/timestamp.{type Timestamp}
import ochoko/config.{type Config}

/// Application context. `send` and `private_key` are added by later tasks.
pub type Context {
  Context(config: Config, db_path: String, now: fn() -> Timestamp)
}
