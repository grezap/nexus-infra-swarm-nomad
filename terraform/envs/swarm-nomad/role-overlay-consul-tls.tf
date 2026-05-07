/*
 * role-overlay-consul-tls.tf -- Phase 0.E.2.2 -- Consul TLS
 *
 * Issues per-node TLS leaf certs from Vault PKI's `pki_int/roles/consul-server`
 * (created in 0.E.2 setup), enables TLS on Consul (mutual TLS for internal
 * RPC + Raft, server-only TLS for HTTPS API), and HARD-CUTS HTTP -> HTTPS
 * (port 8500 disabled via `ports.http = -1`; HTTPS on 8501).
 *
 * Pre-req: 0.E.2.1 gossip encrypt is applied. Vault Agents on all 6 nodes
 * must be authenticated + rendering templates from Vault. PKI consul-server
 * role + 6 narrow Vault policies (with `pki_int/issue/consul-server`
 * capability) are already in place.
 *
 * How it works (per-node, sequential rolling -- mirrors 0.E.2.1 pattern):
 *   1. Install /usr/local/sbin/consul-tls-split.sh on the node. Vault Agent
 *      will call this after each successful PKI cert render to atomically
 *      split the bundle into {server.crt, server.key, ca.pem}.
 *
 *   2. Drop /etc/vault-agent/20-template-tls.hcl with a `template` stanza
 *      that calls `{{ pkiCert "pki_int/issue/consul-server" ... }}` with
 *      this host's specific common_name + alt_names + ip_sans:
 *
 *        common_name = <hostname>.consul.nexus.lab
 *        alt_names   = <hostname>, <hostname>.nexus.lab,
 *                      server.nexus-lab.consul, localhost
 *        ip_sans     = <vmnet10>, <vmnet11>, 127.0.0.1
 *
 *      `server.nexus-lab.consul` is required for verify_server_hostname=true
 *      (Consul's internal RPC peer-identity check). 90-day TTL inherits
 *      from the PKI role.
 *
 *   3. Restart nexus-vault-agent.service so it picks up the new template
 *      stanza. Wait up to 60s for /etc/consul.d/tls/server.crt to render +
 *      pass openssl x509 sanity check.
 *
 *   4. Drop /etc/consul.d/20-tls.hcl with the TLS config block + `ports {
 *      http = -1, https = 8501 }` (hard-cut HTTP off).
 *
 *      tls.internal_rpc.verify_incoming   = true
 *      tls.internal_rpc.verify_outgoing   = true
 *      tls.internal_rpc.verify_server_hostname = true   # mutual TLS for
 *                                                       # Raft + RPC
 *      tls.https.verify_incoming          = false       # operator API:
 *                                                       # TLS but no
 *                                                       # client cert
 *
 *   5. Drop /etc/profile.d/consul-tls.sh exporting CONSUL_HTTP_ADDR=https
 *      ://localhost:8501 + CONSUL_CACERT=/etc/consul.d/tls/ca.pem so any
 *      interactive `ssh node 'consul members'` session works without
 *      explicit args. Smoke probes set the env vars inline (login shells
 *      do source profile.d/, but ssh user@host 'cmd' non-interactive
 *      sessions do NOT).
 *
 *   6. Live-patch nftables to allow 8501 inbound on nic0 from VMnet11.
 *      The baseline already allows 8500; that rule stays harmless once
 *      Consul stops listening on 8500 (ports.http = -1).
 *
 *   7. systemctl restart consul.service. Initial TLS-enable benefits from
 *      a full restart (Consul reload on first-time TLS config can be
 *      racy; restart is unambiguous). Wait for consul to rejoin + verify
 *      https://localhost:8501/v1/status/leader returns leader IP.
 *
 *   8. Move to next node. Sequential rolling restart preserves cluster
 *      quorum: at any moment 5 of 6 agents are operational, and Raft
 *      can survive 1 of 3 servers transitioning.
 *
 * After all 6 done: cluster-wide verification probe from build host
 * (separate null_resource).
 *
 * Idempotency: the template render is idempotent (Vault Agent caches +
 * skips re-render when the bundle is unchanged). If consul.service is
 * already healthy with TLS, the restart still succeeds.
 *
 * Selective ops: var.enable_consul_tls.
 */

