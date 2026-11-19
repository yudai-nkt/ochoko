import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/list
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import ochoko/crypto/rsa
import ochoko/http_date
import ochoko/signature

fn key() -> rsa.PrivateKey {
  cached_key(fn() { rsa.generate(2048) })
}

@external(erlang, "ochoko_rsa_test_ffi", "cached_key")
fn cached_key(make: fn() -> rsa.PrivateKey) -> rsa.PrivateKey

fn public(k: rsa.PrivateKey) -> rsa.PublicKey {
  let assert Ok(p) = rsa.public_from_pem(rsa.public_pem(k))
  p
}

fn base_time() -> Timestamp {
  timestamp.from_unix_seconds(1_700_000_000)
}

fn post_request() -> Request(String) {
  request.new()
  |> request.set_method(http.Post)
  |> request.set_host("example.com")
  |> request.set_path("/users/alice/inbox")
  |> request.set_body("{\"type\":\"Follow\"}")
}

fn signed_post() -> Request(String) {
  signature.sign(
    post_request(),
    key(),
    "https://ochoko.test/actor#main-key",
    base_time(),
  )
}

// --- draft-cavage-http-signatures-12, Appendix C ---

const draft_public_pem =
  "-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDCFENGw33yGihy92pDjZQhl0C3
6rPJj+CvfSC8+q28hxA161QFNUd13wuCTUcq0Qd2qsBe/2hFyc2DCJJg0h1L78+6
Z4UMR7EOcpfdUE9Hf3m/hs+FUR45uBJeDK1HSFHD8bHKD6kv8FPGfJTotc+2xjJw
oYi+1hqp1fIekaxsyQIDAQAB
-----END PUBLIC KEY-----
"

const draft_private_pem =
  "-----BEGIN RSA PRIVATE KEY-----
MIICXgIBAAKBgQDCFENGw33yGihy92pDjZQhl0C36rPJj+CvfSC8+q28hxA161QF
NUd13wuCTUcq0Qd2qsBe/2hFyc2DCJJg0h1L78+6Z4UMR7EOcpfdUE9Hf3m/hs+F
UR45uBJeDK1HSFHD8bHKD6kv8FPGfJTotc+2xjJwoYi+1hqp1fIekaxsyQIDAQAB
AoGBAJR8ZkCUvx5kzv+utdl7T5MnordT1TvoXXJGXK7ZZ+UuvMNUCdN2QPc4sBiA
QWvLw1cSKt5DsKZ8UETpYPy8pPYnnDEz2dDYiaew9+xEpubyeW2oH4Zx71wqBtOK
kqwrXa/pzdpiucRRjk6vE6YY7EBBs/g7uanVpGibOVAEsqH1AkEA7DkjVH28WDUg
f1nqvfn2Kj6CT7nIcE3jGJsZZ7zlZmBmHFDONMLUrXR/Zm3pR5m0tCmBqa5RK95u
412jt1dPIwJBANJT3v8pnkth48bQo/fKel6uEYyboRtA5/uHuHkZ6FQF7OUkGogc
mSJluOdc5t6hI1VsLn0QZEjQZMEOWr+wKSMCQQCC4kXJEsHAve77oP6HtG/IiEn7
kpyUXRNvFsDE0czpJJBvL/aRFUJxuRK91jhjC68sA7NsKMGg5OXb5I5Jj36xAkEA
gIT7aFOYBFwGgQAQkWNKLvySgKbAZRTeLBacpHMuQdl1DfdntvAyqpAZ0lY0RKmW
G6aFKaqQfOXKCyWoUiVknQJAXrlgySFci/2ueKlIE1QqIiLSZ8V8OlpFLRnb1pzI
7U1yQXnTAEFYM560yJlzUpOb1V4cScGd365tiSMvxLOvTA==
-----END RSA PRIVATE KEY-----
"

const draft_signature =
  "qdx+H7PHHDZgy4y/Ahn9Tny9V3GP6YgBPyUXMmoxWtLbHpUnXS2mg2+SbrQDMCJypxBLSPQR2aAjn7ndmw2iicw3HMbe8VfEdKFYRqzic+efkb3nndiv/x1xSHDJWeSWkx3ButlYSuBskLu6kd9Fswtemr3lgdDEmn04swr2Os0="

