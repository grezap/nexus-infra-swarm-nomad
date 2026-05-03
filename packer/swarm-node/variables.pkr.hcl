variable "vm_name" {
  type        = string
  default     = "swarm-node"
  description = "VM display name and output .vmx basename. Default `swarm-node` -- the template; per-clone names (swarm-manager-1/2/3 + swarm-worker-1/2/3) are set by terraform/envs/swarm-nomad/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/swarm-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.4.0/amd64/iso-cd/debian-13.4.0-amd64-netinst.iso"
  description = "Debian 13 netinst ISO URL. Same pin as nexus-infra-vmware/packer/{deb13,vault}."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:0b813535dd76f2ea96eff908c65e8521512c92a0631fd41c95756ffd7d4896dc"
  description = "ISO checksum (literal sha256). Same hash as deb13/vault -- all pin Debian 13.4.0 netinst."
}

variable "docker_channel" {
  type        = string
  default     = "stable"
  description = "Docker CE apt repo channel. `stable` is the only sane choice for the lab; `edge` removed in 2018, `test`/`nightly` only meaningful upstream."
}

variable "nomad_version" {
  type        = string
  default     = "1.9.3"
  description = "Nomad binary version to bake. Pinnable for upgrades. Latest stable as of 2026-05-03."
}

variable "consul_version" {
  type        = string
  default     = "1.20.1"
  description = "Consul binary version to bake. Pinnable for upgrades. Latest stable as of 2026-05-03."
}

variable "hashicorp_arch" {
  type        = string
  default     = "linux_amd64"
  description = "HashiCorp release archive arch suffix on releases.hashicorp.com. amd64 covers all current lab targets."
}

variable "cpus" {
  type        = number
  default     = 4
  description = "vCPU per node. Canon (vms.yaml lines 182-191)."
}

variable "memory_mb" {
  type        = number
  default     = 6144
  description = "Build-time RAM (MB). Set to manager spec (6 GB; APPROVED DEVIATION from canon 8 GB per memory/feedback_prefer_less_memory.md). Workers run at 4 GB (vmrun-resize at clone time -- see terraform/envs/swarm-nomad/)."
}

variable "disk_gb" {
  type        = number
  default     = 80
  description = "Disk size in GB. Canon (vms.yaml lines 182-191)."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
  # Build-time only. Phase 0.E.5 rotates to Vault Agent + key-only via PKI cert.
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
