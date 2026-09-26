# Homelab Progress Log

Reference: `homelab-baseline-v5.txt` is the authoritative source of truth for
device names, stack names, and conventions. Read it before making changes.

Environment name: **Johto** (Semaphore project, tag prefixes, future DNS zone)
— orthogonal to host names (wolf/guardian deities) and stack names (HANABIE songs).

---

## Device Reference (current as of 2026-09-15)

| Hostname | Hardware | Role | IP | Status |
|---|---|---|---|---|
| Amaterasu | MSI Z590 PRO WiFi | Production Docker host | 192.168.50.180 | **Fully deployed and verified.** Already running the new stack-based architecture (mapped it out before touching anything — turned out to be further along than assumed, just one orphaned leftover service, which was removed). All 7 canonical stacks confirmed up and healthy. Quadro P620 driver + container passthrough working — Jellyfin's container confirmed sees the GPU (`nvidia-smi` clean inside it). |
| Holo | Intel NUC7i5BNK (i5-7260U) | Ansible control plane + monitoring | 192.168.50.65 | **Fully deployed and verified.** devs-talk + warning-core running. Staying put for now — the planned migration to the P330 Tiny is on hold (see below). |
| Chibiterasu | ThinkCentre M920q | Staging | 192.168.50.170 | **Fully deployed and verified.** warning-core (agents) running. RAM temporarily at 16GB (a second stick is earmarked but not installed yet). |
| Kutone | Raspberry Pi 3B+ | NUT server + Discord Site Monitor Bot | 192.168.50.12 | **Live, verified.** Ubuntu Server 24.04.5 LTS. Now powered from the UPS's own Critical (battery-backed) outlet bank. Site monitor bot runs via systemd + venv (not Docker) — moved from Amaterasu 2026-09-19. |
| Lycagon | ASRock Z490M-ITX/ac | OPNsense edge router (not configured) | — | QSFP+ NIC installed, needs a QSA adapter for 10G to the switch. Switch side is ready now — this is the next actionable physical task. |
| Fenrir | Synology RS815 | NAS (DSM) | — | Existing, stable, outside the active migration. |
| Sif | ThinkCentre M910s | Ansible-managed + future NAS | 192.168.50.125 | **Legacy stack wiped, now Ansible-managed.** warning-core (agents) running, confirmed healthy in Prometheus/NUT/Tailscale. Actual NAS storage role (Samba/NFS shares) still pending — the 20TB drive isn't installed yet. |
| Zinogre | Intel NUC | Game server (idle) | 192.168.50.151 | **Palworld migrated to Amaterasu 2026-09-25.** Stopped, not decommissioned — kept as a cold fallback copy of the world in case anything needs rolling back. |
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
| warning-core | sif | node-exporter, cadvisor, dozzle, dashdot (agents only) | **Live** |

### Ansible Roles
- **initialize** — system packages, pip deps, sudo setup. Now handles Ubuntu 24.04's PEP 668
  (externally-managed-environment) pip restriction — `break_system_packages` set conditionally
  for 23.04+, omitted on older releases that don't recognize the flag.
- **geerlingguy.docker** — Docker CE + Compose v2 plugin
- **container-configs** — syncs config files and generates `.env.<hostname>` files from vault
- **containers** — copies compose files, starts stacks in correct order
- **nut-client** (new) — installs `nut-client`, sets `MODE=netclient`, points `upsmon` at
  Kutone's NUT server as a slave monitor. Tagged `nut-client` so it can run standalone. Applied
  to `docker-hosts` in the playbook — confirmed active on all four hosts now (holo, chibiterasu,
  amaterasu, sif all connecting to Kutone).
- **tailscale** (new) — adds Tailscale's official apt repo, installs, enables `tailscaled`, and
  joins the tailnet under each host's inventory name. Idempotent — checks `tailscale ip -4`
  first and skips hosts already connected. Tagged `tailscale`, applied to a dedicated
  `tailscale_hosts` group (see Inventory below). See "Remote Access" section below for rollout
  details.

