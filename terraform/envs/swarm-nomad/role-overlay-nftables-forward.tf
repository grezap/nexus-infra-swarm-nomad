/*
 * role-overlay-nftables-forward.tf -- Phase 0.E.4e
 *
 * Hot-fixes the swarm-node `inet filter forward` chain on the live cluster
 * so Docker's swarm ingress mesh DNAT path (host:9443 -> 172.18.0.2:9443
 * etc.) is allowed through the operator-managed nftables ruleset.
 *
 * Why this is needed:
 *   /etc/nftables.conf as deployed by the swarm-node Packer template
 *   declares an `inet filter forward` chain with `policy drop` and ZERO
 *   rules. Docker's iptables-nft writes to a separate `ip filter FORWARD`
 *   chain (policy accept + DOCKER-FORWARD/USER). Linux runs ALL FORWARD
 *   chains for every forwarded packet, so the inet drop kills DNAT'd
 *   ingress traffic before it reaches the container. The ip filter
 *   acceptance is necessary but NOT sufficient.
 *
 *   Diagnosed during nexus-cli v0.1.x live-cluster runs:
 *     - 192.168.70.111:8501 (Consul, host listener) -- works (INPUT chain)
 *     - 192.168.70.111:9443 (Portainer, DNAT'd to 172.18.0.2) -- timed out
 *   The inet filter forward chain was the only candidate; verified via
 *   `nft list chain inet filter forward` showing empty drop policy on a
 *   manager that had its docker daemon restarted (rebuilt ip filter rules
 *   but did not affect inet filter).
 *
 * What this overlay does:
 *   1. SSHes to each swarm-node (managers + workers).
 *   2. Idempotently patches /etc/nftables.conf to add 5 new lines inside
 *      the existing `chain forward { ... }` block:
 *         ct state { established, related } accept
 *         iifname "docker_gwbridge" accept
 *         oifname "docker_gwbridge" accept
 *         iifname "docker0"         accept
 *         oifname "docker0"         accept
 *      Insert position: between `type filter hook forward priority 0; policy drop;`
 *      and the chain's closing `}`.
 *   3. Atomic ruleset reload via `nft -f /etc/nftables.conf`.
 *   4. Restart docker so its iptables-nft rules (which the `flush ruleset`
 *      at the top of nftables.conf will have wiped) get rebuilt. Same
 *      pattern as role-overlay-portainer-firewall.tf -- per memory note
 *      `feedback_nftables_flush_ruleset_wipes_docker.md`.
 *   5. Sequential per-node application to preserve Swarm raft quorum.
 *
 * Idempotency:
 *   Marker comment in /etc/nftables.conf -> skip if already patched. The
 *   Packer base template (packer/swarm-node/files/nftables.conf) already
 *   carries these rules at v3+; this overlay only fires on existing
 *   pre-v3 clones. New clones boot with the rules already in place.
 *
 * Selective ops: var.enable_nftables_forward (default true).
 */

variable "enable_nftables_forward" {
  type        = bool
  default     = true
  description = "0.E.4e: hot-fix /etc/nftables.conf on running swarm-nodes to add inet filter forward accept rules for Docker swarm ingress mesh."
}

locals {
  nftables_forward_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133" },
  ]
}

