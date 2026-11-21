import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/result
import sqlight

pub type Profile {
  Profile(
    display_name: String,
    note: String,
    avatar_url: Option(String),
    header_url: Option(String),
  )
}

pub fn get(conn: sqlight.Connection) -> Result(Profile, sqlight.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT display_name, note, avatar_url, header_url FROM profile WHERE id = 1",
      on: conn,
      with: [],
      expecting: {
        use display_name <- decode.field(0, decode.string)
        use note <- decode.field(1, decode.string)
        use avatar_url <- decode.field(2, decode.optional(decode.string))
        use header_url <- decode.field(3, decode.optional(decode.string))
        decode.success(Profile(display_name:, note:, avatar_url:, header_url:))
      },
    ),
  )
  case rows {
    [p, ..] -> Ok(p)
    [] ->
      Error(sqlight.SqlightError(
        sqlight.GenericError,
        "profile row missing",
        -1,
      ))
  }
}

pub fn update(
  conn: sqlight.Connection,
  p: Profile,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "UPDATE profile SET display_name = ?, note = ?, avatar_url = ?, header_url = ? WHERE id = 1",
    on: conn,
    with: [
      sqlight.text(p.display_name),
      sqlight.text(p.note),
      sqlight.nullable(sqlight.text, p.avatar_url),
      sqlight.nullable(sqlight.text, p.header_url),
    ],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}
