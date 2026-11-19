import argus
import argv
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/result
import gleam/time/timestamp
import ochoko/cli
import ochoko/config
import ochoko/context.{Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/http_client
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
    Ok(cli.Fetch(path, url)) ->
      case run_fetch(path, url) {
        Error(msg) -> {
          io.println_error("error: " <> msg)
          halt(1)
        }
        Ok(res) -> {
          io.println("HTTP " <> int.to_string(res.status))
          io.println(res.body)
        }
      }
    Ok(cli.HashPassword) ->
      case run_hash_password() {
        Error(msg) -> {
          io.println_error("error: " <> msg)
          halt(1)
        }
        Ok(hash) -> io.println(hash)
      }
  }
}

@external(erlang, "ochoko_ffi", "read_password")
fn read_password() -> Result(String, Nil)

/// Reads a password from stdin and returns its argon2id hash. The password
/// itself is never printed.
fn run_hash_password() -> Result(String, String) {
  use password <- result.try(
    read_password() |> result.replace_error("could not read a password"),
  )
  case password {
    "" -> Error("password must not be empty")
    _ ->
      argus.hasher()
      |> argus.algorithm(argus.Argon2id)
      |> argus.hash(password)
      |> result.map(fn(out) { out.encoded_hash })
      |> result.replace_error("could not hash the password")
  }
}

fn run_fetch(
  config_path: String,
  url: String,
) -> Result(Response(String), String) {
  use c <- result.try(config.load(config_path))
  use pem <- result.try(
    simplifile.read(c.private_key_path)
    |> result.map_error(fn(e) {
      c.private_key_path <> ": " <> simplifile.describe_error(e)
    }),
  )
  use key <- result.try(
    rsa.private_from_pem(pem)
    |> result.replace_error(c.private_key_path <> ": invalid private key"),
  )
  let ctx =
    Context(
      config: c,
      db_path: c.database_path,
      now: timestamp.system_time,
      private_key: key,
      send: http_client.httpc_send(10_000),
      login_failure_delay_ms: 1000,
    )
  http_client.signed_get(ctx, url)
  |> result.map_error(http_client.describe_error)
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
