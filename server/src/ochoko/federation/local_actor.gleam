//// JSON documents describing the local actor.

import gleam/json
import gleam/option.{None, Some}
import ochoko/config.{type Config}
import ochoko/store/profile.{type Profile}

pub fn actor_json(c: Config, p: Profile, public_pem: String) -> json.Json {
  let id = config.actor_id(c)
  let name = case p.display_name {
    "" -> c.handle
    n -> n
  }
  let icon = case p.avatar_url {
    Some(url) -> [
      #(
        "icon",
        json.object([
          #("type", json.string("Image")),
          #("url", json.string(url)),
        ]),
      ),
    ]
    None -> []
  }
  json.object([
    #(
      "@context",
      json.array(
        [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/v1",
        ],
        json.string,
      ),
    ),
    #("type", json.string("Person")),
    #("id", json.string(id)),
    #("preferredUsername", json.string(c.handle)),
    #("name", json.string(name)),
    #("summary", json.string(p.note)),
    #("url", json.string("https://" <> c.host <> "/profile")),
    #("inbox", json.string(id <> "/inbox")),
    #("outbox", json.string(id <> "/outbox")),
    #("followers", json.string(config.followers_uri(c))),
    #("following", json.string(id <> "/following")),
    #(
      "endpoints",
      json.object([
        #("sharedInbox", json.string("https://" <> c.host <> "/inbox")),
      ]),
    ),
    #("manuallyApprovesFollowers", json.bool(False)),
    #("discoverable", json.bool(True)),
    #(
      "publicKey",
      json.object([
        #("id", json.string(config.key_id(c))),
        #("owner", json.string(id)),
        #("publicKeyPem", json.string(public_pem)),
      ]),
    ),
    ..icon
  ])
}

pub fn webfinger_json(c: Config) -> json.Json {
  let id = config.actor_id(c)
  json.object([
    #("subject", json.string("acct:" <> config.acct(c))),
    #("aliases", json.array([id], json.string)),
    #(
      "links",
      json.array(
        [
          json.object([
            #("rel", json.string("self")),
            #("type", json.string("application/activity+json")),
            #("href", json.string(id)),
          ]),
        ],
        fn(x) { x },
      ),
    ),
  ])
}

/// An `OrderedCollection` exposing only its size.
pub fn collection_json(id: String, total: Int) -> json.Json {
  json.object([
    #("@context", json.string("https://www.w3.org/ns/activitystreams")),
    #("type", json.string("OrderedCollection")),
    #("id", json.string(id)),
    #("totalItems", json.int(total)),
  ])
}
