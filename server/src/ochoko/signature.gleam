//// HTTP Signatures (draft-cavage-http-signatures-12) and `Digest` headers,
//// as used by Mastodon-compatible ActivityPub servers.

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import ochoko/crypto/rsa.{type PrivateKey, type PublicKey}
import ochoko/http_date

pub type Parsed {
  Parsed(
    key_id: String,
    algorithm: String,
    headers: List(String),
    signature: BitArray,
  )
}

pub type VerifyError {
  MissingSignature
  Malformed
  MissingHeader(String)
  DateOutOfWindow
  DigestMismatch
  BadSignature
}

/// How far in the past a `Date` may be, in seconds.
const max_age_seconds = 43_200

/// How far in the future a `Date` may be, in seconds.
const max_skew_seconds = 3600

/// `SHA-256=` followed by the base64 SHA-256 of the body.
pub fn digest(body: String) -> String {
  let hash = crypto.hash(crypto.Sha256, <<body:utf8>>)
  "SHA-256=" <> bit_array.base64_encode(hash, True)
}

/// Builds the signing string for the given (lower-case) header names.
/// `(request-target)` uses the request's path and query exactly as stored.
pub fn signing_string(
  req: Request(String),
  headers: List(String),
) -> Result(String, VerifyError) {
  headers
  |> list.try_map(fn(name) {
    case name {
      "(request-target)" -> Ok(name <> ": " <> request_target(req))
      "(" <> _ -> Error(Malformed)
      _ ->
        case request.get_header(req, name) {
          Ok(value) -> Ok(name <> ": " <> string.trim(value))
          Error(Nil) -> Error(MissingHeader(name))
        }
    }
  })
  |> result.map(string.join(_, "\n"))
}

fn request_target(req: Request(String)) -> String {
  let method = string.lowercase(http.method_to_string(req.method))
  let query = case req.query {
    Some(q) -> "?" <> q
    None -> ""
  }
  method <> " " <> req.path <> query
}

/// Sets `host`, `date` and (for non-empty bodies) `digest`, then signs
/// `(request-target) host date [digest]` with rsa-sha256.
pub fn sign(
  req: Request(String),
  key: PrivateKey,
  key_id: String,
  now: Timestamp,
) -> Request(String) {
  let host = case req.port {
    Some(port) -> req.host <> ":" <> int.to_string(port)
    None -> req.host
  }
  let req =
    req
    |> request.set_header("host", host)
    |> request.set_header("date", http_date.format(now))
  let #(req, headers) = case req.body {
    "" -> #(req, ["(request-target)", "host", "date"])
    body -> #(request.set_header(req, "digest", digest(body)), [
      "(request-target)",
      "host",
      "date",
      "digest",
    ])
  }
  sign_headers(req, key, key_id, headers)
}

/// Signs exactly the given headers (which must already be present on the
/// request) and sets the `signature` header.
pub fn sign_headers(
  req: Request(String),
  key: PrivateKey,
  key_id: String,
  headers: List(String),
) -> Request(String) {
  let assert Ok(text) = signing_string(req, headers)
  let sig = rsa.sign_sha256(key, <<text:utf8>>)
  let value =
    "keyId=\""
    <> key_id
    <> "\",algorithm=\"rsa-sha256\",headers=\""
    <> string.join(headers, " ")
    <> "\",signature=\""
    <> bit_array.base64_encode(sig, True)
    <> "\""
  request.set_header(req, "signature", value)
}

/// Parses the `Signature` header.
pub fn parse_header(req: Request(String)) -> Result(Parsed, VerifyError) {
  use raw <- result.try(
    request.get_header(req, "signature")
    |> result.replace_error(MissingSignature),
  )
  use params <- result.try(parse_params(raw, []))
  use key_id <- result.try(find(params, "keyid"))
  use sig64 <- result.try(find(params, "signature"))
  use signature <- result.try(
    bit_array.base64_decode(sig64) |> result.replace_error(Malformed),
  )
  let algorithm = list.key_find(params, "algorithm") |> result.unwrap("hs2019")
  use <- require(algorithm == "rsa-sha256" || algorithm == "hs2019")
  let headers =
    list.key_find(params, "headers")
    |> result.unwrap("date")
    |> string.lowercase
    |> string.split(" ")
    |> list.filter(fn(h) { h != "" })
  use <- require(headers != [])
  Ok(Parsed(key_id:, algorithm:, headers:, signature:))
}

