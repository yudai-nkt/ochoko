//// The few Mastodon API fields the scenarios look at.

import gleam/dynamic/decode.{type Decoder}

pub type Account {
  Account(id: String, acct: String)
}

pub type Status {
  Status(id: String, content: String, visibility: String, account: Account)
}

pub type Relationship {
  Relationship(id: String, following: Bool, followed_by: Bool)
}

pub type Notification {
  Notification(type_: String, account: Account)
}

pub fn account() -> Decoder(Account) {
  use id <- decode.field("id", decode.string)
  use acct <- decode.field("acct", decode.string)
  decode.success(Account(id:, acct:))
}

pub fn status() -> Decoder(Status) {
  use id <- decode.field("id", decode.string)
  use content <- decode.field("content", decode.string)
  use visibility <- decode.field("visibility", decode.string)
  use account <- decode.field("account", account())
  decode.success(Status(id:, content:, visibility:, account:))
}

pub fn relationship() -> Decoder(Relationship) {
  use id <- decode.field("id", decode.string)
  use following <- decode.field("following", decode.bool)
  use followed_by <- decode.field("followed_by", decode.bool)
  decode.success(Relationship(id:, following:, followed_by:))
}

pub fn notification() -> Decoder(Notification) {
  use type_ <- decode.field("type", decode.string)
  use account <- decode.field("account", account())
  decode.success(Notification(type_:, account:))
}

/// `/api/v2/search` results, accounts only.
pub fn search_accounts() -> Decoder(List(Account)) {
  decode.at(["accounts"], decode.list(account()))
}
