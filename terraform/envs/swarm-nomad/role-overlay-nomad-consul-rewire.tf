/*
 * role-overlay-nomad-consul-rewire.tf -- Phase 0.E.3.3a -- Nomad → Consul HTTPS rewire
 *
 * Replaces Nomad's firstboot-rendered `consul { address = "127.0.0.1:8500" }`
 * stanza with an ACL-authenticated HTTPS:8501 block. The legacy block has
 * been broken since 0.E.2.2 hard-cut HTTP/8500 -- workers' Nomad client
 * couldn't reach Consul for service discovery, only the cached server list
 * + 41-client-servers.hcl kept them functional.
 *
 * Pre-reqs:
 *   - 0.E.3.2 Nomad ACL is closed (cluster healthy under deny-mode).
 *   - 0.E.2.3 Consul ACL has populated nexus/swarm/agent-tokens/<host>
 *     for all 6 nodes with read perms on service_prefix + node_prefix.
 *   - Vault Agents on all 6 nodes are authenticated + rendering templates.
 *   - Existing per-host Vault policies (security env's role-overlay-vault-
 *     agent-swarm-policies.tf v3) already grant read on
 *     nexus/data/swarm/agent-tokens/<host> -- no security-env touch
 *     required for this sub-phase (no AppRole secret-id rotation cascade).
 *
 * Architecture (3 stages):
 *   Stage 1 (parallel, all 6): Drop /etc/vault-agent/42-template-nomad-
 *     consul-token.hcl that fetches `nexus/data/swarm/agent-tokens/<host>`
 *     and renders /etc/nomad.d/42-consul-token.hcl with a `consul { token
 *     = "<UUID>" }` partial block (token only -- separate from the static
 *     address/ssl/ca_file file because Vault Agent owns rotation). Restart
 *     vault-agent. Wait for render.
 *
 *   Stage 2 (parallel, all 6): Drop /etc/nomad.d/42-consul.hcl with the
 *     content-stable consul block (address + ssl + ca_file). SURGICALLY
 *     remove the legacy `consul { address = "127.0.0.1:8500" }` block from
 *     /etc/nomad.d/nomad.hcl in-place via sed -- otherwise nomad.hcl loads
 *     LATER alphabetically (4X-prefixed files come before 'n') and Nomad's
 *     per-key merge would override our address back to plain HTTP. The
 *     two new files (42-consul-token.hcl + 42-consul.hcl) merge into a
 *     single effective consul stanza.
 *
 *   Stage 3 (sequential per-node, managers first): systemctl restart
 *     nomad.service. Wait HTTPS:4646 + 200 with mgmt-token-auth + verify
 *     `nomad agent-info` reports the new HTTPS address. Sequential is
 *     correct for in-config changes (per memory/feedback_nomad_tls_rolling
 *     _restart_must_be_parallel.md -- only TLS-style wire-format flips
 *     need parallel; this is purely an in-config change).
 *
 * Idempotency:
 *   - Stage 1: file content stable per host; vault-agent restart on already-
 *     rendered file is a no-op. The `sudo grep -qE 'token[[:space:]]+='`
 *     wait-loop probe handles both fresh + already-rendered cases.
 *   - Stage 2 file write: content-stable. Sed-remove uses an address-range
 *     pattern that only matches the legacy 4-line block; after removal the
 *     pattern matches nothing → no-op.
 *   - Stage 3 restart: no-op when Nomad already loaded the new config.
 *
 * Selective ops: var.enable_nomad_consul_rewire AND
 *                var.enable_swarm_vault_agents.
 *
 * 41-client-servers.hcl retention: under this sub-phase workers KEEP the
 * hardcoded manager-IP list. Removing it requires extending the Consul
 * agent policy with `service.nomad/nomad-client write` capability so Nomad
 * agents can self-register in Consul as discoverable services. That's a
 * security-env policy change which triggers the AppRole-secret-id-rotation
 * cascade through 4+ swarm-nomad overlays -- out of scope for 0.E.3.3a;
 * deferred to 0.E.4 or later.
 */

locals {
  nomad_consul_rewire_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111", role = "manager" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112", role = "manager" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113", role = "manager" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131", role = "worker" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132", role = "worker" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133", role = "worker" },
  ]
}

