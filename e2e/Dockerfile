# syntax=docker/dockerfile:1
#
# Images for the e2e stack. Build context is the repository root.
# Keep the Gleam and OTP versions in sync with aqua.yaml.

FROM ghcr.io/gleam-lang/gleam:v1.19.2-scratch@sha256:e4c66c370646bb35b13e9c0612dbf89d2b4f4999151f34aeab55eb5dd439dada AS gleam

FROM erlang:28.5.0.8@sha256:fe3425a5d92e03aa3696b951b128f6c55c6f76d4ddf341c8e511ae9c515ac8d2 AS toolchain
COPY --from=gleam /bin/gleam /usr/local/bin/gleam

FROM toolchain AS build
WORKDIR /src
COPY shared shared
COPY server server
RUN cd server && gleam export erlang-shipment

# The ochoko server.
FROM erlang:28.5.0.8-slim@sha256:45e0fcffac25a41ed047898a57c7913cc69b5114c1aea0db12c85ed4b1164d77 AS ochoko
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/server/build/erlang-shipment /app
RUN mkdir /data
COPY e2e/ochoko/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve", "--config", "/etc/ochoko/ochoko.toml"]

# The test driver.
FROM toolchain AS runner
WORKDIR /runner
COPY e2e/runner/gleam.toml e2e/runner/manifest.toml ./
RUN gleam deps download
COPY e2e/runner .
RUN gleam build
COPY e2e/runner/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["gleam", "run"]
