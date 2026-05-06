/*
 * role-overlay-swarm-vault-agents.tf -- Phase 0.E.2 setup
 *
 * Installs Vault Agent as a `nexus-vault-agent` systemd service on each of
 * the 6 swarm-node clones. Linux equivalent of nexus-infra-vmware's
 * `role-overlay-windows-vault-agent.tf` (0.D.5.4 Windows pattern).
 *
 * Each agent authenticates to vault-1 via its narrow AppRole (provisioned
 * by nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-
 * swarm-approles.tf, which writes per-host JSON sidecars to
 * $HOME/.nexus/vault-agent-swarm-<host>.json on the build host).
 *
 * Cross-env coupling: reads the AppRole creds JSON sidecars. WARN+skip if
 * absent. Operator order:
 *   1. nexus-infra-vmware: pwsh -File scripts/security.ps1 apply
 *      (creates the 6 sidecars)
 *   2. nexus-infra-swarm-nomad: pwsh -File scripts/swarm.ps1 apply
 *      (this file consumes the sidecars)
 *
 * Per-host resource pattern (for_each over filtered map) so each agent is
 * independently `-target`-able for iteration.
 *
 * Vault Agent config: directory mode (`-config=/etc/vault-agent/`) merges
 * all *.hcl files at startup. The setup-side here writes 00-base.hcl
 * (auto_auth approle + sink + vault address). Subsequent sub-phases
 * (0.E.2.1 gossip, 0.E.2.2 TLS, 0.E.2.3 ACL) drop their own template
 * stanzas as 10-template-*.hcl etc. without rewriting the base file.
 *
 * Install steps (each host):
 *   1. Probe: vault binary already at expected version + service running?
 *      If yes, skip.
 *   2. Download vault_<version>_linux_amd64.zip from releases.hashicorp.com
 *      via nexus-gateway egress; verify SHA256SUMS; install to
 *      /usr/local/bin/vault. (Same pattern as consul/nomad in swarm_node
 *      Ansible role.)
 *   3. Stage role-id, secret-id, CA bundle, base config to /etc/vault-agent/
 *      (mode 0400 root:root for secret-id; 0644 for config + CA).
 *   4. Drop /etc/systemd/system/nexus-vault-agent.service unit.
 *   5. systemctl enable --now nexus-vault-agent.
 *   6. Verify: service active within 30s + token sink file populated.
 *
 * Selective ops: var.enable_swarm_vault_agents (master) AND per-host
 *                var.enable_swarm_<hostname>_vault_agent.
 *
 * Reachability invariant: Vault Agent runs as root on each swarm-node;
 * binds to no network ports (sink "file" only). No firewall changes. SSH
 * from build host unaffected.
 */

locals {
  swarm_vault_agent_specs = {
    "swarm-manager-1" = { vm_ip = "192.168.70.111", role = "manager", enabled = var.enable_swarm_manager_1_vault_agent }
    "swarm-manager-2" = { vm_ip = "192.168.70.112", role = "manager", enabled = var.enable_swarm_manager_2_vault_agent }
    "swarm-manager-3" = { vm_ip = "192.168.70.113", role = "manager", enabled = var.enable_swarm_manager_3_vault_agent }
    "swarm-worker-1"  = { vm_ip = "192.168.70.131", role = "worker", enabled = var.enable_swarm_worker_1_vault_agent }
    "swarm-worker-2"  = { vm_ip = "192.168.70.132", role = "worker", enabled = var.enable_swarm_worker_2_vault_agent }
    "swarm-worker-3"  = { vm_ip = "192.168.70.133", role = "worker", enabled = var.enable_swarm_worker_3_vault_agent }
  }

  swarm_vault_agent_active = {
    for host, spec in local.swarm_vault_agent_specs : host => spec
    if var.enable_swarm_vault_agents && spec.enabled
  }

  # Terraform's pathexpand() only handles `~`, NOT `$HOME`. Variable defaults
  # are `$HOME/.nexus/...` (matches the PowerShell-side convention used by
  # nexus-infra-vmware/security overlays), so substitute $HOME -> ~ before
  # expansion. Result: literal Windows path like `C:/Users/grigo/.nexus/...`
  # that terraform `filesha256()` can open + that PS Test-Path/Get-Content
  # accept directly (no further .Replace('$HOME',...) needed).
  vault_agent_creds_dir_expanded = pathexpand(replace(var.vault_agent_swarm_creds_dir, "$HOME", "~"))
  vault_pki_ca_bundle_expanded   = pathexpand(replace(var.vault_pki_ca_bundle_path, "$HOME", "~"))
}

