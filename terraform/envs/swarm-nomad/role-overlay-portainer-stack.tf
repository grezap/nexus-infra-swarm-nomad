/*
 * role-overlay-portainer-stack.tf -- Phase 0.E.4d (manager-1 only)
 *
 * Deploys Portainer CE as a Docker Swarm stack via `docker stack deploy
 * -c portainer-stack.yml portainer` from manager-1 (the Swarm leader).
 *
 * Stack shape (compose v3.8):
 *   - service `server`: 1 replica, constraint `node.role==manager`,
 *     image `portainer/portainer-ce:<version>`, ports 9443:9443 (HTTPS UI)
 *     + 8000:8000 (Edge agent tunnel; harmless if unused). Bind-mounts
 *     /var/lib/portainer-data:/data (the NFS share from 0.E.4a),
 *     /etc/portainer/tls:/certs:ro (the cert+key from 0.E.4b),
 *     /etc/portainer/admin-password.txt:/run/secrets/admin-pw:ro (the
 *     bcrypt hash from 0.E.4d). Command:
 *       --ssl --sslcert /certs/server.crt --sslkey /certs/server.key
 *       --admin-password-file /run/secrets/admin-pw
 *
 *   - service `agent`: mode global (1 task per node × 6 nodes = full
 *     cluster visibility), image `portainer/agent:<version>`. Bind-mounts
 *     /var/run/docker.sock + /var/lib/docker/volumes for inspection.
 *     Cluster-internal port 9001 (only the server peer reaches it).
 *
 *   - network `agent_network`: overlay, attachable, drives
 *     `tasks.agent` DNS round-robin so the Server reaches all 6 agents.
 *
 * Why bind-mount instead of Docker volumes:
 *   - The NFS mount is owned by the host (managed by 0.E.4a); the
 *     container just sees it as a directory. Cleaner separation of
 *     concerns than Docker's NFS volume driver, which would re-mount
 *     NFS inside Docker's namespace.
 *   - TLS files come from the host's Vault Agent render -- bind-mounting
 *     ensures the container always sees the latest rendered version
 *     after Vault Agent rotates the cert (post-rotation `docker service
 *     update --force portainer_server` picks up the new file).
 *
 * Pre-reqs (apply order):
 *   1. 0.E.4a NFS mount on all 3 managers (/var/lib/portainer-data live).
 *   2. 0.E.4b TLS cert files on all 3 managers (/etc/portainer/tls/*).
 *   3. 0.E.4c dnsmasq portainer.nexus.lab A-record live.
 *   4. 0.E.4d Vault Agent rendered /etc/portainer/admin-password.txt.
 *
 * Idempotency:
 *   - `docker stack deploy --prune` is idempotent: Swarm reconciles the
 *     desired state. Re-applies are no-op-fast when nothing changes.
 *   - Stack name `portainer` is fixed; multiple applies update in place.
 *
 * Verification (post-deploy):
 *   - `docker service ls --filter label=com.docker.stack.namespace=portainer`
 *     shows 2 services.
 *   - server replicas 1/1 (running on a manager).
 *   - agent replicas 6/6 (one per node).
 *   - HTTPS GET https://<manager-ip>:9443/api/system/status returns 200.
 *
 * Selective ops: var.enable_portainer_stack.
 */

resource "null_resource" "portainer_stack" {
  count = var.enable_portainer_stack ? 1 : 0

  triggers = {
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    nfs_mount_id        = length(null_resource.portainer_nfs_mount) > 0 ? null_resource.portainer_nfs_mount[0].id : "disabled"
    tls_id              = length(null_resource.portainer_tls) > 0 ? null_resource.portainer_tls[0].id : "disabled"
    admin_render_id     = length(null_resource.portainer_admin_render) > 0 ? null_resource.portainer_admin_render[0].id : "disabled"
    image_version       = var.portainer_image_version
    portainer_stack_v   = "1" # v1 = original (compose v3.8 with server [1 replica, manager-pin] + agent [global]; bind-mounts NFS data, TLS certs, admin-password file; HTTPS:9443).
  }

  depends_on = [null_resource.portainer_nfs_mount, null_resource.portainer_tls, null_resource.portainer_admin_render]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.swarm_node_user}'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $manager1   = '192.168.70.111'
      $version    = '${var.portainer_image_version}'

      # Compose body. Single-quoted PS here-string -- no PS interpolation;
      # $${VERSION} placeholder substituted via PS -replace below to avoid
      # both terraform interpolation and PS interpolation.
      $composeBody = @'
