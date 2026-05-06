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

variable "enable_consul_acl" {
  description = "Phase 0.E.2.3 toggle: enable Consul ACL system cluster-wide. Bootstraps a management token (one-shot, persisted to Vault KV at nexus/swarm/consul-bootstrap-token), creates 6 per-agent policies + tokens (written to nexus/swarm/agent-tokens/<host>), drops Vault Agent template that renders /etc/consul.d/30-acl-token.hcl with each node's agent token, and tightens default_policy to deny via sequential rolling restart. Default true (steady state per memory/feedback_terraform_partial_apply_destroys_resources.md). Set false to keep cluster on legacy no-ACL mode (lab iteration)."
  type        = bool
  default     = true
}

variable "vault_1_ip" {
  description = "VMnet11 IP of vault-1 -- the build host orchestrates KV writes (consul-bootstrap-token, agent-tokens/<host>) by SSH'ing here and running `vault kv put` locally. Mirrors the pattern in nexus-infra-vmware/terraform/envs/security/role-overlay-vault-swarm-secrets-seed.tf."
  type        = string
  default     = "192.168.70.121"
}

variable "vault_init_keys_file" {
  description = "Path on the build host to the Vault init JSON sidecar (root_token + unseal keys), produced by nexus-infra-vmware's `vault_post_init` overlay at 0.D.1. The 0.E.2.3 ACL overlay reads root_token from this file to authenticate the KV writes against vault-1. Default mirrors nexus-infra-vmware/security env's variable of the same name."
  type        = string
  default     = "$HOME/.nexus/vault-init.json"
}

# ─── Phase 0.E.3 — Nomad harden ───────────────────────────────────────────
variable "enable_nomad_tls" {
  description = "Phase 0.E.3.1 toggle: per-node TLS leaf cert from Vault PKI nomad-server role + Nomad tls{} block enabling mutual TLS for RPC + HTTPS API on 4646. Sequential rolling restart of nomad.service across the 6 agents. Default true (steady state per memory/feedback_terraform_partial_apply_destroys_resources.md). Set false to keep Nomad on plain HTTP/4646 (lab-only)."
  type        = bool
  default     = true
}

variable "vault_pki_nomad_role_name" {
  description = "Name of the Vault PKI role under pki_int/ that issues Nomad leaf certs. Mirrors nexus-infra-vmware/terraform/envs/security/variables.tf default; both envs must agree on the role name. Used by 0.E.3.1 Vault Agent template's pkiCert call."
  type        = string
  default     = "nomad-server"
}

variable "enable_nomad_acl" {
  description = "Phase 0.E.3.2 toggle: enable Nomad ACL system cluster-wide. Bootstraps a management token (one-shot, persisted to Vault KV at nexus/swarm/nomad-bootstrap-token), creates a shared `nomad-agent` policy + 6 per-host tokens (written to nexus/swarm/nomad-agent-tokens/<host>), drops Vault Agent template that renders /etc/nomad.d/50-acl-token.hcl with each node's agent token, and applies via sequential rolling restart. Default true (steady state per memory/feedback_terraform_partial_apply_destroys_resources.md). Set false to keep the cluster on no-ACL mode (lab iteration only)."
  type        = bool
  default     = true
}

# ─── Phase 0.E.3.3a — Nomad → Consul HTTPS rewire ─────────────────────────
variable "enable_nomad_consul_rewire" {
  description = "Phase 0.E.3.3a toggle: rewire Nomad's `consul {}` agent stanza from the firstboot-rendered `address = \"127.0.0.1:8500\"` (broken since the 0.E.2.2 hard-cut of HTTP/8500) to ACL-authenticated HTTPS:8501. Drops a Vault Agent template that renders /etc/nomad.d/42-consul-token.hcl from the existing per-host KV path nexus/swarm/agent-tokens/<host> (Consul agent token from 0.E.2.3 -- already has service_prefix + node_prefix read perms, sufficient for Nomad's discovery use case); drops a content-stable /etc/nomad.d/42-consul.hcl with `address = \"https://127.0.0.1:8501\"; ssl = true; ca_file = \"/etc/ssl/certs/consul-ca.pem\"`; surgically removes the legacy `consul { address = \"127.0.0.1:8500\" }` block from /etc/nomad.d/nomad.hcl so the file-merge order doesn't cause the legacy address to win; sequential rolling restart of nomad.service across the 6 agents (managers first). Default true (steady state). Set false for lab iteration on the prior shape. NOTE: workers retain /etc/nomad.d/41-client-servers.hcl (hardcoded manager IPs) under this sub-phase -- removing it requires extending the Consul agent policy with `service.nomad/nomad-client write` so Nomad agents can self-register, deferred to a later sub-phase."
  type        = bool
  default     = true
}

# ─── Phase 0.E.3.3b — Nomad ↔ Vault integration ───────────────────────────
variable "enable_nomad_vault_integration" {
  description = "Phase 0.E.3.3b toggle: enable Nomad's `vault {}` agent stanza on managers (3 nodes only -- workers don't need vault integration for the basic case). Vault Agent renders /etc/nomad.d/60-vault-token.txt from a periodic Vault token issued via the `nomad-cluster` token role (created by nexus-infra-vmware/security env's role-overlay-vault-nomad-jobs-policy.tf); /etc/nomad.d/60-vault.hcl declares the vault stanza with `enabled = true; address = \"https://192.168.70.121:8200\"; ca_file = \"/etc/vault-agent/ca-bundle.crt\"; create_from_role = \"nomad-cluster\"; token_file = \"/etc/nomad.d/60-vault-token.txt\"`. After this, Nomad jobs can request Vault secrets at runtime via the standard Vault Workload Identity flow. Default true (steady state). Set false to skip until later phase. Pre-req: security env's role-overlay-vault-nomad-jobs-policy.tf is applied (creates `nomad-jobs` policy + `nomad-cluster` token role) AND role-overlay-vault-agent-swarm-policies.tf v4 has rolled out (extends manager policies with `auth/token/create/nomad-cluster` capability)."
  type        = bool
  default     = true
}

