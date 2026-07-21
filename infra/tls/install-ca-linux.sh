#!/bin/sh
# =============================================================================
# Project AXIOM — infra/tls/install-ca-linux.sh        (Ubuntu VMs, run as root)
# =============================================================================
# Installs the lab's mkcert root CA (rootCA.pem, produced on the Windows host
# by infra/tls/make-certs.ps1) into the Ubuntu system trust store, so that
# orbit, Fleet Desktop, curl, wget and browsers on this VM trust
# https://fleet.axiom.lab (Caddy's mkcert-signed leaf).
#
# Usage:
#   sudo ./install-ca-linux.sh [path/to/rootCA.pem]
#   (defaults to rootCA.pem sitting next to this script)
#
# Idempotent by design — safe to run repeatedly and from cloud-init runcmd:
# it only rewrites the store when the CA file actually changed. Ubuntu's
# update-ca-certificates requires the file to land in
# /usr/local/share/ca-certificates/ with a .crt extension (content stays PEM).
#
# ─── CRITICAL CAVEAT: osqueryd DOES NOT READ THIS TRUST STORE ────────────────
# Per the Phase 0/1 research brief
# (docs/research/2026-07-20-phase0-1-fleet-brief.md): "osqueryd does not use
# the OS system CA store". Inside the fleetd bundle, orbit and Fleet Desktop
# consult the OS store this script populates — but osqueryd validates TLS
# only against its own bundled certs.pem. The CA must therefore ALSO be baked
# into the fleetd package at build time:
#
#     fleetctl package ... --fleet-certificate /path/to/rootCA.pem
#
# Running this script alone produces the classic half-working host: orbit
# checks in, the host looks online-ish, but osquery enrollment fails with a
# TLS error and no query data ever arrives. This script + the baked cert
# together cover every client on the VM.
# =============================================================================
set -eu

CA_SRC="${1:-$(dirname "$0")/rootCA.pem}"
CA_DST="/usr/local/share/ca-certificates/axiom-mkcert-rootCA.crt"

# ── Preconditions ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (writes ${CA_DST} and rebuilds the store)." >&2
    echo "       Try: sudo $0 $*" >&2
    exit 1
fi

if [ ! -f "$CA_SRC" ]; then
    echo "ERROR: CA file not found: ${CA_SRC}" >&2
    echo "       Generate it on the Windows host with infra/tls/make-certs.ps1," >&2
    echo "       then copy rootCA.pem to this VM (or pass its path as \$1)." >&2
    exit 1
fi

# Cheap sanity check: PEM certificate, not a key or the Caddy leaf bundle.
if ! grep -q 'BEGIN CERTIFICATE' "$CA_SRC"; then
    echo "ERROR: ${CA_SRC} does not look like a PEM certificate." >&2
    exit 1
fi
if grep -q 'PRIVATE KEY' "$CA_SRC"; then
    echo "ERROR: ${CA_SRC} contains a PRIVATE KEY — never distribute rootCA-key.pem." >&2
    exit 1
fi

if ! command -v update-ca-certificates >/dev/null 2>&1; then
    echo "ERROR: update-ca-certificates not found (package: ca-certificates)." >&2
    echo "       apt-get update && apt-get install -y ca-certificates" >&2
    exit 1
fi

# ── Idempotence: skip entirely when the installed CA is already current ─────
if [ -f "$CA_DST" ] && cmp -s "$CA_SRC" "$CA_DST"; then
    echo "OK: CA already installed and current (${CA_DST}) — nothing to do."
    exit 0
fi

# ── Install / refresh ────────────────────────────────────────────────────────
install -m 0644 "$CA_SRC" "$CA_DST"
update-ca-certificates

echo "OK: mkcert root CA installed as ${CA_DST}."
echo "    Verify (needs the fleet.axiom.lab hosts entry + running stack):"
echo "      curl -sSI https://fleet.axiom.lab/healthz"
echo "    REMINDER: this trusts orbit/Fleet Desktop/curl only — osqueryd still"
echo "    needs the CA baked into fleetd via 'fleetctl package --fleet-certificate'."