### Inventory (`inventory`)
- Group: `[docker-hosts]` — amaterasu, holo (local), chibiterasu, sif
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
- **Done 2026-09-19**: Kutone's own power moved to the UPS's Critical-labeled (battery-backed)
  outlet bank — ahead of the originally-planned sequencing (this was meant to wait for the
  battery swap first). Protects Kutone from everything except an actual power outage today —
  the current batteries are still worn enough that the whole UPS drops almost immediately on a
  real outage regardless of outlet bank, so that specific gap still needs the battery swap.
  Everything else (Amaterasu crashing, a hung Docker daemon, a bad reboot) is already covered.

---

## Discord Site Monitor Bot — moved to Kutone, 2026-09-19

Was on Amaterasu (Docker) — moved because a monitor that dies along with the
host it's supposed to detect failures for is a broken design. New
`roles/discord-monitor-bot`: systemd + a Python venv, deliberately not
Docker, since Kutone's whole reason for existing is staying minimal (see
DECISIONS.md for the full "why not Docker here" reasoning and the measured
headroom numbers).

Three real bugs hit getting it running, in order:
1. First apt task included `python3-pip`, which on 24.04 drags in a full
   C/C++ build toolchain (`gcc`, `g++`, `python3-dev`, image libraries) as
   dependencies — directly undermining the point of avoiding Docker's
   overhead. A venv doesn't need it (bundles its own pip via `ensurepip`).
   Fixed the role, then removed the ~92MB of now-unneeded packages from
   Kutone with `apt remove --purge` + `autoremove`.
2. `asyncping3` imports `pkg_resources`, which a bare `python3 -m venv` on
   3.12 doesn't bundle. Installing plain `setuptools` didn't fix it either —
   setuptools removed `pkg_resources` entirely as of **v82.0.0**. Pinned
   `setuptools<82`.
3. `sites.json` landed in the wrong place (`src/sites.json`, matching where
   the `.example` file lives in the repo) — the app actually resolves it
   relative to the process's working directory (the repo root), matching
   how the old Docker setup's bind mount put it at `/app/sites.json`, not
   `/app/src/sites.json`.

Confirmed fully working: logged into Discord, pinging all 5 fleet hosts on
a loop, 36.4MB memory peak. Old Docker container, image, and directory
(including a stale copy of the `.env` with the real token) removed from
Amaterasu. `discord_monitor_bot_env` vault var moved from
`host_vars/amaterasu/vault.yml` to `host_vars/kutone/vault.yml` to match.

---

## Networking / Switch

- **Named: Cerberus.** 2026-09-19 — the Cisco Catalyst 3850 gets a permanent hostname,
  fitting the guardian-deity convention: a three-headed hellhound guarding the gate everything
  else has to pass through, and canonically an evolution of Fenrir (World of Final Fantasy) —
  a nice fit given Fenrir is already the NAS. Turned out the hostname (and domain name,
  `ookami.casa`) had already been applied to the device itself in an earlier undocumented
  session — confirmed via the existing RSA key name (`cerberus.ookami.casa`) when SSH was set
  up below. Docs are caught up now; device config already matched.
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
- **SSH access configured, 2026-09-19.** `crypto key generate rsa` (2048-bit), `username ookami
  privilege 15 secret ...` (privilege 15 chosen deliberately — single-admin home switch, SSH
  login lands directly in privileged EXEC instead of requiring a separate `enable` step),
  `ip ssh version 2`, `line vty 0 15` / `transport input ssh` / `login local` (Telnet fully
  disabled, not left as a fallback).
  - Hit and fixed a real bug along the way: the switch's management IP (`192.168.50.57`) was
    assigned to the **Vlan1** SVI, but `show vlan brief` confirmed every actual host port lives
    on **Vlan50** ("LAN") — Vlan1 only holds two unused stack/module ports (`Gi1/1/1`, `Gi1/1/2`).
    Same subnet number (192.168.50.0/24) assigned across two different VLANs meant ARP requests
    from any real host never reached it (`ssh: Host is down`) even though the interface itself
    showed `up/up`. Fixed by removing the IP from `Vlan1` and re-adding it to `interface vlan 50`
    instead — no `ip routing` needed since this isn't inter-VLAN routing, just moving the
    management address into the broadcast domain everything else already lives in.
  - Confirmed working: `ping` and `ssh ookami@192.168.50.57` both succeed now.