fn draft_request() -> Request(String) {
  request.new()
  |> request.set_method(http.Post)
  |> request.set_host("example.com")
  |> request.set_path("/foo")
  |> request.set_query([#("param", "value"), #("pet", "dog")])
  |> request.set_header("host", "example.com")
  |> request.set_header("date", "Sun, 05 Jan 2014 21:31:40 GMT")
  |> request.set_header("content-type", "application/json")
  |> request.set_header(
    "digest",
    "SHA-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE=",
  )
  |> request.set_header("content-length", "18")
  |> request.set_body("{\"hello\": \"world\"}")
}

pub fn cavage_basic_vector_test() {
  let assert Ok(private) = rsa.private_from_pem(draft_private_pem)
  let assert Ok(public) = rsa.public_from_pem(draft_public_pem)
  let headers = ["(request-target)", "host", "date"]

  let assert Ok(text) = signature.signing_string(draft_request(), headers)
  assert text
    == "(request-target): post /foo?param=value&pet=dog\nhost: example.com\ndate: Sun, 05 Jan 2014 21:31:40 GMT"

  let signed = signature.sign_headers(draft_request(), private, "Test", headers)
  let assert Ok(parsed) = signature.parse_header(signed)
  assert parsed.key_id == "Test"
  assert parsed.algorithm == "rsa-sha256"
  assert parsed.headers == headers
  assert bit_array.base64_encode(parsed.signature, True) == draft_signature

  let assert Ok(expected) = bit_array.base64_decode(draft_signature)
  assert rsa.verify_sha256(public, <<text:utf8>>, expected)
}

pub fn digest_test() {
  assert signature.digest("{\"hello\": \"world\"}")
    == "SHA-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE="
}

// --- sign / verify ---

pub fn sign_then_verify_test() {
  let signed = signed_post()
  let assert Ok(parsed) = signature.parse_header(signed)
  assert parsed.key_id == "https://ochoko.test/actor#main-key"
  assert parsed.headers == ["(request-target)", "host", "date", "digest"]
  assert request.get_header(signed, "date") == Ok(http_date.format(base_time()))
  assert request.get_header(signed, "digest")
    == Ok(signature.digest("{\"type\":\"Follow\"}"))
  assert signature.verify(signed, parsed, public(key()), base_time()) == Ok(Nil)
}

pub fn sign_get_without_body_test() {
  let req =
    request.new()
    |> request.set_host("example.com")
    |> request.set_path("/users/bob")
    |> request.set_query([#("a", "b")])
    |> signature.sign(key(), "k", base_time())
  let assert Ok(parsed) = signature.parse_header(req)
  assert parsed.headers == ["(request-target)", "host", "date"]
  assert request.get_header(req, "digest") == Error(Nil)
  assert signature.verify(req, parsed, public(key()), base_time()) == Ok(Nil)
}

pub fn sign_host_with_port_test() {
  let req =
    request.new()
    |> request.set_host("example.com")
    |> request.set_port(8080)
    |> signature.sign(key(), "k", base_time())
  assert request.get_header(req, "host") == Ok("example.com:8080")
}

pub fn digest_mismatch_test() {
  let tampered = request.set_body(signed_post(), "{\"type\":\"Undo\"}")
  let assert Ok(parsed) = signature.parse_header(tampered)
  assert signature.verify(tampered, parsed, public(key()), base_time())
    == Error(signature.DigestMismatch)
}

pub fn tampered_path_is_bad_signature_test() {
  let tampered = request.set_path(signed_post(), "/users/mallory/inbox")
  let assert Ok(parsed) = signature.parse_header(tampered)
  assert signature.verify(tampered, parsed, public(key()), base_time())
    == Error(signature.BadSignature)
}

pub fn wrong_key_is_bad_signature_test() {
  let signed = signed_post()
  let assert Ok(parsed) = signature.parse_header(signed)
  let assert Ok(other) = rsa.public_from_pem(draft_public_pem)
  assert signature.verify(signed, parsed, other, base_time())
    == Error(signature.BadSignature)
}

pub fn date_too_old_test() {
  let signed = signed_post()
  let assert Ok(parsed) = signature.parse_header(signed)
  let now = timestamp.add(base_time(), duration.seconds(12 * 3600 + 1))
  assert signature.verify(signed, parsed, public(key()), now)
    == Error(signature.DateOutOfWindow)
}

pub fn date_in_future_test() {
  let signed = signed_post()
  let assert Ok(parsed) = signature.parse_header(signed)
  let now = timestamp.add(base_time(), duration.seconds(-3600 - 1))
  assert signature.verify(signed, parsed, public(key()), now)
    == Error(signature.DateOutOfWindow)
}

pub fn date_at_edge_test() {
  let signed = signed_post()
  let assert Ok(parsed) = signature.parse_header(signed)
  let old = timestamp.add(base_time(), duration.seconds(12 * 3600))
  assert signature.verify(signed, parsed, public(key()), old) == Ok(Nil)
  let future = timestamp.add(base_time(), duration.seconds(-3600))
  assert signature.verify(signed, parsed, public(key()), future) == Ok(Nil)
}

pub fn post_without_digest_in_headers_test() {
  let req = request.set_header(signed_post(), "digest", "x")
  let signed =
    signature.sign_headers(req, key(), "k", ["(request-target)", "host", "date"])
  let assert Ok(parsed) = signature.parse_header(signed)
  assert signature.verify(signed, parsed, public(key()), base_time())
    == Error(signature.MissingHeader("digest"))
}

pub fn missing_date_in_signed_headers_test() {
  let signed =
    signature.sign_headers(signed_post(), key(), "k", [
      "(request-target)",
      "host",
      "digest",
    ])
  let assert Ok(parsed) = signature.parse_header(signed)
  assert signature.verify(signed, parsed, public(key()), base_time())
    == Error(signature.MissingHeader("date"))
}

pub fn missing_request_target_in_signed_headers_test() {
  let signed =
    signature.sign_headers(signed_post(), key(), "k", [
      "host",
      "date",
      "digest",
    ])
  let assert Ok(parsed) = signature.parse_header(signed)
  assert signature.verify(signed, parsed, public(key()), base_time())
    == Error(signature.MissingHeader("(request-target)"))
}

pub fn missing_host_in_signed_headers_test() {
  let signed =
    signature.sign_headers(signed_post(), key(), "k", [
      "(request-target)",
      "date",
      "digest",
    ])
  let assert Ok(parsed) = signature.parse_header(signed)
  assert signature.verify(signed, parsed, public(key()), base_time())
    == Error(signature.MissingHeader("host"))
}

pub fn date_header_absent_test() {
  let signed =
    request.Request(
      ..signed_post(),
      headers: list.filter(signed_post().headers, fn(h) { h.0 != "date" }),
    )
  let assert Ok(parsed) = signature.parse_header(signed)
  assert signature.verify(signed, parsed, public(key()), base_time())
    == Error(signature.MissingHeader("date"))
}

pub fn date_unparsable_test() {
  let req =
    post_request()
    |> request.set_header("host", "example.com")
    |> request.set_header("date", "yesterday-ish")
    |> request.set_header("digest", signature.digest("{\"type\":\"Follow\"}"))
  let signed =
    signature.sign_headers(req, key(), "k", [
      "(request-target)",
      "host",
      "date",
      "digest",
    ])
  let assert Ok(parsed) = signature.parse_header(signed)
  let signed =
    request.set_header(
      signed,
      "digest",
      signature.digest("{\"type\":\"Follow\"}"),
    )
  assert signature.verify(signed, parsed, public(key()), base_time())
    == Error(signature.Malformed)
}

pub fn body_without_signed_digest_test() {
  // A PUT with a body must also cover the body with a signed digest.
  let req =
    post_request()
    |> request.set_method(http.Put)
    |> request.set_header("host", "example.com")
    |> request.set_header("date", http_date.format(base_time()))
    |> signature.sign_headers(key(), "k", ["(request-target)", "host", "date"])
  let assert Ok(parsed) = signature.parse_header(req)
  assert signature.verify(req, parsed, public(key()), base_time())
    == Error(signature.MissingHeader("digest"))
}

pub fn hs2019_algorithm_accepted_test() {
  let signed = signed_post()
  let assert Ok(header) = request.get_header(signed, "signature")
  let swapped =
    string.replace(header, "algorithm=\"rsa-sha256\"", "algorithm=\"hs2019\"")
  assert swapped != header
  let req = request.set_header(signed, "signature", swapped)
  let assert Ok(parsed) = signature.parse_header(req)
  assert parsed.algorithm == "hs2019"
  assert signature.verify(req, parsed, public(key()), base_time()) == Ok(Nil)
}

pub fn unsupported_algorithm_rejected_test() {
  let signed = signed_post()
  let assert Ok(header) = request.get_header(signed, "signature")
  let swapped =
    string.replace(header, "algorithm=\"rsa-sha256\"", "algorithm=\"rsa-sha1\"")
  let req = request.set_header(signed, "signature", swapped)
  assert signature.parse_header(req) == Error(signature.Malformed)
}

pub fn parse_header_missing_test() {
  assert signature.parse_header(post_request())
    == Error(signature.MissingSignature)
}

pub fn parse_header_malformed_test() {
  list.each(
    [
      "garbage",
      "keyId=\"k\",algorithm=\"rsa-sha256\"",
      "keyId=\"k\",headers=\"date\",signature=\"!!!notbase64\"",
      "keyId=\"unterminated,signature=\"AAAA\"",
    ],
    fn(value) {
      let req = request.set_header(post_request(), "signature", value)
      assert signature.parse_header(req) == Error(signature.Malformed)
    },
  )
}

pub fn parse_header_mastodon_style_test() {
  let req =
    request.set_header(
      post_request(),
      "signature",
      "keyId=\"https://m.example/users/a#main-key\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date digest content-type\",signature=\"AAAA\"",
    )
  let assert Ok(parsed) = signature.parse_header(req)
  assert parsed.key_id == "https://m.example/users/a#main-key"
  assert parsed.headers
    == ["(request-target)", "host", "date", "digest", "content-type"]
  assert parsed.signature == <<0, 0, 0>>
}
