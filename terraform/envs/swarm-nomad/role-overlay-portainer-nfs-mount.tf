/*
 * role-overlay-portainer-nfs-mount.tf -- Phase 0.E.4a setup (manager side)
 *
 * Mounts the NFSv4 export from nexus-gateway on each of the 3 swarm
 * managers at /var/lib/portainer-data. The Portainer CE Server replica's
 * /data will bind-mount from here, so a Swarm reschedule onto a different
 * manager picks up the same state.
 *
 * Pre-reqs:
 *   - nexus-infra-vmware/foundation env applied with
 *     role-overlay-gateway-nfs-portainer.tf (NFSv4 export at
 *     /srv/nfs/portainer-data, accessible from manager IPs).
 *
 * Choreography (single PWSH local-exec, parallel per-manager):
 *   Stage 1: apt install nfs-common (idempotent; provides mount.nfs4 +
 *     idmapd; lab is non-Kerberos so idmapd is mostly cosmetic).
 *   Stage 2: mkdir /var/lib/portainer-data (root:root 0755).
 *   Stage 3: ensure /etc/fstab entry exists (idempotent via marker line);
 *     mount via systemd's `automount` or direct `mount -a`.
 *   Stage 4: verify mount via `findmnt /var/lib/portainer-data`.
 *
 * Idempotency:
 *   - All stages: shell-side guards on existence + content. Re-applies
 *     are no-op-fast.
 *
 * Selective ops: var.enable_portainer_nfs_mount AND
 *                var.enable_swarm_manager_X (per-manager toggle inherited
 *                from base swarm cluster).
 *
 * Mount options (NFSv4):
 *   - vers=4.2  -- enforce v4.2 (negotiates down to 4.1/4.0 if server
 *                  doesn't support 4.2; lab gateway is on Debian 13
 *                  nfs-utils 2.8+ which is 4.2-capable).
 *   - hard      -- block on server outage instead of returning errors
 *                  (Portainer's BoltDB writes shouldn't see I/O errors).
 *   - rw,bg,_netdev -- bg = background-mount on boot if server unreachable;
 *                      _netdev = wait for network-online.target.
 *   - sec=sys   -- match server's sec=sys (no Kerberos in the lab).
 */

locals {
  portainer_nfs_manager_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113" },
  ]
}

