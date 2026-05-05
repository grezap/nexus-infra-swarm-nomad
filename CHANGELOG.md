# Changelog

All notable changes to `nexus-infra-swarm-nomad` are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Phase 0.E.2.3 — Consul ACL system (closed 2026-05-05)

**Added**
- **`terraform/envs/swarm-nomad/role-overlay-consul-acl.tf`** — five-stage transition-mode ACL bootstrap: (1) drop `/etc/consul.d/30-acl.hcl` in allow-mode on all 6 nodes (parallel); (2) sequential rolling restart of `consul.service` (managers first), cluster reconverges with ACL system enabled but `default_policy="allow"` so anonymous calls still succeed; (3) idempotent bootstrap from manager-1 (forwards to leader internally), management token persisted to Vault KV at `nexus/swarm/consul-bootstrap-token` via `vault kv put` on vault-1 with the build-host root token; (4) parallel 6-way fan-out: per-host `agent-<host>` policy (`node "<host>" { policy = "write" }` + `agent "<host>" { policy = "write" }` + `service_prefix "" { policy = "read" }` + `node_prefix "" { policy = "read" }`) + per-host token created via `consul acl token create`, SecretID written to `nexus/swarm/agent-tokens/<host>`; (4b) drop `/etc/vault-agent/30-template-acl.hcl` on each node, restart `nexus-vault-agent.service`, wait for `/etc/consul.d/30-acl-token.hcl` to render with `acl.tokens.{agent,default}` non-empty; (5) sequential rolling restart with in-place sed flipping `default_policy` "allow" → "deny", per-node 120s settle window with mgmt-token authenticated probe of `https://127.0.0.1:8501/v1/status/leader`.
- **`scripts/smoke-0.E.2.3.ps1`** — chained on `smoke-0.E.2.2.ps1`. ~25 ACL-specific probes covering KV state (mgmt token + 6 agent tokens), per-node config files (`30-acl.hcl` deny-mode, `30-acl-token.hcl` rendered, `30-template-acl.hcl` registered), Consul ACL state (`acl_default_policy=deny`, bootstrap one-shot consumed, 6 `agent-*` policies, ≥7 tokens), cluster shape under deny-mode (6 alive, 3 voter peers, 1 leader), negative checks (anonymous `consul members` denied, anonymous HTTPS GET returns 403).
- **`enable_consul_acl`** + **`vault_1_ip`** + **`vault_init_keys_file`** variables in `terraform/envs/swarm-nomad/variables.tf` (steady-state defaults per `feedback_terraform_partial_apply_destroys_resources.md`).
- **`scripts/swarm.ps1`** Phase-validate set extended to `0.E.2.3`; default `Phase = '0.E.2.3'`.

**Why transition-mode (Pattern A) over single-pass deny (Pattern B)**
- ACL bootstrap requires `acl.enabled=true` cluster-wide (Raft-replicated state). With `default_policy=deny` from the start, agents lock out before they have tokens — registration + health checks fail until each agent reads its token. Pattern A keeps the cluster healthy through bootstrap so any agent-token issuance failure is isolated to that one host instead of dropping the whole cluster into deny-without-tokens. Stage 4 can be retried freely without touching consul state. The extra rolling restart (~3 min) is cheap vs. the blast radius of Pattern B's race.

**Idempotency**
- Stage 1 file write is content-stable. Stage 2 restart on already-restarted node is a no-op. Stage 3 reads existing `management_token` from KV → skip bootstrap (handles the "ACL bootstrap no longer allowed" recovery case explicitly: aborts loudly with manual remediation instructions instead of leaving the cluster mid-state). Stage 4 skips per-host create on KV `agent_token` presence; policy create returns existing record if name collides. Stage 5 sed is idempotent (no-op when already deny). Re-apply after success = pure no-op.

**Cross-repo coupling**
- The 6 Vault Agent policies created by `nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-swarm-policies.tf` already grant the right capabilities (read on `nexus/data/swarm/agent-tokens/<host>` for all 6, read+create+update on `nexus/data/swarm/consul-bootstrap-token` for the 3 managers). The placeholder seed at `nexus/swarm/consul-bootstrap-token` (`management_token=""`, `status="not-bootstrapped"`) is owned by `role-overlay-vault-swarm-secrets-seed.tf` in the security env. The 0.E.2.3 overlay creates the `nexus/swarm/agent-tokens/<host>` paths fresh.

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
