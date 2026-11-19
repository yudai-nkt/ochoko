import argv
import gleam/io
import gleam/option.{Some}
import gleam/result
import gleam/string
import ochoko/cli
import ochoko/config
import ochoko/crypto/rsa
import ochoko/db
import ochoko/store/profile
import simplifile
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
    Ok(cli.Keygen(out_path)) ->
      case run_keygen(out_path) {
        Error(msg) -> {
          io.println_error("error: " <> msg)
          halt(1)
        }
        Ok(public_pem) -> io.print(public_pem)
      }
    Ok(command) ->
      io.println(string.inspect(command) <> ": not implemented yet")
  }
}

fn run_keygen(out_path: String) -> Result(String, String) {
  let key = rsa.generate(2048)
  let describe = fn(e) { out_path <> ": " <> simplifile.describe_error(e) }
  // Create the file with 0600 before writing the secret into it.
  use _ <- result.try(
    simplifile.create_file(out_path) |> result.map_error(describe),
  )
  use _ <- result.try(
    simplifile.set_permissions_octal(out_path, 0o600)
    |> result.map_error(describe),
  )
  use _ <- result.try(
    simplifile.write(out_path, rsa.private_to_pem(key))
    |> result.map_error(describe),
  )
  Ok(rsa.public_pem(key))
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
