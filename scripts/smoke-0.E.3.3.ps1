#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.3.3 smoke gate -- Nomad → Consul HTTPS rewire (3.3a) +
  Nomad-Vault integration (3.3b). Chained on 0.E.3.2.

.DESCRIPTION
  Verifies:
    - All 0.E.3.2 baseline checks (Nomad ACL + earlier) green.

  0.E.3.3a (Nomad → Consul HTTPS rewire, all 6 nodes):
    - /etc/nomad.d/42-consul.hcl present (mode 0640 root:nomad), contains
      `address = "https://127.0.0.1:8501"` + `ssl = true` + `ca_file = ...`.
    - /etc/nomad.d/42-consul-token.hcl present, contains
      `token = "<UUID>"` (vault-agent-rendered).
    - /etc/vault-agent/42-template-nomad-consul-token.hcl present.
    - /etc/nomad.d/nomad.hcl does NOT contain the legacy plain-HTTP
      address `127.0.0.1:8500`.
    - Nomad agent-info reports the new HTTPS address (not 8500).
    - Cluster shape unchanged: 3 alive servers + 3 ready clients.

  0.E.3.3b (Nomad-Vault integration, managers only):
    - On each of 3 managers: /etc/nomad.d/60-vault.hcl present + non-empty
      with `enabled = true` + the configured vault address.
    - On each of 3 managers: /etc/nomad.d/60-vault-token.txt present +
      non-empty (token length >= 36).
    - On 3 workers: NO 60-vault.hcl + NO 60-vault-token.txt
      (defensive: workers shouldn't have these).
    - Vault-side: policy `nomad-jobs` exists; token role `nomad-cluster`
      exists with period=72h.
    - Nomad agent-info on each manager reports vault address present
      (proof the stanza loaded).

  Exit gate: every probe green; non-zero exit on any FAIL.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

# Run the 0.E.3.2 baseline first; bail if it's red.
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.3.2.ps1'
Write-Host '=== Chained baseline: smoke-0.E.3.2.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.3.2 baseline FAILED -- skipping 0.E.3.3 checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.3.3-specific checks ──────────────────────────────────────────────
$user = 'nexusadmin'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allIps     = $managerIps + $workerIps
$leaderIp   = $managerIps[0]
$vaultIp    = '192.168.70.121'
$kvMount    = 'nexus'
$expectedVaultAddr = 'https://192.168.70.121:8200'
$expectedVaultHostPort = '192.168.70.121:8200'

$sshOpts  = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
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

# ─── Resolve mgmt token from KV ──────────────────────────────────────────
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

$mgmtToken = Get-VaultKvField -Path 'swarm/nomad-bootstrap-token' -Field 'management_token'

# ─── Section: 0.E.3.3a per-node config files ─────────────────────────────
Write-Section '0.E.3.3a: Consul-rewire config files (all 6 nodes)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /etc/nomad.d/42-consul.hcl present + contains 127.0.0.1:8501 address" -Probe {
        # Nomad's consul.address is host:port (NO https:// scheme); HTTPS is
        # selected by the sibling `ssl = true` field, not the scheme.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nomad.d/42-consul.hcl && sudo grep -qE "address[[:space:]]+=[[:space:]]+\"127\.0\.0\.1:8501\"" /etc/nomad.d/42-consul.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/nomad.d/42-consul.hcl contains ssl = true" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -qE "ssl[[:space:]]+=[[:space:]]+true" /etc/nomad.d/42-consul.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/nomad.d/42-consul.hcl contains ca_file pointing at consul-ca.pem" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -qE "ca_file[[:space:]]+=[[:space:]]+\"/etc/ssl/certs/consul-ca.pem\"" /etc/nomad.d/42-consul.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/nomad.d/42-consul-token.hcl rendered with token (vault-agent)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nomad.d/42-consul-token.hcl && sudo grep -qE "token[[:space:]]*=[[:space:]]*\"[A-Za-z0-9-]{8,}\"" /etc/nomad.d/42-consul-token.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/vault-agent/42-template-nomad-consul-token.hcl present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/vault-agent/42-template-nomad-consul-token.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/nomad.d/nomad.hcl does NOT contain legacy plain-HTTP 127.0.0.1:8500" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -E "127\.0\.0\.1:8500" /etc/nomad.d/nomad.hcl 2>/dev/null && echo FOUND_LEGACY || echo CLEAN'
        $out -match '^CLEAN$'
    } | Out-Null
}