resource "null_resource" "swarm_vault_agent" {
  for_each = local.swarm_vault_agent_active

  triggers = {
    # Re-run when the AppRole sidecar mtime changes (security env regenerated
    # the secret-id) -- read mtime via the file_hash trick: terraform
    # filesha256 changes when the file content changes (security env updates
    # secret-id on each apply).
    creds_file_path = "${local.vault_agent_creds_dir_expanded}/vault-agent-${each.key}.json"
    swarm_init_id   = null_resource.swarm_init_and_join[0].id
    vault_version   = var.vault_agent_version
    # Capture the sidecar's content hash so terraform re-runs when the
    # security env regenerates the secret-id (every apply rotates it).
    creds_file_hash    = filesha256("${local.vault_agent_creds_dir_expanded}/vault-agent-${each.key}.json")
    swarm_va_overlay_v = "2" # v2 = ERROR-on-missing-creds (was WARN+skip; v1 silently exited 0 when the security env's first apply produced wrongly-named sidecars, leaving terraform thinking the resource was created when it had skipped); also added creds_file_hash trigger so re-applies pick up rotated secret-ids. v1 = original. (NOTE: the rendered systemd unit body now includes RuntimeDirectory=nexus-vault-agent + LogsDirectory=nexus-vault-agent -- the canonical reboot-survival fix for /var/run tmpfs wipe. Trigger version intentionally NOT bumped to avoid cascading the 6-agent reinstall on 0.E.3.3a's atomic apply; the new unit content lands automatically on 0.E.3.3b's apply when creds_file_hash rotates from the security-env secret-id rotation. Manual remediation already applied to the running cluster on 2026-05-06 by `mkdir -p /var/run/nexus-vault-agent` on all 6 nodes; that ad-hoc fix is fine until reboot, at which point the rotation cascade will have written the systemd unit with RuntimeDirectory= for permanent fix.)

    # Captured here for the destroy provisioner -- terraform restricts
    # destroy provisioners to `self`, `count.index`, and `each.key`. We
    # need vm_ip + ssh_user, so freeze them into triggers at create time
    # so `self.triggers.X` is reachable on destroy.
    destroy_vm_ip    = each.value.vm_ip
    destroy_ssh_user = var.swarm_node_user
  }

  depends_on = [null_resource.swarm_init_and_join]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName           = '${each.key}'
      $vmIp           = '${each.value.vm_ip}'
      $role           = '${each.value.role}'
      $vaultVersion   = '${var.vault_agent_version}'
      $credsFile      = '${local.vault_agent_creds_dir_expanded}/vault-agent-${each.key}.json'
      $caBundlePath   = '${local.vault_pki_ca_bundle_expanded}'
      $sshUser        = '${var.swarm_node_user}'

      # Pre-flight: AppRole creds JSON must exist (security env writes it).
      # ERROR (not WARN+skip) -- silent skip on missing creds was the root
      # cause of a 0.E.2.1 cycle where 6 agents were "created" in tf state
      # without /etc/vault-agent/ existing on the nodes (Vault Agent never
      # installed; downstream gossip-encrypt overlay hit `tee: No such file`).
      if (-not (Test-Path $credsFile)) {
        throw "[swarm-va $hostName] creds file $credsFile missing -- run nexus-infra-vmware/scripts/security.ps1 apply FIRST to provision the 6 AppRole sidecars."
      }
      $creds = Get-Content $credsFile | ConvertFrom-Json
      $roleId   = $creds.role_id
      $secretId = $creds.secret_id
      $vaultAddr = $creds.vault_addr
      if (-not $roleId -or -not $secretId) {
        throw "[swarm-va $hostName] creds JSON missing role_id or secret_id"
      }

      # Pre-flight: CA bundle must exist (PKI root distributed to build host
      # in 0.D.2). The Vault Agent uses it to verify the vault server cert.
      if (-not (Test-Path $caBundlePath)) {
        throw "[swarm-va $hostName] CA bundle $caBundlePath missing -- run security env apply (PKI distribute) first."
      }

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # Step 1: probe -- already installed + active?
      $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -x /usr/local/bin/vault && /usr/local/bin/vault version 2>/dev/null && systemctl is-active nexus-vault-agent.service 2>/dev/null" 2>&1 | Out-String).Trim()
      if ($probe -match "Vault v$vaultVersion" -and $probe -match '(?m)^active$') {
        Write-Host "[swarm-va $hostName] already installed at v$vaultVersion + service active; skipping."
        exit 0
      }

      Write-Host "[swarm-va $hostName] installing Vault Agent v$vaultVersion (role=$role)"

      # Step 2: install vault binary (skip if already at expected version)
      # Mirrors the consul/nomad install pattern from the swarm_node Ansible role.
      $installScript = @"
set -euo pipefail

# Step 2.0: ensure DNS resolution works before any outbound HTTP.
# The deb13 baseline used dhcpcd at Packer-build time, then switched to
# systemd-networkd at clone time without enabling systemd-resolved -- result:
# /etc/resolv.conf may be empty (or a stale dhcpcd header) on fresh clones,
# and curl returns "Could not resolve host". Cluster ops use direct IPs so
# this only surfaces when something does outbound HTTP for the first time.
# nexus-gateway's dnsmasq is the canonical lab resolver at 192.168.70.1.
if ! getent hosts releases.hashicorp.com >/dev/null 2>&1; then
  echo "[swarm-va install] /etc/resolv.conf has no working resolver; pointing at nexus-gateway dnsmasq"
  echo "nameserver 192.168.70.1" | sudo tee /etc/resolv.conf > /dev/null
fi

if [ -x /usr/local/bin/vault ] && /usr/local/bin/vault version 2>/dev/null | grep -qF "Vault v$vaultVersion"; then
  echo "vault binary v$vaultVersion already installed"
else
  cd /tmp
  zip="vault_$${vaultVersion}_linux_amd64.zip"
  sums="vault_$${vaultVersion}_SHA256SUMS"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$zip"  -o "`$zip"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$sums" -o "`$sums"
  grep "`$zip" "`$sums" | sha256sum -c -
  unzip -o "`$zip"
  sudo install -m 755 -o root -g root vault /usr/local/bin/vault
  rm -f "`$zip" "`$sums" vault
  echo "vault binary v$vaultVersion installed"
fi

# Step 3: directories + ownership
sudo mkdir -p /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent
sudo chown root:root /etc/vault-agent
sudo chmod 0755 /etc/vault-agent
"@
      $installBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($installScript)
      $installB64   = [Convert]::ToBase64String($installBytes)
      $installOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$installB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $installOut.Trim()
        throw "[swarm-va $hostName] vault binary install failed (rc=$LASTEXITCODE)"
      }
      Write-Host $installOut.Trim()

      # Step 4: stage role-id + secret-id + CA bundle
      $roleIdTmp   = New-TemporaryFile
      $secretIdTmp = New-TemporaryFile
      try {
        # NB: write the credentials WITHOUT a trailing newline -- Vault Agent
        # reads the entire file content as the role-id/secret-id value, and
        # a trailing newline becomes part of the credential, breaking auth.
        [System.IO.File]::WriteAllText($roleIdTmp.FullName, $roleId)
        [System.IO.File]::WriteAllText($secretIdTmp.FullName, $secretId)

        scp @sshOpts $roleIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/role-id"
        scp @sshOpts $secretIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/secret-id"
        scp @sshOpts $caBundlePath "$${sshUser}@$${vmIp}:/tmp/ca-bundle.crt"

        $stageScript = @"
set -euo pipefail
sudo install -m 0400 -o root -g root /tmp/role-id    /etc/vault-agent/role-id
sudo install -m 0400 -o root -g root /tmp/secret-id  /etc/vault-agent/secret-id
sudo install -m 0644 -o root -g root /tmp/ca-bundle.crt /etc/vault-agent/ca-bundle.crt
sudo rm -f /tmp/role-id /tmp/secret-id /tmp/ca-bundle.crt
"@
        $stageBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($stageScript)
        $stageB64   = [Convert]::ToBase64String($stageBytes)
        $stageOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$stageB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stageOut.Trim()
          throw "[swarm-va $hostName] credential staging failed (rc=$LASTEXITCODE)"
        }
      } finally {
        Remove-Item $roleIdTmp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $secretIdTmp.FullName -Force -ErrorAction SilentlyContinue
      }

      # Step 5: write 00-base.hcl + nexus-vault-agent.service
      $baseConfig = @"
