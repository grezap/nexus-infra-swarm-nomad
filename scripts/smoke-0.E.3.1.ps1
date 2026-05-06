#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.3.1 smoke gate -- Nomad TLS (chained on 0.E.2.3).

.DESCRIPTION
  Verifies:
    - All 0.E.2.3 baseline checks (Consul ACL + TLS + gossip + Swarm cluster
      shape) still green.
    - /etc/nomad.d/tls/{server.crt, server.key, ca.pem} present + non-empty
      on all 6 nodes.
    - /etc/ssl/certs/nomad-ca.pem present (operator-readable CA copy).
    - Per-host server.crt has the canonical CN (<host>.nomad.nexus.lab) +
      the right Nomad-specific SAN (server.global.nomad on managers,
      client.global.nomad on workers) + IPs (VMnet10 + VMnet11 + 127.0.0.1).
    - Cert TTL >= 7 days remaining (rotation health).
    - HTTPS:4646 reachable on each manager from build host with the Vault
      CA bundle as trust anchor; /v1/status/leader returns 200.
    - HTTP:4646 plain (no TLS) is rejected -- proves TLS is enforced.
    - `nomad server members` over HTTPS reports 3 alive servers.
    - `nomad node status` over HTTPS reports 3 ready clients.
    - /etc/nomad.d/40-tls.hcl present with `http = true`, `rpc = true`,
      `verify_server_hostname = true`.
    - /etc/vault-agent/40-template-nomad-tls.hcl present (Vault Agent
      template registered).

  Exit gate: every probe green; non-zero exit on any FAIL.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

# Run the 0.E.2.3 baseline first; bail if it's red.
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.2.3.ps1'
Write-Host '=== Chained baseline: smoke-0.E.2.3.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.2.3 baseline FAILED -- skipping 0.E.3.1 checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.3.1-specific checks ──────────────────────────────────────────────
$user = 'nexusadmin'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allIps     = $managerIps + $workerIps
$leaderIp   = $managerIps[0]

# Per-host expected SAN content for cert verification
$nodeSpecs = @{
    '192.168.70.111' = @{ Host = 'swarm-manager-1'; Vmnet10 = '192.168.10.111'; Role = 'manager'; NomadSan = 'server.global.nomad' }
    '192.168.70.112' = @{ Host = 'swarm-manager-2'; Vmnet10 = '192.168.10.112'; Role = 'manager'; NomadSan = 'server.global.nomad' }
    '192.168.70.113' = @{ Host = 'swarm-manager-3'; Vmnet10 = '192.168.10.113'; Role = 'manager'; NomadSan = 'server.global.nomad' }
    '192.168.70.131' = @{ Host = 'swarm-worker-1';  Vmnet10 = '192.168.10.131'; Role = 'worker';  NomadSan = 'client.global.nomad' }
    '192.168.70.132' = @{ Host = 'swarm-worker-2';  Vmnet10 = '192.168.10.132'; Role = 'worker';  NomadSan = 'client.global.nomad' }
    '192.168.70.133' = @{ Host = 'swarm-worker-3';  Vmnet10 = '192.168.10.133'; Role = 'worker';  NomadSan = 'client.global.nomad' }
}

$caBundle = Join-Path $env:USERPROFILE '.nexus/vault-ca-bundle.crt'
$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$nomadEnv = "NOMAD_ADDR=https://localhost:4646 NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem"

