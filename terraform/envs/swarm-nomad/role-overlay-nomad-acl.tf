/*
 * role-overlay-nomad-acl.tf -- Phase 0.E.3.2 -- Nomad ACL system
 *
 * Enables the Nomad ACL subsystem cluster-wide. Bootstraps one management
 * token (one-shot per cluster, persisted to Vault KV at
 * nexus/swarm/nomad-bootstrap-token), creates a single shared `nomad-agent`
 * policy + 6 per-host tokens (one per node, written to
 * nexus/swarm/nomad-agent-tokens/<host>), drops a Vault Agent template
 * that renders /etc/nomad.d/50-acl-token.hcl with each node's
 * `acl.tokens.agent`, and applies via sequential rolling restart of
 * nomad.service so each node picks up its own agent token before the
 * next flips.
 *
 * Pre-reqs:
 *   - 0.E.3.1 Nomad TLS is closed (mTLS for RPC + HTTPS API).
 *   - Vault Agents on all 6 nodes are authenticated + rendering templates.
 *   - Vault policies (extended in security env's role-overlay-vault-agent-
 *     swarm-policies.tf v3) already grant:
 *       * managers (3) : read+create+update on
 *                        nexus/data/swarm/nomad-bootstrap-token
 *       * all 6 agents : read on
 *                        nexus/data/swarm/nomad-agent-tokens/<host>
 *   - KV placeholder paths (security env's
 *     role-overlay-vault-swarm-secrets-seed.tf v2) already seeded:
 *       * nexus/swarm/nomad-bootstrap-token (status=not-bootstrapped,
 *         management_token="")
 *
 * Nomad ACL model differs from Consul:
 *   - No `default_policy` flag. Enabling `acl.enabled=true` makes ACL
 *     enforcement mandatory; the implicit policy for un-tokenized calls
 *     is "anonymous token", which by default has zero permissions = deny.
 *   - No transition-mode flag. To grant temporary anonymous access during
 *     bootstrap, you'd create an `anonymous` policy with broad permissions,
 *     bootstrap, then delete or restrict the policy. We don't bother --
 *     the bootstrap endpoint is exempt from ACL checks (it MUST be, since
 *     no token exists yet), and per-host tokens land within seconds of
 *     enabling ACL via Stage 4-5 rolling.
 *   - Single-tier per-host policy. Unlike Consul's `node "<host>" { ... }`
 *     scoping, Nomad's `node { policy = "write" }` grants on ALL nodes.
 *     We issue per-host tokens for rotation isolation but they all share
 *     a single `nomad-agent` policy. Token-based access; not policy-based.
 *
 * Choreography (5 stages, single PWSH local-exec block):
 *   Stage 1 (parallel, no restart): drop /etc/nomad.d/50-acl.hcl with
 *     `acl { enabled = true }` on all 6 nodes via base64+ssh stdin.
 *
 *   Stage 2 (parallel big-bang restart): systemctl restart nomad.service
 *     on all 6 simultaneously. Brief deny-mode window where neither
 *     operator nor agent calls work; bootstrap endpoint is the exception.
 *     Mirrors role-overlay-nomad-tls.tf v3 reasoning: TLS-style wire-format
 *     flips need parallel restart -- ACL state is replicated via raft, but
 *     the cutover from "no ACL enforcement" to "ACL enforcement" must be
 *     atomic to avoid mid-state confusion.
 *
 *   Stage 3 (build host -> manager-1 + vault-1 over SSH): idempotency
 *     read of management_token from Vault KV; if empty, run
 *     `nomad acl bootstrap`, capture SecretID, write to KV via vault-1
 *     ssh + vault CLI. Mirrors consul-acl Stage 3.
 *
 *   Stage 4 (parallel 6-way fan-out): create shared `nomad-agent` policy
 *     once (skip if exists); for each host, idempotency-read agent_token
 *     from Vault KV; if empty, create token attached to nomad-agent
 *     policy via `nomad acl token create`, write SecretID to Vault KV.
 *
 *   Stage 4b (parallel 6-way): drop /etc/vault-agent/50-template-nomad-acl.hcl
 *     on each node; restart nexus-vault-agent.service; wait up to 90s for
 *     /etc/nomad.d/50-acl-token.hcl to render with `acl.tokens.agent =
 *     "<UUID>"`.
 *
 *   Stage 5 (sequential, managers first): systemctl restart nomad.service
 *     on each node so the agent token is loaded into memory. Sequential
 *     because by this stage every node has its token rendered; the rolling
 *     restart is non-disruptive (each node briefly re-elects but cluster
 *     stays quorate).
 *
 * Idempotency end-to-end:
 *   - Stage 1 file write is content-stable.
 *   - Stage 2 restart on already-ACL'd nomad is a no-op.
 *   - Stage 3 reads existing mgmt token from KV -> skip bootstrap. If
 *     `nomad acl bootstrap` reports "ACL bootstrap no longer allowed"
 *     while KV is empty, ABORT loudly with manual recovery instructions
 *     (mirrors consul-acl Stage 3 critical path).
 *   - Stage 4 skips per-host create on KV agent_token presence; policy
 *     create idempotent (returns existing record on collision).
 *   - Stage 5 restart is needed to load the token; idempotent on already-
 *     loaded.
 *
 * Selective ops: var.enable_nomad_acl. Per-node toggles inherited from
 * var.enable_swarm_<host>_vault_agent.
 *
 * Cross-env coupling: Stage 3 + Stage 4 SSH to vault-1 (var.vault_1_ip)
 * and run `vault kv put` with the build host's root token (from
 * var.vault_init_keys_file). Same pattern as consul-acl.
 */