locals {
  # Per-node specs. ip_sans is comma-separated; the Vault Agent template
  # passes them as-is to pkiCert.
  consul_tls_node_specs = [
    { host = "swarm-manager-1", vm_ip = "192.168.70.111", vmnet10 = "192.168.10.111", role = "manager" },
    { host = "swarm-manager-2", vm_ip = "192.168.70.112", vmnet10 = "192.168.10.112", role = "manager" },
    { host = "swarm-manager-3", vm_ip = "192.168.70.113", vmnet10 = "192.168.10.113", role = "manager" },
    { host = "swarm-worker-1", vm_ip = "192.168.70.131", vmnet10 = "192.168.10.131", role = "worker" },
    { host = "swarm-worker-2", vm_ip = "192.168.70.132", vmnet10 = "192.168.10.132", role = "worker" },
    { host = "swarm-worker-3", vm_ip = "192.168.70.133", vmnet10 = "192.168.10.133", role = "worker" },
  ]
}

resource "null_resource" "consul_tls" {
  count = var.enable_consul_tls && var.enable_swarm_vault_agents ? 1 : 0

  triggers = {
    # Re-run on agent install changes (new agent = new node to enroll in TLS)
    swarm_va_ids = sha256(jsonencode([
      for k, v in null_resource.swarm_vault_agent : v.id
    ]))
    # Re-run on gossip-encrypt changes (we depend on it being live)
    gossip_id = length(null_resource.consul_gossip_encrypt) > 0 ? null_resource.consul_gossip_encrypt[0].id : "disabled"
    # PKI role config (allowed_domains, leaf TTL) pulled from security env --
    # captured here so a security-env knob bump re-issues per-node certs.
    pki_role_name = var.vault_pki_consul_role_name
    consul_tls_v  = "7" # v7 (Phase 0.E.4e) = split-script concatenates leaf + intermediate into server.crt so Consul presents the FULL chain on TLS handshake (off-cluster clients with only root in CA bundle were hitting X509ChainStatus.PartialChain; diagnosed via nexus-cli v0.1.x live runs from the build host). ca.pem stays as the intermediate alone -- mTLS between agents unchanged. v6 = (a) systemd drop-in `-http-port=-1` CLI flag override (Consul HCL config-dir merge silently does NOT override the ports.http key from consul.hcl set by firstboot -- it only ADDS new keys; CLI flags trump all config layers so this is the canonical fix), (b) nftables 8501 rule via `nft -f /etc/nftables.conf` (in-place patch /etc/nftables.conf if missing, then atomic ruleset reload -- the v5 `nft add rule` appended AFTER the counter-drop rule, so the 8501 rule was unreachable). v5 = manual split-script invocation at end of stage1 (Vault Agent's pkiCert caches; a restart with an unchanged cert -> no destination write -> no command invocation, so v4's new split-script logic never ran on a node where v3 had already rendered the cert; manual run is idempotent + guarantees per-version outputs land). v4 = /etc/ssl/certs/consul-ca.pem operator copy. v3 = connect off + parallel restart. v2 = grpc_tls=8503. v1 = original.
  }

  depends_on = [null_resource.swarm_vault_agent, null_resource.consul_gossip_encrypt]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.swarm_node_user}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $pkiRole = '${var.vault_pki_consul_role_name}'
      $kvMount = '${var.vault_kv_mount_path}'

      # ─── Per-node specs (sequential apply order: managers first) ────────
      $nodes = @(
%{for spec in local.consul_tls_node_specs~}
        @{ Host = '${spec.host}'; VmIp = '${spec.vm_ip}'; Vmnet10 = '${spec.vmnet10}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      # ─── Common artifacts (same content on every node) ──────────────────

      # consul-tls-split.sh -- post-render command for the Vault Agent
      # template. Reads /etc/consul.d/tls/bundle.pem (one PEM concatenation
      # of cert + key + CA), splits via awk into separate files atomically,
      # sets canonical perms (server.crt 0644 root:consul, server.key 0600
      # root:consul, ca.pem 0644 root:consul), and reloads consul if it's
      # already TLS-enabled (subsequent renews; first apply uses explicit
      # restart later).
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/consul.d/tls/bundle.pem
DEST=/etc/consul.d/tls
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Split bundle into per-PEM-block files. awk increments on each BEGIN line.
awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

# Identify each block by its header.
SERVER_CRT=""
SERVER_KEY=""
CA_PEM=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*)
      SERVER_KEY=$f
      ;;
    *"BEGIN CERTIFICATE"*)
      if [ -z "$SERVER_CRT" ]; then
        SERVER_CRT=$f
      else
        # Subsequent CERT blocks = CA chain. Keep the LAST one (root) or
        # concat -- for a single-intermediate setup, the second is the
        # intermediate CA which is what consul wants.
        CA_PEM=$f
      fi
      ;;
  esac
