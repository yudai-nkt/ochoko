//// Ids of inbox activities already handled (table `processed_activities`).

import gleam/dynamic/decode
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import sqlight

pub fn is_processed(
  conn: sqlight.Connection,
  uri: String,
) -> Result(Bool, sqlight.Error) {
  sqlight.query(
    "SELECT 1 FROM processed_activities WHERE uri = ?",
    on: conn,
    with: [sqlight.text(uri)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map(fn(rows) { rows != [] })
}

pub fn mark(
  conn: sqlight.Connection,
  uri: String,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  sqlight.query(
    "INSERT OR IGNORE INTO processed_activities (uri, received_at) VALUES (?, ?)",
    on: conn,
    with: [sqlight.text(uri), sqlight.int(seconds)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}
