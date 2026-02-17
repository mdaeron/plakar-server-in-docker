# ─────────────────────────────────────────────────────────────────────────────
# STAGE 1 — Build
# We use a Go image to compile plakar from source, pinned to the exact version
# you requested. The compiled binary is statically linked, so the final image
# can be based on a tiny Alpine image with no Go runtime needed.
# ─────────────────────────────────────────────────────────────────────────────
FROM golang:1.24-alpine AS builder

# The exact plakar version tag we want to build
ARG PLAKAR_VERSION=v1.1.0-beta.4

# git is needed so Go can fetch the module and resolve its VCS metadata
RUN apk add --no-cache git

# Tell the Go toolchain to produce a statically linked binary.
# CGO_ENABLED=0 disables C bindings so the output has no .so dependencies.
ENV CGO_ENABLED=0

RUN go install github.com/PlakarKorp/plakar@${PLAKAR_VERSION}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 2 — Runtime image
# Alpine is a minimal Linux distro (~5 MB). We copy only the compiled binary
# from the builder stage; none of the Go toolchain makes it into this image.
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.21

# Install ca-certificates so plakar can make TLS connections if needed,
# and su-exec to drop privileges cleanly before running the server.
RUN apk add --no-cache ca-certificates su-exec

# Copy the plakar binary out of the builder stage
COPY --from=builder /go/bin/plakar /usr/local/bin/plakar

# Copy the entrypoint script and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ─────── Runtime configuration via environment variables ───────
# PUID / PGID: The user/group ID that the plakar process runs as.
#              Set these to match the owner of your Unraid share so the
#              container can read and write files without permission errors.
ENV PUID=99
ENV PGID=100

# PLAKAR_STORE: Path *inside* the container where the Kloset store lives.
#               This should match the container-side of your bind mount.
ENV PLAKAR_STORE=/kloset

# PLAKAR_LISTEN: The address:port the HTTP server listens on.
#                0.0.0.0 means "all interfaces", making it reachable on the LAN.
#                Port 9876 is plakar's default; change it if you prefer.
ENV PLAKAR_LISTEN=0.0.0.0:9876

# PLAKAR_PASSPHRASE: The encryption passphrase for the Kloset store.
#                    This has NO default value — the container will refuse to
#                    start without it, preventing accidental unencrypted stores.
#                    Supply it at runtime via docker-compose.yml or a .env file;
#                    never hard-code a real passphrase in the Dockerfile itself.
ENV PLAKAR_PASSPHRASE=""

# Expose the port so Docker knows to publish it
EXPOSE 9876

# The entrypoint handles initialization and starts the server
ENTRYPOINT ["/entrypoint.sh"]
