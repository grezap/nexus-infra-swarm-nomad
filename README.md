# nexus-infra-swarm-nomad

[![Packer](https://img.shields.io/badge/Packer-1.11+-blue)](https://www.packer.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.9+-purple)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Blueprint](https://img.shields.io/badge/blueprint-nexus--platform--plan%20v0.1.3-orange)](https://github.com/grezap/nexus-platform-plan)
[![Phase](https://img.shields.io/badge/phase-0.E.1%20in%20progress-yellow)](./CHANGELOG.md)

Tier-2 orchestration for the **NexusPlatform 66-VM lab** — a 3+3 Docker Swarm cluster with co-located Nomad servers + Consul servers on the managers and Nomad/Consul clients on the workers, plus Portainer EE deployed as a clustered Swarm service. Sits on top of the [`nexus-infra-vmware`](https://github.com/grezap/nexus-infra-vmware) foundation (Vault, AD, gateway).

> **Canon:** This repo implements [Phase 0.E](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) (line 151) of the NexusPlatform blueprint. Read [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan) first.
>
> **Current state (Phase 0.E.1 in progress):** `swarm-node` Packer template (Docker CE + Nomad + Consul baked, firstboot script renames hostname/NICs from MAC, renders per-role config) · `swarm-nomad` env composing six clones (3 managers + 3 workers per [`vms.yaml`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/vms.yaml) lines 182–191) · `role-overlay-swarm-init.tf` brings up the cluster after clones land (init mgr-1, join mgr-2/3 + wrk-1/2/3). Packer template build + first cycle apply pending operator-driven run.

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
  smoke-0.E.1.ps1             Per-phase chained smoke gate
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
