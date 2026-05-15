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

## §1 Phase 0.E — full tier bring-up (0.E.1 through 0.E.4e)

A single `pwsh -File scripts\swarm.ps1 apply` brings up **the entire Phase 0.E
tier** — not just the 0.E.1 swarm cluster, but every overlay through 0.E.4e:

- **0.E.1** — 3+3 Swarm cluster bring-up (clones + firstboot + `docker swarm init/join`)
- **0.E.2.1-0.E.2.3** — Consul harden: gossip encryption + TLS + ACL deny-mode
- **0.E.3.1-0.E.3.3** — Nomad harden: TLS + ACL + Nomad → Consul HTTPS rewire + Nomad-Vault integration
- **0.E.4 + 0.E.4a-d** — Portainer CE clustered Swarm service (NFS-via-gateway + TLS + DNS + bcrypt admin from sticky Vault KV + stack deploy)
- **0.E.4e** — cold-rebuild gate + 3 structural fixes (TLS full-chain on the wire · `inet filter forward` accept rules · stage1 stdin-pipe pattern in the 3 TLS overlays)

The §1.x sub-sections below describe the operator-level commands; the per-sub-phase
implementation detail (what each overlay actually does, what state lands where) is
in `docs/verification/` and in the per-overlay file headers under
`terraform/envs/swarm-nomad/role-overlay-*.tf`.

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

This single command brings up the **full Phase 0.E tier** (every sub-phase, in
dependency order). Apply flow:

**0.E.1 — 3+3 Swarm cluster bring-up:**
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
7. `docker node ls` reports 6.

**0.E.2 — Consul harden** (`role-overlay-swarm-vault-agents.tf` + `role-overlay-consul-{gossip,tls,acl}.tf`):
8. Per-node `nexus-vault-agent.service` installed (AppRole authenticated to vault-1 via build-host sidecars).
9. **0.E.2.1** — Consul gossip key rendered from `nexus/swarm/consul-gossip-key` → `/etc/consul.d/10-encrypt.hcl`; sequential rolling consul restart → keyring converges `[6/6]`.
10. **0.E.2.2** — per-node Consul TLS leaf from `pki_int/issue/consul-server`; mTLS for RPC + Raft, server-only TLS for HTTPS API on `:8501`; plain HTTP `:8500` hard-cut via systemd drop-in.
11. **0.E.2.3** — Consul ACL bootstrap (allow → deny transition), mgmt token persisted to `nexus/swarm/consul-bootstrap-token`, 6 per-host agent tokens, anonymous HTTPS `/v1/agent/self` returns `403`.

**0.E.3 — Nomad harden** (`role-overlay-nomad-{tls,acl,consul-rewire,vault}.tf`):
12. **0.E.3.1** — per-node Nomad TLS leaf from `pki_int/issue/nomad-server`; mTLS for RPC + raft + HTTPS API on `:4646`; parallel big-bang restart (a TLS wire-format flip cannot be sequential).
13. **0.E.3.2** — Nomad ACL bootstrap, mgmt token persisted to `nexus/swarm/nomad-bootstrap-token`, shared `nomad-agent` policy + 6 per-host operator tokens.
14. **0.E.3.3a** — Nomad → Consul HTTPS rewire: Vault Agent renders Consul agent token; legacy `consul { address = "127.0.0.1:8500" }` sed-removed; sequential rolling restart.
15. **0.E.3.3b** — Nomad-Vault integration: per-manager periodic token minted via `vault token create -role=nomad-cluster`; `vault {}` stanza loaded.

**0.E.4 — Portainer CE clustered Swarm service** (`role-overlay-portainer-{nfs,tls,dns,admin,stack}.tf`):
16. **0.E.4a** — NFSv4 `/srv/nfs/portainer-data` exported from `nexus-gateway` with `fsid=0`; per-manager mount at `/var/lib/portainer-data`.
17. **0.E.4b** — `pki_int/roles/portainer-server` (CN `portainer.nexus.lab` + per-host IP SANs); per-manager Vault Agent renders `/etc/portainer/tls/{server.crt,server.key,ca.pem}`.
18. **0.E.4c** — dnsmasq `host-record=portainer.nexus.lab,IP1,IP2,IP3` (multi-A round-robin).
19. **0.E.4d** — sticky-seeded `nexus/portainer/admin-bcrypt` (plaintext + bcrypt cost=10); `docker stack deploy portainer-stack.yml` (server 1 replica manager-pinned + agent global × 6).

