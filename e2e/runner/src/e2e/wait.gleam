//// Polling for asynchronous federation, instead of fixed sleeps.

import gleam/erlang/process

const interval_ms = 500

const attempts = 120

/// Retry `check` until it returns `Ok` or about a minute has passed. The
/// error names what we waited for and the last failure.
pub fn until(
  what: String,
  check: fn() -> Result(a, String),
) -> Result(a, String) {
  loop(what, check, attempts)
}

fn loop(
  what: String,
  check: fn() -> Result(a, String),
  left: Int,
) -> Result(a, String) {
  case check() {
    Ok(value) -> Ok(value)
    Error(last) if left <= 1 ->
      Error("timed out waiting for " <> what <> " (last: " <> last <> ")")
    Error(_) -> {
      process.sleep(interval_ms)
      loop(what, check, left - 1)
    }
  }
}