fn require(ok: Bool, next: fn() -> Result(a, VerifyError)) {
  case ok {
    True -> next()
    False -> Error(Malformed)
  }
}

fn find(params: List(#(String, String)), name: String) {
  list.key_find(params, name) |> result.replace_error(Malformed)
}

/// Parses `k="v",k2=token,...` into lower-cased keys.
fn parse_params(
  input: String,
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), VerifyError) {
  let input = string.trim_start(input) |> trim_commas
  case input {
    "" ->
      case acc {
        [] -> Error(Malformed)
        _ -> Ok(acc)
      }
    _ -> {
      use #(name, rest) <- result.try(
        string.split_once(input, "=") |> result.replace_error(Malformed),
      )
      let name = string.trim(name) |> string.lowercase
      case name == "" || string.contains(name, ",") {
        True -> Error(Malformed)
        False -> {
          use #(value, rest) <- result.try(case rest {
            "\"" <> quoted ->
              string.split_once(quoted, "\"") |> result.replace_error(Malformed)
            _ ->
              case string.split_once(rest, ",") {
                Ok(#(v, r)) -> Ok(#(v, r))
                Error(Nil) -> Ok(#(rest, ""))
              }
          })
          parse_params(rest, [#(name, string.trim(value)), ..acc])
        }
      }
    }
  }
}

fn trim_commas(s: String) -> String {
  case s {
    "," <> rest -> string.trim_start(rest) |> trim_commas
    _ -> s
  }
}

/// Fully verifies an inbound request against an already parsed signature.
pub fn verify(
  req: Request(String),
  parsed: Parsed,
  key: PublicKey,
  now: Timestamp,
) -> Result(Nil, VerifyError) {
  let signed = parsed.headers
  let has_body = req.body != ""
  let required =
    list.flatten([
      ["(request-target)", "host", "date"],
      case req.method == http.Post || has_body {
        True -> ["digest"]
        False -> []
      },
    ])
  use _ <- result.try(
    list.find(required, fn(name) { !list.contains(signed, name) })
    |> result.map(fn(name) { Error(MissingHeader(name)) })
    |> result.unwrap(Ok(Nil)),
  )
  use date_header <- result.try(
    request.get_header(req, "date")
    |> result.replace_error(MissingHeader("date")),
  )
  use date <- result.try(
    http_date.parse(string.trim(date_header)) |> result.replace_error(Malformed),
  )
  use _ <- result.try(check_window(date, now))
  use _ <- result.try(check_digest(req, signed))
  use text <- result.try(signing_string(req, signed))
  case rsa.verify_sha256(key, <<text:utf8>>, parsed.signature) {
    True -> Ok(Nil)
    False -> Error(BadSignature)
  }
}

fn check_window(date: Timestamp, now: Timestamp) -> Result(Nil, VerifyError) {
  let #(date_s, _) = timestamp.to_unix_seconds_and_nanoseconds(date)
  let #(now_s, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  let age = now_s - date_s
  case age > max_age_seconds || age < -max_skew_seconds {
    True -> Error(DateOutOfWindow)
    False -> Ok(Nil)
  }
}

fn check_digest(
  req: Request(String),
  signed: List(String),
) -> Result(Nil, VerifyError) {
  case list.contains(signed, "digest") {
    False -> Ok(Nil)
    True ->
      case request.get_header(req, "digest") {
        Error(Nil) -> Error(MissingHeader("digest"))
        Ok(value) ->
          case string.trim(value) == digest(req.body) {
            True -> Ok(Nil)
            False -> Error(DigestMismatch)
          }
      }
  }
}
