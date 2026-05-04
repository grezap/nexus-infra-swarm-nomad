/*
 * role-overlay-consul-gossip-encrypt.tf -- Phase 0.E.2.1
 *
 * Enables Consul LAN gossip encryption across all 6 agents (3 servers + 3
 * clients). Pre-req: 0.E.2 setup (PKI role + KV seed + 6 Vault Agents) is
 * applied -- each node has a `nexus-vault-agent.service` running with
 * AppRole auth + read access to nexus/data/swarm/consul-gossip-key.
 *
 * How it works:
 *   1. Drop /etc/vault-agent/10-template-gossip.hcl on each of the 6 nodes.
 *      The template stanza tells Vault Agent to fetch the gossip key from
 *      Vault KV and render /etc/consul.d/10-encrypt.hcl with:
 *
 *        encrypt = "<base64-32-byte-key>"
 *        encrypt_verify_incoming = true
 *        encrypt_verify_outgoing = true
 *
 *   2. Restart nexus-vault-agent.service on each node so it picks up the
 *      new template stanza (Vault Agent does NOT auto-reload its own
 *      config dir on change).
 *
 *   3. Vault Agent renders the template, then runs the `command` field
 *      (`systemctl restart consul.service`), causing consul to re-read
 *      its config dir and pick up the new 10-encrypt.hcl. consul agents
 *      that have the key gossip encrypted with each other; in steady state
 *      (all 6 have the key), all gossip is encrypted.
 *
 *   4. Apply this overlay sequentially across the 6 nodes (not parallel)
 *      so the cluster doesn't lose quorum -- at any moment 5 of 6 agents
 *      are operational.
 *
 * Idempotency: the template render is itself idempotent (Vault Agent
 * detects the rendered file matches and skips the command). Re-applying
 * this overlay rewrites /etc/vault-agent/10-template-gossip.hcl + reloads
 * the agent; if the gossip key in Vault hasn't changed, /etc/consul.d/
 * 10-encrypt.hcl is unchanged and consul does NOT restart again.
 *
 * Selective ops: var.enable_consul_gossip_encryption.
 *
 * Smoke verification (smoke-0.E.2.1.ps1):
 *   - /etc/consul.d/10-encrypt.hcl present + non-empty on all 6 nodes
 *   - `consul keyring -list` returns 1 primary key (same on all 6)
 *   - `consul members` still returns 6 alive
 *   - existing 0.E.1 checks still green
 */

locals {
  # Sequential apply order: managers first (preserve quorum during their
  # rolling restart), then workers. Within each group, .1 -> .2 -> .3.
  consul_gossip_apply_order = [
    "swarm-manager-1",
    "swarm-manager-2",
    "swarm-manager-3",
    "swarm-worker-1",
    "swarm-worker-2",
    "swarm-worker-3",
  ]
}

