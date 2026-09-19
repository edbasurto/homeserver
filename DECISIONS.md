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
- **sif:** agents only
Prometheus on holo scrapes agents on every host by LAN IP. Core services
must never be deployed anywhere except holo.

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

### Remote access via Tailscale instead
Chosen in place of the Cloudflare Tunnel approach above: a mesh VPN rather
than exposing anything to the public internet at all. No public DNS record,
no edge/tunnel layer to troubleshoot, no attack surface beyond the tailnet
itself.

New `roles/tailscale`: adds Tailscale's official apt repo, installs, enables
`tailscaled`, and joins the tailnet under each host's own inventory name.
Idempotent — checks `tailscale ip -4` first and skips hosts already
connected, so it's safe to run against the whole fleet repeatedly.

Ran a fleet audit before rolling anything out rather than assuming a clean
slate (same lesson as the Amaterasu "it's not actually legacy" discovery
above) — amaterasu and sif already had Tailscale connected from before this
effort. Left both as-is; retagging an already-working connection isn't worth
the churn.

New devices join under a **tagged** identity rather than a personal account
identity. This has a concrete operational benefit for unattended
infrastructure: tagged devices don't go through Tailscale's normal periodic
node-key expiry, so there's no manual re-auth needed down the road for
headless servers. The tag name doubles as another use of the Johto
environment name, consistent with `group_vars/all/vars.yml`'s own note that
Johto is meant for exactly this ("tag prefixes").

**Gotcha worth keeping in mind:** `tailscale up` will echo back the full
command it was given — including the auth key — in its own error output if
you try to change settings on an already-configured node without restating
every existing non-default flag (e.g. bare `--force-reauth` with no other
flags, on a node that already has something like SSH access enabled). The
role's join task uses `no_log: true` for exactly this reason — never run
that command manually with verbose/`-v` output, and never re-run it by hand
against an already-joined host without first checking its current settings.

Out of scope for now: Fenrir (Synology) and Lycagon (OPNsense) can both run
Tailscale, but through their own platform-specific mechanisms (Package
Center, a router plugin) rather than a generic apt install — not a fit for
this role, left for a separate task later.

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
`discord_music_bot_env` lives in `host_vars/amaterasu/vault.yml`;
`discord_monitor_bot_env` lives in `host_vars/kutone/vault.yml` (moved there
2026-09-19 along with the bot itself — see below). The relevant role writes
each to the correct host/path on every deploy. Neither should ever be
committed to the repo directly.

