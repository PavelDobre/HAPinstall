#!/bin/bash
set -e
set -o pipefail

# ===============================
# Validation Helpers
# ===============================
is_valid_ipv4() {
    local ip="$1"
    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        # strip leading zeros via base 10 and check range 0..255
        if ! [[ $o =~ ^[0-9]+$ ]]; then return 1; fi
        if (( 10#$o < 0 || 10#$o > 255 )); then return 1; fi
    done
    return 0
}

is_valid_hostname() {
    local h="$1"
    # RFC 1123 hostname pattern (basic)
    [[ $h =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$ ]]
}

is_valid_host() {
    local h="$1"
    if [[ $h =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        is_valid_ipv4 "$h"
        return $?
    fi
    is_valid_hostname "$h"
}

prompt_for_host() {
    local __varname="$1"; shift
    local prompt="$1"; shift
    local default="${1:-}"
    local input
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$prompt" input
            input=${input:-$default}
        else
            read -rp "$prompt" input
        fi
        if is_valid_host "$input"; then
            printf -v "$__varname" '%s' "$input"
            break
        else
            echo "Invalid address. Enter IPv4 (e.g., 1.2.3.4) or hostname."
        fi
    done
}

prompt_for_port() {
    local __varname="$1"; shift
    local prompt="$1"; shift
    local default="${1:-}"
    local input
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$prompt" input
            input=${input:-$default}
        else
            read -rp "$prompt" input
        fi
        if [[ $input =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
            printf -v "$__varname" '%s' "$input"
            break
        else
            echo "Invalid port. Enter a number 1-65535."
        fi
    done
}

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        sudo cp "$file" "$file.bak_$(date +%F_%T)"
        echo "Backup created for $file."
    fi
}

# ===============================
# Main Menu Function
# ===============================
main_menu() {
    while true; do
        clear
        echo " "
        echo "==== HAProxy tcp-mode ===="
        echo " "
        echo "==== Main Menu ===="
        echo "1) New HAProxy installation"
        echo "2) Edit existing HAProxy configuration"
        echo "3) SSH user and port Configuration"
        echo "4) Stop HAProxy"
        echo "5) Start HAProxy"
        echo "6) Show current config"
        echo "7) Exit"
        echo " "
        echo "=================="
        read -rp "Enter your choice: " choice

        case $choice in
            1) submenu1 ;;
            2) submenu2 ;;
            3) submenu3 ;;
            4) submenu8 ;;
            5) submenu9 ;;
            6) submenu4 ;;
            7) exit 0   ;;
            *) echo "Invalid choice. Press Enter to try again."
               read
               ;;
        esac
    done
}

