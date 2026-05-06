/*
 * role-overlay-nomad-tls.tf -- Phase 0.E.3.1 -- Nomad TLS
 *
 * Issues per-node Nomad TLS leaf certs from Vault PKI's `pki_int/roles/
 * nomad-server` (created in 0.E.3.1 setup, security env), enables TLS on
 * Nomad (mutual TLS for RPC + HTTPS API on 4646), and tightens the
 * cluster to require TLS for inter-server raft replication.
 *
 * Pre-reqs:
 *   - 0.E.2.3 Consul ACL is closed (cluster healthy under deny-mode).
 *   - Vault Agents on all 6 nodes are authenticated + rendering templates.
 *   - PKI nomad-server role + 6 narrow Vault policies (extended in security
 *     env's role-overlay-vault-agent-swarm-policies.tf v3) grant
 *     pki_int/issue/nomad-server capability.
 *
 * Architecture parallel to 0.E.2.2 (Consul TLS):
 *   /etc/vault-agent/40-template-nomad-tls.hcl   <- Vault Agent fetches
 *                                                     leaf cert + writes
 *                                                     bundle.pem
 *   /usr/local/sbin/nomad-tls-split.sh           <- splits bundle into
 *                                                     server.crt + .key +
 *                                                     ca.pem (per-render)
 *   /etc/nomad.d/40-tls.hcl                      <- tls{} stanza enabling
 *                                                     mTLS for RPC +
 *                                                     server-only TLS for
 *                                                     HTTPS API on 4646
 *   /etc/profile.d/nomad-tls.sh                  <- env vars for operator
 *                                                     (NOMAD_ADDR=https://
 *                                                     localhost:4646 +
 *                                                     NOMAD_CACERT=...)
 *
 * SAN coverage (per pki_int/roles/nomad-server allowed_domains):
 *   - common_name: <hostname>.nomad.nexus.lab
 *   - alt_names: <hostname>, <hostname>.nexus.lab,
 *                server.global.nomad (managers) OR client.global.nomad (workers),
 *                localhost
 *   - ip_sans: <vmnet10>, <vmnet11>, 127.0.0.1
 *
 * `server.global.nomad` is REQUIRED on managers because Nomad's internal
 * RPC peer-identity check (verify_server_hostname=true) verifies the
 * certificate's SAN against `server.<region>.nomad`. Region defaults to
 * `global` in the nomad-server.hcl.tpl rendered by Packer firstboot.
 *
 * Choreography (3 stages, sequential rolling restart):
 *   Stage 1 (parallel): Drop split-script + Vault Agent template per host;
 *     restart nexus-vault-agent.service so it picks up the new template;
 *     wait for /etc/nomad.d/tls/{server.crt,server.key,ca.pem} to render
 *     (post-split via the script's command-on-render hook).
 *
 *   Stage 2 (parallel): Drop /etc/nomad.d/40-tls.hcl + /etc/profile.d/
 *     nomad-tls.sh on all 6 nodes. No Nomad restart yet.
 *
 *   Stage 3 (sequential, managers first): systemctl restart nomad.service
 *     on each node. Sequential because Nomad's TLS-enable is a hard cut --
 *     once one node has TLS for RPC, peers without TLS can't talk to it
 *     (verify_outgoing rejects plain peers, verify_incoming rejects plain
 *     callers). The first manager to restart will appear unhealthy until
 *     the next manager joins it; raft tolerates 1 of 3 down so we have
 *     headroom. Workers restart after all managers are TLS-converged.
 *
 *   Per-node settle wait: 90s for nomad.service active + HTTPS API
 *   /v1/status/leader returning 200 with the CA bundle.
 *
 * After all 6 done: cluster-wide verification probe from build host
 * (mgmt-token-authenticated nomad server members + node status).
 *
 * Idempotency:
 *   - Stage 1 template render is idempotent (Vault Agent caches + skips
 *     re-render when the bundle is unchanged).
 *   - Stage 2 file writes are content-stable.
 *   - Stage 3 restart is a no-op if Nomad is already TLS-active with the
 *     same config (config-dir merge picks up file changes on (re)start).
 *
 * Selective ops: var.enable_nomad_tls.
 */

