# The relayer, for a host that runs containers. Build from the repository root:
#   docker build -t nearby-relayer .
#   docker run -p 8787:8787 -v nearby-state:/data --env-file relayer/.env nearby-relayer
FROM rust:1-slim AS build
WORKDIR /src
# The workspace manifest names every member, so each has to be present; only the relayer is built.
COPY Cargo.toml Cargo.lock ./
COPY voucher voucher
COPY relayer relayer
COPY bond bond
RUN cargo build --release -p nearby-relayer

FROM debian:bookworm-slim
COPY --from=build /src/target/release/nearby-relayer /usr/local/bin/nearby-relayer
# Double-spends found are kept here; mount a volume on it, or a restart forgets them.
RUN mkdir /data && chown nobody /data
ENV PORT=8787 STATE_FILE=/data/state.jsonl
VOLUME /data
EXPOSE 8787
USER nobody
CMD ["nearby-relayer"]
