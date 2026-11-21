import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import sqlight

/// Whether our follow request to a remote actor has been accepted.
pub type State {
  Pending
  Accepted
}

pub fn follower_count(conn: sqlight.Connection) -> Result(Int, sqlight.Error) {
  count(conn, "SELECT COUNT(*) FROM followers")
}

pub fn following_count(conn: sqlight.Connection) -> Result(Int, sqlight.Error) {
  count(conn, "SELECT COUNT(*) FROM following")
}

fn count(conn: sqlight.Connection, sql: String) -> Result(Int, sqlight.Error) {
  sqlight.query(sql, on: conn, with: [], expecting: decode.at([0], decode.int))
  |> result.map(fn(rows) {
    case rows {
      [n, ..] -> n
      [] -> 0
    }
  })
}

fn unix(now: Timestamp) -> Int {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  seconds
}

fn run(
  conn: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
) -> Result(Nil, sqlight.Error) {
  sqlight.query(sql, on: conn, with: args, expecting: decode.success(Nil))
  |> result.replace(Nil)
}

/// Adds `actor_id` as a follower, or just records the newer `follow_uri` of
/// an existing follower.
pub fn add_follower(
  conn: sqlight.Connection,
  actor_id: Int,
  follow_uri: String,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  run(
    conn,
    "INSERT INTO followers (actor_id, follow_uri, created_at) VALUES (?, ?, ?)
     ON CONFLICT (actor_id) DO UPDATE SET follow_uri = excluded.follow_uri",
    [sqlight.int(actor_id), sqlight.text(follow_uri), sqlight.int(unix(now))],
  )
}

pub fn remove_follower(
  conn: sqlight.Connection,
  actor_id: Int,
) -> Result(Nil, sqlight.Error) {
  run(conn, "DELETE FROM followers WHERE actor_id = ?", [sqlight.int(actor_id)])
}

/// Removes the follower only if its stored Follow has id `follow_uri`.
pub fn remove_follower_by_follow(
  conn: sqlight.Connection,
  actor_id: Int,
  follow_uri: String,
) -> Result(Nil, sqlight.Error) {
  run(conn, "DELETE FROM followers WHERE actor_id = ? AND follow_uri = ?", [
    sqlight.int(actor_id),
    sqlight.text(follow_uri),
  ])
}

pub fn is_follower(
  conn: sqlight.Connection,
  actor_id: Int,
) -> Result(Bool, sqlight.Error) {
  sqlight.query(
    "SELECT 1 FROM followers WHERE actor_id = ?",
    on: conn,
    with: [sqlight.int(actor_id)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map(fn(rows) { rows != [] })
}

/// Records a pending follow request of ours.
pub fn add_following(
  conn: sqlight.Connection,
  actor_id: Int,
  follow_uri: String,
  now: Timestamp,
) -> Result(Nil, sqlight.Error) {
  run(
    conn,
    "INSERT INTO following (actor_id, state, follow_uri, created_at)
     VALUES (?, 'pending', ?, ?)
     ON CONFLICT (actor_id) DO UPDATE SET
       state = 'pending', follow_uri = excluded.follow_uri",
    [sqlight.int(actor_id), sqlight.text(follow_uri), sqlight.int(unix(now))],
  )
}

pub fn set_following_accepted(
  conn: sqlight.Connection,
  actor_id: Int,
) -> Result(Nil, sqlight.Error) {
  run(conn, "UPDATE following SET state = 'accepted' WHERE actor_id = ?", [
    sqlight.int(actor_id),
  ])
}

pub fn remove_following(
  conn: sqlight.Connection,
  actor_id: Int,
) -> Result(Nil, sqlight.Error) {
  run(conn, "DELETE FROM following WHERE actor_id = ?", [sqlight.int(actor_id)])
}

pub fn is_following(
  conn: sqlight.Connection,
  actor_id: Int,
) -> Result(Option(State), sqlight.Error) {
  sqlight.query(
    "SELECT state FROM following WHERE actor_id = ?",
    on: conn,
    with: [sqlight.int(actor_id)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map(fn(rows) {
    case rows {
      ["accepted", ..] -> Some(Accepted)
      ["pending", ..] -> Some(Pending)
      _ -> None
    }
  })
}

/// Remote actor ids of the followers, newest first.
pub fn followers(conn: sqlight.Connection) -> Result(List(Int), sqlight.Error) {
  actor_ids(conn, "followers")
}

/// Remote actor ids of the accounts we follow (any state), newest first.
pub fn following(conn: sqlight.Connection) -> Result(List(Int), sqlight.Error) {
  actor_ids(conn, "following")
}

fn actor_ids(
  conn: sqlight.Connection,
  table: String,
) -> Result(List(Int), sqlight.Error) {
  sqlight.query(
    "SELECT actor_id FROM "
      <> table
      <> " ORDER BY created_at DESC, actor_id DESC",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
}

/// The id of the Follow activity of the remote follower `actor_id`.
pub fn follower_follow_uri(
  conn: sqlight.Connection,
  actor_id: Int,
) -> Result(Option(String), sqlight.Error) {
  follow_uri(conn, "followers", actor_id)
}

/// The id of our Follow activity to the remote actor `actor_id`.
pub fn following_follow_uri(
  conn: sqlight.Connection,
  actor_id: Int,
) -> Result(Option(String), sqlight.Error) {
  follow_uri(conn, "following", actor_id)
}

fn follow_uri(
  conn: sqlight.Connection,
  table: String,
  actor_id: Int,
) -> Result(Option(String), sqlight.Error) {
  sqlight.query(
    "SELECT follow_uri FROM " <> table <> " WHERE actor_id = ?",
    on: conn,
    with: [sqlight.int(actor_id)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map(fn(rows) {
    case rows {
      [uri, ..] -> Some(uri)
      [] -> None
    }
  })
}