**0.E.4e — cold-rebuild gate + 3 structural fixes** (`role-overlay-nftables-forward.tf` + 3 split-script updates):
20. `inet filter forward` accept rules for `docker_gwbridge`/`docker0` (ingress mesh DNAT path).
21. Consul + Nomad + Portainer split-scripts emit `server.crt = leaf + intermediate` (full chain on the wire).
22. Stage1 stdin-pipe pattern in the 3 TLS overlays (pre-fix argv cliff on Windows ssh.exe).

Final assertion: `docker node ls` = 6, `consul members` = 6, `nomad server members` = 3, `https://portainer.nexus.lab:9443/api/system/status` returns 200 with TLS chain validating against the build host's stock root-only CA bundle.

Total wall-clock for a fresh apply (post-Packer-build): ~25-35 min.

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
| 0.E.4e | TLS full-chain on wire + `inet filter forward` accept rules + stage1 stdin-pipe; cold-rebuild proven end-to-end | ✅ closed (`v0.1.1`, 2026-05-08) |
| 0.E.5 | Close-out canon batch (MASTER-PLAN sub-phase rows + ADRs 0011–0019 + vms.yaml + glossary + handbook + verification artefacts) | ✅ closed (`v0.2.0`, 2026-05-08) — **Phase 0.E complete** |

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

### 3.6 Cold rebuild — destroy → apply → smoke (canon)

The lab is engineered to be re-deployable from cold without operator hot-state. Once 0.E.4e has landed, the canonical full-rebuild path is:

```pwsh
# 1. Tear down (~5 min). nexus-gateway is part of the foundation env (NOT torn down here).
pwsh -File scripts\swarm.ps1 destroy

# 1b. PREREQUISITE for cold rebuild: wipe stale Consul + Nomad bootstrap +
#     per-host agent tokens from Vault KV. The new cluster's `consul acl
#     bootstrap` mints a fresh mgmt token; if the old one is still in KV,
#     consul_acl Stage 3 reuses it, the new cluster doesn't recognize it,
#     and Stage 5 verification fails with "expected 6 alive, got '0'".
#     Same shape for nomad_acl. consul-gossip-key is preserved (not
#     bootstrap state).
$root = (Get-Content "$HOME\.nexus\vault-init.json" | ConvertFrom-Json).root_token
$wipe = @"
export VAULT_TOKEN='$root' VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true
vault kv metadata delete -mount=nexus swarm/consul-bootstrap-token
vault kv metadata delete -mount=nexus swarm/nomad-bootstrap-token
for h in swarm-manager-1 swarm-manager-2 swarm-manager-3 swarm-worker-1 swarm-worker-2 swarm-worker-3; do
  vault kv metadata delete -mount=nexus swarm/agent-tokens/`$h
  vault kv metadata delete -mount=nexus swarm/nomad-agent-tokens/`$h
done
"@
ssh nexusadmin@192.168.70.121 $wipe

# 2. Re-apply from cold (~25-35 min, sequential per-node bring-up + per-overlay apply).
pwsh -File scripts\swarm.ps1 apply

# 3. Smoke gate (~5 min). Chains 0.E.1 -> 0.E.2.x -> 0.E.3.x -> 0.E.4 -> 0.E.4e.
pwsh -File scripts\swarm.ps1 smoke -Phase 0.E.4e

# 4. End-to-end with the operator CLI.
$env:VAULT_ADDR   = 'https://192.168.70.121:8200'
$env:VAULT_CACERT = "$HOME\.nexus\vault-ca-bundle.crt"   # STOCK root-only
vault login -method=ldap username=nexusadmin
$env:VAULT_TOKEN  = vault print token
F:\..\nexus-cli\artifacts\win-x64\nexus.exe cluster-status
# Expect: GREEN across Consul + Nomad + Portainer.
```

There must be **zero manual steps** between (3) and (4) — no `Add-Content $caBundle ...`, no `--insecure`, no `NEXUS_*_ADDR` overrides for cluster reachability. If any are needed, that's a regression in the cluster build, not an operator workaround.

### 3.7 Phase 0.E.4e — TLS full-chain on wire + ingress-mesh forward path

> Scope: ADR-0019. Two architectural fixes that close the gap between "smoke gate green from inside the cluster" and "build-host operator workflow works against the cluster's stock CA bundle."

**Why this phase exists:** Phase 0.E.4 closed with smoke probes that ran *inside* the cluster, against `--cacert /etc/portainer/tls/ca.pem` (the manager's local intermediate file). That gate didn't catch (1) leaf-only on the wire, and (2) `inet filter forward` policy=drop with no rules. The first off-cluster client (`grezap/nexus-cli` v0.1.0) hit both immediately.

**Scope of changes:**

| File | Change |
|---|---|
| `terraform/envs/swarm-nomad/role-overlay-consul-tls.tf` | split-script: server.crt = leaf+intermediate. `consul_tls_v` 6→7. |
| `terraform/envs/swarm-nomad/role-overlay-nomad-tls.tf` | split-script: server.crt = leaf+intermediate. `nomad_tls_v` 4→5. |
| `terraform/envs/swarm-nomad/role-overlay-portainer-tls.tf` | split-script: server.crt = leaf+intermediate. `portainer_tls_v` 1→2. |
| `terraform/envs/swarm-nomad/role-overlay-nftables-forward.tf` | NEW. SSH-driven hot-fix: append docker_gwbridge / docker0 accept rules to `inet filter forward` on each node. |
| `packer/swarm-node/files/nftables.conf` | base template: forward chain populated with the accept rules. Future clones boot clean. |
| `scripts/smoke-0.E.4e.ps1` | NEW. Chained on smoke-0.E.4.ps1; adds wire-chain depth, off-cluster reachability, and forward-rule probes. |
| `scripts/swarm.ps1` | `0.E.4e` added to ValidateSet for `-Phase`. |

**Apply pattern (the only one that survives the 5s-cascade pitfall):**

> Pre-condition: swarm 6/6 nodes Ready, leader healthy, Portainer 1/1. Validate via `docker node ls` + `docker service ls` from any manager. **Abort** if any NACK — cluster fragility from a previous churn cycle will cascade-kill tasks during the apply.

```pwsh
cd terraform/envs/swarm-nomad

