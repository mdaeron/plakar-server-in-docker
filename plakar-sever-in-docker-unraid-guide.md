# Plakar 1.1.0-beta.4 Docker Container for Unraid
### A step-by-step guide with explanations

---

## Background: What Are We Building?

This guide walks you through creating a custom Docker container that runs **plakar**, a backup server, on your Unraid homelab. The container will:

- Install plakar `v1.1.0-beta.4` from source at build time
- Initialize an encrypted **Kloset** store (plakar's backup repository format) on a mounted Unraid share
- Expose plakar's HTTP server on your LAN so other machines can push backups to it

---

## Concept Glossary

Before diving in, a quick reference for the terms you'll encounter:

| Term | What it is |
|---|---|
| **Docker image** | A read-only blueprint for a container, built from a `Dockerfile` |
| **Docker container** | A running instance of an image |
| **Dockerfile** | A recipe that describes how to build an image, layer by layer |
| **Bind mount / volume** | A directory on the Unraid host mapped into the container so data persists after restarts |
| **Kloset** | Plakar's immutable, content-addressed storage format for backup snapshots |
| **plakar server** | A plakar process that exposes a Kloset store over HTTP so remote clients can back up to it |
| **PUID / PGID** | The numeric user/group IDs used inside the container; matching them to your Unraid share owner avoids permission errors |
| **PLAKAR_PASSPHRASE** | A secret string used to encrypt/decrypt the Kloset; without it the store cannot be read or written |

---

## File Structure

We'll create a small project directory to keep things tidy:

```
~/plakar-docker/
├── Dockerfile          ← builds the image
├── entrypoint.sh       ← starts plakar correctly each time the container runs
├── docker-compose.yml  ← optional, but makes managing the container much easier
└── .env                ← holds the passphrase; kept out of docker-compose.yml
```

---

## Step 1 — Prepare the Unraid Share

On your Unraid server, create (or designate) a share that will hold the Kloset store. For this guide we'll assume it lives at:

```
/mnt/user/backups/plakar-kloset
```

Make note of the **UID and GID** that own that directory. You can check by opening the Unraid terminal and running:

```bash
ls -lan /mnt/user/backups/
```

The numbers in the third and fourth columns are the UID and GID respectively. By default Unraid uses `99:100` (`nobody:users`) for shares. You'll substitute your own values in the files below.

---

## Step 2 — The Dockerfile

Create the file `~/plakar-docker/Dockerfile`:

```dockerfile
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
```

### Why a two-stage build?

The **builder** stage downloads the Go toolchain and compiles plakar. The **runtime** stage copies only the resulting ~20 MB binary into a fresh Alpine image. This keeps the final image small and free of build tools that would otherwise increase the attack surface.

---

## Step 3 — The Entrypoint Script

Create `~/plakar-docker/entrypoint.sh`:

```bash
#!/bin/sh
set -e

# ─────────────────────────────────────────────────────────────────────────────
# entrypoint.sh
#
# This script runs every time the container starts. It:
#   1. Validates that PLAKAR_PASSPHRASE has been set
#   2. Creates (or reuses) a group/user matching the Unraid share ownership
#   3. Ensures the Kloset directory exists and is owned correctly
#   4. Initialises the Kloset store on first run (skips if already initialised)
#   5. Starts the plakar HTTP server as the unprivileged user
# ─────────────────────────────────────────────────────────────────────────────

echo "==> Starting plakar entrypoint"
echo "    PUID=${PUID}  PGID=${PGID}"
echo "    Store : ${PLAKAR_STORE}"
echo "    Listen: ${PLAKAR_LISTEN}"

# ── 1. Require a passphrase ───────────────────────────────────────────────────
# Refusing to start without a passphrase ensures the Kloset is always encrypted.
# This turns a misconfiguration (forgetting to set the variable) into a loud,
# obvious failure rather than a silent unencrypted store.
if [ -z "${PLAKAR_PASSPHRASE}" ]; then
    echo "ERROR: PLAKAR_PASSPHRASE is not set or is empty."
    echo "       Set it in your .env file or docker-compose.yml and restart."
    exit 1
fi

# ── 2. Create group and user to match Unraid share ownership ──────────────────
# We check by GID rather than by name. Alpine's base image already contains
# GID 100 as the built-in 'users' group, so if that GID is already taken we
# reuse the existing group instead of trying to create a duplicate (which
# would error with "gid '100' in use").
if getent group "${PGID}" > /dev/null 2>&1; then
    PGID_NAME=$(getent group "${PGID}" | cut -d: -f1)
    echo "    GID ${PGID} already exists as group '${PGID_NAME}' — reusing it"
else
    addgroup -g "${PGID}" plakar
    PGID_NAME=plakar
fi
if ! getent passwd plakar > /dev/null 2>&1; then
    adduser -D -u "${PUID}" -G "${PGID_NAME}" plakar
fi

# ── 3. Ensure the store directory exists and is writable ─────────────────────
# The bind-mounted directory already exists on the host, but the container
# may not have created the plakar sub-directory yet.
mkdir -p "${PLAKAR_STORE}"
chown -R "${PUID}:${PGID}" "${PLAKAR_STORE}"

# ── 4. Initialise the Kloset store (first-run only) ──────────────────────────
# 'plakar at <path> create' sets up the internal Kloset structure.
# PLAKAR_PASSPHRASE is read by plakar automatically from the environment —
# you do not need to pass it as a flag; plakar's own code consumes it.
#
# We detect first run by checking for the Kloset config file.
if [ ! -f "${PLAKAR_STORE}/CONFIG" ]; then
    echo "==> No existing Kloset found — initialising a new encrypted store"
    su-exec "${PUID}:${PGID}" plakar at "${PLAKAR_STORE}" create
    echo "==> Kloset initialised successfully"
else
    echo "==> Existing Kloset found — skipping initialisation"
fi

# ── 5. Start the plakar server ────────────────────────────────────────────────
# 'plakar at <store> server' creates an HTTP proxy in front of the Kloset,
# letting any plakar client on the LAN push or pull snapshots over HTTP.
# The server itself does not need encryption flags — the Kloset layer handles
# encryption transparently using the passphrase from the environment.
#
# We use su-exec to drop from root (needed to set up the user above)
# to the unprivileged plakar user before exec'ing the server process.
# 'exec' replaces this shell so plakar becomes PID 1 and receives signals
# (e.g. SIGTERM from 'docker stop') directly.
echo "==> Starting plakar server on ${PLAKAR_LISTEN}"
exec su-exec "${PUID}:${PGID}" plakar at "${PLAKAR_STORE}" server -listen "${PLAKAR_LISTEN}"
```

**Key points:**

- `PLAKAR_PASSPHRASE` is read automatically by plakar from its environment — you do not pass it as a command-line flag (which would expose it in `ps` output). The environment variable is the correct channel.
- The explicit guard at step 1 makes misconfiguration fail loudly on startup rather than silently creating an unencrypted store.
- `su-exec` is the Alpine equivalent of `gosu` — it drops privileges cleanly and replaces the shell process rather than forking, so signals (like `docker stop`) reach plakar directly.
- The `exec` at the end of the script means plakar becomes **PID 1** inside the container, which is required for clean shutdown.

---

## Step 4 — The `.env` File

Docker Compose automatically reads a file named `.env` in the same directory and makes its values available as variables. This is the right place to store your passphrase — it keeps the secret out of `docker-compose.yml` (which you might commit to version control) and out of your shell history.

Create `~/plakar-docker/.env`:

```bash
# Plakar Kloset encryption passphrase.
# Use a long, random string. A password manager is a good way to generate one.
# WARNING: if you lose this passphrase, your backups cannot be decrypted.
PLAKAR_PASSPHRASE=replace-this-with-a-strong-random-passphrase
```

**Protect this file:**

```bash
chmod 600 ~/plakar-docker/.env
```

`chmod 600` makes the file readable and writable only by your own user account — no other user on the Unraid host can read it.

> **Do not lose the passphrase.** The Kloset cannot be decrypted without it. Store a copy in a password manager or offline in a safe place.

---

## Step 5 — The Docker Compose File

Using Docker Compose is far more maintainable than a raw `docker run` command, because all your settings live in one readable file. `docker-compose` is bundled with Unraid and requires no separate installation — you can confirm it is present by running `docker-compose --version` in the Unraid terminal.

Create `~/plakar-docker/docker-compose.yml`:

```yaml
services:
  plakar:
    # Build the image from the Dockerfile in this directory.
    # If you later push the image to a registry, replace 'build' with 'image'.
    build:
      context: .
      dockerfile: Dockerfile

    container_name: plakar

    # Restart policy: bring the container back up automatically unless
    # you explicitly stop it with 'docker compose down'.
    restart: unless-stopped

    environment:
      # Match these to the owner of your Unraid share (check with ls -lan).
      - PUID=99
      - PGID=100
      # Address the server listens on inside the container.
      # 0.0.0.0 means all interfaces; the port mapping below controls
      # which host port it is exposed on.
      - PLAKAR_LISTEN=0.0.0.0:9876
      # The passphrase is pulled from the .env file in this directory.
      # The bare variable name (no = sign) tells Compose to forward the value
      # from the .env file into the container's environment without ever
      # writing the secret into this file.
      - PLAKAR_PASSPHRASE

    volumes:
      # Format: <host_path>:<container_path>
      # The host path is your Unraid share directory.
      # The container path must match PLAKAR_STORE in the Dockerfile (default: /kloset).
      - /mnt/user/backups/plakar-kloset:/kloset

    ports:
      # Format: <host_port>:<container_port>
      # Exposing only on the local LAN: omit a specific host IP to listen on all
      # interfaces of the Unraid host, or prefix with your LAN IP to be explicit:
      #   - "192.168.1.50:9876:9876"
      - "9876:9876"

    # Optional: attach to a custom Docker network if you use one in Unraid
    # networks:
    #   - homelab

# networks:
#   homelab:
#     external: true
```

The line `- PLAKAR_PASSPHRASE` (without a value after it) is an important pattern: Compose reads the value from `.env` and injects it into the container, but the secret never appears as plain text inside `docker-compose.yml` itself.

---

## Step 6 — Build and Start the Container

Open the Unraid terminal (or SSH in) and navigate to your project folder:

```bash
cd ~/plakar-docker

# Build the Docker image (downloads Go, compiles plakar — takes a few minutes)
docker-compose build

# Start the container in the background
docker-compose up -d

# Verify it is running
docker-compose ps

# Watch the logs to confirm the Kloset was initialised and the server started
docker-compose logs -f
```

You should see output like:

```
==> Starting plakar entrypoint
    PUID=99  PGID=100
    Store : /kloset
    Listen: 0.0.0.0:9876
==> No existing Kloset found — initialising a new encrypted store
==> Kloset initialised successfully
==> Starting plakar server on 0.0.0.0:9876
```

If you forgot to set `PLAKAR_PASSPHRASE`, the container will exit immediately with:

```
ERROR: PLAKAR_PASSPHRASE is not set or is empty.
       Set it in your .env file or docker-compose.yml and restart.
```

On subsequent restarts, the initialisation step is skipped and you'll see "Existing Kloset found".

---

## Step 7 — Adding the Container in Unraid's Docker UI (Alternative)

If you prefer managing containers through the Unraid web UI instead of Compose, you can add it manually:

1. Go to **Docker → Add Container**
2. Set **Name**: `plakar`
3. Set **Repository**: leave blank if building locally, or enter your image tag if you've pushed it to a registry
4. Under **Extra Parameters** add: `--restart=unless-stopped`
5. Add a **Path** mapping: Container Path `/kloset` → Host Path `/mnt/user/backups/plakar-kloset` → Access Mode `Read/Write`
6. Add a **Port** mapping: Container Port `9876` → Host Port `9876` → Connection Type `TCP`
7. Add **Variables** for `PUID`, `PGID`, `PLAKAR_LISTEN`, and `PLAKAR_PASSPHRASE`

When adding `PLAKAR_PASSPHRASE` in the Unraid UI, set the variable type to **Password** if the option exists — this prevents the value from appearing in plain text in the web interface.

Because the image must be built from a Dockerfile, building it via the terminal first and referencing it by image name in the UI is easier than the manual-add flow.

---

## Step 8 — Connect a Client to the Server

On any machine on your LAN that has plakar installed, set the same passphrase in the client's environment so it can decrypt snapshots it fetches from the server:

```bash
export PLAKAR_PASSPHRASE="replace-this-with-a-strong-random-passphrase"

# List snapshots stored on the server
plakar at http://192.168.1.50:9876 ls

# Back up a directory to the server
plakar at http://192.168.1.50:9876 backup /home/user/documents

# Restore a snapshot
plakar at http://192.168.1.50:9876 restore -to /tmp/restore <snapshot-id>
```

Replace `192.168.1.50` with your Unraid server's LAN IP. The passphrase must match the one used when the Kloset was initialised — plakar will refuse to open the store if it doesn't.

---

## Troubleshooting

**Container exits immediately with "PLAKAR_PASSPHRASE is not set":**
The `.env` file is missing, empty, or not in the same directory as `docker-compose.yml`. Confirm the file exists (`ls -la ~/plakar-docker/`), that it contains `PLAKAR_PASSPHRASE=...`, and that `docker-compose config` shows the variable being picked up before restarting.

**"wrong passphrase" or decryption error on startup or client access:**
The passphrase provided does not match the one used when the Kloset was created. Double-check for extra whitespace or newlines in your `.env` file. If you genuinely don't have the original passphrase, the store cannot be recovered — this is working as intended.

**Permission denied when writing to the Kloset:**
Run `ls -lan /mnt/user/backups/plakar-kloset` on the Unraid host and confirm the UID/GID match `PUID`/`PGID` in your Compose file. If they don't, either update the variables or run `chown -R 99:100 /mnt/user/backups/plakar-kloset` from the Unraid terminal.

**Container exits immediately (other causes):**
Check logs with `docker-compose logs plakar`. A common cause is the Kloset directory not being writable. Another is a port conflict — if something else is already using port 9876, change the host-side port in the Compose file (e.g., `"9877:9876"`).

**plakar build fails in Docker:**
The beta version may require a newer Go toolchain than the one specified — as happened with v1.1.0-beta.4 requiring Go 1.24. Update the builder stage to match (e.g. `golang:1.24-alpine`) and rebuild. You can also use `golang:latest` to always pull the newest available version.

**`cached` process inside container:**
Plakar v1.1.0 replaces the old agent with `cached`, a lightweight background process that manages cache and locking. It starts automatically when needed and stops when idle — you don't need to manage it explicitly.

---

## Security Notes

Since this server is LAN-only, a few things to keep in mind:

- **No built-in authentication**: `plakar server` does not require credentials by default. Any device on your LAN that can reach port 9876 can read and write backups. This is acceptable for a trusted home network. However, because the Kloset is encrypted, a device without the passphrase cannot actually read the backup data even if it can connect to the server.
- **No TLS**: HTTP, not HTTPS. Fine for a LAN; do not expose this port to the internet (don't forward it through your router).
- **Encryption at rest**: The Kloset is encrypted using `PLAKAR_PASSPHRASE`. Data on the Unraid share is ciphertext — unreadable without the passphrase regardless of how someone accesses the underlying files.
- **Passphrase storage**: Keep your passphrase in a password manager and/or a secure offline backup. There is no recovery mechanism — a lost passphrase means permanently inaccessible backups.
- **Delete operations**: By default, `plakar server` does *not* allow delete operations, protecting against accidental data loss. Add `-allow-delete` to the server command in `entrypoint.sh` only if you need it.
