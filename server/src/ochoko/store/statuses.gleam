//// Statuses: remote ones received over federation, and our own.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import ochoko/config.{type Config}
import ochoko/federation/note.{type Attachment, type InboundNote, Attachment}
import ochoko/id
import ochoko/store/page.{type Page}
import ochoko_shared/mastodon.{
  type Visibility, Direct, Private, Public, Unlisted,
}
import sqlight

pub type StatusRow {
  StatusRow(
    id: Int,
    uri: String,
    actor_id: Option(Int),
    content_html: String,
    text: Option(String),
    spoiler_text: String,
    sensitive: Bool,
    visibility: Visibility,
    url: Option(String),
    in_reply_to_uri: Option(String),
    language: Option(String),
    published_at: Timestamp,
    deleted_at: Option(Timestamp),
    attachments: List(Attachment),
  )
}

fn unix(at: Timestamp) -> Int {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds
}

fn visibility_text(v: Visibility) -> String {
  mastodon.visibility_to_string(v)
}

fn visibility_from_text(s: String) -> Visibility {
  case s {
    "public" -> Public
    "unlisted" -> Unlisted
    "private" -> Private
    _ -> Direct
  }
}

fn nullable(value: Option(String)) -> sqlight.Value {
  sqlight.nullable(sqlight.text, value)
}

/// Stores a note of remote actor `actor_id`; a note with a known URI is left
/// untouched. A `published` date in the future is clamped to `now`, and the
/// ID is derived from the (clamped) publication time.
pub fn insert_remote(
  conn: sqlight.Connection,
  actor_id: Int,
  n: InboundNote,
  v: Visibility,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  let published = case n.published {
    Some(p) ->
      case timestamp.compare(p, now) {
        order.Gt -> now
        _ -> p
      }
    None -> now
  }
  let status_id = id.generate(published)
  use inserted <- result.try(sqlight.query(
    "INSERT OR IGNORE INTO statuses
         (id, uri, actor_id, content_html, text, spoiler_text, sensitive,
          visibility, url, in_reply_to_uri, language, published_at)
       VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)
       RETURNING id",
    on: conn,
    with: [
      sqlight.int(status_id),
      sqlight.text(n.uri),
      sqlight.int(actor_id),
      sqlight.text(n.content_html),
      sqlight.text(n.spoiler_text),
      sqlight.bool(n.sensitive),
      sqlight.text(visibility_text(v)),
      nullable(n.url),
      nullable(n.in_reply_to),
      nullable(n.language),
      sqlight.int(unix(published)),
    ],
    expecting: decode.at([0], decode.int),
  ))
  case inserted {
    [] -> Ok(Nil)
    _ ->
      list.index_map(n.attachments, fn(a, position) {
        sqlight.query(
          "INSERT INTO media_attachments
             (id, status_id, remote_url, media_type, description, blurhash,
              position)
           VALUES (?, ?, ?, ?, ?, ?, ?)",
          on: conn,
          with: [
            sqlight.int(id.generate(published)),
            sqlight.int(status_id),
            sqlight.text(a.url),
            nullable(a.media_type),
            nullable(a.description),
            nullable(a.blurhash),
            sqlight.int(position),
          ],
          expecting: decode.success(Nil),
        )
      })
      |> result.all
      |> result.replace(Nil)
  }
}

/// Stores a status of our own (`actor_id` NULL, raw `text` kept) and returns
/// it. Its ID derives from `now`; its URI and URL are `config.status_uri`.
pub fn insert_own(
  conn: sqlight.Connection,
  c: Config,
  text: String,
  html: String,
  v: Visibility,
  spoiler: String,
  sensitive: Bool,
  language: Option(String),
  now: Timestamp,
) -> Result(StatusRow, sqlight.Error) {
  let status_id = id.generate(now)
  let uri = config.status_uri(c, status_id)
  use _ <- result.try(sqlight.query(
    "INSERT INTO statuses
         (id, uri, actor_id, content_html, text, spoiler_text, sensitive,
          visibility, url, in_reply_to_uri, language, published_at)
       VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, NULL, ?, ?)",
    on: conn,
    with: [
      sqlight.int(status_id),
      sqlight.text(uri),
      sqlight.text(html),
      sqlight.text(text),
      sqlight.text(spoiler),
      sqlight.bool(sensitive),
      sqlight.text(visibility_text(v)),
      sqlight.text(uri),
      nullable(language),
      sqlight.int(unix(now)),
    ],
    expecting: decode.success(Nil),
  ))
  StatusRow(
    id: status_id,
    uri:,
    actor_id: None,
    content_html: html,
    text: Some(text),
    spoiler_text: spoiler,
    sensitive:,
    visibility: v,
    url: Some(uri),
    in_reply_to_uri: None,
    language:,
    published_at: timestamp.from_unix_seconds(unix(now)),
    deleted_at: None,
    attachments: [],
  )
  |> Ok
}

