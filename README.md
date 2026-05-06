# nexus-infra-swarm-nomad

[![Packer](https://img.shields.io/badge/Packer-1.11+-blue)](https://www.packer.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.9+-purple)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Blueprint](https://img.shields.io/badge/blueprint-nexus--platform--plan%20v0.1.3-orange)](https://github.com/grezap/nexus-platform-plan)
[![Phase](https://img.shields.io/badge/phase-0.E.4%20closed%20%E2%80%A2%200.E.5%20canon%20batch%20next-brightgreen)](./CHANGELOG.md)

Tier-2 orchestration for the **NexusPlatform 66-VM lab** — a 3+3 Docker Swarm cluster with co-located Nomad servers + Consul servers on the managers and Nomad/Consul clients on the workers, plus Portainer EE deployed as a clustered Swarm service. Sits on top of the [`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) foundation (Vault, AD, gateway).

> **Canon:** This repo implements [Phase 0.E](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) (line 151) of the NexusPlatform blueprint. Read [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan) first.
>
> **New to Docker Swarm / Nomad / Consul / Portainer?** See the [tool stack glossary](https://github.com/grezap/nexus-platform-plan/blob/main/docs/glossary.md#3-container-orchestration) for plain-English definitions of each.
>
> **Current state (Phase 0.E.3.3 ✅ closed; 0.E.4 Portainer EE up next):** 0.E.1 swarm cluster bring-up + 0.E.2 setup (Vault PKI `consul-server` role, `nexus/swarm/consul-gossip-key` KV seed, 6 narrow Vault policies + AppRoles + JSON sidecars on the build host, `nexus-vault-agent.service` systemd unit installed on each of 6 swarm-nodes with `RuntimeDirectory=nexus-vault-agent` for tmpfs reboot survival) + **0.E.2.1 Consul gossip encryption** (Vault Agent renders `/etc/consul.d/10-encrypt.hcl` from KV; rolling consul restart converged the keyring to `[6/6]` on a single key) + **0.E.2.2 Consul TLS** (per-node leaf cert from `pki_int/issue/consul-server` rendered by Vault Agent + post-render bundle split, mutual TLS for internal RPC + Raft, server-only TLS for HTTPS API on 8501, plain HTTP/8500 hard-cut via systemd drop-in `-http-port=-1` CLI override) + **0.E.2.3 Consul ACL** (transition-mode 5-stage bootstrap: drop allow-mode `30-acl.hcl` → sequential rolling restart → bootstrap mgmt token from manager-1 → persist to Vault KV at `nexus/swarm/consul-bootstrap-token` → create 6 per-host policies + tokens via Consul ACL API, persist each to `nexus/swarm/agent-tokens/<host>` → drop Vault Agent template that renders `/etc/consul.d/30-acl-token.hcl` per node with `acl.tokens.agent` only → tighten `default_policy` "allow" → "deny" via in-place sed + sequential rolling restart; `down_policy=extend-cache`, `enable_token_persistence=true`, anonymous HTTPS GET `/v1/agent/self` returns 403 across all 6 nodes) + **0.E.3.1 Nomad TLS** (per-node leaf cert from `pki_int/issue/nomad-server` role rendered by Vault Agent + post-render bundle split, mutual TLS for inter-agent RPC + raft + HTTPS API on port 4646, `verify_server_hostname=true` enforces SAN-pinned identity (`server.global.nomad` for managers / `client.global.nomad` for workers), systemd drop-in switches `nomad agent -config=` from single-file mode to dir mode so 40-tls.hcl is loaded, parallel big-bang restart for cluster reconvergence, workers get explicit `client.servers` list pointing at the 3 manager VMnet10 IPs since Consul HTTP service-discovery is hard-cut) + **0.E.3.2 Nomad ACL** (4-stage choreography: drop `acl { enabled = true }` config in `/etc/nomad.d/50-acl.hcl` on all 6 → parallel big-bang restart of nomad.service → idempotent bootstrap from manager-1, persist mgmt token to Vault KV at `nexus/swarm/nomad-bootstrap-token` → create shared `nomad-agent` policy + 6 per-host operator tokens persisted to `nexus/swarm/nomad-agent-tokens/<host>`. Per-agent tokens are NOT injected into agent config -- Nomad's `acl{}` block doesn't support a `token` field; inter-agent RPC authenticates via the mTLS cert from 0.E.3.1 (cert SAN is the wire-layer identity). Anonymous HTTPS GET `/v1/agent/self` returns 403 across all 6 nodes) + **0.E.3.3a Nomad → Consul HTTPS rewire** (drops Vault Agent template that renders `/etc/nomad.d/42-consul-token.hcl` from `nexus/swarm/agent-tokens/<host>`; drops content-stable `/etc/nomad.d/42-consul.hcl` with `address = "127.0.0.1:8501"` (scheme-less, `ssl = true`, `ca_file`); surgical-removes the legacy `consul { address = "127.0.0.1:8500" }` block from `/etc/nomad.d/nomad.hcl` via `sed` anchored on `^consul {$`; sequential rolling restart of nomad.service; verifies via `/v1/agent/self`'s `config.Consuls[].Addr` = `127.0.0.1:8501` + `EnableSSL=true`) + **0.E.3.3b Nomad-Vault integration** (security-env adds `nomad-jobs` Vault policy + `nomad-cluster` periodic-token role with period=72h + extends 3 manager Vault Agent policies with `auth/token/create/nomad-cluster`; swarm-nomad-side mints one periodic token per manager via vault-1 root token (idempotent skip-if-populated), drops `/etc/nomad.d/60-vault.hcl` declaring `vault { enabled = true; address = "https://192.168.70.121:8200"; ca_file = "/etc/vault-agent/ca-bundle.crt"; create_from_role = "nomad-cluster"; token_file = "/etc/nomad.d/60-vault-token.txt" }`; sequential rolling restart of 3 managers; verifies vault stanza loaded). ~155-check chained smoke gate (0.E.1 + 0.E.2.1 + 0.E.2.2 + 0.E.2.3 + 0.E.3.1 + 0.E.3.2 + 0.E.3.3) ALL GREEN.

## What's in here

| Layer | Tool | Purpose |
|---|---|---|
| **Golden image** | Packer 1.11 + `hashicorp/vmware` | One reproducible `swarm-node` template (Docker + Nomad + Consul pre-installed) |
| **VM provisioning** | Terraform 1.9 + `vmrun.exe` | Six clones in `terraform/envs/swarm-nomad/` |
| **Cluster bring-up** | Terraform `null_resource` + SSH | `docker swarm init`/`join`, `consul agent`, `nomad agent` |
| **Validation** | GitHub Actions | `packer validate`, `terraform validate`, `ansible-lint`, `gitleaks` |

## Canonical inventory (per `vms.yaml` lines 182–191)

| VM | OS | vCPU | RAM | Disk | VMnet11 | VMnet10 | Tier dir |
|---|---|---|---|---|---|---|---|
| swarm-manager-1 | deb13 | 4 | 6 GB* | 80 GB | .111 | .111 | `06-orchestration\swarm-manager-1\` |
| swarm-manager-2 | deb13 | 4 | 6 GB* | 80 GB | .112 | .112 | `06-orchestration\swarm-manager-2\` |
| swarm-manager-3 | deb13 | 4 | 6 GB* | 80 GB | .113 | .113 | `06-orchestration\swarm-manager-3\` |
| swarm-worker-1 | deb13 | 4 | 4 GB* | 80 GB | .131 | .131 | `06-orchestration\swarm-worker-1\` |
| swarm-worker-2 | deb13 | 4 | 4 GB* | 80 GB | .132 | .132 | `06-orchestration\swarm-worker-2\` |
| swarm-worker-3 | deb13 | 4 | 4 GB* | 80 GB | .133 | .133 | `06-orchestration\swarm-worker-3\` |

\* RAM is an approved deviation from canon (`vms.yaml` says 8 GB across the board) — managers run Docker + Consul server + Nomad server + Portainer manager replica, workers run Docker + Consul client + Nomad client. Lab-scale observation will inform the canonization commit at 0.E close-out.

## MAC range

| Range | Use |
|---|---|
| `00:50:56:3F:00:50–52` | Manager primaries (VMnet11) |
| `00:50:56:3F:00:53–55` | Worker primaries (VMnet11) |
| `00:50:56:3F:01:50–55` | Secondaries (VMnet10 cluster backplane) |

dhcp-host reservations on `nexus-gateway` are managed by the foundation env in [`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) (`role-overlay-gateway-swarm-reservations.tf`). They must be in place before `swarm-nomad` env's `terraform apply`.

## Quick start

```pwsh
# On the Windows 11 host 10.0.70.101:
# 0) prerequisites: nexus-infra-vmware foundation + security envs healthy (0.D.5 smoke ALL GREEN)

# 1) ensure dnsmasq dhcp-host reservations are live on nexus-gateway
cd ../nexus-infra-vmware
pwsh -File scripts/foundation.ps1 apply -Vars enable_swarm_dhcp_reservations=true

# 2) build the swarm-node Packer template (one image, all 6 clones reuse it)
cd ../nexus-infra-swarm-nomad
cd packer/swarm-node; packer init .; packer build .

# 3) apply the env -- spawns 6 clones + brings up the cluster
cd ../..
pwsh -File scripts/swarm.ps1 cycle

# 4) verify the exit gate
ssh nexusadmin@192.168.70.111 'docker node ls'        # expect 6 nodes
ssh nexusadmin@192.168.70.111 'nomad server members'  # expect 3 servers
ssh nexusadmin@192.168.70.111 'consul members'        # expect 6 (3 server + 3 client)
```

Full walkthrough: [`docs/handbook.md`](./docs/handbook.md). Master plan exit gate (per `MASTER-PLAN.md` line 151): `docker node ls` shows 6, `nomad server members` shows 3.

## Repo layout

```
packer/
  _shared/ansible/roles/      Vendored from nexus-infra-vmware (nexus_{identity,network,firewall,observability})
  swarm-node/                 Docker CE + Nomad + Consul on deb13 (Phase 0.E.1)

terraform/
  envs/swarm-nomad/           Six clones + role overlays for swarm/consul/nomad bring-up
  modules/vm/                 Vendored from nexus-infra-vmware (single/dual-NIC vmrun-driven module)

scripts/
  swarm.ps1                   apply / destroy / smoke / cycle / plan / validate
  smoke-0.E.1.ps1             Phase 0.E.1 swarm-cluster bring-up checks
  smoke-0.E.2.1.ps1           Chains 0.E.1 + Consul gossip-encrypt checks
  smoke-0.E.2.2.ps1           Chains 0.E.2.1 + Consul TLS checks (HTTPS:8501, HTTP hard-cut, mTLS Raft)
  smoke-0.E.2.3.ps1           Chains 0.E.2.2 + Consul ACL deny-mode + 6 per-host tokens
  smoke-0.E.3.1.ps1           Chains 0.E.2.3 + Nomad TLS (mTLS RPC, HTTPS API on 4646)
  smoke-0.E.3.2.ps1           Chains 0.E.3.1 + Nomad ACL (mgmt token in KV, 6 agent tokens, anon-deny)
  smoke-0.E.3.3.ps1           Chains 0.E.3.2 + Nomad → Consul HTTPS rewire + Nomad-Vault integration
  configure-vm-nic.ps1        Vendored from nexus-infra-vmware

docs/
  handbook.md                 Operator runbook
```

## Sub-phase plan (per [MASTER-PLAN.md](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) Phase 0.E)

| Sub-phase | Scope | Exit gate |
|---|---|---|
| **0.E.1** | Packer template + Terraform env + Swarm cluster bring-up | `docker node ls` = 6 |
| 0.E.2 | Consul cluster (3 servers + 3 clients) | `consul members` = 6, `consul operator raft list-peers` = 3 |
| 0.E.3 | Nomad cluster (3 servers + 3 clients, Consul-integrated) | `nomad server members` = 3, `nomad node status` = 3 ready |
| 0.E.4 | Portainer EE clustered Swarm service | Portainer reachable + 3 replicas |
| 0.E.5 | Vault Agents + PKI for orchestration nodes (Docker/Consul/Nomad TLS) | All daemons running with PKI leaves; agents rendering |

## License

[MIT](./LICENSE) © 2026 Greg Zapantis.