done

if [ -z "$SERVER_CRT" ] || [ -z "$SERVER_KEY" ] || [ -z "$CA_PEM" ]; then
  echo "[consul-tls-split] ERROR: bundle missing one of cert/key/ca" >&2
  echo "  bundle blocks:" >&2
  ls -la "$TMP" >&2
  exit 1
fi

# v7 (Phase 0.E.4e): concatenate leaf + intermediate into server.crt so the
# Consul HTTPS listener presents the FULL chain on TLS handshake. Without
# this, off-cluster clients (e.g. nexus-cli on the build host) that have
# only the root in their CA bundle hit X509ChainStatus.PartialChain. ca.pem
# stays as the intermediate alone -- internal mTLS between agents still
# verifies via that anchor unchanged.
cat "$SERVER_CRT" "$CA_PEM" > "$TMP/server-fullchain.crt"

install -m 0644 -o root -g consul "$TMP/server-fullchain.crt" "$DEST/server.crt"
install -m 0640 -o root -g consul "$SERVER_KEY"               "$DEST/server.key"
install -m 0644 -o root -g consul "$CA_PEM"                   "$DEST/ca.pem"

# Operator-accessible copy of the CA bundle. /etc/consul.d/ is mode
# 0750 root:consul (set by firstboot's Ansible) -- protects 10-encrypt.hcl
# (gossip key) + future 30-acl.hcl from non-consul users. nexusadmin can't
# traverse it, so consul CLI calls AS nexusadmin can't read the CA.
# Fix: also write a world-readable copy to /etc/ssl/certs/. Operator env
# (/etc/profile.d/consul-tls.sh) + smoke probes use this path.
install -m 0644 -o root -g root "$CA_PEM" /etc/ssl/certs/consul-ca.pem

echo "[consul-tls-split] $(date -u +%FT%TZ) bundle split: server.crt + server.key + ca.pem (+ /etc/ssl/certs/consul-ca.pem for operator)"

# Reload consul iff it's already running with TLS configured (cert rotation
# case). On first-time TLS enable, consul.service hasn't been restarted yet
# and the TLS config block isn't loaded; the overlay's restart step will
# pick up the new certs. systemctl reload exits 0 even if the service is
# stopped, so we guard with is-active.
if systemctl is-active --quiet consul.service; then
  systemctl reload consul.service 2>/dev/null || true
  echo "[consul-tls-split] reload signal sent to consul.service"
fi
'@

      # /etc/consul.d/20-tls.hcl -- TLS config + hard-cut HTTPS only
      $tlsConfig = @'
# 20-tls.hcl -- Phase 0.E.2.2 -- mutual TLS for internal RPC + Raft;
# server-only TLS for HTTPS API. Hard-cuts HTTP off (port 8500 disabled).
# Renders into the consul -config-dir along with consul.hcl + 10-encrypt.hcl;
# Consul merges in lexical order so 20- supersedes any TLS defaults from
# the role-rendered consul.hcl.

tls {
  defaults {
    ca_file   = "/etc/consul.d/tls/ca.pem"
    cert_file = "/etc/consul.d/tls/server.crt"
    key_file  = "/etc/consul.d/tls/server.key"
  }

  internal_rpc {
    verify_incoming        = true
    verify_outgoing        = true
    verify_server_hostname = true
  }

  https {
    # Operator-friendly: TLS encrypts the channel, but no client cert
    # required for HTTPS API calls. Production would layer ACL tokens /
    # reverse-proxy auth on top.
    verify_incoming = false
  }
}

