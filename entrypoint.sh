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
