#!/bin/sh
# Prepare Mastodon: database, the test account and an API token. Runs inside
# the mastodon-web image; prints only the token on stdout.
set -eu
bundle exec rails db:setup >/dev/null 2>&1
bin/tootctl accounts create alice --email alice@mastodon.test --confirmed --approve >/dev/null
bundle exec rails runner '
  app = Doorkeeper::Application.create!(name: "e2e", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", scopes: "read write follow")
  user = Account.find_local("alice").user
  token = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: user.id, scopes: "read write follow")
  puts token.token
'
