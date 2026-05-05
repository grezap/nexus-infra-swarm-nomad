#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.E.2.3 smoke gate -- Consul ACL system (chained on 0.E.2.2).

.DESCRIPTION
  Verifies:
    - All 0.E.2.2 baseline checks (TLS + gossip + 0.E.1 cluster shape)
      still green.
    - Vault KV state:
        * nexus/swarm/consul-bootstrap-token has non-empty management_token
          (>= 36 chars) + status=bootstrapped.
        * nexus/swarm/agent-tokens/<host> has non-empty agent_token (>= 36
          chars) for all 6 hosts.
    - Per-node config files (all 6 nodes):
        * /etc/consul.d/30-acl.hcl present, mode 0640 root:consul, contains
          `default_policy = "deny"`, `down_policy = "extend-cache"`,
          `enable_token_persistence = true`.
        * /etc/consul.d/30-acl-token.hcl present, mode 0640, contains both
          `agent =` and `default =` with non-empty UUID-shaped values.
        * /etc/vault-agent/30-template-acl.hcl present.
    - Consul ACL state (authenticated with mgmt token from KV):
        * `consul info | grep acl_default_policy` matches "deny".
        * `consul acl bootstrap` returns "ACL bootstrap no longer allowed"
          (proves bootstrap is one-shot consumed).
        * `consul acl policy list` shows >= 6 entries with names matching
          ^agent-(swarm-manager|swarm-worker)-[1-3]$.
        * `consul acl token list` shows >= 7 tokens (1 management + 6
          agent + Consul's internal anonymous token).
    - Cluster shape under deny mode (mgmt-token authenticated):
        * `consul members` reports 6 alive.
        * `consul operator raft list-peers` reports 3 voter peers.
        * Exactly 1 leader.
    - Negative checks:
        * From a swarm-node, anonymous `consul members` (no token) errors
          with Permission denied / 403 / ACL not found.
        * From the build host, an HTTPS GET to /v1/agent/members WITHOUT
          an X-Consul-Token header returns 403 (deny enforced).

  Exit gate: every probe green; non-zero exit on any FAIL.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

# Run the 0.E.2.2 baseline first; bail if it's red.
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'scripts/smoke-0.E.2.2.ps1'
Write-Host '=== Chained baseline: smoke-0.E.2.2.ps1 ===' -ForegroundColor Magenta
& pwsh -NoProfile -File $baselinePath
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '0.E.2.2 baseline FAILED -- skipping 0.E.2.3 checks' -ForegroundColor Red
    exit 1
}

# ─── 0.E.2.3-specific checks ──────────────────────────────────────────────
$user = 'nexusadmin'
$managerIps = @('192.168.70.111', '192.168.70.112', '192.168.70.113')
$workerIps  = @('192.168.70.131', '192.168.70.132', '192.168.70.133')
$allIps     = $managerIps + $workerIps
$leaderIp   = $managerIps[0]
$vaultIp    = '192.168.70.121'
$kvMount    = 'nexus'

$nodeSpecs = @{
    '192.168.70.111' = 'swarm-manager-1'
    '192.168.70.112' = 'swarm-manager-2'
    '192.168.70.113' = 'swarm-manager-3'
    '192.168.70.131' = 'swarm-worker-1'
    '192.168.70.132' = 'swarm-worker-2'
    '192.168.70.133' = 'swarm-worker-3'
}

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$envPrefix = "CONSUL_HTTP_ADDR=https://localhost:8501 CONSUL_CACERT=/etc/ssl/certs/consul-ca.pem"

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
# We need the mgmt token to authenticate the Consul ACL probes below. Read
# it via vault-1 over SSH using base64-encoded inner script (keeps the
# root_token + mgmt token off ssh.exe argv).
$keysFile = Join-Path $env:USERPROFILE '.nexus/vault-init.json'
if (-not (Test-Path $keysFile)) {
    Write-Host "[FAIL] $keysFile missing -- cannot authenticate Vault KV reads" -ForegroundColor Red
    exit 1
}
$rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token
if (-not $rootToken) {
    Write-Host "[FAIL] root_token missing/empty in $keysFile" -ForegroundColor Red
    exit 1
}

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
Write-Section 'Vault KV: mgmt token + 6 agent tokens populated'

$mgmtToken = Get-VaultKvField -Path 'swarm/consul-bootstrap-token' -Field 'management_token'
Test-Check -Description "Vault KV nexus/swarm/consul-bootstrap-token: management_token populated (>= 36 chars)" -Probe {
    $mgmtToken -and $mgmtToken.Length -ge 36
} | Out-Null

Test-Check -Description "Vault KV nexus/swarm/consul-bootstrap-token: status=bootstrapped" -Probe {
    $status = Get-VaultKvField -Path 'swarm/consul-bootstrap-token' -Field 'status'
    $status -eq 'bootstrapped'
} | Out-Null

foreach ($host_ in @('swarm-manager-1', 'swarm-manager-2', 'swarm-manager-3', 'swarm-worker-1', 'swarm-worker-2', 'swarm-worker-3')) {
    Test-Check -Description "Vault KV nexus/swarm/agent-tokens/$host_ : agent_token populated (>= 36 chars)" -Probe {
        $tok = Get-VaultKvField -Path "swarm/agent-tokens/$host_" -Field 'agent_token'
        $tok -and $tok.Length -ge 36
    } | Out-Null
}

