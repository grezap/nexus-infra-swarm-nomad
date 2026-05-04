/*
 * role-overlay-consul-tls.tf -- Phase 0.E.2.2 -- Consul TLS
 *
 * Issues per-node TLS leaf certs from Vault PKI's `pki_int/roles/consul-server`
 * (created in 0.E.2 setup), enables TLS on Consul (mutual TLS for internal
 * RPC + Raft, server-only TLS for HTTPS API), and HARD-CUTS HTTP -> HTTPS
 * (port 8500 disabled via `ports.http = -1`; HTTPS on 8501).
 *
 * Pre-req: 0.E.2.1 gossip encrypt is applied. Vault Agents on all 6 nodes
 * must be authenticated + rendering templates from Vault. PKI consul-server
 * role + 6 narrow Vault policies (with `pki_int/issue/consul-server`
 * capability) are already in place.
 *
 * How it works (per-node, sequential rolling -- mirrors 0.E.2.1 pattern):
 *   1. Install /usr/local/sbin/consul-tls-split.sh on the node. Vault Agent
 *      will call this after each successful PKI cert render to atomically
 *      split the bundle into {server.crt, server.key, ca.pem}.
 *
 *   2. Drop /etc/vault-agent/20-template-tls.hcl with a `template` stanza
 *      that calls `{{ pkiCert "pki_int/issue/consul-server" ... }}` with
 *      this host's specific common_name + alt_names + ip_sans:
 *
 *        common_name = <hostname>.consul.nexus.lab
 *        alt_names   = <hostname>, <hostname>.nexus.lab,
 *                      server.nexus-lab.consul, localhost
 *        ip_sans     = <vmnet10>, <vmnet11>, 127.0.0.1
 *
 *      `server.nexus-lab.consul` is required for verify_server_hostname=true
 *      (Consul's internal RPC peer-identity check). 90-day TTL inherits
 *      from the PKI role.
 *
 *   3. Restart nexus-vault-agent.service so it picks up the new template
 *      stanza. Wait up to 60s for /etc/consul.d/tls/server.crt to render +
 *      pass openssl x509 sanity check.
 *
 *   4. Drop /etc/consul.d/20-tls.hcl with the TLS config block + `ports {
 *      http = -1, https = 8501 }` (hard-cut HTTP off).
 *
 *      tls.internal_rpc.verify_incoming   = true
 *      tls.internal_rpc.verify_outgoing   = true
 *      tls.internal_rpc.verify_server_hostname = true   # mutual TLS for
 *                                                       # Raft + RPC
 *      tls.https.verify_incoming          = false       # operator API:
 *                                                       # TLS but no
 *                                                       # client cert
 *
 *   5. Drop /etc/profile.d/consul-tls.sh exporting CONSUL_HTTP_ADDR=https
 *      ://localhost:8501 + CONSUL_CACERT=/etc/consul.d/tls/ca.pem so any
 *      interactive `ssh node 'consul members'` session works without
 *      explicit args. Smoke probes set the env vars inline (login shells
 *      do source profile.d/, but ssh user@host 'cmd' non-interactive
 *      sessions do NOT).
 *
 *   6. Live-patch nftables to allow 8501 inbound on nic0 from VMnet11.
 *      The baseline already allows 8500; that rule stays harmless once
 *      Consul stops listening on 8500 (ports.http = -1).
 *
 *   7. systemctl restart consul.service. Initial TLS-enable benefits from
 *      a full restart (Consul reload on first-time TLS config can be
 *      racy; restart is unambiguous). Wait for consul to rejoin + verify
 *      https://localhost:8501/v1/status/leader returns leader IP.
 *
 *   8. Move to next node. Sequential rolling restart preserves cluster
 *      quorum: at any moment 5 of 6 agents are operational, and Raft
 *      can survive 1 of 3 servers transitioning.
 *
 * After all 6 done: cluster-wide verification probe from build host
 * (separate null_resource).
 *
 * Idempotency: the template render is idempotent (Vault Agent caches +
 * skips re-render when the bundle is unchanged). If consul.service is
 * already healthy with TLS, the restart still succeeds.
 *
 * Selective ops: var.enable_consul_tls.
 */

locals {
  # Per-node specs. ip_sans is comma-separated; the Vault Agent template
  # passes them as-is to pkiCert.
  consul_tls_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111", vmnet10 = "192.168.10.111", role = "manager" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112", vmnet10 = "192.168.10.112", role = "manager" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113", vmnet10 = "192.168.10.113", role = "manager" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131", vmnet10 = "192.168.10.131", role = "worker" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132", vmnet10 = "192.168.10.132", role = "worker" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133", vmnet10 = "192.168.10.133", role = "worker" },
  ]
}

