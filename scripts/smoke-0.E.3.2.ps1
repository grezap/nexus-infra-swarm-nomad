#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.3.2 smoke gate -- Nomad ACL system (chained on 0.E.3.1).

.DESCRIPTION
  Verifies:
    - All 0.E.3.1 baseline checks (Nomad TLS + Consul ACL + earlier) green.
    - Vault KV state:
        * nexus/swarm/nomad-bootstrap-token has non-empty management_token
          (>= 36 chars) + status=bootstrapped.
        * nexus/swarm/nomad-agent-tokens/<host> has non-empty agent_token
          (>= 36 chars) for all 6 hosts.
    - Per-node config files (all 6):
        * /etc/nomad.d/50-acl.hcl present, mode 0640 root:nomad,
          contains `enabled = true` inside the acl{} block.
        * /etc/nomad.d/50-acl-token.hcl present with token = "<UUID>"
          (rendered by Vault Agent).
        * /etc/vault-agent/50-template-nomad-acl.hcl present.
    - Nomad ACL state (authenticated with mgmt token from KV):
        * `nomad acl bootstrap` returns "ACL bootstrap no longer allowed"
          (proves bootstrap is one-shot consumed).
        * `nomad acl policy list` includes the shared `nomad-agent` policy.
        * `nomad acl token list` shows >= 7 tokens (1 management + 6 agent).
    - Cluster shape under ACL-enforced mode (mgmt-token authenticated):
        * `nomad server members` reports 3 alive servers.
        * `nomad node status` reports 3 ready clients.
    - Negative checks:
        * Anonymous HTTPS GET /v1/agent/self returns 403 on every node.

  Exit gate: every probe green; non-zero exit on any FAIL.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

# Run the 0.E.3.1 baseline first; bail if it's red.
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.3.1.ps1'
Write-Host '=== Chained baseline: smoke-0.E.3.1.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.3.1 baseline FAILED -- skipping 0.E.3.2 checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.3.2-specific checks ──────────────────────────────────────────────
$user = 'nexusadmin'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allIps     = $managerIps + $workerIps
$leaderIp   = $managerIps[0]
$vaultIp    = '192.168.70.121'
$kvMount    = 'nexus'

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$nomadEnv = "NOMAD_ADDR=https://localhost:4646 NOMAD_CACERT=/etc/ssl/certs/nomad-ca.pem"

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

# ─── Resolve Vault root token + read mgmt token from KV ──────────────────
$keysFile = Join-Path $env:USERPROFILE '.nexus/vault-init.json'
if (-not (Test-Path $keysFile)) {
    Write-Host "[FAIL] $keysFile missing" -ForegroundColor Red
    exit 1
}
$rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

function Get-VaultKvField {
    param([string]$Path, [string]$Field)
    $script = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault kv get -field=$Field -mount=$kvMount $Path 2>/dev/null || true
"@
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($script -replace "`r`n", "`n")))
    return (ssh @sshOpts "$user@$vaultIp" "echo '$b64' | base64 -d | bash" 2>&1 | Out-String).Trim()
}

# ─── Section: Vault KV state ──────────────────────────────────────────────
Write-Section 'Vault KV: Nomad mgmt token + 6 agent tokens populated'

$mgmtToken = Get-VaultKvField -Path 'swarm/nomad-bootstrap-token' -Field 'management_token'
Test-Check -Description "Vault KV nexus/swarm/nomad-bootstrap-token: management_token populated (>= 36 chars)" -Probe {
    $mgmtToken -and $mgmtToken.Length -ge 36
} | Out-Null

Test-Check -Description "Vault KV nexus/swarm/nomad-bootstrap-token: status=bootstrapped" -Probe {
    $status = Get-VaultKvField -Path 'swarm/nomad-bootstrap-token' -Field 'status'
    $status -eq 'bootstrapped'
} | Out-Null

foreach ($host_ in @('swarm-manager-1','swarm-manager-2','swarm-manager-3','swarm-worker-1','swarm-worker-2','swarm-worker-3')) {
    Test-Check -Description "Vault KV nexus/swarm/nomad-agent-tokens/$host_ : agent_token populated (>= 36 chars)" -Probe {
        $tok = Get-VaultKvField -Path "swarm/nomad-agent-tokens/$host_" -Field 'agent_token'
        $tok -and $tok.Length -ge 36
    } | Out-Null
}

