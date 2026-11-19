import gleam/string
import ochoko/config

const example =
  "
account_domain = \"ynkt.me\"
host = \"ochoko.ynkt.me\"
handle = \"yudai\"
listen_port = 8000
database_path = \"ochoko.db\"
private_key_path = \"ochoko.pem\"
password_hash = \"hash\"
secret_key_base = \"secret\"
"

pub fn parse_ok_test() {
  let assert Ok(c) = config.parse(example)
  assert c.account_domain == "ynkt.me"
  assert c.host == "ochoko.ynkt.me"
  assert c.handle == "yudai"
  assert c.listen_port == 8000
}

pub fn parse_missing_key_test() {
  let toml = string.replace(example, "host = \"ochoko.ynkt.me\"", "")
  let assert Error(msg) = config.parse(toml)
  assert string.contains(msg, "host")
}

pub fn derived_urls_test() {
  let assert Ok(c) = config.parse(example)
  assert config.actor_id(c) == "https://ochoko.ynkt.me/me"
  assert config.key_id(c) == "https://ochoko.ynkt.me/me#main-key"
  assert config.acct(c) == "yudai@ynkt.me"
}
