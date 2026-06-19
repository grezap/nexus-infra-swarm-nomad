/*
 * role-overlay-consul-acl.tf -- Phase 0.E.2.3 -- Consul ACL system
 *
 * Enables the Consul ACL subsystem cluster-wide with default_policy="deny"
 * + down_policy="extend-cache" + enable_token_persistence=true. Bootstraps
 * one management token (one-shot per cluster, persisted to Vault KV at
 * nexus/swarm/consul-bootstrap-token), creates 6 per-agent policies +
 * tokens (one per node, written to nexus/swarm/agent-tokens/<host>), drops
 * a Vault Agent template that renders /etc/consul.d/30-acl-token.hcl with
 * each node's `acl.tokens.agent` + `acl.tokens.default`, and tightens to
 * deny-mode via a sequential rolling restart.
 *
 * Pre-reqs:
 *   - 0.E.2.2 Consul TLS is applied (mTLS RPC + HTTPS:8501).
 *   - Vault Agents on all 6 nodes are authenticated + rendering templates.
 *   - Vault policies (provisioned by nexus-infra-vmware/terraform/envs/
 *     security/role-overlay-vault-agent-swarm-policies.tf) already grant:
 *       * all 6 agents : read on nexus/data/swarm/agent-tokens/<host>
 *       * managers (3) : read+create+update on nexus/data/swarm/consul-
 *                        bootstrap-token (uniform-fleet read for workers
 *                        is intentional only for managers; workers don't
 *                        need to know the mgmt token).
 *   - KV placeholder paths nexus/swarm/consul-bootstrap-token (status=
 *     not-bootstrapped, management_token="") + nexus/swarm/consul-gossip-
 *     key already seeded (sticky pattern, security env owns).
 *
 * Bootstrap chicken-and-egg (transition-mode pattern):
 *   ACLs need to be enabled cluster-wide BEFORE `consul acl bootstrap` can
 *   succeed (it requires acl.enabled=true). With default_policy="deny" from
 *   the start, agents lock out before they have tokens -- registration +
 *   health checks fail until each agent is issued + reads its token. We
 *   solve this in two passes:
 *
 *     Pass 1 (Stage 1+2): default_policy="allow" -- ACL system enabled
 *       cluster-wide, but anonymous calls are still permitted. Cluster
 *       runs normally. Bootstrap (Stage 3) + per-host token issue (Stage 4)
 *       happen in this safer regime.
 *     Pass 2 (Stage 5): default_policy="deny" -- after every node has its
 *       agent token rendered into /etc/consul.d/30-acl-token.hcl by Vault
 *       Agent, sequentially restart consul on each (managers first) to
 *       pick up the tightened policy. With the agent token already in
 *       place per node, the deny-mode flip is non-disruptive per node.
 *
 *   Pattern A (transition-mode) is preferred over Pattern B (single-pass
 *   deny + race) because (a) blast radius of a token-issue failure is
 *   isolated to one node instead of the whole cluster, (b) Stage 4 can
 *   be retried freely without touching consul state, (c) the extra
 *   rolling restart is ~3 min vs hours of recovery if Pattern B drops
 *   the cluster into deny-without-tokens.
 *
 * Stages (single PWSH local-exec block):
 *   Stage 1 (parallel, no restart): drop /etc/consul.d/30-acl.hcl in
 *     allow-mode on all 6 nodes via base64+ssh stdin.
 *   Stage 2 (sequential per-node, managers first): systemctl restart
 *     consul.service; wait for HTTPS:8501 active. Cluster reconverges
 *     with ACL system enabled, default_policy=allow, no tokens yet.
 *   Stage 3 (build host -> vault-1 + manager-1 over SSH): idempotency
 *     read of management_token from Vault KV; if empty, run `consul acl
 *     bootstrap` from manager-1 (forwards to leader internally), capture
 *     SecretID, write to KV via vault-1 ssh + vault CLI.
 *   Stage 4 (parallel 6-way fan-out): for each host, idempotency-read
 *     agent token from Vault KV; if empty, create policy `agent-<host>`
 *     + token via `consul acl policy/token create` from manager-1
 *     authenticated with the mgmt token, write SecretID to Vault KV at
 *     nexus/swarm/agent-tokens/<host>.
 *   Stage 4b (parallel 6-way): drop /etc/vault-agent/30-template-acl.hcl
 *     on each node, restart nexus-vault-agent.service, wait up to 60s for
 *     /etc/consul.d/30-acl-token.hcl to render with `agent =` + `default
 *     =` substrings present.
 *   Stage 5 (sequential per-node, managers first): in-place patch
 *     /etc/consul.d/30-acl.hcl to flip default_policy "allow" -> "deny",
 *     systemctl restart consul.service, wait for HTTPS:8501 = 200 with
 *     mgmt-token authenticated GET. Per-node 60s settle.
 *
 * Idempotency end-to-end:
 *   - Stage 1: file write is content-stable.
 *   - Stage 2: restart on already-restarted node is a no-op (config
 *     unchanged).
 *   - Stage 3: re-applies read existing mgmt token from KV + skip
 *     bootstrap. If consul reports "ACL bootstrap no longer allowed"
 *     while KV is empty (bootstrap-without-persistence regression), we
 *     ABORT loudly -- recovery requires `consul acl bootstrap-reset` +
 *     manual ops, which we don't auto-perform.
 *   - Stage 4: per-host check on KV agent_token presence AND self-validation
 *     against the live Consul (token read -self); reuse only if it resolves,
 *     else re-create (a cold rebuild has a fresh Consul but persisted KV). skip create
 *     if populated. Policy create is idempotent: `consul acl policy
 *     create` with an existing name returns the existing record's
 *     ID (we treat that as success).
 *   - Stage 5: sed is a no-op when already deny-mode.
 *
 * Selective ops: var.enable_consul_acl. Per-node toggles are inherited
 *   from var.enable_swarm_<host>_vault_agent (we follow the rendered
 *   set; if a host is opted out, it's skipped end-to-end).
 *
 * Cross-env coupling: Stage 3 + Stage 4 SSH to vault-1 (192.168.70.121
 *   by default; override via var.vault_1_ip) and run `vault kv put` with
 *   the build host's root token (read from var.vault_init_keys_file).
 *   This mirrors nexus-infra-vmware/terraform/envs/security/role-overlay-
 *   vault-swarm-secrets-seed.tf's pattern -- the swarm-nomad env is
 *   responsible for state that lives logically in Vault KV.
 */

