import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import ochoko/http_client
import ochoko/http_transport
import support

fn recording_ok() {
  support.recording_send(fn(_req) {
    Ok(response.new(200) |> response.set_body("{}"))
  })
}

fn refused(url: String) -> Bool {
  let #(send, requests) = recording_ok()
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let get = http_client.get(ctx, url, "application/json")
  let signed = http_client.signed_get(ctx, url)
  case get, signed, requests() {
    Error(http_transport.Refused(_)), Error(http_transport.Refused(_)), [] ->
      True
    _, _, _ -> False
  }
}

pub fn refuses_plain_http_test() {
  assert refused("http://r.example/users/a")
}

pub fn refuses_non_web_schemes_test() {
  assert refused("ftp://r.example/users/a")
  assert refused("file:///etc/passwd")
  assert refused("javascript:alert(1)")
}

pub fn refuses_private_ipv4_literals_test() {
  list.each(
    [
      "https://10.0.0.1/",
      "https://127.0.0.1/users/a",
      "https://127.1/",
      "https://2130706433/",
      "https://0.0.0.0/",
      "https://169.254.169.254/latest/meta-data/",
      "https://172.16.5.4/",
      "https://192.168.1.1/",
      "https://100.64.0.1/",
    ],
    fn(url) {
      assert refused(url) as url
    },
  )
}

pub fn refuses_private_ipv6_literals_test() {
  list.each(
    [
      "https://[::1]/",
      "https://[::]/",
      "https://[fe80::1]/",
      "https://[fd00::1]/",
      "https://[::ffff:127.0.0.1]/",
      "https://[::ffff:10.0.0.1]/",
    ],
    fn(url) {
      assert refused(url) as url
    },
  )
}

pub fn refuses_localhost_names_test() {
  assert refused("https://localhost/")
  assert refused("https://LocalHost./")
  assert refused("https://foo.localhost/")
}

pub fn allows_public_https_test() {
  let #(send, requests) = recording_ok()
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Ok(_) =
    http_client.get(ctx, "https://r.example/users/a", "application/json")
  let assert Ok(_) = http_client.get(ctx, "HTTPS://8.8.8.8/", "*/*")
  let assert Ok(_) = http_client.get(ctx, "https://[2001:db8::1]/", "*/*")
  assert list.length(requests()) == 3
}

pub fn rejects_oversized_body_test() {
  let big = string.repeat("x", http_client.max_response_bytes + 1)
  let ctx =
    support.test_context_with_send(support.temp_db_path(), fn(_) {
      Ok(response.new(200) |> response.set_body(big))
    })
  let assert Error(http_transport.TooLarge) =
    http_client.signed_get(ctx, "https://r.example/users/a")
}

pub fn rejects_oversized_content_length_test() {
  let ctx =
    support.test_context_with_send(support.temp_db_path(), fn(_) {
      Ok(
        response.new(200)
        |> response.set_header("content-length", "1048577")
        |> response.set_body("{}"),
      )
    })
  let assert Error(http_transport.TooLarge) =
    http_client.get(ctx, "https://r.example/users/a", "*/*")
}

pub fn post_sets_user_agent_and_signature_test() {
  let #(send, requests) = recording_ok()
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Ok(_) =
    http_client.signed_post(ctx, "https://r.example/inbox", "{}")
  let assert [req] = requests()
  assert request.get_header(req, "user-agent")
    == Ok("ochoko/0.1.0 (+https://ochoko.ynkt.me/)")
  assert request.get_header(req, "content-type")
    == Ok("application/activity+json")
  let assert Ok(_) = request.get_header(req, "signature")
  assert req.path == "/inbox"
}

pub fn post_refuses_private_inbox_test() {
  let #(send, requests) = recording_ok()
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Error(http_transport.Refused(_)) =
    http_client.signed_post(ctx, "https://127.0.0.1:8000/me/inbox", "{}")
  assert requests() == []
}