- **Orthrus — NETGEAR GS108PEv3, brought online in the DeskPi RackMate T1, 2026-09-19.**
  Named for Cerberus's mythological sibling (another multi-headed guard dog, guarding a lesser
  domain) — reads as the small edge switch to Cerberus's core switch. Lowercase (`orthrus`) on
  the device itself, matching every other host in the fleet.
  - Real bug found and fixed: it was still sitting at its **factory-default IP, `192.168.0.239`**
    — not anywhere in `192.168.50.0/24` — which is why the previously-documented address never
    worked (`ssh: Host is down`). Confirmed via a Mac-side interface alias
    (`sudo ifconfig en6 alias 192.168.0.10 255.255.255.0`) + a direct ping, after a full
    `192.168.50.0/24` ARP sweep + MAC-vendor lookup (`api.macvendors.com`) came up with no
    NETGEAR-vendor match at all — proof its management IP wasn't on this subnet, even though
    the switch was already bridging client traffic on that subnet correctly (a MacBook plugged
    directly into it got a clean DHCP lease the whole time). Reconfigured to a static
    `192.168.50.58` / `255.255.255.0` / gateway `192.168.50.1`, right next to Cerberus.
  - Settings: **Switch Management Mode → Web browser and Plus Utility** (enables NSDP discovery
    so it can be found again without already knowing its IP — the exact problem just solved the
    hard way); **Loop Detection → enabled** (this switch doesn't run real STP the way Cerberus
    does, so it needs its own protection against a self-inflicted cable loop); **VLAN → left
    disabled** (the uplink from Cerberus's `Gi1/0/48` is an access port on VLAN 50, so it already
    hands Orthrus plain untagged frames — enabling VLAN mode here would add complexity with no
    benefit unless the uplink is ever changed to a trunk).
  - **Firmware: updated `V2.06.10EN` → `V2.06.24EN`, 2026-09-19.** The prior version was directly
    affected by [CVE-2020-5641](https://www.cve.org/CVERecord?id=CVE-2020-5641) (CSRF — a
    malicious page could hijack an authenticated admin session and silently reconfigure the
    switch), fixed in 2.06.14; 2.06.24 was the latest available at the time, so went straight
    there instead of stopping at the minimum fix. Flashed via the web UI, no issues. The update
    added a new **Power Saving Mode (IEEE 802.3az)** toggle — enabled it (mature standard,
    negligible risk, real power savings on ports not running at full utilization). Also declined
    to enable **File Transfer via Plus Utility (TFTP)** — unlike the NSDP discovery mode enabled
    above, this would allow pushing firmware/config over an unauthenticated protocol; no real use
    case for it since the web UI already handles updates fine, so left disabled.

---

## GPU / Hardware Pipeline

- **GPU**: pulled a **Nvidia Quadro P620** (2GB, Pascal) out of the P330 Tiny and installed it in
  **Amaterasu**, using a 3D-printed full-size PETG bracket (confirmed fit). Pascal supports real
  HEVC decode (10/12-bit) for Jellyfin hardware transcoding.
  **2026-09-19: wired up and working.** Installed `nvidia-driver-580` (explicitly, not the
  `ubuntu-drivers`-recommended 390 — a 2018-era branch with no real NVENC/NVDEC support) +
  `nvidia-container-toolkit`. Amaterasu has UEFI Secure Boot enabled, which meant a MOK
  (Machine-Owner Key) enrollment — a physical console step at boot, before the OS loads, that
  can't be done over SSH. First attempt's enrollment password silently failed at the physical
  prompt (a known MokManager quirk with password entry, not user error); worked cleanly on a
  second attempt with a fresh password. Verified the full chain with a throwaway CUDA container
  before touching the real service, then added a GPU device reservation to Jellyfin's compose
  service. Jellyfin's own container confirmed sees the GPU (`nvidia-smi` clean inside it).
  Only 2GB VRAM on this card — fine for a couple of concurrent transcodes, worth watching under
  heavier 4K HDR tone-mapping load. NVENC enabled in Jellyfin's own dashboard (Playback →
  Transcoding tab — a manual UI step, not Ansible-managed) and confirmed available at the
  FFmpeg level (`h264_nvenc`/`hevc_nvenc`/`av1_nvenc` + `cuda` hwaccel all show up in Jellyfin's
  own logs). **Still needs an actual end-to-end test** (watch `nvidia-smi` during a forced
  transcode) — no media on Amaterasu yet to test with, deferred until there is.
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

