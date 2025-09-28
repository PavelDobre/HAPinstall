#!/bin/bash
set -e

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
        echo "==== Main Menu ===="
        echo "1) New HAProxy installation"
        echo "2) Existing HAProxy configuration"
        echo "3) SSH user and port Configuration"
        echo "4) Show current config"
        echo "5) Exit"
        echo "=================="
        read -rp "Enter your choice: " choice

        case $choice in
            1) submenu1 ;;
            2) submenu2 ;;
            3) submenu3 ;;
            4) submenu4 ;;
            5) exit 0   ;;
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
    echo "Checking for system updates..."
    read -p "Update the system with 'sudo apt-get update && sudo apt-get upgrade -y'? (Recommended) [y/N]: " UPGRADE_CONFIRM
        if [[ "$UPGRADE_CONFIRM" =~ ^[yY]$ ]]; then
            sudo apt-get update
            sudo apt-get upgrade -y
        fi
    clear
echo "=== HAProxy server installation ==="
    
    
    return
}

# ===============================
# Submenu 2 Function
# ===============================
submenu2() {
    while true; do
        clear
        echo " "
        echo "==== Submenu 2 ===="
        echo "1) Sub-option 2-1"
        echo "2) Sub-option 2-2"
        echo "3) Return to Main Menu"
        echo "==================="
        read -rp "Enter your choice: " choice

        case $choice in
            1) echo "You chose Sub-option 2-1"; read -rp "Press Enter to continue..." ;;
            2) echo "You chose Sub-option 2-2"; read -rp "Press Enter to continue..." ;;
            3) return ;;  # Возврат в главное меню
            *) echo "Invalid choice. Press Enter to try again."
               read
               ;;
        esac
    done
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
        echo "2) Edit SSH settings"
        echo "3) Add new user"
        echo "4) Return to Main Menu"
        echo "==================="
        read -rp "Enter your choice: " choice

        case $choice in
            1) submenu5 ;;
            2) submenu6 ;;
            3) echo "You chose Sub-option 2-2"; read -rp "Press Enter to continue..." ;;
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
        backup_file "/etc/ssh/sshd_config"
        read -p "Enter new SSH port (default 2222): " SSHPORT
        SSHPORT=${SSHPORT:-2222}
        sudo sed -i "/^#\?Port /c\Port $SSHPORT" /etc/ssh/sshd_config
        sudo sed -i "/^#\?PermitRootLogin /c\PermitRootLogin no" /etc/ssh/sshd_config
        sudo systemctl daemon-reload
        sudo systemctl restart ssh.socket
        echo "SSH configured: port $SSHPORT, root login disabled."
        echo "==================="
        read -rp "Press any key to return " choice
        case $choice in
            *) return ;;
        esac
    done
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