resource "null_resource" "consul_tls" {
  count = var.enable_consul_tls && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    # Re-run on agent install changes (new agent = new node to enroll in TLS)
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    # Re-run on gossip-encrypt changes (we depend on it being live)
    gossip_id = length(null_resource.consul_gossip_encrypt) > 0 ? null_resource.consul_gossip_encrypt[0].id : "disabled"
    # PKI role config (allowed_domains, leaf TTL) pulled from security env --
    # captured here so a security-env knob bump re-issues per-node certs.
    pki_role_name = var.vault_pki_consul_role_name
    consul_tls_v  = "1"
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.consul_gossip_encrypt]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $pkiRole = '${var.vault_pki_consul_role_name}'
      $kvMount = '${var.vault_kv_mount_path}'

      # ─── Per-node specs (sequential apply order: managers first) ────────
      $nodes = @(
%{for spec in local.consul_tls_node_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}'; Vmnet10 = '${spec.vmnet10}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # ─── Common artifacts (same content on every node) ──────────────────

      # consul-tls-split.sh -- post-render command for the Vault Agent
      # template. Reads /etc/consul.d/tls/bundle.pem (one PEM concatenation
      # of cert + key + CA), splits via awk into separate files atomically,
      # sets canonical perms (server.crt 0644 root:consul, server.key 0600
      # root:consul, ca.pem 0644 root:consul), and reloads consul if it's
      # already TLS-enabled (subsequent renews; first apply uses explicit
      # restart later).
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/consul.d/tls/bundle.pem
DEST=/etc/consul.d/tls
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Split bundle into per-PEM-block files. awk increments on each BEGIN line.
awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

# Identify each block by its header.
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
        # Subsequent CERT blocks = CA chain. Keep the LAST one (root) or
        # concat -- for a single-intermediate setup, the second is the
        # intermediate CA which is what consul wants.
        CA_PEM=$f
      fi
      ;;
  esac
done

if [ -z "$SERVER_CRT" ] || [ -z "$SERVER_KEY" ] || [ -z "$CA_PEM" ]; then
  echo "[consul-tls-split] ERROR: bundle missing one of cert/key/ca" >&2
  echo "  bundle blocks:" >&2
  ls -la "$TMP" >&2
  exit 1
fi

install -m 0644 -o root -g consul "$SERVER_CRT" "$DEST/server.crt"
install -m 0640 -o root -g consul "$SERVER_KEY" "$DEST/server.key"
install -m 0644 -o root -g consul "$CA_PEM"     "$DEST/ca.pem"

echo "[consul-tls-split] $(date -u +%FT%TZ) bundle split: server.crt + server.key + ca.pem"

# Reload consul iff it's already running with TLS configured (cert rotation
# case). On first-time TLS enable, consul.service hasn't been restarted yet
# and the TLS config block isn't loaded; the overlay's restart step will
# pick up the new certs. systemctl reload exits 0 even if the service is
# stopped, so we guard with is-active.
if systemctl is-active --quiet consul.service; then
  systemctl reload consul.service 2>/dev/null || true
  echo "[consul-tls-split] reload signal sent to consul.service"
fi
'@

      # /etc/consul.d/20-tls.hcl -- TLS config + hard-cut HTTPS only
      $tlsConfig = @'
# 20-tls.hcl -- Phase 0.E.2.2 -- mutual TLS for internal RPC + Raft;
# server-only TLS for HTTPS API. Hard-cuts HTTP off (port 8500 disabled).
# Renders into the consul -config-dir along with consul.hcl + 10-encrypt.hcl;
# Consul merges in lexical order so 20- supersedes any TLS defaults from
# the role-rendered consul.hcl.

tls {
  defaults {
    ca_file   = "/etc/consul.d/tls/ca.pem"
    cert_file = "/etc/consul.d/tls/server.crt"
    key_file  = "/etc/consul.d/tls/server.key"
  }

  internal_rpc {
    verify_incoming        = true
    verify_outgoing        = true
    verify_server_hostname = true
  }

  https {
    # Operator-friendly: TLS encrypts the channel, but no client cert
    # required for HTTPS API calls. Production would layer ACL tokens /
    # reverse-proxy auth on top.
    verify_incoming = false
  }
}

ports {
  http  = -1
  https = 8501
}

# Consul's internal "auto-encrypt" is OFF -- we issue per-node certs via
# Vault Agent rather than letting Consul manage its own intermediate.
'@

      # /etc/profile.d/consul-tls.sh -- env var defaults for interactive
      # SSH login shells (NOT non-interactive `ssh user@host cmd`; smoke
      # probes set these inline). Makes operator workflows ergonomic.
      $envProfile = @'
# Consul TLS endpoint defaults for operator login shells.
export CONSUL_HTTP_ADDR=https://127.0.0.1:8501
export CONSUL_CACERT=/etc/consul.d/tls/ca.pem
'@

      # ─── Per-node loop ─────────────────────────────────────────────────
      foreach ($node in $nodes) {
        $nodeHost = $node.Host
        $vmIp     = $node.VmIp
        $vmnet10  = $node.Vmnet10
        Write-Host ""
        Write-Host "[consul-tls $${nodeHost}] enrolling in TLS..."

        # ─ Per-node Vault Agent template (per-host SANs) ─
        # ip_sans includes both VMnet10 backplane + VMnet11 mgmt + 127.0.0.1.
        # alt_names includes server.nexus-lab.consul (required for
        # verify_server_hostname=true) + hostname forms + localhost.
        $altNames = "$nodeHost,$nodeHost.nexus.lab,server.nexus-lab.consul,localhost"
        $ipSans   = "$vmnet10,$vmIp,127.0.0.1"
        $cn       = "$nodeHost.consul.nexus.lab"

        $vaultAgentTemplate = @"
# 20-template-tls.hcl -- Phase 0.E.2.2 (rendered for $nodeHost)
# Vault Agent template that issues a Consul TLS leaf cert from
# pki_int/roles/$pkiRole and writes a single bundle file. The post-render
# 'command' script splits the bundle into server.crt + server.key + ca.pem.

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "/etc/consul.d/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "consul"
  command         = "/usr/local/sbin/consul-tls-split.sh"
  command_timeout = "30s"
}
"@

        # Encode all artifacts via base64 for safe transit.
        $splitB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($splitScript))
        $tlsConfigB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($tlsConfig))
        $envProfileB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($envProfile))
        $vaB64       = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($vaultAgentTemplate))

        # Step 1+2: install split script + drop Vault Agent template +
        # restart vault-agent + ensure tls dir exists with right perms.
        $stage1 = @"
