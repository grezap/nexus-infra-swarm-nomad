# nexus-infra-swarm-nomad — Operator Handbook

Operator runbook for Phase 0.E (Tier-2 orchestration). Mirrors the structure of [`nexus-infra-vmware/docs/handbook.md`](https://github.com/grezap/nexus-infra-vmware/blob/main/docs/handbook.md).

## §0 Prerequisites

- **Build host:** Windows 11 Pro at `10.0.70.101` with VMware Workstation Pro, Packer 1.11+, Terraform 1.9+, OpenSSH client, ssh-agent loaded with the lab key (zero passphrase).
- **Foundation tier healthy:** `nexus-infra-vmware` Phase 0.D fully closed (chained smoke gate ALL GREEN). `nexus-gateway`, `dc-nexus`, `nexus-jumpbox`, `vault-1/2/3`, `vault-transit` running.
- **dnsmasq dhcp-host reservations active for the swarm tier:** managed by `nexus-infra-vmware/terraform/envs/foundation/role-overlay-gateway-swarm-reservations.tf` (default `enable_swarm_dhcp_reservations = true`). Verify on the gateway:

  ```pwsh
  ssh nexusadmin@192.168.70.1 'cat /etc/dnsmasq.d/foundation-swarm-reservations.conf'
  # Expect 6 dhcp-host lines for swarm-manager-1/2/3 + swarm-worker-1/2/3
  ```

  If absent, run `pwsh -File ../nexus-infra-vmware/scripts/foundation.ps1 apply` from the parent repo first.

## §1 Phase 0.E.1 — 3+3 Swarm cluster bring-up

### 1.1 Build the `swarm-node` Packer template

One template, six clones reuse it. ~12-15 min on the build host.

```pwsh
cd packer/swarm-node
packer init .
packer build .
# Output: H:\VMS\NexusPlatform\_templates\swarm-node\swarm-node.vmx
```

The Packer build's post-install shell provisioner runs the canonical sanity checks (`docker --version`, `nomad version`, `consul version`, `systemctl is-enabled` on each unit). The actual cluster behaviour is exercised at apply-time + by the smoke gate.

### 1.2 Apply the env

```pwsh
cd ..\..   # back to repo root
pwsh -File scripts\swarm.ps1 apply
```

Apply flow:
1. Six `vmrun clone` calls (one per VM, parallelizable but Terraform serializes by default).
2. `configure-vm-nic.ps1` writes `ethernet0` (VMnet11) + `ethernet1` (VMnet10) for each clone.
3. `vmrun start ... nogui` powers each on.
4. `swarm-node-firstboot.service` runs once per clone:
   - MAC OUI byte-5 NIC discovery (`:00:` primary, `:01:` secondary)
   - VMnet11 IP -> hostname mapping (`.111-.113` -> `swarm-manager-N`, `.131-.133` -> `swarm-worker-N`)
   - `/etc/hosts` `127.0.1.1` write (per memory `feedback_smoke_gate_probe_robustness.md`)
   - VMnet10 backplane static IP via `20-nic1.{link,network}`
   - `10-nic0.link` rewritten MAC-match (per memory `feedback_systemd_link_precedence_multi_nic.md`)
   - Render `consul.hcl` from `consul-{server,client}.hcl.tpl` based on hostname role
   - Render `nomad.hcl` from `nomad-{server,client}.hcl.tpl`
   - `systemctl enable --now docker.service consul.service nomad.service`
5. `role-overlay-swarm-init.tf`'s `swarm_ready_probe` waits for SSH + `docker.service` on all 6.
6. `role-overlay-swarm-init.tf`'s `swarm_init_and_join` runs:
   - `docker swarm init --advertise-addr 192.168.10.111` on `swarm-manager-1`
   - Captures manager + worker join tokens
   - `docker swarm join --advertise-addr <self-vmnet10> --token <manager-T> 192.168.10.111:2377` on mgr-2/3
   - `docker swarm join --advertise-addr <self-vmnet10> --token <worker-T>  192.168.10.111:2377` on wrk-1/2/3
7. Final assertion: `docker node ls --format '{{.ID}}' | wc -l` returns `6`.

Total wall-clock for a fresh apply (post-Packer-build): ~10-15 min.

### 1.3 Verify the exit gate

```pwsh
pwsh -File scripts\swarm.ps1 smoke
# Expect: ALL 0.E.1 SMOKE CHECKS PASSED
```

Or directly:

```pwsh
ssh nexusadmin@192.168.70.111 'docker node ls'         # 6 nodes
ssh nexusadmin@192.168.70.111 'nomad server members'   # 3 servers
ssh nexusadmin@192.168.70.111 'consul members'         # 6 (3 server + 3 client)
```

### 1.4 Iterating

Selective ops (per memory `feedback_selective_provisioning.md`) — every VM and the cluster bring-up are toggleable:

```pwsh
# Bring up only the 3 managers (skip workers + cluster init)
pwsh -File scripts\swarm.ps1 apply -Vars `
    enable_swarm_worker_1=false, `
    enable_swarm_worker_2=false, `
    enable_swarm_worker_3=false, `
    enable_swarm_init=false

# Iterate on the cluster bring-up alone (assumes clones exist)
pwsh -File scripts\swarm.ps1 apply -Vars enable_swarm_init=true
```

> **Watch out:** Per memory `feedback_terraform_partial_apply_destroys_resources.md`, every `-Vars` invocation is the FULL override set for that apply; vars not passed default back. The defaults reflect the steady state (everything enabled), so omitting `-Vars` is the safe operator path.

### 1.5 Tear down

```pwsh
pwsh -File scripts\swarm.ps1 destroy
```

Destroy flow:
1. `role-overlay-swarm-init.tf`'s destroy provisioner runs `docker swarm leave --force` on every node (best-effort, idempotent).
2. Each `module.swarm_*`'s destroy provisioner runs `vmrun stop` + `vmrun deleteVM` + removes the per-VM directory.

Gateway dhcp-host reservations stay live (they belong to foundation env). To drop them, run `nexus-infra-vmware`'s foundation env with `-Vars enable_swarm_dhcp_reservations=false`.

## §2 Forward direction

| Sub-phase | Scope | Status |
|---|---|---|
| 0.E.1 | Swarm cluster bring-up | 🟡 in progress (this document covers it) |
| 0.E.2 | Consul harden (TLS, ACLs, gossip encryption) | ⏭ planned |
| 0.E.3 | Nomad harden (ACLs, TLS, Vault token integration) | ⏭ planned |
| 0.E.4 | Portainer EE clustered Swarm service | ⏭ planned |
| 0.E.5 | Vault Agents on every node + PKI leaves | ⏭ planned |

Exit gate for the whole phase (per `MASTER-PLAN.md` line 151): `docker node ls` shows 6, `nomad server members` shows 3.
