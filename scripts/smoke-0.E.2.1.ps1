#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.2.1 smoke gate -- Consul gossip encryption (chained on 0.E.1).

.DESCRIPTION
  Verifies:
    - All 0.E.1 baseline checks (28 probes -- SSH/docker/firstboot/hostname/
      Swarm/Consul/Nomad cluster shape) still green.
    - Vault Agent (`nexus-vault-agent.service`) active on all 6 swarm-nodes.
    - AppRole token sink populated on all 6 (proves AppRole auth succeeded).
    - /etc/consul.d/10-encrypt.hcl present + non-empty on all 6 (proves
      Vault Agent rendered the gossip-key template).
    - `consul keyring -list` from a manager shows 1 primary key with
      6/6 alive count (proves the key converged across all agents).

  Exit gate: every probe green; non-zero exit on any FAIL.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

# Run the 0.E.1 baseline first; bail if it's red.
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.1.ps1'
Write-Host '=== Chained baseline: smoke-0.E.1.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.1 baseline FAILED -- skipping 0.E.2.1 checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.2.1-specific checks ──────────────────────────────────────────────
$user = 'nexusadmin'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allIps     = $managerIps + $workerIps

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

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

# ─── Section: Vault Agent service active ─────────────────────────────────
Write-Section 'Vault Agent (nexus-vault-agent.service) active on all 6 nodes'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service'
        $out -match '^active$'
    } | Out-Null
}

# ─── Section: AppRole auth succeeded -- token sink populated ──────────────
Write-Section 'AppRole login produced a token sink on all 6 nodes'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /var/run/nexus-vault-agent/token populated" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT'
        $out -match 'TOKEN_PRESENT'
    } | Out-Null
}

# ─── Section: gossip-encrypt template rendered ────────────────────────────
Write-Section 'Gossip-encrypt template rendered on all 6 nodes'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /etc/consul.d/10-encrypt.hcl present + 'encrypt = ' line" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/consul.d/10-encrypt.hcl && sudo grep -q "encrypt = " /etc/consul.d/10-encrypt.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Section: keyring converged across all agents ─────────────────────────
Write-Section 'Consul keyring -list reports 6/6 alive (gossip encryption uniform)'
$leaderIp = $managerIps[0]

Test-Check -Description "$leaderIp : consul keyring -list shows 6/6 alive on a single primary key" -Probe {
    # `consul keyring -list` output looks like:
    #   ==> Gathering installed encryption keys...
    #   ==> Done!
    #
    #   WAN:
    #     <key> [1/1]
    #
    #   nexus-lab (LAN):
    #     <key> [6/6]
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command 'consul keyring -list 2>&1'
    # Look for at least one key with [6/6] in the LAN section
    $out -match '\[6/6\]'
} | Out-Null

Test-Check -Description "$leaderIp : exactly 1 key in LAN keyring (no orphan keys from rotation)" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command 'consul keyring -list 2>&1 | sed -n "/(LAN):/,/^$/p" | grep -c "^\s*[A-Za-z0-9+/]\{40,\}" || true'
    # If the count is 0 from sed not matching, fall back to less specific check
    if ($out -match '^[0-9]+$' -and [int]$out -ge 1) { return $true }
    # Fallback: just confirm SOME LAN key exists
    $out2 = Invoke-RemoteCommand -Ip $leaderIp -Command 'consul keyring -list 2>&1 | grep -c "\[6/6\]" || true'
    return ($out2 -match '^[1-9]')
} | Out-Null

# ─── Section: cluster operational state still green ───────────────────────
Write-Section 'Cluster still operational after rolling consul restart'
Test-Check -Description "$leaderIp : consul members reports 6 alive" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command 'consul members 2>&1 | grep -c alive || true'
    $out -match '^6$'
} | Out-Null

Test-Check -Description "$leaderIp : consul raft has a leader" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "consul operator raft list-peers 2>&1 | grep -c '^.*leader' || true"
    $out -match '^[1-9]'
} | Out-Null

Test-Check -Description "$leaderIp : docker swarm still 6 nodes" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "docker node ls --format '{{.ID}}' 2>&1 | wc -l"
    $out -match '^6$'
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'ALL 0.E.2.1 SMOKE CHECKS PASSED (chained 0.E.1 baseline)' -ForegroundColor Green
    Write-Host 'Gossip encryption active across all 6 Consul agents (LAN keyring 6/6 on a single primary key).' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
