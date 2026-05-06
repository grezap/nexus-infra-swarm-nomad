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

## §2 Phase status

| Sub-phase | Scope | Status |
|---|---|---|
| 0.E.1 | Swarm cluster bring-up | ✅ closed |
| 0.E.2 | Consul harden (gossip encrypt + TLS + ACL deny-mode) | ✅ closed |
| 0.E.3 | Nomad harden (TLS + ACL + → Consul HTTPS + Vault integration) | ✅ closed |
| 0.E.4 | Portainer CE clustered Swarm service | ✅ closed |
| 0.E.5 | Close-out canon batch (MASTER-PLAN + ADRs + vms.yaml + glossary) | 🟡 next |

Exit gate cumulative: `docker node ls` = 6, `nomad server members` = 3, `consul members` = 6, Portainer UI reachable at `https://portainer.nexus.lab:9443` with CA-validated TLS. ~180-check chained smoke gate (`scripts/smoke-0.E.4.ps1`) ALL GREEN.

## §3 Operator runbooks

### 3.1 Retrieving the Portainer admin password

Generated at 0.E.4d apply time as a 24-char alphanumeric plaintext + bcrypt hash, sticky-seeded in Vault KV. Sticky semantic: re-applies preserve, never overwrite — operator can rotate by `vault kv put` directly.

```pwsh
# From the build host -- root-token to vault-1:
$rootToken = (Get-Content $HOME\.nexus\vault-init.json | ConvertFrom-Json).root_token
ssh nexusadmin@192.168.70.121 "VAULT_TOKEN='$rootToken' VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault kv get -mount=nexus portainer/admin-bcrypt"
```

UI: `https://portainer.nexus.lab:9443`. Login user: `admin`.

