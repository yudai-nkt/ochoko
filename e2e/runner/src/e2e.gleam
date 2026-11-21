//// Federation scenario between ochoko (@yudai@ynkt.test) and Mastodon
//// (@alice@mastodon.test). Steps run in order and share state; the first
//// failure stops the run with a non-zero exit.

import e2e/client.{type Client, Client}
import e2e/entity.{type Account, type Status}
import e2e/oauth
import e2e/wait
import envoy
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string

const ochoko_url = "https://ochoko.ynkt.test"

const ochoko_acct = "yudai@ynkt.test"

const mastodon_url = "https://mastodon.test"

const alice_acct = "alice@mastodon.test"

pub fn main() -> Nil {
  case run() {
    Ok(Nil) -> io.println("\nall federation scenarios passed")
    Error(message) -> {
      io.println_error("\nFAILED: " <> message)
      halt(1)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

type World {
  World(
    ochoko: Client,
    mastodon: Client,
    /// alice's id on Mastodon.
    alice_m: String,
    /// alice's id on ochoko.
    alice_o: String,
    /// yudai's id on Mastodon.
    yudai_m: String,
  )
}

fn run() -> Result(Nil, String) {
  use mastodon_token <- result.try(
    envoy.get("MASTODON_TOKEN") |> result.replace_error("MASTODON_TOKEN unset"),
  )
  let mastodon = Client(mastodon_url, mastodon_token)
  use ochoko_token <- step("log in to ochoko through OAuth", fn() {
    oauth.token(ochoko_url, "e2e-password")
  })
  let ochoko = Client(ochoko_url, ochoko_token)
  use alice <- step("read alice's Mastodon account", fn() {
    client.get(
      mastodon,
      "/api/v1/accounts/verify_credentials",
      entity.account(),
    )
  })
  let world =
    World(ochoko:, mastodon:, alice_m: alice.id, alice_o: "", yudai_m: "")
  use world <- result.try(ochoko_follows_alice(world))
  use Nil <- result.try(mastodon_post_reaches_ochoko(world))
  use world <- result.try(alice_follows_ochoko(world))
  use Nil <- result.try(ochoko_posts_reach_mastodon(world))
  use Nil <- result.try(ochoko_removes_follower(world))
  ochoko_unfollows(world)
}

fn ochoko_follows_alice(w: World) -> Result(World, String) {
  use alice_o <- step("ochoko resolves @" <> alice_acct, fn() {
    resolve(w.ochoko, alice_acct)
  })
  use _ <- step("ochoko follows alice", fn() {
    client.post(
      w.ochoko,
      "/api/v1/accounts/" <> alice_o.id <> "/follow",
      json.object([]),
      entity.relationship(),
    )
  })
  use _ <- step("Mastodon accepts: ochoko is following alice", fn() {
    wait.until("following=true on ochoko", fn() {
      use r <- result.try(relationship(w.ochoko, alice_o.id))
      check(r.following, "following=" <> string.inspect(r.following))
    })
  })
  use _ <- step(
    "Mastodon lists " <> ochoko_acct <> " as alice's follower",
    fn() {
      wait.until("the follower on Mastodon", fn() {
        use followers <- result.try(followers(w.mastodon, w.alice_m))
        check(list.contains(followers, ochoko_acct), string.inspect(followers))
      })
    },
  )
  Ok(World(..w, alice_o: alice_o.id))
}

fn mastodon_post_reaches_ochoko(w: World) -> Result(Nil, String) {
  let marker = marker("from-mastodon")
  use posted <- step("alice posts", fn() {
    post_status(w.mastodon, marker, "public")
  })
  use _ <- step("alice's post reaches ochoko's home timeline", fn() {
    wait.until("the post on ochoko", fn() {
      find_in_home(w.ochoko, marker, alice_acct)
    })
  })
  use _ <- step("alice deletes the post", fn() {
    client.delete(w.mastodon, "/api/v1/statuses/" <> posted.id)
  })
  final_step("the deletion reaches ochoko", fn() {
    wait.until("the post to disappear on ochoko", fn() {
      absent_from_home(w.ochoko, marker)
    })
  })
}

fn alice_follows_ochoko(w: World) -> Result(World, String) {
  use yudai <- step("Mastodon resolves @" <> ochoko_acct, fn() {
    resolve(w.mastodon, ochoko_acct)
  })
  use _ <- step("Mastodon shows the account domain in the handle", fn() {
    check(yudai.acct == ochoko_acct, "acct=" <> yudai.acct)
  })
  use _ <- step("alice follows ochoko", fn() {
    client.post(
      w.mastodon,
      "/api/v1/accounts/" <> yudai.id <> "/follow",
      json.object([]),
      entity.relationship(),
    )
  })
  use _ <- step("ochoko auto-accepts: alice is following", fn() {
    wait.until("following=true on Mastodon", fn() {
      use r <- result.try(relationship(w.mastodon, yudai.id))
      check(r.following, "following=" <> string.inspect(r.following))
    })
  })
  use _ <- step("ochoko notifies about the new follower", fn() {
    wait.until("a follow notification on ochoko", fn() {
      use ns <- result.try(client.get(
        w.ochoko,
        "/api/v1/notifications",
        decode.list(entity.notification()),
      ))
      check(
        list.any(ns, fn(n) {
          n.type_ == "follow" && n.account.acct == alice_acct
        }),
        string.inspect(ns),
      )
    })
  })
  Ok(World(..w, yudai_m: yudai.id))
}

fn ochoko_posts_reach_mastodon(w: World) -> Result(Nil, String) {
  let public = marker("from-ochoko-public")
  let unlisted = marker("from-ochoko-unlisted")
  use posted <- step("ochoko posts publicly", fn() {
    post_status(w.ochoko, public, "public")
  })
  use _ <- step("ochoko posts unlisted", fn() {
    post_status(w.ochoko, unlisted, "unlisted")
  })
  use s <- step("the public post reaches alice's home timeline", fn() {
    wait.until("the public post on Mastodon", fn() {
      find_in_home(w.mastodon, public, ochoko_acct)
    })
  })
  use _ <- step("Mastodon sees it as public", fn() {
    check(s.visibility == "public", "visibility=" <> s.visibility)
  })
  use s <- step("the unlisted post reaches alice's home timeline", fn() {
    wait.until("the unlisted post on Mastodon", fn() {
      find_in_home(w.mastodon, unlisted, ochoko_acct)
    })
  })
  use _ <- step("Mastodon sees it as unlisted", fn() {
    check(s.visibility == "unlisted", "visibility=" <> s.visibility)
  })
  use _ <- step("ochoko deletes the public post", fn() {
    client.delete(w.ochoko, "/api/v1/statuses/" <> posted.id)
  })
  final_step("the deletion reaches Mastodon", fn() {
    wait.until("the post to disappear on Mastodon", fn() {
      absent_from_home(w.mastodon, public)
    })
  })
}

fn ochoko_removes_follower(w: World) -> Result(Nil, String) {
  use _ <- step("ochoko removes alice from its followers", fn() {
    client.post(
      w.ochoko,
      "/api/v1/accounts/" <> w.alice_o <> "/remove_from_followers",
      json.object([]),
      entity.relationship(),
    )
  })
  final_step("Mastodon: alice no longer follows ochoko", fn() {
    wait.until("following=false on Mastodon", fn() {
      use r <- result.try(relationship(w.mastodon, w.yudai_m))
      check(!r.following, "following=" <> string.inspect(r.following))
    })
  })
}

fn ochoko_unfollows(w: World) -> Result(Nil, String) {
  use _ <- step("ochoko unfollows alice", fn() {
    client.post(
      w.ochoko,
      "/api/v1/accounts/" <> w.alice_o <> "/unfollow",
      json.object([]),
      entity.relationship(),
    )
  })
  final_step("Mastodon no longer lists the follower", fn() {
    wait.until("the follower to disappear on Mastodon", fn() {
      use followers <- result.try(followers(w.mastodon, w.alice_m))
      check(!list.contains(followers, ochoko_acct), string.inspect(followers))
    })
  })
}

// ----------------------------------------------------------------- helpers

/// Run one named step, printing its outcome, and continue with its value.
fn step(
  name: String,
  run: fn() -> Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case run() {
    Ok(value) -> {
      io.println("ok   " <> name)
      next(value)
    }
    Error(e) -> {
      io.println("FAIL " <> name)
      Error(name <> ": " <> e)
    }
  }
}

/// A step whose value ends a scenario.
fn final_step(
  name: String,
  run: fn() -> Result(a, String),
) -> Result(a, String) {
  step(name, run, Ok)
}

fn check(condition: Bool, otherwise: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(otherwise)
  }
}

fn marker(label: String) -> String {
  "e2e-" <> label <> "-" <> int.to_string(int.random(1_000_000_000))
}

fn resolve(c: Client, acct: String) -> Result(Account, String) {
  use accounts <- result.try(client.get(
    c,
    client.with_query("/api/v2/search", [
      #("q", "@" <> acct),
      #("resolve", "true"),
      #("type", "accounts"),
    ]),
    entity.search_accounts(),
  ))
  list.find(accounts, fn(a) { a.acct == acct })
  |> result.replace_error(
    "no account " <> acct <> " in " <> string.inspect(accounts),
  )
}

fn relationship(c: Client, id: String) -> Result(entity.Relationship, String) {
  use rs <- result.try(client.get(
    c,
    client.with_query("/api/v1/accounts/relationships", [#("id[]", id)]),
    decode.list(entity.relationship()),
  ))
  list.find(rs, fn(r) { r.id == id })
  |> result.replace_error("no relationship for " <> id)
}

fn followers(c: Client, id: String) -> Result(List(String), String) {
  client.get(
    c,
    "/api/v1/accounts/" <> id <> "/followers",
    decode.list(entity.account()),
  )
  |> result.map(list.map(_, fn(a) { a.acct }))
}

fn post_status(
  c: Client,
  text: String,
  visibility: String,
) -> Result(Status, String) {
  client.post(
    c,
    "/api/v1/statuses",
    json.object([
      #("status", json.string(text)),
      #("visibility", json.string(visibility)),
    ]),
    entity.status(),
  )
}

fn home(c: Client) -> Result(List(Status), String) {
  client.get(c, "/api/v1/timelines/home", decode.list(entity.status()))
}

fn find_in_home(
  c: Client,
  marker: String,
  acct: String,
) -> Result(Status, String) {
  use statuses <- result.try(home(c))
  list.find(statuses, fn(s) {
    string.contains(s.content, marker) && s.account.acct == acct
  })
  |> result.replace_error(
    "not in home timeline ("
    <> int.to_string(list.length(statuses))
    <> " statuses)",
  )
}

fn absent_from_home(c: Client, marker: String) -> Result(Nil, String) {
  use statuses <- result.try(home(c))
  check(
    !list.any(statuses, fn(s) { string.contains(s.content, marker) }),
    "still in home timeline",
  )
}