ports {
  http  = -1
  https = 8501

  # Consul 1.20+ split gRPC into TLS / plain listeners. With TLS enabled,
  # ports.grpc = <N> alongside no ports.grpc_tls is a hard error.
  # Disable both since Connect is OFF (below) and we don't use the plain
  # gRPC channel for anything in the lab. Re-enable + define grpc_tls=8503
  # when 0.E.5+ brings up Connect service mesh.
  grpc     = -1
  grpc_tls = -1
}

# DISABLE Connect (overrides firstboot's `connect { enabled = true }`).
# Reason: Connect auto-bootstraps its own CA + per-server Connect identity
# certs (SAN = "server.<dc>.peering.<trust-domain>.consul"). With our
# verify_server_hostname=true on internal_rpc, Consul expects the simpler
# "server.<dc>.consul" SAN -- which our PKI-issued certs DO have. But
# during inter-node Raft RPC, Connect-enabled peers may present their
# Connect-internal cert (with the peering-SAN) instead of our manual cert,
# causing verification failures + cluster split.
#
# Connect / E15 service mesh was always deferred to 0.E.5 per Greg's #8
# decision in 0.E.2 scoping. Disabling here leaves the Connect data in
# Raft dormant -- re-enabling later (with proper PKI integration) is
# non-destructive.
connect {
  enabled = false
}

# Consul's internal "auto-encrypt" is OFF -- we issue per-node certs via
# Vault Agent rather than letting Consul manage its own intermediate.
'@

      # /usr/local/sbin/consul-systemd-http-override.sh -- v6 fix.
      # Consul's HCL config-dir merge silently DOES NOT override the
      # ports.http key set by firstboot's consul.hcl; it only ADDS new
      # keys (https, grpc_tls). So 20-tls.hcl's `ports.http = -1` is
      # ignored at runtime, /v1/agent/self DebugConfig still shows
      # HTTPPort=8500, and HTTP/8500 keeps listening (breaking the
      # hard-cut). CLI flags are highest precedence in Consul's config
      # layering, so we install a systemd drop-in that resets ExecStart
      # and re-sets it with `-http-port=-1` appended. Pulls the original
      # ExecStart from `systemctl cat` so we don't have to assume the
      # binary path (apt's /usr/bin/consul vs manual /usr/local/bin/).
      # Idempotent: bails if the drop-in is already in place.
      $systemdDropinScript = @'
#!/bin/bash
set -euo pipefail
if systemctl cat consul.service 2>/dev/null | grep -q 'http-port=-1'; then
  echo "[consul-http-override] drop-in already in place; nothing to do"
  exit 0
fi
EXEC_LINE=$(systemctl cat consul.service | grep -E '^ExecStart=' | head -1 | sed 's/^ExecStart=//')
if [ -z "$EXEC_LINE" ]; then
  echo "[consul-http-override] ERROR: could not read ExecStart from consul.service" >&2
  exit 1
fi
mkdir -p /etc/systemd/system/consul.service.d
cat > /etc/systemd/system/consul.service.d/tls-ports-override.conf <<EOF
# 0.E.2.2 v6 -- override ports.http via CLI flag (HCL merge ignores the key)
[Service]
ExecStart=
ExecStart=$EXEC_LINE -http-port=-1
EOF
chmod 0644 /etc/systemd/system/consul.service.d/tls-ports-override.conf
systemctl daemon-reload
echo "[consul-http-override] drop-in installed; ExecStart=$EXEC_LINE -http-port=-1"
'@

      # /usr/local/sbin/consul-nft-fix.sh -- v6 fix.
      # nftables rules are evaluated top-to-bottom in the input chain;
      # once a packet matches the `counter ... drop` rule, processing
      # stops. v5 used `nft add rule` which APPENDS at the end of the
      # chain -- so the 8501 rule landed AFTER the drop and was inert.
      # Fix: patch /etc/nftables.conf in place to include 8501 in the
      # existing operator-UI dport set (handles three legacy forms from
      # earlier Packer templates), then `nft -f /etc/nftables.conf` for
      # an atomic kernel ruleset replacement. Bonus: also persistent
      # across reboots (the v5 runtime add was lost on restart).
      $nftFixScript = @'