locals {
  # Same per-node spec shape as the consul-tls overlay; role determines
  # which Nomad-specific SAN the template adds (server.global.nomad for
  # managers, client.global.nomad for workers).
  nomad_tls_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111", vmnet10 = "192.168.10.111", role = "manager" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112", vmnet10 = "192.168.10.112", role = "manager" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113", vmnet10 = "192.168.10.113", role = "manager" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131", vmnet10 = "192.168.10.131", role = "worker" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132", vmnet10 = "192.168.10.132", role = "worker" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133", vmnet10 = "192.168.10.133", role = "worker" },
  ]
}

resource "null_resource" "nomad_tls" {
  count = var.enable_nomad_tls && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    consul_acl_id = length(null_resource.consul_acl) > 0 ? null_resource.consul_acl[0].id : "disabled"
    pki_role_name = var.vault_pki_nomad_role_name
    nomad_tls_v   = "4" # v4 = drop /etc/nomad.d/41-client-servers.hcl on WORKERS only with explicit `client { servers = [...] }` pointing at the 3 manager VMnet10 IPs. v3's parallel big-bang restart fixed manager-side TLS RPC reconvergence (raft leader elected fine), but workers couldn't find ANY server: their Nomad client config relies on `consul { address = "127.0.0.1:8500" }` for server discovery, but HTTP/8500 was hard-cut in 0.E.2.2 -- 0.E.3.3 Nomad-Vault integration will re-wire workers to use HTTPS:8501 with an ACL token, but for 0.E.3.1 we just hardcode the server list to break the discovery dependency. v3 = parallel big-bang restart (sequential rolled the cluster into a no-leader state during gap). v2 = systemd drop-in switches ExecStart from `-config=/etc/nomad.d/nomad.hcl` (single file) to `-config=/etc/nomad.d/` (directory) so 40-tls.hcl is actually loaded. v1 = original (3-stage; mirrors consul-tls v6 with the 4 memorialized lessons).
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.consul_acl]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $pkiRole = '${var.vault_pki_nomad_role_name}'

      # ─── Per-node specs ────────────────────────────────────────────────
      $nodes = @(
%{for spec in local.nomad_tls_node_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}'; Vmnet10 = '${spec.vmnet10}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # ─── Common artifacts (same on every node) ──────────────────────────

      # nomad-tls-split.sh -- post-render command for the Vault Agent
      # template. Reads /etc/nomad.d/tls/bundle.pem (one PEM concatenation
      # of cert + key + CA), splits via awk into separate files, sets
      # canonical perms (server.crt 0644 root:nomad, server.key 0600
      # root:nomad, ca.pem 0644 root:nomad). Copies CA to /etc/ssl/certs/
      # for operator-ergonomic env vars (mirrors the consul pattern).
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/nomad.d/tls/bundle.pem
DEST=/etc/nomad.d/tls
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

SERVER_CRT=""
SERVER_KEY=""
CA_PEM=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*)
      SERVER_KEY=$f
      ;;
    *"BEGIN CERTIFICATE"*)
      if [ -z "$SERVER_CRT" ]; then
        SERVER_CRT=$f
      else
        CA_PEM=$f
      fi
      ;;
  esac
done

if [ -z "$SERVER_CRT" ] || [ -z "$SERVER_KEY" ] || [ -z "$CA_PEM" ]; then
  echo "[nomad-tls-split] ERROR: bundle missing one of cert/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

install -m 0644 -o root -g nomad "$SERVER_CRT" "$DEST/server.crt"
install -m 0640 -o root -g nomad "$SERVER_KEY" "$DEST/server.key"
install -m 0644 -o root -g nomad "$CA_PEM"     "$DEST/ca.pem"

# Operator-readable copy. /etc/nomad.d/ is mode 0750 root:nomad so
# nexusadmin can't traverse without sudo; the world-readable copy at
# /etc/ssl/certs/nomad-ca.pem makes the env-var-based operator workflow
# in /etc/profile.d/nomad-tls.sh work without elevation.
install -m 0644 -o root -g root "$CA_PEM" /etc/ssl/certs/nomad-ca.pem

echo "[nomad-tls-split] $(date -u +%FT%TZ) bundle split: server.crt + server.key + ca.pem (+ /etc/ssl/certs/nomad-ca.pem)"

# Nomad doesn't support a SIGHUP-style hot reload of TLS config (unlike
# Consul's reload). Cert rotations must come with a service restart;
# leave that to the overlay's Stage 3 + Vault Agent's own renewal flow
# (which runs `systemctl reload-or-restart nomad.service` via cmd).
'@

      # /etc/nomad.d/40-tls.hcl -- TLS config block. Enable mTLS for RPC,
      # server-only TLS for HTTPS API. verify_server_hostname=true requires
      # the cert to have server.global.nomad / client.global.nomad SANs;
      # the PKI role provides them.
      $tlsConfig = @'
