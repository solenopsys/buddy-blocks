FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    libgcc \
    libstdc++

# Create app directory
WORKDIR /app

# Copy the binary and library
COPY zig-out/bin/buddy-blocks-musl /app/buddy-blocks
COPY lib/liblmdbx-x86_64-musl.so /usr/local/lib/liblmdbx-x86_64-musl.so

# Set library path
ENV LD_LIBRARY_PATH=/usr/local/lib

# Create data directories
RUN mkdir -p /data

# Expose port
EXPOSE 10001

# Run the server
CMD ["/app/buddy-blocks"]
