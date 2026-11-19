import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/result
import gleam/string
import ochoko/federation/remote_actor_types.{type RemoteActor, RemoteActor}
import sqlight

const columns =
  "id, uri, username, domain, display_name, summary_html, avatar_url, header_url, url, inbox, shared_inbox, followers_uri, public_key_id, public_key_pem, bot, locked"

fn row() -> decode.Decoder(RemoteActor) {
  use id <- decode.field(0, decode.int)
  use uri <- decode.field(1, decode.string)
  use username <- decode.field(2, decode.string)
  use domain <- decode.field(3, decode.string)
  use display_name <- decode.field(4, decode.string)
  use summary_html <- decode.field(5, decode.string)
  use avatar_url <- decode.field(6, decode.optional(decode.string))
  use header_url <- decode.field(7, decode.optional(decode.string))
  use url <- decode.field(8, decode.optional(decode.string))
  use inbox <- decode.field(9, decode.string)
  use shared_inbox <- decode.field(10, decode.optional(decode.string))
  use followers_uri <- decode.field(11, decode.optional(decode.string))
  use public_key_id <- decode.field(12, decode.string)
  use public_key_pem <- decode.field(13, decode.string)
  use bot <- decode.field(14, sqlight.decode_bool())
  use locked <- decode.field(15, sqlight.decode_bool())
  decode.success(RemoteActor(
    id:,
    uri:,
    username:,
    domain:,
    display_name:,
    summary_html:,
    avatar_url:,
    header_url:,
    url:,
    inbox:,
    shared_inbox:,
    followers_uri:,
    public_key_id:,
    public_key_pem:,
    bot:,
    locked:,
  ))
}

/// Inserts the actor, or refreshes the existing row with the same `uri`, and
/// returns the stored row (with its id).
pub fn upsert(
  conn: sqlight.Connection,
  actor: RemoteActor,
  fetched_at: Int,
) -> Result(RemoteActor, sqlight.Error) {
  let sql =
    "INSERT INTO remote_actors (uri, username, domain, display_name, summary_html, avatar_url, header_url, url, inbox, shared_inbox, followers_uri, public_key_id, public_key_pem, bot, locked, fetched_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (uri) DO UPDATE SET
       username = excluded.username,
       domain = excluded.domain,
       display_name = excluded.display_name,
       summary_html = excluded.summary_html,
       avatar_url = excluded.avatar_url,
       header_url = excluded.header_url,
       url = excluded.url,
       inbox = excluded.inbox,
       shared_inbox = excluded.shared_inbox,
       followers_uri = excluded.followers_uri,
       public_key_id = excluded.public_key_id,
       public_key_pem = excluded.public_key_pem,
       bot = excluded.bot,
       locked = excluded.locked,
       fetched_at = excluded.fetched_at
     RETURNING "
    <> columns
  use rows <- result.try(sqlight.query(
    sql,
    on: conn,
    with: [
      sqlight.text(actor.uri),
      sqlight.text(actor.username),
      sqlight.text(actor.domain),
      sqlight.text(actor.display_name),
      sqlight.text(actor.summary_html),
      sqlight.nullable(sqlight.text, actor.avatar_url),
      sqlight.nullable(sqlight.text, actor.header_url),
      sqlight.nullable(sqlight.text, actor.url),
      sqlight.text(actor.inbox),
      sqlight.nullable(sqlight.text, actor.shared_inbox),
      sqlight.nullable(sqlight.text, actor.followers_uri),
      sqlight.text(actor.public_key_id),
      sqlight.text(actor.public_key_pem),
      sqlight.bool(actor.bot),
      sqlight.bool(actor.locked),
      sqlight.int(fetched_at),
    ],
    expecting: row(),
  ))
  case rows {
    [stored, ..] -> Ok(stored)
    [] ->
      Error(sqlight.SqlightError(
        sqlight.GenericError,
        "upsert returned no row",
        -1,
      ))
  }
}

fn first(
  rows: Result(List(a), sqlight.Error),
) -> Result(Option(a), sqlight.Error) {
  use rows <- result.map(rows)
  case rows {
    [x, ..] -> option.Some(x)
    [] -> option.None
  }
}

pub fn get(
  conn: sqlight.Connection,
  id: Int,
) -> Result(Option(RemoteActor), sqlight.Error) {
  sqlight.query(
    "SELECT " <> columns <> " FROM remote_actors WHERE id = ?",
    on: conn,
    with: [sqlight.int(id)],
    expecting: row(),
  )
  |> first
}

pub fn get_by_uri(
  conn: sqlight.Connection,
  uri: String,
) -> Result(Option(RemoteActor), sqlight.Error) {
  sqlight.query(
    "SELECT " <> columns <> " FROM remote_actors WHERE uri = ?",
    on: conn,
    with: [sqlight.text(uri)],
    expecting: row(),
  )
  |> first
}

/// The row for `uri` together with its `fetched_at` (unix seconds).
pub fn get_cached(
  conn: sqlight.Connection,
  uri: String,
) -> Result(Option(#(RemoteActor, Int)), sqlight.Error) {
  sqlight.query(
    "SELECT " <> columns <> ", fetched_at FROM remote_actors WHERE uri = ?",
    on: conn,
    with: [sqlight.text(uri)],
    expecting: {
      use actor <- decode.then(row())
      use fetched_at <- decode.field(16, decode.int)
      decode.success(#(actor, fetched_at))
    },
  )
  |> first
}

/// Case-insensitive prefix match on `username` or `username@domain`.
pub fn search_prefix(
  conn: sqlight.Connection,
  q: String,
  limit: Int,
) -> Result(List(RemoteActor), sqlight.Error) {
  let pattern =
    q
    |> string.trim
    |> string.drop_start(case string.starts_with(q, "@") {
      True -> 1
      False -> 0
    })
    |> string.replace("\\", "\\\\")
    |> string.replace("%", "\\%")
    |> string.replace("_", "\\_")
  sqlight.query("SELECT " <> columns <> " FROM remote_actors
         WHERE lower(username || '@' || domain) LIKE lower(?) || '%' ESCAPE '\\'
         ORDER BY lower(username), domain
         LIMIT ?", on: conn, with: [sqlight.text(pattern), sqlight.int(limit)], expecting: row())
}
