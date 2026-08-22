FROM hexpm/elixir:1.18.4-erlang-28.0.2-alpine-3.22.1 AS build

RUN apk add --no-cache build-base git
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

COPY bench/platform_floor/floor_app/mix.exs ./mix.exs
COPY mix.lock ./mix.lock
RUN MIX_ENV=prod mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

COPY bench/platform_floor/floor_app/lib ./lib
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release

FROM alpine:3.22.1 AS runtime
RUN apk add --no-cache libstdc++ ncurses-libs openssl
WORKDIR /app
COPY --from=build /app/_build/prod/rel/platform_floor ./
ENV HOME=/app
CMD ["/app/bin/platform_floor", "start"]