# ===============================
# New HAProxy installation
# ===============================
submenu1() {
    clear
    echo " "
    echo "Checking for system updates..."
    read -rp "Update the system with 'sudo apt-get update && sudo apt-get upgrade -y'? (Recommended) [y/N]: " UPGRADE_CONFIRM
        if [[ "$UPGRADE_CONFIRM" =~ ^[yY]$ ]]; then
            sudo rm -f /etc/apt/sources.list.d/docker.list
            sudo apt-get update
            sudo apt-get upgrade -y
        fi
    clear
    echo " "
    echo "=== HAProxy server installation ==="
    echo "Installing Docker and Docker Compose..."
    sudo apt-get install -y ca-certificates curl gnupg lsb-release mc
    sudo install -m 0755 -d /etc/apt/keyrings
    
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    
    UBUNTU_CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
    
   echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    sudo systemctl enable docker
    sudo systemctl start docker
clear
    echo "Docker installed successfully."
    echo " "
    echo "=== HAProxy server configuration ==="
    
    backup_file "$DOCKER_COMPOSE_FILE"
backup_file "$CONFIG_FILE"

sudo mkdir -p /opt/haproxy
cd /opt/haproxy
echo " "
echo "Enter the default remote backend address:"
prompt_for_host DEFAULT_REMOTE_ADDR "Default backend address: "

FRONTENDS=()
BACKENDS=()

    while true; do
        echo "Adding a new forwarding rule:"
        prompt_for_port LOCAL_PORT "  Local port (e.g., 443): "

    BACKEND_SERVERS=()
    while true; do
        prompt_for_host REMOTE_ADDR "  Remote server address (default: $DEFAULT_REMOTE_ADDR): " "$DEFAULT_REMOTE_ADDR"
        prompt_for_port REMOTE_PORT "  Remote server port (e.g., 443): "
        BACKEND_SERVERS+=("${REMOTE_ADDR}:${REMOTE_PORT}")
        read -rp "  Add another backend server? (y/n): " ADD_MORE
        [[ "$ADD_MORE" =~ ^[yY]$ ]] || break
    done

    FRONTENDS+=("$LOCAL_PORT")
    BACKENDS+=("$(IFS=','; echo "${BACKEND_SERVERS[*]}")")

    read -rp "Add another rule? (y/n): " CONTINUE
    [[ "$CONTINUE" =~ ^[yY]$ ]] || break
    done
    # Configure HAProxy stats credentials
echo "Configure HAProxy statistics page:"
read -rp "Stats username: " STATS_USER
read -rs -p "Stats password: " STATS_PASS
echo

echo "Creating docker-compose.yml..."
cat <<EOF > "$DOCKER_COMPOSE_FILE"
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

# Create haproxy.cfg from scratch
cat <<EOF > "$CONFIG_FILE"
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

# Add frontend/backend rules
for i in "${!FRONTENDS[@]}"; do
    LOCAL_PORT="${FRONTENDS[$i]}"
    IFS=',' read -ra SERVERS <<< "${BACKENDS[$i]}"

    echo "" >> "$CONFIG_FILE"
    echo "frontend frontend_${LOCAL_PORT}" >> "$CONFIG_FILE"
    echo "    bind *:${LOCAL_PORT}" >> "$CONFIG_FILE"
    echo "    default_backend backend_${LOCAL_PORT}" >> "$CONFIG_FILE"

    echo "" >> "$CONFIG_FILE"
    echo "backend backend_${LOCAL_PORT}" >> "$CONFIG_FILE"
    echo "    balance roundrobin" >> "$CONFIG_FILE"
    for j in "${!SERVERS[@]}"; do
        echo "    server srv$((j+1)) ${SERVERS[$j]} check" >> "$CONFIG_FILE"
    done
done

cat <<EOF >> "$CONFIG_FILE"

listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
    stats auth $STATS_USER:$STATS_PASS
EOF
clear
echo "HAProxy configuration file created successfully."
echo "Starting HAProxy..."
sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
HOST_IP=$(hostname -I | awk '{print $1}')
echo "========================================="
echo "Installation completed!"
echo "HAProxy stats: http://$HOST_IP:9000/stats"
echo "Stats login: $STATS_USER"
echo "Stats password: $STATS_PASS"
echo "========================================="
echo " = = Don't forget to change SSH port and add SSH user = ="
echo " "
        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
}

