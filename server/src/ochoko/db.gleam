import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import ochoko/db/migrations
import sqlight

/// Open a connection and apply the standard pragmas.
pub fn open(path: String) -> Result(sqlight.Connection, sqlight.Error) {
  use conn <- result.try(sqlight.open(path))
  let journal = case path {
    ":memory:" -> ""
    _ -> "PRAGMA journal_mode = WAL;"
  }
  case
    sqlight.exec(
      journal <> "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;",
      on: conn,
    )
  {
    Ok(Nil) -> Ok(conn)
    Error(e) -> {
      let _ = sqlight.close(conn)
      Error(e)
    }
  }
}

/// Open a connection, run `f`, and close the connection afterwards.
pub fn with_connection(path: String, f: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = open(path)
  let result = f(conn)
  let _ = sqlight.close(conn)
  result
}

/// Apply pending migrations, tracking progress in `PRAGMA user_version`.
pub fn migrate(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  use current <- result.try(user_version(conn))
  migrations.all()
  |> list.index_map(fn(sql, i) { #(i + 1, sql) })
  |> list.filter(fn(m) { m.0 > current })
  |> list.try_each(fn(m) { apply(conn, m.0, m.1) })
}

fn apply(
  conn: sqlight.Connection,
  version: Int,
  sql: String,
) -> Result(Nil, sqlight.Error) {
  let script =
    "BEGIN;\n"
    <> sql
    <> "\nPRAGMA user_version = "
    <> int.to_string(version)
    <> ";\nCOMMIT;"
  case sqlight.exec(script, on: conn) {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> {
      let _ = sqlight.exec("ROLLBACK", on: conn)
      Error(e)
    }
  }
}

fn user_version(conn: sqlight.Connection) -> Result(Int, sqlight.Error) {
  use rows <- result.map(
    sqlight.query("PRAGMA user_version", on: conn, with: [], expecting: {
      use n <- decode.field(0, decode.int)
      decode.success(n)
    }),
  )
  case rows {
    [n, ..] -> n
    [] -> 0
  }
}