# Post-0.E.3.2: Nomad ACL enforced. Resolve mgmt token from Vault KV;
# fall back to tokenless (pre-0.E.3.2 baseline behavior).
$nomadMgmtToken = ''
$keysFileNomad = Join-Path $env:USERPROFILE '.nexus/vault-init.json'
if (Test-Path $keysFileNomad) {
    try {
        $rootTokenN = (Get-Content $keysFileNomad | ConvertFrom-Json).root_token
        if ($rootTokenN) {
            $kvProbeN = @"
set -euo pipefail
export VAULT_TOKEN='$rootTokenN'
VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault kv get -field=management_token -mount=nexus swarm/nomad-bootstrap-token 2>/dev/null || true
"@
            $kvProbeNB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kvProbeN -replace "`r`n", "`n")))
            $kvOutN = (ssh @sshOpts "$user@192.168.70.121" "echo '$kvProbeNB64' | base64 -d | bash" 2>&1 | Out-String).Trim()
            if ($kvOutN -and $kvOutN.Length -ge 36) { $nomadMgmtToken = $kvOutN }
        }
    } catch { }
}
$nomadTokenEnv = if ($nomadMgmtToken) { "NOMAD_TOKEN='$nomadMgmtToken'" } else { '' }

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
    Test-Check -Description "$ip : /etc/nomad.d/tls/server.crt + key + ca.pem all present + non-empty" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nomad.d/tls/server.crt && sudo test -s /etc/nomad.d/tls/server.key && sudo test -s /etc/nomad.d/tls/ca.pem && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/ssl/certs/nomad-ca.pem present (operator-readable CA copy)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'test -r /etc/ssl/certs/nomad-ca.pem && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Section: cert subject CN + SANs match per-host design ───────────────
Write-Section 'Per-node cert subject CN + Nomad-specific SAN match design'
foreach ($ip in $allIps) {
    $spec = $nodeSpecs[$ip]
    $expectedCn = "$($spec.Host).nomad.nexus.lab"
    $expectedNomadSan = $spec.NomadSan

    Test-Check -Description "$ip : server.crt subject CN == $expectedCn" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/nomad.d/tls/server.crt -noout -subject 2>/dev/null"
        $out -match [regex]::Escape("CN=$expectedCn") -or $out -match [regex]::Escape("CN = $expectedCn")
    } | Out-Null

    Test-Check -Description "$ip : server.crt SAN includes '$expectedNomadSan' (verify_server_hostname requires this)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/nomad.d/tls/server.crt -noout -ext subjectAltName 2>/dev/null"
        $out -match [regex]::Escape($expectedNomadSan)
    } | Out-Null

    Test-Check -Description "$ip : server.crt SAN includes VMnet10 IP $($spec.Vmnet10) + VMnet11 IP $ip + 127.0.0.1" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/nomad.d/tls/server.crt -noout -ext subjectAltName 2>/dev/null"
        $out -match [regex]::Escape($spec.Vmnet10) -and $out -match [regex]::Escape($ip) -and $out -match '127\.0\.0\.1'
    } | Out-Null

    Test-Check -Description "$ip : server.crt notAfter > now+7d (rotation health)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo openssl x509 -in /etc/nomad.d/tls/server.crt -noout -checkend 604800 && echo OK"
        $out -match 'OK'
    } | Out-Null
}

