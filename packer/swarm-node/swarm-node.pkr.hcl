/*
 * swarm-node — NexusPlatform Docker Swarm + Nomad + Consul node template
 *              (Phase 0.E.1)
 *
 * Six instances of this template clone into a 3+3 Swarm cluster on the
 * orchestration tier (06-orchestration). Per nexus-platform-plan/
 * docs/infra/vms.yaml lines 182-191:
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as deb13 + vault)
 *   - 4 vCPU, 80 GB disk
 *   - RAM: managers 6 GB, workers 4 GB (DEVIATION FROM CANON: vms.yaml says
 *     8 GB across the board; user-approved 2026-05-03 per memory/
 *     feedback_prefer_less_memory.md -- managers run Docker + Consul
 *     server + Nomad server + Portainer manager replica, workers run
 *     just Docker + Consul client + Nomad client; lab-scale observation
 *     supports the lower spec; vms.yaml updated at 0.E close-out.
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service); ethernet1 =
 *     VMnet10 (cluster backplane / Swarm + Consul Raft + Nomad raft)
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): single NAT NIC for apt fetch, then
 *     `vmx_remove_ethernet_interfaces = true` strips it. Docker CE +
 *     Nomad binary + Consul binary downloaded + verified + installed.
 *     Systemd units delivered (disabled until firstboot decides
 *     server-vs-client mode).
 *   - Clone-time (terraform/modules/vm): scripts/configure-vm-nic.ps1
 *     writes ethernet0 (VMnet11) + ethernet1 (VMnet10) post-clone.
 *   - First-boot (swarm-node-firstboot.service ExecStart): MAC-OUI-byte-5
 *     NIC discovery (same pattern as vault-firstboot.sh); maps VMnet11 IP
 *     to canonical hostname (.111-.113 -> swarm-manager-N, .131-.133 ->
 *     swarm-worker-N); writes /etc/hosts; configures VMnet10 backplane
 *     (.111-.113/.131-.133); renders /etc/consul.d/consul.hcl + /etc/
 *     nomad.d/nomad.hcl in server mode (manager) or client mode (worker);
 *     then enables consul.service, nomad.service, docker.service.
 *   - Cluster bring-up (terraform/envs/swarm-nomad/role-overlay-swarm-init.tf):
 *     after all 6 nodes have docker.service Running, SSH to mgr-1 runs
 *     `docker swarm init`, captures manager + worker join tokens, joins
 *     the other 5 nodes via SSH.
 *
 * Self-signed bootstrap is regenerated PER-CLONE at first boot using the
 * clone's actual hostname + IP. Phase 0.E.5 reissues from Vault PKI.
 *
 * Build:   cd packer/swarm-node; packer init .; packer build .
 * See:     docs/handbook.md s 1
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ─── Source: Debian 13 netinst, VMware Workstation builder ────────────────
source "vmware-iso" "swarm-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64" # Workstation catalog lags; compatible with Debian 13
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0 # growable single-file VMDK

  # Single NAT NIC at build time -- Terraform attaches the real dual-NIC
  # config (VMnet11 + VMnet10) at clone time via modules/vm/.
  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20" # WS 17+ hw version

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  # Strip all ethernet*.* lines so Terraform's modules/vm can write the
  # dual-NIC config cleanly post-clone.
  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "swarm-node template (Phase 0.E.1) -- built by Packer; Docker CE ${var.docker_channel}, Nomad ${var.nomad_version}, Consul ${var.consul_version}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

# ─── Build: install OS + install Docker/Nomad/Consul + apply shared roles ─
build {
  name    = "swarm-node"
  sources = ["source.vmware-iso.swarm-node"]

  # Stage static config files the shared roles + swarm_node role expect
  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip"
    ]
  }

  # Apply the shared nexus_* roles + the swarm_node tail.
  # extra_arguments per-pair to avoid the shell-tokenization issue
  # documented in nexus-infra-vmware/packer/vault/vault.pkr.hcl.
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "ansible/roles/swarm_node",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "docker_channel=${var.docker_channel}",
      "--extra-vars", "nomad_version=${var.nomad_version}",
      "--extra-vars", "consul_version=${var.consul_version}",
      "--extra-vars", "hashicorp_arch=${var.hashicorp_arch}",
    ]
  }

  # Final sanity + cleanup.
  # Mirrors vault.pkr.hcl: service-state checks only, no FS-permission-
  # sensitive probes (Docker + Consul + Nomad data dirs are 0700/0750
  # owned by their respective users -- nexusadmin can't traverse).
  provisioner "shell" {
    inline = [
      "echo '--- swarm-node post-install checks ---'",
      "test -x /usr/bin/docker",
      "test -x /usr/local/bin/nomad",
      "test -x /usr/local/bin/consul",
      "/usr/bin/docker --version",
      "/usr/local/bin/nomad version | head -1",
      "/usr/local/bin/consul version | head -1",
      # docker.service is INTENTIONALLY DISABLED at template time so it doesn't
      # start before swarm-node-firstboot.service has set up NIC config + the
      # iptables-baseline-vs-nftables interaction is decided. firstboot does
      # `systemctl enable --now docker.service` after rendering its config.
      # We just verify the unit got registered (apt install of docker-ce
      # delivers /lib/systemd/system/docker.service) -- `systemctl cat` exits 0
      # if the unit exists in any unit-file lookup path, regardless of enable
      # state, and exits non-zero if the unit is unknown.
      "systemctl cat docker.service > /dev/null",
      "systemctl is-enabled swarm-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "id consul",
      "id nomad",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*", # regenerated on first boot
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
