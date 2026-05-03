#!/bin/bash
# ==============================================================================
# Script Name: ubuntu-setup.sh
# Description: Idempotent Ubuntu Initialization Script for C++ Development
# Environment: Ubuntu 20.04/22.04/24.04 (x86_64 ONLY)
# ==============================================================================

set -euo pipefail

# ==========================================
# Global Constants
# ==========================================
readonly TSINGHUA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
readonly OS_CODENAME="$(source /etc/os-release && echo "${VERSION_CODENAME}")"
readonly CURRENT_USER="${USER}"
readonly USER_HOME="${HOME}"

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_RESET='\033[0m'

# ==========================================
# Utility Functions
# ==========================================
log_info() { echo -e "${COLOR_CYAN}[INFO] ${1}${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_GREEN}[OK]   ${1}${COLOR_RESET}"; }
log_error() { echo -e "${COLOR_RED}[FAIL] ${1}${COLOR_RESET}" >&2; exit 1; }

trap 'echo -e "${COLOR_RED}[FATAL] Script failed at line ${LINENO}!${COLOR_RESET}" >&2' ERR

# Updates a specific block of text in a configuration file idempotently.
update_config_block() {
  local file="$1"
  local block_name="$2"
  local content="$3"
  local start_mark="# --- BEGIN ${block_name} ---"
  local end_mark="# --- END ${block_name} ---"

  touch "${file}"
  sed -i -e "/^${start_mark}$/,/^${end_mark}$/d" "${file}"
  echo -e "${start_mark}\n${content}\n${end_mark}" >> "${file}"
}

# ==========================================
# Core Modules
# ==========================================
# Verifies OS architecture and execution privileges.
check_environment() {
  log_info "1. Checking environment..."

  if [[ "${EUID}" -eq 0 ]]; then
    log_error "Please run this script as a normal user with sudo privileges, not root."
  fi

  if [[ "$(uname -m)" != "x86_64" ]]; then
    log_error "This script exclusively targets x86_64 architecture."
  fi

  # Cache sudo credentials upfront
  sudo -v || log_error "Failed to obtain sudo privileges."
  log_success "Environment check passed: ${CURRENT_USER} @ x86_64"
}