Variable names for reference:
- **discord-music-bot** (amaterasu): `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `DISCORD_TOKEN`
- **discord-site-monitor-bot** (kutone): `DISCORD_TOKEN`, `ALERT_CHANNEL_ID`, `MONITOR_ROLE_ID`

### Discord Site Monitor Bot moved from Amaterasu to Kutone
A site-monitor bot that runs on the same host it's supposed to detect
failures for is a broken design — if Amaterasu goes down, the thing that's
meant to tell you goes down with it. Kutone doesn't have this problem: it's
independent of Amaterasu's failure modes, and (as of 2026-09-19) sits on the
UPS's own battery-backed outlets.

Runs via **systemd + a Python venv, deliberately not Docker** — Kutone is a
Raspberry Pi 3B+ with ~900MB usable RAM whose entire reason for existing is
staying minimal and rarely touched (it's the NUT server). Docker's daemon
layer (`dockerd` + `containerd`) carries a real standing overhead —
commonly 100-200MB+ before the bot process itself even starts — that buys
nothing here since this is the only thing that would ever run on this host.
A plain systemd unit costs only the Python process itself (40-80MB).
Measured Kutone's actual headroom before deciding: 631MB available, load
average ~0, NUT's own daemons using under 12MB combined — either approach
would have technically fit, but only one matches "don't load up the
safety-critical box."

The one non-obvious piece: `asyncping3` needs raw-socket access for ICMP.
The old Docker image handled this with `setcap cap_net_raw+ep` on the
container's Python binary. The systemd unit uses `AmbientCapabilities=
CAP_NET_RAW` instead — same effect, but scoped to just this one service
rather than a capability grant on a shared system Python binary.

`sites.json` (the list of fleet hosts it pings — not a secret) is Ansible-
managed as plain `copy: content:` in `roles/discord-monitor-bot`, unlike the
`.env` which stays vault-only. Currently lists amaterasu, holo, chibiterasu,
sif, and kutone — fenrir, zinogre, and lycagon left out (no tracked/live IP
for them yet). It lands at the repo root, not `src/` — the app resolves it
relative to the process's working directory, matching how the old Docker
setup's bind mount put it at `/app/sites.json`, not `/app/src/sites.json`.

**Deployed and confirmed working 2026-09-19**, after finding two more real
issues beyond the ones anticipated above:
- The first apt task included `python3-pip` "just in case" — on 24.04 that
  drags in a full C/C++ build toolchain (`gcc`, `g++`, `python3-dev`, image
  libraries) as dependencies, directly undermining the whole point of
  avoiding Docker's overhead here. A venv doesn't need it — it bundles its
  own pip via `ensurepip`. Removed `python3-pip` from the role and purged
  the ~92MB of now-unneeded packages from Kutone after the fact.
- `asyncping3` imports `pkg_resources`, but installing plain `setuptools`
  didn't fix the resulting `ModuleNotFoundError` — setuptools removed
  `pkg_resources` entirely as of **v82.0.0**. Pinned `setuptools<82`.

Confirmed via logs: logged into Discord, pinging all 5 fleet hosts on a
loop, 36.4MB memory peak — in line with the estimate above. Old Docker
container, image, and directory (including a stale copy of the `.env`)
removed from Amaterasu.

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

### Sif brought into Ansible management — 2026-09-19
Ran a health check first (NVMe SMART, CPU stress test, log sweep) before
touching anything, same discipline as every other host migration this
project has done. NVMe and CPU came back clean. A secondary 1TB HDD in the
box showed a real, repeatable bad sector (SMART self-test fails at the same
LBA every time) — turned out to be irrelevant, since that drive was only
ever a SATA cabling/port test, not the intended NAS storage. The actual
20TB drive isn't installed yet, so the real NAS storage/share role is a
separate, later task.

Verified no real data existed on the old legacy stack before wiping it
(checked actual volume sizes — everything was at default/just-initialized
size, consistent with containers that were started but never really used).
Stopped and removed all of it, then added `sif` to `docker-hosts` and gave
it the same `warning-core` (agents-only) treatment as Chibiterasu. It picks
up `nut-client` and `tailscale` automatically since those plays already
target broader groups Sif is now part of.

Deliberately did **not** invent an app-stack assignment for Sif (e.g.
giving it some of Amaterasu's stacks) — the existing plan has always been
NAS, not a fourth general-purpose app host, and that's still the plan.
Bringing it into `docker-hosts` is about Ansible management and monitoring
consistency, not about running application stacks there.

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
full-size PETG bracket (the card came out of the P330 in a low-profile
bracket).

**Wired up 2026-09-19.** Explicitly picked `nvidia-driver-580` over
`ubuntu-drivers`' own "recommended" pick (`nvidia-driver-390`) — 390 is a
2018-era legacy branch with no meaningful NVENC/NVDEC support, a bad fit for
a card being installed specifically for hardware transcoding. Added
`nvidia-container-toolkit` and a GPU device reservation
(`deploy.resources.reservations.devices`) to Jellyfin's compose service —
verified the whole chain with a throwaway CUDA container before touching
the real service. NVENC/NVDEC codec selection itself lives in Jellyfin's
own dashboard (Playback settings) — a manual UI step, not something Ansible
manages.

### Amaterasu has UEFI Secure Boot enabled — MOK enrollment gotcha
Installing the NVIDIA driver requires DKMS to build an out-of-tree kernel
module, which Secure Boot won't load unless it's signed by a key the
firmware trusts. Ubuntu's tooling handles this by generating a
Machine-Owner Key (MOK) and asking for a password on install — but
**enrolling that key is a physical console step that happens before the OS
boots, at a firmware-level "MOK Manager" screen, and cannot be done over
SSH under any circumstances.** Decided to keep Secure Boot enabled (not
disable it in BIOS to sidestep this) since Amaterasu has monitor access
available for exactly this kind of step; a KVM/remote-console device for it
is a known gap, noted as a future want.

Hit a real, reproducible MokManager bug on the first attempt: a
correctly-typed enrollment password was rejected as "doesn't match" at the
physical prompt. This is a known quirk of MokManager's primitive pre-boot
keyboard handling (Shift-key/capital-letter input is a common trigger), not
user error — the fix was simply to reboot again (safe: Secure Boot stays on,
Ubuntu boots fine either way, the NVIDIA module just doesn't load until
enrollment succeeds) and retry with a fresh password. Worked cleanly the
second time. Relevant if this ever needs doing again on another host: don't
assume a rejected MOK password means it was mistyped — a reboot-and-retry is
the correct first response, not troubleshooting the typing itself.

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

### Kutone's power source — moved to the UPS's Critical outlets
Kutone's own power must come from the UPS's **Critical**-labeled (battery-
backed) outlet bank, confirmed via CyberPower's own documentation — not a
regular wall outlet, or it loses power at the same instant as everything it's
supposed to warn. **Done as of 2026-09-19** — Kutone is now physically on
that outlet bank, ahead of the originally-planned sequencing (this was meant
to wait for the battery swap first).

Worth being precise about what this does and doesn't fix yet: the UPS's
current batteries are still old enough that `battery.charge` reads
effectively 0% and the low-battery flag is set even while charging on
utility power — meaning on an actual outage right now, the whole UPS still
shuts off almost immediately regardless of which outlet anything is plugged
into. So this move protects Kutone from everything *except* a real power
outage today — a crashed/hung/rebooting Amaterasu, a Docker daemon issue,
etc. — which is most of the realistic failure modes, just not literally all
of them. The remaining gap (actual outage survival) still needs the battery
swap, which stays funds-gated and its own separate task.
