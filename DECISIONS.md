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

### P330 Tiny becomes the new Holo — not Chibiterasu, not a K3s control plane
Three options were weighed for this ex-work e-waste box (i7-8700T, 6c/12t,
32GB RAM): replace Holo, replace Chibiterasu (M920q), or hold it for the
Phase 2 K3s control plane ("M700," still unsourced).

Decided: **replace Holo.** Reasoning:
- Role-fit beats raw spec: Holo carries continuous, growing load (Ansible
  control plane, Semaphore CI/CD, Forgejo, Postgres/Mongo, monitoring for the
  whole fleet). Chibiterasu is a *deliberately disposable* pre-prod smoke-test
  box, torn down and rebuilt routinely — the least demanding role in the
  fleet, not the one that deserves the best hardware, even though the M920q is
  plausibly closer in raw spec to the P330 than the NUC is.
- Timing: best time to migrate is now, while devs-talk's data (Forgejo repos,
  Wiki pages, Semaphore project config, Planka boards) is only ~2 weeks old
  and nearly empty — migration cost (pg_dump/restore, mongodump/restore,
  config copy) is close to zero today and only grows the longer Holo runs.
- Domino effect: the freed NUC7i5BNK's CPU (`i5-7260U`) is the *exact* chip
  already planned for "3x NUC i5-7260U workers" in the Phase 2 K3s plan
  (confirmed via Intel's own spec sheet) — nothing sits idle, no new purchase
  needed for one of those three workers.
- The K3s-control-plane option was rejected only because Phase 2 isn't
  current work (Phase 1 isn't done yet) — the P330 would sit mostly idle
  waiting on a phase that hasn't started, while Holo runs thin on hardware
  for its *current*, actively-growing workload in the meantime.

Migration itself has not started as of 2026-09-14 — this is a decision, not
yet an execution.

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
- Ed already had spare Pi 3B+ units — zero additional cost either way.

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