resource "null_resource" "nomad_consul_rewire" {
  count = var.enable_nomad_consul_rewire && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    nomad_acl_id  = length(null_resource.nomad_acl) > 0 ? null_resource.nomad_acl[0].id : "disabled"
    consul_acl_id = length(null_resource.consul_acl) > 0 ? null_resource.consul_acl[0].id : "disabled"
    kv_mount_path = var.vault_kv_mount_path
    rewire_v      = "4" # v4 = Stage 3 final-verification probe switched from `nomad agent-info | sed -n '/^consul/...'` (which silently matches an empty string -- agent-info has NO consul section) to `curl /v1/agent/self | grep '"Addr":"127.0.0.1:8501"'` (the JSON API returns config.Consuls[] plural). v3 = drop `https://` prefix from consul.address -- Nomad's consul-client config parser expects `host:port` format only (NOT a URL with scheme), and the scheme triggers a `Failed to initialize Consul client: too many colons in address` error at agent boot. The HTTPS protocol is selected by the sibling `ssl = true` field, not by the scheme in `address`. v2 wrote `address = "https://127.0.0.1:8501"` from the user's original spec (which used URL form); the address must be `127.0.0.1:8501`. Caught at apply time when manager-1 entered restart-counter loop with the literal Go `net.SplitHostPort` error. v2 = sed-remove anchor uses `^consul {$` line (not the preceding comment line) -- the swarm-node-firstboot.sh nomad-client.hcl.tpl comment is `# Co-located Consul agent on this node` (workers, exact-match) but nomad-server.hcl.tpl is `# Co-located Consul agent on this node provides service discovery + auto-join` (managers, longer). v1's anchor matched only the worker comment line via `^...$`, so manager Stage 2 reported "idempotent skip" (comment-line-not-found branch) but the legacy `consul { address = "127.0.0.1:8500" }` block on managers stayed in place, then the sanity-check grep failed all 3 managers. v2 anchors on `^consul {$` directly + only fires when the legacy 8500 address is detected (defensive against future nomad.hcl edits that might add another consul block). v1 = original.
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.nomad_acl, null_resource.consul_acl]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $kvMount = '${var.vault_kv_mount_path}'

      $nodes = @(
%{for spec in local.nomad_consul_rewire_node_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      $leaderIp     = $nodes[0].VmIp
      $nomadEnvBase = "NOMAD_ADDR=https://localhost:4646 NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem"

      # Read mgmt token from Vault KV (any node has a vault-agent token; we
      # use vault-1 directly to avoid plumbing per-node permissions).
      $vaultIp  = '${var.vault_1_ip}'
      $keysFile = '${local.vault_init_keys_file_expanded}'
      if (-not (Test-Path $keysFile)) {
        throw "[nomad-consul-rewire] vault init keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token
      $kvReadScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault kv get -field=management_token -mount=$kvMount swarm/nomad-bootstrap-token 2>/dev/null || true
"@
      $kvReadB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvReadScript -replace "`r`n", "`n")))
      $mgmtToken = (ssh @sshOpts "$sshUser@$vaultIp" "echo '$kvReadB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
      if (-not $mgmtToken -or $mgmtToken.Length -lt 36) {
        throw "[nomad-consul-rewire] could not resolve nomad mgmt token from Vault KV"
      }
      Write-Host "[nomad-consul-rewire] resolved nomad mgmt token (prefix $($mgmtToken.Substring(0,8))...)"

      # ─── Stage 1 (parallel, all 6) — Vault Agent template for token ────
      Write-Host ""
      Write-Host "[nomad-consul-rewire] Stage 1 -- Vault Agent template renders /etc/nomad.d/42-consul-token.hcl on all 6 (parallel)"

      # Per-host template body. Renders ONLY the `consul { token = "..." }`
      # partial -- the address/ssl/ca_file static stanza ships in Stage 2.
      # File ordering: 42-consul-token.hcl < 42-consul.hcl (because '-' =
      # 0x2D < '.' = 0x2E), so token loads first; address+ssl+ca_file load
      # second; Nomad merges both into one effective stanza (per-key, with
      # later overriding -- but the two files don't overlap in keys so
      # merge result is the union).
      $vaTmplBody = @'
# 42-template-nomad-consul-token.hcl -- Phase 0.E.3.3a (rendered for HOSTNAME)
# Vault Agent template that fetches this node's Consul agent token from
# nexus/data/swarm/agent-tokens/HOSTNAME and writes /etc/nomad.d/42-consul-
# token.hcl as a partial consul{} block containing only the token field.
# The static address+ssl+ca_file fields ship in 42-consul.hcl (terraform-
# managed, content-stable). Splitting token from static config lets Vault
# Agent rotate the token independently -- the consul-acl overlay's token
# rotation pattern is to mint a new token + put to KV, and the next vault-
# agent render picks it up automatically.

template {
  contents = <<EOT
{{ with secret "KVMOUNT/data/swarm/agent-tokens/HOSTNAME" }}consul {
  token = "{{ .Data.data.agent_token }}"
}
{{ end }}
EOT

  destination = "/etc/nomad.d/42-consul-token.hcl"
  perms       = "0640"
  user        = "root"
  group       = "nomad"
}
'@

      $stage1ScriptTmpl = @'
set -euo pipefail
echo 'TPL_B64' | base64 -d | sudo tee /etc/vault-agent/42-template-nomad-consul-token.hcl > /dev/null
sudo chown root:root /etc/vault-agent/42-template-nomad-consul-token.hcl
sudo chmod 0644 /etc/vault-agent/42-template-nomad-consul-token.hcl
sudo systemctl restart nexus-vault-agent.service
'@

      $stage1Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node     = $_
        $sshUser  = $using:sshUser
        $sshOpts  = $using:sshOpts
        $kvMount  = $using:kvMount
        $tplBase  = $using:vaTmplBody
        $tplStage = $using:stage1ScriptTmpl

        $hostName  = $node.Host
        $rendered  = ($tplBase -replace 'HOSTNAME', $hostName) -replace 'KVMOUNT', $kvMount
        $tplB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($rendered -replace "`r`n", "`n")))
        $script    = (($tplStage -replace 'TPL_B64', $tplB64)) -replace "`r`n", "`n"

        $out = $script | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$hostName] stage1 (template drop + vault-agent restart) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage1Errors.Count -gt 0) {
        $stage1Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-consul-rewire] Stage 1 failed on $($stage1Errors.Count) node(s)"
      }

      # Wait for /etc/nomad.d/42-consul-token.hcl to render with non-empty
      # token. /etc/nomad.d/ is mode 0750 root:nomad → sudo on test+grep
      # (per memory/feedback_sudo_required_for_consul_etc_traverse.md).
      # Heredoc-piped pattern (per memory/feedback_powershell_backslash_quote.md
      # -- PS double-quote can't carry `\"`; pipe via bash -s).
      $renderProbe = @'
