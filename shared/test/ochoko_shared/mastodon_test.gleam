import ochoko_shared/mastodon.{Direct, Private, Public, Unlisted}

pub fn visibility_to_string_test() {
  assert mastodon.visibility_to_string(Public) == "public"
  assert mastodon.visibility_to_string(Unlisted) == "unlisted"
  assert mastodon.visibility_to_string(Private) == "private"
  assert mastodon.visibility_to_string(Direct) == "direct"
}
