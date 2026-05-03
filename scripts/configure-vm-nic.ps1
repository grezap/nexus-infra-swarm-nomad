<#
.SYNOPSIS
    Rewrite a cloned .vmx to attach one or two NICs with pinned MACs.

.DESCRIPTION
    NexusPlatform's Packer templates are built with `vmx_remove_ethernet_interfaces
    = true` so the resulting template has zero NIC entries. Terraform's modules/vm/
    calls this script after `vmrun clone` to add NICs:

      Single-NIC mode (default):
        ethernet0 -> caller-chosen VMnet + MAC. Used by foundation env
        VMs (dc-nexus, jumpbox) and most data-tier VMs.

      Dual-NIC mode (when -SecondaryVnet + -SecondaryMac are provided):
        ethernet0 = primary (typically VMnet11 service network).
        ethernet1 = secondary (typically VMnet10 cluster backplane).
        Used by Vault cluster nodes (per nexus-platform-plan/docs/infra/vms.yaml
        + MASTER-PLAN.md line 188) and any future cluster-shaped service.

    For 3+ NIC VMs (e.g. nexus-gateway with bridged + VMnet10 + VMnet11),
    see scripts/configure-gateway-nics.ps1.

.PARAMETER VmxPath
    Absolute path to the cloned .vmx.

.PARAMETER Vnet
    Primary NIC's VMware network name (ethernet0). Examples: "vmnet11" (lab
    service), "vmnet10" (backplane), "bridged" (physical LAN). Case-insensitive.

.PARAMETER Mac
    Primary NIC's static MAC. VMware requires the 00:50:56 OUI and fourth byte
    in 0x00-0x3F for the user-managed range.

.PARAMETER SecondaryVnet
    Optional secondary NIC's VMware network name (ethernet1). When provided
    together with -SecondaryMac, the script writes a second NIC entry.

.PARAMETER SecondaryMac
    Optional secondary NIC's static MAC. Same OUI + fourth-byte rules apply.

.EXAMPLE
    # Single-NIC (most common)
    ./configure-vm-nic.ps1 `
        -VmxPath H:/VMS/NexusPlatform/01-foundation/dc-nexus/dc-nexus.vmx `
        -Vnet    VMnet11 `
        -Mac     00:50:56:3F:00:25

.EXAMPLE
    # Dual-NIC (Vault cluster node — VMnet11 service + VMnet10 backplane)
    ./configure-vm-nic.ps1 `
        -VmxPath H:/VMS/NexusPlatform/01-foundation/vault-1/vault-1.vmx `
        -Vnet            VMnet11 `
        -Mac             00:50:56:3F:00:40 `
        -SecondaryVnet   VMnet10 `
        -SecondaryMac    00:50:56:3F:01:40
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmxPath,
    [Parameter(Mandatory)][string]$Vnet,
    [Parameter(Mandatory)][string]$Mac,
    [string]$SecondaryVnet,
    [string]$SecondaryMac
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $VmxPath)) {
    throw "VMX not found at $VmxPath"
}

# XOR check: both secondary params must be provided together, or neither.
$hasSecondary = $false
if ($SecondaryVnet -or $SecondaryMac) {
    if (-not ($SecondaryVnet -and $SecondaryMac)) {
        throw 'Provide BOTH -SecondaryVnet and -SecondaryMac (or neither). Got Vnet=' +
              "'$SecondaryVnet', Mac='$SecondaryMac'."
    }
    $hasSecondary = $true
}

function Format-NicBlock {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$NicVnet,
        [Parameter(Mandatory)][string]$NicMac
    )
    $key = "ethernet$Index"
    $vl  = $NicVnet.ToLower()
    $bi  = @{ 'bridged' = 'bridged'; 'nat' = 'nat'; 'hostonly' = 'hostonly' }
    if ($bi.ContainsKey($vl)) {
        return @(
            "$key.present = `"TRUE`""
            "$key.virtualDev = `"vmxnet3`""
            "$key.connectionType = `"$($bi[$vl])`""
            "$key.addressType = `"static`""
            "$key.address = `"$NicMac`""
            "$key.wakeOnPcktRcv = `"FALSE`""
            "$key.startConnected = `"TRUE`""
        )
    } else {
        return @(
            "$key.present = `"TRUE`""
            "$key.virtualDev = `"vmxnet3`""
            "$key.connectionType = `"custom`""
            "$key.vnet = `"$NicVnet`""
            "$key.addressType = `"static`""
            "$key.address = `"$NicMac`""
            "$key.wakeOnPcktRcv = `"FALSE`""
            "$key.startConnected = `"TRUE`""
        )
    }
}

$lines = Get-Content $VmxPath

# Strip any existing ethernet* entries so we write from a clean slate.
$lines = $lines | Where-Object { $_ -notmatch '^ethernet[0-9]+\.' }

$nicBlocks = @()
$nicBlocks += Format-NicBlock -Index 0 -NicVnet $Vnet -NicMac $Mac
if ($hasSecondary) {
    $nicBlocks += Format-NicBlock -Index 1 -NicVnet $SecondaryVnet -NicMac $SecondaryMac
}

$lines = @($lines) + $nicBlocks

# Write atomically (tmp + move) so a crashed script can't leave half a .vmx.
$tmp = "$VmxPath.tmp"
$lines | Set-Content -Path $tmp -Encoding ASCII
Move-Item -Path $tmp -Destination $VmxPath -Force

if ($hasSecondary) {
    Write-Host "[configure-vm-nic] wrote 2 NICs to $VmxPath" -ForegroundColor Green
    Write-Host "  ethernet0  vnet=$Vnet           MAC=$Mac"
    Write-Host "  ethernet1  vnet=$SecondaryVnet  MAC=$SecondaryMac"
} else {
    Write-Host "[configure-vm-nic] wrote 1 NIC to $VmxPath" -ForegroundColor Green
    Write-Host "  ethernet0  vnet=$Vnet  MAC=$Mac"
}