#!/bin/bash
set -euo pipefail
CONF=/etc/nftables.conf
if grep -qE 'dport \{[^}]*8501[^}]*\}.*accept' "$CONF"; then
  echo "[nft-fix] 8501 already in $CONF; will reload anyway for position fix"
else
  # Three legacy forms shipped by older Packer templates:
  #   tcp dport { 8500, 4646 }
  #   tcp dport { 8500 }
  #   tcp dport 8500 accept   (bare port)
  sed -i -E 's/dport \{ 8500, 4646 \}/dport { 8500, 8501, 4646 }/' "$CONF"
  sed -i -E 's/dport \{ 8500 \}/dport { 8500, 8501 }/' "$CONF"
  sed -i -E 's/(tcp dport) 8500 accept/\1 { 8500, 8501 } accept/' "$CONF"
fi

# Atomic in-kernel ruleset replacement
nft -f "$CONF"

# Sanity probe: 8501 rule must come BEFORE counter-drop in the active chain
H_8501=$(nft -a list chain inet filter input | awk '/dport.*8501.*accept/ {for (i=1;i<=NF;i++) if ($i=="handle") {print $(i+1); exit}}')
H_DROP=$(nft -a list chain inet filter input | awk '/counter packets.*drop/ {for (i=1;i<=NF;i++) if ($i=="handle") {print $(i+1); exit}}')

if [ -z "$H_8501" ]; then
  echo "[nft-fix] ERROR: 8501 rule not found in active chain after reload" >&2
  nft list chain inet filter input >&2
  exit 1
fi
if [ -n "$H_DROP" ] && [ "$H_8501" -ge "$H_DROP" ]; then
  echo "[nft-fix] ERROR: 8501 rule (handle $H_8501) is at/after drop (handle $H_DROP); fix did not work" >&2
  nft -a list chain inet filter input >&2
  exit 1
fi
echo "[nft-fix] OK: 8501 active before drop (8501=handle $H_8501, drop=handle $${H_DROP:-none})"
'@

      # /etc/profile.d/consul-tls.sh -- env var defaults for interactive
      # SSH login shells (NOT non-interactive `ssh user@host cmd`; smoke
      # probes set these inline). Makes operator workflows ergonomic.
      $envProfile = @'
# Consul TLS endpoint defaults for operator login shells.
# Note: CONSUL_CACERT points at /etc/ssl/certs/consul-ca.pem (world-readable
# copy of /etc/consul.d/tls/ca.pem), since /etc/consul.d/ is 0750 root:consul
# and non-consul users can't traverse there. The split script writes both
# locations; consul.service uses /etc/consul.d/tls/ca.pem (private), CLIs
# use /etc/ssl/certs/consul-ca.pem (public).
export CONSUL_HTTP_ADDR=https://127.0.0.1:8501
export CONSUL_CACERT=/etc/ssl/certs/consul-ca.pem
'@

      # ─── Phase 1 (sequential per node, doesn't restart consul): ────────
      # Install split script + drop per-host Vault Agent PKI template +
      # restart vault-agent. Wait for cert files to render. This phase is
      # safe to run sequentially because it only touches vault-agent +
      # /etc/consul.d/tls/ -- consul.service keeps running on plain HTTP
      # until Phase 3.
      foreach ($node in $nodes) {
        $nodeHost = $node.Host
        $vmIp     = $node.VmIp
        $vmnet10  = $node.Vmnet10
        Write-Host ""
        Write-Host "[consul-tls $${nodeHost}] Phase 1 -- cert render"

        $altNames = "$nodeHost,$nodeHost.nexus.lab,server.nexus-lab.consul,localhost"
        $ipSans   = "$vmnet10,$vmIp,127.0.0.1"
        $cn       = "$nodeHost.consul.nexus.lab"

        $vaultAgentTemplate = @"
# 20-template-tls.hcl -- Phase 0.E.2.2 (rendered for $nodeHost)
# Vault Agent template that issues a Consul TLS leaf cert from
# pki_int/roles/$pkiRole and writes a single bundle file. The post-render
# 'command' script splits the bundle into server.crt + server.key + ca.pem.

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "/etc/consul.d/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "consul"
  command         = "/usr/local/sbin/consul-tls-split.sh"
  command_timeout = "30s"
}
"@

        # LF-normalize before encoding (Windows CRLF source -> bash parse errors)
        $splitLf  = $splitScript        -replace "`r`n", "`n"
        $vaLf     = $vaultAgentTemplate -replace "`r`n", "`n"
        $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($splitLf))
        $vaB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($vaLf))

        $stage1 = @"
