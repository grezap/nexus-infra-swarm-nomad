/*
 * envs/swarm-nomad -- Phase 0.E.1: 3+3 Docker Swarm + Nomad + Consul cluster.
 *
 * Per nexus-platform-plan/docs/infra/vms.yaml lines 182-191 +
 * MASTER-PLAN.md Phase 0.E goal (line 151):
 *
 *   - 3 manager nodes  (swarm-manager-1/2/3) -- Swarm manager + Nomad server
 *                                               + Consul server
 *   - 3 worker  nodes  (swarm-worker-1/2/3)  -- Swarm worker  + Nomad client
 *                                               + Consul client (idiomatic
 *                                               for Nomad service discovery;
 *                                               canon adds at 0.E close-out)
 *
 *   - OS: Debian 13 via the swarm-node Packer template
 *   - Tier directory: H:/VMS/NexusPlatform/06-orchestration/<vm>/
 *   - Per-VM subdirs (memory/feedback_vmware_per_vm_folders.md)
 *   - Dual-NIC: VMnet11 service network (DHCP via dnsmasq dhcp-host
 *     reservation -> .111-.113 / .131-.133) + VMnet10 cluster backplane
 *     (static IP per hostname mapping in swarm-node-firstboot.sh)
 *   - Managers: 4 vCPU, 6 GB RAM (deviation from canon 8 GB)
 *   - Workers:  4 vCPU, 4 GB RAM (deviation from canon 8 GB)
 *   - 80 GB disk each
 *
 * MAC convention (per memory feedback_windows_ssh_automation.md +
 * project_nexus_infra_phase.md range tracking):
 *   00:50:56:3F:00:50-52  -> manager primaries (VMnet11)
 *   00:50:56:3F:00:53-55  -> worker primaries  (VMnet11)
 *   00:50:56:3F:01:50-55  -> secondaries       (VMnet10)
 *
 * Selective ops (per memory/feedback_selective_provisioning.md):
 *   - var.enable_swarm_cluster (default true) gates the entire env
 *   - Per-VM `var.enable_swarm_manager_N` / `var.enable_swarm_worker_N`
 *     toggles for iteration (each defaults true)
 *   - role-overlay-swarm-init.tf wires `docker swarm init` + cluster join
 *     AFTER all 6 clones are up; toggleable via var.enable_swarm_init
 *
 * Pre-flight dependency: nexus-gateway must have the Swarm dnsmasq
 * dhcp-host reservations active. This is owned by
 * nexus-infra-vmware/terraform/envs/foundation/role-overlay-gateway-swarm-reservations.tf
 * (toggled via var.enable_swarm_dhcp_reservations -- default true).
 * Operator order:
 *
 *   1. Foundation env (in nexus-infra-vmware):
 *      pwsh -File scripts/foundation.ps1 apply
 *   2. Swarm-node Packer template built (packer build packer/swarm-node)
 *   3. THIS env: pwsh -File scripts/swarm.ps1 apply
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

# ─── Manager nodes (3) ────────────────────────────────────────────────────
module "swarm_manager_1" {
  source = "../../modules/vm"
  count  = var.enable_swarm_cluster && var.enable_swarm_manager_1 ? 1 : 0

  vm_name           = "swarm-manager-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/swarm-manager-1"

  vnet        = var.vnet_primary
  mac_address = var.mac_swarm_manager_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_swarm_manager_1_secondary
}

module "swarm_manager_2" {
  source = "../../modules/vm"
  count  = var.enable_swarm_cluster && var.enable_swarm_manager_2 ? 1 : 0

  vm_name           = "swarm-manager-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/swarm-manager-2"

  vnet        = var.vnet_primary
  mac_address = var.mac_swarm_manager_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_swarm_manager_2_secondary
}

module "swarm_manager_3" {
  source = "../../modules/vm"
  count  = var.enable_swarm_cluster && var.enable_swarm_manager_3 ? 1 : 0

  vm_name           = "swarm-manager-3"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/swarm-manager-3"

  vnet        = var.vnet_primary
  mac_address = var.mac_swarm_manager_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_swarm_manager_3_secondary
}

# ─── Worker nodes (3) ─────────────────────────────────────────────────────
module "swarm_worker_1" {
  source = "../../modules/vm"
  count  = var.enable_swarm_cluster && var.enable_swarm_worker_1 ? 1 : 0

  vm_name           = "swarm-worker-1"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/swarm-worker-1"

  vnet        = var.vnet_primary
  mac_address = var.mac_swarm_worker_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_swarm_worker_1_secondary
}

module "swarm_worker_2" {
  source = "../../modules/vm"
  count  = var.enable_swarm_cluster && var.enable_swarm_worker_2 ? 1 : 0

  vm_name           = "swarm-worker-2"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/swarm-worker-2"

  vnet        = var.vnet_primary
  mac_address = var.mac_swarm_worker_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_swarm_worker_2_secondary
}

module "swarm_worker_3" {
  source = "../../modules/vm"
  count  = var.enable_swarm_cluster && var.enable_swarm_worker_3 ? 1 : 0

  vm_name           = "swarm-worker-3"
  template_vmx_path = var.template_vmx_path
  vm_output_dir     = "${var.vm_output_dir_root}/swarm-worker-3"

  vnet        = var.vnet_primary
  mac_address = var.mac_swarm_worker_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_swarm_worker_3_secondary
}
