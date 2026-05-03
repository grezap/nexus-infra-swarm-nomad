/*
 * role-overlay-swarm-init.tf -- bring up the 3+3 Docker Swarm cluster after
 * the clones land. Two sequential null_resources, top-level so each is
 * independently `-target`-able for iteration:
 *
 *   1. swarm_ready_probe   -- SSH echo + docker.service Running probes on
 *                             all 6 nodes.
 *   2. swarm_init_and_join -- mgr-1 only: `docker swarm init` (advertise on
 *                             VMnet10), capture manager + worker join tokens,
 *                             then SSH to mgr-2/3 + wrk-1/2/3 with the
 *                             right token. Idempotent via
 *                             `docker info --format '{{.Swarm.LocalNodeState}}'`
 *                             probe ('active' = already in a swarm).
 *
 * SSH transit pattern: short single-shot commands; for the join phase we
 * embed the token directly in the remote command. Tokens never persist to
 * Terraform state -- they're pulled from mgr-1 at apply-time and used in
 * the same null_resource. (0.E.5 will write them to Vault KV at
 * `nexus/swarm/join/{manager,worker}` so future operations don't need to
 * re-read them from mgr-1.)
 *
 * Reachability invariant (memory/feedback_lab_host_reachability.md):
 *   - All operations are outbound from build host -> swarm nodes; no
 *     firewall changes; SSH/22 + 2376/2377/4646/8500 reachability from
 *     10.0.70.x stays intact (the nftables ruleset baked in the
 *     swarm-node Packer template allows VMnet11 inbound on those ports).
 */

locals {
  swarm_manager_ips = [
    "192.168.70.111",
    "192.168.70.112",
    "192.168.70.113",
  ]
  swarm_worker_ips = [
    "192.168.70.131",
    "192.168.70.132",
    "192.168.70.133",
  ]
  swarm_all_ips = concat(local.swarm_manager_ips, local.swarm_worker_ips)
  # mgr-1 advertises the swarm leader on its VMnet10 backplane IP. Other
  # nodes join by SSH'ing to mgr-1 and reading the token, then running
  # `docker swarm join --advertise-addr <self-VMnet10> --token <T> 192.168.10.111:2377`.
  swarm_leader_vmnet10 = "192.168.10.111"
}