# Step 1: nftables forward fix on running cluster (additive; one docker restart per node).
#   Per-node sequential with 30s settle (longer than 0.E.4d's 5s -- intentional).
terraform apply -auto-approve -target='null_resource.nftables_forward[0]'

# Step 2: portainer_tls re-render. Vault Agent picks up the new template,
#   writes new bundle.pem, split-script writes leaf+intermediate to server.crt.
#   Container hasn't been restarted yet -- it's still serving the old leaf-only cert.
terraform apply -auto-approve -target='null_resource.portainer_tls[0]'

# Step 3: force a single Portainer service update so the container restarts and
#   picks up the new server.crt via its bind-mount.
ssh nexusadmin@192.168.70.111 'docker service update --force --detach=false portainer_server'

# Step 4: consul_tls re-render (sequential per-manager rolling restart per overlay's logic).
terraform apply -auto-approve -target='null_resource.consul_tls[0]'

# Step 5: nomad_tls re-render (parallel big-bang restart per
#   feedback_nomad_tls_rolling_restart_must_be_parallel.md -- TLS wire-format flips
#   are the one case where parallel is correct).
terraform apply -auto-approve -target='null_resource.nomad_tls[0]'

# Step 6: smoke gate.
pwsh -File scripts\smoke-0.E.4e.ps1 -RunCli `
     -NexusCliPath "F:\..\nexus-cli\artifacts\win-x64\nexus.exe"
```

**Expected output between steps:** each `terraform apply -target` produces a per-node "rendering" / "split / restart" log line, then "OK" per node. The `-target` flag suppresses cascade replacement of downstream resources (consul_acl, nomad_vault_integration, portainer_admin_render, portainer_stack); a future `terraform apply` without `-target` will reconcile that drift.

**Rollback procedure:** every overlay has a destroy provisioner that reverts via `.bak.*` backups + service restart:

```pwsh
# Targeted rollback (per overlay) -- restores /etc/nftables.conf or server.crt etc.
terraform destroy -auto-approve -target='null_resource.nftables_forward[0]'
terraform destroy -auto-approve -target='null_resource.portainer_tls[0]'   # tears down portainer_stack via cascade
terraform destroy -auto-approve -target='null_resource.consul_tls[0]'
terraform destroy -auto-approve -target='null_resource.nomad_tls[0]'

# Per-overlay state recovery (if the destroy provisioner fails mid-flight):
ssh nexusadmin@<node> 'sudo cp /etc/nftables.conf.bak.nft-forward /etc/nftables.conf && sudo nft -f /etc/nftables.conf && sudo systemctl restart docker'
```

**Verification (Block C of smoke-0.E.4e.ps1, run by hand for fast feedback):**