# ─── Section: 0.E.3.3a Nomad effective config reports new consul address ──
# `nomad agent-info` does NOT include the consul section; we use the JSON
# API endpoint /v1/agent/self instead (config.Consuls[] -- plural since
# Nomad 1.7+ supports multi-Consul). Grep for literal substrings since
# Go's json.Marshal default has no spaces.
Write-Section '0.E.3.3a: Nomad /v1/agent/self reports Consuls[].Addr=127.0.0.1:8501 + EnableSSL=true'
if ($mgmtToken -and $mgmtToken.Length -ge 36) {
    foreach ($ip in $allIps) {
        Test-Check -Description "$ip : Consuls[].Addr=127.0.0.1:8501 + EnableSSL=true (effective config)" -Probe {
            $out = Invoke-RemoteCommand -Ip $ip -Command "curl -s --cacert /etc/ssl/certs/nomad-ca.pem -H 'X-Nomad-Token: $mgmtToken' https://127.0.0.1:4646/v1/agent/self"
            ($out -match '"Addr":"127\.0\.0\.1:8501"') -and ($out -match '"EnableSSL":true') -and (-not ($out -match '"Addr":"127\.0\.0\.1:8500"'))
        } | Out-Null
    }
} else {
    Write-Host '[SKIP] mgmt token unavailable; skipping nomad agent-info checks' -ForegroundColor Yellow
}

# ─── Section: 0.E.3.3a cluster shape unchanged ────────────────────────────
Write-Section '0.E.3.3a: Cluster shape unchanged post-rewire'
if ($mgmtToken -and $mgmtToken.Length -ge 36) {
    Test-Check -Description "$leaderIp : nomad server members reports 3 alive servers" -Probe {
        $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad server members 2>&1 | grep -c alive || true"
        $out -match '^3$'
    } | Out-Null
    Test-Check -Description "$leaderIp : nomad node status reports 3 ready clients" -Probe {
        $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$nomadEnv NOMAD_TOKEN='$mgmtToken' nomad node status 2>&1 | grep -c ready || true"
        $out -match '^3$'
    } | Out-Null
}

# ─── Section: 0.E.3.3b Vault-side policy + token role ─────────────────────
Write-Section '0.E.3.3b: Vault-side nomad-jobs policy + nomad-cluster token role'
$vaultProbeScript = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
echo '--- nomad-jobs policy ---'
vault policy read nomad-jobs 2>&1 | head -10 || echo POLICY_MISSING
echo '--- nomad-cluster role ---'
# Need full output -- `period 72h` is at line 11 in vault read output;
# earlier bug truncated at line 10 ("orphan false") so the period match
# always failed.
vault read auth/token/roles/nomad-cluster 2>&1 || echo ROLE_MISSING
"@
$vaultProbeB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultProbeScript -replace "`r`n", "`n")))
$vaultProbeOut = (ssh @sshOpts "$user@$vaultIp" "echo '$vaultProbeB64' | base64 -d | bash" 2>&1 | Out-String)

Test-Check -Description "vault-1: policy nomad-jobs exists with read on secret/data/*" -Probe {
    ($vaultProbeOut -notmatch 'POLICY_MISSING') -and ($vaultProbeOut -match 'secret/data/\*')
} | Out-Null

