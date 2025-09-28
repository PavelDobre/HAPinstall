#!/bin/bash
set -e

# ===============================
# Main Menu Function
# ===============================
main_menu() {
    while true; do
        clear
        echo " "
        echo "==== Main Menu ===="
        echo "1) Option 1"
        echo "2) Option 2"
        echo "3) Exit"
        echo "=================="
        read -rp "Enter your choice: " choice

        case $choice in
            1) submenu1 ;;
            2) submenu2 ;;
            3) 
                echo "Exiting..."
                exit 0
                ;;
            *) echo "Invalid choice. Press Enter to try again."
               read
               ;;
        esac
    done
}

# ===============================
# Submenu 1 Function
# ===============================
submenu1() {
    while true; do
        clear
        echo " "
        echo "==== Submenu 1 ===="
        echo "1) Sub-option 1-1"
        echo "2) Sub-option 1-2"
        echo "3) Return to Main Menu"
        echo "==================="
        read -rp "Enter your choice: " choice

        case $choice in
            1) echo "You chose Sub-option 1-1"; read -rp "Press Enter to continue..." ;;
            2) echo "You chose Sub-option 1-2"; read -rp "Press Enter to continue..." ;;
            3) return ;;  # Возврат в главное меню
            *) echo "Invalid choice. Press Enter to try again."
               read
               ;;
        esac
    done
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
# Script Start
# ===============================
main_menu
