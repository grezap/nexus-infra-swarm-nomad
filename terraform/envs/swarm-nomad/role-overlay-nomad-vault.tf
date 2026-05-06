/*
 * role-overlay-nomad-vault.tf -- Phase 0.E.3.3b -- Nomad ↔ Vault integration
 *
 * Enables Nomad's `vault {}` agent stanza on managers (3 nodes only;
 * workers don't need vault integration for the basic case). After this,
 * Nomad jobs can request Vault secrets at runtime via the standard
 * `template { vault { ... } }` block in their job spec.
 *
 * Pre-reqs:
 *   - 0.E.3.2 Nomad ACL closed (mgmt token in Vault KV).
 *   - 0.E.3.3a Nomad → Consul HTTPS rewire applied (clean cluster shape).
 *   - nexus-infra-vmware/security env applied with:
 *       * role-overlay-vault-nomad-jobs-policy.tf v1 (creates Vault policy
 *         `nomad-jobs` + token role `nomad-cluster`).
 *       * role-overlay-vault-agent-swarm-policies.tf v4 (manager Vault
 *         Agent policies extended with `auth/token/create/nomad-cluster`
 *         update + `auth/token/roles/nomad-cluster` read).
 *
 * Token strategy (legacy "long-lived periodic token" pattern, NOT
 * Workload Identity):
 *   - At apply time we mint ONE periodic token per manager via
 *     `vault token create -role=nomad-cluster -policy=nomad-jobs` from
 *     vault-1 (using the build host's root token). Period=72h means the
 *     token can be renewed indefinitely as long as a renewal lands within
 *     each 72h window.
 *   - We scp the token to /etc/nomad.d/60-vault-token.txt on the manager.
 *   - Nomad's vault{} agent loop on startup reads the token, then takes
 *     over renewal -- it calls `vault token renew-self` ahead of each
 *     period boundary. The file is one-shot from terraform's perspective;
 *     Nomad maintains the token state going forward (in-memory + file
 *     updates).
 *   - Idempotency: probe for existing non-empty token file. If present,
 *     SKIP the mint (Nomad is already renewing); otherwise mint a fresh
 *     token. NEVER overwrite a populated token file -- that would orphan
 *     Nomad's renewal accounting and require a service restart.
 *
 * Why one-shot mint instead of Vault Agent template:
 *   Vault Agent template's `{{ with secret "auth/token/create/<role>" }}`
 *   would mint a NEW token on every render cycle, overwriting the file
 *   and creating dozens of orphaned tokens per day. The one-shot pattern
 *   matches Nomad's expectation of a stable token-holder.
 *
 * Why managers only:
 *   Nomad's vault{} agent stanza only needs to be on servers (not
 *   clients). Nomad servers brokering Vault token requests for jobs is
 *   the canonical model. Workers (clients) inherit child tokens from the
 *   server's bootstrap token at job-allocation time -- no per-worker
 *   vault token required.
 *
 * Choreography (3 stages, managers only):
 *   Stage 1 (sequential per-manager): idempotency probe. If
 *     /etc/nomad.d/60-vault-token.txt is non-empty, skip mint. Otherwise,
 *     vault-1 mints a periodic token for THIS manager via root token,
 *     scp to /etc/nomad.d/60-vault-token.txt (mode 0640 root:nomad).
 *   Stage 2 (parallel managers): drop /etc/nomad.d/60-vault.hcl.
 *   Stage 3 (sequential per-manager): systemctl restart nomad.service.
 *     Wait HTTPS:4646 + 200 with mgmt-token-auth. Verify the vault block
 *     is loaded via `nomad agent-info` showing the configured address.
 *
 * Selective ops: var.enable_nomad_vault_integration AND
 *                var.enable_swarm_vault_agents.
 *
 * Cross-env coupling: Stage 1 SSH to vault-1 (var.vault_1_ip) and runs
 * `vault token create -role=...` with the build host's root token.
 */

locals {
  nomad_vault_manager_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113" },
  ]
}