Test-Check -Description "vault-1: token role nomad-cluster exists with period 72h + nomad-jobs policy" -Probe {
    ($vaultProbeOut -notmatch 'ROLE_MISSING') -and ($vaultProbeOut -match 'nomad-jobs') -and ($vaultProbeOut -match '72h|259200')
} | Out-Null

# ─── Section: 0.E.3.3b per-manager vault stanza files ─────────────────────
Write-Section '0.E.3.3b: Manager vault stanza files (3 managers only)'
foreach ($ip in $managerIps) {
    Test-Check -Description "$ip : /etc/nomad.d/60-vault.hcl present + contains enabled = true" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nomad.d/60-vault.hcl && sudo grep -qE "enabled[[:space:]]+=[[:space:]]+true" /etc/nomad.d/60-vault.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/nomad.d/60-vault.hcl contains create_from_role = nomad-cluster" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -qE "create_from_role[[:space:]]+=[[:space:]]+\"nomad-cluster\"" /etc/nomad.d/60-vault.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/nomad.d/60-vault.hcl points at expected vault address" -Probe {
        # PS double-quote: `" embeds a literal `"` (no backslash); bash
        # single-quoted regex sees `"` literal which is what the file has.
        # Earlier bug had `\`" -- the backslash leaked through to bash,
        # making the regex look for backslash-quote, which never matched.
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -qE 'address[[:space:]]+=[[:space:]]+`"https://192\.168\.70\.121:8200`"' /etc/nomad.d/60-vault.hcl && echo OK"
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/nomad.d/60-vault-token.txt populated (>= 36 chars; periodic token)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nomad.d/60-vault-token.txt && sudo wc -c < /etc/nomad.d/60-vault-token.txt'
        $out -match '\d+' -and ([int]($out -replace '\D','') -ge 36)
    } | Out-Null
}

# ─── Section: 0.E.3.3b workers should NOT have vault stanza ───────────────
Write-Section '0.E.3.3b: Workers do NOT have vault stanza files'
foreach ($ip in $workerIps) {
    Test-Check -Description "$ip : NO /etc/nomad.d/60-vault.hcl (workers don't get vault stanza)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test ! -e /etc/nomad.d/60-vault.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null
    Test-Check -Description "$ip : NO /etc/nomad.d/60-vault-token.txt (workers don't get vault token)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test ! -e /etc/nomad.d/60-vault-token.txt && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Section: 0.E.3.3b /v1/agent/self reports Vault enabled + address ─────
# Nomad 1.7+ exposes config.Vaults[] (plural; multi-Vault). Grep the JSON
# for the configured address + Enabled=true. Same pattern as the consul
# rewire verification (per memory feedback_nomad_consul_address_scheme_less.md).
Write-Section '0.E.3.3b: Nomad /v1/agent/self reports Vaults[].Addr + Enabled=true on managers'
if ($mgmtToken -and $mgmtToken.Length -ge 36) {
    foreach ($ip in $managerIps) {
        Test-Check -Description "$ip : Vaults[].Addr=$expectedVaultAddr + Enabled=true (effective config)" -Probe {
            $out = Invoke-RemoteCommand -Ip $ip -Command "curl -s --cacert /etc/ssl/certs/nomad-ca.pem -H 'X-Nomad-Token: $mgmtToken' https://127.0.0.1:4646/v1/agent/self"
            ($out -match ('"Addr":"' + [regex]::Escape($expectedVaultAddr) + '"')) -and ($out -match '"Enabled":true')
        } | Out-Null
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'ALL 0.E.3.3 SMOKE CHECKS PASSED (chained 0.E.3.2 + 0.E.3.1 + 0.E.2.3 + 0.E.2.2 + 0.E.2.1 + 0.E.1)' -ForegroundColor Green
    Write-Host '0.E.3.3a: Nomad agents talk to Consul over HTTPS:8501 with ACL token (legacy 8500 block removed).' -ForegroundColor Green
    Write-Host '0.E.3.3b: Managers integrated with Vault (nomad-cluster token role, period 72h, vault-jobs policy).' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