## Backups (3-2-1) — restic to Fenrir, 2026-09-21

The "2" in the 3-2-1 plan is now live: Amaterasu backs up to Fenrir nightly via `restic`, over
SFTP, on an automated systemd timer. New `roles/restic-backup`, deployed to Amaterasu only.

- **Scope**: Immich, Home Assistant, Mealie, Actual Budget. Deliberately excludes Jellyfin
  (media is replaceable, not worth the space/bandwidth) and Nextcloud (deployed but not
  actually in use yet — will be added once it is).
- **Per-service mechanics**: Postgres-backed services (Immich) get a `pg_dump` first — never
  snapshot a live Postgres data directory directly. SQLite-backed services (Home Assistant,
  Mealie, Actual Budget) get a `sqlite3 .backup` first, same reasoning — a raw copy of a live
  SQLite file can catch it mid-write and come back corrupt. The `pg_dump` step uses the
  container's own `$POSTGRES_USER`/`$POSTGRES_DB` env vars rather than hardcoding credentials
  into the script.
- **Retention**: 14 daily / 8 weekly / 6 monthly snapshots, pruned automatically after each run
  to actually reclaim space on Fenrir rather than let it grow unbounded.
- **Fenrir-side setup** (manual, since Fenrir isn't Ansible-managed): a dedicated `backups`
  shared folder (Recycle Bin left off deliberately — restic already handles its own
  versioning, a second retention layer at the filesystem level would just silently prevent
  pruned space from actually being reclaimed), SFTP enabled (a separate toggle from plain SSH —
  Control Panel > File Services > FTP > SFTP tab), and DSM's "User Home" service enabled (no
  home directory existed for the account at all until this was turned on, which is also where
  `~/.ssh/authorized_keys` has to live).
- **First real backup confirmed working**, 2026-09-21: 270 files, 232MiB backed up (154MiB
  stored after dedup/compression), snapshot saved and retention policy applied cleanly.

**Real bugs hit and fixed getting here** (six, not one — worth recording since several were
non-obvious):
1. Missing `BatchMode=yes` on the SSH command meant a failed key-auth attempt silently fell
   back to waiting for a password prompt that would never come, hanging forever instead of
   failing fast.
2. An unquoted env-file value containing spaces (`RESTIC_SSH_COMMAND=ssh -i ... -o ...`) broke
   when the file was sourced as a shell script — only the first word was taken as the value.
3. Root has no `/root/.ssh` on Amaterasu, so `StrictHostKeyChecking=accept-new` had nowhere to
   persist the accepted host key. Fixed by pointing `UserKnownHostsFile` at
   `/etc/restic/known_hosts` instead of depending on root's home directory existing.
4. Ubuntu 24.04's apt-installed restic is **0.12.1**, which predates `RESTIC_SSH_COMMAND`
   support entirely (added in 0.15.2+) — it was being silently ignored on every single
   connection attempt. Fixed by installing restic 0.19.1 directly from GitHub releases instead
   of relying on the stale apt package.
5. Even on 0.19.1, `RESTIC_SSH_COMMAND` still wasn't taking effect reliably. Rebuilt the role
   around explicitly passing `-o sftp.command="..."` on every restic invocation instead of
   depending on env-var auto-detection — version-independent and easy to verify.
6. The systemd service had no `$HOME` set (systemd services don't inherit a shell HOME by
   default), and restic refuses to run without one to derive its cache directory from. Added
   `Environment=HOME=/root` to the service unit.