# ─── 1. Wait for cluster nodes ready (SSH + docker.service active) ────────
resource "null_resource" "swarm_ready_probe" {
  count = var.enable_swarm_cluster && var.enable_swarm_init ? 1 : 0

  triggers = {
    swarm_manager_1_id = length(module.swarm_manager_1) > 0 ? module.swarm_manager_1[0].vm_name : "absent"
    swarm_manager_2_id = length(module.swarm_manager_2) > 0 ? module.swarm_manager_2[0].vm_name : "absent"
    swarm_manager_3_id = length(module.swarm_manager_3) > 0 ? module.swarm_manager_3[0].vm_name : "absent"
    swarm_worker_1_id  = length(module.swarm_worker_1) > 0 ? module.swarm_worker_1[0].vm_name : "absent"
    swarm_worker_2_id  = length(module.swarm_worker_2) > 0 ? module.swarm_worker_2[0].vm_name : "absent"
    swarm_worker_3_id  = length(module.swarm_worker_3) > 0 ? module.swarm_worker_3[0].vm_name : "absent"
    ready_overlay_v    = "1"
  }

  depends_on = [
    module.swarm_manager_1, module.swarm_manager_2, module.swarm_manager_3,
    module.swarm_worker_1, module.swarm_worker_2, module.swarm_worker_3,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${join("','", local.swarm_all_ips)}')
      $user    = '${var.swarm_node_user}'
      $timeout = ${var.swarm_cluster_timeout_minutes}

      foreach ($ip in $ips) {
        Write-Host "[swarm ready] probing SSH on $ip..."
        $bootDeadline = (Get-Date).AddMinutes($timeout)
        $sshReady = $false
        while ((Get-Date) -lt $bootDeadline) {
          $probe = (ssh -o ConnectTimeout=5 -o ConnectionAttempts=1 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo ok" 2>&1 | Out-String).Trim()
          if ($probe -match 'ok') { $sshReady = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $sshReady) {
          throw "[swarm ready] $${ip}: ssh echo probe never succeeded after $timeout min"
        }
        Write-Host "[swarm ready] $${ip}: SSH ready"

        Write-Host "[swarm ready] $${ip}: probing docker.service..."
        $dockerDeadline = (Get-Date).AddMinutes($timeout)
        $dockerReady = $false
        while ((Get-Date) -lt $dockerDeadline) {
          $status = (ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "systemctl is-active docker.service" 2>&1 | Out-String).Trim()
          if ($status -match '^active$') { $dockerReady = $true; break }
          Write-Host "[swarm ready] $${ip}: docker.service status='$status', retrying..."
          Start-Sleep -Seconds 10
        }
        if (-not $dockerReady) {
          throw "[swarm ready] $${ip}: docker.service never became active after $timeout min"
        }
        Write-Host "[swarm ready] $${ip}: docker.service active"
      }

      Write-Host "[swarm ready] all 6 nodes ready -- SSH + docker.service active"
    PWSH
  }
}

# ─── 2. Init swarm on mgr-1 + join the rest ───────────────────────────────
resource "null_resource" "swarm_init_and_join" {
  count = var.enable_swarm_cluster && var.enable_swarm_init ? 1 : 0

  triggers = {
    ready_id       = null_resource.swarm_ready_probe[0].id
    leader_vmnet10 = local.swarm_leader_vmnet10
    init_overlay_v = "1"
  }

  depends_on = [null_resource.swarm_ready_probe]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user           = '${var.swarm_node_user}'
      $leaderIp       = '${local.swarm_manager_ips[0]}'
      $leaderVmnet10  = '${local.swarm_leader_vmnet10}'
      $managerIps     = @('${join("','", slice(local.swarm_manager_ips, 1, length(local.swarm_manager_ips)))}')
      $workerIps      = @('${join("','", local.swarm_worker_ips)}')

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      function Get-SwarmState {
        param([string]$Ip)
        $out = (ssh @sshOpts "$user@$Ip" "docker info --format '{{.Swarm.LocalNodeState}}'" 2>&1 | Out-String).Trim()
        return $out
      }

      # ── Step 1: leader (mgr-1) ──
      $leaderState = Get-SwarmState -Ip $leaderIp
      Write-Host "[swarm init] $${leaderIp}: current swarm state = '$leaderState'"
      if ($leaderState -match 'active') {
        Write-Host "[swarm init] $${leaderIp}: already in a swarm, skipping init"
      } else {
        Write-Host "[swarm init] $${leaderIp}: docker swarm init --advertise-addr $leaderVmnet10"
        $initOut = (ssh @sshOpts "$user@$leaderIp" "docker swarm init --advertise-addr $leaderVmnet10" 2>&1 | Out-String)
        Write-Host $initOut
        if ($LASTEXITCODE -ne 0) { throw "[swarm init] $${leaderIp}: docker swarm init failed (rc=$LASTEXITCODE)" }
      }

      # ── Step 2: capture manager + worker tokens from leader ──
      Write-Host "[swarm init] capturing join tokens from $leaderIp..."
      $managerToken = (ssh @sshOpts "$user@$leaderIp" "docker swarm join-token -q manager" 2>&1 | Out-String).Trim()
      $workerToken  = (ssh @sshOpts "$user@$leaderIp" "docker swarm join-token -q worker"  2>&1 | Out-String).Trim()
      if (-not $managerToken -or $managerToken -notmatch '^SWMTKN-') { throw "[swarm init] failed to capture manager token (got '$managerToken')" }
      if (-not $workerToken  -or $workerToken  -notmatch '^SWMTKN-') { throw "[swarm init] failed to capture worker token  (got '$workerToken')" }
      Write-Host "[swarm init] tokens captured (manager: $($managerToken.Substring(0,16))..., worker: $($workerToken.Substring(0,16))...)"

      # ── Step 3: join mgr-2 + mgr-3 ──
      foreach ($mgrIp in $managerIps) {
        $state = Get-SwarmState -Ip $mgrIp
        if ($state -match 'active') {
          Write-Host "[swarm init] $${mgrIp}: already in a swarm, skipping join"
          continue
        }
        # advertise-addr is the joining node's own VMnet10 IP; map by VMnet11
        # last octet (.112 -> .10.112, .113 -> .10.113).
        $lastOctet  = ($mgrIp -split '\.')[-1]
        $advAddr    = "192.168.10.$lastOctet"
        Write-Host "[swarm init] $${mgrIp}: joining as manager (advertise $advAddr)"
        $joinOut = (ssh @sshOpts "$user@$mgrIp" "docker swarm join --advertise-addr $advAddr --token $managerToken $${leaderVmnet10}:2377" 2>&1 | Out-String)
        Write-Host $joinOut
        if ($LASTEXITCODE -ne 0) { throw "[swarm init] $${mgrIp}: docker swarm join (manager) failed (rc=$LASTEXITCODE)" }
      }

      # ── Step 4: join wrk-1/2/3 ──
      foreach ($wrkIp in $workerIps) {
        $state = Get-SwarmState -Ip $wrkIp
        if ($state -match 'active') {
          Write-Host "[swarm init] $${wrkIp}: already in a swarm, skipping join"
          continue
        }
        $lastOctet  = ($wrkIp -split '\.')[-1]
        $advAddr    = "192.168.10.$lastOctet"
        Write-Host "[swarm init] $${wrkIp}: joining as worker (advertise $advAddr)"
        $joinOut = (ssh @sshOpts "$user@$wrkIp" "docker swarm join --advertise-addr $advAddr --token $workerToken $${leaderVmnet10}:2377" 2>&1 | Out-String)
        Write-Host $joinOut
        if ($LASTEXITCODE -ne 0) { throw "[swarm init] $${wrkIp}: docker swarm join (worker) failed (rc=$LASTEXITCODE)" }
      }

      # ── Step 5: verify quorum from leader ──
      Start-Sleep -Seconds 5
      Write-Host "[swarm init] verifying cluster shape from $leaderIp..."
      $nodeCount = (ssh @sshOpts "$user@$leaderIp" "docker node ls --format '{{.ID}}' | wc -l" 2>&1 | Out-String).Trim()
      Write-Host "[swarm init] docker node ls reports $nodeCount node(s)"
      if ($nodeCount -ne '6') {
        throw "[swarm init] expected 6 nodes, got '$nodeCount' -- cluster bring-up incomplete"
      }
      Write-Host "[swarm init] OK -- 3+3 swarm cluster live (exit gate met)"
    PWSH
  }

  # Destroy-time leave: best-effort `docker swarm leave --force` on every
  # node. Idempotent: ignored on nodes already not in a swarm.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user = 'nexusadmin'
      $ips  = @(
        '192.168.70.111','192.168.70.112','192.168.70.113',
        '192.168.70.131','192.168.70.132','192.168.70.133'
      )
      foreach ($ip in $ips) {
        Write-Host "[swarm destroy] $${ip}: docker swarm leave --force"
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$user@$ip" "docker swarm leave --force" 2>$null
      }
      exit 0
    PWSH
  }
}
