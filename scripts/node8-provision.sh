#!/usr/bin/env bash
set -euo pipefail

# HYDRA Node 8 Provisioning
# ==========================
# Run once after OVH delivers the server.
# Configures the node for the HYDRA namespace with dedicated taint.
#
# Prerequisites:
#   - SSH access to the new server (root or sudo user)
#   - K3s token from node-1 (/var/lib/rancher/k3s/server/node-token)
#   - WireGuard config from node-1

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_muso}"
NODE8_PUBLIC_IP="${NODE8_PUBLIC_IP:?Set NODE8_PUBLIC_IP to the server's public IP}"
NODE8_VRACK_IP="${NODE8_VRACK_IP:-10.0.0.8}"
NODE8_USER="${NODE8_USER:-root}"
NODE1_IP="${NODE1_IP:-135.148.169.37}"
NODE1_VRACK_IP="${NODE1_VRACK_IP:-10.0.0.1}"
K3S_VERSION="${K3S_VERSION:-v1.34.5+k3s1}"
WG_PEER_IP="${WG_PEER_IP:-10.8.0.8}"

# Team SSH public keys
AARON_KEY="$(cat "$HOME/.ssh/ovh_muso.pub" 2>/dev/null || echo "")"
SERHII_KEY="${SERHII_SSH_KEY:-}"
IHOR_KEY="${IHOR_SSH_KEY:-}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; exit 1; }

remote() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_PUBLIC_IP" "$@"
}

log "Starting Node 8 provisioning: $NODE8_PUBLIC_IP ($NODE8_VRACK_IP)"

# -------------------------------------------------------------------
# Step 1: Set hostname
# -------------------------------------------------------------------
log "Step 1/8: Setting hostname to ovh-node-8..."
remote "hostnamectl set-hostname ovh-node-8"
remote "echo '127.0.1.1 ovh-node-8' >> /etc/hosts"
log "  Hostname set."

# -------------------------------------------------------------------
# Step 2: Configure vRack NIC
# -------------------------------------------------------------------
log "Step 2/8: Configuring vRack NIC ($NODE8_VRACK_IP)..."

# Detect the vRack NIC (second interface, not the primary)
VRACK_NIC=$(remote "ip -o link show | grep -v 'lo\|veth\|cni\|flannel\|cilium' | awk -F': ' '{print \$2}' | tail -1")
log "  Detected vRack NIC: $VRACK_NIC"

remote bash -s <<VRACK_EOF
cat > /etc/netplan/60-vrack.yaml <<EOF
network:
  version: 2
  ethernets:
    $VRACK_NIC:
      addresses:
        - ${NODE8_VRACK_IP}/24
      mtu: 9000
      routes:
        - to: 10.0.0.0/24
          via: 10.0.0.1
EOF
netplan apply
VRACK_EOF

# Verify vRack connectivity
sleep 3
remote "ping -c 2 -W 3 $NODE1_VRACK_IP" || fail "Cannot reach node-1 via vRack"
log "  vRack configured and node-1 reachable."

# -------------------------------------------------------------------
# Step 3: Install WireGuard client
# -------------------------------------------------------------------
log "Step 3/8: Installing WireGuard..."
remote bash -s <<'WG_INSTALL_EOF'
apt-get update -qq
apt-get install -y -qq wireguard-tools
WG_INSTALL_EOF

# Generate WireGuard keys on node-8
NODE8_PRIVKEY=$(remote "wg genkey")
NODE8_PUBKEY=$(echo "$NODE8_PRIVKEY" | remote "wg pubkey")

# Get node-1's WireGuard public key
NODE1_PUBKEY=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$NODE1_IP" \
  "cat /etc/wireguard/publickey 2>/dev/null || wg show wg0 public-key")

# Configure WireGuard on node-8
remote bash -s <<WG_CONF_EOF
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $NODE8_PRIVKEY
Address = ${WG_PEER_IP}/24
DNS = 10.0.0.1

[Peer]
PublicKey = $NODE1_PUBKEY
AllowedIPs = 10.8.0.0/24
Endpoint = ${NODE1_IP}:51820
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
WG_CONF_EOF

# Add node-8 as a peer on node-1
log "  Adding node-8 as WireGuard peer on node-1..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$NODE1_IP" \
  "wg set wg0 peer $NODE8_PUBKEY allowed-ips ${WG_PEER_IP}/32"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$NODE1_IP" \
  "wg-quick save wg0"

log "  WireGuard configured (${WG_PEER_IP})."

# -------------------------------------------------------------------
# Step 4: Join K3s cluster
# -------------------------------------------------------------------
log "Step 4/8: Joining K3s cluster..."

# Get K3s token from node-1
K3S_TOKEN=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$NODE1_IP" \
  "cat /var/lib/rancher/k3s/server/node-token")