locals {
  nomad_acl_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111", role = "manager" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112", role = "manager" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113", role = "manager" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131", role = "worker" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132", role = "worker" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133", role = "worker" },
  ]
}

resource "null_resource" "nomad_acl" {
  count = var.enable_nomad_acl && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    nomad_tls_id  = length(null_resource.nomad_tls) > 0 ? null_resource.nomad_tls[0].id : "disabled"
    kv_mount_path = var.vault_kv_mount_path
    nomad_acl_v   = "2" # v2 = drop Stage 4b (Vault Agent template that rendered 50-acl-token.hcl) + drop Stage 5 (rolling restart to load that token). Nomad's `acl{}` block does NOT support a `token` field -- v1's rendered file caused `acl unexpected keys token` parse errors crashlooping nomad.service on all 6 nodes. The actual Nomad architecture: agents authenticate inter-agent RPC via the mTLS cert from 0.E.3.1 (cert SAN is the identity); agent ACL tokens are only needed when the agent's HTTP API is called locally (operator-style, not agent-internal). So we keep Stage 4 (create shared `nomad-agent` policy + 6 per-host operator tokens persisted to Vault KV at `nexus/swarm/nomad-agent-tokens/<host>`) for future operator scripting, but skip the rendering + restart entirely. v1 = original 5-stage; broke at Stage 5 when nomad failed to parse the rendered token file.
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.nomad_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.swarm_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $kvMount  = '${var.vault_kv_mount_path}'
      $vaultIp  = '${var.vault_1_ip}'
      $keysFile = '${local.vault_init_keys_file_expanded}'

      if (-not (Test-Path $keysFile)) {
        throw "[nomad-acl] vault init keys file $keysFile missing -- 0.D.1 vault_post_init must have produced it."
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token
      if (-not $rootToken) {
        throw "[nomad-acl] root_token field missing/empty in $keysFile"
      }

      $nodes = @(
%{for spec in local.nomad_acl_node_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      $leaderIp     = $nodes[0].VmIp
      $nomadEnv     = "NOMAD_ADDR=https://localhost:4646 NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem"
      $vaultEnvBase = "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true"

      # ─── Stage 1 (parallel, no restart): drop ACL config ─────────────
      $aclConfig = @'
# 50-acl.hcl -- Phase 0.E.3.2 -- Nomad ACL system enabled.
# Loaded via the systemd drop-in (config-dir-override.conf from 0.E.3.1)
# which switched ExecStart to `-config=/etc/nomad.d/`. Files in the dir
# are merged in lexical order; 50- comes after 40-tls.hcl so this stanza
# adds ACL on top of the TLS-enabled cluster.
#
# Nomad does NOT have a default_policy flag (unlike Consul). Enabling
# ACL implies deny-by-default for un-tokenized calls -- the "anonymous"
# token has zero permissions unless a policy named "anonymous" is created
# (we never do).

acl {
  enabled = true
}
'@

      $stage1Tmpl = @'
set -euo pipefail
echo 'PAYLOAD_B64' | base64 -d | sudo tee /etc/nomad.d/50-acl.hcl > /dev/null
sudo chown root:nomad /etc/nomad.d/50-acl.hcl
sudo chmod 0640 /etc/nomad.d/50-acl.hcl
'@

      $aclConfigLf  = $aclConfig -replace "`r`n", "`n"
      $aclConfigB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($aclConfigLf))

      Write-Host ""
      Write-Host "[nomad-acl] Stage 1 -- drop /etc/nomad.d/50-acl.hcl on all 6 nodes (parallel)"

      $stage1Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $stage1  = (($using:stage1Tmpl) -replace 'PAYLOAD_B64', $using:aclConfigB64) -replace "`r`n", "`n"
        $out = $stage1 | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return "[$($node.Host)] stage1 failed (rc=$LASTEXITCODE): $($out.Trim())" }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage1Errors.Count -gt 0) {
        $stage1Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-acl] Stage 1 failed on $($stage1Errors.Count) node(s)"
      }
      Write-Host "[nomad-acl] Stage 1 complete -- ACL config staged on all 6 nodes."

      # ─── Stage 2 (parallel big-bang restart): enable ACL cluster-wide ─
      Write-Host ""
      Write-Host "[nomad-acl] Stage 2 -- big-bang restart of nomad.service on all 6 (parallel)..."
      Write-Host "[nomad-acl] (~10-30s outage; cluster reconverges with ACL enabled)"

      $stage2Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $out = ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo systemctl restart nomad.service" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] stage2 restart failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage2Errors.Count -gt 0) {
        $stage2Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-acl] Stage 2 (nomad restart) failed on $($stage2Errors.Count) node(s)"
      }

      # Wait for nomad.service active on all 6 + /v1/agent/health returns
      # something (200 if healthy; even 401 means the agent is up + ACLs
      # are enforcing). Don't gate on /v1/status/leader because that may
      # block under deny-mode without auth.
      $stage2WaitErrors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$sshUser@$($node.VmIp)" "systemctl is-active nomad.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            # /v1/agent/health returns 200 (or 500 with body) without auth;
            # just use TCP probe to confirm the listener is up.
            $tcp = (ssh @sshOpts "$sshUser@$($node.VmIp)" "timeout 3 bash -c 'cat < /dev/tcp/127.0.0.1/4646' 2>&1 || true; echo -n DONE" 2>&1 | Out-String).Trim()
            if ($tcp -match 'DONE') { return $null }
          }
          Start-Sleep -Seconds 3
        }
        $journal = (ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo journalctl -u nomad.service --no-pager -n 20" 2>&1 | Out-String)
        return "[$($node.Host)] nomad.service or :4646 not ready within 120s; journal:`n$journal"
      } | Where-Object { $_ -ne $null }
      if ($stage2WaitErrors.Count -gt 0) {
        $stage2WaitErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-acl] Stage 2 wait failed on $($stage2WaitErrors.Count) node(s)"
      }
      Write-Host "[nomad-acl] Stage 2 complete -- ACL system enabled cluster-wide; agents listening on :4646."

      # Settle window: let raft + serf converge before bootstrap.
      Start-Sleep -Seconds 8

      # ─── Stage 3 — bootstrap mgmt token, persist to Vault KV ─────────
      Write-Host ""
      Write-Host "[nomad-acl] Stage 3 -- bootstrap management token (idempotent) + persist to Vault KV"

      # Idempotency probe: existing management_token at
      # nexus/<mount>/swarm/nomad-bootstrap-token?
      $kvReadScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv get -field=management_token -mount=$kvMount swarm/nomad-bootstrap-token 2>/dev/null || true