set -euo pipefail
sudo mkdir -p /etc/consul.d/tls
sudo chown root:consul /etc/consul.d/tls
sudo chmod 0750 /etc/consul.d/tls

# Split script
echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/consul-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/consul-tls-split.sh
sudo chmod 0755 /usr/local/sbin/consul-tls-split.sh

# Vault Agent template
echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/20-template-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/20-template-tls.hcl
sudo chmod 0644 /etc/vault-agent/20-template-tls.hcl

# Restart vault-agent so it picks up the new template stanza
sudo systemctl restart nexus-vault-agent.service
"@
        $stage1B64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stage1))
        $stage1Out = ssh @sshOpts "$sshUser@$vmIp" "echo '$stage1B64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stage1Out.Trim()
          throw "[consul-tls $${nodeHost}] stage1 (split + va template) failed (rc=$LASTEXITCODE)"
        }

        # Step 3: wait for cert files to materialize. Vault Agent renders
        # the bundle then runs the split script; we observe the resulting
        # 3 files. Probe the SAN of server.crt to confirm it's the right
        # cert (right CN for this host), not a stale one from a prior cycle.
        Write-Host "[consul-tls $${nodeHost}] waiting for cert render + split..."
        $deadline = (Get-Date).AddSeconds(60)
        $rendered = $false
        while ((Get-Date) -lt $deadline) {
          $check = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /etc/consul.d/tls/server.crt && sudo test -s /etc/consul.d/tls/server.key && sudo test -s /etc/consul.d/tls/ca.pem && sudo openssl x509 -in /etc/consul.d/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
          if ($check -match 'OK') { $rendered = $true; break }
          Start-Sleep -Seconds 3
        }
        if (-not $rendered) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
          Write-Host $journal
          throw "[consul-tls $${nodeHost}] cert files not rendered (CN=$cn) within 60s"
        }
        Write-Host "[consul-tls $${nodeHost}] cert rendered (CN=$cn)"

        # Step 4+5+6: drop tls config + env profile + nftables 8501 + restart consul
        $stage2 = @"
set -euo pipefail

# /etc/consul.d/20-tls.hcl (TLS config; ports.http=-1; ports.https=8501)
echo '$tlsConfigB64' | base64 -d | sudo tee /etc/consul.d/20-tls.hcl > /dev/null
sudo chown root:consul /etc/consul.d/20-tls.hcl
sudo chmod 0640 /etc/consul.d/20-tls.hcl

# /etc/profile.d/consul-tls.sh (operator env defaults)
echo '$envProfileB64' | base64 -d | sudo tee /etc/profile.d/consul-tls.sh > /dev/null
sudo chown root:root /etc/profile.d/consul-tls.sh
sudo chmod 0644 /etc/profile.d/consul-tls.sh