To rotate the password manually (lab-only — production would generate via Vault's password-policy + audit log):

```bash
# On vault-1, after `vault login` with root token:
NEW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
NEW_BCRYPT=$(python3 -c "import bcrypt, sys; sys.stdout.write(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=10)).decode())" "$NEW")
vault kv put -mount=nexus portainer/admin-bcrypt bcrypt_hash="$NEW_BCRYPT" plaintext="$NEW" status="rotated" rotated_at="$(date -u +%FT%TZ)"
# Vault Agent on each manager re-renders /etc/portainer/admin-password.txt within ~30s.
# Restart the Portainer Server container so it re-reads the file:
ssh nexusadmin@192.168.70.111 'sudo docker service update --force portainer_server'
```

### 3.2 Vault HA reboot recovery (Shamir auto-unseal cascade)

The 3-node Vault HA cluster (vault-1/2/3) auto-unseals via the `nexus-cluster-unseal` transit key on a single-node `vault-transit` companion (192.168.70.124). vault-transit itself uses Shamir (3-of-5). On host reboot vault-transit comes up sealed, so the HA cluster can't auto-unseal and crashloops with `seal wrapper unreachable`.

Recovery (~2 min):

```pwsh
# 1. Unseal vault-transit with 3 of 5 Shamir keys.
$j = Get-Content $HOME\.nexus\vault-transit-init.json | ConvertFrom-Json
foreach ($k in $j.unseal_keys_b64[0..2]) {
  ssh nexusadmin@192.168.70.124 "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault operator unseal '$k'"
}

# 2. Reset systemd failure on HA nodes + restart in parallel.
@('192.168.70.121','192.168.70.122','192.168.70.123') | ForEach-Object -ThrottleLimit 3 -Parallel {
  ssh nexusadmin@$_ "sudo systemctl reset-failed vault.service; sudo systemctl start vault.service"
}

# 3. After ~8s, verify via `vault status` on each HA node.
foreach ($ip in @('192.168.70.121','192.168.70.122','192.168.70.123')) {
  Write-Host "=== $ip ==="
  ssh nexusadmin@$ip "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status 2>&1 | grep -E 'Sealed|HA Mode|Active Node'"
}
```

After Vault HA recovers, Vault Agent on swarm-nodes might still be crashlooping if `/var/run/nexus-vault-agent/` was wiped (tmpfs gets cleared on reboot). The systemd unit rendered by `role-overlay-swarm-vault-agents.tf` v3+ includes `RuntimeDirectory=nexus-vault-agent` which auto-recreates the dir on every service start, so this only affects pre-v3 deployments. Manual fix:

```pwsh
@('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133') | ForEach-Object -ThrottleLimit 6 -Parallel {
  ssh nexusadmin@$_ "sudo mkdir -p /var/run/nexus-vault-agent && sudo systemctl reset-failed nexus-vault-agent.service && sudo systemctl restart nexus-vault-agent.service"
}
```

### 3.3 NFS troubleshooting (Portainer state)

Portainer CE's `/data` lives on an NFSv4 export from nexus-gateway (`/srv/nfs/portainer-data` → mounted at `/var/lib/portainer-data` on each manager). Common issues:

| Symptom | Diagnosis | Fix |
|---|---|---|
| `mount.nfs4: No such file or directory` | Server's `fsid=0` makes the export the NFSv4 pseudo-root; client must mount via `:/`, not `:/srv/nfs/portainer-data` | fstab entry: `192.168.70.1:/  /var/lib/portainer-data  nfs4  rw,hard,bg,_netdev,vers=4.2,sec=sys  0  0` |
| `mount.nfs4: timed out` | nftables on gateway dropping tcp/2049 inbound | `ssh nexusadmin@192.168.70.1 "sudo nft list chain inet filter input | grep 2049"` should show 3 manager-IP-specific accept rules |
| Portainer Server pod can't read `/data` | NFS server unreachable from this manager | `ssh nexusadmin@<manager> "findmnt /var/lib/portainer-data; sudo touch /var/lib/portainer-data/.write-test && sudo rm -f /var/lib/portainer-data/.write-test"` |
| Stale BoltDB after manual NFS unmount | Portainer can't reattach to BoltDB if the file was open during unmount | `docker service update --force portainer_server` (Swarm reschedules + reattaches) |

Verify NFS export from build host:

```pwsh
ssh nexusadmin@192.168.70.1 'sudo exportfs -v'
# Should list 3 manager IPs (.111/.112/.113) with rw,sync,no_root_squash,fsid=0
```

### 3.4 Smoke gate cheat sheet

```pwsh
pwsh -File scripts\swarm.ps1 smoke -Phase 0.E.4    # ~180 chained checks
pwsh -File scripts\swarm.ps1 smoke -Phase 0.E.3.3  # ~155 chained (skip 0.E.4)
pwsh -File scripts\swarm.ps1 smoke -Phase 0.E.3.2  # ~140 chained (skip 0.E.3.3 + 0.E.4)
```

Each `smoke-0.E.<N>.ps1` runs the `<N-1>` baseline first; failures cascade from earliest broken sub-phase.

### 3.5 Operator credential reference

| Asset | Vault KV path | Field | Used by |
|---|---|---|---|
| Consul gossip key | `nexus/swarm/consul-gossip-key` | `gossip_key` | Vault Agent template → `/etc/consul.d/10-encrypt.hcl` |
| Consul mgmt token | `nexus/swarm/consul-bootstrap-token` | `management_token` | Operator + smoke probes |
| Consul agent token (per host) | `nexus/swarm/agent-tokens/<host>` | `agent_token` | Vault Agent template → `/etc/consul.d/30-acl-token.hcl` + Nomad's `consul.token` |
| Nomad mgmt token | `nexus/swarm/nomad-bootstrap-token` | `management_token` | Operator + smoke probes |
| Nomad operator tokens (per host) | `nexus/swarm/nomad-agent-tokens/<host>` | `agent_token` | Operator scripting (NOT consumed by agents — they use mTLS) |
| Portainer admin pwd | `nexus/portainer/admin-bcrypt` | `bcrypt_hash` (rendered) + `plaintext` (operator-readable) | Portainer CE login |
| Vault HA Shamir | `~/.nexus/vault-transit-init.json` | `unseal_keys_b64` | vault-transit reboot recovery |
| Build host root token | `~/.nexus/vault-init.json` | `root_token` | All cross-env terraform applies |