```pwsh
# 1. Stock CA bundle should have exactly 1 cert (root only).
$bundle = "$HOME\.nexus\vault-ca-bundle.crt"
(Select-String $bundle 'BEGIN CERTIFICATE' -SimpleMatch).Count   # expect: 1

# 2. Off-cluster TLS handshake to each manager's services should succeed.
foreach ($ip in '192.168.70.111','192.168.70.112','192.168.70.113') {
  foreach ($p in 8501,4646,9443) {
    # --ssl-no-revoke: Windows curl uses schannel, which checks CRL by default;
    # the lab PKI doesn't expose a CRL endpoint reachable from the build host,
    # so without this flag schannel returns curl exit 60 ("revocation status unknown").
    $code = curl.exe -sS --cacert $bundle --ssl-no-revoke -m 5 -o $null -w '%{http_code}' "https://$ip:$p/$(if ($p -eq 9443) { 'api/system/status' } else { 'v1/status/leader' })"
    "{0,-16} :{1,-5} -> {2}" -f $ip, $p, $code
  }
}
# Expect: 8501 -> 200, 4646 -> 200 or 403 (Nomad anon-deny is fine; gate is TLS validates),
#         9443 -> 200. Anything else is a regression.

# 3. Wire-chain depth at one of each.
function Get-Depth($ip,$p,$sni) {
  $tcp = [System.Net.Sockets.TcpClient]::new($ip,$p)
  $script:d = 0
  $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(),$false,{ param($s,$c,$ch,$e) $script:d=$ch.ChainElements.Count; $true })
  $ssl.AuthenticateAsClient($sni)
  $ssl.Dispose(); $tcp.Dispose()
  return $script:d
}
Get-Depth '192.168.70.111' 8501 'swarm-manager-1.consul.nexus.lab'   # expect: 2
Get-Depth '192.168.70.111' 4646 'server.global.nomad'                 # expect: 2
Get-Depth '192.168.70.111' 9443 'portainer.nexus.lab'                 # expect: 2
```

**Common failure modes during apply:**

| Symptom | Likely cause | Fix |
|---|---|---|
| `[consul-acl] cluster not converged under deny-mode: expected 6 alive, got '0'` after a cold rebuild | Stale Consul mgmt token in Vault KV from a previous deploy; Stage 3 "idempotent reuse" trusted it; new cluster has different bootstrap state. Same shape applies to `[nomad-acl]` Stage 3. | **Cold-rebuild prerequisite (canon):** before re-applying after a destroy, wipe the affected KV paths via root token: `vault kv metadata delete -mount=nexus swarm/consul-bootstrap-token`, `... swarm/nomad-bootstrap-token`, and the per-host `swarm/agent-tokens/<host>` and `swarm/nomad-agent-tokens/<host>` for all 6 nodes. `consul-gossip-key` is preserved (not bootstrap state). Then re-apply. Tracked for canonical-fix in 0.E.5+ as "validate token against cluster, re-bootstrap on stale". |
| `bash: -c: line 1: unexpected EOF while looking for matching '` during a TLS overlay's Phase 1 stage1 | Pre-0.E.4e: stage1 used `bash -c 'echo BASE64 \| base64 -d \| bash'`; ssh.exe argv handling on Windows clips ~6KB single-quoted strings. v7's split-script edit pushed stage1 over the threshold. | Fixed in `consul-tls v7` / `nomad-tls v5` / `portainer-tls v2` (commit [`10377af`](https://github.com/grezap/nexus-infra-swarm-nomad/commit/10377af)). Stage1 now mirrors stage2: pipe LF-normalized plaintext to ssh + `bash -s` with `tr -d '\r'` on the remote. |
| Portainer task fails immediately after step 3 | Container started but dockerd was restarting elsewhere too soon | Wait 60s; rerun `docker service update --force portainer_server` |
| Consul rolling restart leaves a manager out of raft | Sequential 5s sleep too short on a fragile cluster | Step 4 retry; if persistent, check `consul members` for split-brain and use `consul force-leave` |
| Wire-chain depth = 1 after step 5 | Vault Agent's pkiCert returned cached cert without re-render (the cert hadn't expired yet) | Manually delete `/etc/nomad.d/tls/bundle.pem` on each manager + `systemctl restart nexus-vault-agent.service`; idempotent re-render fires |
| Smoke gate Block C says "bundle has N certs (expected 1)" | Operator augmented the bundle as a workaround for the pre-0.E.4e state | Restore from `$HOME\.nexus\vault-ca-bundle.crt.bak.*` and re-run smoke |
| Smoke gate Block A "Consul .131:8501 sends >=2 chain elements" FAILS for workers | Workers' Consul HTTPS API binds `127.0.0.1` only (Consul client-mode `client_addr` default); off-cluster probes get TCP refused. Not a regression. | Smoke gate v2+ correctly probes managers only for Consul (workers' on-disk server.crt is verified by the file-check in the same block). |
| `:9443` reachable from manager but not from build host | nftables_forward overlay didn't fire on this node, OR docker hasn't been restarted | `ssh nexusadmin@<ip> 'sudo nft list chain inet filter forward'` should show docker_gwbridge accept; if missing, re-run step 1 with `-target='null_resource.nftables_forward[0]'` |