locals {
  consul_acl_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111", role = "manager" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112", role = "manager" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113", role = "manager" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131", role = "worker" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132", role = "worker" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133", role = "worker" },
  ]

  # Reuse the path-expansion convention from role-overlay-swarm-vault-agents.tf
  # (terraform pathexpand handles ~ but not $HOME; substitute first).
  vault_init_keys_file_expanded = pathexpand(replace(var.vault_init_keys_file, "$HOME", "~"))
}

resource "null_resource" "consul_acl" {
  count = var.enable_consul_acl && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    tls_id        = length(null_resource.consul_tls) > 0 ? null_resource.consul_tls[0].id : "disabled"
    kv_mount_path = var.vault_kv_mount_path
    consul_acl_v  = "6" # v6 (2026-06-20) = Stage 4 self-validates the KV agent token against the LIVE Consul (mirrors Stage 3's mgmt-token validation) before "reusing" it. THE BUG: Stage 4 idempotency was keyed on Vault-KV presence alone, but Vault KV persists across a swarm destroy/apply while the Consul cluster is rebuilt fresh -- so a cold rebuild "reused" stale KV agent tokens and never created the 6 agent policies/tokens in the new Consul (smoke 0.E.2.3 "6 agent-* policies / >=7 tokens" failed). Surfaced by the 2026-06-20 Portainer-fix cold rebuild (the FIRST swarm cold rebuild where the KV agent tokens already existed from a prior successful rebuild). Same class as [[feedback_cold_rebuild_stale_kv_tokens]]. v5 = anonymous-deny verify probe switches from `consul members` (returns empty under deny -- Consul filters node:read per node, returns empty array; doesn't actually error so a regex like 'Permission denied' never matches) to curl /v1/agent/self (requires agent:read; anonymous in deny-mode returns explicit HTTP 403 + permission-denied body -- single unambiguous signal). v4 = drop tokens.default from rendered 30-acl-token.hcl (was scope creep -- the local agent transparently falls back to tokens.default for un-tokenized API calls, which silently bypassed default_policy=deny enforcement and broke the in-overlay anonymous-deny verification probe; user spec called for tokens.agent only, so the cluster now requires explicit CONSUL_HTTP_TOKEN on every operator call). v3 = sudo on `test -s` in the Stage 4b render-wait probe (/etc/consul.d/ is mode 0750 root:consul; nexusadmin can't traverse so the bare `test -s` always failed EACCES and the probe reported MISSING -- looped to 90s timeout despite the file being correctly rendered). v2 = fix regex in Stage 4 policy verify (consul `policy read -format=json` emits `"ID": "<uuid>"` with space after colon, not `"ID":"<uuid>"` -- v1 regex never matched, treated successful policy create as failure on every host) + heredoc-piped probe in Stage 4b wait (PS double-quote string can't carry `\"` -- terminates string at the backslash; switched to heredoc-piped pattern). v1 = original (5-stage transition-mode pattern; allow-mode bootstrap then deny-mode rolling restart with rendered agent tokens).
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.consul_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.swarm_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $kvMount  = '${var.vault_kv_mount_path}'
      $vaultIp  = '${var.vault_1_ip}'
      $keysFile = '${local.vault_init_keys_file_expanded}'

      # ── Resolve build-host root token (used to authenticate vault CLI on
      #    vault-1 for the KV writes). Throw clearly if the sidecar is
      #    missing -- without it we can't persist the bootstrap token.
      if (-not (Test-Path $keysFile)) {
        throw "[consul-acl] vault init keys file $keysFile missing -- 0.D.1 vault_post_init must have produced it. Run nexus-infra-vmware/scripts/security.ps1 apply first."
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token
      if (-not $rootToken) {
        throw "[consul-acl] root_token field missing/empty in $keysFile"
      }

      # ── Per-node specs (sequential apply order: managers first) ────────
      $nodes = @(
%{for spec in local.consul_acl_node_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # The leader proxy: any manager forwards `consul acl ...` to the
      # current Raft leader internally. We pin to manager-1 for stability.
      $leaderIp     = $nodes[0].VmIp   # 192.168.70.111 by spec order
      $envPrefix    = "CONSUL_HTTP_ADDR=https://localhost:8501 CONSUL_CACERT=/etc/ssl/certs/consul-ca.pem"
      $vaultEnvBase = "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true"

      # ── Stage 1 payloads (allow-mode ACL config) ───────────────────────
      $aclConfigAllow = @'
# 30-acl.hcl -- Phase 0.E.2.3 -- ACL system (transition mode -> deny in
# Stage 5 of the same overlay run). Renders alongside 10-encrypt.hcl
# (gossip) + 20-tls.hcl in /etc/consul.d/. Keys here are NEW to the
# ports/tls config -- HCL config-dir merge ADDS new keys correctly (see
# memory/feedback_consul_hcl_ports_merge_no_override.md; the ports.http
# scalar-override case is the exception, not the rule).

acl {
  enabled                  = true
  default_policy           = "allow"
  down_policy              = "extend-cache"
  enable_token_persistence = true
}
'@

      $stage1Tmpl = @'
set -euo pipefail
echo 'PAYLOAD_B64' | base64 -d | sudo tee /etc/consul.d/30-acl.hcl > /dev/null
sudo chown root:consul /etc/consul.d/30-acl.hcl
sudo chmod 0640 /etc/consul.d/30-acl.hcl
'@

      $aclAllowLf  = $aclConfigAllow -replace "`r`n", "`n"
      $aclAllowB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($aclAllowLf))

      Write-Host ""
      Write-Host "[consul-acl] Stage 1 -- drop /etc/consul.d/30-acl.hcl (allow-mode) on all 6 nodes (parallel)"

      $stage1Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $stage1Script = (($using:stage1Tmpl) -replace 'PAYLOAD_B64', $using:aclAllowB64) -replace "`r`n", "`n"
        $out = $stage1Script | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return "[$($node.Host)] stage1 (acl config drop) failed (rc=$LASTEXITCODE): $($out.Trim())" }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage1Errors.Count -gt 0) {
        $stage1Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[consul-acl] Stage 1 failed on $($stage1Errors.Count) node(s)"
      }
      Write-Host "[consul-acl] Stage 1 complete -- ACL config staged on all 6 nodes."

      # ── Stage 2 (sequential per-node) — restart consul.service ────────
      Write-Host ""
      Write-Host "[consul-acl] Stage 2 -- sequential rolling restart of consul.service (managers first)"
      foreach ($node in $nodes) {
        $nodeHost = $node.Host
        $vmIp     = $node.VmIp
        Write-Host "[consul-acl $${nodeHost}] restarting consul.service (allow-mode ACL)"

        $rc = ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl restart consul.service" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $rc.Trim()
          throw "[consul-acl $${nodeHost}] restart failed (rc=$LASTEXITCODE)"
        }

        # Wait for HTTPS:8501 to return 200 again (max 90s -- consul rejoin
        # plus ACL system warm-up; allow-mode means anon GET succeeds).
        $deadline = (Get-Date).AddSeconds(90)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active consul.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            $probe = (ssh @sshOpts "$sshUser@$vmIp" "curl -sS --cacert /etc/ssl/certs/consul-ca.pem -o /dev/null -w '%%{http_code}' https://127.0.0.1:8501/v1/status/leader 2>&1" 2>&1 | Out-String).Trim()
            if ($probe -match '^200$') { $ready = $true; break }
          }
          Start-Sleep -Seconds 3
        }
        if (-not $ready) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u consul.service --no-pager -n 30" 2>&1 | Out-String)
          Write-Host $journal
          throw "[consul-acl $${nodeHost}] HTTPS:8501 not ready within 90s after restart"
        }
        Write-Host "[consul-acl $${nodeHost}] consul healthy with ACL=allow"
      }
      Write-Host "[consul-acl] Stage 2 complete -- ACL system enabled cluster-wide (allow mode)."

      # Settle period: let ACL state propagate via Raft to all 3 servers.
      Start-Sleep -Seconds 8

      # ── Stage 3 — bootstrap mgmt token, persist to Vault KV ───────────
      Write-Host ""
      Write-Host "[consul-acl] Stage 3 -- bootstrap management token (idempotent) + persist to Vault KV"

      # Idempotency probe: read management_token from KV. Quoted root token
      # via base64-encoded inner script avoids exposing it in argv.
      $kvReadScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv get -field=management_token -mount=$kvMount swarm/consul-bootstrap-token 2>/dev/null || true
