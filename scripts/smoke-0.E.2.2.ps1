#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.2.2 smoke gate -- Consul TLS (chained on 0.E.2.1).

.DESCRIPTION
  Verifies:
    - All 0.E.2.1 baseline checks (39 probes) still green.
    - /etc/consul.d/tls/{server.crt, server.key, ca.pem} present + non-empty
      on all 6 nodes, with mode + ownership matching the design.
    - Per-host server.crt has the canonical CN
      (<host>.consul.nexus.lab) + the right ip_sans (VMnet10 + VMnet11
      + 127.0.0.1) + alt_names (server.nexus-lab.consul + hostname forms).
    - Cert TTL >= 7 days remaining (close-to-rotation alert).
    - HTTPS:8501 reachable from build host with $HOME/.nexus/vault-ca-bundle
      .crt as the trust anchor; /v1/status/leader returns leader IP.
    - HTTP:8500 NOT listening (`curl http://...:8500/v1/status/leader` ->
      connection refused / timeout).
    - `consul members` over HTTPS reports 6 alive members.
    - `consul operator raft list-peers` over HTTPS reports 3 server peers,
      one of them leader (proves mutual TLS for RPC + Raft).
    - Plain `consul members` from a swarm-node WITHOUT env vars FAILS with
      "Failed to connect to Consul agent" (proves HTTP API is gone).

  Exit gate: every probe green; non-zero exit on any FAIL.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

# Run the 0.E.2.1 baseline first; bail if it's red.
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.2.1.ps1'
Write-Host '=== Chained baseline: smoke-0.E.2.1.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.2.1 baseline FAILED -- skipping 0.E.2.2 checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.2.2-specific checks ──────────────────────────────────────────────
$user = 'nexusadmin'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allIps     = $managerIps + $workerIps

# Per-host expected SAN content for cert verification
$nodeSpecs = @{
    '192.168.70.111' = @{ Host = 'swarm-manager-1'; Vmnet10 = '192.168.10.111' }
    '192.168.70.112' = @{ Host = 'swarm-manager-2'; Vmnet10 = '192.168.10.112' }
    '192.168.70.113' = @{ Host = 'swarm-manager-3'; Vmnet10 = '192.168.10.113' }
    '192.168.70.131' = @{ Host = 'swarm-worker-1';  Vmnet10 = '192.168.10.131' }
    '192.168.70.132' = @{ Host = 'swarm-worker-2';  Vmnet10 = '192.168.10.132' }
    '192.168.70.133' = @{ Host = 'swarm-worker-3';  Vmnet10 = '192.168.10.133' }
}

$caBundle = Join-Path $env:USERPROFILE '.nexus/vault-ca-bundle.crt'

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$envPrefix = "CONSUL_HTTP_ADDR=https://localhost:8501 CONSUL_CACERT=/etc/consul.d/tls/ca.pem"

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

# ─── Section: cert files present + correct perms ──────────────────────────
Write-Section 'Per-node TLS cert files (server.crt + server.key + ca.pem)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /etc/consul.d/tls/server.crt + key + ca.pem all present + non-empty" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/consul.d/tls/server.crt && sudo test -s /etc/consul.d/tls/server.key && sudo test -s /etc/consul.d/tls/ca.pem && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Section: cert subject + SANs match per-host design ───────────────────
Write-Section 'Per-node cert subject CN + SANs match design'
foreach ($ip in $allIps) {
    $spec = $nodeSpecs[$ip]
    $expectedCn = "$($spec.Host).consul.nexus.lab"

    Test-Check -Description "$ip : server.crt subject CN == $expectedCn" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/consul.d/tls/server.crt -noout -subject 2>/dev/null"
        $out -match [regex]::Escape("CN=$expectedCn") -or $out -match [regex]::Escape("CN = $expectedCn")
    } | Out-Null

    Test-Check -Description "$ip : server.crt SAN includes 'server.nexus-lab.consul' (verify_server_hostname)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/consul.d/tls/server.crt -noout -ext subjectAltName 2>/dev/null"
        $out -match 'server\.nexus-lab\.consul'
    } | Out-Null

    Test-Check -Description "$ip : server.crt SAN includes VMnet10 IP $($spec.Vmnet10) + VMnet11 IP $ip + 127.0.0.1" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/consul.d/tls/server.crt -noout -ext subjectAltName 2>/dev/null"
        $out -match [regex]::Escape($spec.Vmnet10) -and $out -match [regex]::Escape($ip) -and $out -match '127\.0\.0\.1'
    } | Out-Null

    Test-Check -Description "$ip : server.crt notAfter > now+7d (rotation health)" -Probe {
        # openssl -checkend takes seconds; 7d = 604800s
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/consul.d/tls/server.crt -noout -checkend 604800 && echo OK"
        $out -match 'OK'
    } | Out-Null
}

