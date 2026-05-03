# terraform/modules/vm

Reusable VMware Workstation VM module for NexusPlatform lab VMs. **Implemented in Phase 0.B.2; extended to dual-NIC in Phase 0.D.1** — consumed first by `terraform/deb13-smoke/` to verify the deb13 template, then by `terraform/envs/foundation/` (Phase 0.C — single-NIC dc-nexus + jumpbox), and `terraform/envs/security/` (Phase 0.D — dual-NIC Vault cluster nodes).

Instantiates a Packer-built template as a running VM with one or two pinned-MAC NICs on caller-chosen VMnets. Drives `vmrun.exe` through `null_resource` + `local-exec` — no `vmrest` daemon or third-party provider required.

## Why this module exists

The `terraform/gateway/` module is hand-rolled for nexus-gateway's 3-NIC topology (bridged + VMnet11 + VMnet10). Every other lab VM has a simpler shape: one NIC on VMnet11 (single-NIC mode), or two NICs on VMnet11 + VMnet10 (dual-NIC mode for cluster-shaped services like Vault, Consul, Postgres replicas). This module covers both. The 3+ NIC case stays in `terraform/gateway/` until a second 3-NIC consumer appears.

## Modes

- **Single-NIC** (default): one NIC at `ethernet0` on `var.vnet` with `var.mac_address`. Used by foundation env (dc-nexus, jumpbox) and most data/apps-tier VMs.
- **Dual-NIC**: when `var.vnet_secondary` AND `var.mac_secondary` are both non-null, a second NIC is added at `ethernet1`. Used by Vault cluster nodes (Phase 0.D — VMnet11 service + VMnet10 backplane per `nexus-platform-plan/docs/infra/vms.yaml` and MASTER-PLAN line 188) and any future cluster-shaped service.

## Inputs

| Variable            | Required | Default                                                  | Notes |
|---------------------|----------|----------------------------------------------------------|-------|
| `vm_name`           | yes      | —                                                        | Unique. Used as `.vmx` basename and `vmrun -cloneName`. |
| `template_vmx_path` | yes      | —                                                        | Absolute path to the Packer-built `.vmx` (e.g. the deb13 template). |
| `vm_output_dir`     | yes      | —                                                        | Where the clone lands. Created by `vmrun clone`. |
| `vnet`              | no       | `VMnet11`                                                | Primary NIC's VMware network name. Case-insensitive. Built-ins: `bridged`, `nat`, `hostonly`. |
| `mac_address`       | yes      | —                                                        | Primary NIC MAC: `00:50:56:XX:YY:ZZ` with `XX` in `0x00..0x3F`. Regex-validated. |
| `vnet_secondary`    | no       | `null`                                                   | Optional secondary NIC's VMware network. Typically `VMnet10` (backplane) when primary is `VMnet11`. Must be set together with `mac_secondary`. |
| `mac_secondary`     | no       | `null`                                                   | Optional secondary NIC MAC. Same OUI rules as primary. Convention: fifth byte `0x01` for secondary, mirroring primary's sixth byte. Regex-validated when set. |
| `cpus`              | no       | `2`                                                      | Reserved — not yet applied at runtime (Packer template value inherited). |
| `memory_mb`         | no       | `1024`                                                   | Reserved — not yet applied. |
| `vmrun_path`        | no       | `C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe` | Override if Workstation is installed elsewhere. |

## Outputs

| Output         | Value |
|----------------|-------|
| `vm_path`      | `${vm_output_dir}/${vm_name}.vmx` |
| `mac_address`  | Pass-through of the input MAC.     |
| `vm_name`      | Pass-through of the input name.    |

## Usage — single-NIC

```hcl
module "my_vm" {
  source = "../modules/vm"

  vm_name           = "my-postgres"
  template_vmx_path = "H:/VMS/NexusPlatform/_templates/deb13/deb13.vmx"
  vm_output_dir     = "H:/VMS/NexusPlatform/20-data/my-postgres"
  mac_address       = "00:50:56:3F:00:30"
  # vnet defaults to VMnet11
}

output "postgres_mac" { value = module.my_vm.mac_address }
```

## Usage — dual-NIC (Vault cluster node)

```hcl
module "vault_1" {
  source = "../modules/vm"

  vm_name           = "vault-1"
  template_vmx_path = "H:/VMS/NexusPlatform/_templates/vault/vault.vmx"
  vm_output_dir     = "H:/VMS/NexusPlatform/01-foundation/vault-1"

  # Primary NIC: VMnet11 service network (DHCP from nexus-gateway, pinned IP via dhcp-host MAC reservation)
  vnet              = "VMnet11"
  mac_address       = "00:50:56:3F:00:40"

  # Secondary NIC: VMnet10 cluster backplane (no DHCP server; static IP configured at OS level)
  vnet_secondary    = "VMnet10"
  mac_secondary     = "00:50:56:3F:01:40"
}
```

The VM boots, DHCPs from `nexus-gateway`'s dnsmasq (typically gets an IP in `192.168.70.200-.250`), and is reachable via SSH from the host at whatever DHCP address it lands on. If you want a pinned IP, declare a static lease in `nexus-gateway`'s dnsmasq config (the `addn-hosts` mechanism — see `docs/nexus-gateway.md`).

## MAC allocation convention

Reserve MAC ranges per tier so you don't collide:

| Range                   | Purpose                                     |
|-------------------------|---------------------------------------------|
| `00:50:56:3F:00:10-1F`  | Edge tier (gateway has `:10`, `:11`, `:12`). |
| `00:50:56:3F:00:20-2F`  | Smoke-test / scratch VMs.                   |
| `00:50:56:3F:00:30-3F`  | Data-tier VMs (Postgres, Mongo, …).         |
| `00:50:56:3F:00:40-4F`  | Core services (Vault, Consul, …).           |
| `00:50:56:3F:00:50-5F`  | Apps tier.                                  |
| `00:50:56:3F:00:60-FF`  | Reserved for future tiers.                  |

These are conventions, not enforced. Document each allocation in the calling module's `variables.tf`.

## Limitations

- **Up to 2 NICs.** 3+ NIC VMs hand-roll their own `null_resource` chain (see `terraform/gateway/` for the 3-NIC reference).
- **`cpus` and `memory_mb` inputs are not yet applied.** Packer's template values are inherited. Future improvement: edit the cloned `.vmx` in `configure_nic` (it already rewrites ethernet entries; same pattern extends to `numvcpus` + `memsize`).
- **Destroy is hard-kill** (`vmrun stop <vmx> hard`). For graceful shutdown, add a destroy provisioner running `vmrun stop <vmx> soft` ahead of `power_on`.
- **Dual-NIC mode does NOT configure the secondary NIC's IP at the OS level.** VMware sees the NIC; the guest OS still needs to assign an IP. For VMnet10 backplane (no DHCP server in the lab), the consuming Packer template is responsible for static IP config (e.g. `vault` template's first-boot script reads hostname → maps to canonical 192.168.10.121/.122/.123).
