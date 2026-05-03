# `swarm-node` Packer template — Phase 0.E.1

Debian 13 netinst-based template with **Docker CE**, **HashiCorp Nomad**, and **HashiCorp Consul** binaries pre-installed. Six instances of this template are cloned by [`terraform/envs/swarm-nomad/`](../../terraform/envs/swarm-nomad/) into a 3+3 Swarm cluster (3 managers + 3 workers) on the orchestration tier.

## What's baked

| Component | Where | Purpose |
|---|---|---|
| **Docker CE** | `apt` from `download.docker.com/linux/debian` (channel `stable`) | Container runtime + Swarm orchestration |
| **HashiCorp Nomad** binary | `/usr/local/bin/nomad` (`releases.hashicorp.com`) | Workload scheduler — server on managers, client on workers |
| **HashiCorp Consul** binary | `/usr/local/bin/consul` (`releases.hashicorp.com`) | Service discovery + Raft KV — server on managers, client on workers |
| **`swarm-node-firstboot.service`** | `/usr/local/sbin/swarm-node-firstboot.sh` | Runs once per clone: MAC-OUI NIC discovery → hostname/IP mapping → render Consul + Nomad config in correct mode → enable runtime services |

## Why baked instead of apply-time installed

Same reasoning as [`vault`](../../../nexus-infra-vmware/packer/vault/) (Phase 0.D.1): apply-time installs cost ~3 min × 6 clones = 18 min of network fetch on every cycle, plus exposes apply to repository availability. Baked-template image clones are usable in seconds.

## Build

```pwsh
# On the Windows 11 host 10.0.70.101 with VMware Workstation Pro:
cd packer/swarm-node
packer init .
packer build .
# Output: H:/VMS/NexusPlatform/_templates/swarm-node/swarm-node.vmx
```

## Verify

After build the post-install shell provisioner runs the canonical sanity checks (`docker --version`, `nomad version`, `consul version`, `systemctl is-enabled` on each unit). The actual cluster behaviour is exercised by [`terraform/envs/swarm-nomad/`](../../terraform/envs/swarm-nomad/) at apply-time + [`scripts/smoke-0.E.1.ps1`](../../scripts/smoke-0.E.1.ps1).

## Versions

| Pin | File | Notes |
|---|---|---|
| Debian 13.4.0 netinst | `variables.pkr.hcl` `iso_url` + `iso_checksum` | Same pin as `nexus-infra-vmware/packer/{deb13,vault}` |
| Docker CE channel `stable` | `variables.pkr.hcl` `docker_channel` | Apt-pinned at install time |
| Nomad `1.9.3` | `variables.pkr.hcl` `nomad_version` | Bump at build-time when newer-stable lands |
| Consul `1.20.1` | `variables.pkr.hcl` `consul_version` | Bump at build-time when newer-stable lands |
