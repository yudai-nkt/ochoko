import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import ochoko/app
import ochoko/config.{type Config, Config}
import ochoko/crypto/rsa
import simplifile
import support

/// Start the application on a random high port, retrying when it is taken.
fn start_on_free_port(
  base: Config,
  attempts: Int,
) -> #(Int, actor.Started(Supervisor)) {
  let port = 20_000 + int.random(30_000)
  let c = Config(..base, listen_port: port)
  case app.start_link(c, "127.0.0.1"), attempts {
    Ok(started), _ -> #(port, started)
    Error(_), 0 -> panic as "could not start the app"
    Error(_), _ -> start_on_free_port(base, attempts - 1)
  }
}

pub fn serves_health_test() {
  let db_path = support.temp_db_path()
  let key_path = db_path <> ".pem"
  let assert Ok(Nil) =
    simplifile.write(key_path, rsa.private_to_pem(support.test_key()))
  let base =
    Config(
      ..support.test_config(),
      database_path: db_path,
      private_key_path: key_path,
    )
  let #(port, started) = start_on_free_port(base, 20)
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/health")
  let res = httpc.send(req) |> result.map_error(fn(_) { "request failed" })
  let assert Ok(res) = res
  assert res.status == 200
  assert res.body == "ok"
  app.stop(started)
}

pub fn port_in_use_is_an_error_test() {
  let db_path = support.temp_db_path()
  let key_path = db_path <> ".pem"
  let assert Ok(Nil) =
    simplifile.write(key_path, rsa.private_to_pem(support.test_key()))
  let base =
    Config(
      ..support.test_config(),
      database_path: db_path,
      private_key_path: key_path,
    )
  let #(port, started) = start_on_free_port(base, 20)
  let assert Error(msg) =
    app.start_link(Config(..base, listen_port: port), "127.0.0.1")
  assert msg != ""
  app.stop(started)
}
