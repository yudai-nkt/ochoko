//// User-facing notifications (table `notifications`).

import gleam/dynamic/decode
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import ochoko/id
import sqlight

/// Records a follow notification; a repeated `activity_uri` is ignored.
pub fn add_follow(
  conn: sqlight.Connection,
  actor_id: Int,
  activity_uri: String,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  sqlight.query(
    "INSERT OR IGNORE INTO notifications (id, type, actor_id, activity_uri, created_at)
     VALUES (?, 'follow', ?, ?, ?)",
    on: conn,
    with: [
      sqlight.int(id.generate(now)),
      sqlight.int(actor_id),
      sqlight.text(activity_uri),
      sqlight.int(seconds),
    ],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}
