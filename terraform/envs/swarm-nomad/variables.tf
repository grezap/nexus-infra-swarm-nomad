# envs/swarm-nomad -- variables.
#
# Defaults reflect steady-state (per memory/feedback_terraform_partial_apply
# _destroys_resources.md). Operator opt-out is the explicit override.

# ─── Toggles ───────────────────────────────────────────────────────────────
variable "enable_swarm_cluster" {
  description = "Master toggle for the entire env. Default true; set false to skip the whole apply (e.g. iterating on the foundation env without disturbing swarm)."
  type        = bool
  default     = true
}

variable "enable_swarm_manager_1" {
  description = "Manager-1 (swarm-manager-1) toggle. Default true."
  type        = bool
  default     = true
}

variable "enable_swarm_manager_2" {
  description = "Manager-2 toggle."
  type        = bool
  default     = true
}

variable "enable_swarm_manager_3" {
  description = "Manager-3 toggle. Disable for iteration on a 1-or-2-manager subset."
  type        = bool
  default     = true
}

variable "enable_swarm_worker_1" {
  description = "Worker-1 toggle."
  type        = bool
  default     = true
}

variable "enable_swarm_worker_2" {
  description = "Worker-2 toggle."
  type        = bool
  default     = true
}

variable "enable_swarm_worker_3" {
  description = "Worker-3 toggle."
  type        = bool
  default     = true
}

variable "enable_swarm_init" {
  description = "Whether to run the post-clone bring-up overlay (`docker swarm init` on mgr-1, join the rest). Default true. Disable for iteration on the VM provisioning layer alone."
  type        = bool
  default     = true
}

# ─── Template + paths ──────────────────────────────────────────────────────
variable "template_vmx_path" {
  description = "Absolute path to the swarm-node Packer template .vmx (per packer/swarm-node/variables.pkr.hcl `output_directory`)."
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/swarm-node/swarm-node.vmx"
}

variable "vm_output_dir_root" {
  description = "Per-VM clone destination root under tier 06-orchestration. Each clone lands in its own subdirectory (memory/feedback_vmware_per_vm_folders.md)."
  type        = string
  default     = "H:/VMS/NexusPlatform/06-orchestration"
}

# ─── Networks ──────────────────────────────────────────────────────────────
variable "vnet_primary" {
  description = "Primary VMware network (service NIC). Lab uses VMnet11 (192.168.70.0/24)."
  type        = string
  default     = "VMnet11"
}

variable "vnet_secondary" {
  description = "Secondary VMware network (cluster backplane: Swarm Raft, Consul Raft, Nomad raft). Lab uses VMnet10 (192.168.10.0/24)."
  type        = string
  default     = "VMnet10"
}

# ─── MAC pool: managers ────────────────────────────────────────────────────
variable "mac_swarm_manager_1_primary" {
  description = "swarm-manager-1 primary NIC (VMnet11). Pinned to .111 via gateway dhcp-host reservation."
  type        = string
  default     = "00:50:56:3F:00:50"
}

variable "mac_swarm_manager_1_secondary" {
  description = "swarm-manager-1 secondary NIC (VMnet10). Static 192.168.10.111 set by swarm-node-firstboot.sh."
  type        = string
  default     = "00:50:56:3F:01:50"
}

variable "mac_swarm_manager_2_primary" {
  type    = string
  default = "00:50:56:3F:00:51"
}

variable "mac_swarm_manager_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:51"
}

variable "mac_swarm_manager_3_primary" {
  type    = string
  default = "00:50:56:3F:00:52"
}

variable "mac_swarm_manager_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:52"
}

# ─── MAC pool: workers ─────────────────────────────────────────────────────
variable "mac_swarm_worker_1_primary" {
  description = "swarm-worker-1 primary NIC (VMnet11). Pinned to .131 via gateway dhcp-host reservation."
  type        = string
  default     = "00:50:56:3F:00:53"
}

variable "mac_swarm_worker_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:53"
}

variable "mac_swarm_worker_2_primary" {
  type    = string
  default = "00:50:56:3F:00:54"
}

variable "mac_swarm_worker_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:54"
}

variable "mac_swarm_worker_3_primary" {
  type    = string
  default = "00:50:56:3F:00:55"
}

