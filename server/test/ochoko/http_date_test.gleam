import gleam/time/timestamp
import ochoko/http_date

pub fn http_date_format_test() {
  assert http_date.format(timestamp.from_unix_seconds(1_388_957_500))
    == "Sun, 05 Jan 2014 21:31:40 GMT"
}

pub fn http_date_parse_test() {
  assert http_date.parse("Sun, 05 Jan 2014 21:31:40 GMT")
    == Ok(timestamp.from_unix_seconds(1_388_957_500))
}

pub fn http_date_parse_garbage_test() {
  assert http_date.parse("not a date") == Error(Nil)
}
