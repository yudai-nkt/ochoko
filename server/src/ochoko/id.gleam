import gleam/int
import gleam/time/timestamp.{type Timestamp}

@external(erlang, "ochoko_ffi", "unique_positive")
fn unique_positive() -> Int

fn unix_ms(at: Timestamp) -> Int {
  let #(seconds, nanos) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1000 + nanos / 1_000_000
}

/// Smallest ID that could be generated at `at`; for time-based comparisons.
pub fn floor(at: Timestamp) -> Int {
  int.bitwise_shift_left(unix_ms(at), 16)
}

/// Time-ordered ID: milliseconds since the epoch in the high bits, and 16
/// bits of a node-local unique integer in the low bits.
pub fn generate(at: Timestamp) -> Int {
  int.bitwise_or(floor(at), int.bitwise_and(unique_positive(), 0xFFFF))
}
