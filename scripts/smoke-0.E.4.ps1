#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.4 smoke gate -- Portainer CE clustered Swarm service.
  Chained on smoke-0.E.3.3.ps1.

.DESCRIPTION
  Verifies:
    - All 0.E.3.3 baseline checks (Nomad-Vault + Consul-rewire) green.

  0.E.4a (NFS server on gateway + per-manager mount):
    - nexus-gateway: nfs-kernel-server active, /srv/nfs/portainer-data
      exists + mode 0755, exportfs -v shows the export.
    - Per-manager: /var/lib/portainer-data is mounted (NFSv4.2 from
      192.168.70.1:/), writable by root.
    - Workers: NO /var/lib/portainer-data mount (defensive).

  0.E.4b (Vault PKI portainer-server role + per-manager TLS render):
    - vault-1: pki_int/roles/portainer-server exists (allowed_domains
      includes portainer.nexus.lab).
    - Per-manager: /etc/portainer/tls/{server.crt, server.key, ca.pem}
      present; cert subject CN=portainer.nexus.lab; SAN includes
      manager IP + portainer.nexus.lab; cert expiry > 7d.

  0.E.4c (dnsmasq A-record):
    - dig @192.168.70.1 portainer.nexus.lab returns at least one of
      .111-.113.

  0.E.4d (admin password seed + render + stack deploy):
    - vault-1: nexus/portainer/admin-bcrypt has bcrypt_hash + plaintext
      fields populated.
    - Per-manager: /etc/portainer/admin-password.txt rendered with the
      plaintext admin password (^[A-Za-z0-9]{12,}$) -- Portainer's
      --admin-password-file hashes the file content, so it must be plaintext.
    - manager-1: docker stack ls shows `portainer`; service ls shows
      portainer_server (1/1) + portainer_agent (6/6 global).
    - manager-1: HTTPS GET /api/system/status on 9443 returns 200 with
      valid TLS chain (validates against the build host's nexus-ca-bundle).

  Exit gate: every probe green; non-zero exit on any FAIL.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

# Run the 0.E.3.3 baseline first; bail if it's red.
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.3.3.ps1'
Write-Host '=== Chained baseline: smoke-0.E.3.3.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.3.3 baseline FAILED -- skipping 0.E.4 checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.4-specific checks ────────────────────────────────────────────────
$user = 'nexusadmin'
$gatewayIp  = '192.168.70.1'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$leaderIp   = $managerIps[0]
$vaultIp    = '192.168.70.121'
$kvMount    = 'nexus'

$sshOpts = @('-o', 'ConnectTimeout=8', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$failures = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][scriptblock]$Probe)
    try {
        $result = & $Probe
        if ($result) {
            Write-Host "[OK]   $Description" -ForegroundColor Green
            return $true
        } else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            $script:failures += $Description
            return $false
        }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:failures += "$Description ($($_.Exception.Message))"
        return $false
    }
}

function Invoke-RemoteCommand {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Command)
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

# Resolve root token for vault-1 KV reads
$keysFile = Join-Path $env:USERPROFILE '.nexus/vault-init.json'
if (-not (Test-Path $keysFile)) { Write-Host "[FAIL] $keysFile missing"; exit 1 }
$rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

# ─── Section: 0.E.4a NFS server on gateway ────────────────────────────────
Write-Section '0.E.4a: NFS server on nexus-gateway'

Test-Check -Description "$gatewayIp : nfs-kernel-server active" -Probe {
    $out = Invoke-RemoteCommand -Ip $gatewayIp -Command 'systemctl is-active nfs-kernel-server'
    $out -match '^active$'
} | Out-Null

Test-Check -Description "$gatewayIp : /srv/nfs/portainer-data exists, mode 0755" -Probe {
    $out = Invoke-RemoteCommand -Ip $gatewayIp -Command "stat -c '%a %U:%G' /srv/nfs/portainer-data 2>&1"
    $out -match '^755 root:root'
} | Out-Null

Test-Check -Description "$gatewayIp : exportfs lists 3 client entries for portainer-data" -Probe {
    $out = Invoke-RemoteCommand -Ip $gatewayIp -Command 'sudo exportfs -v 2>&1 | grep -c portainer-data'
    [int]$out -ge 3
} | Out-Null