# ===============================
# Edit existing HAProxy conf
# ===============================
submenu2() {
 if [ ! -f "$CONFIG_FILE" ]; then
            echo "Configuration file not found. Cannot edit."
            exit 1
        fi

        while true; do
            echo "Current HAProxy rules:"
            RULE_NUMBER=1
            RULE_LIST=()

            for FRONTEND_PORT in $(grep -E '^frontend frontend_[0-9]+' "$CONFIG_FILE" | sed -E 's/^frontend frontend_([0-9]+).*/\1/'); do
                BACKEND="backend_${FRONTEND_PORT}"
                BACKEND_SERVERS=$(awk "/backend $BACKEND/,/^$/" "$CONFIG_FILE" | grep 'server ' | awk '{print $3}')
                echo "[$RULE_NUMBER] Frontend port: $FRONTEND_PORT -> Backends: $BACKEND_SERVERS"
                RULE_LIST+=("$FRONTEND_PORT")
                RULE_NUMBER=$((RULE_NUMBER+1))
            done

            echo "Choose an action:"
            echo "A) Add new rule"
            echo "E) Edit existing rule"
            echo "D) Delete rule"
            echo "X) Exit without changes"
            read -rp "Your choice (A/E/D/X): " RULE_ACTION

            case $RULE_ACTION in
                A|a)
                    while true; do
                    clear
                        echo "Adding a new rule:"
                        prompt_for_port LOCAL_PORT "  Local port (e.g., 443): "

                        BACKEND_SERVERS=()
                        while true; do
                            prompt_for_host REMOTE_ADDR "  Remote server address: "
                            prompt_for_port REMOTE_PORT "  Remote server port: "
                            BACKEND_SERVERS+=("${REMOTE_ADDR}:${REMOTE_PORT}")
                            read -rp "  Add another backend server? (y/n): " ADD_MORE
                            [[ "$ADD_MORE" =~ ^[yY]$ ]] || break
                        done

                        echo "Adding new frontend/backend to haproxy.cfg"
                        {
                            echo ""
                            echo "frontend frontend_${LOCAL_PORT}"
                            echo "    bind *:${LOCAL_PORT}"
                            echo "    default_backend backend_${LOCAL_PORT}"
                            echo ""
                            echo "backend backend_${LOCAL_PORT}"
                            echo "    balance roundrobin"
                            for i in "${!BACKEND_SERVERS[@]}"; do
                                echo "    server srv$((i+1)) ${BACKEND_SERVERS[$i]} check"
                            done
                        } | sudo tee -a "$CONFIG_FILE" > /dev/null

                        echo "Rule added successfully."
                        read -rp "Add another rule? (y/n): " CONTINUE_ADD
                        [[ "$CONTINUE_ADD" =~ ^[yY]$ ]] || break
                    done
                    ;;

                E|e)
                    while true; do
                    clear
                    echo " "
                        echo "Editing an existing rule"
                        echo "Current HAProxy rules:"
            RULE_NUMBER=1
            RULE_LIST=()

            for FRONTEND_PORT in $(grep -E '^frontend frontend_[0-9]+' "$CONFIG_FILE" | sed -E 's/^frontend frontend_([0-9]+).*/\1/'); do
                BACKEND="backend_${FRONTEND_PORT}"
                BACKEND_SERVERS=$(awk "/backend $BACKEND/,/^$/" "$CONFIG_FILE" | grep 'server ' | awk '{print $3}')
                echo "[$RULE_NUMBER] Frontend port: $FRONTEND_PORT -> Backends: $BACKEND_SERVERS"
                RULE_LIST+=("$FRONTEND_PORT")
                RULE_NUMBER=$((RULE_NUMBER+1))
            done
                        if (( ${#RULE_LIST[@]} == 0 )); then
                            echo "No rules available to edit."
                            read -rp "Press Enter to return " _
                            break
                        fi
                        while true; do
                            read -rp "Enter the rule number to edit: " EDIT_NUM
                            if [[ $EDIT_NUM =~ ^[0-9]+$ ]]; then
                                RULE_COUNT=${#RULE_LIST[@]}
                                if (( EDIT_NUM >= 1 && EDIT_NUM <= RULE_COUNT )); then
                                    break
                                fi
                            fi
                            echo "Invalid selection. Enter a number between 1 and ${#RULE_LIST[@]}."
                        done
                        EDIT_PORT=${RULE_LIST[$((EDIT_NUM-1))]}

                        if [ -z "$EDIT_PORT" ]; then
                            echo "Invalid rule number."
                            break
                        fi

                        sudo sed -i "/frontend frontend_${EDIT_PORT}/,/^$/d" "$CONFIG_FILE"
                        sudo sed -i "/backend backend_${EDIT_PORT}/,/^$/d" "$CONFIG_FILE"

                        echo "Enter new configuration for port $EDIT_PORT"
                        BACKEND_SERVERS=()
                        while true; do
                            prompt_for_host REMOTE_ADDR "  Remote server address: "
                            prompt_for_port REMOTE_PORT "  Remote server port: "
                            BACKEND_SERVERS+=("${REMOTE_ADDR}:${REMOTE_PORT}")
                            read -rp "  Add another backend server? (y/n): " ADD_MORE
                            [[ "$ADD_MORE" =~ ^[yY]$ ]] || break
                        done

                        {
                            echo ""
                            echo "frontend frontend_${EDIT_PORT}"
                            echo "    bind *:${EDIT_PORT}"
                            echo "    default_backend backend_${EDIT_PORT}"
                            echo ""
                            echo "backend backend_${EDIT_PORT}"
                            echo "    balance roundrobin"
                            for i in "${!BACKEND_SERVERS[@]}"; do
                                echo "    server srv$((i+1)) ${BACKEND_SERVERS[$i]} check"
                            done
                        } | sudo tee -a "$CONFIG_FILE" > /dev/null

                        echo "Rule updated successfully."
                        read -rp "Edit another rule? (y/n): " CONTINUE_EDIT
                        [[ "$CONTINUE_EDIT" =~ ^[yY]$ ]] || break
                    done
                    ;;

                D|d)
                    while true; do
                    clear
                        echo "Deleting a rule"
                        echo "Current HAProxy rules:"
            RULE_NUMBER=1
            RULE_LIST=()

            for FRONTEND_PORT in $(grep -E '^frontend frontend_[0-9]+' "$CONFIG_FILE" | sed -E 's/^frontend frontend_([0-9]+).*/\1/'); do
                BACKEND="backend_${FRONTEND_PORT}"
                BACKEND_SERVERS=$(awk "/backend $BACKEND/,/^$/" "$CONFIG_FILE" | grep 'server ' | awk '{print $3}')
                echo "[$RULE_NUMBER] Frontend port: $FRONTEND_PORT -> Backends: $BACKEND_SERVERS"
                RULE_LIST+=("$FRONTEND_PORT")
                RULE_NUMBER=$((RULE_NUMBER+1))
            done
                        if (( ${#RULE_LIST[@]} == 0 )); then
                            echo "No rules available to delete."
                            read -rp "Press Enter to return " _
                            break
                        fi
                        while true; do
                            read -rp "Enter the rule number to delete: " DEL_NUM
                            if [[ $DEL_NUM =~ ^[0-9]+$ ]]; then
                                RULE_COUNT=${#RULE_LIST[@]}
                                if (( DEL_NUM >= 1 && DEL_NUM <= RULE_COUNT )); then
                                    break
                                fi
                            fi
                            echo "Invalid selection. Enter a number between 1 and ${#RULE_LIST[@]}."
                        done
                        DEL_PORT=${RULE_LIST[$((DEL_NUM-1))]}

                        if [ -z "$DEL_PORT" ]; then
                            echo "Invalid rule number."
                            break
                        fi

                        sudo sed -i "/frontend frontend_${DEL_PORT}/,/^$/d" "$CONFIG_FILE"
                        sudo sed -i "/backend backend_${DEL_PORT}/,/^$/d" "$CONFIG_FILE"

                        echo "Rule for port $DEL_PORT deleted successfully."
                        read -rp "Delete another rule? (y/n): " CONTINUE_DEL
                        [[ "$CONTINUE_DEL" =~ ^[yY]$ ]] || break
                    done
                    ;;

                X|x)
                    echo "Exiting edit mode without changes."
                    return
                    ;;

                *)
                    echo "Invalid option."
                    ;;
            esac

            # Restart HAProxy after any modification (with quick config validation)
            echo "Validating haproxy.cfg before restart..."
            if sudo docker run --rm -v "$CONFIG_FILE":/usr/local/etc/haproxy/haproxy.cfg:ro haproxy:2.9 haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg; then
                echo "Configuration valid. Restarting HAProxy container..."
                sudo docker compose -f "$DOCKER_COMPOSE_FILE" down
                sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
                echo "HAProxy restarted successfully."
            else
                echo "Invalid HAProxy configuration. Not restarting. Please fix errors above."
            fi

            read -rp "Do you want to continue editing rules? (y/n): " CONTINUE_LOOP
            [[ "$CONTINUE_LOOP" =~ ^[yY]$ ]] || break
        done



#HOST_IP=$(hostname -I | awk '{print $1}')
#echo "========================================="
#echo "HAProxy stats: http://$HOST_IP:9000/stats"
#echo "Stats login: $STATS_USER"
#echo "Stats password: $STATS_PASS"
#echo "SSH access: ssh $NEWUSER@$HOST_IP -p $SSHPORT"
#echo "========================================="
#echo " "
#        read -rp "Press any key to return " choice
#        case $choice in
#            *) return ;;
#        esac
return
}

# ===============================
# SSH user and port Function
# ===============================
submenu3() {
    while true; do
        clear
        echo " "
        echo "==== SSH menu ===="
        echo "1) Show settings"
        echo "2) Edit SSH port"
        echo "3) Add new SSH user"
        echo "4) Return to Main Menu"
        echo "==================="
        read -rp "Enter your choice: " choice

        case $choice in
            1) submenu5 ;;
            2) submenu6 ;;
            3) submenu7 ;;
            4) return ;;
            *) echo "Invalid choice. Press Enter to try again."
               read
               ;;
        esac
    done
}

