# Homelab Progress Log

Reference: `homelab-baseline-v5.txt` is the authoritative source of truth for
device names, stack names, and conventions. Read it before making changes.

Environment name: **Johto** (Semaphore project, tag prefixes, future DNS zone)
— orthogonal to host names (wolf/guardian deities) and stack names (HANABIE songs).

---

## Device Reference (current as of 2026-09-15)

| Hostname | Hardware | Role | IP | Status |
|---|---|---|---|---|
| Amaterasu | MSI Z590 PRO WiFi | Production Docker host | 192.168.50.180 | **Fully deployed and verified.** Already running the new stack-based architecture (mapped it out before touching anything — turned out to be further along than assumed, just one orphaned leftover service, which was removed). All 7 canonical stacks confirmed up and healthy. Quadro P620 physically installed, inert until Jellyfin transcode is wired up. |
| Holo | Intel NUC7i5BNK (i5-7260U) | Ansible control plane + monitoring | 192.168.50.65 | **Fully deployed and verified.** devs-talk + warning-core running. Staying put for now — the planned migration to the P330 Tiny is on hold (see below). |
| Chibiterasu | ThinkCentre M920q | Staging | 192.168.50.170 | **Fully deployed and verified.** warning-core (agents) running. RAM temporarily at 16GB (a second stick is earmarked but not installed yet). |
| Kutone | Raspberry Pi 3B+ | NUT server (UPS monitoring) | 192.168.50.12 | **Live, verified.** Ubuntu Server 24.04.5 LTS. Still powered from a wall outlet, not the UPS itself (see Open Items). |
| Lycagon | ASRock Z490M-ITX/ac | OPNsense edge router (not configured) | — | QSFP+ NIC installed, needs a QSA adapter for 10G to the switch. Switch side is ready now — this is the next actionable physical task. |
| Fenrir | Synology RS815 | NAS (DSM) | — | Existing, stable, outside the active migration. |
| Sif | ThinkCentre M910s | Migration source → future NAS | 192.168.50.125 | Still running the OLD flat pre-consolidation stack. To be wiped and rebuilt (Ubuntu, not TrueNAS) once Amaterasu/Holo are fully cut over. |
| P330 Tiny | i7-8700T (6c/12t), 32GB RAM | **On hold** | — | Hit an intermittent boot/POST reliability issue during testing (unresolved). Pulled the Quadro P620 out of it and moved that into Amaterasu regardless — the chassis itself is set aside for now rather than a blocker on anything else moving forward. |

---

## Repo Structure

The old per-service `docker/<service>/docker-compose.yml` layout has been fully
replaced with a stack-based Ansible-managed structure:

- Compose files: `docker/stacks/<stack>/compose.<hostname>.yml`
- Config files:  `docker/configs/<service>/...` (synced to host by Ansible)
- Env files:     generated on each host from Ansible Vault vars at deploy time

### Stacks (all in `docker/stacks/`)

| Stack | Host | Services | Status |
|---|---|---|---|
| tousou-gate | amaterasu | Traefik v3, Authentik + postgres + redis | **Live** |
| sunrise-mqtt-soup | amaterasu | Home Assistant, Mosquitto | **Live** |
| hyperdimension-library | amaterasu | Jellyfin, Calibre, Immich, Mealie | **Live** |
| osaki-ni-cloud | amaterasu | Nextcloud + postgres + redis | **Live** |
| spicy-queen-ctrl | amaterasu | Homarr, Portainer, WhatUpDocker, Actual Budget | **Live** |
| neet-game | amaterasu | Minecraft | **Live** |
| warning-core | amaterasu | node-exporter, cadvisor, dozzle, dashdot (agents only) | **Live** |
| devs-talk | holo | Semaphore, Forgejo, code-server, Planka, Wiki.js, MeshCentral + shared postgres + mongodb | **Live** |
| warning-core | holo | Prometheus, Grafana (core) + agents | **Live** |
| good-day-so-epic | chibiterasu | (sandbox — intentionally empty) | **Live** (empty by design) |
| warning-core | chibiterasu | node-exporter, cadvisor, dozzle, dashdot (agents only) | **Live** |

### Ansible Roles
- **initialize** — system packages, pip deps, sudo setup. Now handles Ubuntu 24.04's PEP 668
  (externally-managed-environment) pip restriction — `break_system_packages` set conditionally
  for 23.04+, omitted on older releases that don't recognize the flag.