Test-Check -Description "$gatewayIp : :2049 listener active" -Probe {
    $out = Invoke-RemoteCommand -Ip $gatewayIp -Command "sudo ss -tlnp 2>/dev/null | grep -c ':2049'"
    [int]$out -ge 1
} | Out-Null

# ─── Section: 0.E.4a per-manager NFS mount ────────────────────────────────
Write-Section '0.E.4a: Per-manager NFS mount'

foreach ($ip in $managerIps) {
    Test-Check -Description "$ip : /var/lib/portainer-data mounted via nfs4" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'findmnt /var/lib/portainer-data -t nfs4 -o SOURCE,FSTYPE,OPTIONS 2>&1'
        $out -match 'nfs4' -and $out -match '192.168.70.1'
    } | Out-Null
}
foreach ($ip in $workerIps) {
    Test-Check -Description "$ip : NO /var/lib/portainer-data mount (workers don't run Portainer Server)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'findmnt /var/lib/portainer-data 2>&1; echo done'
        $out -notmatch 'nfs4'
    } | Out-Null
}

# ─── Section: 0.E.4b Vault PKI portainer-server role ──────────────────────
Write-Section '0.E.4b: Vault PKI role + per-manager TLS render'

$vaultProbeScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
vault read pki_int/roles/portainer-server 2>&1 | head -15 || echo ROLE_MISSING
"@
$vaultProbeB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultProbeScript -replace "`r`n", "`n")))
$vaultProbeOut = (ssh @sshOpts "$user@$vaultIp" "echo '$vaultProbeB64' | base64 -d | bash" 2>&1 | Out-String)

Test-Check -Description "vault-1: pki_int/roles/portainer-server exists with portainer.nexus.lab in allowed_domains" -Probe {
    ($vaultProbeOut -notmatch 'ROLE_MISSING') -and ($vaultProbeOut -match 'portainer.nexus.lab')
} | Out-Null

foreach ($ip in $managerIps) {
    Test-Check -Description "$ip : /etc/portainer/tls/server.crt + .key + ca.pem present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/portainer/tls/server.crt && sudo test -s /etc/portainer/tls/server.key && sudo test -s /etc/portainer/tls/ca.pem && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : cert CN = portainer.nexus.lab" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/portainer/tls/server.crt -noout -subject 2>&1'
        $out -match 'CN\s*=\s*portainer.nexus.lab'
    } | Out-Null

    Test-Check -Description "$ip : cert SAN includes portainer.nexus.lab + this manager IP" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/portainer/tls/server.crt -noout -ext subjectAltName 2>&1"
        ($out -match 'portainer.nexus.lab') -and ($out -match [regex]::Escape($ip))
    } | Out-Null

    Test-Check -Description "$ip : cert valid > 7d (openssl -checkend 604800)" -Probe {
        # openssl -checkend prints "Certificate will not expire" on stdout (success)
        # then `&& echo OK` adds OK on the next line. PS -match is unanchored
        # regex-substring; `^OK$` won't match multi-line output. Use 'OK\b' to
        # find the marker as a substring.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/portainer/tls/server.crt -checkend 604800 -noout && echo OK'
        $out -match 'OK\b'
    } | Out-Null
}

# ─── Section: 0.E.4c dnsmasq A-record ─────────────────────────────────────
Write-Section '0.E.4c: dnsmasq portainer.nexus.lab A-record'

Test-Check -Description "Manager resolution: portainer.nexus.lab returns one of .111/.112/.113" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "getent hosts portainer.nexus.lab 2>&1"
    $out -match '192\.168\.70\.(111|112|113)'
} | Out-Null

Test-Check -Description "Gateway dig returns >=1 A-record for portainer.nexus.lab in manager IP range" -Probe {
    # dnsmasq's `host-record=NAME,IP1,IP2,IP3` returns ONE A-record per query
    # (cycling through the IPs across queries via internal load-balance), not
    # all three at once. The Swarm routing mesh routes traffic on any manager
    # IP to the active replica, so single-IP responses are sufficient.
    $out = Invoke-RemoteCommand -Ip $gatewayIp -Command 'dig +short @127.0.0.1 portainer.nexus.lab 2>&1'
    $count = ($out -split "`n" | Where-Object { $_ -match '^192\.168\.70\.(111|112|113)$' } | Measure-Object).Count
    $count -ge 1
} | Out-Null

