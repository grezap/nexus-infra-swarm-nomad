# envs/swarm-nomad -- outputs + operator next-step crib.

output "swarm_manager_ips" {
  description = "Canonical VMnet11 IPs for the 3 Swarm managers."
  value = {
    swarm_manager_1 = "192.168.70.111"
    swarm_manager_2 = "192.168.70.112"
    swarm_manager_3 = "192.168.70.113"
  }
}

output "swarm_worker_ips" {
  description = "Canonical VMnet11 IPs for the 3 Swarm workers."
  value = {
    swarm_worker_1 = "192.168.70.131"
    swarm_worker_2 = "192.168.70.132"
    swarm_worker_3 = "192.168.70.133"
  }
}

output "swarm_node_vm_paths" {
  description = "Filesystem paths of every running swarm-node clone's .vmx (the ones that were enabled this apply)."
  value = merge(
    length(module.swarm_manager_1) > 0 ? { swarm_manager_1 = module.swarm_manager_1[0].vm_path } : {},
    length(module.swarm_manager_2) > 0 ? { swarm_manager_2 = module.swarm_manager_2[0].vm_path } : {},
    length(module.swarm_manager_3) > 0 ? { swarm_manager_3 = module.swarm_manager_3[0].vm_path } : {},
    length(module.swarm_worker_1) > 0 ? { swarm_worker_1 = module.swarm_worker_1[0].vm_path } : {},
    length(module.swarm_worker_2) > 0 ? { swarm_worker_2 = module.swarm_worker_2[0].vm_path } : {},
    length(module.swarm_worker_3) > 0 ? { swarm_worker_3 = module.swarm_worker_3[0].vm_path } : {},
  )
}

output "next_step" {
  description = "Operator crib -- what to do once apply is green."
  value       = <<-EOT
    Phase 0.E.2.1 closed (if smoke gate is green): swarm cluster live (0.E.1)
    + Vault Agents + Consul gossip encryption.

    Verify the master-plan exit gate (MASTER-PLAN.md line 151):

      ssh nexusadmin@192.168.70.111 'docker node ls'         # 6 nodes
      ssh nexusadmin@192.168.70.111 'consul members'         # 6 members
      ssh nexusadmin@192.168.70.111 'nomad server members'   # 3 servers

    Verify 0.E.2.1 gossip-encrypt is uniform across the cluster:

      ssh nexusadmin@192.168.70.111 'consul keyring -list'
      # Expect: single base64 key with [6/6] in the LAN section.

    Verify per-node Vault Agents are authenticated:

      for ip in 111 112 113 131 132 133; do
        ssh nexusadmin@192.168.70.$ip 'systemctl is-active nexus-vault-agent.service && sudo test -s /var/run/nexus-vault-agent/token && echo "vault-agent OK"'
      done

    Run the full chained smoke gate (39 checks across 0.E.1 + 0.E.2.1):

      pwsh -File scripts/swarm.ps1 smoke

    Iterating?
      pwsh -File scripts/swarm.ps1 cycle              # destroy + apply + smoke
      pwsh -File scripts/swarm.ps1 apply -Vars enable_swarm_init=false               # skip cluster bring-up
      pwsh -File scripts/swarm.ps1 apply -Vars enable_consul_gossip_encryption=false # skip 0.E.2.1
      pwsh -File scripts/swarm.ps1 apply -Vars enable_swarm_manager_3_vault_agent=false # iterate on 5 agents

    Forward direction (subsequent sub-phases):
      0.E.2.2 = Consul TLS (per-node leaf cert from Vault PKI consul-server
                role; tls{} block in consul.hcl; HTTP -> HTTPS hard-cut on 8501)
      0.E.2.3 = Consul ACL system (default_policy=deny; bootstrap on leader;
                management token persisted to Vault KV; per-agent policies +
                tokens via Vault Agent template)
      0.E.3   = Nomad harden (TLS, ACLs, Vault token integration)
      0.E.4   = Portainer EE clustered Swarm service
      0.E.5   = Vault Agent template polish + PKI leaves for Docker/Nomad
                + close-out canon (MASTER-PLAN sub-phases, ADR, vms.yaml,
                CHANGELOG, handbook)
  EOT
}
