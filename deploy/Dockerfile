FROM debian:trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates build-essential libsqlite3-dev \
 && git clone --depth 1 https://github.com/vlang/v /opt/v && make -C /opt/v
# Without pkg-config, V looks for a bundled sqlite3.c that isn't there.
RUN apt-get install -y --no-install-recommends pkg-config
WORKDIR /src
COPY *.v v.mod ./
COPY web ./web
RUN /opt/v/v -prod -o vlyra .

FROM debian:trixie-slim AS base
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ffmpeg ca-certificates && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["vlyra", "--data", "/data", "--media", "/music"]

FROM base AS source
COPY --from=build /src/vlyra /usr/local/bin/vlyra

FROM base AS prebuilt
COPY deploy/vlyra-linux /usr/local/bin/vlyra