resource "null_resource" "consul_gossip_encrypt" {
  count = var.enable_consul_gossip_encryption && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    # Re-run when any agent install changes (new vault-agent install =
    # new node to enroll in encrypted gossip).
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    gossip_overlay_v = "1"
  }

  depends_on = [null_resource.swarm_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.swarm_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $kvMount  = '${var.vault_kv_mount_path}'

      $applyOrder = @(
%{for host in local.consul_gossip_apply_order~}
        '${host}',
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # Map host -> VMnet11 IP for SSH addressing
      $hostNameMap = @{
        'swarm-manager-1' = '192.168.70.111'
        'swarm-manager-2' = '192.168.70.112'
        'swarm-manager-3' = '192.168.70.113'
        'swarm-worker-1'  = '192.168.70.131'
        'swarm-worker-2'  = '192.168.70.132'
        'swarm-worker-3'  = '192.168.70.133'
      }

      # The Vault Agent template stanza. Inline contents avoids a separate
      # source-file scp. The `command` field makes Vault Agent restart consul
      # after each successful render. The {{ with secret ... }} ... {{ end }}
      # block reads from KV v2 (engine prefixes path with /data/).
      $templateConfig = @"
# 10-template-gossip.hcl -- Phase 0.E.2.1
# Vault Agent template that fetches the gossip key from KV and renders
# /etc/consul.d/10-encrypt.hcl. The `command` field runs after each
# successful render; consul re-reads its config dir on restart.

template {
  contents = <<EOT
{{ with secret "$kvMount/data/swarm/consul-gossip-key" }}encrypt = "{{ .Data.data.gossip_key }}"
encrypt_verify_incoming = true
encrypt_verify_outgoing = true
{{ end }}
EOT

  destination = "/etc/consul.d/10-encrypt.hcl"
  perms       = "0640"
  user        = "root"
  group       = "consul"

  command         = "systemctl restart consul.service"
  command_timeout = "30s"
}
"@

      $templateBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($templateConfig)
      $templateB64   = [Convert]::ToBase64String($templateBytes)

      foreach ($hostName in $applyOrder) {
        $vmIp = $hostNameMap[$hostName]
        Write-Host ""
        Write-Host "[gossip-encrypt $hostName] enrolling in encrypted gossip..."

        # Step 1: drop the template config + restart vault-agent
        $stageScript = @"
set -euo pipefail
echo '$templateB64' | base64 -d | sudo tee /etc/vault-agent/10-template-gossip.hcl > /dev/null
sudo chown root:root /etc/vault-agent/10-template-gossip.hcl
sudo chmod 0644 /etc/vault-agent/10-template-gossip.hcl
sudo systemctl restart nexus-vault-agent.service
"@
        $stageBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($stageScript)
        $stageB64   = [Convert]::ToBase64String($stageBytes)

        $stageOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$stageB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stageOut.Trim()
          throw "[gossip-encrypt $hostName] stage failed (rc=$LASTEXITCODE)"
        }

        # Step 2: wait for /etc/consul.d/10-encrypt.hcl to materialize
        # (Vault Agent renders templates within ~5s of startup typically)
        $renderDeadline = (Get-Date).AddSeconds(60)
        $rendered = $false
        while ((Get-Date) -lt $renderDeadline) {
          $check = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /etc/consul.d/10-encrypt.hcl && sudo grep -q 'encrypt = ' /etc/consul.d/10-encrypt.hcl && echo RENDERED" 2>&1 | Out-String).Trim()
          if ($check -match 'RENDERED') { $rendered = $true; break }
          Start-Sleep -Seconds 3
        }
        if (-not $rendered) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
          Write-Host $journal
          throw "[gossip-encrypt $hostName] template never rendered /etc/consul.d/10-encrypt.hcl within 60s"
        }
        Write-Host "[gossip-encrypt $hostName] /etc/consul.d/10-encrypt.hcl rendered"

        # Step 3: wait for consul to be back up (Vault Agent's command
        # restarted it; takes ~5-10s to rejoin cluster)
        $consulDeadline = (Get-Date).AddSeconds(60)
        $consulReady = $false
        while ((Get-Date) -lt $consulDeadline) {
          $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active consul.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            # additional probe: consul info -- ensures rejoin succeeded
            $info = (ssh @sshOpts "$sshUser@$vmIp" "consul info 2>&1 | grep -E 'leader_addr|known_servers' | head -2" 2>&1 | Out-String).Trim()
            if ($info -match 'known_servers' -or $info -match 'leader_addr') {
              $consulReady = $true; break
            }
          }
          Start-Sleep -Seconds 3
        }
        if (-not $consulReady) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u consul.service --no-pager -n 30" 2>&1 | Out-String)
          Write-Host $journal
          throw "[gossip-encrypt $hostName] consul.service didn't return to ready within 60s"
        }
        Write-Host "[gossip-encrypt $hostName] consul rejoined (encrypted gossip active)"
      }

      Write-Host ""
      Write-Host "[gossip-encrypt] all 6 agents enrolled. Verifying keyring consistency..."
      Start-Sleep -Seconds 5

      # Final cluster-wide verification: keyring should show exactly 1 key
      # alive on all 6 agents. Use a temp var to avoid the PowerShell hashtable
      # indexer syntax colliding with terraform's heredoc interpolation parser.
      $leaderProbeIp = $hostNameMap['swarm-manager-1']
      $keyringOut = (ssh @sshOpts "$sshUser@$leaderProbeIp" "consul keyring -list 2>&1" 2>&1 | Out-String)
      Write-Host $keyringOut.Trim()
      if ($keyringOut -notmatch '6/6') {
        throw "[gossip-encrypt] keyring not converged across all 6 agents (expected '... 6/6 ...' alive count)"
      }
      Write-Host "[gossip-encrypt] OK -- gossip encrypted across all 6 agents (keyring 6/6)"
    PWSH
  }

  # Destroy provisioner: best-effort cleanup. Removes the template + the
  # rendered file + restarts consul (which falls back to no-encrypt).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $hostNames = @('swarm-manager-1','swarm-manager-2','swarm-manager-3','swarm-worker-1','swarm-worker-2','swarm-worker-3')
      $hostNameMap = @{
        'swarm-manager-1' = '192.168.70.111'; 'swarm-manager-2' = '192.168.70.112'; 'swarm-manager-3' = '192.168.70.113'
        'swarm-worker-1'  = '192.168.70.131'; 'swarm-worker-2'  = '192.168.70.132'; 'swarm-worker-3'  = '192.168.70.133'
      }
      foreach ($h in $hostNames) {
        $ip = $hostNameMap[$h]
        Write-Host "[gossip-encrypt destroy] $${h}: removing template + rendered file + restarting consul"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/vault-agent/10-template-gossip.hcl /etc/consul.d/10-encrypt.hcl; sudo systemctl restart nexus-vault-agent.service consul.service" 2>$null
      }
      exit 0
    PWSH
  }
}