# ===============================
# Show SSH settings
# ===============================
submenu5() {
    while true; do
        clear
        echo " "
        echo "Users with shell access:" && \
        grep -E "(/bin/bash|/bin/sh|/bin/zsh)$" /etc/passwd | cut -d: -f1 && \
        echo && \
        echo "SSH Port:" && \
        grep -i "^Port" /etc/ssh/sshd_config | awk '{print $2}' || echo "22 (default)" && \
        echo && \
        echo "Root login allowed:" && \
        grep -i "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}' || echo "no (default)"
        echo " "
        echo "==================="
        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
    done
}

# ===============================
# Edit SSH port settings
# ===============================
submenu6() {
    while true; do
        clear
        echo " "
        echo "Current SSH Port:" && \
        grep -i "^Port" /etc/ssh/sshd_config | awk '{print $2}' || echo "22 (default)"
        backup_file "/etc/ssh/sshd_config"
        echo " "
        prompt_for_port SSHPORT "Enter new SSH port (default 22): " 22
        sudo sed -i "/^#\?Port /c\Port $SSHPORT" /etc/ssh/sshd_config
        sudo sed -i "/^#\?PermitRootLogin /c\PermitRootLogin no" /etc/ssh/sshd_config
        sudo systemctl daemon-reload
        sudo systemctl restart ssh || sudo systemctl restart sshd
        echo " "
        echo "==================="
        if sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null; then
            echo "SSH service restarted successfully."
        else
            echo "Failed to restart SSH service."
        fi
        if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
            echo "SSH is running."
            echo " "
            echo "==================="
            PORT_INFO=$(sudo ss -tlnp | grep sshd || true)
                if [ -n "$PORT_INFO" ]; then
                    echo "Listening ports:"
                    echo "$PORT_INFO"
                else
                    echo "Could not detect SSH listening port."
                fi
        else
            echo "SSH is not running. Please check configuration or logs with:"
            echo "   sudo journalctl -u ssh --no-pager | tail -20"
            exit 1
        fi

        echo " "
        echo "==================="
        echo "SSH configured: port $SSHPORT, root login disabled."
        echo "==================="
        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
    done
}
# ===============================
# Add new SSH user
# ===============================
submenu7() {
    while true; do
        clear
        echo "Current users:" && \
        grep -E "(/bin/bash|/bin/sh|/bin/zsh)$" /etc/passwd | cut -d: -f1
        echo " "
        read -rp "Enter the name of the new user: " NEWUSER
            if id "$NEWUSER" &>/dev/null; then
                echo "User $NEWUSER already exists."
            else
                sudo adduser --disabled-password --gecos "" "$NEWUSER"
                echo "Set a password for user $NEWUSER:"
                sudo passwd "$NEWUSER"
                sudo usermod -aG sudo "$NEWUSER"
                echo "User $NEWUSER created and added to the sudo group."
            fi
        echo " "
        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
    done
}