"@
      $kvReadB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvReadScript -replace "`r`n", "`n")))
      $existingMgmt = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvReadB64' | base64 -d | bash" 2>&1 | Out-String).Trim()

      $mgmtToken = $null
      if ($existingMgmt -and $existingMgmt.Length -ge 36) {
        # VALIDATE the KV token against the LIVE cluster before trusting it.
        # Cold-rebuild fleet audit 2026-05-22 (the documented manual KV-wipe
        # BLOCKER): on a destroy+apply the VMs are re-cloned (fresh consul
        # state) but the OLD management token persists in Vault KV. Blindly
        # reusing it -> every subsequent ACL call fails against the fresh
        # cluster (Stage 5 verify: "expected 6 alive, got 0"). Self-validate
        # via `consul acl token read -self`; if it doesn't resolve on the live
        # cluster the token is stale -> fall through to (re-)bootstrap, which
        # works because the fresh cluster has never been bootstrapped.
        $valScript = @"
export VAULT_TOKEN='$rootToken'
$envPrefix CONSUL_HTTP_TOKEN='$existingMgmt' consul acl token read -self -format=json 2>&1 || true
"@
        $valB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($valScript -replace "`r`n", "`n")))
        $valOut = (ssh @sshOpts "$sshUser@$leaderIp" "echo '$valB64' | base64 -d | bash" 2>&1 | Out-String)
        if ($valOut -match '"AccessorID"' -or $valOut -match '"SecretID"') {
          $mgmtToken = $existingMgmt
          $tokenPrefix = $mgmtToken.Substring(0, [Math]::Min(8, $mgmtToken.Length))
          Write-Host "[consul-acl] Stage 3 -- KV management token validated against live cluster (prefix $tokenPrefix...); reusing"
        } else {
          Write-Host "[consul-acl] Stage 3 -- KV management token is STALE (failed self-validation on the live cluster -- destroy+rebuild leftover); discarding + re-bootstrapping"
        }
      }
      if (-not $mgmtToken) {
        Write-Host "[consul-acl] Stage 3 -- bootstrapping management token from $leaderIp"
        $bootstrapOut = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix consul acl bootstrap -format=json" 2>&1 | Out-String).Trim()
        # Two failure modes:
        # (a) "ACL bootstrap no longer allowed" -- consul has been bootstrapped
        #     before but KV doesn't have the token (regression / human op).
        #     ABORT loudly; manual recovery required (consul acl bootstrap-reset
        #     + re-bootstrap, then `vault kv put` the new token).
        # (b) other error -- network / consul restart didn't take.
        if ($bootstrapOut -match 'no longer allowed') {
          throw @"
[consul-acl] CRITICAL: cluster reports 'ACL bootstrap no longer allowed' but Vault KV has empty management_token. The cluster was bootstrapped previously and the token was lost.

Recovery (manual):
  1. ssh to a server, find the bootstrap reset index:
     ssh nexusadmin@$leaderIp "sudo journalctl -u consul.service | grep -i 'bootstrap reset' | tail -5"
  2. echo <RESET_INDEX> | sudo tee /etc/consul.d/acl-bootstrap-reset
  3. ssh nexusadmin@$leaderIp "$envPrefix consul acl bootstrap -format=json"
  4. Capture the SecretID and persist it to Vault KV at nexus/swarm/consul-bootstrap-token.management_token

Bootstrap output was:
$bootstrapOut
"@
        }
        $parsed = $null
        try { $parsed = $bootstrapOut | ConvertFrom-Json } catch { }
        if (-not $parsed -or -not $parsed.SecretID) {
          throw "[consul-acl] bootstrap did not return a parseable SecretID; output:`n$bootstrapOut"
        }
        $mgmtToken = $parsed.SecretID
        $tokenPrefix = $mgmtToken.Substring(0, [Math]::Min(8, $mgmtToken.Length))
        Write-Host "[consul-acl] Stage 3 -- bootstrap returned mgmt token (prefix $tokenPrefix...); persisting to Vault KV"

        # Persist to vault-1 KV. Use base64-encoded inner script to keep the
        # secret out of ssh.exe argv.
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $kvWriteScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv put -mount=$kvMount swarm/consul-bootstrap-token \
  management_token='$mgmtToken' \
  status='bootstrapped' \
  bootstrapped_at='$timestamp' >/dev/null
echo 'OK'
"@
        $kvWriteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvWriteScript -replace "`r`n", "`n")))
        $kvWriteOut = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvWriteB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $kvWriteOut -notmatch 'OK') {
          throw "[consul-acl] Stage 3 -- failed to persist mgmt token to Vault KV: $kvWriteOut"
        }
        Write-Host "[consul-acl] Stage 3 -- mgmt token persisted to nexus/$kvMount/swarm/consul-bootstrap-token"
      }

      if (-not $mgmtToken) {
        throw "[consul-acl] Stage 3 -- mgmt token still null after bootstrap path; aborting"
      }

      # ── Stage 4 — per-host policies + agent tokens (parallel 6-way) ───
      Write-Host ""
      Write-Host "[consul-acl] Stage 4 -- per-host policies + agent tokens (idempotent, parallel)"

      # Policy body template -- HOSTNAME placeholder substituted per-host.
      $agentPolicyTmpl = @'
