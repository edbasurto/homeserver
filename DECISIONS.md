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