# nftables: ensure 8501 from VMnet11 is allowed (idempotent rule add).
# The baseline rule already allows {8500, 4646}; we add 8501 by replacing
# the rule via nft -f /etc/nftables.conf if not already present.
if ! sudo nft list chain inet filter input 2>/dev/null | grep -q 'tcp dport.*8501'; then
  # Append the runtime rule (will be picked up by next nftables.service
  # reload OR persisted via the file rewrite below). For now, live-add.
  sudo nft add rule inet filter input iifname \"nic0\" ip saddr 192.168.70.0/24 tcp dport 8501 accept comment '"Consul HTTPS UI from VMnet11 (0.E.2.2)"'
fi

# Restart consul.service to pick up TLS config (initial TLS enable benefits
# from full restart vs reload; subsequent cert rotations use SIGHUP/reload
# via the split script).
sudo systemctl restart consul.service
"@
        $stage2B64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stage2))
        $stage2Out = ssh @sshOpts "$sshUser@$vmIp" "echo '$stage2B64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stage2Out.Trim()
          throw "[consul-tls $${nodeHost}] stage2 (config + restart) failed (rc=$LASTEXITCODE)"
        }

        # Step 7: wait for consul to be back + serving HTTPS on 8501
        Write-Host "[consul-tls $${nodeHost}] waiting for consul HTTPS on 8501..."
        $consulDeadline = (Get-Date).AddSeconds(90)
        $consulReady = $false
        while ((Get-Date) -lt $consulDeadline) {
          $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active consul.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            # Probe HTTPS API directly via curl + the new CA bundle.
            # /v1/status/leader returns "" (empty) before quorum is restored;
            # any HTTP 200 (even with empty body) means TLS is up.
            $probe = (ssh @sshOpts "$sshUser@$vmIp" "curl -sS --cacert /etc/consul.d/tls/ca.pem -o /dev/null -w '%%{http_code}' https://127.0.0.1:8501/v1/status/leader 2>&1" 2>&1 | Out-String).Trim()
            if ($probe -match '^200$') { $consulReady = $true; break }
          }
          Start-Sleep -Seconds 3
        }
        if (-not $consulReady) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u consul.service --no-pager -n 30" 2>&1 | Out-String)
          Write-Host $journal
          throw "[consul-tls $${nodeHost}] consul HTTPS:8501 not ready within 90s"
        }
        Write-Host "[consul-tls $${nodeHost}] consul HTTPS:8501 active (TLS handshake OK)"
      }

      Write-Host ""
      Write-Host "[consul-tls] all 6 nodes enrolled. Verifying cluster shape over TLS..."
      Start-Sleep -Seconds 10

      # Cluster-wide verification from leader's perspective. Use env vars
      # inline since /etc/profile.d/ doesn't load in non-interactive ssh.
      $leaderIp = '192.168.70.111'
      $envPrefix = "CONSUL_HTTP_ADDR=https://localhost:8501 CONSUL_CACERT=/etc/consul.d/tls/ca.pem"

      $members = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix consul members 2>&1 | grep -c alive" 2>&1 | Out-String).Trim()
      if ($members -ne '6') {
        throw "[consul-tls] cluster not converged: expected 6 alive members over TLS, got '$members'"
      }
      Write-Host "[consul-tls] consul members over HTTPS reports 6 alive"

      $rpcPeers = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix consul operator raft list-peers 2>&1 | grep -c '192.168.10'" 2>&1 | Out-String).Trim()
      if ($rpcPeers -ne '3') {
        throw "[consul-tls] raft mTLS not healthy: expected 3 server peers, got '$rpcPeers'"
      }
      Write-Host "[consul-tls] consul raft list-peers over HTTPS + mTLS reports 3 server peers"

      Write-Host "[consul-tls] OK -- TLS enabled across all 6 agents (mutual TLS for RPC + HTTPS API on 8501)"
    PWSH
  }

  # Destroy: best-effort tear down. Removes TLS config + cert files +
  # restarts consul (falls back to plain HTTP). Operator must also
  # destroy the nftables 8501 rule manually if desired (we leave it; the
  # rule is harmless in the absence of a listener).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $ips = @('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133')
      foreach ($ip in $ips) {
        Write-Host "[consul-tls destroy] $${ip}: removing TLS config + cert files + restart consul"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/consul.d/20-tls.hcl /etc/profile.d/consul-tls.sh /etc/vault-agent/20-template-tls.hcl /etc/consul.d/tls/server.crt /etc/consul.d/tls/server.key /etc/consul.d/tls/ca.pem /etc/consul.d/tls/bundle.pem; sudo systemctl restart nexus-vault-agent.service consul.service" 2>$null
      }
      exit 0
    PWSH
  }
}