variable "mac_swarm_worker_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:55"
}

# ─── Cluster bring-up ──────────────────────────────────────────────────────
variable "swarm_node_user" {
  description = "SSH user for the swarm-node clones (Packer-baked nexusadmin)."
  type        = string
  default     = "nexusadmin"
}

variable "swarm_cluster_timeout_minutes" {
  description = "Per-node SSH ready-probe timeout when waiting for clones to come up before swarm init/join."
  type        = number
  default     = 12
}

# ─── Phase 0.E.2 — Consul harden ──────────────────────────────────────────
# Setup primitives (Vault Agent install on all 6 nodes) + sub-phase toggles
# (0.E.2.1 gossip encrypt; 0.E.2.2 TLS lands here; 0.E.2.3 ACL lands here).
# Cross-repo dependency: nexus-infra-vmware/terraform/envs/security must be
# applied first to write the AppRole creds JSON sidecars + KV seed.

variable "enable_swarm_vault_agents" {
  description = "Master toggle for installing nexus-vault-agent.service on all 6 swarm-nodes (Phase 0.E.2 setup). Default true."
  type        = bool
  default     = true
}

variable "enable_swarm_manager_1_vault_agent" {
  description = "Per-host Vault Agent toggle for swarm-manager-1. Default true (gated under enable_swarm_vault_agents)."
  type        = bool
  default     = true
}

variable "enable_swarm_manager_2_vault_agent" {
  type    = bool
  default = true
}

variable "enable_swarm_manager_3_vault_agent" {
  type    = bool
  default = true
}

variable "enable_swarm_worker_1_vault_agent" {
  type    = bool
  default = true
}

variable "enable_swarm_worker_2_vault_agent" {
  type    = bool
  default = true
}

variable "enable_swarm_worker_3_vault_agent" {
  type    = bool
  default = true
}

variable "vault_agent_version" {
  description = "Vault binary version to install on each swarm-node (matches nexus-infra-vmware/packer/vault/variables.pkr.hcl `vault_version` default of 1.18.4)."
  type        = string
  default     = "1.18.4"
}

variable "vault_agent_swarm_creds_dir" {
  description = "Directory on the build host where the 6 vault-agent-swarm-<host>.json sidecars live (written by nexus-infra-vmware security env). Each contains role_id + secret_id + CA path + vault address."
  type        = string
  default     = "$HOME/.nexus"
}

variable "vault_pki_ca_bundle_path" {
  description = "Path on the build host to the Vault PKI root+intermediate CA bundle (written by nexus-infra-vmware security env at 0.D.2). Vault Agents on swarm nodes use this to verify the vault server cert."
  type        = string
  default     = "$HOME/.nexus/vault-ca-bundle.crt"
}

variable "vault_kv_mount_path" {
  description = "Vault KV-v2 engine mount path. Templates pull `<mount>/data/swarm/...` paths."
  type        = string
  default     = "nexus"
}

variable "enable_consul_gossip_encryption" {
  description = "Phase 0.E.2.1 toggle: drop Vault Agent template that renders /etc/consul.d/10-encrypt.hcl, restart consul to enroll in encrypted gossip. Sequential rolling apply across the 6 agents to preserve quorum. Default true."
  type        = bool
  default     = true
}

variable "enable_consul_tls" {
  description = "Phase 0.E.2.2 toggle: per-node TLS leaf cert from Vault PKI consul-server role + Consul tls{} block + HARD-CUT HTTP->HTTPS (port 8500 disabled, 8501 only). Sequential rolling restart across the 6 agents. Default true. Set false to keep cluster on plain HTTP/8500 (lab-only); otherwise this lands the production-shape mutual TLS for internal RPC + Raft, plus server-side TLS for the operator HTTPS API."
  type        = bool
  default     = true
}

variable "vault_pki_consul_role_name" {
  description = "Name of the Vault PKI role under pki_int/ that issues Consul leaf certs. Mirrors nexus-infra-vmware/terraform/envs/security/variables.tf default; both envs must agree on the role name. Used by 0.E.2.2 Vault Agent template's pkiCert call."
  type        = string
  default     = "consul-server"
}