node "HOSTNAME" {
  policy = "write"
}
agent "HOSTNAME" {
  policy = "write"
}
service_prefix "" {
  policy = "read"
}
node_prefix "" {
  policy = "read"
}
'@

      $stage4Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node       = $_
        $sshUser    = $using:sshUser
        $sshOpts    = $using:sshOpts
        $kvMount    = $using:kvMount
        $vaultIp    = $using:vaultIp
        $leaderIp   = $using:leaderIp
        $rootToken  = $using:rootToken
        $mgmtToken  = $using:mgmtToken
        $envPrefix  = $using:envPrefix
        $vaultEnvBase = $using:vaultEnvBase
        $polTmpl    = $using:agentPolicyTmpl

        $hostName   = $node.Host
        $policyName = "agent-$hostName"

        # Idempotency: existing agent_token at nexus/<mount>/swarm/agent-tokens/<host>?
        $kvProbeScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv get -field=agent_token -mount=$kvMount swarm/agent-tokens/$hostName 2>/dev/null || true
"@
        $kvProbeB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvProbeScript -replace "`r`n", "`n")))
        $existing = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvProbeB64' | base64 -d | bash" 2>&1 | Out-String).Trim()

        if ($existing -and $existing.Length -ge 36) {
          # Self-validate the KV agent token against the LIVE Consul cluster
          # (mirrors Stage 3's mgmt-token validation). On a COLD REBUILD the
          # Consul cluster is brand-new (no ACL tokens yet) but Vault KV
          # PERSISTS -- so a KV-present agent token may not exist in the fresh
          # Consul. Reuse only if it actually resolves via `token read -self`;
          # otherwise fall through to re-create the policy + token (overwriting
          # the stale KV value). Without this, a cold rebuild leaves the fresh
          # Consul with zero agent policies/tokens. [[feedback_cold_rebuild_stale_kv_tokens]]
          $valScript = @"
set -euo pipefail
$envPrefix CONSUL_HTTP_TOKEN='$existing' consul acl token read -self -format=json 2>&1 || true
"@
          $valB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($valScript -replace "`r`n", "`n")))
          $valOut = (ssh @sshOpts "$sshUser@$leaderIp" "echo '$valB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
          if ($valOut -match '"SecretID"') {
            return @{ Host = $hostName; Status = 'reused'; Error = $null }
          }
          Write-Host "[consul-acl] Stage 4 -- $hostName KV agent token is STALE (not present in the live Consul -- cold-rebuild leftover); re-creating policy + token"
        }

        # Create policy (idempotent: if it exists, `consul acl policy create`
        # returns "Failed ACL policy creation: ... Invalid Policy: A Policy
        # with Name 'agent-X' already exists" -- treat as success).
        $polBody = $polTmpl -replace 'HOSTNAME', $hostName
        $polB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($polBody -replace "`r`n", "`n")))
        # Combined create+read script. Both consul commands emit the policy
        # ID in their output (text-format `ID:           <uuid>` from create;
        # `"ID": "<uuid>"` from read -format=json with a space after colon
        # which is why the v1 regex `"ID":"<uuid>"` failed -- consul's JSON
        # output is pretty-printed). Match a bare UUID anywhere in the
        # combined output. Re-applies see "policy already exists" on create
        # but the trailing read still returns the existing record's UUID.
        $createPolScript = @"
