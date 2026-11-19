import argv
import gleam/io
import gleam/string
import ochoko/cli
import ochoko/config

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> a

pub fn main() -> Nil {
  case cli.parse_args(argv.load().arguments) {
    Error(msg) -> {
      io.println_error(msg)
      halt(2)
    }
    Ok(cli.Serve(path)) ->
      case config.load(path) {
        Error(msg) -> {
          io.println_error("error: " <> msg)
          halt(1)
        }
        Ok(c) ->
          io.println(
            "config loaded for " <> config.acct(c) <> "; server not wired yet",
          )
      }
    Ok(command) ->
      io.println(string.inspect(command) <> ": not implemented yet")
  }
}
