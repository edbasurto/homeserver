# Architecture Decisions & Rationale

Captures the "why" behind implementation choices that aren't obvious from the
code. Read this before making changes that touch the areas described below.

---

## Networking

### tousou-gate owns the proxy network
`tousou-gate` creates the Docker network `tousou-gate_proxy`. It is the only
stack that declares this network as non-external. Every other stack that needs
Traefik routing references it as:
```yaml
networks:
  proxy:
    external: true
    name: tousou-gate_proxy
```
**Consequence:** tousou-gate must always start before any other stack on
amaterasu. This is enforced in `roles/containers/tasks/start.yml`.

### AdGuard Home not in any stack
AdGuard was in the old tousou-gate compose but was dropped. OPNsense (Lycagon)
has AdGuard Home built in — DNS filtering is handled at the network/router
layer, not as a Docker container.

---

## Stack Decisions

### Traefik over nginx-proxy-manager (tousou-gate)
The baseline specified Traefik v3 + Authentik. The old tousou-gate was a
holdover from before the baseline was written. It was fully rewritten — nginx-
proxy-manager, its MariaDB, and the old meshcentral entry were all removed.

### Mealie over Tandoor (hyperdimension-library)
Both were candidates. Mealie was chosen. Tandoor should not be added.

### Shared postgres for devs-talk
devs-talk runs on holo (Intel NUC7 i5 — modest hardware). Rather than running
four separate postgres containers for forgejo, semaphore, planka, and wiki.js,
one shared `devs-postgres` container is used with a SQL init script at
`docker/configs/devs-postgres/init-databases.sql` that creates all four
databases on first start. All services connect as the same user (`devs`) to
their respective database.

### MeshCentral uses MongoDB (devs-talk)
MeshCentral's supported database is MongoDB. It does not use the shared
postgres instance. Its own `meshcentral-mongodb` container runs alongside it in
devs-talk.

### warning-core is split per host
- **holo:** core services (Prometheus, Grafana) + agents (node-exporter, cadvisor, dozzle, dashdot)
- **amaterasu:** agents only
- **chibiterasu:** agents only
Prometheus on holo scrapes agents on all three hosts by LAN IP. Core services
must never be deployed to amaterasu or chibiterasu.

### nextcloud uses postgres, not mariadb (osaki-ni-cloud)
The old our-7days-restore stack used MariaDB. The baseline specifies postgres.
It was updated when the stack was migrated to osaki-ni-cloud.

### Remote access via Cloudflare Tunnel — tried, reverted 2026-09-17
`ookami.casa` is managed on Cloudflare, and the existing root A record points
at Amaterasu's LAN IP (192.168.50.180, DNS-only/unproxied) — that only ever
resolved usefully from inside the LAN, it was never reachable from outside.

Tried a Cloudflare Tunnel (`cloudflared`) rather than forwarding a port on
the router, for the usual reasons: no inbound port needed on the router,
home WAN IP never exposed, Cloudflare terminates public TLS. Ran as a
service in `tousou-gate`, routing `immich.ookami.casa` directly to
`immich-server:2283`.

**Reverted after extensive troubleshooting turned up a persistent
intermittent 502 that never got fully root-caused.** Ruled out along the
way: DNS, Docker networking, Immich itself (100% reliable under both
sequential and 40-concurrent-request direct testing, bypassing the tunnel
entirely), a wider Cloudflare regional incident. Not fixed by forcing HTTP/2
instead of QUIC, forcing IPv4-only edge connections, or a keep-alive timeout
flag (which turned out to be a documented no-op for a dashboard-managed
ingress config anyway). Failures consistently left zero trace in
`cloudflared`'s own debug logs, pointing at something in Cloudflare's edge
routing to this specific tunnel that wasn't controllable from the container
side. Also saw a device-specific pattern (consistently worse on one phone
than another) that was never isolated — plausibly the client side's own
IPv6/HTTP3 preference, a completely separate connection leg from anything
that was tuned.

Decided: not worth running this publicly in its current flaky state, and a
good moment to reconsider the security posture too — the only things
actually gating access were Cloudflare's edge and Immich's own login,
since Authentik was never wired in front of it. `cloudflared` removed from
`tousou-gate`. The `cloudflare_tunnel_token` vault var was left in place
(harmless, encrypted) in case this gets revisited — if it does, recreating
the tunnel object from scratch in Cloudflare's dashboard is the next
untried step, since the current one's degraded state was never explained.

### mosquitto had no config file — fixed
`sunrise-mqtt-soup`'s mosquitto has bind-mounted `/docker/configs/mosquitto`
since the stack was created, but no task ever wrote a `mosquitto.conf` there
and none existed in the repo — it had been crash-looping (or simply never
running) the whole time. Added `docker/configs/mosquitto/mosquitto.conf`
(listeners on 1883 + 9001/websockets, persistence on, `allow_anonymous true`
since this is LAN-only with no auth configured yet) and a sync task in
`container-configs`, following the same pattern as prometheus/devs-postgres.

### good-day-so-epic is intentionally empty
The sandbox stack on chibiterasu has no pinned services by design. Add and
remove services freely for experiments. Do not promote patterns from here to
production stacks.

---

## Ansible & Deployment

### Playbook must run from holo
holo uses `ansible_connection=local` in inventory. This means Ansible runs holo's
tasks on whatever machine is executing the playbook. holo is the intended
Ansible control plane — Semaphore runs there and executes playbooks. Running
the playbook from a Mac will cause holo's tasks to execute on the Mac instead.

**Deployment order:**
1. SSH to holo manually → run `ansible-playbook playbook.yml --limit holo`
2. Once Semaphore is up on holo, all future runs go through it
3. `--limit chibiterasu` first to validate, then `--limit amaterasu`