resource "null_resource" "nomad_vault_integration" {
  count = var.enable_nomad_vault_integration && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    rewire_id     = length(null_resource.nomad_consul_rewire) > 0 ? null_resource.nomad_consul_rewire[0].id : "disabled"
    nomad_acl_id  = length(null_resource.nomad_acl) > 0 ? null_resource.nomad_acl[0].id : "disabled"
    role_name     = var.vault_nomad_cluster_role_name
    vault_addr    = var.vault_addr
    nomad_vault_v = "2" # v2 = Stage 3 final-verification probe switched from `nomad agent-info | grep <addr>` to `curl /v1/agent/self | grep '"Addr":"https://...:8200"' + '"Enabled":true'` (the JSON API returns config.Vaults[] -- plural, mirroring Consuls[]). v1's agent-info probe never matched because Nomad's plain-text agent-info `vault` section is empty (just the header line); all vault details live in the JSON API. Same lesson as nomad_consul_rewire v3->v4. v1 = original (one-shot per-manager periodic token mint via vault-1 root token + idempotent skip-if-populated; vault{} stanza in /etc/nomad.d/60-vault.hcl; sequential rolling restart of 3 managers).
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.nomad_acl, null_resource.nomad_consul_rewire]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.swarm_node_user}'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $vaultIp   = '${var.vault_1_ip}'
      $vaultAddr = '${var.vault_addr}'
      $kvMount   = '${var.vault_kv_mount_path}'
      $roleName  = '${var.vault_nomad_cluster_role_name}'
      $keysFile  = '${local.vault_init_keys_file_expanded}'

      if (-not (Test-Path $keysFile)) {
        throw "[nomad-vault] vault init keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token
      if (-not $rootToken) { throw "[nomad-vault] root_token missing in $keysFile" }

      # Read mgmt token from Vault KV (used in Stage 3 for the
      # mgmt-token-authenticated 200-probe + agent-info verification).
      $kvReadScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault kv get -field=management_token -mount=$kvMount swarm/nomad-bootstrap-token 2>/dev/null || true
"@
      $kvReadB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvReadScript -replace "`r`n", "`n")))
      $mgmtToken = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvReadB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
      if (-not $mgmtToken -or $mgmtToken.Length -lt 36) {
        throw "[nomad-vault] could not resolve nomad mgmt token from Vault KV"
      }

      $managers = @(
%{for spec in local.nomad_vault_manager_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      $leaderIp = $managers[0].VmIp

      # ─── Stage 1 (sequential per-manager) — idempotent token mint ──────
      Write-Host ""
      Write-Host "[nomad-vault] Stage 1 -- per-manager periodic token mint (idempotent skip-if-populated)"

      foreach ($m in $managers) {
        $hostName = $m.Host
        $vmIp     = $m.VmIp

        # Probe: does /etc/nomad.d/60-vault-token.txt already exist + non-empty?
        # /etc/nomad.d/ is mode 0750 root:nomad → sudo on test (per
        # memory/feedback_sudo_required_for_consul_etc_traverse.md).
        $probe = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /etc/nomad.d/60-vault-token.txt && echo POPULATED || echo EMPTY" 2>&1 | Out-String).Trim()
        if ($probe -match 'POPULATED') {
          Write-Host "[nomad-vault $${hostName}] /etc/nomad.d/60-vault-token.txt already populated -- preserving (Nomad maintains renewal)"
          continue
        }

        Write-Host "[nomad-vault $${hostName}] minting fresh periodic token via vault-1 + role $roleName"

        # Mint a periodic token on vault-1 with the build host's root
        # token. The role's allowed_policies + period are pre-configured
        # by the security env's role-overlay-vault-nomad-jobs-policy.tf.
        $mintScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
vault token create -role='$roleName' -display-name='nomad-server-$hostName' -format=json
"@
        $mintB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($mintScript -replace "`r`n", "`n")))
        $mintOut = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$mintB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        $parsed = $null
        try { $parsed = $mintOut | ConvertFrom-Json } catch { }
        if (-not $parsed -or -not $parsed.auth -or -not $parsed.auth.client_token) {
          throw "[nomad-vault $${hostName}] vault token create did not return a parseable client_token; output:`n$mintOut"
        }
        $clientToken = $parsed.auth.client_token
        $tokenPrefix = $clientToken.Substring(0, [Math]::Min(8, $clientToken.Length))
        Write-Host "[nomad-vault $${hostName}] minted periodic token (prefix $tokenPrefix..., period=$($parsed.auth.lease_duration)s)"

        # Stage on the manager via base64+ssh. Mode 0640 root:nomad.
        # Trailing newline is fine here (Nomad parses the token file as
        # the entire content stripped of trailing whitespace).
        $stageScript = @"
set -euo pipefail
echo -n '$clientToken' | sudo tee /etc/nomad.d/60-vault-token.txt > /dev/null
sudo chown root:nomad /etc/nomad.d/60-vault-token.txt
sudo chmod 0640 /etc/nomad.d/60-vault-token.txt
echo OK
"@
        $stageB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($stageScript -replace "`r`n", "`n")))
        $stageOut = (ssh @sshOpts "$sshUser@$vmIp" "echo '$stageB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        if ($stageOut -notmatch 'OK') {
          throw "[nomad-vault $${hostName}] failed to stage 60-vault-token.txt: $stageOut"
        }
        Write-Host "[nomad-vault $${hostName}] /etc/nomad.d/60-vault-token.txt staged"
      }

      # ─── Stage 2 (parallel managers) — vault stanza config file ────────
      Write-Host ""
      Write-Host "[nomad-vault] Stage 2 -- drop /etc/nomad.d/60-vault.hcl on 3 managers (parallel)"

      $vaultStanza = @"
