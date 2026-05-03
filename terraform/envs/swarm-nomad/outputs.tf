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
    Phase 0.E.1 swarm cluster bring-up complete (if smoke gate is green).

    Verify the exit gate (per MASTER-PLAN.md line 151):

      ssh nexusadmin@192.168.70.111 'docker node ls'
      # Expect: 6 nodes (3 managers Leader/Reachable + 3 workers Active)

      ssh nexusadmin@192.168.70.111 'consul members'
      # Expect: 6 members (3 server + 3 client)

      ssh nexusadmin@192.168.70.111 'nomad server members'
      # Expect: 3 alive servers

    Or run the full smoke gate:

      pwsh -File scripts/swarm.ps1 smoke

    Iterating?
      pwsh -File scripts/swarm.ps1 cycle    # destroy + apply + smoke
      pwsh -File scripts/swarm.ps1 apply -Vars enable_swarm_init=false   # skip cluster bring-up
      pwsh -File scripts/swarm.ps1 apply -Vars enable_swarm_worker_3=false  # bring up 5 of 6

    Forward direction:
      0.E.2 = harden Consul (TLS, ACLs, gossip encryption)
      0.E.3 = harden Nomad (ACLs, TLS, Vault token integration)
      0.E.4 = Portainer EE clustered Swarm service
      0.E.5 = Vault Agents on every node + PKI leaves for Docker/Consul/Nomad TLS
  EOT
}