- **geerlingguy.docker** — Docker CE + Compose v2 plugin
- **container-configs** — syncs config files and generates `.env.<hostname>` files from vault
- **containers** — copies compose files, starts stacks in correct order
- **nut-client** (new) — installs `nut-client`, sets `MODE=netclient`, points `upsmon` at
  Kutone's NUT server as a slave monitor. Tagged `nut-client` so it can run standalone. Applied
  to `docker-hosts` in the playbook — confirmed active on all three hosts now (holo, chibiterasu,
  amaterasu all connecting to Kutone).
- **tailscale** (new) — adds Tailscale's official apt repo, installs, enables `tailscaled`, and
  joins the tailnet under each host's inventory name. Idempotent — checks `tailscale ip -4`
  first and skips hosts already connected. Tagged `tailscale`, applied to a dedicated
  `tailscale_hosts` group (see Inventory below). See "Remote Access" section below for rollout
  details.

### Inventory (`inventory`)
- Group: `[docker-hosts]` — amaterasu, holo (local), chibiterasu
- holo uses `ansible_connection=local` — **playbook must be run from holo**, manually via SSH
  for now (not yet through Semaphore — see Known Open Items)
- `[misc_hosts]` (new) — non-Docker infra hosts managed piecemeal, outside the main
  docker-hosts playbook group. Currently just kutone, brought into Ansible's reach for the
  first time (previously NUT-server-only, unmanaged) with its own dedicated Holo-issued
  SSH key, same pattern as the docker-hosts.
- `[tailscale_hosts]` (new) — cross-cutting group (amaterasu, holo, chibiterasu, kutone, sif)
  for the tailscale role, independent of which other groups a host belongs to.
- Non-Docker hosts: `[nas_hosts]`, `[k3s_nodes]` — `sif`'s stale IP fixed (was `.249`, now the
  real `.125`); `tsume`/`zinogre` k3s placeholders are still stale, needs cleanup, deferred
- Vagrant testing: use `ansible-playbook -i inventory.vagrant playbook.yml`

### Other
- `.gitignore` covers HA secrets, vault password, DS_Store, and macOS `.DS_Store` recursively
- Prometheus config at `docker/configs/prometheus/prometheus.yml` — scrapes all three
  docker-hosts by LAN IP (holo `.65`, amaterasu `.180`, chibiterasu `.170`)
- `requirements.yml` pins `geerlingguy.docker` 7.0.2 and `community.docker` collection

---

## Ansible Control Plane — now genuinely on Holo

Both directions work now:
- **Pull**: Holo's `~/homeserver` tracks `origin/main` over HTTPS (repo is public, no creds
  needed to read)
- **Push**: Holo has its own repo-scoped GitHub **deploy key** (`~/.ssh/id_ed25519_github`,
  write access enabled), separate from any personal account key — Holo can commit and push on
  its own now, not just the Mac
- **Workflow**: commit + push from wherever the edit happens, `git pull` on Holo before any
  `ansible-playbook` run. The playbook itself only ever runs on Holo — never the Mac.
- Holo needed `git config user.name`/`user.email` set for its first-ever local commit (never
  configured before tonight)

---

## UPS / Power Monitoring (NUT) — Kutone

- **Hardware**: CyberPower PR1500LCDRTXL2U (ex-work, a colleague gave me a spare when it was
  swapped out). No RMCARD (network card) installed — base unit is USB + DB9 serial only.
- **Batteries**: current ones are old/worn — `battery.charge` reads `0`, `ups.status` shows the
  `LB` (low battery) flag even while on utility power and charging. This isn't a NUT bug — it's
  the batteries' internal gas-gauge losing calibration with age, while voltage (47.4V vs 48V
  nominal) suggests some real capacity is still there. **Practical consequence: on the current
  batteries, the UPS effectively shuts off almost immediately on an actual outage** — replacing
  them is a real priority, not just tidiness.
- **Batteries on order (pending funds)**: 4× Mighty Max 12V/9AH, as two dual-packs (~$90 total,
  ~$10 cheaper than 4 singles, ~2 week ship once ordered).