# ===============================
# Show current config
# ===============================
submenu4() {
    while true; do
        clear
        echo " "
        echo "===== Current config ============="
        HOST_IP=$(hostname -I | awk '{print $1}')
        echo "Host IP: $HOST_IP"
        echo "---------------------------------"
        echo "Current HAProxy rules:"
            RULE_NUMBER=1
            RULE_LIST=()
            for FRONTEND_PORT in $(grep -E '^frontend frontend_[0-9]+' "$CONFIG_FILE" | sed -E 's/^frontend frontend_([0-9]+).*/\1/'); do
                BACKEND="backend_${FRONTEND_PORT}"
                BACKEND_SERVERS=$(awk "/backend $BACKEND/,/^$/" "$CONFIG_FILE" | grep 'server ' | awk '{print $3}')
                echo "[$RULE_NUMBER] Frontend port: $FRONTEND_PORT -> Backends: $BACKEND_SERVERS"
                RULE_LIST+=("$FRONTEND_PORT")
                RULE_NUMBER=$((RULE_NUMBER+1))
            done
        echo "---------------------------------"
        #HOST_IP=$(hostname -I | awk '{print $1}')
        echo "HAProxy stats: http://$HOST_IP:9000/stats"
        #echo "HAProxy stat: http://<serverIP>:9000/"
        grep -E "^\s*stats auth" /opt/haproxy/haproxy.cfg | awk '{split($3, creds, ":"); print "User: " creds[1] "\nPass: " creds[2]}'
        echo "---------------------------------"
        echo "Users with shell access:" && \
        grep -E "(/bin/bash|/bin/sh|/bin/zsh)$" /etc/passwd | cut -d: -f1 && \
        echo && \
        echo "SSH Port:" && \
        grep -i "^Port" /etc/ssh/sshd_config | awk '{print $2}' || echo "22 (default)" && \
        echo && \
        echo "Root login allowed:" && \
        grep -i "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}' || echo "no (default)"
        echo "---------------------------------"

        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
    done
}