# 40-tls.hcl -- Phase 0.E.3.1 -- Nomad TLS
# Renders alongside nomad.hcl (firstboot-rendered) in /etc/nomad.d/.
# Nomad merges all *.hcl files at startup in lexical order; 40- supersedes
# any TLS defaults from earlier files (there are none currently).

tls {
  # Enable HTTPS for the operator API on port 4646 (replaces plain HTTP)
  http = true

  # Enable mutual TLS for inter-agent RPC (port 4647 + raft)
  rpc  = true

  ca_file   = "/etc/nomad.d/tls/ca.pem"
  cert_file = "/etc/nomad.d/tls/server.crt"
  key_file  = "/etc/nomad.d/tls/server.key"

  # Verify peer certificates expose the expected SAN (server.<region>.nomad
  # for servers; client.<region>.nomad for clients). Without this, ACL
  # bypass via cert-impersonation is possible. PKI role's allowed_domains
  # constrains the SAN list to our 6 hostnames + the standard SANs.
  verify_server_hostname = true

  # Server-side: do not require client certs on the HTTPS API (operators
  # authenticate via NOMAD_TOKEN once 0.E.3.2 ACL lands; mTLS for the
  # client-facing API would require distributing client certs to every
  # operator workstation, which is out of scope).
  verify_https_client    = false
}
'@

      # /etc/profile.d/nomad-tls.sh -- env-var defaults for operator login
      # shells. Mirrors /etc/profile.d/consul-tls.sh from 0.E.2.2.
      $envProfile = @'
# Nomad TLS endpoint defaults for operator login shells.
export NOMAD_ADDR=https://127.0.0.1:4646
export NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem
'@

      # /etc/nomad.d/41-client-servers.hcl -- WORKERS ONLY -- explicit
      # client.servers list (VMnet10 backplane IPs of the 3 managers).
      # Workers' Nomad config uses `consul { address = "127.0.0.1:8500" }`
      # for server discovery, but plain HTTP/8500 was hard-cut in 0.E.2.2 --
      # workers had no way to find servers after the TLS rolling restart
      # invalidated their cached server list. 0.E.3.3 will re-wire the
      # consul block to HTTPS:8501 with an ACL token; for now hardcoding
      # the 3 manager IPs gives workers an explicit-configured fallback.
      $clientServersConfig = @'
# 41-client-servers.hcl -- Phase 0.E.3.1 (workers only)
# Hardcode the 3 manager IPs (VMnet10 backplane). 0.E.3.3 will replace
# this with consul-discovery over HTTPS once Nomad's consul block is
# updated to use the ACL'd HTTPS API.

client {
  servers = [
    "192.168.10.111:4647",
    "192.168.10.112:4647",
    "192.168.10.113:4647",
  ]
}
'@

      # systemd drop-in to switch Nomad's ExecStart from single-file
      # `-config=/etc/nomad.d/nomad.hcl` to dir-mode `-config=/etc/nomad.d/`.
      # Without this, Nomad ignores 40-tls.hcl entirely (the file is in the
      # dir but the agent only reads the explicit file path). Pattern
      # mirrors consul-tls v6's tls-ports-override.conf drop-in.
      # Idempotent: bails if the drop-in is already in place.
      $systemdDropinScript = @'
#!/bin/bash
set -euo pipefail
DROPIN_DIR=/etc/systemd/system/nomad.service.d
DROPIN=$DROPIN_DIR/config-dir-override.conf
if [ -f "$DROPIN" ] && grep -q 'config=/etc/nomad.d/$' "$DROPIN"; then
  echo "[nomad-systemd-override] drop-in already in place; nothing to do"
  exit 0
fi
EXEC_LINE=$(systemctl cat nomad.service | grep -E '^ExecStart=' | head -1 | sed 's/^ExecStart=//')
if [ -z "$EXEC_LINE" ]; then
  echo "[nomad-systemd-override] ERROR: could not read ExecStart from nomad.service" >&2
  exit 1
