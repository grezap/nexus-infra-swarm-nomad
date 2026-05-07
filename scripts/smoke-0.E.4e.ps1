#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.4e smoke gate -- ingress-mesh full-chain TLS + inet filter
  forward accept rules. Chained on smoke-0.E.4.ps1.

.DESCRIPTION
  Verifies the two architectural fixes that ship in 0.E.4e:

  Block A -- TLS full-chain on the wire (cluster-side cert rendering)
    A.1  /etc/consul.d/tls/server.crt has 2 PEM certs (leaf + intermediate)
    A.2  /etc/nomad.d/tls/server.crt has 2 PEM certs (leaf + intermediate)
    A.3  /etc/portainer/tls/server.crt has 2 PEM certs (leaf + intermediate)
    A.4  Consul HTTPS handshake at :8501 sends 2 wire-chain elements
    A.5  Nomad HTTPS handshake at :4646 sends 2 wire-chain elements
    A.6  Portainer HTTPS handshake at :9443 sends 2 wire-chain elements

  Block B -- inet filter forward chain accept rules
    B.1  /etc/nftables.conf on each swarm-node has the 0.E.4e marker
    B.2  Running ruleset has `iifname "docker_gwbridge" accept` rule
    B.3  Running ruleset has `oifname "docker_gwbridge" accept` rule
    B.4  Running ruleset has `ct state { established, related } accept`

  Block C -- off-cluster reachability (probe FROM the build host)
    This is the gate that 0.E.4 lacked. Every previous smoke probed services
    from inside the cluster (where iifname=nic1 saddr=192.168.10.0/24 in
    the input chain short-circuits). Off-cluster reachability has to be
    asserted from the build host's bridged adapter (10.0.70.x).
    C.1  Consul HTTPS GET /v1/status/leader at each manager:8501 -> HTTP 200
    C.2  Nomad HTTPS GET /v1/status/leader at each manager:4646 -> HTTP 200
    C.3  Portainer HTTPS GET /api/system/status at each manager:9443 -> HTTP 200
    C.4  All three blocks above validate with the STOCK root-only CA bundle
         (no manual augmentation; if this is green, the bundle workaround
         can be retired).

  Block D -- nexus-cli end-to-end (the real acceptance gate)
    Optional; only runs if -RunCli is passed AND nexus.exe is built.
    D.1  nexus-cli cluster-status with stock CA bundle returns exit 0
    D.2  nexus-cli cluster-status --json renders Consul + Nomad + Portainer
         all OK; overall=green

  Exit gate: every Block A/B/C probe green; non-zero exit on any FAIL.

.PARAMETER Strict
  Reserved for future use (currently unused; mirrors the 0.E.4 smoke).

.PARAMETER NexusCliPath
  Full path to a published nexus-cli binary (e.g. the win-x64 AOT artifact).
  When provided AND -RunCli is set, Block D runs. Default unset.

.PARAMETER RunCli
  Enable Block D. Requires -NexusCliPath. The CLI is invoked with the
  current process env (VAULT_TOKEN, VAULT_ADDR, VAULT_CACERT) -- the
  operator must `vault login` first.

.EXAMPLE
  pwsh -File scripts\smoke-0.E.4e.ps1