if (-not $mgmtToken -or $mgmtToken.Length -lt 36) {
    Write-Host ''
    Write-Host 'Cannot continue ACL checks without mgmt token from Vault KV; aborting' -ForegroundColor Red
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# ─── Section: per-node config files ───────────────────────────────────────
Write-Section 'Per-node ACL config files (30-acl.hcl + 30-acl-token.hcl + Vault Agent template)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : 30-acl.hcl contains default_policy = deny" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/consul.d/30-acl.hcl && sudo grep -qE "default_policy[[:space:]]+=[[:space:]]+.deny." /etc/consul.d/30-acl.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : 30-acl.hcl contains down_policy = extend-cache + enable_token_persistence = true" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -qE "down_policy[[:space:]]+=[[:space:]]+.extend-cache." /etc/consul.d/30-acl.hcl && sudo grep -qE "enable_token_persistence[[:space:]]+=[[:space:]]+true" /etc/consul.d/30-acl.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : 30-acl-token.hcl has agent= UUID (no default token -- enforces explicit token)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/consul.d/30-acl-token.hcl && sudo grep -qE "agent[[:space:]]+=[[:space:]]+.[A-Za-z0-9-]{36,}." /etc/consul.d/30-acl-token.hcl && ! sudo grep -qE "default[[:space:]]+=" /etc/consul.d/30-acl-token.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null

    Test-Check -Description "$ip : /etc/vault-agent/30-template-acl.hcl present (template registered with Vault Agent)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/vault-agent/30-template-acl.hcl && echo OK'
        $out -match '^OK$'
    } | Out-Null
}

# ─── Section: Consul ACL state (mgmt-token authenticated) ─────────────────
Write-Section 'Consul ACL state (authenticated with mgmt token)'

Test-Check -Description "$leaderIp : consul info reports acl = enabled (deny enforcement is verified by anonymous probes below)" -Probe {
    # `consul info` exposes only `acl = enabled|disabled` (no detailed
    # default_policy field). We assert ACL system on; the anonymous-deny
    # probes (HTTP 403 from each node) prove default_policy is actually deny.
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul info 2>&1 | grep -E '^\s*acl\s*=' | head -1"
    $out -match 'enabled'
} | Out-Null

Test-Check -Description "$leaderIp : consul acl bootstrap returns 'no longer allowed' (one-shot consumed)" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix consul acl bootstrap 2>&1 || true"
    $out -match 'no longer allowed'
} | Out-Null

Test-Check -Description "$leaderIp : consul acl policy list shows 6 agent-* policies" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul acl policy list 2>&1 | grep -cE 'agent-(swarm-manager|swarm-worker)-[1-3]' || true"
    $out -match '^6$'
} | Out-Null

Test-Check -Description "$leaderIp : consul acl token list shows >= 7 tokens (1 mgmt + 6 agent + others)" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul acl token list 2>&1 | grep -c 'AccessorID:' || true"
    [int]($out) -ge 7
} | Out-Null

# ─── Section: Cluster shape under deny mode ───────────────────────────────
Write-Section 'Cluster shape under deny mode (mgmt-token authenticated)'

Test-Check -Description "$leaderIp : consul members (mgmt-token) reports 6 alive" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul members 2>&1 | grep -c alive || true"
    $out -match '^6$'
} | Out-Null

Test-Check -Description "$leaderIp : consul raft list-peers (mgmt-token) reports 3 voter peers" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul operator raft list-peers 2>&1 | grep -c '192.168.10' || true"
    $out -match '^3$'
} | Out-Null

Test-Check -Description "$leaderIp : raft list-peers shows exactly 1 leader" -Probe {
    $out = Invoke-RemoteCommand -Ip $leaderIp -Command "$envPrefix CONSUL_HTTP_TOKEN='$mgmtToken' consul operator raft list-peers 2>&1 | grep -c 'leader' || true"
    $out -match '^1$'
} | Out-Null

# ─── Section: Negative checks (deny-mode enforcement) ─────────────────────
Write-Section 'Anonymous access denied (default_policy=deny enforced)'

foreach ($ip in $allIps) {
    Test-Check -Description "$ip : anonymous HTTPS GET /v1/agent/self returns 403 (deny enforced)" -Probe {
        # `consul members` with no token does NOT error -- Consul filters by
        # node:read and returns an empty list, so we can't pattern-match on
        # output. /v1/agent/self requires agent:read on the host; anonymous
        # token has no permissions in deny-mode, so curl returns 403 with
        # a "Permission denied" body. Single unambiguous signal.
        $out = Invoke-RemoteCommand -Ip $ip -Command "curl -sS --cacert /etc/ssl/certs/consul-ca.pem -o /dev/null -w '%{http_code}' https://127.0.0.1:8501/v1/agent/self"
        $out -match '^403$'
    } | Out-Null
}

# Note: /v1/agent/members is intentionally NOT probed here -- Consul
# returns 200 with an empty array under deny (filtered by node:read per
# node), not 403. The 6 per-node /v1/agent/self probes above are the
# canonical anonymous-deny enforcement test.

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'ALL 0.E.2.3 SMOKE CHECKS PASSED (chained 0.E.2.2 + 0.E.2.1 + 0.E.1 baseline)' -ForegroundColor Green
    Write-Host 'Consul ACL system ENFORCED across all 6 agents: default_policy=deny, down_policy=extend-cache, mgmt token in Vault KV, 6 per-agent tokens active, anonymous calls denied at API layer.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