fi
# Replace `-config=<anything>` with `-config=/etc/nomad.d/`.
NEW_EXEC=$(echo "$EXEC_LINE" | sed -E 's#-config=[^ ]+#-config=/etc/nomad.d/#')
if [ "$NEW_EXEC" = "$EXEC_LINE" ]; then
  echo "[nomad-systemd-override] WARN: ExecStart had no -config flag to rewrite; appending one" >&2
  NEW_EXEC="$EXEC_LINE -config=/etc/nomad.d/"
fi
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
# 0.E.3.1 v2 -- override -config to point at the dir, not a single file
# (so 40-tls.hcl is loaded alongside nomad.hcl)
[Service]
ExecStart=
ExecStart=$NEW_EXEC
EOF
chmod 0644 "$DROPIN"
systemctl daemon-reload
echo "[nomad-systemd-override] drop-in installed; new ExecStart=$NEW_EXEC"
'@

      Write-Host ""
      Write-Host "[nomad-tls] Stage 1 -- per-host cert render via Vault Agent (parallel)"

      # ─── Stage 1 (parallel) — install split script + Vault Agent
      #     template, restart vault-agent, wait for cert render ──────────
      $stage1Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $pkiRole = $using:pkiRole
        $splitScript = $using:splitScript

        $nodeHost = $node.Host
        $vmIp     = $node.VmIp
        $vmnet10  = $node.Vmnet10
        $role     = $node.Role

        # Nomad-specific SAN: server.global.nomad on managers,
        # client.global.nomad on workers. PKI role permits BOTH so a
        # misconfig still issues, but we constrain to the right one.
        $nomadIdentitySan = if ($role -eq 'manager') { 'server.global.nomad' } else { 'client.global.nomad' }
        $altNames = "$nodeHost,$nodeHost.nexus.lab,$nodeHost.nomad.nexus.lab,$nomadIdentitySan,localhost"
        $ipSans   = "$vmnet10,$vmIp,127.0.0.1"
        $cn       = "$nodeHost.nomad.nexus.lab"

        # Per-host Vault Agent template. Same pkiCert pattern as Consul
        # TLS template; uses the nomad-server PKI role.
        $vaTemplate = @"
# 40-template-nomad-tls.hcl -- Phase 0.E.3.1 (rendered for $nodeHost)
# Vault Agent template: issues a Nomad TLS leaf cert from
# pki_int/roles/$pkiRole; writes bundle.pem; post-render command splits
# the bundle into per-file outputs.

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "/etc/nomad.d/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "nomad"
  command         = "/usr/local/sbin/nomad-tls-split.sh"
  command_timeout = "30s"
}
"@

        $splitLf  = $splitScript -replace "`r`n", "`n"
        $vaLf     = $vaTemplate  -replace "`r`n", "`n"
        $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($splitLf))
        $vaB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($vaLf))

        $stage1 = @"
set -euo pipefail
sudo mkdir -p /etc/nomad.d/tls
sudo chown root:nomad /etc/nomad.d/tls
sudo chmod 0750 /etc/nomad.d/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/nomad-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/nomad-tls-split.sh
sudo chmod 0755 /usr/local/sbin/nomad-tls-split.sh

echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/40-template-nomad-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/40-template-nomad-tls.hcl
sudo chmod 0644 /etc/vault-agent/40-template-nomad-tls.hcl

sudo systemctl restart nexus-vault-agent.service

# Wait up to 30s for bundle to render. Use sudo on test (per
# memory/feedback_sudo_required_for_consul_etc_traverse.md -- /etc/nomad.d/
# is 0750 root:nomad and nexusadmin can't traverse without elevation).
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if sudo test -s /etc/nomad.d/tls/bundle.pem; then break; fi
  sleep 2
done
if ! sudo test -s /etc/nomad.d/tls/bundle.pem; then
  echo "[stage1] ERROR: bundle.pem not rendered within 30s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi

# Manual split-script invocation. Like consul-tls v5 lesson: pkiCert
# results are CACHED, so restart with unchanged cert -> no destination
# write -> command-on-render doesn't fire. Manual run is idempotent +
# guarantees per-version outputs land regardless of cache state.
sudo /usr/local/sbin/nomad-tls-split.sh
"@
        $stage1B64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($stage1 -replace "`r`n", "`n")))
        $out = (ssh @sshOpts "$sshUser@$vmIp" "echo '$stage1B64' | base64 -d | bash" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
          return "[$nodeHost] stage1 (cert render) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }

        # Verify CN matches per-host expectation
        $check = (ssh @sshOpts "$sshUser@$vmIp" "sudo openssl x509 -in /etc/nomad.d/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -notmatch 'OK') {
          return "[$nodeHost] cert subject CN mismatch (expected $cn); openssl output: $check"
        }
        return $null
      } | Where-Object { $_ -ne $null }

      if ($stage1Errors.Count -gt 0) {
        $stage1Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-tls] Stage 1 failed on $($stage1Errors.Count) node(s)"
      }
      Write-Host "[nomad-tls] Stage 1 complete -- cert files rendered on all 6 nodes."

      # ─── Stage 2 (parallel) — drop config + env profile ───────────────
      Write-Host ""
      Write-Host "[nomad-tls] Stage 2 -- drop /etc/nomad.d/40-tls.hcl + /etc/profile.d/nomad-tls.sh on all 6 (parallel, no nomad restart)"

      $tlsConfigLf         = $tlsConfig          -replace "`r`n", "`n"
      $envProfileLf        = $envProfile         -replace "`r`n", "`n"
      $systemdDropinLf     = $systemdDropinScript -replace "`r`n", "`n"
      $clientServersLf     = $clientServersConfig -replace "`r`n", "`n"
      $tlsConfigB64        = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($tlsConfigLf))
      $envProfileB64       = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($envProfileLf))
      $systemdDropinB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($systemdDropinLf))
      $clientServersB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($clientServersLf))

      # Stage 2 script template: WORKER role inserts the client.servers
      # block. MANAGER role doesn't (managers discover each other via
      # serf gossip on VMnet10).
      $stage2Tmpl = @"
set -euo pipefail
echo '$tlsConfigB64' | base64 -d | sudo tee /etc/nomad.d/40-tls.hcl > /dev/null
sudo chown root:nomad /etc/nomad.d/40-tls.hcl
sudo chmod 0640 /etc/nomad.d/40-tls.hcl

echo '$envProfileB64' | base64 -d | sudo tee /etc/profile.d/nomad-tls.sh > /dev/null
sudo chown root:root /etc/profile.d/nomad-tls.sh
sudo chmod 0644 /etc/profile.d/nomad-tls.sh

# v4: workers get an explicit client.servers list (Consul service-discovery
# is broken since 0.E.2.2 hard-cut HTTP/8500). The CLIENT_SERVERS_BLOB
# placeholder is replaced per-node: workers get the b64'd hcl, managers
# get the no-op string ''.
CLIENT_SERVERS_B64='CLIENT_SERVERS_BLOB'
if [ -n "`$CLIENT_SERVERS_B64" ]; then
  echo "`$CLIENT_SERVERS_B64" | base64 -d | sudo tee /etc/nomad.d/41-client-servers.hcl > /dev/null
  sudo chown root:nomad /etc/nomad.d/41-client-servers.hcl
  sudo chmod 0640 /etc/nomad.d/41-client-servers.hcl
fi