# ─── Section: Nomad config files ──────────────────────────────────────────
Write-Section 'Per-node Nomad TLS config files'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : 40-tls.hcl contains http = true + rpc = true + verify_server_hostname = true" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -qE "http[[:space:]]+=[[:space:]]+true" /etc/nomad.d/40-tls.hcl && sudo grep -qE "rpc[[:space:]]+=[[:space:]]+true" /etc/nomad.d/40-tls.hcl && sudo grep -qE "verify_server_hostname[[:space:]]+=[[:space:]]+true" /etc/nomad.d/40-tls.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : 40-template-nomad-tls.hcl present (Vault Agent template registered)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/vault-agent/40-template-nomad-tls.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Section: HTTPS:4646 reachable from build host with vault CA bundle ──
# Same X509Chain trick as the consul-tls smoke gate. Vault PKI root +
# pki_int intermediate must both be in the chain to validate the leaf;
# fetch the intermediate from a node and add to ExtraStore.
Write-Section 'HTTPS:4646 reachable from build host (mTLS chain validates against vault CA bundle)'
if (-not (Test-Path $caBundle)) {
    Write-Host "[FAIL] $caBundle missing" -ForegroundColor Red
    $script:failures += 'vault CA bundle missing on build host'
} else {
    $bundlePem = Get-Content -Raw $caBundle
    $bundleCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $bundleCerts.ImportFromPem($bundlePem)
    $intermediatePem = (ssh @sshOpts "$user@$leaderIp" 'sudo cat /etc/nomad.d/tls/ca.pem' 2>$null | Out-String)
    if ($intermediatePem -match 'BEGIN CERTIFICATE') { $bundleCerts.ImportFromPem($intermediatePem) }
    $script:trustStore = $bundleCerts

    # Only managers expose HTTPS:4646 to operator clients (workers ship
    # with addresses.http = "127.0.0.1" -- per nomad-client.hcl.tpl --
    # so worker port 4646 binds to localhost only). Per-manager probe.
    foreach ($ip in $managerIps) {
        Test-Check -Description "$ip : HTTPS:4646 returns 200 + cert chain validates against vault CA bundle" -Probe {
            $tcp = $null; $stream = $null; $ssl = $null
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $iar = $tcp.BeginConnect($ip, 4646, $null, $null)
                if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { return $false }
                $tcp.EndConnect($iar)
                $stream = $tcp.GetStream()
                $validator = {
                    param($sender, $cert, $chain, $errors)
                    $serverCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cert)
                    $myChain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
                    $myChain.ChainPolicy.ExtraStore.AddRange($script:trustStore)
                    $myChain.ChainPolicy.RevocationMode = 'NoCheck'
                    $myChain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
                    [void]$myChain.Build($serverCert)
                    if ($myChain.ChainElements.Count -lt 2) { return $false }
                    $rootThumb = $myChain.ChainElements[$myChain.ChainElements.Count - 1].Certificate.Thumbprint
                    foreach ($c in $script:trustStore) { if ($c.Thumbprint -eq $rootThumb) { return $true } }
                    return $false
                }
                $ssl = [System.Net.Security.SslStream]::new($stream, $false, $validator)
                $ssl.AuthenticateAsClient($ip)
                $req = "GET /v1/status/leader HTTP/1.1`r`nHost: ${ip}:4646`r`nConnection: close`r`n`r`n"
                $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
                $ssl.Write($reqBytes, 0, $reqBytes.Length)
                $ssl.Flush()
                $reader = [System.IO.StreamReader]::new($ssl)
                $statusLine = $reader.ReadLine()
                return ($statusLine -match '^HTTP/1\.[01] 200')
            } catch {
                return $false
            } finally {
                if ($ssl) { $ssl.Dispose() }
                if ($stream) { $stream.Dispose() }
                if ($tcp) { $tcp.Dispose() }
            }
        } | Out-Null
    }
}

# ─── Section: cluster shape over HTTPS ────────────────────────────────────
Write-Section 'Cluster shape over HTTPS (TLS handshake + RPC mTLS verified)'

Test-Check -Description "$leaderIp : nomad server members over HTTPS reports 3 alive" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv $nomadTokenEnv nomad server members 2>&1 | grep -c alive || true"
    $out -match '^3$'
} | Out-Null

Test-Check -Description "$leaderIp : nomad node status over HTTPS reports 3 ready clients" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv $nomadTokenEnv nomad node status 2>&1 | grep -c ready || true"
    $out -match '^3$'
} | Out-Null

# ─── Section: HTTP:4646 plain rejected ────────────────────────────────────
# With tls.http=true, Nomad expects TLS on 4646. A plain HTTP request to
# https://...:4646 should fail with a TLS handshake error or get a
# "Client sent an HTTP request to an HTTPS server" 400 response.
Write-Section 'Plain HTTP:4646 rejected (TLS enforcement on operator API)'
foreach ($ip in $managerIps) {
    Test-Check -Description "$ip : plain HTTP GET against TLS port (curl -k http://...:4646) fails handshake" -Probe {
        # Use curl FROM the node itself (curl on the build host needs ssh
        # tunneling). The node's own loopback is a good proxy.
        $out = Invoke-RemoteCommand -Ip $ip -Command "curl -sS --max-time 3 http://127.0.0.1:4646/v1/status/leader 2>&1 || true"
        # Expect either "Client sent an HTTP request" or a connection-style
        # error indicating TLS mismatch.
        $out -match 'Client sent an HTTP request|HTTP request to an HTTPS|empty reply|EOF|reset by peer|connection reset'
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'ALL 0.E.3.1 SMOKE CHECKS PASSED (chained 0.E.2.3 + 0.E.2.2 + 0.E.2.1 + 0.E.1)' -ForegroundColor Green
    Write-Host 'Nomad TLS active across all 6 agents: mutual TLS for RPC + HTTPS API on 4646; verify_server_hostname enforced; per-node leaf certs from Vault PKI nomad-server role (90-day TTL).' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