set -euo pipefail
$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' bash -c 'echo "$polB64" | base64 -d | consul acl policy create -name "$policyName" -rules - 2>&1 || true' | head -20
$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul acl policy read -name "$policyName" 2>/dev/null | head -10 || true
"@
        $createPolB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($createPolScript -replace "`r`n", "`n")))
        $polOut = (ssh @sshOpts "$sshUser@$leaderIp" "echo '$createPolB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        if ($polOut -notmatch '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') {
          return @{ Host = $hostName; Status = 'failed'; Error = "policy create/verify failed: $polOut" }
        }

        # Create token attached to the policy. Token create is NOT idempotent
        # in Consul (every call mints a fresh accessor + secret). We've
        # already idempotency-gated above on KV agent_token presence, so we
        # only reach here when truly absent.
        $createTokenScript = @"
set -euo pipefail
$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul acl token create -policy-name "$policyName" -description "agent token for $hostName (Phase 0.E.2.3)" -format=json
"@
        $createTokenB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($createTokenScript -replace "`r`n", "`n")))
        $tokenOut = (ssh @sshOpts "$sshUser@$leaderIp" "echo '$createTokenB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        $parsed = $null
        try { $parsed = $tokenOut | ConvertFrom-Json } catch { }
        if (-not $parsed -or -not $parsed.SecretID) {
          return @{ Host = $hostName; Status = 'failed'; Error = "token create did not return SecretID: $tokenOut" }
        }
        $secretID = $parsed.SecretID

        # Persist to Vault KV at nexus/<mount>/swarm/agent-tokens/<host>.
        $kvPutScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
$vaultEnvBase vault kv put -mount=$kvMount swarm/agent-tokens/$hostName agent_token='$secretID' >/dev/null
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
        Write-Host "[consul-acl $($r.Host)] $($r.Status)$(if ($r.Error) { ' -- ' + $r.Error })"
      }
      if ($stage4Failures.Count -gt 0) {
        throw "[consul-acl] Stage 4 failed on $($stage4Failures.Count) host(s)"
      }
      Write-Host "[consul-acl] Stage 4 complete -- 6 agent tokens present in Vault KV at nexus/$kvMount/swarm/agent-tokens/<host>"

      # ── Stage 4b — drop Vault Agent template, restart vault-agent ─────
      Write-Host ""
      Write-Host "[consul-acl] Stage 4b -- drop /etc/vault-agent/30-template-acl.hcl + render 30-acl-token.hcl on all 6 (parallel)"

      # Per-host Vault Agent template (HOSTNAME placeholder substituted in
      # the parallel block). The destination 30-acl-token.hcl renders into
      # /etc/consul.d/, merged into the running consul config on next reload
      # (Stage 5 restart picks it up). The template uses {{ with secret ... }}
      # so an empty/missing KV path renders an empty file (which consul
      # tolerates -- it's just an extra empty config file). Once Stage 4
      # has populated the KV path, the next Vault Agent render picks it up.
      $vaTmplBody = @'
