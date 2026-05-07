/*
 * role-overlay-portainer-tls.tf -- Phase 0.E.4b -- Portainer TLS cert render
 *
 * Issues a per-manager Portainer TLS leaf cert from Vault PKI's
 * `pki_int/roles/portainer-server` (created in 0.E.4b setup, security
 * env), splits the bundle into server.crt + server.key + ca.pem in
 * /etc/portainer/tls/. The Portainer CE Server replica's container will
 * bind-mount this directory as /certs:ro.
 *
 * Why per-manager certs (not single shared cert):
 *   - Each manager's Vault Agent renders its own cert with the same CN
 *     (portainer.nexus.lab) and the same allowed SAN list. So functionally
 *     they're equivalent for TLS validation regardless of which manager
 *     Swarm has the Server replica scheduled on.
 *   - Per-manager render means each manager's Vault Agent owns its own
 *     leaf-cert lifecycle (renewal, rotation). No "single source of truth"
 *     race with the Server replica's bind mount when Swarm reschedules.
 *   - Mirrors the existing consul-tls + nomad-tls per-host render pattern.
 *
 * Pre-reqs:
 *   - 0.E.4a NFS mount applied (Portainer CE will need it; this overlay
 *     doesn't consume it but it's part of the same sub-phase setup).
 *   - 0.E.3.3 closed (cluster healthy under TLS+ACL).
 *   - Vault Agents on the 3 managers are authenticated + rendering
 *     templates.
 *   - Manager Vault Agent policies (security env's role-overlay-vault-
 *     agent-swarm-policies.tf v5) grant pki_int/issue/portainer-server
 *     capability.
 *
 * Architecture (mirrors role-overlay-nomad-tls.tf shape, simpler since
 * managers-only and no service-restart needed):
 *   /etc/vault-agent/70-template-portainer-tls.hcl   <- Vault Agent
 *                                                       fetches leaf cert
 *                                                       + writes bundle.pem
 *   /usr/local/sbin/portainer-tls-split.sh           <- splits bundle into
 *                                                       server.crt + .key +
 *                                                       ca.pem (per-render)
 *   /etc/portainer/tls/{server.crt, server.key, ca.pem}
 *
 * SAN coverage (per pki_int/roles/portainer-server allowed_domains):
 *   - common_name: portainer.nexus.lab
 *   - alt_names: portainer.nexus.lab, localhost
 *   - ip_sans: 192.168.70.111, 192.168.70.112, 192.168.70.113, 127.0.0.1
 *
 * The PKI role uses `allow_bare_domains=true` because the CN is the
 * literal `portainer.nexus.lab` (no subdomain segment).
 *
 * Choreography (single PWSH local-exec, parallel per-manager):
 *   Stage 1 (parallel): Drop split-script + Vault Agent template per
 *     manager; restart nexus-vault-agent.service so it picks up the new
 *     template; wait up to 90s for /etc/portainer/tls/server.crt to
 *     render (post-split via the script's command-on-render hook).
 *
 *   No Stage 2/3: Portainer CE service isn't deployed here -- 0.E.4d
 *   handles the docker stack deploy. Future cert rotations will trigger
 *   Vault Agent to re-render, post-render command runs the split script,
 *   the Server container's bind-mount picks up the new files
 *   transparently (Portainer reloads TLS on file change OR a SIGHUP-
 *   compatible re-deploy is needed; lab-pragmatic assumption is once
 *   per 90 days a `docker service update --force portainer_server`
 *   bump is acceptable).
 *
 * Idempotency:
 *   - Vault Agent template is content-stable; re-applies are no-op-fast.
 *   - The split script's `install -m` is idempotent (overwrites with
 *     same content).
 *
 * Selective ops: var.enable_portainer_tls AND var.enable_swarm_vault_agents.
 */

locals {
  portainer_tls_manager_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113" },
  ]
}

