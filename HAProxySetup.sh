#!/bin/bash

set -e

# Function for backing up a file
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        sudo cp "$file" "$file.bak_$(date +%F_%T)"
        echo "Backup for $file created."
    fi
}

# Use the function for needed files
# backup_file "/etc/ssh/sshd_config"
# backup_file "/opt/haproxy/docker-compose.yml"
# backup_file "/opt/haproxy/haproxy.cfg"



# --- Check if running as root ---
#if [[ "$EUID" -ne 0 ]]; then
#    echo "This script must be run as root. Please use sudo or run as the root user."
#    exit 1
#fi

# --- Check that the system is Ubuntu ---
if [[ ! -f /etc/os-release ]]; then
    echo "Could not determine the operating system type. This script is supported only on Ubuntu."
    exit 1
fi

. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    echo "This script is supported only on Ubuntu. Detected OS: $ID"
    exit 1
fi

# --- Check that the system is up to date ---
echo "Checking for system updates..."
read -p "Would you like to update the system with 'sudo apt-get update && sudo apt-get upgrade -y'? (Recommended!) [y/N]: " UPGRADE_CONFIRM
if [[ "$UPGRADE_CONFIRM" =~ ^[yY]$ ]]; then
    sudo apt-get update
    sudo apt-get upgrade -y
fi

echo "=== HAProxy server installation ==="

# --- 1. Create a user with sudo privileges ---
read -p "Enter the name of the new user: " NEWUSER
echo

# Create the user if it does not exist
if id "$NEWUSER" &>/dev/null; then
    echo "User $NEWUSER already exists."
else
    sudo adduser --disabled-password --gecos "" "$NEWUSER"
    echo "Now set the password for user $NEWUSER:"
    sudo passwd "$NEWUSER"
    sudo usermod -aG sudo "$NEWUSER"
    echo "User $NEWUSER created and added to the sudo group."
fi

# --- 2. Configure SSH ---
backup_file "/etc/ssh/sshd_config"
read -p "Enter new SSH port (default is 2222): " SSHPORT
SSHPORT=${SSHPORT:-2222}

sudo sed -i "/^#\?Port /c\Port $SSHPORT" /etc/ssh/sshd_config
sudo sed -i "/^#\?PermitRootLogin /c\PermitRootLogin no" /etc/ssh/sshd_config

echo "SSH configured: port $SSHPORT, root login disabled."
sudo systemctl restart ssh

# --- 3. Install Docker and Docker Compose and mc ---
echo "=== Installing Docker and Docker Compose ==="
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release mc

# Add Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo \"\${UBUNTU_CODENAME:-\$VERSION_CODENAME}\") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-compose-plugin docker-ce docker-ce-cli containerd.io

sudo systemctl enable docker
sudo systemctl start docker

echo "Docker and Docker Compose installed."

# --- 4. Configure HAProxy ---
backup_file "/opt/haproxy/docker-compose.yml"
backup_file "/opt/haproxy/haproxy.cfg"

echo "=== Configuring HAProxy ==="
sudo mkdir -p /opt/haproxy
cd /opt/haproxy

# Request the main remote server address for proxying
echo "Enter the main address (or IP) of the remote server for proxying:"
read -p "Default remote server: " DEFAULT_REMOTE_ADDR

FRONTENDS=()
BACKENDS=()

while true; do
    echo "Adding a new forwarding rule:"
    read -p "  Local port (e.g., 443): " LOCAL_PORT

    BACKEND_SERVERS=()
    while true; do
        read -p "  Remote server address (Enter for $DEFAULT_REMOTE_ADDR): " REMOTE_ADDR
        REMOTE_ADDR=${REMOTE_ADDR:-$DEFAULT_REMOTE_ADDR}
        read -p "  Remote server port (e.g., 443): " REMOTE_PORT
        BACKEND_SERVERS+=("$REMOTE_ADDR:$REMOTE_PORT")
        read -p "  Add another server to this backend for roundrobin load balancing? (y/n): " ADD_MORE
        [[ "$ADD_MORE" =~ ^[yY]$ ]] || break
    done

    FRONTENDS+=("$LOCAL_PORT")
    BACKENDS+=("$(IFS=','; echo "${BACKEND_SERVERS[*]}")")

    read -p "Add another rule? (y/n): " CONTINUE
    [[ "$CONTINUE" =~ ^[yY]$ ]] || break
done

# --- Set up HAProxy stats page credentials ---
echo "Configure HAProxy statistics web interface:"
read -p "Enter username for stats page: " STATS_USER
read -s -p "Enter password for stats page: " STATS_PASS
echo

# Create docker-compose.yml with logging section
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  haproxy:
    image: haproxy:2.9
    container_name: haproxy
    restart: always
    network_mode: host
    user: root
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
EOF

# Create haproxy.cfg
cat <<EOF > haproxy.cfg
global
    log stdout format raw local0
    maxconn 1000

defaults
    log     global
    mode    tcp
    option  dontlognull
    timeout connect 10s
    timeout client  1m
    timeout server  1m
EOF

# Add all configured forwarding rules
for i in "${!FRONTENDS[@]}"; do
    LOCAL_PORT="${FRONTENDS[$i]}"
    IFS=',' read -ra SERVERS <<< "${BACKENDS[$i]}"

    echo "" >> haproxy.cfg
    echo "frontend frontend_$LOCAL_PORT" >> haproxy.cfg
    echo "    bind *:$LOCAL_PORT" >> haproxy.cfg
    echo "    default_backend backend_$LOCAL_PORT" >> haproxy.cfg

    echo "" >> haproxy.cfg
    echo "backend backend_$LOCAL_PORT" >> haproxy.cfg
    echo "    balance roundrobin" >> haproxy.cfg
    for j in "${!SERVERS[@]}"; do
        echo "    server srv$((j+1)) ${SERVERS[$j]} check" >> haproxy.cfg
    done
done

# Add HAProxy stats section
cat <<EOF >> haproxy.cfg

listen stats
    bind *:9000
    stats enable
    stats uri /
    stats refresh 5s
    stats auth $STATS_USER:$STATS_PASS

EOF

echo "HAProxy configuration file created."

# --- 5. Launch HAProxy ---
echo "=== Starting HAProxy ==="
sudo docker compose up -d

echo "========================================="
echo "Installation completed!"
echo "HAProxy statistics: http://<server-ip>:9000/"
echo "Login: $STATS_USER"
echo "Password: $STATS_PASS"
echo "SSH access: ssh $NEWUSER@<server-ip> -p $SSHPORT"
echo "========================================="