set -euo pipefail
sudo mkdir -p /etc/consul.d/tls
sudo chown root:consul /etc/consul.d/tls
sudo chmod 0750 /etc/consul.d/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/consul-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/consul-tls-split.sh
sudo chmod 0755 /usr/local/sbin/consul-tls-split.sh

echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/20-template-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/20-template-tls.hcl
sudo chmod 0644 /etc/vault-agent/20-template-tls.hcl

sudo systemctl restart nexus-vault-agent.service

# Wait for bundle.pem to materialize (Vault Agent renders templates a few
# seconds after startup). Once present, run the split script manually --
# DON'T rely on Vault Agent's command-on-render trigger because pkiCert
# results are CACHED (so a vault-agent restart with an unchanged cert doesn't
# trigger the destination write -> no command invocation -> the new split
# script's logic never runs). Manual invocation is idempotent + guarantees
# the script-versioned outputs (e.g. /etc/ssl/certs/consul-ca.pem in v4)
# land regardless of cache state.
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s /etc/consul.d/tls/bundle.pem && break
  sleep 2
done
if ! sudo test -s /etc/consul.d/tls/bundle.pem; then
  echo "[stage1] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/consul-tls-split.sh
"@
        $stage1B64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stage1))
        $stage1Out = ssh @sshOpts "$sshUser@$vmIp" "echo '$stage1B64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stage1Out.Trim()
          throw "[consul-tls $${nodeHost}] phase1 (cert render) failed (rc=$LASTEXITCODE)"
        }

        # Wait for cert + verify CN
        $deadline = (Get-Date).AddSeconds(60)
        $rendered = $false
        while ((Get-Date) -lt $deadline) {
          $check = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /etc/consul.d/tls/server.crt && sudo test -s /etc/consul.d/tls/server.key && sudo test -s /etc/consul.d/tls/ca.pem && sudo openssl x509 -in /etc/consul.d/tls/server.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
          if ($check -match 'OK') { $rendered = $true; break }
          Start-Sleep -Seconds 3
        }
        if (-not $rendered) {
          $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
          Write-Host $journal
          throw "[consul-tls $${nodeHost}] cert files not rendered (CN=$cn) within 60s"
        }
        Write-Host "[consul-tls $${nodeHost}] cert rendered (CN=$cn)"
      }

      Write-Host ""
      Write-Host "[consul-tls] Phase 1 complete -- all 6 nodes have cert files."
      Write-Host "[consul-tls] Phase 2 -- dropping TLS config + env profile + nftables on all 6 (parallel, no restart yet)..."

      # ─── Phase 2 (parallel, no consul restart): ─────────────────────────
      # Drop /etc/consul.d/20-tls.hcl + /etc/profile.d/consul-tls.sh +
      # nftables 8501 rule on all 6 nodes simultaneously. Consul keeps
      # running on plain HTTP -- the new config file isn't loaded until
      # Phase 3 restart. This split lets us minimize the cluster outage
      # window in Phase 3.
      # Normalize all PS-heredoc payloads to LF-only before base64. Source
      # files on the build host are CRLF (Windows), and PS @'..'@ preserves
      # source line endings -- which leaks into the decoded script on the
      # remote and breaks bash parsing in subtle ways (e.g. `sudo bash\r`
      # decoded as a command name with trailing CR -> "command not found").
      $tlsConfigLf       = $tlsConfig           -replace "`r`n", "`n"
      $envProfileLf      = $envProfile          -replace "`r`n", "`n"
      $systemdDropinLf   = $systemdDropinScript -replace "`r`n", "`n"
      $nftFixLf          = $nftFixScript        -replace "`r`n", "`n"

      $tlsConfigB64     = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($tlsConfigLf))
      $envProfileB64    = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($envProfileLf))
      $systemdDropinB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($systemdDropinLf))
      $nftFixB64        = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($nftFixLf))

      # Stage2 grew in v6 (4 nested base64 blobs vs v5's 2), and the previous
      # `echo 'B64' | base64 -d | bash` outer-command pattern started failing
      # under -Parallel runspaces with "bash: -c: line 1: unexpected EOF while
      # looking for matching '". Cause: ssh.exe arg/quoting handling on Windows
      # is fragile when forwarding ~6KB single-quoted strings via -Parallel.
      # Fix: pipe the plaintext bash script to ssh via stdin + run with
      # `bash -s`. No long argv, no embedded quoting, no command-length cliff.
      # Line endings normalized to LF so the remote bash doesn't choke on CRLF.
      $stage2 = (@"
set -euo pipefail
echo '$tlsConfigB64' | base64 -d | sudo tee /etc/consul.d/20-tls.hcl > /dev/null
sudo chown root:consul /etc/consul.d/20-tls.hcl
sudo chmod 0640 /etc/consul.d/20-tls.hcl

echo '$envProfileB64' | base64 -d | sudo tee /etc/profile.d/consul-tls.sh > /dev/null
sudo chown root:root /etc/profile.d/consul-tls.sh
sudo chmod 0644 /etc/profile.d/consul-tls.sh

# v6: install systemd drop-in to override ports.http via CLI flag.
# Must land BEFORE Phase 3 restart so the new ExecStart is used.
# Absolute /bin/bash since sudo's secure_path may not include `bash`.
echo '$systemdDropinB64' | base64 -d | sudo /bin/bash

# v6: fix nftables rule position. Reloads /etc/nftables.conf atomically;
# if 8501 missing from baseline (older Packer template), patches first.
echo '$nftFixB64' | base64 -d | sudo /bin/bash
"@) -replace "`r`n", "`n"

      # Parallel SSH fan-out via ForEach-Object -Parallel (PS7+).
      $phase2Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $stage2 = $using:stage2
        # Pipe the plaintext script to ssh's stdin; remote bash reads via -s.
        # `tr -d '\r'` strips any CR bytes that pwsh's Windows-side stdout
        # writer injects when piping to ssh.exe (we LF-normalize $stage2 in
        # memory but the pipe-to-ssh.exe path can still re-introduce CRs in
        # text mode -- bash then sees `sudo /bin/bash\r` as the command and
        # errors with "command not found").
        $out = $stage2 | ssh @sshOpts "$sshUser@$($node.VmIp)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] phase2 failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }

      if ($phase2Errors.Count -gt 0) {
        $phase2Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[consul-tls] phase2 (TLS config drop) failed on $($phase2Errors.Count) node(s)"
      }
      Write-Host "[consul-tls] Phase 2 complete -- TLS config staged on all 6 nodes."

      Write-Host ""
      Write-Host "[consul-tls] Phase 3 -- big-bang restart of consul.service on all 6 (parallel)..."
      Write-Host "[consul-tls] (~10-30s cluster outage; all nodes converge with TLS simultaneously)"

      # ─── Phase 3 (parallel, big-bang restart): ──────────────────────────
      # systemctl restart consul.service on all 6 simultaneously. This
      # avoids the chicken-and-egg of sequential rolling -- if some nodes
      # had TLS while others didn't, RPC handshakes would fail in both
      # directions (verify_outgoing rejects plaintext peers, verify_incoming
      # rejects plaintext callers). Parallel restart means all 6 come back
      # up with TLS within seconds of each other; cluster reconverges.
      $phase3Errors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $out = ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo systemctl restart consul.service" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          return "[$($node.Host)] phase3 restart failed (rc=$LASTEXITCODE): $($out.Trim())"
        }
        return $null
      } | Where-Object { $_ -ne $null }

      if ($phase3Errors.Count -gt 0) {
        $phase3Errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[consul-tls] phase3 (consul restart) failed on $($phase3Errors.Count) node(s)"
      }
      Write-Host "[consul-tls] Phase 3 complete -- restart commands issued; waiting for cluster to converge..."

      # Wait per-node for HTTPS:8501 to be reachable (parallel polling).
      $phase3WaitErrors = $nodes | ForEach-Object -ThrottleLimit 6 -Parallel {
        $node = $_
        $sshUser = $using:sshUser
        $sshOpts = $using:sshOpts
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$sshUser@$($node.VmIp)" "systemctl is-active consul.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            $probe = (ssh @sshOpts "$sshUser@$($node.VmIp)" "curl -sS --cacert /etc/ssl/certs/consul-ca.pem -o /dev/null -w '%%{http_code}' https://127.0.0.1:8501/v1/status/leader 2>&1" 2>&1 | Out-String).Trim()
            if ($probe -match '^200$') { return $null }
          }
          Start-Sleep -Seconds 3
        }
        $journal = (ssh @sshOpts "$sshUser@$($node.VmIp)" "sudo journalctl -u consul.service --no-pager -n 30" 2>&1 | Out-String)
        return "[$($node.Host)] consul HTTPS:8501 not ready within 120s; journal:`n$journal"
      } | Where-Object { $_ -ne $null }

      if ($phase3WaitErrors.Count -gt 0) {
        $phase3WaitErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "[consul-tls] phase3 wait (HTTPS:8501 ready) failed on $($phase3WaitErrors.Count) node(s)"
      }
      Write-Host "[consul-tls] Phase 3 complete -- HTTPS:8501 active on all 6 nodes."

      Write-Host ""
      Write-Host "[consul-tls] all 6 nodes TLS-enabled. Verifying cluster shape over TLS..."
      Start-Sleep -Seconds 10

      # Cluster-wide verification from leader's perspective. Use env vars
      # inline since /etc/profile.d/ doesn't load in non-interactive ssh.
      $leaderIp = '192.168.70.111'
      $envPrefix = "CONSUL_HTTP_ADDR=https://localhost:8501 CONSUL_CACERT=/etc/ssl/certs/consul-ca.pem"

      $members = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix consul members 2>&1 | grep -c alive" 2>&1 | Out-String).Trim()
      if ($members -ne '6') {
        throw "[consul-tls] cluster not converged: expected 6 alive members over TLS, got '$members'"
      }
      Write-Host "[consul-tls] consul members over HTTPS reports 6 alive"

      $rpcPeers = (ssh @sshOpts "$sshUser@$leaderIp" "$envPrefix consul operator raft list-peers 2>&1 | grep -c '192.168.10'" 2>&1 | Out-String).Trim()
      if ($rpcPeers -ne '3') {
        throw "[consul-tls] raft mTLS not healthy: expected 3 server peers, got '$rpcPeers'"
      }
      Write-Host "[consul-tls] consul raft list-peers over HTTPS + mTLS reports 3 server peers"

      Write-Host "[consul-tls] OK -- TLS enabled across all 6 agents (mutual TLS for RPC + HTTPS API on 8501)"
    PWSH
  }

  # Destroy: best-effort tear down. Removes TLS config + cert files +
  # restarts consul (falls back to plain HTTP). Operator must also
  # destroy the nftables 8501 rule manually if desired (we leave it; the
  # rule is harmless in the absence of a listener).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $ips = @('192.168.70.111','192.168.70.112','192.168.70.113','192.168.70.131','192.168.70.132','192.168.70.133')
      foreach ($ip in $ips) {
        Write-Host "[consul-tls destroy] $${ip}: removing TLS config + cert files + systemd drop-in + restart consul"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/consul.d/20-tls.hcl /etc/profile.d/consul-tls.sh /etc/vault-agent/20-template-tls.hcl /etc/consul.d/tls/server.crt /etc/consul.d/tls/server.key /etc/consul.d/tls/ca.pem /etc/consul.d/tls/bundle.pem /etc/ssl/certs/consul-ca.pem /etc/systemd/system/consul.service.d/tls-ports-override.conf; sudo systemctl daemon-reload; sudo systemctl restart nexus-vault-agent.service consul.service" 2>$null
      }
      exit 0
    PWSH
  }
}
