/*
 * role-overlay-portainer-admin-render.tf -- Phase 0.E.4d (managers only)
 *
 * Drops a Vault Agent template on each manager that renders the PLAINTEXT
 * Portainer admin password (field `plaintext`) from `nexus/portainer/admin-bcrypt`
 * (sticky-seeded by security env's role-overlay-vault-portainer-admin-
 * seed.tf) to /etc/portainer/admin-password.txt (mode 0640 root:root).
 *
 * The Portainer CE Server container will bind-mount this file as
 * /run/secrets/admin-pw:ro and consume it via the `--admin-password-file`
 * flag at startup. IMPORTANT: Portainer's `--admin-password-file` reads the
 * file content as the PLAINTEXT password and bcrypts it internally (only the
 * `--admin-password` CLI flag takes a pre-computed bcrypt hash). Writing the
 * bcrypt hash here (the v2 bug) made Portainer bcrypt the bcrypt-string, so
 * the KV plaintext never authenticated. Render the plaintext (v3, 2026-06-19).
 *
 * Pre-reqs:
 *   - 0.E.4d security-env apply landed (KV seeded + manager policy v6
 *     grants `read` on nexus/data/portainer/admin-bcrypt).
 *   - Vault Agents on the 3 managers are authenticated + rendering.
 *   - 0.E.4b portainer_tls applied (cert files in /etc/portainer/tls/).
 *
 * Idempotency:
 *   - Vault Agent template is content-stable; re-applies are no-op-fast.
 *   - The render-wait probe checks for non-empty file containing a
 *     bcrypt-shaped string ($2b$ or $2a$ prefix).
 *
 * Selective ops: var.enable_portainer_admin_render AND
 *                var.enable_swarm_vault_agents.
 */

locals {
  portainer_admin_manager_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113" },
  ]
}