- Also, mid-task: a `docker exec immich-postgres printenv` command run to verify env var names
  accidentally printed `POSTGRES_PASSWORD` in plaintext to a tool output. Same incident class
  as the earlier vault leak — stopped immediately, flagged, rotated `immich_pg_password`
  (DB password changed via a trusted local `docker exec` connection, vault updated, redeployed).

---

## Authentik — fixed a silent non-functional deployment, 2026-09-25

`authentik-server` and `authentik-worker` had been running (in the `docker ps` sense) since the
tousou-gate rewrite, but neither had ever actually finished starting up — both were stuck in an
infinite connection-retry loop from the moment they were first deployed. Because Authentik
retries instead of exiting on a failed dependency connection, this never showed up as a restart
or a crash — just "Up N days" forever, quietly non-functional the whole time. Found by chance
while spot-checking container health (dashdot/portainer) and noticing `authentik-worker`'s
restart count was in the thousands.

**Three separate bugs, all pre-existing (not introduced by the tousou-gate rewrite itself)**:
1. `AUTHENTIK_POSTGRESQL__HOST` was never set. Authentik defaults to `127.0.0.1` when it's
   missing, so the worker was endlessly retrying Postgres on its own loopback instead of the
   `authentik-postgres` container. Fixed by adding the var explicitly in
   `roles/container-configs/tasks/main.yml`.
2. Same bug, same fix, for Redis: `AUTHENTIK_REDIS__HOST` was also never set, so both
   `authentik-server` and `authentik-worker` were separately stuck retrying Redis on `localhost`
   too — this one affected the server, not just the worker, meaning the actual login/SSO service
   itself had never come up either.
3. `/docker/configs/authentik/{media,templates,certs}` were owned `root:root 0755` (created ad
   hoc, before this role existed) — Authentik runs as uid 1000 internally and had no write
   access, so the migration step failed with `PermissionError: .../media/public` every time.
   Fixed with a proper directory-creation task, owned `1000:1000`, following the same pattern
   already used for the *arr pipeline's config dirs.
- A `grep` intended to check only for the `AUTHENTIK_POSTGRESQL__HOST` key name matched the
  whole `AUTHENTIK_POSTGRESQL` prefix and printed `AUTHENTIK_POSTGRESQL__PASSWORD` in plaintext.
  Same incident class as the Immich/restic-backup leaks — stopped, flagged, `authentik_pg_password`
  rotated (`ALTER USER` via a trusted local `docker exec` session, vault updated, redeployed).
- All three fixes deployed from Holo (the only host playbooks are ever run from) and verified via
  container health/logs and a direct `pg_stat_activity` connection count — never another
  credential-exposing check. Both containers now report `running`/`healthy` with real API traffic
  in the logs, apparently for the first time.
- **Authentik is not currently gating access to anything** — it was never wired into Traefik as
  forward-auth for any service, and still isn't. The Traefik dashboard is still exposed with no
  auth in front of it (existing open item, unchanged by this fix).

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
- [x] Kutone moved to the UPS's Critical (battery-backed) outlet bank
- [ ] UPS batteries swapped (funds-gated) — the one remaining gap: current batteries still
      can't hold a real outage, regardless of which outlet anything is on
