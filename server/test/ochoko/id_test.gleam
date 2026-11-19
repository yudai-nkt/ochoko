import gleam/time/timestamp
import ochoko/id

pub fn ids_are_time_ordered_test() {
  let t1 = timestamp.from_unix_seconds_and_nanoseconds(1_700_000_000, 1_000_000)
  let t2 = timestamp.from_unix_seconds_and_nanoseconds(1_700_000_000, 2_000_000)
  assert id.generate(t1) < id.generate(t2)
  assert id.floor(t1) <= id.generate(t1)
}