# 00-base.hcl -- Phase 0.E.2 setup. auto_auth + vault address. Each
# 0.E.2.X sub-phase drops its own NN-template-*.hcl in this dir to add
# template stanzas (gossip key, TLS cert, ACL token) without rewriting
# this file.

pid_file = "/var/run/nexus-vault-agent/agent.pid"

vault {
  address = "$vaultAddr"
  ca_cert = "/etc/vault-agent/ca-bundle.crt"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role-id"
      secret_id_file_path                 = "/etc/vault-agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/var/run/nexus-vault-agent/token"
      mode = 0640
    }
  }
}
"@

      $unitFile = @"
[Unit]
Description=Nexus Vault Agent (Phase 0.E.2 -- Consul harden setup)
Documentation=https://developer.hashicorp.com/vault/docs/agent
Requires=network-online.target
After=network-online.target swarm-node-firstboot.service
ConditionFileIsExecutable=/usr/local/bin/vault

[Service]
Type=simple
User=root
Group=root
# RuntimeDirectory= -- v3 fix. systemd auto-creates /run/nexus-vault-agent
# (= /var/run/nexus-vault-agent) on every service start. Critical because
# /var/run is tmpfs and the install-time `mkdir -p /var/run/nexus-vault-
# agent` did NOT survive host reboots -- post-reboot all 6 agents crash-
# looped with "error creating file sink: no such file or directory" when
# trying to write the AppRole token sink. RuntimeDirectoryMode=0755 mirrors
# the install-time chmod.
RuntimeDirectory=nexus-vault-agent
RuntimeDirectoryMode=0755
LogsDirectory=nexus-vault-agent
LogsDirectoryMode=0755
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/
ExecReload=/bin/kill -HUP \`$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:/var/log/nexus-vault-agent/agent.log
StandardError=append:/var/log/nexus-vault-agent/agent.log

[Install]
WantedBy=multi-user.target
"@

      $configBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($baseConfig)
      $configB64   = [Convert]::ToBase64String($configBytes)
      $unitBytes   = [System.Text.UTF8Encoding]::new($false).GetBytes($unitFile)
      $unitB64     = [Convert]::ToBase64String($unitBytes)

      $finalScript = @"
set -euo pipefail
echo '$configB64' | base64 -d | sudo tee /etc/vault-agent/00-base.hcl > /dev/null
sudo chown root:root /etc/vault-agent/00-base.hcl
sudo chmod 0644 /etc/vault-agent/00-base.hcl

echo '$unitB64' | base64 -d | sudo tee /etc/systemd/system/nexus-vault-agent.service > /dev/null
sudo chown root:root /etc/systemd/system/nexus-vault-agent.service
sudo chmod 0644 /etc/systemd/system/nexus-vault-agent.service

sudo systemctl daemon-reload
sudo systemctl enable --now nexus-vault-agent.service
"@
      $finalBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($finalScript)
      $finalB64   = [Convert]::ToBase64String($finalBytes)
      $finalOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$finalB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $finalOut.Trim()
        throw "[swarm-va $hostName] config/service setup failed (rc=$LASTEXITCODE)"
      }
      Write-Host $finalOut.Trim()

      # Step 6: verify service active + token sink populated
      Start-Sleep -Seconds 5
      $verifyDeadline = (Get-Date).AddSeconds(30)
      $serviceActive = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active nexus-vault-agent.service" 2>&1 | Out-String).Trim()
        if ($status -eq 'active') { $serviceActive = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $serviceActive) {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[swarm-va $hostName] nexus-vault-agent.service failed to reach active within 30s"
      }
      Write-Host "[swarm-va $hostName] nexus-vault-agent.service active"

      # Token sink populated? (proves AppRole auth succeeded)
      $tokenCheck = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT" 2>&1 | Out-String).Trim()
      if ($tokenCheck -notmatch 'TOKEN_PRESENT') {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[swarm-va $hostName] AppRole login appears to have failed (token sink empty)"
      }
      Write-Host "[swarm-va $hostName] AppRole authenticated; token sink populated"
    PWSH
  }

  # Destroy provisioner: stop + disable + remove the agent. Idempotent.
  # Per terraform's destroy-provisioner restrictions, only `self`,
  # `count.index`, and `each.key` are reachable -- vm_ip and ssh_user are
  # captured into triggers above for `self.triggers.*` access here.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName    = '${each.key}'
      $vmIp    = '${self.triggers.destroy_vm_ip}'
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[swarm-va destroy] $${host}: stopping nexus-vault-agent + cleaning files"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vault-agent.service 2>/dev/null; sudo rm -rf /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent /etc/systemd/system/nexus-vault-agent.service; sudo systemctl daemon-reload" 2>$null
      exit 0
    PWSH
  }
}