resource "null_resource" "portainer_admin_render" {
  count = var.enable_portainer_admin_render && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    portainer_tls_id = length(null_resource.portainer_tls) > 0 ? null_resource.portainer_tls[0].id : "disabled"
    kv_mount_path    = var.vault_kv_mount_path
    admin_render_v   = "3" # v3 (2026-06-19) = render `.Data.data.plaintext` instead of `.Data.data.bcrypt_hash`. THE BUG: Portainer's `--admin-password-file` reads the file content as the PLAINTEXT password (Portainer bcrypts it internally); only the `--admin-password` CLI flag takes a pre-computed bcrypt hash. v2 wrote the bcrypt hash to the file, so Portainer bcrypted the bcrypt-string and the real admin password became the `$2b$...` string -- the KV plaintext (and the bcrypt string, and `admin`) all 401'd. Live-caught during the nexus-cli v0.8.2 SwarmAdapter close-out (the topology /api/endpoints enrichment couldn't authenticate). Fix = render the plaintext. v2 = template body switched from HCL inline-string syntax to HCL heredoc (fixed an illegal-char crashloop). v1 = original (broken inline-string syntax).
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.portainer_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $kvMount = '${var.vault_kv_mount_path}'

      $managers = @(
%{for spec in local.portainer_admin_manager_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # Per-manager Vault Agent template body. Renders the PLAINTEXT
      # admin password to /etc/portainer/admin-password.txt -- mode 0640
      # root:root so the dockerd process (running as root) can read but
      # nexusadmin can't traverse + cat. The Portainer Server container
      # bind-mounts this file at /run/secrets/admin-pw:ro and feeds it to
      # `--admin-password-file` (which reads the file as plaintext + bcrypts it).
      #
      # NOTE: HCL heredoc syntax (`contents = <<EOT ... EOT`) is used
      # instead of inline-string syntax. Inline strings would require
      # escaping the inner `"` around the secret path, which under PS
      # `@'...'@` (literal here-string) means writing literal backslash-
      # quote that HCL doesn't accept. Heredoc passes through literally
      # without escape concerns.
      #
      # Trailing newline: Vault Agent's HCL heredoc emits the content
      # as-is. The `{{- ... -}}` trim markers strip leading/trailing
      # whitespace around the secret call so the file ends up containing
      # ONLY the plaintext password with no padding. Trailing whitespace
      # would become part of the password Portainer hashes -- corrupting login.
      $vaTmplBody = @'
template {
  contents = <<EOT
{{- with secret "KVMOUNT/data/portainer/admin-bcrypt" -}}
{{ .Data.data.plaintext }}
{{- end -}}
EOT

  destination = "/etc/portainer/admin-password.txt"
  perms       = "0640"
  user        = "root"
  group       = "root"
}
'@

      $stage1Tmpl = @'
set -euo pipefail
sudo mkdir -p /etc/portainer
sudo chown root:root /etc/portainer
sudo chmod 0755 /etc/portainer

echo 'TPL_B64' | base64 -d | sudo tee /etc/vault-agent/71-template-portainer-admin.hcl > /dev/null
sudo chown root:root /etc/vault-agent/71-template-portainer-admin.hcl
sudo chmod 0644 /etc/vault-agent/71-template-portainer-admin.hcl

sudo systemctl restart nexus-vault-agent.service
'@

      $stage1Errors = $managers | ForEach-Object -ThrottleLimit 3 -Parallel {
        $node    = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $kvMount = $using:kvMount
        $tplBase = $using:vaTmplBody
        $tplStage = $using:stage1Tmpl

        $hostName = $node.Host
        $rendered = $tplBase -replace 'KVMOUNT', $kvMount
        $renderedLf = $rendered -replace "`r`n", "`n"
        $tplB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($renderedLf))
        $script = (($tplStage -replace 'TPL_B64', $tplB64)) -replace "`r`n", "`n"

        $out = $script | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$hostName] stage1 (template drop + vault-agent restart) failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }
      if ($stage1Errors.Count -gt 0) {
        $stage1Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[portainer-admin-render] Stage 1 failed on $($stage1Errors.Count) manager(s)"
      }

      # Wait for /etc/portainer/admin-password.txt to render with the PLAINTEXT
      # admin password (the seed generates a 24-char alphanumeric string; Portainer's
      # --admin-password-file hashes the file content, so it must be plaintext NOT a
      # bcrypt hash). Use sudo on test/grep -- /etc/portainer is mode 0755 but the
      # file itself is 0640 root:root.
      $renderProbe = @'
set -euo pipefail
if sudo test -s /etc/portainer/admin-password.txt; then
  if sudo grep -qE '^[A-Za-z0-9]{12,}$' /etc/portainer/admin-password.txt; then
    echo OK
  else
    echo NOT_RENDERED
  fi
else
  echo MISSING
fi
'@
      $stage1WaitErrors = $managers | ForEach-Object -ThrottleLimit 3 -Parallel {
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
        return "[$($node.Host)] /etc/portainer/admin-password.txt never rendered with bcrypt hash within 90s; journal:`n$journal"
      } | Where-Object { $_ -ne $null }
      if ($stage1WaitErrors.Count -gt 0) {
        $stage1WaitErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[portainer-admin-render] render-wait failed on $($stage1WaitErrors.Count) manager(s)"
      }
      Write-Host "[portainer-admin-render] OK -- /etc/portainer/admin-password.txt rendered with the plaintext admin password on all 3 managers"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $managerIps = @('192.168.70.111','192.168.70.112','192.168.70.113')
      foreach ($ip in $managerIps) {
        Write-Host "[portainer-admin-render destroy] $${ip}: removing template + admin-password file + restart vault-agent"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/vault-agent/71-template-portainer-admin.hcl /etc/portainer/admin-password.txt; sudo systemctl restart nexus-vault-agent.service" 2>$null
      }
      exit 0
    PWSH
  }
}
