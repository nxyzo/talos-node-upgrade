#!/bin/bash
set -euo pipefail

# Define color variables
YELLOW="\e[33m"
RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
PURPLE="\e[35m"
RESET="\e[0m"

## lists
node_names=()
node_ips=()
node_os=()
update_needed=()

## variables
talos_version=""
TALOS_DIR="talos"
talenv_path="${TALOS_DIR}/talenv.yaml"
talconfig_path="${TALOS_DIR}/talconfig.yaml"

function print_colored() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${RESET}"
}

function get_node_names() {
    local tmp_nodes=()

    if ! mapfile -t tmp_nodes < <(
        kubectl get nodes -o wide | tail -n +2 | awk '{print $1}'
    ); then
        print_colored "$RED" "Error: Nodes could not be read"
        return 1
    fi

    if [[ ${#tmp_nodes[@]} -eq 0 ]]; then
        print_colored "$RED" "Error: Nodes could not be found"
        return 1
    fi

    node_names=("${tmp_nodes[@]}")
}

function get_node_ips() {
    local tmp_node_ips=()

    if ! mapfile -t tmp_node_ips < <(
        kubectl get nodes -o wide | tail -n +2 | awk '{print $6}'
    ); then
        print_colored "$RED" "Error: Node ips could not be read"
        return 1
    fi

    if [[ ${#tmp_node_ips[@]} -eq 0 ]]; then
        print_colored "$RED" "Error: Node ips could not be found"
        return 1
    fi

    node_ips=("${tmp_node_ips[@]}")
}

function get_node_os() {
    local tmp_node_os=()

    if ! mapfile -t tmp_node_os < <(
        kubectl get nodes -o wide | tail -n +2 | awk '{print $9}' | tr -d '()'
    ); then
        print_colored "$RED" "Error: Node os could not be read"
        return 1
    fi

    if [[ ${#tmp_node_os[@]} -eq 0 ]]; then
        print_colored "$RED" "Error: Node os could not be found"
        return 1
    fi

    node_os=("${tmp_node_os[@]}")
}

function get_talos_version() {
    if [[ ! -f "$talenv_path" ]]; then
        print_colored "$RED" "Error: talenv does not exist"
        return 1
    fi

    local tmp_talos_version
    tmp_talos_version=$(yq -r '.talosVersion' "$talenv_path")

    if [[ -z "$tmp_talos_version" || "$tmp_talos_version" == "null" ]]; then
        print_colored "$RED" "Error: Talos version could not be extracted"
        return 1
    fi

    talos_version="$tmp_talos_version"
}

check_requirements() {
    local ip
    local failed=0

    for ip in "${node_ips[@]}"; do
        if ! talosctl --nodes "$ip" get machineconfig >/dev/null 2>&1; then
            print_colored "$RED" "Fehler: machineconfig konnte für Node $ip nicht gelesen werden"
            failed=1
        fi
    done

    if ! talosctl config info >/dev/null 2>&1; then
        print_colored "$RED" "Fehler: talosctl config ist ungültig oder nicht verfügbar"
        failed=1
    fi

    if [[ -z "${TALOSCONFIG:-}" ]]; then
        print_colored "$RED" "Fehler: TALOSCONFIG ist nicht gesetzt"
        failed=1
    elif [[ ! -f "$TALOSCONFIG" ]]; then
        print_colored "$RED" "Fehler: TALOSCONFIG-Datei nicht gefunden: $TALOSCONFIG"
        failed=1
    fi

    [[ -f "$talconfig_path" ]] || { print_colored "$RED" "Fehler: $talconfig_path fehlt"; failed=1; }
    [[ -f "$talenv_path" ]] || { print_colored "$RED" "Fehler: $talenv_path fehlt"; failed=1; }

    command -v kubectl >/dev/null 2>&1 || { print_colored "$RED" "Fehler: kubectl fehlt"; failed=1; }
    command -v talhelper >/dev/null 2>&1 || { print_colored "$RED" "Fehler: talhelper fehlt"; failed=1; }
    command -v talosctl >/dev/null 2>&1 || { print_colored "$RED" "Fehler: talosctl fehlt"; failed=1; }
    command -v yq >/dev/null 2>&1 || { print_colored "$RED" "Fehler: yq fehlt"; failed=1; }

    return $failed
}

function check_version() {
    local i

    get_node_os || return 1
    get_talos_version || return 1

    update_needed=()

    for i in "${!node_os[@]}"; do
        if [[ "${node_os[$i]}" != "$talos_version" ]]; then
            update_needed+=("YES")
        else
            update_needed+=("NO")
        fi
    done
}

function show_nodes() {
    printf "%-15s %-15s %-10s %-15s\n" "NAME" "IP" "OS" "NEEDS UPDATE"

    local i
    for i in "${!node_names[@]}"; do
        local color="$RESET"

        if [[ "${update_needed[$i]}" == "YES" ]]; then
            color="$YELLOW"
        elif [[ "${update_needed[$i]}" == "NO" ]]; then
            color="$GREEN"
        fi

        printf "${color}%-15s %-15s %-10s %-15s${RESET}\n" \
            "${node_names[$i]}" \
            "${node_ips[$i]}" \
            "${node_os[$i]}" \
            "${update_needed[$i]}"
    done
}

function ask_for_confirmation() {
    local prompt="$1"
    local response

    while true; do
        read -rp "$prompt (y/n): " response
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

function show_nodes_update() {
    printf "%-15s %-15s %-10s\n" "NAME" "IP" "OS"

    local i
    for i in "${!node_names[@]}"; do
        if [[ "${update_needed[$i]}" == "YES" ]]; then
            printf "${YELLOW}%-15s %-15s %-10s${RESET}\n" \
                "${node_names[$i]}" \
                "${node_ips[$i]}" \
                "${node_os[$i]}"
        fi
    done
}

function get_talos_image() {
    local ip="$1"

    if [[ ! -f "$talconfig_path" ]]; then
        print_colored "$RED" "Fehler: talconfig nicht gefunden: $talconfig_path"
        return 1
    fi

    local image
    image=$(yq -r ".nodes[] | select(.ipAddress == \"$ip\") | .talosImageURL" "$talconfig_path")

    if [[ -z "$image" || "$image" == "null" ]]; then
        print_colored "$RED" "Fehler: Keine talosImageURL für IP $ip gefunden"
        return 1
    fi

    printf '%s\n' "$image"
}

update_nodes() {
    local i
    local node_name
    local node_ip
    local talos_image

    for i in "${!node_names[@]}"; do
        [[ "${update_needed[$i]}" == "YES" ]] || continue

        node_name="${node_names[$i]}"
        node_ip="${node_ips[$i]}"

        talos_image=$(get_talos_image "$node_ip") || return 1

        print_colored "$BLUE" "Updating node $node_name with IP $node_ip..."

        if ! kubectl cordon "$node_name"; then
            print_colored "$RED" "Fehler: Konnte Node $node_name nicht cordon setzen"
            return 1
        fi

        if ! kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=15m; then
            print_colored "$RED" "Fehler: Konnte Node $node_name nicht drainen"
            kubectl uncordon "$node_name" >/dev/null 2>&1 || true
            return 1
        fi

        if ! (
            cd "$TALOS_DIR" || exit 1
            talhelper gencommand upgrade \
                --node "$node_ip" \
                --extra-flags "--image='${talos_image}:${talos_version}' --timeout=10m" | bash
        ); then
            print_colored "$RED" "Fehler: Upgrade für $node_name fehlgeschlagen"
            kubectl uncordon "$node_name" >/dev/null 2>&1 || true
            return 1
        fi

        if ! kubectl wait --for=condition=Ready "node/$node_name" --timeout=15m; then
            print_colored "$RED" "Fehler: Node $node_name wurde nicht rechtzeitig Ready"
            kubectl uncordon "$node_name" >/dev/null 2>&1 || true
            return 1
        fi

        if ! kubectl uncordon "$node_name"; then
            print_colored "$RED" "Fehler: Konnte Node $node_name nicht uncordon setzen"
            return 1
        fi

        print_colored "$GREEN" "Node $node_name erfolgreich aktualisiert"
        echo "Wait 5 minutes for the node to stabilize..."
        sleep 300
    done
}

function exit_no_update_needed() {
    for status in "${update_needed[@]}"; do
        if [[ "$status" == "YES" ]]; then
            update_needed=true
            break
        fi
    done
    if [[ "$update_needed" != true ]]; then
        print_colored "$GREEN" "All nodes are already up to date. No update needed."
        exit 0
    fi
}

get_node_names
get_node_ips
check_version
show_nodes
exit_no_update_needed
ask_for_confirmation "Do you want to update the nodes?" || exit 0

print_colored "$BLUE" "Checking requirements..."
check_requirements || exit 1

print_colored "$YELLOW" "The following nodes will be updated..."
show_nodes_update
ask_for_confirmation "Do you want to proceed with the update?" || exit 0

update_nodes