# Configures APT to use the Tsinghua University mirror for faster downloads.
setup_apt_mirrors() {
  log_info "2. Optimizing APT mirrors..."

  # For Ubuntu 24.04+ (DEB822 format)
  if [[ -f "/etc/apt/sources.list.d/ubuntu.sources" ]]; then
    if [[ ! -f "/etc/apt/sources.list.d/ubuntu.sources.bak" ]]; then
      sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
    fi

    sudo tee /etc/apt/sources.list.d/ubuntu.sources > /dev/null <<EOF
Types: deb
URIs: ${TSINGHUA_MIRROR}
Suites: ${OS_CODENAME} ${OS_CODENAME}-updates ${OS_CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${TSINGHUA_MIRROR}
Suites: ${OS_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

  # For Ubuntu 20.04/22.04 (Legacy format)
  elif [[ -f "/etc/apt/sources.list" ]]; then
    if [[ ! -f "/etc/apt/sources.list.bak" ]]; then
      sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi

    sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${TSINGHUA_MIRROR} ${OS_CODENAME} main restricted universe multiverse
deb ${TSINGHUA_MIRROR} ${OS_CODENAME}-updates main restricted universe multiverse
deb ${TSINGHUA_MIRROR} ${OS_CODENAME}-backports main restricted universe multiverse
deb ${TSINGHUA_MIRROR} ${OS_CODENAME}-security main restricted
deb ${TSINGHUA_MIRROR} ${OS_CODENAME}-security universe
deb ${TSINGHUA_MIRROR} ${OS_CODENAME}-security multiverse
EOF
  fi
  log_success "APT mirrors configured."
}

# Adds the official Kitware APT repository for the latest CMake versions.
install_cmake_repo() {
  log_info "3. Adding Kitware APT repository for latest CMake..."
  sudo apt-get update -yqq
  sudo apt-get install -yqq ca-certificates gpg wget

  if [[ ! -f "/usr/share/keyrings/kitware-archive-keyring.gpg" ]]; then
    wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc | gpg --dearmor - | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${OS_CODENAME} main" | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null
  fi
  log_success "Kitware repository configured."
}

# Installs all required C++ and system development tools.
update_system_and_tools() {
  log_info "4. Installing system updates and development toolchain..."

  # Prevent interactive dialogs during apt installation
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1

  sudo apt-get update -yqq

  local packages=(
    build-essential ninja-build cmake gdb valgrind libboost-all-dev
    python3-pip python3-venv pipx
    curl tcpdump iperf3 jq vim git tree openssh-server zip unzip
    libssl-dev protobuf-compiler libprotobuf-dev zookeeper zookeeperd libzookeeper-mt-dev
  )

  sudo -E apt-get install -y "${packages[@]}"

  log_success "Toolchain installed."
}

# Injects custom Git prompt and aliases into the user's .bashrc.
setup_bashrc() {
  log_info "5. Configuring terminal environment..."

  local bashrc_content
  bashrc_content=$(cat << 'EOF'
# Git Prompt
parse_git_info() {
    local gitdir
    gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 0

    local safe_name="${gitdir//[^a-zA-Z0-9]/_}"
    local var_time="_GIT_CACHE_TIME_${safe_name}"
    local var_data="_GIT_CACHE_DATA_${safe_name}"

    local cached_time="${!var_time}"
    if [[ -n "$cached_time" ]] && (( SECONDS - cached_time < 2 )); then
        printf "%s" "${!var_data}"
        return 0
    fi

    local status_output
    status_output=$(GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 --branch 2>/dev/null) || return 0

    local first_line="${status_output%%$'\n'*}"
    local files="${status_output#*$'\n'}"
    [[ "$files" == "$first_line" ]] && files=""

    local branch_info="${first_line:3}"
    local branch="${branch_info%%...*}"

    if [[ "$branch" == "No commits yet on "* ]]; then
        branch="${branch#No commits yet on }"
    elif [[ "$branch" == "Initial commit on "* ]]; then 
        branch="${branch#Initial commit on }"
    elif [[ "$branch" == "HEAD (no branch)" || -z "$branch" ]]; then
        branch=":$(git rev-parse --short HEAD 2>/dev/null)"
    fi

    local ahead="" behind="" dirty=""

    local re_ahead="ahead ([0-9]+)"
    [[ "$first_line" =~ $re_ahead ]] && ahead="+${BASH_REMATCH[1]}"

    local re_behind="behind ([0-9]+)"
    [[ "$first_line" =~ $re_behind ]] && behind="-${BASH_REMATCH[1]}"

    if [[ -n "$files" ]]; then
        local re_staged=$'(^|\n)[^ ?]. '
        local re_unstaged=$'(^|\n).[^ ?] '
        local re_untracked=$'(^|\n)\\?\\? '

        [[ "$files" =~ $re_staged ]] && dirty+="+"
        [[ "$files" =~ $re_unstaged ]] && dirty+="*"
        [[ "$files" =~ $re_untracked ]] && dirty+="?"
    fi

    local c_cyan=$'\001\e[36m\002'
    local c_reset=$'\001\e[0m\002'
    local output=" ${c_cyan}(${branch}${dirty}${ahead}${behind})${c_reset}"

    printf -v "$var_time" "%s" "$SECONDS"
    printf -v "$var_data" "%s" "$output"
    printf "%s" "$output"
}

# PS1 Configuration
export PS1="\[\e[1;32m\]\u\[\e[0m\]@\[\e[1;31m\]\h\[\e[0m\] \[\e[33m\]\w\$(parse_git_info)\[\e[0m\]\n$ "

# Proxy Aliases
alias proxy='export {http,https,all,HTTP,HTTPS,ALL}_proxy="http://127.0.0.1:7897"; echo "Proxy -> 127.0.0.1:7897"'
alias unproxy='unset {http,https,all,HTTP,HTTPS,ALL}_proxy; echo "Proxy disabled"'

EOF
)

  update_config_block "${USER_HOME}/.bashrc" "UBUNTU_SETUP_TERMINAL" "${bashrc_content}"
  log_success ".bashrc configured."
}

# ==========================================
# Main Execution
# ==========================================
main() {
  echo -e "${COLOR_GREEN}=== Ubuntu x86_64 Dev Setup ===${COLOR_RESET}"

  check_environment
  setup_apt_mirrors
  install_cmake_repo
  update_system_and_tools
  setup_bashrc

  echo -e "\n${COLOR_GREEN}[OK] Setup applied successfully!${COLOR_RESET}"
  echo -e "Run ${COLOR_CYAN}source ~/.bashrc${COLOR_RESET} or restart your terminal to apply changes."
}

main "$@"