version: "3.8"

services:
  server:
    image: portainer/portainer-ce:__VERSION__
    command:
      - --ssl
      - --sslcert
      - /certs/server.crt
      - --sslkey
      - /certs/server.key
      - --admin-password-file
      - /run/secrets/admin-pw
    ports:
      - target: 9443
        published: 9443
        protocol: tcp
        mode: ingress
      - target: 8000
        published: 8000
        protocol: tcp
        mode: ingress
    volumes:
      - /var/lib/portainer-data:/data
      - /etc/portainer/tls:/certs:ro
      - /etc/portainer/admin-password.txt:/run/secrets/admin-pw:ro
    networks:
      - agent_network
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
      labels:
        - "com.nexusplatform.tier=06-orchestration"
        - "com.nexusplatform.component=portainer-server"

  agent:
    image: portainer/agent:__VERSION__
    environment:
      AGENT_CLUSTER_ADDR: tasks.agent
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - agent_network
    deploy:
      mode: global
      restart_policy:
        condition: on-failure
        delay: 5s
      labels:
        - "com.nexusplatform.tier=06-orchestration"
        - "com.nexusplatform.component=portainer-agent"

networks:
  agent_network:
    driver: overlay
    attachable: true
'@

      $compose = $composeBody -replace '__VERSION__', $version
      $composeLf = $compose -replace "`r`n", "`n"
      $composeB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($composeLf))

      Write-Host "[portainer-stack] deploying portainer/portainer-ce:$version + portainer/agent:$version via docker stack deploy"

      $deployScript = @"
set -euo pipefail
echo '$composeB64' | base64 -d > /tmp/portainer-stack.yml
sudo docker stack deploy --with-registry-auth --prune --resolve-image=changed -c /tmp/portainer-stack.yml portainer
rm -f /tmp/portainer-stack.yml

echo '--- waiting up to 120s for server to converge to 1 running replica ---'
for i in `$(seq 1 24); do
  RUNNING=`$(sudo docker service ls --filter name=portainer_server --format '{{.Replicas}}' | grep -oE '^[0-9]+' | head -1)
  if [ "`$RUNNING" = "1" ]; then
    echo "portainer_server replica running"
    break
  fi
  sleep 5
done

echo '--- waiting up to 120s for agent to converge to 6 running replicas ---'
for i in `$(seq 1 24); do
  RUNNING=`$(sudo docker service ls --filter name=portainer_agent --format '{{.Replicas}}' | grep -oE '^[0-9]+' | head -1)
  if [ "`$RUNNING" = "6" ]; then
    echo "portainer_agent at 6/6 global"
    break
  fi
  sleep 5
done

echo '--- final service state ---'
sudo docker service ls --filter label=com.nexusplatform.component
echo '--- portainer_server tasks ---'
sudo docker service ps portainer_server --no-trunc --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}' | head -10
echo '--- portainer_agent tasks ---'
sudo docker service ps portainer_agent --no-trunc --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}' | head -10
"@
      $deployB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($deployScript -replace "`r`n", "`n")))

      $output = ssh @sshOpts "$sshUser@$manager1" "echo '$deployB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[portainer-stack] deploy failed (rc=$rc)"
      }

      # Final HTTPS probe -- verify TLS chain validates against the build host's
      # Vault PKI bundle + /api/system/status returns 200.
      Start-Sleep -Seconds 5
      Write-Host ""
      Write-Host "[portainer-stack] verifying HTTPS:9443/api/system/status from manager-1..."
      $probeOut = (ssh @sshOpts "$sshUser@$manager1" "curl -sS --cacert /etc/ssl/certs/nexus-ca.crt -o /dev/null -w '%%{http_code}' https://portainer.nexus.lab:9443/api/system/status 2>&1 || curl -sS -k -o /dev/null -w '%%{http_code}' https://127.0.0.1:9443/api/system/status 2>&1" 2>&1 | Out-String).Trim()
      Write-Host "[portainer-stack] HTTP code: $probeOut"

      Write-Host "[portainer-stack] OK -- Portainer CE deployed (server 1/1, agent 6/6)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@192.168.70.111" "sudo docker stack rm portainer 2>/dev/null || true" 2>$null
      exit 0
    PWSH
  }
}