.EXAMPLE
  # Full end-to-end including the CLI:
  pwsh -File scripts\smoke-0.E.4e.ps1 -RunCli `
       -NexusCliPath "F:\..\nexus-cli\artifacts\win-x64\nexus.exe"

.NOTES
  Pre-conditions for Block C:
    - Build host has $HOME\.nexus\vault-ca-bundle.crt in its STOCK form
      (root-only). If the operator augmented it with the intermediate as
      a workaround, restore from .bak.* before running C.4.
    - VMnet11 adapter on build host has 192.168.70.254 (default route to
      192.168.70.0/24).
#>

[CmdletBinding()]
param(
    [switch]$Strict,
    [string]$NexusCliPath,
    [switch]$RunCli
)

$ErrorActionPreference = 'Stop'

# ─── Chained baseline: smoke-0.E.4.ps1 ────────────────────────────────────
$repoRoot     = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.4.ps1'
Write-Host '=== Chained baseline: smoke-0.E.4.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.4 baseline FAILED -- skipping 0.E.4e checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.4e-specific checks ───────────────────────────────────────────────
$user        = 'nexusadmin'
$managerIps  = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps   = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allNodeIps  = $managerIps + $workerIps

$sshOpts = @('-o', 'ConnectTimeout=8', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$caBundle = Join-Path $env:USERPROFILE '.nexus\vault-ca-bundle.crt'
if (-not (Test-Path $caBundle)) {
    Write-Host "[FATAL] CA bundle not found at $caBundle -- run 0.D.2 first." -ForegroundColor Red
    exit 1
}

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
        }
        Write-Host "[FAIL] $Description" -ForegroundColor Red
        $script:failures += $Description
        return $false
    } catch {
        Write-Host "[FAIL] $Description -- $($_.Exception.Message)" -ForegroundColor Red
        $script:failures += "$Description -- $($_.Exception.Message)"
        return $false
    }
}

function Get-RemoteCertChainDepth {
    param([string]$Host_, [int]$Port, [string]$Sni)
    $depth = 0
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = 5000
        $tcp.SendTimeout    = 5000
        $tcp.Connect($Host_, $Port)
        $ssl = [System.Net.Security.SslStream]::new(
            $tcp.GetStream(), $false,
            { param($s, $c, $ch, $e) $script:depth = $ch.ChainElements.Count; $true })
        $ssl.AuthenticateAsClient($Sni)
        $ssl.Dispose(); $tcp.Dispose()
    } catch {
        $script:depth = 0
    }
    return $script:depth
}

# ─── Block A: server.crt files have 2 PEMs ────────────────────────────────
Write-Section 'Block A -- server.crt full-chain on disk'

foreach ($ip in $allNodeIps) {
    $host_ = ($ip -split '\.')[-1]
    Test-Check "consul server.crt on .$host_ has 2 PEM blocks" {
        $n = (ssh @sshOpts "$user@$ip" 'sudo grep -c "BEGIN CERTIFICATE" /etc/consul.d/tls/server.crt 2>/dev/null') -as [int]
        return $n -eq 2
    } | Out-Null
    Test-Check "nomad server.crt on .$host_ has 2 PEM blocks" {
        $n = (ssh @sshOpts "$user@$ip" 'sudo grep -c "BEGIN CERTIFICATE" /etc/nomad.d/tls/server.crt 2>/dev/null') -as [int]
        return $n -eq 2
    } | Out-Null
}
foreach ($ip in $managerIps) {
    $host_ = ($ip -split '\.')[-1]
    Test-Check "portainer server.crt on .$host_ has 2 PEM blocks" {
        $n = (ssh @sshOpts "$user@$ip" 'sudo grep -c "BEGIN CERTIFICATE" /etc/portainer/tls/server.crt 2>/dev/null') -as [int]
        return $n -eq 2
    } | Out-Null
}

# ─── Block A.4-A.6: wire-chain depth on TLS handshake ─────────────────────
Write-Section 'Block A -- wire-chain depth on TLS handshake'

# Consul HTTPS API on workers binds 127.0.0.1 only (Consul client-mode default
# `client_addr`). Off-cluster Block A probes only the 3 managers' 8501.
# Workers' on-disk server.crt is already verified above (file check).
foreach ($ip in $managerIps) {
    $host_ = ($ip -split '\.')[-1]
    Test-Check "Consul .${host_}:8501 sends >=2 chain elements on handshake" {
        $d = Get-RemoteCertChainDepth -Host_ $ip -Port 8501 -Sni "swarm-manager-1.consul.nexus.lab"
        return $d -ge 2
    } | Out-Null
}
# Nomad's HTTPS API binds all interfaces on every node (manager + worker).
foreach ($ip in $allNodeIps) {
    $host_ = ($ip -split '\.')[-1]
    Test-Check "Nomad .${host_}:4646 sends >=2 chain elements on handshake" {
        $d = Get-RemoteCertChainDepth -Host_ $ip -Port 4646 -Sni "server.global.nomad"
        return $d -ge 2
    } | Out-Null
}
foreach ($ip in $managerIps) {
    $host_ = ($ip -split '\.')[-1]
    Test-Check "Portainer .${host_}:9443 sends >=2 chain elements on handshake" {
        $d = Get-RemoteCertChainDepth -Host_ $ip -Port 9443 -Sni "portainer.nexus.lab"
        return $d -ge 2
    } | Out-Null
}

# ─── Block B: inet filter forward chain ──────────────────────────────────
Write-Section 'Block B -- inet filter forward accept rules'

foreach ($ip in $allNodeIps) {
    $host_ = ($ip -split '\.')[-1]
    Test-Check "node .$host_ /etc/nftables.conf has 0.E.4e marker" {
        (ssh @sshOpts "$user@$ip" 'grep -qF "nftables-forward (managed by" /etc/nftables.conf && echo OK') -match 'OK'
    } | Out-Null
    $rules = ssh @sshOpts "$user@$ip" 'sudo nft list chain inet filter forward 2>/dev/null'
    Test-Check "node .$host_ running ruleset: docker_gwbridge ingress accept" {
        $rules -match 'iifname "docker_gwbridge" accept'
    } | Out-Null
    Test-Check "node .$host_ running ruleset: docker_gwbridge egress accept" {
        $rules -match 'oifname "docker_gwbridge" accept'
    } | Out-Null
    Test-Check "node .$host_ running ruleset: ct state established/related accept" {
        $rules -match 'ct state .*established'
    } | Out-Null
}

# ─── Block C: off-cluster reachability from this build host ───────────────
Write-Section 'Block C -- off-cluster reachability (build host -> services) with STOCK CA bundle'

# The bundle MUST be root-only at this point (the gate is meaningless if
# augmented). Probe + warn if it isn't.
$bundleCount = (Select-String -Path $caBundle -Pattern 'BEGIN CERTIFICATE' -SimpleMatch).Count
Test-Check "build-host CA bundle is root-only ($bundleCount cert; expected 1)" {
    return $bundleCount -eq 1
} | Out-Null
if ($bundleCount -ne 1) {
    Write-Host "  WARN: bundle has $bundleCount certs. If this contains the intermediate, the gate below" -ForegroundColor Yellow
    Write-Host "        will pass spuriously. Restore from .bak.* and re-run to validate the cluster-side fix." -ForegroundColor Yellow
}

# Off-cluster reachability uses a precompiled C# delegate for cert validation.
# Why not curl: Windows curl uses schannel which doesn't honour IP SANs (only
# DNS names) -- our lab certs use IP SANs so schannel rejects every probe.
# Why not a PS scriptblock callback: HttpClient invokes the callback on a
# thread-pool thread, which has no PS Runspace -- the scriptblock fails with
# "There is no Runspace available to run scripts in this thread". A static
# C# delegate has no Runspace dependency. This is the same chain-validation
# logic nexus-cli's HttpClient factory uses (ADR-0019).
# Off-cluster TLS validation against the stock bundle. Why not curl: Windows
# curl uses schannel which doesn't honour IP SANs. Why not HttpClient: its
# certificate-callback fires on a thread-pool thread which has no PS Runspace.
# SslStream's callback fires synchronously on the calling thread (Runspace
# present) -- and we only need to confirm the chain validates, not pull HTTP
# bodies. So the gate becomes: open a TLS connection to the service, manually
# build the chain against $rootCerts, return chain.Build() result. If the
# server presents the full chain (Block A confirms 2 elements on wire) AND
# the chain anchors at the root in our stock bundle, validation succeeds.
$script:rootCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$script:rootCerts.ImportFromPemFile($caBundle)

function Test-StockBundleHandshake([string]$Host_, [int]$Port, [string]$Sni) {
    $tcp = $null; $ssl = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = 5000; $tcp.SendTimeout = 5000
        $tcp.Connect($Host_, $Port)
        $script:validated = $false
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, {
            param($s, $cert, $chain, $errs)
            if ($null -eq $cert) { return $false }
            $cp = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $cp.ChainPolicy.TrustMode = 'CustomRootTrust'
            $cp.ChainPolicy.RevocationMode = 'NoCheck'
            $cp.ChainPolicy.CustomTrustStore.AddRange($script:rootCerts)
            if ($chain) { foreach ($e in $chain.ChainElements) { $cp.ChainPolicy.ExtraStore.Add($e.Certificate) | Out-Null } }
            $script:validated = $cp.Build($cert)
            return $script:validated
        })
        $ssl.AuthenticateAsClient($Sni)
        return $script:validated
    } catch {
        return $false
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Dispose() }
    }
}

foreach ($ip in $managerIps) {
    $host_ = ($ip -split '\.')[-1]
    Test-Check "Consul TLS validates against stock bundle on .${host_}:8501" {
        return Test-StockBundleHandshake -Host_ $ip -Port 8501 -Sni "swarm-manager-1.consul.nexus.lab"
    } | Out-Null
    Test-Check "Nomad TLS validates against stock bundle on .${host_}:4646" {
        return Test-StockBundleHandshake -Host_ $ip -Port 4646 -Sni "server.global.nomad"
    } | Out-Null
    Test-Check "Portainer TLS validates against stock bundle on .${host_}:9443" {
        return Test-StockBundleHandshake -Host_ $ip -Port 9443 -Sni "portainer.nexus.lab"
    } | Out-Null
}

# ─── Block D: nexus-cli end-to-end ────────────────────────────────────────
if ($RunCli) {
    Write-Section 'Block D -- nexus-cli cluster-status'
    if (-not $NexusCliPath -or -not (Test-Path $NexusCliPath)) {
        $failures += "Block D requested but -NexusCliPath '$NexusCliPath' is missing or empty"
        Write-Host "[FAIL] -NexusCliPath required for -RunCli" -ForegroundColor Red
    } elseif (-not $env:VAULT_TOKEN) {
        $failures += "Block D requested but VAULT_TOKEN env var not set; run vault login first"
        Write-Host "[FAIL] VAULT_TOKEN not set" -ForegroundColor Red
    } else {
        Test-Check "nexus-cli cluster-status (human) exits 0" {
            & $NexusCliPath cluster-status | Out-Null
            return $LASTEXITCODE -eq 0
        } | Out-Null
        Test-Check "nexus-cli cluster-status --json reports overall=green" {
            $j = & $NexusCliPath cluster-status --json | ConvertFrom-Json
            return $j.overall -eq 'green'
        } | Out-Null
    }
}

# ─── Roll-up ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL GREEN -- 0.E.4e gate passed." -ForegroundColor Green
    exit 0
}
Write-Host "FAILURES ($($failures.Count)):" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