/// Marks our own status `id` as deleted (the row is kept as a tombstone).
pub fn mark_deleted(
  conn: sqlight.Connection,
  id: Int,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "UPDATE statuses SET deleted_at = ?
     WHERE id = ? AND actor_id IS NULL AND deleted_at IS NULL",
    on: conn,
    with: [sqlight.int(unix(now)), sqlight.int(id)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

/// The status `id`, deleted or not.
pub fn get(
  conn: sqlight.Connection,
  id: Int,
) -> Result(Option(StatusRow), sqlight.Error) {
  use rows <- result.try(sqlight.query(
    "SELECT " <> select_columns <> " FROM statuses WHERE id = ?",
    on: conn,
    with: [sqlight.int(id)],
    expecting: status_decoder(),
  ))
  use rows <- result.map(load_attachments(conn, list.take(rows, 1)))
  list.first(rows) |> option.from_result
}

/// How long an `Idempotency-Key` stays valid, in seconds.
const idempotency_ttl = 3600

/// The live status previously created under `key`, if any. Expired keys are
/// purged on the way.
pub fn find_by_idempotency_key(
  conn: sqlight.Connection,
  key: String,
  now: Timestamp,
) -> Result(Option(StatusRow), sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "DELETE FROM idempotency_keys WHERE created_at <= ?",
    on: conn,
    with: [sqlight.int(unix(now) - idempotency_ttl)],
    expecting: decode.success(Nil),
  ))
  use ids <- result.try(sqlight.query(
    "SELECT status_id FROM idempotency_keys WHERE key = ?",
    on: conn,
    with: [sqlight.text(key)],
    expecting: decode.at([0], decode.int),
  ))
  case ids {
    [status_id, ..] ->
      get(conn, status_id)
      |> result.map(
        option.then(_, fn(row) {
          case row.deleted_at {
            None -> Some(row)
            Some(_) -> None
          }
        }),
      )
    [] -> Ok(None)
  }
}

