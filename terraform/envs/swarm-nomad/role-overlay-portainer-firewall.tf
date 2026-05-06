/*
 * role-overlay-portainer-firewall.tf -- Phase 0.E.4d
 *
 * Canonicalizes the nftables patch that opens TCP/9443 (Portainer HTTPS UI)
 * + TCP/8000 (Portainer Edge agent tunnel) inbound on the swarm-nodes'
 * `nic0` (VMnet11 service interface). Without this, Docker Swarm's ingress
 * routing mesh receives packets but the host's nftables ruleset drops them
 * before they reach the DOCKER-INGRESS chain.
 *
 * Why all 6 swarm nodes (not just managers):
 *   Docker Swarm's routing mesh accepts published-port traffic on EVERY
 *   node, then forwards to the active replica via IPVS in the ingress
 *   namespace. Workers without the firewall rule would silently drop
 *   incoming requests, defeating the routing-mesh design.
 *
 * Why a separate overlay (not folded into the swarm-node Packer template):
 *   Portainer is a Phase 0.E.4 deliverable. The 0.E.1 swarm-node template
 *   only knows about Consul + Nomad + Docker Swarm baseline ports. Adding
 *   Portainer ports to the template would couple it to a specific app
 *   deployment, which the master plan separates intentionally (template ≠
 *   service deploy). This overlay layers the Portainer firewall as a
 *   service-specific concern on top of the role-aware baseline.
 *
 * Why in-place patch of /etc/nftables.conf (not runtime `nft add rule`):
 *   Per memory `feedback_nftables_runtime_add_after_drop.md`: runtime
 *   `nft add rule` lands AFTER the canonical `counter drop` in the input
 *   chain (unreachable). In-place patch + `nft -f /etc/nftables.conf`
 *   for atomic ruleset reload IS persistent across reboots AND positions
 *   the rule above the drop counter.
 *
 * CRITICAL TIMING: this overlay's `nft -f` will FLUSH the entire ruleset
 * (because /etc/nftables.conf starts with `flush ruleset`). That includes
 * Docker's iptables-nft tables for the ingress mesh. To recover those
 * rules, dockerd must be restarted on each node. The overlay handles this
 * sequentially after the ruleset reload.
 *
 * Idempotency:
 *   - Marker comment in /etc/nftables.conf -> skip if already patched.
 *   - Re-applies are no-op-fast.
 *
 * Selective ops: var.enable_portainer_firewall (default true).
 */

locals {
  portainer_firewall_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133" },
  ]
}

resource "null_resource" "portainer_firewall" {
  count = var.enable_portainer_firewall ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    portainer_firewall_v = "1"
  }

  depends_on = [null_resource.swarm_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $nodes = @(
%{for spec in local.portainer_firewall_node_specs~}
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
MARKER='# portainer ingress mesh (managed by terraform/envs/swarm-nomad/role-overlay-portainer-firewall.tf)'

if grep -qF "$MARKER" /etc/nftables.conf; then
  echo "[portainer-fw] /etc/nftables.conf already patched (idempotent skip)"
  exit 0
fi

# Backup + patch in-place. awk inserts the marker + accept rule
# IMMEDIATELY before the chain's `counter drop` line. Match `^counter drop$`
# (the swarm-node baseline; the gateway uses `counter packets ... drop`).
sudo cp /etc/nftables.conf /etc/nftables.conf.bak.portainer-fw
sudo awk -v marker="$MARKER" '
  /^[[:space:]]*counter drop[[:space:]]*$/ && !inserted {
    print "        " marker
    print "        iifname \"nic0\" ip saddr 192.168.70.0/24 tcp dport { 9443, 8000 } accept comment \"Portainer CE ingress mesh from VMnet11\""
    print ""
    inserted = 1
  }
  { print }
' /etc/nftables.conf.bak.portainer-fw | sudo tee /etc/nftables.conf > /dev/null

# Atomic ruleset reload. NOTE: `flush ruleset` at the top of /etc/nftables.conf
# wipes Docker's iptables-nft tables (ingress DNAT). dockerd restart below
# rebuilds them.
sudo nft -f /etc/nftables.conf

# Restart dockerd to re-install ingress mesh iptables/nftables rules.
sudo systemctl restart docker
sleep 4

# Verify ingress mesh DNAT rule exists (Docker Swarm rebuilds DOCKER-INGRESS).
DNAT_COUNT=$(sudo iptables -t nat -L DOCKER-INGRESS -n 2>/dev/null | grep -cE 'DNAT.*tcp dpt:(9443|8000)' || true)
echo "[portainer-fw] DOCKER-INGRESS DNAT rules for 9443/8000: $DNAT_COUNT"
echo "[portainer-fw] OK"
'@
      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($patchScript -replace "`r`n", "`n")))

      # Sequential per-node application -- avoids parallel docker restarts
      # which would simultaneously remove Swarm raft quorum on managers.
      foreach ($node in $nodes) {
        Write-Host "[portainer-fw] patching $($node.Host) ($($node.VmIp))..."
        $out = (ssh @sshOpts "$sshUser@$($node.VmIp)" "echo '$b64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        Write-Host $out
        if ($LASTEXITCODE -ne 0) {
          throw "[portainer-fw] failed on $($node.Host) (rc=$LASTEXITCODE)"
        }
        # Settle window between nodes -- raft quorum has time to absorb the
        # docker restart on this manager before the next one drops.
        Start-Sleep -Seconds 5
      }

      Write-Host ""
      Write-Host "[portainer-fw] OK -- nftables 9443/8000 open + Docker ingress mesh rebuilt on all 6 nodes"
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
if [ -f /etc/nftables.conf.bak.portainer-fw ]; then
  sudo cp /etc/nftables.conf.bak.portainer-fw /etc/nftables.conf
  sudo nft -f /etc/nftables.conf
  sudo rm -f /etc/nftables.conf.bak.portainer-fw
  sudo systemctl restart docker
  echo "[portainer-fw destroy] reverted"
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