variable "vault_nomad_cluster_role_name" {
  description = "Name of the Vault token role that mints periodic tokens for the Nomad servers' vault{} integration. Created by security env. Default 'nomad-cluster'."
  type        = string
  default     = "nomad-cluster"
}

variable "vault_addr" {
  description = "Vault server address as Nomad sees it. Uses VMnet11 IP (192.168.70.121) directly because vault-1.nexus.lab does NOT resolve from cluster nodes (only the short hostname `vault-1` resolves via the gateway dnsmasq). Used by 0.E.3.3b's nomad vault{} stanza."
  type        = string
  default     = "https://192.168.70.121:8200"
}

# ─── Phase 0.E.4a — Portainer NFS client mount (managers only) ─────────────
variable "enable_portainer_nfs_mount" {
  description = "Phase 0.E.4a toggle: per-manager NFSv4 mount of nexus-gateway's /srv/nfs/portainer-data export at /var/lib/portainer-data. Provides shared /data so the single Portainer CE Server replica can be Swarm-rescheduled across managers without state loss. Default true. Pre-req: foundation env's role-overlay-gateway-nfs-portainer.tf has run."
  type        = bool
  default     = true
}

variable "portainer_nfs_server" {
  description = "Hostname or IP of the NFS server exporting Portainer's /data. Defaults to 192.168.70.1 (nexus-gateway's VMnet11 IP)."
  type        = string
  default     = "192.168.70.1"
}

variable "portainer_nfs_remote_path" {
  description = "Remote NFS path on the server (must match foundation env's portainer_nfs_export_path). Default /srv/nfs/portainer-data."
  type        = string
  default     = "/srv/nfs/portainer-data"
}

variable "portainer_data_local_mount" {
  description = "Local mount point on each manager for the Portainer NFS share. Default /var/lib/portainer-data."
  type        = string
  default     = "/var/lib/portainer-data"
}

# ─── Phase 0.E.4b — Portainer TLS cert render (managers only) ──────────────
variable "enable_portainer_tls" {
  description = "Phase 0.E.4b toggle: per-manager Vault Agent template that renders a Portainer CE TLS leaf cert from pki_int/issue/portainer-server (created by security env's role-overlay-vault-pki-portainer.tf). Splits the bundle into /etc/portainer/tls/{server.crt, server.key, ca.pem} via post-render command. The Portainer CE Server container will bind-mount /etc/portainer/tls as /certs:ro at deploy time (0.E.4d). Default true. Pre-req: security env's manager Vault Agent policies are at v5+ (have pki_int/issue/portainer-server capability)."
  type        = bool
  default     = true
}

variable "vault_pki_portainer_role_name" {
  description = "Name of the PKI role under pki_int/ for Portainer leaf certs. Mirrors security env default. Used by 0.E.4b's Vault Agent template."
  type        = string
  default     = "portainer-server"
}

# ─── Phase 0.E.4d — Portainer admin password render + stack deploy ─────────
variable "enable_portainer_admin_render" {
  description = "Phase 0.E.4d toggle: per-manager Vault Agent template that renders /etc/portainer/admin-password.txt from `nexus/portainer/admin-bcrypt.bcrypt_hash` (sticky-seeded by security env). The Portainer CE Server container bind-mounts this as `/run/secrets/admin-pw:ro` and consumes it via `--admin-password-file`. Default true. Pre-req: security env at v6+ with manager policies granting read on the KV path."
  type        = bool
  default     = true
}

variable "enable_portainer_stack" {
  description = "Phase 0.E.4d toggle: deploy Portainer CE as a Docker Swarm stack via `docker stack deploy -c portainer-stack.yml portainer` from manager-1. Service shape: 1 server replica (manager-pinned via constraint) + global agent (1 task per node × 6 nodes). Bind-mounts NFS data + TLS certs + admin-password file. Default true. Pre-req: 0.E.4a NFS mount + 0.E.4b TLS render + 0.E.4d admin-password render all applied."
  type        = bool
  default     = true
}

variable "portainer_image_version" {
  description = "Portainer CE + agent image tag. Both portainer/portainer-ce and portainer/agent published with matching tags. Default `lts` (long-term-support floating tag); pin to a specific version like `2.21.4` for reproducibility."
  type        = string
  default     = "lts"
}

variable "enable_portainer_firewall" {
  description = "Phase 0.E.4d toggle: patch /etc/nftables.conf on all 6 swarm-nodes to allow inbound TCP/9443 (Portainer HTTPS UI) + TCP/8000 (Edge agent tunnel) from VMnet11. Required because the swarm-node baseline ruleset doesn't open Portainer's published ports, and Docker Swarm's routing mesh accepts on every node. The overlay also restarts dockerd sequentially after the `nft -f` reload (which would otherwise wipe Docker's iptables-nft ingress mesh rules due to `flush ruleset` in /etc/nftables.conf). Default true. Pre-req: portainer_stack deployed (otherwise no ingress mesh to set up)."
  type        = bool
  default     = true
}