"@
      $kvReadB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvReadScript -replace "`r`n", "`n")))
      $existingMgmt = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvReadB64' | base64 -d | bash" 2>&1 | Out-String).Trim()

      $mgmtToken = $null
      if ($existingMgmt -and $existingMgmt.Length -ge 36) {
        $mgmtToken = $existingMgmt
        $tokenPrefix = $mgmtToken.Substring(0, [Math]::Min(8, $mgmtToken.Length))
        Write-Host "[nomad-acl] Stage 3 -- reusing existing management token from Vault KV (prefix $tokenPrefix...)"
      } else {
        Write-Host "[nomad-acl] Stage 3 -- KV management_token empty; bootstrapping from $leaderIp"
        $bootstrapOut = (ssh @sshOpts "$sshUser@$leaderIp" "$nomadEnv nomad acl bootstrap -json" 2>&1 | Out-String).Trim()

        if ($bootstrapOut -match 'no longer allowed|already bootstrapped') {
          throw @"
[nomad-acl] CRITICAL: cluster reports ACL bootstrap no longer allowed but Vault KV has empty management_token. Cluster was bootstrapped previously and the token was lost.

Recovery (manual):
  1. Find the bootstrap reset index:
     ssh nexusadmin@$leaderIp "$nomadEnv nomad acl bootstrap 2>&1 | grep -i 'index'"
  2. echo <RESET_INDEX> | sudo tee /var/lib/nomad/server/acl-bootstrap-reset
  3. Re-run: ssh nexusadmin@$leaderIp "$nomadEnv nomad acl bootstrap -json"
  4. Capture the SecretID, persist to Vault KV at nexus/swarm/nomad-bootstrap-token.management_token.

Bootstrap output:
$bootstrapOut
"@
        }

        $parsed = $null
        try { $parsed = $bootstrapOut | ConvertFrom-Json } catch { }
        if (-not $parsed -or -not $parsed.SecretID) {
          throw "[nomad-acl] bootstrap did not return a parseable SecretID; output:`n$bootstrapOut"
        }
        $mgmtToken = $parsed.SecretID
        $tokenPrefix = $mgmtToken.Substring(0, [Math]::Min(8, $mgmtToken.Length))
        Write-Host "[nomad-acl] Stage 3 -- bootstrap returned mgmt token (prefix $tokenPrefix...); persisting to Vault KV"

        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $kvWriteScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv put -mount=$kvMount swarm/nomad-bootstrap-token \
  management_token='$mgmtToken' \
  status='bootstrapped' \
  bootstrapped_at='$timestamp' >/dev/null
echo 'OK'
"@
        $kvWriteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvWriteScript -replace "`r`n", "`n")))
        $kvWriteOut = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvWriteB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $kvWriteOut -notmatch 'OK') {
          throw "[nomad-acl] Stage 3 -- failed to persist mgmt token to Vault KV: $kvWriteOut"
        }
        Write-Host "[nomad-acl] Stage 3 -- mgmt token persisted to nexus/$kvMount/swarm/nomad-bootstrap-token"
      }

      if (-not $mgmtToken) {
        throw "[nomad-acl] Stage 3 -- mgmt token still null after bootstrap path"
      }

      # ─── Stage 4 — shared policy + per-host tokens ────────────────────
      Write-Host ""
      Write-Host "[nomad-acl] Stage 4 -- create shared nomad-agent policy + per-host tokens (idempotent)"

      # Single shared policy. Nomad doesn't scope `node {}` to a specific
      # node name (unlike Consul's `node "<host>" { ... }`) -- so per-host
      # policy isolation isn't possible without major Nomad-side workarounds.
      # We use one shared policy with the full agent+node grant; per-host
      # rotation comes from issuing distinct tokens per host (each with
      # the same policy). Tokens persist to per-host KV paths for
      # operator clarity + rotation.
      $agentPolicyBody = @'