# 30-template-acl.hcl -- Phase 0.E.2.3 (rendered for HOSTNAME)
# Vault Agent template that fetches this node's Consul agent token from
# nexus/data/swarm/agent-tokens/HOSTNAME and writes /etc/consul.d/30-acl-
# token.hcl with the acl.tokens.agent block ONLY. We deliberately do NOT
# set acl.tokens.default -- if the local agent had a default token, every
# anonymous HTTP API call would silently fall back to it (transparent
# operator authentication), which undermines default_policy=deny at the
# agent-fallback layer. With tokens.default unset, anonymous calls use
# Consul's built-in anonymous token (empty policy under default_policy=
# deny -> denied). Operators must provide CONSUL_HTTP_TOKEN explicitly.

template {
  contents = <<EOT
{{ with secret "KVMOUNT/data/swarm/agent-tokens/HOSTNAME" }}acl {
  tokens {
    agent = "{{ .Data.data.agent_token }}"
  }
}
{{ end }}
EOT

  destination = "/etc/consul.d/30-acl-token.hcl"
  perms       = "0640"
  user        = "root"
  group       = "consul"
}
'@

      $stage4bScriptTmpl = @'
set -euo pipefail
echo 'TPL_B64' | base64 -d | sudo tee /etc/vault-agent/30-template-acl.hcl > /dev/null
sudo chown root:root /etc/vault-agent/30-template-acl.hcl
sudo chmod 0644 /etc/vault-agent/30-template-acl.hcl
sudo systemctl restart nexus-vault-agent.service
'@

      $stage4bErrors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node     = $_
        $sshUser  = $using:sshUser
        $sshOpts  = $using:sshOpts
        $kvMount  = $using:kvMount
        $tplBase  = $using:vaTmplBody
        $tplStage = $using:stage4bScriptTmpl

        $hostName = $node.Host
        $rendered = ($tplBase -replace 'HOSTNAME', $hostName) -replace 'KVMOUNT', $kvMount
        $renderedLf = $rendered -replace "`r`n", "`n"
        $tplB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($renderedLf))
        $script = (($tplStage -replace 'TPL_B64', $tplB64)) -replace "`r`n", "`n"

        $out = $script | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$hostName] stage4b (template drop + vault-agent restart) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage4bErrors.Count -gt 0) {
        $stage4bErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[consul-acl] Stage 4b failed on $($stage4bErrors.Count) node(s)"
      }

      # Wait for /etc/consul.d/30-acl-token.hcl to render with non-empty
      # tokens on all 6. Vault Agent typically renders within 5-10s after
      # restart; allow 60s for slow nodes. The probe script is sent via
      # stdin (heredoc-piped pattern) to avoid PS double-quoted string
      # parser collisions with `\"` (PS doesn't escape `\"`; it uses
      # backtick-quote `"). Probe checks: file non-empty + contains an
      # `agent   = "<UUID>"` line where the UUID is at least 8 chars.
      # Both test + grep MUST be sudo'd because /etc/consul.d/ is mode
      # 0750 root:consul -- nexusadmin can't even traverse there without
      # elevation, so a bare `test -s` always fails EACCES and reports
      # MISSING (the v2 bug -- v3 wraps both file ops in sudo).
      $renderProbeScript = @'
