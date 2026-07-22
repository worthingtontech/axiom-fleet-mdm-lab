#!/usr/bin/env bash
#
# gitops.sh -- apply the AXIOM Fleet desired state with `fleetctl gitops`.
#
# Used by:
#   * .github/workflows/apply.yml  (self-hosted LAN runner, on push to main)
#   * humans, locally, against the live Fleet server
#
# It ALWAYS dry-runs first, then applies (unless FLEET_DRY_RUN_ONLY=true).
#
# Required environment:
#   FLEET_URL                   - https://fleet.axiom.lab (the live server)
#   FLEET_API_TOKEN             - API-only global-admin token (runbooks/ci-cd-setup.md)
#   FLEET_GLOBAL_ENROLL_SECRET  - expanded into gitops/default.yml at apply time
# Optional:
#   FLEET_DRY_RUN_ONLY=true     - validate only, never mutate the server
#   FLEETCTL_VERSION            - override the pinned fleetctl version
#
# Fleet GitOps semantics (ADR-0006): there is NO `--delete-missing` flag.
# Deletion is declarative *per section* -- dropping an item from a section in the
# YAML removes it on apply; a section omitted entirely is left untouched. Always
# read the dry-run diff before trusting an apply.
set -euo pipefail

# Pin fleetctl in lockstep with the Fleet server (ADR-0006).
FLEETCTL_VERSION="${FLEETCTL_VERSION:-4.89.1}"

# GitOps source files. On Fleet FREE the teams file (fleets/unassigned.yml) is
# SKIPPED by fleetctl ("teams are a Premium feature"); we still pass it so the
# exact command keeps working the day the lab moves to Premium.
GITOPS_FILES=(-f gitops/default.yml -f gitops/fleets/unassigned.yml)

# --- preflight: fail fast on missing required env ----------------------------
: "${FLEET_URL:?FLEET_URL must be set (e.g. https://fleet.axiom.lab)}"
: "${FLEET_API_TOKEN:?FLEET_API_TOKEN must be set (API-only global-admin token)}"
: "${FLEET_GLOBAL_ENROLL_SECRET:?FLEET_GLOBAL_ENROLL_SECRET must be exported (gitops expands it)}"

echo "==> Installing fleetctl@${FLEETCTL_VERSION}"
npm install -g "fleetctl@${FLEETCTL_VERSION}"
fleetctl --version

echo "==> Pointing fleetctl at ${FLEET_URL}"
# TLS is validated against the OS trust store (mkcert -install covers it on the
# runner). NEVER --insecure.
fleetctl config set --address "${FLEET_URL}" --token "${FLEET_API_TOKEN}"

echo "==> Dry-run (validate desired state; no changes)"
fleetctl gitops "${GITOPS_FILES[@]}" --dry-run

if [ "${FLEET_DRY_RUN_ONLY:-false}" = "true" ]; then
  echo "==> FLEET_DRY_RUN_ONLY=true -- stopping after dry-run."
  exit 0
fi

echo "==> Applying desired state to ${FLEET_URL}"
fleetctl gitops "${GITOPS_FILES[@]}"

echo "==> Done."
