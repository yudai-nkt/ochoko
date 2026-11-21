pub type Command {
  Serve(config_path: String)
  Keygen(out_path: String)
  HashPassword
  Profile(
    config_path: String,
    display_name: Result(String, Nil),
    note: Result(String, Nil),
    avatar_url: Result(String, Nil),
  )
  Fetch(config_path: String, url: String)
}

pub fn parse_args(args: List(String)) -> Result(Command, String) {
  case args {
    ["serve", ..rest] ->
      case rest {
        ["--config", path] -> Ok(Serve(path))
        _ -> Error("usage: ochoko serve --config PATH")
      }
    ["keygen", out_path] -> Ok(Keygen(out_path))
    ["keygen", ..] -> Error("usage: ochoko keygen OUT_PATH")
    ["hash-password"] -> Ok(HashPassword)
    ["hash-password", ..] -> Error("usage: ochoko hash-password")
    ["profile", "--config", path, ..opts] -> parse_profile(path, opts)
    ["profile", ..] ->
      Error(
        "usage: ochoko profile --config PATH [--display-name S] [--note S] [--avatar-url S]",
      )
    ["fetch", "--config", path, url] -> Ok(Fetch(path, url))
    ["fetch", ..] -> Error("usage: ochoko fetch --config PATH URL")
    [other, ..] -> Error("unknown command: " <> other)
    [] -> Error("usage: ochoko <serve|keygen|hash-password|profile|fetch> ...")
  }
}

fn parse_profile(path: String, opts: List(String)) -> Result(Command, String) {
  parse_profile_opts(opts, Profile(path, Error(Nil), Error(Nil), Error(Nil)))
}

fn parse_profile_opts(
  opts: List(String),
  acc: Command,
) -> Result(Command, String) {
  case opts, acc {
    [], _ -> Ok(acc)
    ["--display-name", v, ..rest], Profile(..) ->
      parse_profile_opts(rest, Profile(..acc, display_name: Ok(v)))
    ["--note", v, ..rest], Profile(..) ->
      parse_profile_opts(rest, Profile(..acc, note: Ok(v)))
    ["--avatar-url", v, ..rest], Profile(..) ->
      parse_profile_opts(rest, Profile(..acc, avatar_url: Ok(v)))
    [other, ..], _ -> Error("unexpected profile argument: " <> other)
  }
}
