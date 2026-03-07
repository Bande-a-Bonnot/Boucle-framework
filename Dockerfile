# Build stage
FROM rust:1.82-slim AS builder

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
COPY tools/ tools/

RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/boucle /usr/local/bin/boucle

# Default: run as MCP server (stdio transport)
ENTRYPOINT ["boucle"]
CMD ["mcp"]