resource "null_resource" "nftables_forward" {
  count = var.enable_nftables_forward ? 1 : 0

  triggers = {
    nftables_forward_v = "1"
  }

  # Run after any portainer-firewall changes since both rewrite /etc/nftables.conf.
  depends_on = [null_resource.portainer_firewall]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $nodes = @(
%{for spec in local.nftables_forward_node_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # Bash patch script. Idempotent via marker comment. After patching,
      # `nft -f /etc/nftables.conf` flushes the ruleset (including Docker's
      # iptables-nft rules), so we ALSO restart dockerd to rebuild the
      # ingress mesh rules. Sequential per-node restart preserves Swarm
      # quorum (3 of 3 raft tolerates 1 down).
      $patchScript = @'
set -euo pipefail
MARKER='# nftables-forward (managed by terraform/envs/swarm-nomad/role-overlay-nftables-forward.tf)'

if grep -qF "$MARKER" /etc/nftables.conf; then
  echo "[nft-forward] /etc/nftables.conf already patched (idempotent skip)"
  exit 0
fi

# Check this node actually has the empty drop chain we expect to patch.
if ! sudo nft list chain inet filter forward 2>/dev/null | grep -q "policy drop"; then
  echo "[nft-forward] forward chain is not policy=drop; skipping"
  exit 0
fi

# Backup + patch in-place. awk inserts the marker + accept rules
# IMMEDIATELY after the `type filter hook forward priority 0; policy drop;`
# line of the forward chain. Match the exact line shape from the swarm-node
# Packer template.
sudo cp /etc/nftables.conf /etc/nftables.conf.bak.nft-forward
sudo awk -v marker="$MARKER" '
  /^[[:space:]]*type filter hook forward priority 0; policy drop;[[:space:]]*$/ && !inserted {
    print
    print ""
    print "        " marker
    print "        ct state { established, related } accept"
    print "        iifname \"docker_gwbridge\" accept comment \"Docker swarm ingress mesh (in)\""
    print "        oifname \"docker_gwbridge\" accept comment \"Docker swarm ingress mesh (out)\""
    print "        iifname \"docker0\"         accept comment \"Docker default bridge (in)\""
    print "        oifname \"docker0\"         accept comment \"Docker default bridge (out)\""
    inserted = 1
    next
  }
  { print }
' /etc/nftables.conf.bak.nft-forward | sudo tee /etc/nftables.conf > /dev/null

# Atomic ruleset reload. NOTE: `flush ruleset` at the top of /etc/nftables.conf
# wipes Docker's iptables-nft tables (ingress DNAT). dockerd restart below
# rebuilds them.
sudo nft -f /etc/nftables.conf

# Restart dockerd to re-install ingress mesh iptables/nftables rules.
sudo systemctl restart docker
sleep 4

# Verify forward chain has the accept rule (running state).
if sudo nft list chain inet filter forward 2>/dev/null | grep -q 'iifname "docker_gwbridge" accept'; then
  echo "[nft-forward] OK -- forward chain accept rules in place"
else
  echo "[nft-forward] ERROR -- expected accept rules not found in running ruleset" >&2
  exit 1
fi

echo "[nft-forward] OK"
'@
      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($patchScript -replace "`r`n", "`n")))

      # Sequential per-node application -- avoids parallel docker restarts
      # which would simultaneously remove Swarm raft quorum on managers.
      foreach ($node in $nodes) {
        Write-Host "[nft-forward] patching $($node.Host) ($($node.VmIp))..."
        $out = (ssh @sshOpts "$sshUser@$($node.VmIp)" "echo '$b64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        Write-Host $out
        if ($LASTEXITCODE -ne 0) {
          throw "[nft-forward] failed on $($node.Host) (rc=$LASTEXITCODE)"
        }
        # Settle window between nodes -- raft quorum has time to absorb the
        # docker restart on this manager before the next one drops.
        Start-Sleep -Seconds 5
      }

      Write-Host ""
      Write-Host "[nft-forward] OK -- inet filter forward chain accept rules + Docker ingress mesh rebuilt on all 6 nodes"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $ips = @('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133')
      $cleanup = @'
set -euo pipefail
if [ -f /etc/nftables.conf.bak.nft-forward ]; then
  sudo cp /etc/nftables.conf.bak.nft-forward /etc/nftables.conf
  sudo nft -f /etc/nftables.conf
  sudo rm -f /etc/nftables.conf.bak.nft-forward
  sudo systemctl restart docker
  echo "[nft-forward destroy] reverted"
fi
'@
      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($cleanup -replace "`r`n", "`n")))
      foreach ($ip in $ips) {
        ssh @sshOpts "$sshUser@$ip" "echo '$b64' | base64 -d | bash" 2>$null
      }
      exit 0
    PWSH
  }
}