- **NUT server**: Kutone (Raspberry Pi 3B+), Ubuntu Server 24.04.5 LTS. `usbhid-ups` driver,
  confirmed exact hardware match via `lsusb` (`0764:0601`, self-identifies as PR1500LCDRT2U —
  shared USB HID identity across the whole RT2U/XL2U family). Hit one real setup issue: the UPS
  was plugged in before the `nut` package installed its udev rules, causing "insufficient
  permissions" — fixed with `udevadm control --reload-rules && udevadm trigger`.
- **NUT client on Holo**: verified working end to end. Hit `ERR ACCESS-DENIED` on the first
  attempt — root cause was a typo'd password (mismatched between Kutone's `upsd.users` and
  Holo's vault entry), not a syntax issue. Confirmed fixed via Kutone's own server log:
  `User upsmon@192.168.50.65 logged into UPS [cyberpower]`.
- **Open**: Kutone's own power is still a plain wall outlet, not the UPS's Critical-labeled
  (battery-backed) bank. **Deliberately deprioritized** until the battery swap happens — with
  the current dead batteries, moving it now wouldn't meaningfully help, since the whole UPS
  drops almost immediately on an outage regardless of which outlet bank anything is on. Once
  new batteries are in, this becomes the actual priority.

---

## Networking / Switch

- **Cisco Catalyst 3850-48P**: reinstalled 2026-09-14. Hit and fixed two real issues:
  - `gbic-invalid` errdisable on the 10G SFP+ uplink (`Te1/1/4`) — a previously-working
    third-party RJ45-to-SFP+ module got rejected because `service unsupported-transceiver`
    wasn't in the (likely reset/never-saved) running-config. Fixed and this time actually
    saved with `copy running-config startup-config`.
  - Several host ports had come up on default VLAN 1 instead of VLAN 50 (the real subnet,
    192.168.50.0/24) — fixed per-port with `switchport access vlan 50` (`interface range` for
    the multi-port case). Holo and Zinogre needed this; Amaterasu's port was already correct —
    its unreachability turned out to be a loose/misseated Ethernet cable, unrelated to the switch.
  - Current topology: Xfinity modem → ASUS RT-AX88U → 3850 (Te1/1/4). ASUS is standing in as
    the WiFi AP too (no dedicated AP yet).

---

## GPU / Hardware Pipeline

- **GPU**: pulled a **Nvidia Quadro P620** (2GB, Pascal) out of the P330 Tiny and installed it in
  **Amaterasu**, using a 3D-printed full-size PETG bracket (confirmed fit). Pascal supports real
  HEVC decode (10/12-bit) for Jellyfin hardware transcoding. Card is physically installed but
  inert — drivers/nvidia-container-toolkit/Jellyfin passthrough aren't configured yet.
- **P330 Tiny**: hit an intermittent boot/POST reliability issue during hardware testing —
  after certain restarts it fails to POST at all (no display, host unreachable), recoverable
  only by a full AC unplug/replug. Tested across two different power adapters; the issue tracked
  with the board itself, not the adapter. **Unresolved, and set aside for now** — the P620 win
  is banked regardless, and chasing this further isn't worth delaying UPS batteries and getting
  Chibiterasu/Amaterasu on the new architecture, which are the actual priorities. Holo stays on
  the NUC until/unless this gets revisited.

---

## Remote Access — Tailscale

Decided on a mesh VPN (Tailscale) for remote access rather than exposing anything to the
public internet — see DECISIONS.md for the reasoning, including why an earlier attempt at
public access via a Cloudflare Tunnel was reverted.

- Audited the fleet before rolling anything out: amaterasu and sif already had Tailscale
  installed and connected from before this effort — left as-is, no need to touch working
  connections. holo, chibiterasu, and kutone did not have it.
- New `roles/tailscale` installs it fleet-wide and joins each new host under its own
  inventory hostname.
- New devices join tagged (rather than tied to a personal account identity), which also
  disables Tailscale's periodic node-key expiry for them — no manual re-auth needed down
  the road for unattended infrastructure.
- kutone needed a few one-time setup steps before it could be Ansible-managed at all
  (passwordless sudo, a dedicated SSH key from holo) — same bootstrapping every other host
  in the fleet already went through.
- Out of scope for now: Fenrir (Synology) and Lycagon (OPNsense) can both run Tailscale too,
  but through their own platform-specific mechanisms (Package Center, a router plugin) —
  not a fit for the same apt-based role. Separate task, later.

---

## Roadmap Progress

Restructured 2026-09-18 — the old "Phase 1 (current)" label was swallowing basically the
entire foundational buildout into one bucket, which made real, substantial progress look
like it wasn't happening. Four phases now, each with its own checklist.