set -euo pipefail
if sudo test -s /etc/consul.d/30-acl-token.hcl; then
  if sudo grep -qE 'agent[[:space:]]+=[[:space:]]+"[A-Za-z0-9-]{8,}"' /etc/consul.d/30-acl-token.hcl; then
    echo OK
  else
    echo NOT_RENDERED
  fi
else
  echo MISSING
fi
'@
      $stage4bWaitErrors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $probe   = ($using:renderProbeScript) -replace "`r`n", "`n"
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
          $check = ($probe | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String).Trim()
          if ($check -match 'OK') { return $null }
          Start-Sleep -Seconds 3
        }
        $journal = (ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        return "[$($node.Host)] /etc/consul.d/30-acl-token.hcl never rendered with non-empty agent token within 90s; journal:`n$journal"
      } | Where-Object { $_ -ne $null }
      if ($stage4bWaitErrors.Count -gt 0) {
        $stage4bWaitErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[consul-acl] Stage 4b render-wait failed on $($stage4bWaitErrors.Count) node(s)"
      }
      Write-Host "[consul-acl] Stage 4b complete -- /etc/consul.d/30-acl-token.hcl rendered on all 6 nodes"

      # ── Stage 5 — tighten to deny + sequential rolling restart ────────
      Write-Host ""
      Write-Host "[consul-acl] Stage 5 -- tighten default_policy 'allow' -> 'deny' + sequential rolling restart (managers first)"

      foreach ($node in $nodes) {
        $nodeHost = $node.Host
        $vmIp     = $node.VmIp
        Write-Host "[consul-acl $${nodeHost}] tightening to deny + restart"

        $tightenScript = @'
set -euo pipefail
sudo sed -i 's/default_policy *= *"allow"/default_policy = "deny"/' /etc/consul.d/30-acl.hcl
if ! sudo grep -q 'default_policy *= *"deny"' /etc/consul.d/30-acl.hcl; then
  echo "[stage5] ERROR: sed did not flip default_policy in /etc/consul.d/30-acl.hcl" >&2
  sudo cat /etc/consul.d/30-acl.hcl >&2
  exit 1
fi
sudo systemctl restart consul.service
'@
        $tightenLf  = $tightenScript -replace "`r`n", "`n"
        $tightenB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($tightenLf))
        $out = (ssh @sshOpts "$sshUser@$vmIp" "echo '$tightenB64' | base64 -d | bash" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
          Write-Host $out.Trim()
          throw "[consul-acl $${nodeHost}] tighten+restart failed (rc=$LASTEXITCODE)"
        }

        # Wait for HTTPS:8501 to return 200 with mgmt-token-authenticated GET.
        # Anonymous GET should return 403/Permission denied at this point
        # (deny-mode), but the authenticated probe must still succeed.
        $deadline = (Get-Date).AddSeconds(120)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active consul.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            $probe = (ssh @sshOpts "$sshUser@$vmIp" "curl -sS --cacert /etc/ssl/certs/consul-ca.pem -H 'X-Consul-Token: $mgmtToken' -o /dev/null -w '%%{http_code}' https://127.0.0.1:8501/v1/status/leader 2>&1" 2>&1 | Out-String).Trim()
            if ($probe -match '^200$') { $ready = $true; break }
          }
          Start-Sleep -Seconds 3
        }
        if (-not $ready) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u consul.service --no-pager -n 30" 2>&1 | Out-String)
          Write-Host $journal
          throw "[consul-acl $${nodeHost}] HTTPS:8501 (with mgmt token) not ready within 120s after deny-mode restart"
        }
        Write-Host "[consul-acl $${nodeHost}] consul healthy with ACL=deny + agent-token rendered"
      }

      # Final cluster-shape verification under deny-mode (mgmt-token
      # authenticated). Use TCP probe + curl with the mgmt token.
      Start-Sleep -Seconds 8
      Write-Host ""
      Write-Host "[consul-acl] verifying cluster shape under deny-mode..."

      $membersOut = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul members 2>&1 | grep -c alive" 2>&1 | Out-String).Trim()
      if ($membersOut -ne '6') {
        throw "[consul-acl] cluster not converged under deny-mode: expected 6 alive, got '$membersOut'"
      }
      Write-Host "[consul-acl] consul members (mgmt-token authenticated): 6 alive"

      $peersOut = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul operator raft list-peers 2>&1 | grep -c '192.168.10'" 2>&1 | Out-String).Trim()
      if ($peersOut -ne '3') {
        throw "[consul-acl] raft list-peers under deny-mode: expected 3 server peers, got '$peersOut'"
      }
      Write-Host "[consul-acl] consul raft list-peers: 3 voter peers"

      # Negative check from leader: anonymous (no token) HTTP GET to a
      # token-required endpoint MUST return 403. Use /v1/agent/self because:
      #   (a) `consul members` with no token does NOT error -- it returns
      #       an empty list (Consul filters by node:read per node, denied
      #       => empty), and rc=2 with empty stdout doesn't match a regex
      #       like 'Permission denied' on output.
      #   (b) /v1/agent/self requires agent:read on the host -- with the
      #       anonymous token this is denied and consul returns HTTP 403
      #       plus a body "Permission denied: anonymous token lacks
      #       permission 'agent:read'..." -- a single unambiguous signal.
      # Only use --cacert + bash $-quoting (no PS escapes); no token header
      # is sent, so the local agent uses the implicit anonymous token.
      $anonProbe = (ssh @sshOpts "$sshUser@$leaderIp" "curl -sS --cacert /etc/ssl/certs/consul-ca.pem -o /dev/null -w '%%{http_code}' https://127.0.0.1:8501/v1/agent/self 2>&1" 2>&1 | Out-String).Trim()
      if ($anonProbe -ne '403') {
        throw "[consul-acl] anonymous /v1/agent/self did NOT return 403 (got '$anonProbe') -- default_policy may not be deny"
      }
      Write-Host "[consul-acl] anonymous /v1/agent/self returns 403 (default_policy=deny verified)"

      Write-Host ""
      Write-Host "[consul-acl] OK -- ACL system enforced cluster-wide (default_policy=deny + 6 agent tokens active + mgmt token in Vault KV)"
    PWSH
  }

  # Destroy: best-effort tear-down. Removes the ACL config files +
  # template + token-renders + restarts vault-agent + consul. Cluster
  # falls back to no-ACL mode (default_policy not set -> Consul's legacy
  # default = allow, equivalent to ACL system disabled). Operator must
  # also clear the bootstrap-token + agent-tokens KV paths if they want
  # a clean re-bootstrap on next apply (the placeholder seed in security
  # env doesn't overwrite populated values; manual `vault kv put -mount=
  # nexus swarm/consul-bootstrap-token management_token=""` first).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $ips = @('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133')
      foreach ($ip in $ips) {
        Write-Host "[consul-acl destroy] $${ip}: removing ACL config + template + restarting consul"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/consul.d/30-acl.hcl /etc/consul.d/30-acl-token.hcl /etc/vault-agent/30-template-acl.hcl; sudo systemctl restart nexus-vault-agent.service consul.service" 2>$null
      }
      exit 0
    PWSH
  }
}