# ===============================
# Stop HAProxy
# ===============================
submenu8() {
    sudo docker compose -f "$DOCKER_COMPOSE_FILE" ps --services --filter "status=running" | grep -qw haproxy && sudo docker compose -f "$DOCKER_COMPOSE_FILE" down && echo "Haproxy stopped" || echo "Haproxy is not running"
    echo " "
    sudo docker compose -f "$DOCKER_COMPOSE_FILE" ps --format "table {{.Name}}\t{{.State}}"
    echo " "
        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
}


# ===============================
# Start HAProxy
# ===============================
submenu9() {
    #sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    sudo docker compose -f "$DOCKER_COMPOSE_FILE" ps --services --filter "status=running" | grep -qw haproxy && echo "Haproxy already started" || sudo docker compose -f "$DOCKER_COMPOSE_FILE" up -d
    echo " "
    sudo docker compose -f "$DOCKER_COMPOSE_FILE" ps --format "table {{.Name}}\t{{.State}}"
    echo " "
        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
}



# ===============================
# Script Start
# ===============================


if [[ ! -f /etc/os-release ]]; then
    echo "Cannot determine OS type. This script supports only Ubuntu."
    exit 1
fi

. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    echo "This script supports only Ubuntu. Detected OS: $ID"
    exit 1
fi
CONFIG_FILE="/opt/haproxy/haproxy.cfg"
DOCKER_COMPOSE_FILE="/opt/haproxy/docker-compose.yml"
clear


main_menu