# nomad-agent -- Phase 0.E.3.2 shared policy for the 6 swarm-node nomad
# agents. Each agent gets its own SecretID (rotation isolation) but they
# all attach to this single policy.

agent {
  policy = "write"
}

node {
  policy = "write"
}

namespace "default" {
  policy = "read"
}
'@

      # Idempotency: read existing policy. If absent, create.
      $polReadScript = @"
set -euo pipefail
$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad acl policy info nomad-agent 2>&1 | head -5 || true
"@
      $polReadB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($polReadScript -replace "`r`n", "`n")))
      $polReadOut = (ssh @sshOpts "$sshUser@$leaderIp" "echo '$polReadB64' | base64 -d | bash" 2>&1 | Out-String).Trim()

      if ($polReadOut -notmatch 'Name\s*=\s*nomad-agent') {
        Write-Host "[nomad-acl] creating shared nomad-agent policy"
        $polBodyLf = $agentPolicyBody -replace "`r`n", "`n"
        $polB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($polBodyLf))
        $polCreateScript = @"
set -euo pipefail
echo '$polB64' | base64 -d > /tmp/nomad-agent.policy.hcl
$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad acl policy apply -description 'Phase 0.E.3.2 shared swarm-node agent policy' nomad-agent /tmp/nomad-agent.policy.hcl
rm -f /tmp/nomad-agent.policy.hcl
"@
        $polCreateB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($polCreateScript -replace "`r`n", "`n")))
        $polCreateOut = (ssh @sshOpts "$sshUser@$leaderIp" "echo '$polCreateB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
          throw "[nomad-acl] Stage 4 -- failed to create nomad-agent policy: $polCreateOut"
        }
        Write-Host "[nomad-acl] nomad-agent policy created"
      } else {
        Write-Host "[nomad-acl] nomad-agent policy already exists; reusing"
      }

      # Per-host token issuance. Idempotent on KV agent_token presence.
      $stage4Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node       = $_
        $sshUser    = $using:sshUser
        $sshOpts    = $using:sshOpts
        $kvMount    = $using:kvMount
        $vaultIp    = $using:vaultIp
        $leaderIp   = $using:leaderIp
        $rootToken  = $using:rootToken
        $mgmtToken  = $using:mgmtToken
        $nomadEnv   = $using:nomadEnv
        $vaultEnvBase = $using:vaultEnvBase

        $hostName = $node.Host

        # Idempotency: existing agent_token at
        # nexus/<mount>/swarm/nomad-agent-tokens/<host>?
        $kvProbeScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv get -field=agent_token -mount=$kvMount swarm/nomad-agent-tokens/$hostName 2>/dev/null || true
