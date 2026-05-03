#!/bin/bash
# swarm-node-firstboot.sh — runs once at first boot per swarm-node clone.
#
# Mirrors the vault-firstboot.sh pattern (nexus-infra-vmware/packer/vault/),
# adapted for the 6-node Swarm cluster. Same NIC discrimination by MAC OUI
# byte 5 (0x00 primary VMnet11, 0x01 secondary VMnet10), same /etc/hosts
# pattern, same hostname renaming, then renders consul.hcl + nomad.hcl
# in server-vs-client mode by hostname role.
#
# Idempotent: marker file at /var/lib/swarm-node-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/swarm-node-firstboot-done
LOG_PREFIX="[swarm-node-firstboot]"

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Discover both NICs by MAC OUI pattern ──────────────────────────────
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX ERROR: no secondary NIC (MAC pattern 00:50:56:*:01:*) found -- swarm requires the VMnet10 backplane" >&2
  ip -br link >&2
  exit 1
fi

# ─── 2. Ensure nic0 == primary, nic1 == secondary ──────────────────────────
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

if [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 3. Wait for nic0 DHCP ─────────────────────────────────────────────────
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  ip -br addr show nic0 >&2 || true
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 4. Map IP -> hostname + VMnet10 IP + cluster role ─────────────────────
case "$VMNET11_IP" in
  192.168.70.111) HOSTNAME=swarm-manager-1; VMNET10_IP=192.168.10.111; ROLE=manager ;;
  192.168.70.112) HOSTNAME=swarm-manager-2; VMNET10_IP=192.168.10.112; ROLE=manager ;;
  192.168.70.113) HOSTNAME=swarm-manager-3; VMNET10_IP=192.168.10.113; ROLE=manager ;;
  192.168.70.131) HOSTNAME=swarm-worker-1;  VMNET10_IP=192.168.10.131; ROLE=worker  ;;
  192.168.70.132) HOSTNAME=swarm-worker-2;  VMNET10_IP=192.168.10.132; ROLE=worker  ;;
  192.168.70.133) HOSTNAME=swarm-worker-3;  VMNET10_IP=192.168.10.133; ROLE=worker  ;;
  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' (expected .111-.113 or .131-.133)" >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME role=$ROLE VMnet10 IP=$VMNET10_IP/24"

# ─── 5. Hostname + /etc/hosts ──────────────────────────────────────────────
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
fi

# Per memory/feedback_smoke_gate_probe_robustness.md: every Linux first-boot
# must write /etc/hosts entry for the new hostname or sudo emits "unable to
# resolve host" stderr noise on every invocation.
HOSTS_LINE="127.0.1.1 $HOSTNAME.nexus.lab $HOSTNAME"
sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
echo "$HOSTS_LINE" >> /etc/hosts
echo "$LOG_PREFIX wrote /etc/hosts entry: $HOSTS_LINE"

# ─── 6. VMnet10 backplane config (.link MAC-match + .network static) ───────
echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

# Per memory/feedback_systemd_link_precedence_multi_nic.md -- rewrite the
# baseline 10-nic0.link to MAC-match the primary NIC instead of the greedy
# OriginalName=en* match. Without this, on every reboot AFTER firstboot
# systemd-udev's lex-order match leaves nic1 stuck on its kernel-default
# name and the static .network rule never applies -> backplane has no IP
# -> Swarm/Consul/Nomad Raft RPC unreachable -> quorum loss on any restart.
if [ -f /etc/systemd/network/10-nic0.link ] && ! grep -q "^MACAddress=$PRIMARY_MAC" /etc/systemd/network/10-nic0.link; then
  echo "$LOG_PREFIX rewriting 10-nic0.link to MAC-match primary"
  cat > /etc/systemd/network/10-nic0.link <<EOF
[Match]
MACAddress=$PRIMARY_MAC

[Link]
Name=nic0
EOF
  udevadm control --reload 2>/dev/null || true
fi

ip link set nic1 up 2>/dev/null || true
if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
  ip addr add "$VMNET10_IP/24" dev nic1 || true
fi
systemctl restart systemd-networkd
sleep 3

# ─── 7. Render Consul + Nomad config from the right template ───────────────
case "$ROLE" in
  manager)
    CONSUL_TPL=/etc/consul.d/consul-server.hcl.tpl
    NOMAD_TPL=/etc/nomad.d/nomad-server.hcl.tpl
    ;;
  worker)
    CONSUL_TPL=/etc/consul.d/consul-client.hcl.tpl
    NOMAD_TPL=/etc/nomad.d/nomad-client.hcl.tpl
    ;;
