//// Serializes password verification. Argon2 is deliberately expensive in
//// CPU and memory, so concurrent login attempts must not run it in
//// parallel: one runs at a time, and an attempt that cannot get its turn
//// within the timeout is turned away.

/// How long a login attempt waits for its turn, in milliseconds.
pub const wait_ms = 1000

@external(erlang, "ochoko_ffi", "with_lock")
fn with_lock(name: String, timeout_ms: Int, f: fn() -> a) -> Result(a, Nil)

/// Runs `f` while holding the login lock, waiting up to `timeout_ms` for it.
/// `Error(Nil)` if the lock stayed busy (and `f` did not run).
pub fn run(timeout_ms: Int, f: fn() -> a) -> Result(a, Nil) {
  with_lock("login", timeout_ms, f)
}
