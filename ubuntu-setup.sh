#!/bin/bash
# ==============================================================================
# Script Name: ubuntu-setup.sh
# Description: Idempotent Ubuntu Initialization Script for C++ Development
# Environment: Ubuntu 20.04/22.04/24.04 (x86_64 ONLY)
# ==============================================================================

set -euo pipefail

# ==========================================
# Global Configurations
# ==========================================
readonly TSINGHUA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
readonly OS_CODENAME="$(source /etc/os-release && echo "${VERSION_CODENAME}")"
readonly CURRENT_USER="$(whoami)"
readonly USER_HOME="$(getent passwd "${CURRENT_USER}" | cut -d: -f6)"

readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_CYAN='\033[0;36m'
readonly C_NC='\033[0m'

# ==========================================
# Utility Functions
# ==========================================
log_info()    { echo -e "${C_CYAN}[INFO] ${1}${C_NC}"; }
log_success() { echo -e "${C_GREEN}[OK]   ${1}${C_NC}"; }
log_error()   { echo -e "${C_RED}[FAIL] ${1}${C_NC}" >&2; exit 1; }

trap 'echo -e "${C_RED}[FATAL] Script failed at line ${LINENO}!${C_NC}" >&2' ERR

update_config_block() {
  local file="$1" block_name="$2" content="$3" use_sudo="${4:-false}"
  local start_mark="# --- BEGIN ${block_name} ---"
  local end_mark="# --- END ${block_name} ---"

  if [[ "${use_sudo}" == "true" ]]; then
    sudo touch "${file}"
    sudo sed -i -e "/^${start_mark}$/,/^${end_mark}$/d" "${file}"
    echo -e "${start_mark}\n${content}\n${end_mark}" | sudo tee -a "${file}" > /dev/null
  else
    touch "${file}"
    sed -i -e "/^${start_mark}$/,/^${end_mark}$/d" "${file}"
    echo -e "${start_mark}\n${content}\n${end_mark}" >> "${file}"
  fi
}

show_spinner() {
  local pid=$1
  local msg="$2"
  local spin='-\|/'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r${C_CYAN}[%c]${C_NC} %s" "${spin:$i:1}" "$msg"
    sleep 0.1
  done
  printf "\r\033[K"
}

# ==========================================
# Core Modules
# ==========================================
check_environment() {
  log_info "1. Checking environment..."
  [[ "${EUID}" -eq 0 ]] && log_error "Please run this script as a normal user with sudo privileges."
  [[ "$(uname -m)" != "x86_64" ]] && log_error "This script exclusively targets x86_64 architecture."
  
  sudo -v || log_error "Failed to obtain sudo privileges."
  log_success "Environment check passed: ${CURRENT_USER} @ x86_64"
}

setup_apt_mirrors() {
  log_info "2. Optimizing APT mirrors..."
  if [[ -f "/etc/apt/sources.list.d/ubuntu.sources" ]]; then
    if [[ ! -f "/etc/apt/sources.list.d/ubuntu.sources.bak" ]]; then
      sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
    fi
    local deb822="Types: deb\nURIs: ${TSINGHUA_MIRROR}\nSuites: ${OS_CODENAME} ${OS_CODENAME}-updates ${OS_CODENAME}-backports\nComponents: main restricted universe multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\nTypes: deb\nURIs: ${TSINGHUA_MIRROR}\nSuites: ${OS_CODENAME}-security\nComponents: main restricted universe multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
    echo -e "${deb822}" | sudo tee /etc/apt/sources.list.d/ubuntu.sources > /dev/null
  elif [[ -f "/etc/apt/sources.list" ]]; then
    if [[ ! -f "/etc/apt/sources.list.bak" ]]; then
      sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi
    sudo sed -i "s|http://.*archive.ubuntu.com/ubuntu/|${TSINGHUA_MIRROR}|g; s|http://.*security.ubuntu.com/ubuntu/|${TSINGHUA_MIRROR}|g" /etc/apt/sources.list
  fi
  log_success "APT mirrors configured."
}

install_cmake_repo() {
  log_info "3. Adding Kitware APT repository for latest CMake..."
  sudo apt-get update -yqq
  sudo apt-get install -yqq ca-certificates gpg wget

  if [[ ! -f "/usr/share/keyrings/kitware-archive-keyring.gpg" ]]; then
    wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${OS_CODENAME} main" | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null
  fi
  log_success "Kitware repository configured."
}

update_system_and_tools() {
  log_info "4. Installing system updates and development toolchain..."
  
  export DEBIAN_FRONTEND=noninteractive
  if [[ -f "/etc/needrestart/needrestart.conf" ]]; then
    sudo sed -i "s/^#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/g" /etc/needrestart/needrestart.conf
  fi

  sudo apt-get update -yqq
  
  local packages=(
    build-essential ninja-build cmake gdb valgrind libboost-all-dev
    python3-pip python3-venv pipx
    curl tcpdump iperf3 jq vim git tree openssh-server zip unzip
    libssl-dev protobuf-compiler libprotobuf-dev zookeeper zookeeperd libzookeeper-mt-dev docker.io
  )
  
  local log_file="/tmp/ubuntu-setup-apt.log"
  sudo -E apt-get install -y "${packages[@]}" > "${log_file}" 2>&1 &
  show_spinner "$!" "Installing packages (log: ${log_file})..."
  
  # Ensure docker group access
  if ! groups "${CURRENT_USER}" | grep -q '\bdocker\b'; then
    sudo usermod -aG docker "${CURRENT_USER}"
  fi
  log_success "Toolchain installed."
}

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

    local re_ahead="ahead ([0-9]+)"
    [[ "$first_line" =~ $re_ahead ]] && ahead="+${BASH_REMATCH[1]}"

    local re_behind="behind ([0-9]+)"
    [[ "$first_line" =~ $re_behind ]] && behind="-${BASH_REMATCH[1]}"

    if [[ -n "$files" ]]; then
        local re_staged="(^|$'\n')[^ ?]. "
        local re_unstaged="(^|$'\n').[^ ?] "
        local re_untracked="(^|$'\n')\?\? "

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

# PS1
export PS1="\[\e[1;32m\]\u\[\e[0m\]@\[\e[1;31m\]\h\[\e[0m\] \[\e[33m\]\w\$(parse_git_info)\[\e[0m\]\n$ "

# Proxy
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
  echo -e "${C_GREEN}=== Ubuntu x86_64 Dev Setup ===${C_NC}"
  
  check_environment
  setup_apt_mirrors
  install_cmake_repo
  update_system_and_tools
  setup_bashrc

  echo -e "\n${C_GREEN}[OK] Setup applied successfully!${C_NC}"
  echo -e "Run ${C_CYAN}source ~/.bashrc${C_NC} to apply changes."
}

main "$@"
