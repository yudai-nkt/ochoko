//// User-facing notifications (table `notifications`).

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import ochoko/id
import ochoko/store/page.{type Page}
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

pub type Kind {
  Follow
}

pub type NotificationRow {
  NotificationRow(id: Int, kind: Kind, actor_id: Int, created_at: Timestamp)
}

fn row_decoder() -> decode.Decoder(NotificationRow) {
  use id <- decode.field(0, decode.int)
  use actor_id <- decode.field(1, decode.int)
  use created_at <- decode.field(2, decode.int)
  decode.success(NotificationRow(
    id:,
    kind: Follow,
    actor_id:,
    created_at: timestamp.from_unix_seconds(created_at),
  ))
}

/// A page of notifications, newest first (`min_id` pages forward).
pub fn list(
  conn: sqlight.Connection,
  page: Page,
) -> Result(List(NotificationRow), sqlight.Error) {
  let #(bound_sql, bound_args) = page.bounds(page)
  sqlight.query(
    "SELECT id, actor_id, created_at FROM notifications WHERE 1 = 1"
      <> bound_sql
      <> page.order_limit(page),
    on: conn,
    with: list.append(bound_args, [sqlight.int(page.limit)]),
    expecting: row_decoder(),
  )
  |> result.map(page.finish(page, _))
}

pub fn get(
  conn: sqlight.Connection,
  id: Int,
) -> Result(Option(NotificationRow), sqlight.Error) {
  sqlight.query(
    "SELECT id, actor_id, created_at FROM notifications WHERE id = ?",
    on: conn,
    with: [sqlight.int(id)],
    expecting: row_decoder(),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

pub fn clear(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "DELETE FROM notifications",
    on: conn,
    with: [],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

pub fn dismiss(
  conn: sqlight.Connection,
  id: Int,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "DELETE FROM notifications WHERE id = ?",
    on: conn,
    with: [sqlight.int(id)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}