resource "null_resource" "portainer_nfs_mount" {
  count = var.enable_portainer_nfs_mount ? 1 : 0

  triggers = {
    nfs_server   = var.portainer_nfs_server
    remote_path  = var.portainer_nfs_remote_path
    local_mount  = var.portainer_data_local_mount
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    overlay_v = "2" # v2 = mount via NFSv4 pseudo-root path `:/` instead of `:/srv/nfs/portainer-data`. The server-side export uses `fsid=0`, which makes that path the NFSv4 pseudo-root (visible to clients as `/`). Clients accessing the same path under the original name get `mount.nfs4: No such file or directory` because that path doesn't exist in the pseudo-root namespace. The single-export single-pseudo-root pattern is the simplest NFSv4 layout: one export at fsid=0, clients mount via `:/`. v1 = original (used `:/srv/nfs/portainer-data` -- failed with ENOENT against the pseudo-root).
  }

  depends_on = [null_resource.swarm_init_and_join]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.swarm_node_user}'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $nfsServer  = '${var.portainer_nfs_server}'
      $remotePath = '${var.portainer_nfs_remote_path}'
      $localMount = '${var.portainer_data_local_mount}'

      $managers = @(
%{for spec in local.portainer_nfs_manager_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # Bash script body. Single-quoted here-string -- terraform-side values
      # substituted via -replace below. Bash variables escaped via $$ for
      # terraform per memory/feedback_terraform_heredoc_powershell.md.
      $bashTmpl = @'
set -euo pipefail
NFS_SERVER='__NFS_SERVER__'
REMOTE_PATH='__REMOTE_PATH__'
LOCAL_MOUNT='__LOCAL_MOUNT__'
MARKER='# managed by terraform/envs/swarm-nomad/role-overlay-portainer-nfs-mount.tf'

# ── Stage 1: install nfs-common (idempotent) ───────────────────────────
if ! dpkg -s nfs-common >/dev/null 2>&1; then
  echo "[portainer-nfs-mount] installing nfs-common"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common
else
  echo "[portainer-nfs-mount] nfs-common already installed"
fi

# ── Stage 2: create local mount point ──────────────────────────────────
sudo mkdir -p "$LOCAL_MOUNT"
sudo chown root:root "$LOCAL_MOUNT"
sudo chmod 0755 "$LOCAL_MOUNT"

# ── Stage 3: add /etc/fstab entry (idempotent) ─────────────────────────
# NFSv4 pseudo-root: the server's `fsid=0` export becomes the client's
# root namespace, so we mount via "$NFS_SERVER:/" (NOT $REMOTE_PATH --
# that path doesn't exist in the pseudo-root). REMOTE_PATH is kept in
# the trigger for documentation + matches foundation env's export path.
if ! grep -qF "$MARKER" /etc/fstab; then
  echo "[portainer-nfs-mount] adding /etc/fstab entry"
  echo "" | sudo tee -a /etc/fstab > /dev/null
  echo "$MARKER" | sudo tee -a /etc/fstab > /dev/null
  echo "$NFS_SERVER:/  $LOCAL_MOUNT  nfs4  rw,hard,bg,_netdev,vers=4.2,sec=sys  0  0" | sudo tee -a /etc/fstab > /dev/null
elif ! grep -qE "^$NFS_SERVER:/[[:space:]]+$LOCAL_MOUNT" /etc/fstab; then
  # Marker present but stale path (e.g. v1 left :/srv/nfs/portainer-data).
  # Drop the stale lines (marker + the next non-comment data line) and
  # re-add the correct entry.
  echo "[portainer-nfs-mount] correcting stale /etc/fstab entry to use NFSv4 pseudo-root"
  sudo sed -i "\|$MARKER|,+1d" /etc/fstab
  echo "" | sudo tee -a /etc/fstab > /dev/null
  echo "$MARKER" | sudo tee -a /etc/fstab > /dev/null
  echo "$NFS_SERVER:/  $LOCAL_MOUNT  nfs4  rw,hard,bg,_netdev,vers=4.2,sec=sys  0  0" | sudo tee -a /etc/fstab > /dev/null
else
  echo "[portainer-nfs-mount] /etc/fstab already has portainer-data entry (idempotent skip)"
fi

# ── Stage 4: mount + verify ────────────────────────────────────────────
if findmnt "$LOCAL_MOUNT" >/dev/null 2>&1; then
  echo "[portainer-nfs-mount] $LOCAL_MOUNT already mounted (idempotent)"
else
  echo "[portainer-nfs-mount] mounting $LOCAL_MOUNT"
  sudo mount -a
  sleep 1
  if ! findmnt "$LOCAL_MOUNT" >/dev/null 2>&1; then
    echo "[portainer-nfs-mount] ERROR: mount -a did not bring up $LOCAL_MOUNT" >&2
    sudo dmesg | tail -10 >&2
    exit 1
  fi
fi

# Write+read sanity test (proves rw + no_root_squash work end-to-end).
TESTFILE="$LOCAL_MOUNT/.tf-mount-probe-$(hostname)"
echo "test-$(date -u +%s)" | sudo tee "$TESTFILE" > /dev/null
sudo cat "$TESTFILE" >/dev/null
sudo rm -f "$TESTFILE"

echo "--- findmnt $LOCAL_MOUNT ---"
findmnt "$LOCAL_MOUNT"
echo "[portainer-nfs-mount] OK"
'@

      $bashRendered = $bashTmpl `
        -replace '__NFS_SERVER__', $nfsServer `
        -replace '__REMOTE_PATH__', $remotePath `
        -replace '__LOCAL_MOUNT__', $localMount
      $bashLf = $bashRendered -replace "`r`n", "`n"
      $bashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bashLf))

      Write-Host ""
      Write-Host "[portainer-nfs-mount] mounting $remotePath on 3 managers from $nfsServer (parallel)"

      $errors = $managers | ForEach-Object -ThrottleLimit 3 -Parallel {
        $node = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $b64 = $using:bashB64
        $out = (ssh @sshOpts "$sshUser@$($node.VmIp)" "echo '$b64' | base64 -d | bash" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] mount failed (rc=$LASTEXITCODE):`n$out"
        }
        Write-Host "[$($node.Host)]`n$out"
        return $null
      } | Where-Object { $_ -ne $null }

      if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[portainer-nfs-mount] failed on $($errors.Count) manager(s)"
      }
      Write-Host "[portainer-nfs-mount] OK -- $localMount mounted on all 3 managers"
    PWSH
  }

  # Destroy: unmount + remove fstab entry. Keeps nfs-common installed.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $managerIps = @('192.168.70.111','192.168.70.112','192.168.70.113')
      $cleanup = @'
set -euo pipefail
sudo umount /var/lib/portainer-data 2>/dev/null || true
sudo sed -i '/managed by terraform.envs.swarm-nomad.role-overlay-portainer-nfs-mount/d; /portainer-data/d' /etc/fstab
echo "[portainer-nfs-mount destroy] cleaned"
'@
      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($cleanup -replace "`r`n", "`n")))
      foreach ($ip in $managerIps) {
        ssh @sshOpts "$sshUser@$ip" "echo '$b64' | base64 -d | bash" 2>$null
      }
      exit 0
    PWSH
  }
}
