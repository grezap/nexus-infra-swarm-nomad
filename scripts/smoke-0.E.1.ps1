#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.1 smoke gate -- 3+3 Docker Swarm cluster bring-up.

.DESCRIPTION
  Verifies the exit gate per MASTER-PLAN.md line 151:
    "docker node ls shows 6, nomad server members shows 3"

  Plus reachability + service-state checks per memory/feedback_lab_host_
  reachability.md and feedback_smoke_gate_probe_robustness.md (marker-token
  matching with `-match`, NOT strict equality, to tolerate sudo's
  "unable to resolve host" stderr noise on freshly renamed hosts).

  Each check echoes [OK] or [FAIL] with a one-line reason. Exits 1 on
  any FAIL; 0 on all-green. No external dependencies beyond ssh + the
  build host's ssh-agent + the canonical $HOME/.ssh/config lab stanza.

.PARAMETER Strict
  Fail on warnings (e.g. cluster not yet quorate but the leader is up).
  Default: false (warnings are logged but don't fail the gate).

.NOTES
  Ordered: cheapest first (SSH reachability) -> service state -> swarm/
  nomad/consul cluster shape. Failing early on a dead node short-circuits
  the slower cluster-shape probes.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allIps     = $managerIps + $workerIps

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$failures = @()
$warnings = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Probe
    )
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
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Command
    )
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

# ─── Section 1: per-node SSH reachability ─────────────────────────────────
Write-Section 'Per-node SSH reachability + docker.service'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : SSH echo probe" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker'
        $out -match 'nexus-smoke-marker'
    } | Out-Null
    Test-Check -Description "$ip : docker.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active docker.service'
        $out -match '^active$'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) reachability/service check(s) failed; skipping cluster probes." -ForegroundColor Red
    exit 1
}

# ─── Section 2: firstboot completion ──────────────────────────────────────
Write-Section 'swarm-node firstboot completion'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /var/lib/swarm-node-firstboot-done present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/swarm-node-firstboot-done && echo done'
        $out -match 'done'
    } | Out-Null
}

# ─── Section 3: hostname mapping ──────────────────────────────────────────
Write-Section 'Hostname mapping (canonical IPs -> canonical hostnames)'
$expected = @{
    '192.168.70.111' = 'swarm-manager-1'
    '192.168.70.112' = 'swarm-manager-2'
    '192.168.70.113' = 'swarm-manager-3'
    '192.168.70.131' = 'swarm-worker-1'
    '192.168.70.132' = 'swarm-worker-2'
    '192.168.70.133' = 'swarm-worker-3'
}
foreach ($ip in $allIps) {
    $expectedHostname = $expected[$ip]
    Test-Check -Description "$ip : hostname == $expectedHostname" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$expectedHostname$"
    } | Out-Null
}

# ─── Section 4: Swarm cluster shape (the master-plan exit gate) ──────────
Write-Section 'Swarm cluster shape (MASTER-PLAN.md line 151 exit gate)'
$leaderIp = $managerIps[0]

Test-Check -Description "$leaderIp : docker info reports Swarm: active" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "docker info --format '{{.Swarm.LocalNodeState}}'"
    $out -match 'active'
} | Out-Null

Test-Check -Description "$leaderIp : docker node ls reports 6 nodes" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "docker node ls --format '{{.ID}}' | wc -l"
    $out -match '^6$'
} | Out-Null

Test-Check -Description "$leaderIp : docker node ls reports 3 managers (Reachable + Leader)" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "docker node ls --filter role=manager --format '{{.Status}} {{.ManagerStatus}}'"
    # Expect lines like "Ready Leader" + "Ready Reachable" x 2
    $lines = ($out -split "`n").Where({ $_ -match 'Ready' })
    return $lines.Count -eq 3
} | Out-Null

Test-Check -Description "$leaderIp : docker node ls reports 3 workers (Ready)" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "docker node ls --filter role=worker --format '{{.Status}}'"
    $lines = ($out -split "`n").Where({ $_ -match 'Ready' })
    return $lines.Count -eq 3
} | Out-Null

# ─── Section 5: Consul cluster shape ─────────────────────────────────────
# Probes target the TLS endpoint (steady state post-0.E.2.2: HTTP/8500 is
# hard-cut, only HTTPS/8501 listens). If you're running 0.E.1 in isolation
# with `enable_consul_tls=false`, override $consulEnv to "" before invoking
# the smoke script, or run `consul members` directly via ssh.
$consulEnv = "CONSUL_HTTP_ADDR=https://localhost:8501 CONSUL_CACERT=/etc/ssl/certs/consul-ca.pem"

Write-Section 'Consul cluster shape (informational; harden in 0.E.2)'
Test-Check -Description "$leaderIp : consul members reports 6 alive members" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$consulEnv consul members 2>&1 | grep -c alive || true"
    $out -match '^6$'
} | Out-Null

Test-Check -Description "$leaderIp : consul operator raft list-peers reports 3 peers" -Probe {
    # Count rows with the canonical VMnet10 backplane IP prefix; the column
    # header reads "Voter" (capital) and rows show "true", so plain
    # `grep -c voter` is a probe bug -- counts neither header nor rows.
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$consulEnv consul operator raft list-peers | grep -c '192.168.10' || true"
    $out -match '^3$'
} | Out-Null

# ─── Section 6: Nomad cluster shape ───────────────────────────────────────
Write-Section 'Nomad cluster shape (informational; harden in 0.E.3)'
Test-Check -Description "$leaderIp : nomad server members reports 3 alive servers" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "nomad server members 2>&1 | grep -c alive || true"
    $out -match '^3$'
} | Out-Null

Test-Check -Description "$leaderIp : nomad node status reports 3 ready clients" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "nomad node status 2>&1 | grep -c ready || true"
    $out -match '^3$'
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.E.1 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: docker node ls = 6, nomad server members = 3 (per MASTER-PLAN.md line 151)" -ForegroundColor Green
    if ($warnings.Count -gt 0 -and $Strict) {
        Write-Host "Warnings (Strict mode): $($warnings.Count)" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        exit 1
    }
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