remote bash -s <<K3S_EOF
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_URL="https://${NODE1_VRACK_IP}:6443" \
  K3S_TOKEN="$K3S_TOKEN" \
  INSTALL_K3S_EXEC="agent \
    --node-name ovh-node-8 \
    --node-label dedicated=hydra \
    --node-taint dedicated=hydra:NoSchedule \
    --node-ip ${NODE8_VRACK_IP} \
    --flannel-iface ${VRACK_NIC:-ens3}" \
  sh -
K3S_EOF

# Wait for node to appear
log "  Waiting for node to join cluster..."
for i in $(seq 1 30); do
  NODE_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$NODE1_IP" \
    "kubectl get node ovh-node-8 -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null") || NODE_STATUS=""
  if [[ "$NODE_STATUS" == "Ready" ]]; then
    break
  fi
  sleep 5
done

if [[ "$NODE_STATUS" != "Ready" ]]; then
  fail "Node ovh-node-8 did not become Ready within 150s"
fi
log "  Node ovh-node-8 joined and Ready."

# -------------------------------------------------------------------
# Step 5: Install Longhorn prerequisites
# -------------------------------------------------------------------
log "Step 5/8: Installing Longhorn prerequisites..."
remote bash -s <<'LONGHORN_EOF'
apt-get install -y -qq open-iscsi nfs-common
systemctl enable --now iscsid
LONGHORN_EOF
log "  Longhorn prerequisites installed."

# -------------------------------------------------------------------
# Step 6: Create longhorn-node8 StorageClass
# -------------------------------------------------------------------
log "Step 6/8: Creating longhorn-node8 StorageClass..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$NODE1_IP" bash -s <<'SC_EOF'
kubectl apply -f - <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-node8
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "2880"
  fromBackup: ""
  nodeSelector: "dedicated=hydra"
  diskSelector: "default-disk"
YAML
SC_EOF
log "  StorageClass longhorn-node8 created."

# -------------------------------------------------------------------
# Step 7: Configure SSH keys
# -------------------------------------------------------------------
log "Step 7/8: Configuring SSH keys..."
remote bash -s <<SSH_EOF
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Ensure authorized_keys exists
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Add team keys (idempotent)
$([ -n "$AARON_KEY" ] && echo "grep -qF '$AARON_KEY' /root/.ssh/authorized_keys || echo '$AARON_KEY' >> /root/.ssh/authorized_keys")
$([ -n "$SERHII_KEY" ] && echo "grep -qF '$SERHII_KEY' /root/.ssh/authorized_keys || echo '$SERHII_KEY' >> /root/.ssh/authorized_keys")
$([ -n "$IHOR_KEY" ] && echo "grep -qF '$IHOR_KEY' /root/.ssh/authorized_keys || echo '$IHOR_KEY' >> /root/.ssh/authorized_keys")

# Harden SSH
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload sshd
SSH_EOF
log "  SSH keys configured, password auth disabled."

# -------------------------------------------------------------------
# Step 8: Install monitoring agents
# -------------------------------------------------------------------
log "Step 8/8: Installing monitoring agents..."
remote bash -s <<'MON_EOF'
# Node Exporter
useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true
NODE_EXPORTER_VERSION="1.7.0"
cd /tmp
curl -sfLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter

# Promtail
PROMTAIL_VERSION="2.9.4"
cd /tmp
curl -sfLO "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
apt-get install -y -qq unzip
unzip -o "promtail-linux-amd64.zip"
cp promtail-linux-amd64 /usr/local/bin/promtail
chmod +x /usr/local/bin/promtail

mkdir -p /etc/promtail
cat > /etc/promtail/config.yml <<EOF
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push

scrape_configs:
  - job_name: journal
    journal:
      json: false
      max_age: 12h
      labels:
        job: systemd-journal
        host: ovh-node-8
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'

  - job_name: k3s
    static_configs:
      - targets: [localhost]
        labels:
          job: k3s-agent
          host: ovh-node-8
          __path__: /var/log/syslog
EOF

cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail
After=network.target

[Service]
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now promtail

# Clean up
rm -rf /tmp/node_exporter-* /tmp/promtail-*
MON_EOF
log "  node-exporter and promtail installed and running."

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
log ""
log "============================================"
log "Node 8 provisioning COMPLETE"
log "============================================"
log "  Hostname:    ovh-node-8"
log "  Public IP:   $NODE8_PUBLIC_IP"
log "  vRack IP:    $NODE8_VRACK_IP"
log "  WireGuard:   $WG_PEER_IP"
log "  K3s:         agent (taint: dedicated=hydra:NoSchedule)"
log "  StorageClass: longhorn-node8"
log "  Monitoring:  node-exporter + promtail"
log ""
log "Next steps:"
log "  1. Add node-exporter scrape target to Prometheus config"
log "  2. Deploy HYDRA namespace and workloads"
log "  3. Run: hydra/scripts/deploy.sh"
