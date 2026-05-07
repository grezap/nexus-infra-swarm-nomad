# Changelog

All notable changes to `nexus-infra-swarm-nomad` are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

(Empty — next release accumulates here.)

## [0.1.0] — 2026-05-07 — "Phase 0.E orchestration tier — Swarm + Consul + Nomad + Portainer CE"

First tagged release of `nexus-infra-swarm-nomad`. Closes Phase 0.E in
the [NexusPlatform MASTER-PLAN](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md#4-build-phases) (Tier-2 orchestration). All 4 sub-phases
landed:

- **0.E.1** — `swarm-node` Packer template + Terraform clones for the
  6-node 3+3 Docker Swarm (3 managers + 3 workers); dnsmasq dhcp-host
  pinning; cluster bring-up.
- **0.E.2** — Consul harden across 3 sub-sub-phases: gossip encryption
  (0.E.2.1) → mutual TLS for RPC + Raft + HTTPS:8501 hard-cut from
  HTTP:8500 (0.E.2.2) → ACL `default_policy=deny` cluster-wide with
  mgmt token in Vault KV + 6 per-host agent tokens (0.E.2.3).
- **0.E.3** — Nomad harden + Vault integration across 4 sub-sub-phases:
  TLS with `verify_server_hostname=true` (0.E.3.1) → ACL `enabled=true`
  with mgmt token in Vault KV + 6 per-host operator tokens; agents
  authenticate inter-RPC via mTLS cert SAN (0.E.3.2) → Nomad → Consul
  HTTPS rewire (0.E.3.3a) → Nomad-Vault integration via `nomad-cluster`
  periodic-token role period=72h (0.E.3.3b).
- **0.E.4** — Portainer CE clustered Swarm service across 4 sub-sub-
  phases: NFSv4 from gateway for shared `/data` (0.E.4a) → per-manager
  TLS leaf cert from `pki_int/issue/portainer-server` (0.E.4b) →
  dnsmasq `portainer.nexus.lab` multi-A round-robin (0.E.4c) →
  bcrypt admin password sticky seed + per-manager render + `docker
  stack deploy` with manager-pinned server (1 replica) + global agent
  (6 tasks) + canonical nftables firewall overlay opening 9443/8000
  with sequential dockerd restart (0.E.4d).

**Smoke gate**: ~180 chained probes in `scripts/smoke-0.E.4.ps1` (chains
0.E.3.3 → 0.E.3.2 → 0.E.3.1 → 0.E.2.3 → 0.E.2.2 → 0.E.2.1 → 0.E.1).
ALL GREEN at tag time.

**Operator UI**: `https://portainer.nexus.lab:9443`. Admin credentials:
`vault kv get -field=plaintext -mount=nexus portainer/admin-bcrypt`.

**Architectural decisions** memorialized in
[`nexus-platform-plan/docs/adr/`](https://github.com/grezap/nexus-platform-plan/tree/main/docs/adr):
ADR-0016 (Nomad-Vault legacy periodic-token vs. Workload Identity),
ADR-0017 (Portainer CE single-replica + NFS-via-gateway), ADR-0018
(nftables flush-ruleset + Docker iptables-nft conflict resolution).

**Lessons memorialized** in the session-memory feedback library:
`feedback_systemd_runtime_directory_tmpfs.md`,
`feedback_nomad_consul_address_scheme_less.md`,
`feedback_nfsv4_fsid0_pseudo_root.md`,
`feedback_vault_agent_template_hcl_heredoc.md`,
`feedback_nftables_flush_ruleset_wipes_docker.md`, plus per-overlay
trigger-comment iteration trails.

Detailed per-sub-phase change log below.

### Phase 0.E.4 — Portainer CE clustered Swarm service (closed 2026-05-07)

**Sub-phase 0.E.4a — NFS server on gateway + per-manager mount**

**Added (foundation env -- nexus-infra-vmware)**
- `terraform/envs/foundation/role-overlay-gateway-nfs-portainer.tf` — installs `nfs-kernel-server` on nexus-gateway, exports `/srv/nfs/portainer-data` NFSv4-only (`fsid=0` pseudo-root) to manager IPs, patches `/etc/nftables.conf` in-place to allow tcp/2049 from manager IPs (per memory `feedback_nftables_runtime_add_after_drop.md`). v1 → v2 added explicit `mkdir -p /etc/exports.d` (the directory isn't created by the `nfs-kernel-server` package on Debian 13).

**Added (swarm-nomad env)**
- **`terraform/envs/swarm-nomad/role-overlay-portainer-nfs-mount.tf`** — managers-only (3) NFSv4.2 mount of the gateway export at `/var/lib/portainer-data`. Idempotent fstab marker comment + mount-active probe + R/W sanity test. v1 → v2 fixed mount source from `:/srv/nfs/portainer-data` to `:/` (NFSv4 pseudo-root semantics — clients mount the fsid=0 root via `:/`).

**Lesson canonized:** `feedback_nfsv4_fsid0_pseudo_root.md`.

**Sub-phase 0.E.4b — Vault PKI portainer-server role + per-manager TLS render**

**Added (security env -- nexus-infra-vmware)**
- `terraform/envs/security/role-overlay-vault-pki-portainer.tf` (NEW) — creates `pki_int/roles/portainer-server` with `allowed_domains=portainer.nexus.lab,nexus.lab,localhost`, `allow_ip_sans=true`, `server_flag=true`, `client_flag=false` (server-only EKU; the cert is consumed by Portainer's HTTPS listener, no mTLS).
- `role-overlay-vault-agent-swarm-policies.tf` v4 → v5 — manager Vault Agent policies extended with `pki_int/issue/portainer-server` (create+update). Workers don't get this — Portainer Server runs only on managers.

**Added (swarm-nomad env)**
- **`terraform/envs/swarm-nomad/role-overlay-portainer-tls.tf`** — managers-only Vault Agent template renders TLS leaf cert from `pki_int/issue/portainer-server`; post-render command splits bundle into `/etc/portainer/tls/{server.crt, server.key, ca.pem}`. Single shared CN `portainer.nexus.lab` + per-host IP SAN — clients connecting via the DNS name see consistent TLS validation regardless of which manager Swarm has the active replica scheduled on.

**Sub-phase 0.E.4c — dnsmasq portainer.nexus.lab A-record**

**Added (foundation env)**
- `terraform/envs/foundation/role-overlay-gateway-portainer-dns.tf` — drops `/etc/dnsmasq.d/foundation-portainer.conf` with single `host-record=portainer.nexus.lab,192.168.70.111,192.168.70.112,192.168.70.113` line; reloads dnsmasq. Multi-IP A-record gives round-robin behavior across managers; combined with Swarm's routing mesh, any manager IP routes to the active Server replica.

**Sub-phase 0.E.4d — Admin password sticky seed + render + Docker stack deploy**

**Added (security env)**
- `terraform/envs/security/role-overlay-vault-portainer-admin-seed.tf` (NEW) — sticky-seeds `nexus/portainer/admin-bcrypt` with two fields: `bcrypt_hash` (used by Portainer's `--admin-password-file`) + `plaintext` (lab-only operator-readable password). Generated server-side on vault-1 via `openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24` + `python3-bcrypt` (auto-installed if missing). Sticky semantic — never overwrites a populated value.
- `role-overlay-vault-agent-swarm-policies.tf` v5 → v6 — manager policies extended with `read` on `nexus/data/portainer/admin-bcrypt`.

**Added (swarm-nomad env)**
- **`terraform/envs/swarm-nomad/role-overlay-portainer-admin-render.tf`** — managers-only Vault Agent template renders `bcrypt_hash` to `/etc/portainer/admin-password.txt` (mode 0640 root:root, no trailing newline). Render-wait probe checks for bcrypt-shape (`^\$2[aby]\$10\$`).
- **`terraform/envs/swarm-nomad/role-overlay-portainer-stack.tf`** — manager-1 runs `docker stack deploy -c portainer-stack.yml portainer`. Compose v3.8 with two services: `server` (1 replica, `node.role==manager` constraint, ports 9443:9443 + 8000:8000, bind-mounts NFS data + TLS certs + admin-password file) + `agent` (mode global, 1 task per node × 6 nodes, mounts docker.sock + /var/lib/docker/volumes for cluster-wide visibility). Overlay network `agent_network` (attachable) drives `tasks.agent` DNS round-robin.

**`scripts/smoke-0.E.4.ps1`** — chained on `smoke-0.E.3.3.ps1`. ~30 0.E.4-specific probes covering: gateway nfs-kernel-server active, exports listed via `exportfs -v`, per-manager NFS mount via `findmnt`, workers do NOT have the mount, Vault PKI role exists with portainer.nexus.lab in allowed_domains, per-manager TLS files present + CN match + SAN includes manager IP + cert validity > 7d, dnsmasq returns 3 A-records, KV admin-bcrypt seeded, /etc/portainer/admin-password.txt rendered with bcrypt hash, docker stack `portainer` deployed with server 1/1 + agent 6/6, HTTPS GET /api/system/status returns 200 with valid TLS chain.

**`terraform/envs/swarm-nomad/role-overlay-portainer-firewall.tf`** (NEW) — canonicalized firewall overlay. Patches `/etc/nftables.conf` on all 6 swarm-nodes to add `iifname "nic0" ip saddr 192.168.70.0/24 tcp dport { 9443, 8000 } accept` immediately before the canonical `counter drop` line. Sequential per-node application + dockerd restart: `nft -f /etc/nftables.conf` (with `flush ruleset` at top) wipes Docker's iptables-nft rules including DOCKER-INGRESS DNAT, so dockerd must be restarted to rebuild them. Sequential restart preserves Swarm raft quorum (3-of-3 raft tolerates 1 down). Idempotent via marker comment in /etc/nftables.conf.

**`scripts/swarm.ps1`** — Phase ValidateSet extended to `0.E.4`; default Phase = `0.E.4`.

**Cluster credentials post-0.E.4**
- Portainer admin login: username `admin`; plaintext = `vault kv get -field=plaintext -mount=nexus portainer/admin-bcrypt` (from vault-1).
- Portainer UI: `https://portainer.nexus.lab:9443`.
- TLS: 90-day leaf from Vault PKI Intermediate CA; CA chain validates via `~/.nexus/vault-ca-bundle.crt`.

**Cascade budget: 2 cascades** (~50min total)
- Cascade 1: 0.E.4b security apply triggers v4→v5 manager policy bump → swarm_approles re-rotates → 6 swarm_vault_agent + 8 dependent overlays + new portainer_tls (15 add / 14 destroy).
- Cascade 2: 0.E.4d security apply triggers v5→v6 manager policy bump → swarm_approles re-rotates → 6 swarm_vault_agent + 8 dependent overlays + new portainer_admin_render + portainer_stack (17 add / 15 destroy).

The two security-env applies couldn't be folded into one because 0.E.4d's seed (admin-bcrypt) and read capability had to land AFTER 0.E.4b's PKI role was in place + the v5 cascade had finished (0.E.4d's swarm-nomad-side overlays consume `null_resource.portainer_tls.id` as a `depends_on`). One cascade per logical sub-phase is the cleanest available shape.

**Iteration trail (memorialized in trigger comments)**
- `portainer_nfs_mount` v1→v2: NFSv4 client mount source `:/srv/nfs/portainer-data` failed with `mount.nfs4: No such file or directory`. Server's `fsid=0` makes the export the NFSv4 pseudo-root; clients mount via `:/`. Lesson: `feedback_nfsv4_fsid0_pseudo_root.md`.
- `portainer_admin_render` v1→v2: HCL inline-string template body (`contents = "..."`) with leftover backtick-quote escapes from a previous @"..."@ pattern, written via @'...'@ literal here-string. File contained literal backslash-quote where HCL expected just quote. All 3 vault-agents crashlooped with `illegal char`. Switched to HCL heredoc syntax. Lesson: `feedback_vault_agent_template_hcl_heredoc.md`.
- Hot-fix→canonical for nftables: ad-hoc `nft -f` ruleset reload wiped Docker's iptables-nft DOCKER-INGRESS DNAT rules → HTTPS:9443 returned `000`. Required sequential `systemctl restart docker` across all 6 swarm-nodes to rebuild Swarm ingress mesh. Permanent fix landed in `role-overlay-portainer-firewall.tf` which embeds the docker restart in the patch choreography. Lesson: `feedback_nftables_flush_ruleset_wipes_docker.md`.

**Smoke probe iterations**
- `cert valid > 7d` probe: `^OK$` strict-equality regex never matched multi-line output (`openssl ... -checkend` prints "Certificate will not expire" on stdout, then `&& echo OK` adds OK on a new line). Switched to substring match `OK\b`.
- `dig 3 A-records` probe: dnsmasq's `host-record=NAME,IP1,IP2,IP3` returns ONE A-record per query (round-robin across queries), not all three at once. Relaxed to `>=1 A-record in manager IP range`.
- `vault kv get | head -15` probe: 15 lines truncated before reaching the data fields (bcrypt_hash, plaintext are at lines 17+). Bumped to `head -30`.

**Cluster credentials post-0.E.4**
- Portainer admin login: username `admin`; plaintext = `vault kv get -field=plaintext -mount=nexus portainer/admin-bcrypt` (from vault-1).
- Portainer UI: `https://portainer.nexus.lab:9443`.
- TLS: 90-day leaf from Vault PKI Intermediate CA; CA chain validates via `~/.nexus/vault-ca-bundle.crt`.

### Phase 0.E.3.3 — Nomad → Consul HTTPS rewire + Nomad-Vault integration (closed 2026-05-06)

**Sub-phase 0.E.3.3a — Nomad → Consul HTTPS rewire**

**Added**
- **`terraform/envs/swarm-nomad/role-overlay-nomad-consul-rewire.tf`** — 3-stage rollout: (1) parallel drop of Vault Agent template `/etc/vault-agent/42-template-nomad-consul-token.hcl` per-host that fetches `nexus/data/swarm/agent-tokens/<host>` (the Consul agent token from 0.E.2.3, sufficient `service_prefix + node_prefix` read perms) and renders `/etc/nomad.d/42-consul-token.hcl` with `consul { token = "<UUID>" }`; vault-agent restart + render-wait. (2) parallel drop of content-stable `/etc/nomad.d/42-consul.hcl` with `address = "127.0.0.1:8501"` (scheme-less per Nomad's net.SplitHostPort parser), `ssl = true`, `ca_file = "/etc/ssl/certs/consul-ca.pem"`; **surgical-removes the legacy `consul { address = "127.0.0.1:8500" }` block from `/etc/nomad.d/nomad.hcl`** via `sed` anchored on `^consul {$` (NOT the preceding comment, since manager + worker firstboot templates have different comment text), gated on detecting the literal `8500` address. (3) sequential rolling restart of `nomad.service` (managers first); HTTPS:4646 + 200 probe with mgmt-token-auth; final verification via `curl /v1/agent/self` confirming `Consuls[].Addr=127.0.0.1:8501` + `EnableSSL=true` + no residual `:8500` reference.
- **`enable_nomad_consul_rewire`** variable (default true).

**v1 → v2 → v3 → v4 evolution (4 iterations memorialized in trigger comment)**
- v1 → v2: sed anchor moved from `^# Co-located Consul agent on this node$` (worker template comment) to `^consul {$` (the actual code line) — manager template's comment is longer (`...provides service discovery + auto-join`), so v1 silently skipped Stage 2 on managers via the comment-not-found "idempotent" branch, leaving the legacy block intact.
- v2 → v3: dropped `https://` URL prefix from `consul.address` — Nomad uses Go `net.SplitHostPort` which expects bare `host:port`; URL form triggers `Failed to initialize Consul client: too many colons in address` at boot. HTTPS is enabled by sibling `ssl = true`, NOT by scheme.
- v3 → v4: Stage 3 final-verification probe switched from `nomad agent-info | sed -n '/^consul/...'` (which silently matches empty string — agent-info has NO consul section) to `curl /v1/agent/self | grep '"Addr":"127.0.0.1:8501"'` (the JSON API returns `config.Consuls[]` plural).

**Sub-phase 0.E.3.3b — Nomad-Vault integration (managers only)**

**Added (security env)**
- **`nexus-infra-vmware/terraform/envs/security/role-overlay-vault-nomad-jobs-policy.tf`** — creates Vault policy `nomad-jobs` (lab-scale read on `secret/data/*` + `secret/metadata/*` + token self-management; tighten per-job at workload onboarding) + Vault token role `nomad-cluster` (allowed_policies=`nomad-jobs`, period=72h, orphan=false, renewable=true).
- **`enable_nomad_vault_jobs`** + **`vault_nomad_cluster_role_name`** variables in security env (defaults true / `nomad-cluster`).
- **`role-overlay-vault-agent-swarm-policies.tf` v3 → v4** — manager Vault Agent policies (3 of 6) extended with `auth/token/create/nomad-cluster` (update) + `auth/token/roles/nomad-cluster` (read) capabilities. Workers don't get this — the basic Nomad-Vault integration only needs Nomad servers to mint child tokens.

**Added (swarm-nomad env)**
- **`terraform/envs/swarm-nomad/role-overlay-nomad-vault.tf`** — managers-only (3 nodes) 3-stage rollout: (1) sequential per-manager idempotent-skip-if-populated mint of a periodic token via vault-1 root token + `vault token create -role=nomad-cluster`, scp'd to `/etc/nomad.d/60-vault-token.txt` (mode 0640 root:nomad). One-shot terraform-side write — Nomad takes over renewal post-startup; we never overwrite a populated token (would orphan Nomad's accounting). (2) parallel drop of `/etc/nomad.d/60-vault.hcl` declaring `vault { enabled = true; address = "https://192.168.70.121:8200"; ca_file = "/etc/vault-agent/ca-bundle.crt"; create_from_role = "nomad-cluster"; token_file = "/etc/nomad.d/60-vault-token.txt"; task_token_ttl = "1h" }` (uses VMnet11 IP directly because `vault-1.nexus.lab` doesn't resolve from cluster nodes — only the short hostname `vault-1` does). (3) sequential rolling restart of 3 managers; mgmt-token-authenticated 200 probe + `nomad agent-info` reports the configured vault address.
- **`enable_nomad_vault_integration`** + **`vault_addr`** variables (defaults true / `https://192.168.70.121:8200`).

**Workers remain on `41-client-servers.hcl` (hardcoded manager IPs from 0.E.3.1)**
Removing the hardcoded list requires extending the per-host Consul agent policies with `service "nomad" { policy = "write" }` + `service "nomad-client" { policy = "write" }` so Nomad agents can self-register in Consul as discoverable services. That's a security-env policy change which triggers the AppRole-secret-id-rotation cascade through 6+ swarm-nomad overlays — deferred to 0.E.4 or later.

**`scripts/smoke-0.E.3.3.ps1`** — chained on `smoke-0.E.3.2.ps1`. ~50 0.E.3.3-specific probes covering: per-node `42-consul.hcl` content (HTTPS:8501 address scheme-less + ssl=true + ca_file), per-node `42-consul-token.hcl` renders a UUID-shaped token, vault-agent template file present, `nomad.hcl` does NOT contain legacy `:8500`, Nomad's `/v1/agent/self` reports `Consuls[].Addr=127.0.0.1:8501` + `EnableSSL=true`, cluster shape unchanged (3 servers + 3 clients ready), Vault-side `nomad-jobs` policy + `nomad-cluster` role with period 72h, manager-only `60-vault.hcl` + `60-vault-token.txt` files, workers do NOT have those files, `nomad agent-info` reports configured vault address on each manager.

**Pre-flight regression recovery (this same session)**
- Vault HA cluster (vault-1/2/3) was crash-looping post-host-reboot because vault-transit (192.168.70.124) was sealed; HA's transit auto-unseal couldn't proceed. Recovery: 3 of 5 Shamir keys via `vault operator unseal` on vault-transit + `systemctl reset-failed && start vault.service` on vault-1/2/3. Cluster auto-unsealed within 8s.
- All 6 swarm-node `nexus-vault-agent.service` units found at restart-counter ~1219 due to `/var/run/nexus-vault-agent` being wiped by the host reboot (`/var/run` is tmpfs). Manual `mkdir -p` recovered immediately. Permanent fix landed in `role-overlay-swarm-vault-agents.tf` rendered systemd unit body: added `RuntimeDirectory=nexus-vault-agent` + `LogsDirectory=nexus-vault-agent` (canonical replacement for the install-time `mkdir -p /var/run/...` that was a one-shot). Fix activates on the 0.E.3.3b cascade re-deploy of the 6 vault-agents.

**Cluster credentials post-0.E.3.3**
- Consul agent token (per-host, used by Nomad for HTTPS:8501): `nexus/swarm/agent-tokens/<host>.agent_token` (unchanged from 0.E.2.3).
- Nomad-Vault periodic bootstrap token (per-manager, used by Nomad's vault{} stanza): `/etc/nomad.d/60-vault-token.txt` on each manager (NOT in Vault KV — Nomad maintains renewal post-startup).
- Operator workflow unchanged.

### Phase 0.E.3.2 — Nomad ACL system (closed 2026-05-06)

**Added**
- **`terraform/envs/swarm-nomad/role-overlay-nomad-acl.tf`** — 4-stage rollout: (1) parallel drop of `/etc/nomad.d/50-acl.hcl` with `acl { enabled = true }` on all 6 nodes; (2) parallel big-bang restart of `nomad.service` (TLS-style; ACL state is replicated via raft and the cutover from "no enforcement" to "deny" must be atomic; sequential would leave nodes in mixed state); (3) idempotent bootstrap from manager-1 via `nomad acl bootstrap -json`, mgmt token persisted to Vault KV at `nexus/swarm/nomad-bootstrap-token` via vault-1 ssh + root token; (4) shared `nomad-agent` policy created (`agent { policy = "write" }` + `node { policy = "write" }` + `namespace "default" { policy = "read" }` -- single shared policy because Nomad's `node {}` block doesn't scope per-host like Consul's), then parallel 6-way per-host token creation, each persisted to `nexus/swarm/nomad-agent-tokens/<host>`.
- **`scripts/smoke-0.E.3.2.ps1`** — chained on `smoke-0.E.3.1.ps1`. ~30 ACL-specific probes covering KV state (mgmt token + 6 agent tokens), per-node config files (`50-acl.hcl` enabled=true; defensively asserts the absence of `50-acl-token.hcl` and `50-template-nomad-acl.hcl` to catch v1 leftovers), Nomad ACL state (bootstrap one-shot consumed, `nomad-agent` policy present, ≥7 tokens), cluster shape under deny mode, anonymous HTTPS GET `/v1/agent/self` returns 403 on every node.
- **`enable_nomad_acl`** variable in `terraform/envs/swarm-nomad/variables.tf` (default true).
- **`scripts/swarm.ps1`** Phase ValidateSet extended to `0.E.3.2`; default Phase = `0.E.3.2`.
- **`smoke-0.E.1.ps1`** + **`smoke-0.E.3.1.ps1`** Nomad probes made ACL-aware (auto-resolve mgmt token from Vault KV; fall back to tokenless when KV is empty / pre-0.E.3.2 baseline).

**v1 → v2: removed Stage 4b (Vault Agent template) + Stage 5 (rolling restart)**
- v1 dropped a Vault Agent template that rendered `/etc/nomad.d/50-acl-token.hcl` with `acl { token = "<UUID>" }`. Crashed all 6 nomad services with `acl unexpected keys token` -- **Nomad's `acl{}` config block does NOT support a `token` field**; the only supported keys are `enabled`, `token_ttl`, `policy_ttl`, `role_ttl`, `replication_token`. Per-agent tokens via config are not Nomad's model: inter-agent RPC authenticates via the mTLS X509 cert from 0.E.3.1 (the cert SAN `server.global.nomad`/`client.global.nomad` IS the wire-layer identity). The 6 KV-persisted tokens stay as ready-to-use operator tokens (one per host for rotation isolation) but are not consumed by the agents themselves. v2 of the overlay drops the bad template entirely + skips the rolling restart.
- v1 left the bad template on disk after the apply errored mid-Stage 5; manual cleanup removed `/etc/vault-agent/50-template-nomad-acl.hcl` from all 6 nodes so Vault Agent doesn't re-render the bad file on its next restart.

**Cluster credentials post-0.E.3.2**
- Nomad mgmt token: `vault kv get -field=management_token -mount=nexus swarm/nomad-bootstrap-token` from vault-1.
- Per-host operator tokens: `nexus/swarm/nomad-agent-tokens/<host>.agent_token`.
- Operator workflow: `NOMAD_ADDR=https://localhost:4646 NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem NOMAD_TOKEN=<token>`. Without `NOMAD_TOKEN`, anonymous calls are denied.

### Phase 0.E.3.1 — Nomad TLS (closed 2026-05-06)

**Added**
- **`terraform/envs/swarm-nomad/role-overlay-nomad-tls.tf`** — 3-stage rollout (mirrors the consul-tls overlay shape): (1) parallel per-host cert render via Vault Agent template `/etc/vault-agent/40-template-nomad-tls.hcl` calling `pkiCert "pki_int/issue/nomad-server"` with role-specific SANs (`server.global.nomad` on managers, `client.global.nomad` on workers — required for `verify_server_hostname=true`); split-script writes per-file `server.crt`/`server.key`/`ca.pem` + an operator-readable `/etc/ssl/certs/nomad-ca.pem` copy. (2) parallel config drop: `/etc/nomad.d/40-tls.hcl` (tls{} stanza + http=true + rpc=true + verify_server_hostname=true), `/etc/profile.d/nomad-tls.sh` (NOMAD_ADDR + NOMAD_CACERT operator env vars), workers-only `/etc/nomad.d/41-client-servers.hcl` (explicit 3-manager VMnet10 IP list — Consul service-discovery is hard-cut since 0.E.2.2), systemd drop-in `/etc/systemd/system/nomad.service.d/config-dir-override.conf` (rewrites `ExecStart` from `-config=/etc/nomad.d/nomad.hcl` to `-config=/etc/nomad.d/` so the new files are loaded). (3) parallel big-bang restart of `nomad.service` (sequential isolates the first node — peers reject TLS, leader election stalls).
- **`scripts/smoke-0.E.3.1.ps1`** — chained on `smoke-0.E.2.3.ps1`. ~30 Nomad-TLS-specific probes covering per-node cert files, role-specific SAN validation, cert TTL > 7d, `40-tls.hcl` content checks, HTTPS:4646 + chain validation against the Vault PKI bundle from the build host, cluster shape under HTTPS (3 alive servers + 3 ready clients), plain HTTP:4646 rejected (TLS enforced).
- **`enable_nomad_tls`** + **`vault_pki_nomad_role_name`** variables in `terraform/envs/swarm-nomad/variables.tf` (defaults true / `nomad-server`).
- **`scripts/swarm.ps1`** Phase ValidateSet extended to `0.E.3.1`; default Phase = `0.E.3.1`.
- **`smoke-0.E.1.ps1`** Nomad probes made TLS-aware (NOMAD_ADDR + NOMAD_CACERT inline). No token yet (Nomad ACLs land in 0.E.3.2).

**Cross-repo (`nexus-infra-vmware/security` env)**
- New **`role-overlay-vault-pki-nomad.tf`** — `pki_int/roles/nomad-server` PKI role with allowed_domains covering all 6 hostnames + `server.global.nomad` + `client.global.nomad` + standard variants; 90d leaf TTL; server+client EKU.
- **`role-overlay-vault-agent-swarm-policies.tf`** v3 — extends the 6 swarm Vault Agent policies with `pki_int/issue/nomad-server` (all 6) + `nexus/data/swarm/nomad-bootstrap-token` (managers RW, workers no access) + `nexus/data/swarm/nomad-agent-tokens/<host>` (per-host R) — last two are placeholders for 0.E.3.2 ACL.
- **`role-overlay-vault-swarm-secrets-seed.tf`** v2 — adds sticky placeholder at `nexus/swarm/nomad-bootstrap-token` (`management_token=""`, `status="not-bootstrapped"`).

**Why parallel big-bang for Stage 3 (vs sequential as 0.E.2.3 ACL did)**
- Same logic as 0.E.2.2 Consul TLS: with `verify_server_hostname=true` + `tls.rpc=true`, Nomad's RPC layer rejects plain peers. Sequential rolling leaves the first-restarted node TLS-only while peers still speak plain RPC; raft can't elect (`No cluster leader`), per-node 90s probe deadline fires before the cluster ever converges. Parallel flips all 6 within seconds; raft re-elects within ~10-30s of the last node. (Confirmed empirically — v3 of the overlay; v1-v2 had different earlier issues.)

**Why workers need an explicit `client.servers` list**
- Workers' Nomad `client` config relies on `consul { address = "127.0.0.1:8500" }` for server discovery, but plain HTTP/8500 was hard-cut in 0.E.2.2. Pre-0.E.3.1 the cluster was healthy because workers had cached server addresses in `/opt/nomad/data`; the Stage 3 restart invalidated those caches AND forced TLS, leaving workers with no path to the servers. Hardcoding `client.servers = ["192.168.10.111:4647", ".112:4647", ".113:4647"]` in `41-client-servers.hcl` breaks the discovery dependency. 0.E.3.3 will rewire the consul stanza to use HTTPS:8501 with an ACL token.

**Cascade impact note (apply v1)**
- Applying the swarm-nomad env after the security env regenerated 6 swarm AppRole secret-id sidecars triggered a `creds_file_hash` cascade: terraform recreated all 6 `swarm_vault_agent` resources + the 3 dependent consul_* overlays (`consul_gossip_encrypt`, `consul_tls`, `consul_acl`) before reaching `nomad_tls`. Each was idempotent end-to-end (mgmt tokens + agent tokens + KV state all reused via Stage 3 idempotency-read), so the final cluster state is identical to pre-cascade — but the cluster transitioned through allow-mode ACL during the consul_acl re-create. Total apply window for the cascaded path: ~25 min vs ~5 min if only nomad_tls were planned.

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
