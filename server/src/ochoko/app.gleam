import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/time/timestamp
import mist
import ochoko/config.{type Config}
import ochoko/context.{type Context, Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/federation/delivery
import ochoko/http_transport
import ochoko/web/router
import simplifile
import sqlight
import wisp
import wisp/wisp_mist

/// Interface the production server binds to; a reverse proxy fronts it.
const production_interface = "127.0.0.1"

/// Load the key, migrate the database, start the delivery worker and the HTTP
/// server under a supervisor, then block forever. Only returns on a startup
/// error.
pub fn start(config: Config) -> Result(Nil, String) {
  wisp.configure_logger()
  use _ <- result.try(start_link(config, production_interface))
  process.sleep_forever()
  Ok(Nil)
}

/// Like `start` but returns once the supervisor is running, linked to the
/// caller, and lets the caller choose the interface.
pub fn start_link(
  config: Config,
  interface: String,
) -> Result(actor.Started(Supervisor), String) {
  use ctx <- result.try(build_context(config))
  let handler =
    wisp_mist.handler(handle(_, ctx), config.secret_key_base)
    |> mist.new
    |> mist.port(config.listen_port)
    |> mist.bind(interface)
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(supervision.worker(fn() { delivery.start(ctx) }))
  |> supervisor.add(mist.supervised(handler))
  |> supervisor.start
  |> result.map_error(fn(_) {
    "could not start the server on port " <> int_to_string(config.listen_port)
  })
}

fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  router.handle_request(req, ctx)
}

fn build_context(config: Config) -> Result(Context, String) {
  use pem <- result.try(
    simplifile.read(config.private_key_path)
    |> result.map_error(fn(e) {
      config.private_key_path <> ": " <> simplifile.describe_error(e)
    }),
  )
  use key <- result.try(
    rsa.private_from_pem(pem)
    |> result.replace_error(config.private_key_path <> ": invalid private key"),
  )
  use conn <- result.try(
    db.open(config.database_path) |> result.map_error(describe_db_error),
  )
  let migrated = db.migrate(conn)
  let _ = sqlight.close(conn)
  use _ <- result.try(migrated |> result.map_error(describe_db_error))
  Ok(Context(
    config:,
    db_path: config.database_path,
    now: timestamp.system_time,
    private_key: key,
    send: http_transport.httpc_send(10_000),
    login_failure_delay_ms: 1000,
  ))
}

fn describe_db_error(e: sqlight.Error) -> String {
  "database: " <> e.message
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
