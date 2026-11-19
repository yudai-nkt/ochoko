//// Persistent outgoing-delivery queue (table `deliveries`).

import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import sqlight

/// A claimed delivery row.
pub type Delivery {
  Delivery(id: Int, inbox: String, body: String, attempts: Int)
}

pub fn unix(now: Timestamp) -> Int {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  seconds
}

/// Queue `body` once for each distinct inbox, due immediately.
pub fn enqueue(
  conn: sqlight.Connection,
  inboxes: List(String),
  body: String,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  let at = unix(now)
  list.unique(inboxes)
  |> list.try_each(fn(inbox) {
    sqlight.query(
      "INSERT INTO deliveries (inbox, body, next_attempt_at, created_at)
       VALUES (?, ?, ?, ?)",
      on: conn,
      with: [
        sqlight.text(inbox),
        sqlight.text(body),
        sqlight.int(at),
        sqlight.int(at),
      ],
      expecting: decode.success(Nil),
    )
    |> result.replace(Nil)
  })
}

/// The inbox to deliver to for each follower: the shared inbox when known,
/// else the personal inbox; deduplicated.
pub fn inboxes_for_followers(conn: sqlight.Connection) -> List(String) {
  sqlight.query(
    "SELECT DISTINCT COALESCE(r.shared_inbox, r.inbox)
     FROM followers f JOIN remote_actors r ON r.id = f.actor_id
     ORDER BY 1",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> result.unwrap([])
}

/// Atomically claim up to `limit` due, unlocked rows by locking them until
/// `now + lock_seconds`.
pub fn claim_due(
  conn: sqlight.Connection,
  now: Timestamp,
  limit: Int,
  lock_seconds: Int,
) -> Result(List(Delivery), sqlight.Error) {
  let at = unix(now)
  sqlight.query(
    "UPDATE deliveries SET locked_until = ?
     WHERE id IN (
       SELECT id FROM deliveries
       WHERE next_attempt_at <= ? AND locked_until <= ?
       ORDER BY next_attempt_at, id LIMIT ?)
     RETURNING id, inbox, body, attempts",
    on: conn,
    with: [
      sqlight.int(at + lock_seconds),
      sqlight.int(at),
      sqlight.int(at),
      sqlight.int(limit),
    ],
    expecting: {
      use id <- decode.field(0, decode.int)
      use inbox <- decode.field(1, decode.string)
      use body <- decode.field(2, decode.string)
      use attempts <- decode.field(3, decode.int)
      decode.success(Delivery(id:, inbox:, body:, attempts:))
    },
  )
}

pub fn delete(conn: sqlight.Connection, id: Int) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "DELETE FROM deliveries WHERE id = ?",
    on: conn,
    with: [sqlight.int(id)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

/// Record a failed attempt: bump `attempts`, set the next due time, unlock.
pub fn reschedule(
  conn: sqlight.Connection,
  id: Int,
  attempts: Int,
  next_attempt_at: Int,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "UPDATE deliveries
     SET attempts = ?, next_attempt_at = ?, locked_until = 0 WHERE id = ?",
    on: conn,
    with: [
      sqlight.int(attempts),
      sqlight.int(next_attempt_at),
      sqlight.int(id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}
