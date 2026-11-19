//// The `RemoteActor` record. Defined apart from `remote_actor` because the
//// store needs the type and `remote_actor` needs the store; `remote_actor`
//// re-exports it as a type alias.

import gleam/option.{type Option}

pub type RemoteActor {
  RemoteActor(
    id: Int,
    uri: String,
    username: String,
    domain: String,
    display_name: String,
    summary_html: String,
    avatar_url: Option(String),
    header_url: Option(String),
    url: Option(String),
    inbox: String,
    shared_inbox: Option(String),
    followers_uri: Option(String),
    public_key_id: String,
    public_key_pem: String,
    bot: Bool,
    locked: Bool,
  )
}
