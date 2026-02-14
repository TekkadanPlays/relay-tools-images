FROM rust:1.75 as builder

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy source code
COPY . .

# Build the application
RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create app user
RUN useradd -r -s /bin/false wallet

WORKDIR /app

# Copy binary from builder stage
COPY --from=builder /app/target/release/wallet-service /usr/local/bin/

# Create data directory
RUN mkdir -p /data && chown wallet:wallet /data

USER wallet

EXPOSE 50051 8080

CMD ["wallet-service"]