### Phase 1 — Foundation 🟡 mostly done
- [x] **Plan**: services wanted, device inventory + specs, OS per device, device↔service mapping
      (`homelab-baseline-v5.txt`, this repo's naming conventions)
- [x] **Hardware**: fleet racked and health-checked (NVMe SMART, CPU stress test, log sweep on
      each active host). Two physical racks:
  - **Main rack** — 15U (17" external depth, 12" usable/rackable depth), top to bottom —
    patch panel (1U), switch (1U), CyberPower outlet strip (1U), empty (1U), Sif (2U), empty
    (1U), Synology RS815/Fenrir (1U), empty (1U), Amaterasu (3U), empty (3U) reserved at the
    bottom for growth. A 120mm fan is mounted above the patch panel exhausting upward; a
    second fan slot is reserved for later. The switch and Amaterasu ride on 5"-8" adjustable
    rack extenders to actually fit the 12" rackable depth.
  - **DeskPi RackMate T1** — small/edge devices, top to bottom — NETGEAR ProSafe GS108PE (1U,
    idle, reserved for future expansion — not in active use yet), Chibiterasu (1U), Zinogre
    (1U — hardware/role not yet tracked elsewhere in this doc), Holo (1U), 4U empty. No patch
    panel here yet; considered unnecessary at this scale for now.
- [x] **Network**: 3850 switch reinstalled, VLAN 50 correct fleet-wide (see Networking section
      below for the two bugs hit and fixed)
- [ ] **Network**: Lycagon/OPNsense as the real router — still a consumer router (ASUS RT-AX88U)
      today; switch side has been ready since the 3850 reinstall
- [x] **Ansible control plane**: Holo set up with push + pull GitHub access, Semaphore installed
      (not yet actually driving deploys — see Known Open Items)

### Phase 2 — Core Services Live ✅ done
- [x] Staging (Chibiterasu): warning-core (agents) deployed and verified
- [x] Production (Amaterasu): all 7 canonical stacks deployed and verified — was already
      substantially migrated when actually audited, not the ground-up deploy originally assumed
- [x] All required vault vars populated (`host_vars/amaterasu/vault.yml`,
      `host_vars/holo/vault.yml`) — see DECISIONS.md for the variable names by stack

### Phase 3 — Resilience 🟡 in progress
- [x] UPS monitoring (NUT): Kutone verified end-to-end, `upsmon` confirmed connected on every
      docker-host
- [x] Remote access (Tailscale): fleet-wide rollout, tagged devices for unattended infra
- [ ] UPS batteries swapped (funds-gated) — then move Kutone's own power to the UPS's Critical
      outlet bank
- [ ] NAS backup solution + a real 3-2-1 strategy — Sif still needs to be wiped and rebuilt as
      the actual NAS; nothing is backed up anywhere right now beyond what's already noted
      per-service

### Phase 4 — Scale (later)
- [ ] K3s cluster (M700 control plane + 3x repurposed NUC i5-7260U workers) in a DeskPi
      RackMate T1 — hostnames still TBD
- [ ] Permanent 2.5G switch (Zyxel XMG1915-10E top candidate, ~$170-190), QSFP uplink to Lycagon
- [ ] Configure Jellyfin GPU passthrough for the P620 once hyperdimension-library's drivers are
      wired up
- [ ] Decide what (if anything) to do with the P330 chassis — currently on hold, see above

### Known Open Items (don't map cleanly to a phase)
- [ ] Traefik dashboard is exposed without auth — add Authentik middleware before going live
- [ ] Semaphore is set up (project "Johto") but `holo`'s inventory entry is
      `ansible_connection=local` — Semaphore runs tasks *inside its own container*, which isn't
      the holo host. Needs either a separate Semaphore-facing inventory or switching holo to
      SSH outright before Semaphore can actually drive deploys.
- [ ] Inventory cleanup: `tsume`/`zinogre` k3s placeholders are stale
- [ ] A handful of old/unused directories are still sitting on Amaterasu outside the managed
      stacks (leftover from before the migration) — not touched, just noted for a future cleanup
      pass
- [ ] Discord bot for Semaphore alerts (deferred idea, replaces Telegram)
- [ ] Tailscale on Fenrir and Lycagon (deferred — different install mechanisms per platform)