- [x] NAS backup solution + a real 3-2-1 strategy — the "2" is done: restic backs up Amaterasu
      to Fenrir nightly, verified working. See the dedicated "Backups (3-2-1)" section above.
      **The "1" copy is a 26TB Western Digital Red Pro (model WD260KFGX)**, internal SATA in
      Sif's one 3.5" bay — brand new, a gift, deliberately kept write-infrequent to protect its
      longevity/value.
  - **The two spare 8TB drives have real, decided roles now — the hot-swap-dock idea is
    shelved, not needed.** The Seagate ST8000NM0055 (16 reallocated sectors) went to Amaterasu
    as Jellyfin's media drive — matched deliberately to the lower-stakes role, since Backblaze's
    own drive-failure research shows any nonzero reallocated-sector count is a real elevated
    near-term failure signal, and Jellyfin's media is explicitly replaceable if that happens.
    The clean WD80EMAZ (0 reallocated/pending/uncorrectable across the board) is held in
    reserve for the higher-stakes backup role instead.
  - **A third spare surfaced 2026-09-20**: a 1TB WD1003FBYX-01Y7B0 (WD RE4 enterprise line),
    health-checked clean, currently sitting in Sif temporarily with no assigned role yet.
  - **The K3s cluster plan (M700 control plane + 3x NUC workers) was dropped outright**,
    2026-09-20 — no real use case ever materialized, and a friend's suggestion to replace
    Ansible with Kubernetes entirely prompted a full reconsideration that concluded K8s's real
    advantages don't pay off at this fleet's scale/shape. See DECISIONS.md. This frees the M700
    entirely — now earmarked for a 3D-printed NAS mod (its M.2 slot carries real SATA, unlike
    newer Tinys) to finally put the WD80EMAZ to use, not yet built.
  - **Fenrir (Synology RS815)** is the "2" — RAID5 across four 3TB drives (~8TB usable), all
    four bays populated. Not in Ansible's inventory (different platform, managed via its own
    DSM UI/apps).
- [x] **Game-server duty consolidated onto Amaterasu, 2026-09-25.** Palworld moved off Zinogre
      via its existing (separate, not-in-this-repo) Ansible pipeline, just retargeted at
      Amaterasu — world save migrated cleanly, verified healthy post-move. Zinogre's copy is
      stopped, kept as a fallback rather than decommissioned. Also installed **Pelican** (a
      Pterodactyl-successor game-panel) on Amaterasu ahead of any *future* game servers — tested
      against a disposable throwaway instance first and confirmed it covers the gameplay-setting
      depth needed before deciding anything, but Palworld itself stays on the plain Ansible
      pipeline rather than switching. Router port-forward (UDP 8211/27015) repointed to
      Amaterasu's IP for external/friend access.

### Phase 4 — Scale (later)
- [ ] Permanent 2.5G switch (Zyxel XMG1915-10E top candidate, ~$170-190), QSFP uplink to Lycagon
- [x] Configure Jellyfin GPU passthrough for the P620 — done 2026-09-19, see GPU / Hardware
      Pipeline above
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
- [ ] Chibiterasu running Proxmox instead of bare Ubuntu (deferred idea, not decided) — would
      let it host arbitrary VMs, not just the current Docker staging role, and adds real
      snapshot/rollback for testing risky changes. Needs its 32GB RAM upgrade first and more
      design discussion (how it'd actually be used) before committing to anything — flagged for
      later, not in progress.
- [ ] GPU-accelerate Immich's ML container (face recognition, CLIP smart search) with a spare
      **GTX 750 Ti** — CPU-only ONNX inference is fine for steady day-to-day imports, but a GPU
      would matter a lot for bulk operations (a big library backfill, or a full re-scan after a
      model upgrade). The concurrent-session cap that makes Quadro matter for video transcoding
      doesn't apply to CUDA compute, so a GeForce card has no real disadvantage here. Confirmed
      feasible: Amaterasu has two free PCIe slots (P620 occupies the top one), and the 750 Ti
      needs no supplemental power. Maxwell architecture, same driver-support timeline as the
      P620's Pascal (both feature-complete through driver 580, security-only after). Not
      started — a "when you want to" task, no blocker left.
- [ ] **Frigate NVR** (deferred idea, not decided) — centralize security cameras. Amaterasu is
      the likely host, but detection should run on a **Coral TPU** (already planned as a
      purchase), not the shared P620 — Frigate's object detection runs continuously the whole
      time cameras are active, unlike Jellyfin's on-demand transcoding, and would contend for
      the P620's 2GB VRAM if it ran there instead. Recording storage TBD — the two spare 8TB
      drives on hand are now earmarked for the mini-rack backup dock idea above instead (see
      NAS/3-2-1 item), so this would need either a separate drive or to share one of those.
      Camera compatibility not evaluated yet. Not started.
