import argv
import gleam/io
import gleam/option.{Some}
import gleam/result
import gleam/string
import ochoko/cli
import ochoko/config
import ochoko/db
import ochoko/store/profile
import sqlight

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> a

pub fn main() -> Nil {
  case cli.parse_args(argv.load().arguments) {
    Error(msg) -> {
      io.println_error(msg)
      halt(2)
    }
    Ok(cli.Serve(path)) ->
      case config.load(path) {
        Error(msg) -> {
          io.println_error("error: " <> msg)
          halt(1)
        }
        Ok(c) ->
          io.println(
            "config loaded for " <> config.acct(c) <> "; server not wired yet",
          )
      }
    Ok(cli.Profile(path, display_name, note, avatar_url)) ->
      case run_profile(path, display_name, note, avatar_url) {
        Error(msg) -> {
          io.println_error("error: " <> msg)
          halt(1)
        }
        Ok(p) -> {
          io.println("display name: " <> p.display_name)
          io.println("note: " <> p.note)
          io.println("avatar url: " <> option.unwrap(p.avatar_url, ""))
          io.println("header url: " <> option.unwrap(p.header_url, ""))
        }
      }
    Ok(command) ->
      io.println(string.inspect(command) <> ": not implemented yet")
  }
}

fn run_profile(
  config_path: String,
  display_name: Result(String, Nil),
  note: Result(String, Nil),
  avatar_url: Result(String, Nil),
) -> Result(profile.Profile, String) {
  use c <- result.try(config.load(config_path))
  use conn <- result.try(
    db.open(c.database_path) |> result.map_error(describe_db_error),
  )
  let outcome = {
    use _ <- result.try(db.migrate(conn))
    use current <- result.try(profile.get(conn))
    let updated =
      profile.Profile(
        display_name: result.unwrap(display_name, current.display_name),
        note: result.unwrap(note, current.note),
        avatar_url: case avatar_url {
          Ok(url) -> Some(url)
          Error(Nil) -> current.avatar_url
        },
        header_url: current.header_url,
      )
    use _ <- result.try(profile.update(conn, updated))
    profile.get(conn)
  }
  let _ = sqlight.close(conn)
  outcome |> result.map_error(describe_db_error)
}

fn describe_db_error(e: sqlight.Error) -> String {
  "database: " <> e.message
}
