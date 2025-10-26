FROM alpine:3.19

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

# Default runtime tuning (override at `podman run` if needed)
ENV BUDDY_CONTROLLER_IDLE_NS=1000000 \
    BUDDY_WORKER_SLEEP_NS=1000

# Create data directories
RUN mkdir -p /data

# Expose port
EXPOSE 10001

USER 1000 
CMD ["/app/buddy-blocks"]