pub fn remember_idempotency_key(
  conn: sqlight.Connection,
  key: String,
  status_id: Int,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "INSERT OR REPLACE INTO idempotency_keys (key, status_id, created_at)
     VALUES (?, ?, ?)",
    on: conn,
    with: [sqlight.text(key), sqlight.int(status_id), sqlight.int(unix(now))],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

/// Deletes the status `uri`, but only if it belongs to `actor_id`.
pub fn delete_remote(
  conn: sqlight.Connection,
  uri: String,
  actor_id: Int,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "DELETE FROM statuses WHERE uri = ? AND actor_id = ?",
    on: conn,
    with: [sqlight.text(uri), sqlight.int(actor_id)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

fn optional_time(unix_seconds: Option(Int)) -> Option(Timestamp) {
  option.map(unix_seconds, timestamp.from_unix_seconds)
}

const select_columns =
  "id, uri, actor_id, content_html, text, spoiler_text, sensitive,
   visibility, url, in_reply_to_uri, language, published_at, deleted_at"

fn status_decoder() -> decode.Decoder(StatusRow) {
  use id <- decode.field(0, decode.int)
  use uri <- decode.field(1, decode.string)
  use actor_id <- decode.field(2, decode.optional(decode.int))
  use content_html <- decode.field(3, decode.string)
  use text <- decode.field(4, decode.optional(decode.string))
  use spoiler_text <- decode.field(5, decode.string)
  use sensitive <- decode.field(6, sqlight.decode_bool())
  use visibility <- decode.field(7, decode.string)
  use url <- decode.field(8, decode.optional(decode.string))
  use in_reply_to_uri <- decode.field(9, decode.optional(decode.string))
  use language <- decode.field(10, decode.optional(decode.string))
  use published_at <- decode.field(11, decode.int)
  use deleted_at <- decode.field(12, decode.optional(decode.int))
  decode.success(
    StatusRow(
      id:,
      uri:,
      actor_id:,
      content_html:,
      text:,
      spoiler_text:,
      sensitive:,
      visibility: visibility_from_text(visibility),
      url:,
      in_reply_to_uri:,
      language:,
      published_at: timestamp.from_unix_seconds(published_at),
      deleted_at: optional_time(deleted_at),
      attachments: [],
    ),
  )
}

fn load_attachments(
  conn: sqlight.Connection,
  rows: List(StatusRow),
) -> Result(List(StatusRow), sqlight.Error) {
  list.try_map(rows, fn(row) {
    use attachments <- result.map(attachments_of(conn, row.id))
    StatusRow(..row, attachments:)
  })
}

pub fn get_by_uri(
  conn: sqlight.Connection,
  uri: String,
) -> Result(Option(StatusRow), sqlight.Error) {
  use rows <- result.try(sqlight.query(
    "SELECT " <> select_columns <> " FROM statuses WHERE uri = ?",
    on: conn,
    with: [sqlight.text(uri)],
    expecting: status_decoder(),
  ))
  use rows <- result.map(load_attachments(conn, list.take(rows, 1)))
  list.first(rows) |> option.from_result
}

/// Number of non-deleted statuses of `actor_id` (`None`: our own).
pub fn count_by_actor(
  conn: sqlight.Connection,
  actor_id: Option(Int),
) -> Result(Int, sqlight.Error) {
  let #(where_, args) = actor_clause(actor_id)
  sqlight.query(
    "SELECT COUNT(*) FROM statuses WHERE deleted_at IS NULL AND " <> where_,
    on: conn,
    with: args,
    expecting: decode.at([0], decode.int),
  )
  |> result.map(fn(rows) { list.first(rows) |> result.unwrap(0) })
}

fn actor_clause(actor_id: Option(Int)) -> #(String, List(sqlight.Value)) {
  case actor_id {
    Some(id) -> #("actor_id = ?", [sqlight.int(id)])
    None -> #("actor_id IS NULL", [])
  }
}

/// A page of the non-deleted, non-direct statuses of `actor_id` (`None`: our
/// own), newest first. `min_id` pages forward: the `limit` statuses just
/// newer than it, still returned newest first.
pub fn list_by_actor(
  conn: sqlight.Connection,
  actor_id: Option(Int),
  page: Page,
) -> Result(List(StatusRow), sqlight.Error) {
  let #(actor_sql, actor_args) = actor_clause(actor_id)
  let bounds = [
    #("id < ?", page.max_id),
    #("id > ?", page.since_id),
    #("id > ?", page.min_id),
  ]
  let #(bound_sql, bound_args) =
    list.fold(bounds, #([], []), fn(acc, bound) {
      case bound.1 {
        Some(n) -> #([" AND " <> bound.0, ..acc.0], [sqlight.int(n), ..acc.1])
        None -> acc
      }
    })
  let ascending = option.is_some(page.min_id)
  use rows <- result.try(sqlight.query(
    "SELECT "
      <> select_columns
      <> " FROM statuses WHERE deleted_at IS NULL AND visibility != 'direct' AND "
      <> actor_sql
      <> string.concat(list.reverse(bound_sql))
      <> case ascending {
      True -> " ORDER BY id ASC LIMIT ?"
      False -> " ORDER BY id DESC LIMIT ?"
    },
    on: conn,
    with: list.flatten([
      actor_args,
      list.reverse(bound_args),
      [sqlight.int(page.limit)],
    ]),
    expecting: status_decoder(),
  ))
  let rows = case ascending {
    True -> list.reverse(rows)
    False -> rows
  }
  load_attachments(conn, rows)
}

fn attachments_of(
  conn: sqlight.Connection,
  status_id: Int,
) -> Result(List(Attachment), sqlight.Error) {
  sqlight.query(
    "SELECT remote_url, media_type, description, blurhash
     FROM media_attachments WHERE status_id = ? ORDER BY position",
    on: conn,
    with: [sqlight.int(status_id)],
    expecting: {
      use url <- decode.field(0, decode.string)
      use media_type <- decode.field(1, decode.optional(decode.string))
      use description <- decode.field(2, decode.optional(decode.string))
      use blurhash <- decode.field(3, decode.optional(decode.string))
      decode.success(Attachment(url:, media_type:, description:, blurhash:))
    },
  )
}