set -euo pipefail
if sudo test -s /etc/nomad.d/42-consul-token.hcl; then
  if sudo grep -qE 'token[[:space:]]*=[[:space:]]*"[A-Za-z0-9-]{8,}"' /etc/nomad.d/42-consul-token.hcl; then
    echo OK
  else
    echo NOT_RENDERED
  fi
else
  echo MISSING
fi
'@
      $stage1WaitErrors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $probe   = ($using:renderProbe) -replace "`r`n", "`n"
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
          $check = ($probe | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String).Trim()
          if ($check -match 'OK') { return $null }
          Start-Sleep -Seconds 3
        }
        $journal = (ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        return "[$($node.Host)] /etc/nomad.d/42-consul-token.hcl never rendered with non-empty token within 90s; journal:`n$journal"
      } | Where-Object { $_ -ne $null }
      if ($stage1WaitErrors.Count -gt 0) {
        $stage1WaitErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-consul-rewire] Stage 1 render-wait failed on $($stage1WaitErrors.Count) node(s)"
      }
      Write-Host "[nomad-consul-rewire] Stage 1 complete -- /etc/nomad.d/42-consul-token.hcl rendered on all 6 nodes"

      # ─── Stage 2 (parallel, all 6) — static config + sed-remove legacy ─
      Write-Host ""
      Write-Host "[nomad-consul-rewire] Stage 2 -- drop /etc/nomad.d/42-consul.hcl + surgical-remove legacy consul{} from /etc/nomad.d/nomad.hcl on all 6 (parallel)"

      $consulStaticConfig = @'
