# ADR-0004: TLS terminates at Caddy (mkcert CA); lab DNS via hosts-file entries

- **Status:** Accepted (Phase 1)
- **Date:** 2026-07-20
- **Phase:** 1 — Fleet core (docker-compose stack)
- **Related:** ADR-0001 (topology — `axiom-core` compose stack); research brief
  [2026-07-20-phase0-1-fleet-brief.md](../research/2026-07-20-phase0-1-fleet-brief.md) §2;
  encyclopedia 03 (Fleet core), 04 (TLS & PKI)

## Context

Every agent conversation in this lab — osquery enroll/config/log traffic from
fleetd, the live-query WebSocket from the web UI, and (in later phases) Apple/
Windows MDM check-ins and SCEP — happens over HTTPS to a single Fleet URL.
Phase 1 must decide **where TLS terminates, what signs the certificate, and how
lab machines resolve the name** — and those three choices are coupled.

Constraints that shape the decision:

1. **Real TLS matters even in a lab.** fleetd *can* be built with `--insecure`,
   but that disables certificate validation everywhere and trains exactly the
   habit this portfolio exists to reject. The honest $0 path is a real chain:
   a local CA (mkcert) signing a leaf that fleetd genuinely validates.
2. **osqueryd does not use the OS system CA store.** Orbit and Fleet Desktop
   do; osqueryd — the component doing enrollment — does not. Trusting the
   mkcert root on a VM is therefore *not sufficient*: the CA must also be baked
   into the fleetd package via `--fleet-certificate rootCA.pem` (the CA, never
   the leaf). This is the research brief's single most common local-lab
   failure mode, and it means our TLS design must produce a stable
   `rootCA.pem` artifact that every package build and VM provision consumes.
3. **Fleet can terminate TLS itself** (`FLEET_SERVER_TLS=true` + cert/key
   mounts), or a reverse proxy can own it while Fleet serves plain HTTP on the
   compose network.
4. **Name/SAN/URL alignment is load-bearing.** `FLEET_SERVER_URL` is the
   external HTTPS URL clients are redirected to during enrollment, and future
   MDM (Apple SCEP, Windows WSTEP) embeds it in enrollment payloads. The URL's
   hostname must appear in the leaf certificate's SANs, and every enrolling
   device must resolve it — from the Windows host, from every VM, and from the
   Android emulator (which can't use `localhost`). We therefore issue the leaf
   with SANs for `fleet.axiom.lab`, the host's **LAN IP** (detected
   dynamically by the scripts, never hardcoded), and `localhost`.
5. There is no DNS server in the lab, and Phase 5–7 will add more HTTPS
   services (Keycloak, Grafana) that also need names and certificates.

## Decision

**TLS terminates at a Caddy container.** Fleet runs `FLEET_SERVER_TLS=false`
and listens on plain HTTP `0.0.0.0:1337` **inside the compose network only**
(no host publish except an optional `127.0.0.1` loopback for debugging). Caddy
binds host port 443, serves the **mkcert leaf** (`fleet.axiom.lab` + LAN IP +
`localhost` SANs), and `reverse_proxy`s to `fleet:1337` by compose service DNS
— not `127.0.0.1`, which inside the Caddy container would point at Caddy
itself.

**Lab name resolution is hosts-file entries**, not a DNS server:

- The Windows host maps `fleet.axiom.lab` → `127.0.0.1` (or the LAN IP) in
  `C:\Windows\System32\drivers\etc\hosts`.
- Every VM gets `“<LAN-IP> fleet.axiom.lab”` written by its provisioning
  (cloud-init / unattend) — the same code path that installs fleetd and trusts
  `rootCA.pem`.
- The LAN-IP SAN keeps an IP-based fallback *cryptographically* valid for
  anything that can't take a hosts entry (e.g. the Android emulator's NAT view
  of the host). Note the Phase 1 Caddy site matches only the
  `fleet.axiom.lab` hostname on 443 — actually serving raw-IP HTTPS clients
  is a deliberate one-line Caddyfile extension deferred until a phase needs
  it; the SAN is minted now because a leaf can never be amended.

**Why Caddy** rather than nginx or Traefik:

- **Host-preserving transparent proxy by default.** Caddy's `reverse_proxy`
  passes `Host` and sets `X-Forwarded-*` automatically — Fleet sees the
  external hostname unmodified, which osquery enroll, MDM/SCEP, and redirect
  URLs all depend on. nginx needs the `proxy_set_header` boilerplate written
  (and gotten right) by hand.