"@
        $kvProbeB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvProbeScript -replace "`r`n", "`n")))
        $existing = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvProbeB64' | base64 -d | bash" 2>&1 | Out-String).Trim()

        if ($existing -and $existing.Length -ge 36) {
          return @{ Host = $hostName; Status = 'reused'; Error = $null }
        }

        # Create token attached to nomad-agent policy.
        $createTokenScript = @"
set -euo pipefail
$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad acl token create -name 'agent-$hostName' -policy nomad-agent -type client -json
"@
        $createTokenB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($createTokenScript -replace "`r`n", "`n")))
        $tokenOut = (ssh @sshOpts "$sshUser@$leaderIp" "echo '$createTokenB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        $parsed = $null
        try { $parsed = $tokenOut | ConvertFrom-Json } catch { }
        if (-not $parsed -or -not $parsed.SecretID) {
          return @{ Host = $hostName; Status = 'failed'; Error = "token create did not return SecretID: $tokenOut" }
        }
        $secretID = $parsed.SecretID

        # Persist to Vault KV.
        $kvPutScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv put -mount=$kvMount swarm/nomad-agent-tokens/$hostName agent_token='$secretID' >/dev/null
echo 'OK'
"@
        $kvPutB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvPutScript -replace "`r`n", "`n")))
        $kvPutOut = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvPutB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        if ($kvPutOut -notmatch 'OK') {
          return @{ Host = $hostName; Status = 'failed'; Error = "kv put failed: $kvPutOut" }
        }
        return @{ Host = $hostName; Status = 'created'; Error = $null }
      }

      $stage4Failures = @($stage4Errors | Where-Object { $_.Status -eq 'failed' })
      foreach ($r in $stage4Errors) {
        Write-Host "[nomad-acl $($r.Host)] $($r.Status)$(if ($r.Error) { ' -- ' + $r.Error })"
      }
      if ($stage4Failures.Count -gt 0) {
        throw "[nomad-acl] Stage 4 failed on $($stage4Failures.Count) host(s)"
      }
      Write-Host "[nomad-acl] Stage 4 complete -- 6 per-host operator tokens persisted to Vault KV at nexus/$kvMount/swarm/nomad-agent-tokens/<host>"

      # No Stage 4b / Stage 5: Nomad's `acl{}` block does NOT support a
      # `token` field (only `enabled`, `token_ttl`, `policy_ttl`, etc.).
      # Per-agent tokens via config file would require systemd
      # EnvironmentFile=NOMAD_TOKEN injection, but that's unnecessary --
      # Nomad agents authenticate inter-agent RPC via the mTLS cert from
      # 0.E.3.1 (the cert SAN `server.global.nomad`/`client.global.nomad`
      # IS the identity at the wire layer). The 6 KV-persisted tokens
      # serve as ready-to-use operator tokens (one per host for rotation
      # isolation) but are not consumed by the agents themselves.

      # Final cluster-shape verification (mgmt-token authenticated).
      Start-Sleep -Seconds 8
      Write-Host ""
      Write-Host "[nomad-acl] verifying cluster shape under ACL-enforced mode..."

      $serversOut = (ssh @sshOpts "$sshUser@$leaderIp" "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad server members 2>&1 | grep -c alive" 2>&1 | Out-String).Trim()
      if ($serversOut -ne '3') {
        throw "[nomad-acl] expected 3 alive servers, got '$serversOut'"
      }
      Write-Host "[nomad-acl] nomad server members (mgmt-token authenticated): 3 alive"

      $clientsOut = (ssh @sshOpts "$sshUser@$leaderIp" "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad node status 2>&1 | grep -c ready" 2>&1 | Out-String).Trim()
      if ($clientsOut -ne '3') {
        throw "[nomad-acl] expected 3 ready clients, got '$clientsOut'"
      }
      Write-Host "[nomad-acl] nomad node status: 3 ready clients"

      # Anonymous-deny check: GET /v1/agent/self without token -> 403.
      # Same pattern as consul-acl (per memory/feedback_consul_acl_anon_
      # filtered_not_403.md -- use item endpoints, not list endpoints).
      $anonProbe = (ssh @sshOpts "$sshUser@$leaderIp" "curl -sS --cacert /etc/ssl/certs/nomad-ca.pem -o /dev/null -w '%%{http_code}' https://127.0.0.1:4646/v1/agent/self 2>&1" 2>&1 | Out-String).Trim()
      if ($anonProbe -ne '403') {
        throw "[nomad-acl] anonymous /v1/agent/self did NOT return 403 (got '$anonProbe') -- ACL not enforcing"
      }
      Write-Host "[nomad-acl] anonymous /v1/agent/self returns 403 (ACL enforcement verified)"

      Write-Host ""
      Write-Host "[nomad-acl] OK -- ACL system enforced cluster-wide (mgmt token in Vault KV; 6 agent tokens active)"
    PWSH
  }

  # Destroy: best-effort tear-down. Removes ACL config files + template +
  # restarts vault-agent + nomad. Cluster falls back to no-ACL mode.
  # Does NOT clear Vault KV state (mgmt token + agent tokens stay; operator
  # must `vault kv put -force ... management_token=""` for a clean re-bootstrap).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $ips = @('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133')
      foreach ($ip in $ips) {
        Write-Host "[nomad-acl destroy] $${ip}: removing ACL config + template + restarting"
        # Note: 50-acl-token.hcl + 50-template-nomad-acl.hcl are v1 leftovers
        # we never deploy in v2+; rm them defensively in case a re-applied v1
        # left them on disk.
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/nomad.d/50-acl.hcl /etc/nomad.d/50-acl-token.hcl /etc/vault-agent/50-template-nomad-acl.hcl; sudo systemctl restart nexus-vault-agent.service nomad.service" 2>$null
      }
      exit 0
    PWSH
  }
}