esac

for tpl in "$CONSUL_TPL" "$NOMAD_TPL"; do
  if [ ! -f "$tpl" ]; then
    echo "$LOG_PREFIX ERROR: $tpl missing -- swarm_node Ansible role didn't install it?" >&2
    exit 1
  fi
done

# Consul retry-join targets all 3 manager VMnet10 IPs. Workers will be
# listed as Consul clients but won't appear in the server quorum.
CONSUL_RETRY_JOIN_LIST='"192.168.10.111", "192.168.10.112", "192.168.10.113"'

CONSUL_DST=/etc/consul.d/consul.hcl
sed -e "s|@HOSTNAME@|$HOSTNAME|g" \
    -e "s|@VMNET11_IP@|$VMNET11_IP|g" \
    -e "s|@VMNET10_IP@|$VMNET10_IP|g" \
    -e "s|@CONSUL_RETRY_JOIN_LIST@|$CONSUL_RETRY_JOIN_LIST|g" \
    "$CONSUL_TPL" > "$CONSUL_DST"
chown root:consul "$CONSUL_DST"
chmod 640 "$CONSUL_DST"
echo "$LOG_PREFIX rendered $CONSUL_DST ($ROLE mode)"

NOMAD_DST=/etc/nomad.d/nomad.hcl
sed -e "s|@HOSTNAME@|$HOSTNAME|g" \
    -e "s|@VMNET11_IP@|$VMNET11_IP|g" \
    -e "s|@VMNET10_IP@|$VMNET10_IP|g" \
    "$NOMAD_TPL" > "$NOMAD_DST"
# Worker nomad needs root to manage cgroups + containerd; manager nomad
# server can run as nomad user. Both modes share /etc/nomad.d/nomad.hcl;
# privilege is decided in the systemd unit (nomad.service template overrides
# User= via /etc/systemd/system/nomad.service.d/role.conf when worker).
if [ "$ROLE" = "worker" ]; then
  mkdir -p /etc/systemd/system/nomad.service.d
  cat > /etc/systemd/system/nomad.service.d/role.conf <<EOF
[Service]
User=root
Group=root
EOF
  echo "$LOG_PREFIX nomad role override: worker -> run as root for cgroup mgmt"
fi
chown root:nomad "$NOMAD_DST"
chmod 640 "$NOMAD_DST"
echo "$LOG_PREFIX rendered $NOMAD_DST ($ROLE mode)"

# ─── 8. Enable + start runtime services ────────────────────────────────────
# CRITICAL: use `systemctl start --no-block` here, NOT `enable --now`.
#
# Why: this script runs INSIDE swarm-node-firstboot.service, whose unit file
# declares `Before=docker.service consul.service nomad.service` (defense-in-
# depth so the daemons can never start before firstboot has rendered their
# configs). `enable --now docker.service` translates to enable + start, and
# the `--now` flag blocks until docker.service reaches "active" state.
# But docker can't become active until firstboot.service reaches "active"
# (Before= constraint), and firstboot can't finish because we're blocked on
# `--now`. Deadlock -- the `start` process spins forever, the firstboot
# service stays "activating" indefinitely, downstream readiness probes
# (terraform null_resource.swarm_ready_probe) time out and the apply fails.
# Diagnosed 2026-05-03 first cycle apply -- 46 min spinning before timeout.
#
# Fix: enable (registers the wanted-by symlink, returns immediately) +
# start --no-block (queues the start request, returns immediately). Once
# this script touches the marker and exits, systemd's oneshot+RemainAfterExit
# reaches "active", the queued starts proceed in dependency order
# (consul before nomad per nomad.service's `After=consul.service`).
systemctl daemon-reload
systemctl enable docker.service consul.service nomad.service
systemctl start --no-block docker.service consul.service nomad.service

# Don't probe is-active here -- the daemons start AFTER this script exits.
# The terraform swarm_ready_probe overlay handles readiness verification.
echo "$LOG_PREFIX docker.service / consul.service / nomad.service queued (will start after firstboot completes)"

# ─── 9. Mark complete ──────────────────────────────────────────────────────
touch "$MARKER"
echo "$LOG_PREFIX done -- $HOSTNAME ready ($ROLE role on VMnet11 $VMNET11_IP / VMnet10 $VMNET10_IP)"