- **WebSocket passthrough with zero config.** Live query in the Fleet UI rides
  a WebSocket; Caddy upgrades it natively, whereas nginx requires explicit
  `Upgrade`/`Connection` header plumbing (a classic silent-breakage spot —
  brief §7 item 9 still requires an in-UI verification).
- **Config brevity that a reader can audit.** The entire termination story is
  a ~4-line Caddyfile: site name, `tls <leaf> <key>`, `reverse_proxy
  fleet:1337`. Traefik would drag in label/dynamic-config machinery that buys
  nothing at this scale.
- Phase 5–7 will need vhosts for Keycloak and Grafana behind the same 443 —
  Caddy is already the planned front door, so adopting it now avoids a later
  proxy swap.

**Why hosts-file DNS** rather than a local DNS server (dnsmasq/Pi-hole/
Technitium container):

- Zero extra infrastructure: no DNS container to run, secure, and keep
  answering; no per-VM resolver reconfiguration; no DHCP interaction on the
  VirtualBox networks.
- The known cost — *every* VM's provisioning must write the entry — is
  acceptable **because provisioning is code** (Phase 2/6 cloud-init and
  unattend files in Git). A missing entry is a reproducible provisioning bug,
  not a snowflake.

## Consequences

**Positive**
- fleetd validates a real certificate chain end-to-end — no `--insecure`
  anywhere in the lab, matching production practice.
- Fleet's container stays cert-free: no leaf/key mounts, no restart on cert
  rotation; rotating the leaf touches only Caddy.
- One stable `rootCA.pem` artifact feeds `fleetctl package
  --fleet-certificate`, VM trust stores, and `fleetctl debug connection`.
- The proxy layer is already in place for Keycloak/Grafana vhosts in Phase 5–7.

**Negative / risks**
- Plain HTTP exists on the compose bridge between Caddy and Fleet. Accepted:
  the bridge is a single-host private network; mitigated by not publishing
  1337 beyond loopback and by setting `FLEET_SERVER_TRUSTED_PROXIES` to the
  compose bridge subnet so Fleet trusts `X-Forwarded-For` only from Caddy's
  network (confirm the subnet with `docker network inspect`).
- Behind a proxy the UI's WebSocket origin check needs
  `FLEET_SERVER_WEBSOCKETS_ALLOW_UNSAFE_ORIGIN=true` — a documented,
  lab-acceptable relaxation.
- If the host's LAN IP changes (DHCP), the IP SAN and VM hosts entries go
  stale — leaf must be re-issued and VMs re-provisioned. Scripts detect the
  IP dynamically to make this a re-run, not an edit.
- `fleet.axiom.lab` is resolvable only where provisioning has written the
  hosts entry; ad-hoc devices must get the entry manually (the leaf carries a
  LAN-IP SAN as future-proofing, but the Phase 1 Caddy vhost serves the
  hostname only).
- Future MDM enrollment hard-depends on `FLEET_SERVER_URL` ==
  `https://fleet.axiom.lab` staying aligned with the leaf SANs; changing the
  name after MDM assets exist is a re-enrollment event, so the name is fixed
  now.

## Alternatives considered

- **Fleet terminates TLS itself** (`FLEET_SERVER_TLS=true`, mount leaf+key
  into the fleet container). *Rejected:* couples cert rotation to the Fleet
  container, requires read-only cert mounts that hard-fail startup when
  missing, and — since Caddy is needed later for Keycloak/Grafana vhosts
  anyway — would put a TLS hop *behind* the proxy, forcing re-encrypt +
  skip-verify (or CA plumbing) inside the compose network for no security
  gain on a single host.
- **nginx as terminator.** *Rejected:* functionally equivalent but needs
  hand-written `proxy_set_header Host/X-Forwarded-*` and WebSocket upgrade
  blocks — more surface for the exact silent proxy bugs (broken live query,
  wrong redirect host) this lab wants to avoid demonstrating.
- **Traefik.** *Rejected:* dynamic-config/label machinery is overkill for a
  handful of static vhosts; config is harder for a portfolio reader to audit
  at a glance.
- **Local DNS server (dnsmasq/Technitium container).** *Rejected:* real
  infrastructure cost (one more always-on service, VM resolver config) to
  solve a problem hosts-file-as-code already solves at zero cost. Revisit
  only if the lab outgrows static naming.
- **`--insecure` fleetd packages / skip TLS entirely.** *Rejected outright:*
  defeats the purpose — the mkcert chain is the demonstration that $0 does
  not mean fake TLS.
