# AXIOM telemetry (Phase 5)

Observability for the Fleet control plane and the enrolled fleet — **logs → Loki**,
**metrics → Prometheus**, **dashboards-as-code in Grafana**. A composable add-on: it
joins the running `axiom-core` bridge and reads the existing `fleet-logs` volume, so
the Phase 1–4 stack is never modified.

```
 Fleet osquery result/status logs ──▶ [ vector ] ──▶ [ loki ] ─────────────┐
 Fleet /metrics (basic auth)      ──▶ [ prometheus ] ◀── [ fleet-exporter ] │
 Fleet REST API ──────────────────────────────────────────┘                │
                                                                    [ grafana ]  ◀── dashboards/*.json
```

## Why each source

| Signal | Source | Why |
|---|---|---|
| agents online / check-in lag | **Loki** (`axiom-heartbeat` scheduled query, 60s) | Fleet's `/metrics` has **no** per-host data; a scheduled query that every host logs is the tamper-evident liveness beacon. Kill an agent → its heartbeat stops within one interval. |
| enclave FIM (canary hash) | **Loki** (`axiom-enclave-canary-hash` query) + exporter | streams the live sha256 of the weights-cache canary; the exporter turns policy #8 into a pass/fail gauge. |
| Fleet server health | **Prometheus** `/metrics` | Go runtime, RSS/CPU, per-handler HTTP latency. Enabled by `FLEET_PROMETHEUS_BASIC_AUTH_*` (off by default). |
| failing policies by tier | **fleet-exporter** → Prometheus | Fleet does not expose policy pass/fail in `/metrics`; the exporter polls the REST API and emits `axiom_policy_failing_hosts{policy,critical}`. |

Sources are wired in Git: scheduled queries live in [`gitops/default.yml`](../../gitops/default.yml)
under `reports:` (Fleet renamed the GitOps `queries` key to `reports`); `/metrics` is enabled by
`FLEET_PROMETHEUS_BASIC_AUTH_USERNAME/_PASSWORD` in `infra/.env`.

## Bring up

The core stack must be running first. Then, from the repo root:

```
docker compose -f infra/telemetry/docker-compose.yml --env-file infra/.env up -d --build
```

Grafana → **http://127.0.0.1:3000** (admin / `$GRAFANA_ADMIN_PASSWORD` from `infra/.env`).
Three dashboards auto-provision under the **AXIOM** folder: Fleet Health, Compliance, Enclave FIM.

## Secrets — nothing sensitive is committed

- **Grafana admin** + **exporter** creds live only in `infra/.env` (gitignored).
- The Fleet `/metrics` basic-auth password is written into the `prom-secrets` volume by the
  one-shot `prom-init` container (from `infra/.env`) and referenced by Prometheus via
  `password_file` — it never appears in `prometheus.yml`.
- The exporter authenticates as a dedicated **api-only observer** user (least privilege):
  ```
  fleetctl user create --name "AXIOM Exporter" --email exporter@axiom.lab \
      --password <FLEET_EXPORTER_PASSWORD> --api-only --global-role observer
  ```

## Acceptance

- `docker compose ... up -d` → all dashboards render with live data from a clean start.
- Kill a host's agent (`systemctl stop orbit` or power off the VM) → **Fleet Health → Agents
  reporting** drops within one heartbeat interval (~1 min), and the per-host heartbeat series
  flatlines.

## Ports (all loopback-only — never LAN-exposed)

| Service | Host bind | Purpose |
|---|---|---|
| grafana | `127.0.0.1:3000` | dashboards |
| prometheus | `127.0.0.1:9090` | metrics debug |
| loki | `127.0.0.1:3100` | log API debug |

The only LAN-facing port in the whole lab remains Caddy `:443`.
