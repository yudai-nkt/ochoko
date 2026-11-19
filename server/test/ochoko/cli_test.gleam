import ochoko/cli.{Fetch, HashPassword, Keygen, Profile, Serve}

pub fn serve_test() {
  assert cli.parse_args(["serve", "--config", "c.toml"]) == Ok(Serve("c.toml"))
}

pub fn serve_missing_config_test() {
  let assert Error(_) = cli.parse_args(["serve"])
}

pub fn keygen_test() {
  assert cli.parse_args(["keygen", "k.pem"]) == Ok(Keygen("k.pem"))
}

pub fn hash_password_test() {
  assert cli.parse_args(["hash-password"]) == Ok(HashPassword)
}

pub fn profile_test() {
  assert cli.parse_args([
      "profile", "--config", "c.toml", "--display-name", "Y", "--avatar-url",
      "u",
    ])
    == Ok(Profile("c.toml", Ok("Y"), Error(Nil), Ok("u")))
}

pub fn profile_no_options_test() {
  assert cli.parse_args(["profile", "--config", "c.toml"])
    == Ok(Profile("c.toml", Error(Nil), Error(Nil), Error(Nil)))
}

pub fn fetch_test() {
  assert cli.parse_args(["fetch", "--config", "c.toml", "https://x/y"])
    == Ok(Fetch("c.toml", "https://x/y"))
}

pub fn unknown_command_test() {
  let assert Error(msg) = cli.parse_args(["bogus"])
  assert msg != ""
}

pub fn empty_test() {
  let assert Error(_) = cli.parse_args([])
}