# 42-consul.hcl -- Phase 0.E.3.3a -- static portion of Nomad's consul{}
# stanza. Pairs with /etc/nomad.d/42-consul-token.hcl (vault-agent-rendered
# token). Loads alphabetically AFTER 42-consul-token.hcl ('-' < '.'), so the
# token is in the merge first; this static config layers address+ssl+ca_file
# on top.
#
# IMPORTANT: address is host:port form (NO https:// scheme). Nomad's consul-
# client config parser uses Go net.SplitHostPort and rejects URLs with
# "too many colons in address". HTTPS is enabled by the sibling `ssl = true`
# field, not the scheme. Caught at v2 apply time by manager-1 crashloop.

consul {
  address = "127.0.0.1:8501"
  ssl     = true
  ca_file = "/etc/ssl/certs/consul-ca.pem"
}
'@

      # Sed-remove the legacy consul{} block from /etc/nomad.d/nomad.hcl.
      # The block as rendered by swarm-node-firstboot.sh's two templates is:
      #
      #   <comment>      <-- workers: "# Co-located Consul agent on this node"
      #                       managers: "# Co-located Consul agent on this node provides service discovery + auto-join"
      #   consul {
      #     address = "127.0.0.1:8500"
      #   }
      #
      # Anchor on the `^consul {$` line (NOT the comment) since the comment
      # text differs between manager + worker templates -- v1 anchored on
      # the worker comment + silently skipped on managers, leaving the
      # legacy block intact. We also gate the sed on detecting the literal
      # 8500 address so we never delete a non-legacy consul block (defensive
      # against future hand-edits).
      $stage2Script = @'
set -euo pipefail

# 1. Drop the static config file.
echo 'STATIC_B64' | base64 -d | sudo tee /etc/nomad.d/42-consul.hcl > /dev/null
sudo chown root:nomad /etc/nomad.d/42-consul.hcl
sudo chmod 0640 /etc/nomad.d/42-consul.hcl

# 2. Surgical-remove legacy block from nomad.hcl. Idempotent: gate on
#    detecting the literal "127.0.0.1:8500" address; if absent, the legacy
#    block is already gone (or never existed) and we skip.
if sudo grep -qE 'address[[:space:]]*=[[:space:]]*"127\.0\.0\.1:8500"' /etc/nomad.d/nomad.hcl; then
  # Range delete from `^consul {$` through the next `^}$`.
  sudo sed -i '/^consul {$/,/^}$/d' /etc/nomad.d/nomad.hcl
  if sudo grep -qE 'address[[:space:]]*=[[:space:]]*"127\.0\.0\.1:8500"' /etc/nomad.d/nomad.hcl; then
    echo "[stage2] ERROR: sed did not remove legacy consul{} block (8500 address still present)" >&2
    sudo grep -nE 'consul|8500' /etc/nomad.d/nomad.hcl >&2
    exit 1
  fi
  echo "[stage2] removed legacy consul{} block from /etc/nomad.d/nomad.hcl"
else
  echo "[stage2] legacy consul{} block already removed from /etc/nomad.d/nomad.hcl (idempotent)"
