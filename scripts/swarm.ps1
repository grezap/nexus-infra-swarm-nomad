#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the swarm-nomad env -- pwsh-native equivalent of
  the bash-shaped Makefile targets.

.DESCRIPTION
  Mirrors nexus-infra-vmware/scripts/{foundation,security}.ps1 shape (per
  memory/feedback_build_host_pwsh_native.md -- GNU make is not installed
  on the build host; pwsh wrappers are canonical). Provides
  apply/destroy/smoke/cycle/plan/validate verbs against
  terraform/envs/swarm-nomad/ + delegates smoke to scripts/smoke-0.E.<N>.ps1.

  Pre-flight dependency: nexus-gateway must have the Swarm dnsmasq
  dhcp-host reservations active (managed in nexus-infra-vmware's foundation
  env via role-overlay-gateway-swarm-reservations.tf, default true).
  This wrapper does NOT check or apply those reservations -- foundation
  ownership stays separate.

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/swarm-nomad
  destroy  -- terraform destroy -auto-approve
  smoke    -- run the active phase smoke gate (default 0.E.1)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Phase
  Which smoke phase to run. '0.E.1' (default) is the only phase implemented
  in this commit; later sub-phases (0.E.2 Consul harden, 0.E.3 Nomad
  harden, 0.E.4 Portainer, 0.E.5 Vault Agents) will add their own gates.

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags.

.PARAMETER SmokeArgs
  Hashtable forwarded to the smoke script (e.g. -SmokeArgs @{Strict=$true}).

.EXAMPLE
  pwsh -File scripts\swarm.ps1 cycle

.EXAMPLE
  # bring up only the 3 managers (skip workers + cluster init); useful for
  # iterating on the manager-side topology
  pwsh -File scripts\swarm.ps1 apply -Vars enable_swarm_worker_1=false,enable_swarm_worker_2=false,enable_swarm_worker_3=false,enable_swarm_init=false

.EXAMPLE
  # destroy + re-apply a single worker (mgrs + other workers untouched)
  pwsh -File scripts\swarm.ps1 apply -Vars enable_swarm_worker_2=false
  pwsh -File scripts\swarm.ps1 apply

.NOTES
  See scripts/smoke-0.E.<N>.ps1 for the underlying check definitions.
  See nexus-infra-vmware/scripts/{foundation,security}.ps1 for the same
  shape applied to envs/foundation/ + envs/security/ in the parent repo.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [ValidateSet('0.E.1', '0.E.2.1', '0.E.2.2', '0.E.2.3', '0.E.3.1', '0.E.3.2', '0.E.3.3', '0.E.4')]
    [string]$Phase = '0.E.4',

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\swarm-nomad'
$smokePath = Join-Path $repoRoot ("scripts\smoke-{0}.ps1" -f $Phase)

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) {
            throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
}

function Get-VarFlags {
    # Same -Vars handling as foundation.ps1 / security.ps1: accept both PS
    # array form and comma-joined-string form (pwsh -File doesn't tokenize
    # commas like interactive PS does).
    $flags = @()
    foreach ($v in $Vars) {
        foreach ($piece in ($v -split ',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $flags += @('-var', $trimmed) }
        }
    }
    return $flags
}

function Invoke-Apply {
    Write-Step 'terraform apply -auto-approve'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step "pwsh -File $(Split-Path -Leaf $smokePath) (phase $Phase)"
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found for phase $Phase`: $smokePath"
    }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "smoke gate failed (exit $LASTEXITCODE)"
    }
}

function Invoke-Plan {
    Write-Step 'terraform plan'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate'
    Invoke-Terraform @('validate')
}

# ─── Dispatch ─────────────────────────────────────────────────────────────
switch ($Verb) {
    'apply'    { Invoke-Apply }
    'destroy'  { Invoke-Destroy }
    'smoke'    { Invoke-Smoke }
    'plan'     { Invoke-Plan }
    'validate' { Invoke-Validate }
    'cycle' {
        Invoke-Destroy
        Invoke-Apply
        Invoke-Smoke
    }
}

Write-Host ''
Write-Host "swarm $Verb complete" -ForegroundColor Green
