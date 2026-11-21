//// Obtain an ochoko access token the way a client does: register an app,
//// submit the login form with a PKCE challenge, exchange the code.

import e2e/client
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri

const redirect_uri = "https://e2e.test/callback"

const scopes = "read write follow"

pub fn token(base_url: String, password: String) -> Result(String, String) {
  let anon = client.Client(base_url, "")
  use #(client_id, client_secret) <- result.try(
    client.post(
      anon,
      "/api/v1/apps",
      json.object([
        #("client_name", json.string("e2e")),
        #("redirect_uris", json.string(redirect_uri)),
        #("scopes", json.string(scopes)),
      ]),
      {
        use id <- decode.field("client_id", decode.string)
        use secret <- decode.field("client_secret", decode.string)
        decode.success(#(id, secret))
      },
    ),
  )
  let verifier =
    crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
  let challenge =
    crypto.hash(crypto.Sha256, bit_array.from_string(verifier))
    |> bit_array.base64_url_encode(False)
  use login <- result.try(
    client.post_form(base_url, "/oauth/authorize", [
      #("client_id", client_id),
      #("redirect_uri", redirect_uri),
      #("response_type", "code"),
      #("scope", scopes),
      #("code_challenge", challenge),
      #("code_challenge_method", "S256"),
      #("password", password),
    ]),
  )
  use code <- result.try(code_from_redirect(login))
  client.post(
    anon,
    "/oauth/token",
    json.object([
      #("grant_type", json.string("authorization_code")),
      #("code", json.string(code)),
      #("client_id", json.string(client_id)),
      #("client_secret", json.string(client_secret)),
      #("redirect_uri", json.string(redirect_uri)),
      #("code_verifier", json.string(verifier)),
    ]),
    decode.at(["access_token"], decode.string),
  )
}

fn code_from_redirect(
  resp: response.Response(String),
) -> Result(String, String) {
  let location = response.get_header(resp, "location") |> result.unwrap("")
  let code = {
    use parsed <- result.try(uri.parse(location))
    use query <- result.try(case parsed.query {
      Some(q) -> Ok(q)
      None -> Error(Nil)
    })
    use pairs <- result.try(uri.parse_query(query))
    list.key_find(pairs, "code")
  }
  case resp.status, code {
    302, Ok(code) -> Ok(code)
    status, _ ->
      Error(
        "login did not redirect with a code: HTTP "
        <> int.to_string(status)
        <> " location="
        <> location,
      )
  }
}
