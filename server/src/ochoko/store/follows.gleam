import gleam/dynamic/decode
import gleam/result
import sqlight

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