# 60-vault.hcl -- Phase 0.E.3.3b -- Nomad's vault{} agent stanza.
# Pairs with /etc/nomad.d/60-vault-token.txt (one-shot terraform-managed
# bootstrap token; Nomad takes over renewal post-restart).

vault {
  enabled          = true
  address          = "$vaultAddr"
  ca_file          = "/etc/vault-agent/ca-bundle.crt"
  create_from_role = "$roleName"
  token_file       = "/etc/nomad.d/60-vault-token.txt"
  task_token_ttl   = "1h"
}
"@

      $stanzaLf  = $vaultStanza -replace "`r`n", "`n"
      $stanzaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stanzaLf))

      $stage2Tmpl = @'
set -euo pipefail
echo 'STANZA_B64' | base64 -d | sudo tee /etc/nomad.d/60-vault.hcl > /dev/null
sudo chown root:nomad /etc/nomad.d/60-vault.hcl
sudo chmod 0640 /etc/nomad.d/60-vault.hcl
echo OK
'@
      $stage2LfTmpl = ($stage2Tmpl -replace 'STANZA_B64', $stanzaB64) -replace "`r`n", "`n"

      $stage2Errors = $managers | ForEach-Object -ThrottleLimit 3 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $script  = $using:stage2LfTmpl
        $out = $script | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] stage2 (60-vault.hcl drop) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage2Errors.Count -gt 0) {
        $stage2Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-vault] Stage 2 failed on $($stage2Errors.Count) manager(s)"
      }
      Write-Host "[nomad-vault] Stage 2 complete -- 60-vault.hcl staged on 3 managers"

      # ─── Stage 3 (sequential per-manager) — restart nomad ──────────────
      # Sequential rolling restart: in-config change (not a wire-format
      # flip), so sequential is safe + mirrors consul-acl Stage 5 pattern.
      Write-Host ""
      Write-Host "[nomad-vault] Stage 3 -- sequential rolling restart of nomad.service on managers"

      foreach ($m in $managers) {
        $hostName = $m.Host
        $vmIp     = $m.VmIp
        Write-Host "[nomad-vault $${hostName}] restarting nomad.service"

        $rc = ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl restart nomad.service" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $rc.Trim()
          throw "[nomad-vault $${hostName}] restart failed (rc=$LASTEXITCODE)"
        }

        # Wait for HTTPS:4646 + 200 with mgmt-token-auth.
        $deadline = (Get-Date).AddSeconds(120)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active nomad.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            $probe = (ssh @sshOpts "$sshUser@$vmIp" "curl -sS --cacert /etc/ssl/certs/nomad-ca.pem -H 'X-Nomad-Token: $mgmtToken' -o /dev/null -w '%%{http_code}' https://127.0.0.1:4646/v1/status/leader 2>&1" 2>&1 | Out-String).Trim()
            if ($probe -match '^200$') { $ready = $true; break }
          }
          Start-Sleep -Seconds 3
        }
        if (-not $ready) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nomad.service --no-pager -n 30" 2>&1 | Out-String)
          Write-Host $journal
          throw "[nomad-vault $${hostName}] HTTPS:4646 (mgmt-token authenticated) not ready within 120s"
        }
        Write-Host "[nomad-vault $${hostName}] nomad healthy with vault stanza loaded"
      }

      # ─── Cluster-wide verification ─────────────────────────────────────
      Start-Sleep -Seconds 8
      Write-Host ""
      Write-Host "[nomad-vault] verifying vault integration..."

      $nomadEnvBase = "NOMAD_ADDR=https://localhost:4646 NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem"

      $serversOut = (ssh @sshOpts "$sshUser@$leaderIp" "$nomadEnvBase NOMAD_TOKEN='$mgmtToken' nomad server members 2>&1 | grep -c alive" 2>&1 | Out-String).Trim()
      if ($serversOut -ne '3') {
        throw "[nomad-vault] expected 3 alive servers post-vault-integration, got '$serversOut'"
      }
      Write-Host "[nomad-vault] nomad server members: 3 alive"

      # Verify vault block via Nomad's JSON API. config.Vaults[] (plural --
      # Nomad 1.7+ supports multi-Vault) contains the loaded stanza; grep
      # for the configured Addr + Enabled=true as the load proof. The
      # plain-text `nomad agent-info` vault section is just the header
      # line with no body, so v1's agent-info regex was always-falsy. Same
      # pattern as the consul rewire JSON probe.
      $vaultAddrEsc = [regex]::Escape($vaultAddr)
      foreach ($m in $managers) {
        $hostName = $m.Host
        $vmIp     = $m.VmIp
        $agentSelf = (ssh @sshOpts "$sshUser@$vmIp" "curl -s --cacert /etc/ssl/certs/nomad-ca.pem -H 'X-Nomad-Token: $mgmtToken' https://127.0.0.1:4646/v1/agent/self" 2>&1 | Out-String)
        if ($agentSelf -notmatch ('"Addr":"' + $vaultAddrEsc + '"')) {
          throw "[nomad-vault $${hostName}] /v1/agent/self does NOT report Vaults[].Addr=$vaultAddr -- vault block didn't load"
        }
        if ($agentSelf -notmatch '"Enabled":true') {
          throw "[nomad-vault $${hostName}] /v1/agent/self does NOT report Vaults[].Enabled=true"
        }
        Write-Host "[nomad-vault $${hostName}] /v1/agent/self confirms Vaults[].Addr=$vaultAddr + Enabled=true"
      }

      Write-Host ""
      Write-Host "[nomad-vault] OK -- 3 Nomad managers integrated with Vault (token role $roleName, period 72h, address $vaultAddr)"
    PWSH
  }

  # Destroy: best-effort tear-down. Removes the vault stanza file + token
  # file + restart. Token in Vault is NOT explicitly revoked (would
  # require operator-side `vault token revoke` with the SecretID we
  # didn't persist). Re-apply will mint a fresh token on a clean dir.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $managerIps = @('192.168.70.111','192.168.70.112','192.168.70.113')
      foreach ($ip in $managerIps) {
        Write-Host "[nomad-vault destroy] $${ip}: removing vault stanza + token + restarting"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/nomad.d/60-vault.hcl /etc/nomad.d/60-vault-token.txt; sudo systemctl restart nomad.service" 2>$null
      }
      exit 0
    PWSH
  }
}