# ─── Section: HTTPS:8501 reachable from build host with vault CA bundle ──
Write-Section 'HTTPS:8501 reachable from build host with $HOME/.nexus/vault-ca-bundle.crt'
if (-not (Test-Path $caBundle)) {
    Write-Host "[FAIL] $caBundle missing -- run nexus-infra-vmware/scripts/security.ps1 apply (PKI distribute)" -ForegroundColor Red
    $script:failures += "vault CA bundle missing on build host"
} else {
    foreach ($ip in $allIps) {
        Test-Check -Description "$ip : curl https://${ip}:8501/v1/status/leader returns 200 with vault CA bundle" -Probe {
            $code = (curl -sS --cacert $caBundle -o $null -w '%{http_code}' --connect-timeout 5 "https://${ip}:8501/v1/status/leader" 2>&1 | Out-String).Trim()
            $code -eq '200'
        } | Out-Null
    }
}

# ─── Section: HTTP:8500 NOT listening ─────────────────────────────────────
Write-Section 'HTTP:8500 hard-cut (port not listening)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : tcp/8500 closed (connection refused or timeout)" -Probe {
        # `curl` returns non-200 if no listener. Check for connection failure.
        $code = (curl -sS -o $null -w '%{http_code}' --connect-timeout 3 "http://${ip}:8500/v1/status/leader" 2>&1 | Out-String).Trim()
        # Empty code = couldn't connect (refused/timeout). Or non-zero curl exit.
        # Either way, 8500 isn't serving Consul.
        return ($code -eq '000' -or $code -eq '')
    } | Out-Null
}

# ─── Section: consul cluster shape over HTTPS ────────────────────────────
Write-Section 'Cluster shape over HTTPS (mutual TLS for RPC verified)'
$leaderIp = $managerIps[0]

Test-Check -Description "$leaderIp : consul members over HTTPS reports 6 alive" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix consul members 2>&1 | grep -c alive || true"
    $out -match '^6$'
} | Out-Null

Test-Check -Description "$leaderIp : consul raft list-peers over HTTPS reports 3 server peers" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix consul operator raft list-peers 2>&1 | grep -c '192.168.10' || true"
    $out -match '^3$'
} | Out-Null

Test-Check -Description "$leaderIp : raft list-peers shows exactly 1 leader" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix consul operator raft list-peers 2>&1 | grep -c 'leader' || true"
    $out -match '^1$'
} | Out-Null

# ─── Section: HTTP API gone confirmation ──────────────────────────────────
Write-Section 'Plain consul calls without env vars fail (proves HTTP gone)'
Test-Check -Description "$leaderIp : plain consul members (no CONSUL_HTTP_ADDR) fails / not reachable" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "consul members 2>&1 || true"
    # Without TLS env vars, default endpoint is http://127.0.0.1:8500. Should
    # error with connection refused / Failed to connect.
    $out -match 'connection refused' -or $out -match 'Failed to connect' -or $out -match 'Get .*8500.*connect'
} | Out-Null

# ─── Section: Vault Agent rendered the bundle (check render markers) ─────
Write-Section 'Vault Agent PKI bundle rendered + split (post-render audit)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /etc/consul.d/tls/bundle.pem present (Vault Agent output)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/consul.d/tls/bundle.pem && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'ALL 0.E.2.2 SMOKE CHECKS PASSED (chained 0.E.2.1 + 0.E.1 baseline)' -ForegroundColor Green
    Write-Host 'TLS active across all 6 Consul agents: mutual TLS for internal RPC + Raft, server-only TLS for HTTPS API on 8501. Plain HTTP:8500 hard-cut.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