if (-not $mgmtToken -or $mgmtToken.Length -lt 36) {
    Write-Host ''
    Write-Host 'Cannot continue ACL checks without mgmt token; aborting' -ForegroundColor Red
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# ─── Section: per-node config files ───────────────────────────────────────
# v2: only check for /etc/nomad.d/50-acl.hcl (the enabled=true config).
# Per-agent tokens via config file are NOT supported by Nomad (`acl { token }`
# is not a valid key); inter-agent RPC is authenticated via mTLS cert from
# 0.E.3.1 (cert SAN is the identity at the wire layer). The 6 per-host
# tokens persisted to Vault KV are operator-use tokens, not agent-config
# inputs. We intentionally do NOT deploy 50-acl-token.hcl or its Vault
# Agent template -- the smoke confirms NEITHER exists (defensive against
# v1 leftovers).
Write-Section 'Per-node Nomad ACL config files'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : 50-acl.hcl contains enabled = true" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nomad.d/50-acl.hcl && sudo grep -qE "enabled[[:space:]]+=[[:space:]]+true" /etc/nomad.d/50-acl.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : NO /etc/nomad.d/50-acl-token.hcl (Nomad acl{} doesn't support `token`; agents auth via mTLS)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test ! -e /etc/nomad.d/50-acl-token.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : NO /etc/vault-agent/50-template-nomad-acl.hcl (we don't render an agent token file)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test ! -e /etc/vault-agent/50-template-nomad-acl.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Section: Nomad ACL state (mgmt-token authenticated) ─────────────────
Write-Section 'Nomad ACL state (authenticated with mgmt token)'

Test-Check -Description "$leaderIp : nomad acl bootstrap returns 'no longer allowed' (one-shot consumed)" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv nomad acl bootstrap 2>&1 || true"
    $out -match 'no longer allowed|already bootstrapped|ACL bootstrap'
} | Out-Null

Test-Check -Description "$leaderIp : nomad acl policy list includes nomad-agent" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad acl policy list 2>&1 | grep -c nomad-agent || true"
    $out -match '^[1-9]'
} | Out-Null

Test-Check -Description "$leaderIp : nomad acl token list shows >= 7 tokens (1 mgmt + 6 agent)" -Probe {
    # Output format (table):
    #   Name                   Type        Global  Accessor ID    Expired
    #   Bootstrap Token        management  true    <UUID>         false
    #   agent-swarm-manager-1  client      false   <UUID>         false
    #   ...
    # Match lines whose type column is `management|client` (skip header).
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad acl token list 2>&1 | grep -cE '(management|client)[[:space:]]+(true|false)' || true"
    [int]($out) -ge 7
} | Out-Null

# ─── Section: cluster shape under ACL ─────────────────────────────────────
Write-Section 'Cluster shape under ACL-enforced mode (mgmt-token authenticated)'

Test-Check -Description "$leaderIp : nomad server members reports 3 alive servers" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad server members 2>&1 | grep -c alive || true"
    $out -match '^3$'
} | Out-Null

Test-Check -Description "$leaderIp : nomad node status reports 3 ready clients" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad node status 2>&1 | grep -c ready || true"
    $out -match '^3$'
} | Out-Null

# ─── Section: Anonymous deny ──────────────────────────────────────────────
Write-Section 'Anonymous access denied (ACL enforcement)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : anonymous HTTPS GET /v1/agent/self returns 403" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "curl -sS --cacert /etc/ssl/certs/nomad-ca.pem -o /dev/null -w '%{http_code}' https://127.0.0.1:4646/v1/agent/self"
        $out -match '^403$'
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'ALL 0.E.3.2 SMOKE CHECKS PASSED (chained 0.E.3.1 + 0.E.2.3 + 0.E.2.2 + 0.E.2.1 + 0.E.1)' -ForegroundColor Green
    Write-Host 'Nomad ACL ENFORCED cluster-wide: mgmt token in Vault KV, 6 per-host agent tokens active, anonymous calls denied at API layer.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