resource "null_resource" "portainer_tls" {
  count = var.enable_portainer_tls && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    pki_role_name   = var.vault_pki_portainer_role_name
    portainer_tls_v = "2" # v2 (Phase 0.E.4e) = split-script concatenates leaf + intermediate into server.crt so Portainer presents the FULL chain on TLS handshake (off-cluster clients with only root in CA bundle were hitting X509ChainStatus.PartialChain). ca.pem stays as the intermediate alone. v1 = original (per-manager Vault Agent template renders portainer leaf cert from pki_int/issue/portainer-server; split script writes server.crt + server.key + ca.pem to /etc/portainer/tls/).
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.nomad_consul_rewire]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $pkiRole = '${var.vault_pki_portainer_role_name}'

      $managers = @(
%{for spec in local.portainer_tls_manager_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # portainer-tls-split.sh -- post-render command for the Vault Agent
      # template. Reads /etc/portainer/tls/bundle.pem (one PEM concat of
      # cert + key + CA), splits via awk into server.crt + server.key +
      # ca.pem with canonical perms (0644 root:root for crt+ca, 0640
      # root:root for the key -- the docker container runs as root so any
      # mode that root can read is fine).
      # Mirrors nomad-tls-split.sh shape.
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/portainer/tls/bundle.pem
DEST=/etc/portainer/tls
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
  echo "[portainer-tls-split] ERROR: bundle missing one of cert/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

# v2 (Phase 0.E.4e): concatenate leaf + intermediate into server.crt so the
# Portainer HTTPS listener presents the FULL chain on TLS handshake. Mirrors
# the consul-tls v7 / nomad-tls v5 fix; ca.pem stays as the intermediate alone.
cat "$SERVER_CRT" "$CA_PEM" > "$TMP/server-fullchain.crt"

install -m 0644 -o root -g root "$TMP/server-fullchain.crt" "$DEST/server.crt"
install -m 0640 -o root -g root "$SERVER_KEY"               "$DEST/server.key"
install -m 0644 -o root -g root "$CA_PEM"                   "$DEST/ca.pem"

echo "[portainer-tls-split] $(date -u +%FT%TZ) bundle split: server.crt + server.key + ca.pem"
'@

      Write-Host ""
      Write-Host "[portainer-tls] Stage 1 -- per-manager cert render via Vault Agent (parallel)"

      $stage1Errors = $managers | ForEach-Object -ThrottleLimit 3 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $pkiRole = $using:pkiRole
        $splitScript = $using:splitScript

        $hostName = $node.Host
        $vmIp     = $node.VmIp

        # SAN coverage matches the PKI role's allowed_domains:
        # CN = portainer.nexus.lab; alt_names = portainer.nexus.lab,localhost;
        # ip_sans = THIS manager's VMnet11 IP + 127.0.0.1.
        # The PKI role allows IP SANs but enforce_hostnames=false so the
        # CN doesn't have to match a real hostname.
        $cn       = "portainer.nexus.lab"
        $altNames = "portainer.nexus.lab,localhost"
        $ipSans   = "$vmIp,127.0.0.1"

        $vaTemplate = @"
# 70-template-portainer-tls.hcl -- Phase 0.E.4b (rendered for $hostName)
# Vault Agent template: issues a Portainer TLS leaf cert from
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

  destination     = "/etc/portainer/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "root"
  command         = "/usr/local/sbin/portainer-tls-split.sh"
  command_timeout = "30s"
}
"@

        $splitLf  = $splitScript -replace "`r`n", "`n"
        $vaLf     = $vaTemplate  -replace "`r`n", "`n"
        $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($splitLf))
        $vaB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($vaLf))

        $stage1 = @"
set -euo pipefail
sudo mkdir -p /etc/portainer/tls
sudo chown root:root /etc/portainer/tls
sudo chmod 0755 /etc/portainer/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/portainer-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/portainer-tls-split.sh
sudo chmod 0755 /usr/local/sbin/portainer-tls-split.sh

echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/70-template-portainer-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-portainer-tls.hcl
sudo chmod 0644 /etc/vault-agent/70-template-portainer-tls.hcl

sudo systemctl restart nexus-vault-agent.service

# Wait up to 30s for bundle to render. Use sudo on test (per
# memory/feedback_sudo_required_for_consul_etc_traverse.md -- /etc/portainer/
# is 0755 root:root so traversal is fine, but sudo defends against future
# perm tightening).
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if sudo test -s /etc/portainer/tls/bundle.pem; then break; fi
  sleep 2
done
if ! sudo test -s /etc/portainer/tls/bundle.pem; then
  echo "[stage1] ERROR: bundle.pem not rendered within 30s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi

# Manual split-script invocation (per memory consul-tls v5 lesson:
# pkiCert results are CACHED, so a vault-agent restart with unchanged
# cert -> no destination write -> command-on-render doesn't fire).
sudo /usr/local/sbin/portainer-tls-split.sh
"@
        # Pipe plaintext stage1 to ssh stdin + run with `bash -s`. Mirrors the
        # stage2/consul-tls fix: the embedded-base64 pattern fails when ssh.exe's
        # argv handling clips ~6KB single-quoted strings on Windows.
        $stage1Lf = $stage1 -replace "`r`n", "`n"
        $out = ($stage1Lf | ssh @sshOpts "$sshUser@$vmIp" "tr -d '\r' | bash -s" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
          return "[$hostName] stage1 (cert render) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }

        # Verify CN matches expected
        $check = (ssh @sshOpts "$sshUser@$vmIp" "sudo openssl x509 -in /etc/portainer/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -notmatch 'OK') {
          return "[$hostName] cert subject CN mismatch (expected $cn); openssl output: $check"
        }
        return $null
      } | Where-Object { $_ -ne $null }

      if ($stage1Errors.Count -gt 0) {
        $stage1Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[portainer-tls] Stage 1 failed on $($stage1Errors.Count) manager(s)"
      }
      Write-Host "[portainer-tls] Stage 1 complete -- cert files rendered on all 3 managers."
      Write-Host "[portainer-tls] OK -- /etc/portainer/tls/{server.crt, server.key, ca.pem} ready for Portainer CE deployment"
    PWSH
  }

  # Destroy: best-effort tear-down. Removes TLS template + cert files.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $managerIps = @('192.168.70.111','192.168.70.112','192.168.70.113')
      foreach ($ip in $managerIps) {
        Write-Host "[portainer-tls destroy] $${ip}: removing TLS template + cert files + restart vault-agent"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/vault-agent/70-template-portainer-tls.hcl /etc/portainer/tls/server.crt /etc/portainer/tls/server.key /etc/portainer/tls/ca.pem /etc/portainer/tls/bundle.pem /usr/local/sbin/portainer-tls-split.sh; sudo systemctl restart nexus-vault-agent.service" 2>$null
      }
      exit 0
    PWSH
  }
}
