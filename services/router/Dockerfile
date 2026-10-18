FROM rust:1.90-slim AS build
WORKDIR /app

RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock* ./
# Dependency-cache layer: empty main + build
RUN mkdir src && echo "fn main(){}" > src/main.rs && cargo build --release

COPY src ./src
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim
WORKDIR /app
RUN apt-get update && apt-get install -y ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/ttc-router .
EXPOSE 8081
CMD ["./ttc-router"]