# v2: install systemd drop-in to switch -config from single file -> dir.
# Without this, 40-tls.hcl is ignored at runtime even though it's on disk.
echo '$systemdDropinB64' | base64 -d | sudo /bin/bash
"@
      $stage2TmplLf = $stage2Tmpl -replace "`r`n", "`n"

      $stage2Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node             = $_
        $sshUser          = $using:sshUser
        $sshOpts          = $using:sshOpts
        $stage2Tmpl       = $using:stage2TmplLf
        $clientServersB64 = $using:clientServersB64

        # Workers get the client.servers blob; managers get ''.
        $blob = if ($node.Role -eq 'worker') { $clientServersB64 } else { '' }
        $stage2 = $stage2Tmpl -replace 'CLIENT_SERVERS_BLOB', $blob

        # Heredoc-piped pattern (per memory/feedback_pwsh_ssh_stdin_cr_injection.md)
        $out = $stage2 | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] stage2 (config drop) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }

      if ($stage2Errors.Count -gt 0) {
        $stage2Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-tls] Stage 2 failed on $($stage2Errors.Count) node(s)"
      }
      Write-Host "[nomad-tls] Stage 2 complete -- TLS config staged on all 6 nodes."

      # ─── Stage 3 (parallel big-bang) — restart nomad on all 6 ─────────
      # Nomad RPC with verify_server_hostname=true rejects plain peers.
      # Rolling sequentially would isolate the first node (TLS-only) from
      # the rest (still plaintext) until the next node flips -- raft can't
      # elect during the gap, /v1/status/leader stays 500, per-node deadline
      # fires before cluster converges. Parallel big-bang flips all 6
      # within seconds of each other; raft re-elects within ~10-30s.
      # ~10-30s cluster outage during the parallel restart.
      Write-Host ""
      Write-Host "[nomad-tls] Stage 3 -- big-bang restart of nomad.service on all 6 (parallel)..."
      Write-Host "[nomad-tls] (~10-30s cluster outage; all nodes converge with TLS simultaneously)"

      $stage3Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $out = ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo systemctl restart nomad.service" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] stage3 restart failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage3Errors.Count -gt 0) {
        $stage3Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-tls] Stage 3 (nomad restart) failed on $($stage3Errors.Count) node(s)"
      }
      Write-Host "[nomad-tls] Stage 3 -- restart commands issued; waiting for cluster to converge..."

      # Per-node wait for HTTPS:4646 + 200 (parallel polling, max 120s).
      $stage3WaitErrors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$sshUser@$($node.VmIp)" "systemctl is-active nomad.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            $probe = (ssh @sshOpts "$sshUser@$($node.VmIp)" "curl -sS --cacert /etc/ssl/certs/nomad-ca.pem -o /dev/null -w '%%{http_code}' https://127.0.0.1:4646/v1/status/leader 2>&1" 2>&1 | Out-String).Trim()
            if ($probe -match '^200$') { return $null }
          }
          Start-Sleep -Seconds 3
        }
        $journal = (ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo journalctl -u nomad.service --no-pager -n 30" 2>&1 | Out-String)
        return "[$($node.Host)] nomad HTTPS:4646 not ready within 120s; journal:`n$journal"
      } | Where-Object { $_ -ne $null }

      if ($stage3WaitErrors.Count -gt 0) {
        $stage3WaitErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[nomad-tls] Stage 3 wait (HTTPS:4646 ready) failed on $($stage3WaitErrors.Count) node(s)"
      }
      Write-Host "[nomad-tls] Stage 3 complete -- HTTPS:4646 active on all 6 nodes."

      Write-Host ""
      Write-Host "[nomad-tls] Stage 3 complete -- all 6 nodes TLS-enabled. Verifying cluster shape over TLS..."
      Start-Sleep -Seconds 8

      # Cluster-wide verification. Use TLS env vars inline (operator
      # /etc/profile.d/ doesn't load in non-interactive ssh).
      $leaderIp = '192.168.70.111'
      $envPrefix = "NOMAD_ADDR=https://localhost:4646 NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem"

      $servers = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix nomad server members 2>&1 | grep -c alive" 2>&1 | Out-String).Trim()
      if ($servers -ne '3') {
        throw "[nomad-tls] expected 3 alive servers over TLS, got '$servers'"
      }
      Write-Host "[nomad-tls] nomad server members over HTTPS: 3 alive"

      $clients = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix nomad node status 2>&1 | grep -c ready" 2>&1 | Out-String).Trim()
      if ($clients -ne '3') {
        throw "[nomad-tls] expected 3 ready clients over TLS, got '$clients'"
      }
      Write-Host "[nomad-tls] nomad node status over HTTPS: 3 ready"

      Write-Host "[nomad-tls] OK -- TLS enabled across all 6 Nomad agents (mutual TLS for RPC + HTTPS API on 4646)"
    PWSH
  }

  # Destroy: best-effort tear-down. Removes TLS config + cert files +
  # restarts vault-agent + nomad. Cluster falls back to plain HTTP/4646.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $ips = @('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133')
      foreach ($ip in $ips) {
        Write-Host "[nomad-tls destroy] $${ip}: removing TLS config + cert files + restart"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/nomad.d/40-tls.hcl /etc/nomad.d/41-client-servers.hcl /etc/profile.d/nomad-tls.sh /etc/vault-agent/40-template-nomad-tls.hcl /etc/nomad.d/tls/server.crt /etc/nomad.d/tls/server.key /etc/nomad.d/tls/ca.pem /etc/nomad.d/tls/bundle.pem /etc/ssl/certs/nomad-ca.pem /etc/systemd/system/nomad.service.d/config-dir-override.conf; sudo systemctl daemon-reload; sudo systemctl restart nexus-vault-agent.service nomad.service" 2>$null
      }
      exit 0
    PWSH
  }
}