fi
echo "[stage2] OK"
'@

      $staticLf  = $consulStaticConfig -replace "`r`n", "`n"
      $staticB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($staticLf))
      $stage2LfTmpl = ($stage2Script -replace 'STATIC_B64', $staticB64) -replace "`r`n", "`n"

      $stage2Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $script  = $using:stage2LfTmpl
        $out = $script | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] stage2 (static config + sed remove) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage2Errors.Count -gt 0) {
        $stage2Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-consul-rewire] Stage 2 failed on $($stage2Errors.Count) node(s)"
      }
      Write-Host "[nomad-consul-rewire] Stage 2 complete -- static config staged + legacy block removed on all 6"

      # ─── Stage 3 (sequential per-node, managers first) — restart nomad ─
      # ACL-style in-config change → sequential rolling is safe. Per
      # memory/feedback_nomad_tls_rolling_restart_must_be_parallel.md:
      # parallel is required for TLS-style wire-format flips; sequential
      # is correct for in-config changes like this one.
      Write-Host ""
      Write-Host "[nomad-consul-rewire] Stage 3 -- sequential rolling restart of nomad.service (managers first)"

      foreach ($node in $nodes) {
        $nodeHost = $node.Host
        $vmIp     = $node.VmIp
        Write-Host "[nomad-consul-rewire $${nodeHost}] restarting nomad.service"

        $rc = ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl restart nomad.service" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $rc.Trim()
          throw "[nomad-consul-rewire $${nodeHost}] restart failed (rc=$LASTEXITCODE)"
        }

        # Wait for HTTPS:4646 + 200 with mgmt-token-auth (ACL is enforced
        # so anonymous returns 403; 200 = leader elected + ACL serving).
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
          throw "[nomad-consul-rewire $${nodeHost}] HTTPS:4646 (mgmt-token authenticated) not ready within 120s"
        }
        Write-Host "[nomad-consul-rewire $${nodeHost}] nomad healthy with new consul HTTPS config"
      }

      # ─── Cluster-wide verification ─────────────────────────────────────
      Start-Sleep -Seconds 8
      Write-Host ""
      Write-Host "[nomad-consul-rewire] verifying cluster shape + consul integration..."

      $serversOut = (ssh @sshOpts "$sshUser@$leaderIp" "$nomadEnvBase NOMAD_TOKEN='$mgmtToken' nomad server members 2>&1 | grep -c alive" 2>&1 | Out-String).Trim()
      if ($serversOut -ne '3') {
        throw "[nomad-consul-rewire] expected 3 alive servers post-rewire, got '$serversOut'"
      }
      Write-Host "[nomad-consul-rewire] nomad server members: 3 alive"

      $clientsOut = (ssh @sshOpts "$sshUser@$leaderIp" "$nomadEnvBase NOMAD_TOKEN='$mgmtToken' nomad node status 2>&1 | grep -c ready" 2>&1 | Out-String).Trim()
      if ($clientsOut -ne '3') {
        throw "[nomad-consul-rewire] expected 3 ready clients post-rewire, got '$clientsOut'"
      }
      Write-Host "[nomad-consul-rewire] nomad node status: 3 ready"

      # Verify the effective consul block via Nomad's JSON API. The
      # /v1/agent/self response includes config.Consuls[] (plural -- Nomad
      # 1.7+ supports multi-Consul); we grep for the literal substrings
      # since Go's json.Marshal default has no spaces. `nomad agent-info`
      # does NOT include a consul section, so v1/v2 of this probe (which
      # used `agent-info | sed`) silently matched the empty string.
      $agentSelf = (ssh @sshOpts "$sshUser@$leaderIp" "curl -s --cacert /etc/ssl/certs/nomad-ca.pem -H 'X-Nomad-Token: $mgmtToken' https://127.0.0.1:4646/v1/agent/self" 2>&1 | Out-String)
      if ($agentSelf -notmatch '"Addr":"127\.0\.0\.1:8501"') {
        throw "[nomad-consul-rewire] /v1/agent/self does NOT report Consuls[].Addr=127.0.0.1:8501 (rewire didn't take effect)"
      }
      if ($agentSelf -notmatch '"EnableSSL":true') {
        throw "[nomad-consul-rewire] /v1/agent/self does NOT report Consuls[].EnableSSL=true"
      }
      if ($agentSelf -match '"Addr":"127\.0\.0\.1:8500"') {
        throw "[nomad-consul-rewire] /v1/agent/self STILL reports plain HTTP Consuls[].Addr=127.0.0.1:8500 (legacy block not removed)"
      }
      Write-Host "[nomad-consul-rewire] /v1/agent/self confirms Consuls[].Addr=127.0.0.1:8501 + EnableSSL=true on $leaderIp"

      Write-Host ""
      Write-Host "[nomad-consul-rewire] OK -- all 6 Nomad agents rewired to ACL-authenticated Consul HTTPS:8501"
    PWSH
  }

  # Destroy: best-effort tear-down. Removes new files + restores legacy
  # consul block in nomad.hcl is NOT done here (we don't keep a saved copy
  # of the original block; firstboot template would be needed). Nomad will
  # have NO consul stanza after destroy; cluster keeps running but loses
  # service-discovery integration. This is acceptable for a destroy path.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $ips = @('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133')
      foreach ($ip in $ips) {
        Write-Host "[nomad-consul-rewire destroy] $${ip}: removing 0.E.3.3a artefacts + restarting"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/nomad.d/42-consul.hcl /etc/nomad.d/42-consul-token.hcl /etc/vault-agent/42-template-nomad-consul-token.hcl; sudo systemctl restart nexus-vault-agent.service nomad.service" 2>$null
      }
      exit 0
    PWSH
  }
}
