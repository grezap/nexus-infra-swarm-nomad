# Changelog

All notable changes to `nexus-infra-swarm-nomad` are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Phase 0.E.1 — Swarm cluster bring-up (in progress)

**Added**
- Repo scaffold: `LICENSE` (MIT), `.gitignore`, `.gitleaks.toml`, `ansible.cfg`, GitHub Actions CI matrix.
- **Packer template `swarm-node`** (`packer/swarm-node/`) — Debian 13 base + Docker CE + Nomad + Consul binaries pre-installed at template-build time. `swarm-node-firstboot.sh` runs once per clone: discovers NICs by MAC OUI byte 5 (`:00:` primary VMnet11, `:01:` secondary VMnet10), maps `192.168.70.111-113` → `swarm-manager-N` and `.131-.133` → `swarm-worker-N`, sets hostname + `/etc/hosts`, configures VMnet10 backplane, renders Consul + Nomad config in server-vs-client mode by hostname role.
- **Vendored shared roles** — `packer/_shared/ansible/roles/nexus_{identity,network,firewall,observability}` copied verbatim from `nexus-infra-vmware` (commit `9c7da9a`) for symmetry with the existing template family.
- **Vendored `terraform/modules/vm/`** + **`scripts/configure-vm-nic.ps1`** — same source.
- **Terraform env `envs/swarm-nomad/`** — six `module "swarm_..."` blocks (3 managers + 3 workers), all gated by `var.enable_<vm> ? 1 : 0`. Default MACs `00:50:56:3F:00:50-55` primary + `:01:50-55` secondary, all per `vms.yaml` lines 182–191.
- **`role-overlay-swarm-init.tf`** — after clones land, SSH-driven bring-up: `docker swarm init` on `swarm-manager-1`, `docker swarm join --token <manager>` on `swarm-manager-2/3`, `docker swarm join --token <worker>` on `swarm-worker-1/2/3`. Idempotent via `docker info | grep "Swarm: active"` probe. Token persistence to Vault KV deferred to 0.E.5.
- **`scripts/swarm.ps1`** + **`scripts/smoke-0.E.1.ps1`** — pwsh-native operator wrappers (matches `foundation.ps1` / `security.ps1` shape from `nexus-infra-vmware`).
- **`docs/handbook.md`** — operator runbook skeleton with §0 prerequisites + §1 Phase 0.E.1 walkthrough.

**Cross-repo**
- `nexus-infra-vmware` foundation env gains `role-overlay-gateway-swarm-reservations.tf` — adds dhcp-host pins on `nexus-gateway` for the swarm cluster's six MACs (default `var.enable_swarm_dhcp_reservations = true` per memory `feedback_terraform_partial_apply_destroys_resources.md`).

**Notes**
- RAM deviation from canon: managers 6 GB (canon 8 GB), workers 4 GB (canon 8 GB). Will be ratified in `vms.yaml` at 0.E close-out.
- Vault Agents on swarm nodes deferred to **0.E.5** — not required for the 0.E.1 exit gate (`docker node ls` = 6).
