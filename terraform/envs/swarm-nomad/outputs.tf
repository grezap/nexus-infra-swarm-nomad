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
    Phase 0.E.2.2 closed (if smoke gate is green): mutual TLS for Consul
    internal RPC + Raft, server-only TLS for HTTPS API on port 8501,
    HTTP/8500 hard-cut. Per-node leaf certs from Vault PKI consul-server
    role (90-day TTL); rendered + auto-rotated by per-host Vault Agents.

    Verify HTTPS:8501 reachable from the build host with the Vault PKI bundle:

      $env:CONSUL_HTTP_ADDR="https://192.168.70.111:8501"
      curl --cacert "$env:USERPROFILE\.nexus\vault-ca-bundle.crt" `
           https://192.168.70.111:8501/v1/status/leader
      # ^ note: Windows curl is Schannel; if you hit CERT_TRUST_IS_PARTIAL_CHAIN
      #   use the smoke gate's PowerShell X509Chain probe instead, or run from
      #   any swarm-node with `consul members` (env vars in /etc/profile.d).

    Verify HTTP/8500 hard-cut on every node (no listener):

      for ip in 111 112 113 131 132 133; do
        nc -vz 192.168.70.$ip 8500 2>&1 | grep -E "refused|timed out"
      done

    Verify cluster health over mutual TLS (from any swarm-node, env vars
    auto-loaded by /etc/profile.d/consul-tls.sh in interactive shells):

      ssh nexusadmin@192.168.70.111
      consul members                           # 6 alive
      consul operator raft list-peers          # 3 server peers, 1 leader
      consul keyring -list                     # 1 LAN key, [6/6]

    Verify per-node Vault Agents are still rendering certs:

      for ip in 111 112 113 131 132 133; do
        ssh nexusadmin@192.168.70.$ip 'sudo test -s /etc/consul.d/tls/server.crt && \
          sudo openssl x509 -in /etc/consul.d/tls/server.crt -noout -enddate'
      done

    Run the full chained smoke gate (~70 checks across 0.E.1 + 0.E.2.1 + 0.E.2.2):

      pwsh -File scripts/swarm.ps1 smoke

    Iterating?
      pwsh -File scripts/swarm.ps1 cycle              # destroy + apply + smoke
      pwsh -File scripts/swarm.ps1 apply -Vars enable_consul_tls=false                # keep cluster on plain HTTP/8500 (lab-only)
      pwsh -File scripts/swarm.ps1 apply -Vars enable_consul_gossip_encryption=false  # skip 0.E.2.1
      pwsh -File scripts/swarm.ps1 apply -Vars enable_swarm_init=false                # skip cluster bring-up

    Forward direction (subsequent sub-phases):
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