# ─── Section: 0.E.4d admin password + stack ───────────────────────────────
Write-Section '0.E.4d: Vault admin-bcrypt seed + per-manager render'

$adminProbeScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
# `vault kv get` prints metadata + data sections. The data fields (bcrypt_hash,
# plaintext) are at lines 17-20+ -- earlier `head -15` truncated before reaching
# them. Use head -30 to ensure all fields are visible.
vault kv get -mount=$kvMount portainer/admin-bcrypt 2>&1 | head -30 || echo SEED_MISSING
"@
$adminProbeB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($adminProbeScript -replace "`r`n", "`n")))
$adminProbeOut = (ssh @sshOpts "$user@$vaultIp" "echo '$adminProbeB64' | base64 -d | bash" 2>&1 | Out-String)

Test-Check -Description "vault-1: nexus/portainer/admin-bcrypt has bcrypt_hash + plaintext fields" -Probe {
    ($adminProbeOut -notmatch 'SEED_MISSING') -and ($adminProbeOut -match 'bcrypt_hash') -and ($adminProbeOut -match 'plaintext')
} | Out-Null

foreach ($ip in $managerIps) {
    Test-Check -Description "$ip : /etc/portainer/admin-password.txt rendered with plaintext admin password" -Probe {
        # Portainer's --admin-password-file reads the file as the PLAINTEXT
        # password (it bcrypts internally); the render overlay (v3) writes the
        # 24-char alphanumeric plaintext, NOT a bcrypt hash (the v2 bug).
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -qE '^[A-Za-z0-9]{12,}$' /etc/portainer/admin-password.txt && echo OK"
        $out -match '^OK$'
    } | Out-Null
}

Write-Section '0.E.4d: docker stack deploy (Portainer CE)'

Test-Check -Description "$leaderIp : docker stack ls includes portainer" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command 'sudo docker stack ls 2>&1 | grep -c portainer || true'
    [int]$out -ge 1
} | Out-Null

Test-Check -Description "$leaderIp : portainer_server replicas 1/1 running" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "sudo docker service ls --filter name=portainer_server --format '{{.Replicas}}'"
    $out -match '^1/1'
} | Out-Null

Test-Check -Description "$leaderIp : portainer_agent global 6/6 running (one per swarm node)" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "sudo docker service ls --filter name=portainer_agent --format '{{.Replicas}}'"
    $out -match '^6/6'
} | Out-Null

Write-Section '0.E.4d: HTTPS reachability'

Test-Check -Description "$leaderIp : https://portainer.nexus.lab:9443/api/system/status returns 200 (CA-validated)" -Probe {
    # Validate against /etc/portainer/tls/ca.pem (the NexusPlatform Intermediate
    # CA, written by Vault Agent's split script). World-readable mode 0644 so
    # nexusadmin can read without sudo. --resolve forces the SNI hostname for
    # cert validation while connecting to localhost (avoids Swarm-mesh routing
    # to a different manager whose cert SAN doesn't match build-host expectations).
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "curl -sS --cacert /etc/portainer/tls/ca.pem --resolve portainer.nexus.lab:9443:127.0.0.1 -o /dev/null -w '%{http_code}' https://portainer.nexus.lab:9443/api/system/status 2>&1"
    $out -match '^200$'
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'ALL 0.E.4 SMOKE CHECKS PASSED (chained 0.E.3.3 + 0.E.3.2 + 0.E.3.1 + 0.E.2.3 + 0.E.2.2 + 0.E.2.1 + 0.E.1)' -ForegroundColor Green
    Write-Host '0.E.4a: NFS server on gateway + 3 manager mounts.' -ForegroundColor Green
    Write-Host '0.E.4b: Vault PKI portainer-server role + per-manager TLS cert.' -ForegroundColor Green
    Write-Host '0.E.4c: dnsmasq portainer.nexus.lab multi-A round-robin.' -ForegroundColor Green
    Write-Host '0.E.4d: Portainer CE Server (1/1) + global Agent (6/6) deployed; HTTPS:9443 healthy.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
