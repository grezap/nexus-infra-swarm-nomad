/*
 * modules/vm — NexusPlatform reusable single-NIC VM module
 *
 * Instantiates a Packer-built template as a running VMware Workstation VM
 * with a single pinned-MAC NIC on a caller-chosen VMnet. Same vmrun-driven
 * approach as terraform/gateway/main.tf (see that module's header comment
 * for the rationale — elsudano/vmworkstation v2.0.1 has three blockers we
 * avoid by driving vmrun.exe directly).
 *
 * This module is the generic case: one template, one NIC, one MAC.
 * nexus-gateway's 3-NIC topology stays in terraform/gateway/ — it's too
 * special to squeeze into this module's surface area without regretting it.
 *
 * Lifecycle:
 *   1. clone_vm      — `vmrun clone <template> <dst> full` full clone.
 *   2. configure_nic — `scripts/configure-vm-nic.ps1` rewrites the cloned
 *                      .vmx so ethernet0 has the caller's VMnet + MAC.
 *   3. power_on      — `vmrun start <dst> nogui`.
 *
 * Destroy runs in reverse (stop → deleteVM → rm -rf parent dir) — see the
 * destroy-time provisioners. `self.triggers.*` mirrors `local.*` values so
 * Terraform's destroy-time reference restrictions are satisfied.
 */

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

locals {
  target_vmx  = "${var.vm_output_dir}/${var.vm_name}.vmx"
  scripts_dir = abspath("${path.module}/../../../scripts")
}

# ─── Clone template → running VM instance ─────────────────────────────────
resource "null_resource" "clone_vm" {
  triggers = {
    template_vmx = var.template_vmx_path
    target_vmx   = local.target_vmx
    vm_name      = var.vm_name
    vmrun        = var.vmrun_path
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $src = '${var.template_vmx_path}'
      $dst = '${local.target_vmx}'
      if (-not (Test-Path $src)) { throw "Template VMX not found: $src" }
      if (Test-Path $dst)        { throw "Destination already exists: $dst — terraform destroy first or taint clone_vm." }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
      & '${var.vmrun_path}' clone $src $dst full -cloneName=${var.vm_name}
      if ($LASTEXITCODE -ne 0) { throw "vmrun clone failed with exit code $LASTEXITCODE" }
      if (-not (Test-Path $dst)) { throw "vmrun reported success but $dst was not created." }
      Write-Host "Cloned ${var.vm_name}: $src -> $dst"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $dst   = '${self.triggers.target_vmx}'
      $vmrun = '${self.triggers.vmrun}'
      if (Test-Path $dst) {
        # Both calls can "fail" legitimately (VM already stopped, stale
        # registration) — vmrun writes errors to stdout with a non-zero exit.
        # Capture + discard both streams and ignore exit codes.
        & $vmrun stop     $dst hard *>$null
        & $vmrun deleteVM $dst      *>$null
        Remove-Item -Recurse -Force (Split-Path -Parent $dst) -ErrorAction SilentlyContinue
      }
      exit 0
    PWSH
  }
}

# ─── NIC configuration (single-NIC or dual-NIC) ──────────────────────────
# When var.vnet_secondary + var.mac_secondary are both non-null, configure-vm-nic.ps1
# writes ethernet1 in addition to ethernet0. Default: single-NIC.
resource "null_resource" "configure_nic" {
  triggers = {
    target_vmx     = local.target_vmx
    vnet           = var.vnet
    mac_address    = var.mac_address
    vnet_secondary = var.vnet_secondary == null ? "" : var.vnet_secondary
    mac_secondary  = var.mac_secondary == null ? "" : var.mac_secondary
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      # Use hashtable splat (NOT array splat) for named-parameter invocation.
      # Array splat with `-Name`, value pairs treats `-Mac` as a value at
      # positional bind time, leaving the MAC value with nowhere to go and
      # erroring "A positional parameter cannot be found that accepts
      # argument '00:50:56:...'". Discovered 2026-04-29 during foundation
      # cycle after dual-NIC modules/vm extension landed.
      $nicArgs = @{
        VmxPath = '${local.target_vmx}'
        Vnet    = '${var.vnet}'
        Mac     = '${var.mac_address}'
      }
      $secondaryVnet = '${var.vnet_secondary == null ? "" : var.vnet_secondary}'
      $secondaryMac  = '${var.mac_secondary == null ? "" : var.mac_secondary}'
      if ($secondaryVnet -and $secondaryMac) {
        $nicArgs.SecondaryVnet = $secondaryVnet
        $nicArgs.SecondaryMac  = $secondaryMac
      }
      & '${local.scripts_dir}/configure-vm-nic.ps1' @nicArgs
    PWSH
  }

  depends_on = [null_resource.clone_vm]
}

# ─── Power on ────────────────────────────────────────────────────────────
resource "null_resource" "power_on" {
  triggers = {
    target_vmx = local.target_vmx
    vmrun      = var.vmrun_path
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "& '${var.vmrun_path}' start '${local.target_vmx}' nogui"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "& '${self.triggers.vmrun}' stop '${self.triggers.target_vmx}' hard 2>$null; exit 0"
  }

  depends_on = [null_resource.configure_nic]
}
