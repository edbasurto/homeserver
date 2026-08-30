# Homelab Progress Log

Reference: `homelab-baseline-v5.txt` is the authoritative source of truth for
device names, stack names, and conventions. Read it before making changes.

---

## What's Been Built

### Repo Structure
The old per-service `docker/<service>/docker-compose.yml` layout has been fully
replaced with a stack-based Ansible-managed structure:

- Compose files: `docker/stacks/<stack>/compose.<hostname>.yml`
- Config files:  `docker/configs/<service>/...` (synced to host by Ansible)
- Env files:     generated on each host from Ansible Vault vars at deploy time

### Stacks (all in `docker/stacks/`)

| Stack | Host | Services |
|---|---|---|
| tousou-gate | amaterasu | Traefik v3, Authentik + postgres + redis |
| sunrise-mqtt-soup | amaterasu | Home Assistant, Mosquitto |
| hyperdimension-library | amaterasu | Jellyfin, Calibre, Immich, Mealie |
| osaki-ni-cloud | amaterasu | Nextcloud + postgres + redis |
| spicy-queen-ctrl | amaterasu | Homarr, Portainer, WhatUpDocker, Actual Budget |
| neet-game | amaterasu | Minecraft |
| warning-core | amaterasu | node-exporter, cadvisor, dozzle, dashdot (agents only) |
| devs-talk | holo | Semaphore, Forgejo, code-server, Planka, Wiki.js, MeshCentral + shared postgres + mongodb |
| warning-core | holo | Prometheus, Grafana (core) + agents |
| good-day-so-epic | chibiterasu | (sandbox — intentionally empty) |
| warning-core | chibiterasu | node-exporter, cadvisor, dozzle, dashdot (agents only) |

### Ansible Roles
- **initialize** — system packages, pip deps, sudo setup
- **geerlingguy.docker** — Docker CE + Compose v2 plugin
- **container-configs** — syncs config files and generates `.env.<hostname>` files from vault
- **containers** — copies compose files, starts stacks in correct order

### Inventory (`inventory`)
- Group: `[docker-hosts]` — amaterasu, holo (local), chibiterasu
- holo uses `ansible_connection=local` — **playbook must be run from holo** (via Semaphore)
- Non-Docker hosts: `[nas_hosts]` (sif), `[k3s_nodes]` (tsume, zinogre)
- Vagrant testing: use `ansible-playbook -i inventory.vagrant playbook.yml`

### Other
- `.gitignore` covers HA secrets, vault password, DS_Store
- Prometheus config at `docker/configs/prometheus/prometheus.yml` — scrapes all three hosts

---

## What Still Needs to Happen

### Step 1 — Pre-flight (do these before running the playbook)

**1a. Populate Ansible Vault vars** — the playbook will fail at env file generation without these.

```bash
ansible-vault edit host_vars/amaterasu/vault.yml
```
Add:
```yaml
authentik_secret_key: ""       # 50+ char random string
authentik_pg_password: ""
immich_pg_password: ""
nextcloud_pg_password: ""
nextcloud_admin_user: ""
nextcloud_admin_password: ""
# homeassistant_secrets_yaml is optional — only needed if you add real secrets to HA
```

```bash
ansible-vault edit host_vars/holo/vault.yml
```
Add:
```yaml
devs_pg_password: ""
semaphore_admin_password: ""
planka_secret_key: ""          # long random string
```

**1b. Add Discord bot .env contents to the amaterasu vault** — [x] files backed up, now store in vault so Ansible can restore them on rebuild.

```bash
ansible-vault edit host_vars/amaterasu/vault.yml
```
Add:
```yaml
discord_music_bot_env: |
  SPOTIFY_CLIENT_ID=your_value
  SPOTIFY_CLIENT_SECRET=your_value
  DISCORD_TOKEN=your_value

discord_monitor_bot_env: |
  DISCORD_TOKEN=your_value
  ALERT_CHANNEL_ID=your_value
```
Ansible will write these files to the correct paths on amaterasu automatically on every deploy.

---

### Step 2 — Deploy Holo

Holo is the Ansible control plane. It must be set up first.
Holo uses `ansible_connection=local` — the playbook **must be run from holo itself**.

1. SSH into holo: `ssh -i ~/.ssh/holo ookami@192.168.50.125`
2. Clone the repo onto holo (if not already there)
3. Run: `ansible-playbook playbook.yml --limit holo`
4. Once Semaphore is up, all future runs go through it

---

### Step 3 — Validate Against Chibiterasu

Run from holo (or via Semaphore once it's up):
```bash
ansible-playbook playbook.yml --limit chibiterasu
```
This validates warning-core agents and good-day-so-epic deploy without touching production.

---

### Step 4 — Deploy Amaterasu

Run from holo via Semaphore:
```bash
ansible-playbook playbook.yml --limit amaterasu
```

---

### Step 5 — Remaining Phase 1 Items

- [ ] Set up Lycagon with OPNsense (WAN: 1GbE to XB8, LAN: 2.5GbE to switch)
- [ ] Transfer DHCP from ASUS RT-AX88U to Lycagon (same subnet + gateway IP)
- [ ] Install Quadro M2000 in Amaterasu for Jellyfin hardware transcoding
- [ ] Set up remote access to Amaterasu — headless in rack, no GUI currently.
      Decide on approach (Cockpit recommended as simplest) then add to initialize role.

---

### Known Open Items
- [ ] Traefik dashboard is exposed without auth — add Authentik middleware before going live
- M700, 3x NUC, and permanent switch hostnames: **TBD**
- Permanent switch: Zyxel XMG1915-10E (~$170-190) is top candidate
- K3s cluster (Phase 2): M700 control plane + 3x NUC i5-7260U workers

---

## Device Reference

| Hostname | Hardware | Role | IP |
|---|---|---|---|
| Amaterasu | MSI Z590 PRO WiFi | Production Docker host | 192.168.50.180 |
| Holo | Intel NUC7 i5 | Ansible controller + monitoring | 192.168.50.125 |
| Chibiterasu | ThinkCentre M920q | Staging | 192.168.50.170 |
| Lycagon | ASRock Z490M-ITX | OPNsense router (not yet configured) | — |
| Fenrir | Synology RS815 | NAS (DSM) | — |
| Sif | ThinkCentre M910s | Planned TrueNAS NAS | 192.168.50.249 |
