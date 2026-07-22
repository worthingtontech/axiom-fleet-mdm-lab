#!/usr/bin/env python3
"""
AXIOM fleet-exporter -- exposes Fleet business metrics that Fleet's own
/metrics endpoint does NOT (it only serves Go/HTTP server-health metrics).

Polls the Fleet REST API (plain HTTP over the axiom-core bridge) and serves a
Prometheus text endpoint on :$EXPORTER_PORT/metrics with:
  axiom_exporter_up
  axiom_hosts_online / _offline / _missing / _total
  axiom_policy_failing_hosts{policy,critical}   (failing-host count per policy)
  axiom_policy_passing_hosts{policy,critical}
  axiom_critical_policy_failing_hosts           (sum where critical=true)
  axiom_enclave_canary_failing_hosts            (canary policy failing hosts)
  axiom_scrape_errors_total

Stdlib only -- no pip deps, tiny image. Auth: logs in with a dedicated observer
user (FLEET_EXPORTER_EMAIL/_PASSWORD) and re-logs in on 401.
"""
import json
import os
import ssl
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FLEET_URL = os.environ.get("FLEET_URL", "http://fleet:1337").rstrip("/")
# api-only users authenticate with a pre-issued token (they cannot use /login).
# Prefer the token; fall back to email+password login for a normal user.
TOKEN = os.environ.get("FLEET_EXPORTER_TOKEN", "").strip()
EMAIL = os.environ.get("FLEET_EXPORTER_EMAIL", "")
PASSWORD = os.environ.get("FLEET_EXPORTER_PASSWORD", "")
PORT = int(os.environ.get("EXPORTER_PORT", "9100"))
POLL = int(os.environ.get("POLL_SECONDS", "30"))

# TLS context only used if FLEET_URL is https (internal default is http).
_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE

_lock = threading.Lock()
_metrics_text = "# AXIOM fleet-exporter starting\naxiom_exporter_up 0\n"
_token = None
_scrape_errors = 0


def _req(path, method="GET", body=None, token=None):
    url = FLEET_URL + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=15, context=_CTX) as r:
        return json.loads(r.read().decode())


def login():
    resp = _req("/api/v1/fleet/login", method="POST",
                body={"email": EMAIL, "password": PASSWORD})
    return resp["token"]


def _esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def poll_once():
    """Return the Prometheus text body for the current Fleet state."""
    global _token, _scrape_errors
    if _token is None:
        _token = TOKEN if TOKEN else login()

    def get(path):
        global _token
        try:
            return _req(path, token=_token)
        except urllib.error.HTTPError as e:
            if e.code == 401:            # token stale -> refresh (static token or re-login)
                _token = TOKEN if TOKEN else login()
                return _req(path, token=_token)
            raise

    summary = get("/api/latest/fleet/host_summary")
    policies = get("/api/latest/fleet/policies").get("policies", [])

    lines = [
        "# HELP axiom_exporter_up 1 if the last Fleet API poll succeeded.",
        "# TYPE axiom_exporter_up gauge",
        "axiom_exporter_up 1",
        "# TYPE axiom_hosts_online gauge",
        f"axiom_hosts_online {summary.get('online_count', 0)}",
        "# TYPE axiom_hosts_offline gauge",
        f"axiom_hosts_offline {summary.get('offline_count', 0)}",
        "# TYPE axiom_hosts_missing gauge",
        f"axiom_hosts_missing {summary.get('mia_count', 0)}",
        "# TYPE axiom_hosts_total gauge",
        f"axiom_hosts_total {summary.get('totals_hosts_count', 0)}",
    ]

    crit_failing = 0
    canary_failing = 0
    lines.append("# HELP axiom_policy_failing_hosts Hosts failing a policy.")
    lines.append("# TYPE axiom_policy_failing_hosts gauge")
    for p in policies:
        name = _esc(p.get("name", "unknown"))
        crit = "true" if p.get("critical") else "false"
        failing = int(p.get("failing_host_count", 0) or 0)
        lines.append(
            f'axiom_policy_failing_hosts{{policy="{name}",critical="{crit}"}} {failing}')
        if p.get("critical"):
            crit_failing += failing
        if "canary" in name.lower():
            canary_failing += failing
    lines.append("# TYPE axiom_policy_passing_hosts gauge")
    for p in policies:
        name = _esc(p.get("name", "unknown"))
        crit = "true" if p.get("critical") else "false"
        passing = int(p.get("passing_host_count", 0) or 0)
        lines.append(
            f'axiom_policy_passing_hosts{{policy="{name}",critical="{crit}"}} {passing}')

    lines.append("# TYPE axiom_critical_policy_failing_hosts gauge")
    lines.append(f"axiom_critical_policy_failing_hosts {crit_failing}")
    lines.append("# HELP axiom_enclave_canary_failing_hosts Hosts where the weights-cache FIM canary policy is failing.")
    lines.append("# TYPE axiom_enclave_canary_failing_hosts gauge")
    lines.append(f"axiom_enclave_canary_failing_hosts {canary_failing}")
    lines.append("# TYPE axiom_scrape_errors_total counter")
    lines.append(f"axiom_scrape_errors_total {_scrape_errors}")
    return "\n".join(lines) + "\n"


def poll_loop():
    global _metrics_text, _scrape_errors, _token
    while True:
        try:
            body = poll_once()
            with _lock:
                _metrics_text = body
        except Exception as e:            # noqa: BLE001 -- surface as a metric, keep serving
            _scrape_errors += 1
            _token = None                 # force re-login next cycle
            with _lock:
                _metrics_text = (
                    "# TYPE axiom_exporter_up gauge\naxiom_exporter_up 0\n"
                    "# TYPE axiom_scrape_errors_total counter\n"
                    f"axiom_scrape_errors_total {_scrape_errors}\n"
                    f"# last error: {_esc(e)}\n")
            print(f"[exporter] poll error: {e}", flush=True)
        time.sleep(POLL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") in ("/metrics", ""):
            with _lock:
                body = _metrics_text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass   # quiet


if __name__ == "__main__":
    threading.Thread(target=poll_loop, daemon=True).start()
    print(f"[exporter] serving :{PORT}/metrics, polling {FLEET_URL} every {POLL}s", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
