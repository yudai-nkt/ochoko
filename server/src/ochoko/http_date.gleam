//// IMF-fixdate (RFC 9110) formatting and parsing.

import gleam/time/timestamp.{type Timestamp}

pub fn format(t: Timestamp) -> String {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(t)
  format_seconds(seconds)
}

pub fn parse(s: String) -> Result(Timestamp, Nil) {
  case parse_seconds(s) {
    Ok(seconds) -> Ok(timestamp.from_unix_seconds(seconds))
    Error(Nil) -> Error(Nil)
  }
}

@external(erlang, "ochoko_http_date_ffi", "format")
fn format_seconds(seconds: Int) -> String

@external(erlang, "ochoko_http_date_ffi", "parse")
fn parse_seconds(s: String) -> Result(Int, Nil)
