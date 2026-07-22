#!/bin/sh
# AXIOM remediation -- install + enable the Linux audit daemon (auditd).
# Pairs with policy "Linux -- auditd running (canary)" (gitops/lib/linux/policies/
# canary-auditd.yml). Delivered via Fleet's script-execution API (run-script), which
# runs it as root; the fleetd agent must be built with --enable-scripts.
#
# Idempotent: safe to re-run. On success the auditd process is up, so the policy's
#   SELECT 1 FROM processes WHERE name='auditd'
# returns a row and the host flips green -- which the canary gate then observes.
set -e

echo "[axiom] remediating: install + enable auditd"
export DEBIAN_FRONTEND=noninteractive

if command -v auditctl >/dev/null 2>&1 && pgrep -x auditd >/dev/null 2>&1; then
  echo "[axiom] auditd already running -- nothing to do"
else
  apt-get update -qq
  apt-get install -y --no-install-recommends auditd
  systemctl enable --now auditd
fi

# Confirm the control's observable is now true.
if pgrep -x auditd >/dev/null 2>&1; then
  echo "[axiom] OK: auditd process is running"
else
  echo "[axiom] ERROR: auditd not running after install" >&2
  exit 1
fi