All three hosts are deployed as of 2026-09-15. Before running the Amaterasu
deploy, mapped out its actual running state first rather than assuming — it
turned out to already be substantially on the new stack-based architecture,
not the old flat stack. Worth the extra step: it changed the deploy from "big
risky migration" to "small reconciliation plus removing one orphaned leftover
service."

### Vagrant uses a separate inventory
`inventory.vagrant` exists for testing with a local VM. The main `ansible.cfg`
does not contain any vagrant settings. Use:
```bash
ansible-playbook -i inventory.vagrant playbook.yml
```

### Discord bot .env files are vault-managed
Both bot `.env` files are stored in `host_vars/amaterasu/vault.yml` as
`discord_music_bot_env` and `discord_monitor_bot_env`. The container-configs
role writes them to the correct paths on amaterasu on every deploy. They should
never be committed to the repo directly.

Variable names for reference:
- **discord-music-bot:** `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `DISCORD_TOKEN`
- **discord-site-monitor-bot:** `DISCORD_TOKEN`, `ALERT_CHANNEL_ID`

### HA secrets.yaml is optional
`homeassistant_secrets_yaml` in the amaterasu vault is optional. The
container-configs task only runs if the variable is defined. As of the start of
this project the HA secrets.yaml contained only the default placeholder — no
real secrets. Add real values to the vault if/when HA integrations need tokens
or passwords.

---

## Devices

### Zinogre was renamed to Holo
The Intel NUC7 i5 was previously named Zinogre. It was renamed Holo (wise
overseer from Spice and Wolf) to reflect its role as the infrastructure brain.
Zinogre is now an available hostname.

### Sekiro is not part of the homelab
Sekiro is a gaming PC. It must never appear in inventory, stacks, or any
homelab configuration.

### Amaterasu IP
Amaterasu's LAN IP is `192.168.50.180`. This is reflected in the Prometheus
scrape config and inventory. (Was briefly .179 before correction.)

### Holo's IP changed from .125 to .65
.125 is the *old* box (a Lenovo ThinkCentre M910s) that was already live under
the name "holo" (via Tailscale) when this whole consolidation effort started —
that was legacy/accidental, not a deliberate hardware choice. The real Holo is
an Intel NUC7i5BNK at `.65`. The old M910s was renamed **Sif** and is the
migration source for a future NAS rebuild, not a competing Holo candidate.

### P330 Tiny — set aside for now
Was weighing this box (i7-8700T, 6c/12t, 32GB RAM) as a replacement for Holo,
reasoning that its role-fit (continuous, growing load — Ansible control
plane, Semaphore CI/CD, Forgejo, Postgres/Mongo, fleet monitoring) beats raw
spec comparisons with Chibiterasu or holding it for a future K3s control
plane.

That plan is on hold. During hardware testing the P330 turned up an
intermittent boot/POST reliability issue — after certain restarts it fails to
POST at all (no display, host unreachable), only recoverable with a full AC
unplug/replug. Tested across two different power adapters and traced it to
the board itself, not the adapter. Root cause still unknown.

Decided: **don't chase this further right now.** The GPU (Quadro P620) was
already pulled out of it and is a clean win regardless of what happens to the
chassis — no reason to hold that up. Continuing to debug an intermittent,
hard-to-reproduce fault isn't worth delaying UPS batteries or getting
Chibiterasu/Amaterasu onto the new architecture, which matter more right now.
Holo stays on the NUC7i5BNK until/unless this gets revisited.

### GPU: Quadro P620 in Amaterasu
The P330 Tiny's GPU (confirmed via physical inspection: Quadro P620, Pascal,
2GB, ~40W, slot-powered) was pulled and installed in Amaterasu for Jellyfin
hardware transcoding. Pascal supports real HEVC decode (10/12-bit), which
matters for modern 4K/HDR media libraries. Installed with a 3D-printed
full-size PETG bracket (the card came out of the
P330 in a low-profile bracket). Card is physically present but inert —
drivers/nvidia-container-toolkit/Jellyfin passthrough are not configured and
won't be until hyperdimension-library actually deploys to Amaterasu.

---

## UPS / Power Monitoring (NUT)

### NUT on a dedicated Pi, not on Holo
Considered running the NUT server directly on Holo instead of buying/using a
separate device. Decided on a dedicated Raspberry Pi 3B+ (named **Kutone**,
after Chibiterasu's companion spirit in Ōkamiden) because:
- Holo is also the box that gets touched most (Ansible runs, Docker restarts,
  Semaphore deploys) — coupling "the thing that must reliably warn everyone
  before a real outage" to "the thing that's mid-changed most often" is a bad
  pairing for something safety-critical.
- Power budget: a Pi draws single-digit watts vs. a loaded NUC; if something
  needs to be the last device standing during an outage, low power draw
  matters.

### Kutone's power source — and why fixing it is deliberately on hold
Kutone's own power must come from the UPS's **Critical**-labeled (battery-
backed) outlet bank, confirmed via CyberPower's own documentation — not a
regular wall outlet, or it loses power at the same instant as everything it's
supposed to warn.

As of 2026-09-14 it's still on a wall outlet. This is **deliberate, not
forgotten**: the UPS's current batteries are old enough that `battery.charge`
reads effectively 0% and the low-battery flag is set even while charging on
utility power — meaning on a real outage right now, the whole UPS shuts off
almost immediately regardless of which outlet anything is plugged into.
Moving Kutone's power now wouldn't meaningfully protect it yet. The actual
fix — new batteries — is funds-gated; moving Kutone's power becomes the
priority again once those batteries are in.
