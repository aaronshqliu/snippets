#!/bin/bash
# ==============================================================================
# Script Name: ubuntu-setup.sh
# Description: Ubuntu Initialization Script
# Environment: Ubuntu 20.04/22.04/24.04 (x86_64 & aarch64)
# ==============================================================================

# Enable strict mode
set -euo pipefail

# ==========================================
# Global Configurations
# ==========================================
readonly SCRIPT_VERSION="3.2.0"
readonly CMAKE_VERSION="4.1.5"

readonly TSINGHUA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
readonly GITHUB_HOSTS_URL="https://raw.hellogithub.com/hosts"

# Color definitions
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

# ==========================================
# Utility Functions
# ==========================================
log_info()    { echo -e "${COLOR_CYAN}[INFO] ${1}${COLOR_NC}"; }
log_success() { echo -e "${COLOR_GREEN}[OK]   ${1}${COLOR_NC}"; }
log_warning() { echo -e "${COLOR_YELLOW}[WARN] ${1}${COLOR_NC}"; }
log_error()   { echo -e "${COLOR_RED}[FAIL] ${1}${COLOR_NC}" >&2; exit 1; }

# Global error trap
trap 'echo -e "${COLOR_RED}[FATAL] Script failed at line ${LINENO}! Please check the logs above.${COLOR_NC}" >&2' ERR

# Retry mechanism that returns 1 on failure instead of exiting the script
retry_command() {
  local max_attempts=3
  local timeout=2
  local attempt=1

  while (( attempt <= max_attempts )); do
    if "$@"; then
      return 0
    fi
    log_warning "Command '$1' failed. Retrying in ${timeout}s (${attempt}/${max_attempts})..."
    sleep "${timeout}"
    (( attempt++ ))
    (( timeout *= 2 ))
  done
  log_warning "Command '$1' finally failed after ${max_attempts} attempts."
  return 1
}

# Idempotent config block updater
update_config_block() {
  local file="$1"
  local block_name="$2"
  local content="$3"
  local use_sudo="${4:-false}"

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

# ==========================================
# Core Modules
# ==========================================

check_environment() {
  log_info "1. Checking environment..."
  if [[ "${EUID}" -eq 0 ]]; then
    log_error "Please do not run this script as root or via sudo directly!\nUsage: ./ubuntu-setup.sh (It will prompt for password when needed)"
  fi

  readonly CURRENT_USER="$(whoami)"
  readonly USER_HOME="$(eval echo "~${CURRENT_USER}")"
  
  if [[ -f "/etc/os-release" ]]; then
    readonly OS_CODENAME="$(source /etc/os-release && echo "${VERSION_CODENAME:-}")"
  else
    log_error "Cannot find /etc/os-release. Unsupported Linux distribution."
  fi

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)  readonly SYS_ARCH="x86_64" ;;
    aarch64) readonly SYS_ARCH="aarch64" ;;
    *)       log_error "Unsupported system architecture: ${arch}" ;;
  esac

  echo "User: ${CURRENT_USER} | Home: ${USER_HOME}"
  echo "OS Codename: ${OS_CODENAME} | Architecture: ${SYS_ARCH}"
  log_success "Environment check passed."
}

setup_apt_mirrors() {
  log_info "2. Optimizing APT mirrors (Tsinghua Mirror)..."
  
  if [[ -f "/etc/apt/sources.list.d/ubuntu.sources" ]]; then
    [[ ! -f "/etc/apt/sources.list.d/ubuntu.sources.bak" ]] && \
      sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak

    local deb822_content="Types: deb
URIs: ${TSINGHUA_MIRROR}
Suites: ${OS_CODENAME} ${OS_CODENAME}-updates ${OS_CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${TSINGHUA_MIRROR}
Suites: ${OS_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"

    echo "${deb822_content}" | sudo tee /etc/apt/sources.list.d/ubuntu.sources > /dev/null
    log_success "APT (DEB822) mirrors configured."

  elif [[ -f "/etc/apt/sources.list" ]]; then
    [[ ! -f "/etc/apt/sources.list.bak" ]] && \
      sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak

    sudo sed -i "s|http://.*archive.ubuntu.com/ubuntu/|${TSINGHUA_MIRROR}|g" /etc/apt/sources.list
    sudo sed -i "s|http://.*security.ubuntu.com/ubuntu/|${TSINGHUA_MIRROR}|g" /etc/apt/sources.list
    log_success "APT (sources.list) mirrors configured."
  else
    log_warning "No standard APT source file found, skipping."
  fi
}

update_system_and_tools() {
  log_info "3. Updating system and installing basic tools..."
  
  # === Bypass Ubuntu 22.04+ needrestart interactive prompt ===
  if [[ -f "/etc/needrestart/needrestart.conf" ]]; then
    log_info "Configuring needrestart to avoid interactive daemon prompts..."
    sudo sed -i "s/^#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/g" /etc/needrestart/needrestart.conf || true
  fi
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  sudo apt-get clean
  retry_command sudo apt-get update || log_warning "APT update had issues, continuing anyway..."
  sudo -E apt-get upgrade -y || log_warning "APT upgrade had issues, continuing anyway..."

  local packages=(
    vim git curl wget zip unzip tree build-essential ninja-build
    python3-pip pipx libssl-dev valgrind samba samba-common
    openssh-server gnome-tweaks jq
  )
  
  retry_command sudo -E apt-get install -y "${packages[@]}" || log_warning "Some APT packages failed to install."
  log_success "System update and tools installation phase completed."
}

setup_bashrc() {
  log_info "4. Configuring terminal environment (.bashrc)..."
  
  local bashrc_content
  read -r -d '' bashrc_content << 'EOF' || true
# Git Info Prompt
parse_git_info() {
  local branch dirty ahead behind status behind_count ahead_count
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || branch=$(git rev-parse --short HEAD 2>/dev/null) || return
  dirty=""
  [[ -n "$(git status --porcelain 2>/dev/null | head -n 1)" ]] && dirty="*"
  ahead=""; behind=""
  status=$(git rev-list --left-right --count @{upstream}...HEAD 2>/dev/null)
  if [[ -n "$status" ]]; then
    read -r behind_count ahead_count <<< "$status"
    [[ "$ahead_count" -gt 0 ]] && ahead="+"
    [[ "$behind_count" -gt 0 ]] && behind="-"
  fi
  printf " \001\e[36m\002(%s%s%s%s)" "$branch" "$dirty" "$ahead" "$behind"
}

export PS1="\[\e[1;32m\]\u\[\e[m\]@\[\e[1;31m\]\h\[\e[m\]:\[\e[33m\]\w\$(parse_git_info)\[\e[m\]\n$ "

# Proxy Aliases (Hardcoded to 7890 as requested)
alias proxy='export {http,https,all,HTTP,HTTPS,ALL}_proxy="http://127.0.0.1:7890"; echo "Proxy enabled -> 127.0.0.1:7890"'
alias unproxy='unset {http,https,all,HTTP,HTTPS,ALL}_proxy; echo "Proxy disabled"'
EOF

  update_config_block "${USER_HOME}/.bashrc" "UBUNTU_SETUP_TERMINAL" "${bashrc_content}"
  log_success ".bashrc configuration applied."
}

setup_github_hosts() {
  log_info "5. GitHub Hosts Acceleration"
  echo -ne "${COLOR_YELLOW}Do you want to update /etc/hosts to accelerate GitHub access? (y/n) [n]: ${COLOR_NC}"
  local apply_hosts
  read -r apply_hosts
  apply_hosts="${apply_hosts:-n}"

  if [[ "${apply_hosts}" =~ ^[Yy]$ ]]; then
    local temp_hosts="/tmp/github_hosts.txt"
    log_info "Fetching GitHub hosts..."
    
    if curl -s -m 10 "${GITHUB_HOSTS_URL}" -o "${temp_hosts}"; then
      local hosts_content
      hosts_content="$(cat "${temp_hosts}")"
      update_config_block "/etc/hosts" "GITHUB_HOSTS_520" "${hosts_content}" "true"
      
      if command -v resolvectl >/dev/null 2>&1; then
        sudo resolvectl flush-caches || true
      elif command -v systemd-resolve >/dev/null 2>&1; then
        sudo systemd-resolve --flush-caches || true
      fi
      log_success "GitHub hosts updated successfully."
    else
      log_warning "Failed to fetch GitHub hosts (network timeout), skipping."
    fi
    rm -f "${temp_hosts}"
  else
    log_info "Skipped GitHub hosts update."
  fi
}

install_cmake_securely() {
  log_info "6. Installing CMake ${CMAKE_VERSION} securely..."
  
  if command -v cmake >/dev/null 2>&1 && cmake --version | grep -q "${CMAKE_VERSION}"; then
    log_success "CMake ${CMAKE_VERSION} is already installed, skipping."
    return 0
  fi

  # Run in subshell to prevent directory pollution
  (
    cd /tmp || { log_warning "Cannot enter /tmp directory. Skipping CMake."; exit 0; }
    
    local tar_file="cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}.tar.gz"
    local sha_file="cmake-${CMAKE_VERSION}-SHA-256.txt"
    
    local proxies=(
      "https://v6.gh-proxy.org/"
      "https://github.cnxiaobai.com/"
      "https://cdn.gh-proxy.org/"
      "https://edgeone.gh-proxy.org/"
      ""
    )

    local download_success=false
    for proxy in "${proxies[@]}"; do
      local base_url="${proxy}https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}"
      local proxy_name="${proxy:-Official GitHub}"
      log_info "Trying to download via: ${proxy_name}"
      
      if curl -SLf --progress-bar -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -o "${tar_file}" "${base_url}/${tar_file}" && \
         curl -SLf -s -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -o "${sha_file}" "${base_url}/${sha_file}"; then
        download_success=true
        break
      else
        log_warning "Download failed with ${proxy_name}, trying next mirror..."
        rm -f "${tar_file}" "${sha_file}"
      fi
    done

    if [[ "${download_success}" != "true" ]]; then
      log_warning "All download attempts failed (404/Timeout). Skipping CMake installation."
      exit 0
    fi

    log_info "Verifying file integrity (SHA256)..."
    if ! grep "${tar_file}" "${sha_file}" | sha256sum -c - >/dev/null 2>&1; then
      log_warning "SECURITY ALERT: CMake SHA256 checksum failed! Dropping downloaded files."
      rm -f "${tar_file}" "${sha_file}"
      exit 0
    fi
    log_success "Checksum verification passed."

    log_info "Extracting and deploying..."
    tar -zxf "${tar_file}"
    sudo rm -rf "/opt/cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}"
    sudo mv "cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}" /opt/
    sudo ln -sf "/opt/cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}/bin/"* /usr/local/bin/

    rm -f "${tar_file}" "${sha_file}"
  ) || true

  if command -v cmake >/dev/null 2>&1 && cmake --version | grep -q "${CMAKE_VERSION}"; then
    log_success "CMake ${CMAKE_VERSION} installed successfully."
  else
    log_warning "CMake installation was skipped or incomplete."
  fi
}

setup_samba() {
  log_info "7. Configuring Samba Shared Folder"
  
  echo -ne "${COLOR_YELLOW}Do you want to configure Samba shared folder for current user? (y/n) [n]: ${COLOR_NC}"
  local apply_samba
  read -r apply_samba
  apply_samba="${apply_samba:-n}"

  if [[ "${apply_samba}" =~ ^[Yy]$ ]]; then
    local smb_conf="[Share]
   comment = Shared Folder
   path = ${USER_HOME}
   valid users = ${CURRENT_USER}
   directory mask = 0775
   create mask = 0775
   public = yes
   writable = yes
   available = yes
   browseable = yes"

    update_config_block "/etc/samba/smb.conf" "USER_SHARE" "${smb_conf}" "true"

    log_info "Setting up Samba access password for user: ${CURRENT_USER}"
    log_info "Press Enter directly if you want to skip password setup."
    
    if sudo smbpasswd -a "${CURRENT_USER}"; then
      sudo systemctl restart smbd
      log_success "Samba password set and service restarted."
    else
      log_warning "Samba password setup skipped or failed. Service is still running."
    fi
  else
    log_info "Skipped Samba configuration."
  fi
}

setup_git() {
  log_info "8. Configuring Git Global Settings"
  
  echo -ne "${COLOR_YELLOW}Do you want to configure global Git user.name and user.email? (y/n) [n]: ${COLOR_NC}"
  local do_config
  read -r do_config
  do_config="${do_config:-n}"

  if [[ "${do_config}" =~ ^[Yy]$ ]]; then
    local g_name g_email
    read -r -p "Enter Git user.name: " g_name
    read -r -p "Enter Git user.email: " g_email

    if [[ -n "${g_name}" ]] && [[ -n "${g_email}" ]]; then
      git config --global user.name "${g_name}"
      git config --global user.email "${g_email}"
      git config --global credential.helper store
      log_success "Git configured as: ${g_name} <${g_email}>"
    else
      log_warning "Incomplete input, Git configuration skipped."
    fi
  else
    log_info "Skipped Git configuration."
  fi
}

# ==========================================
# Main Execution
# ==========================================
main() {
  echo -e "${COLOR_GREEN}==========================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}      Ubuntu Automated Setup v${SCRIPT_VERSION}      ${COLOR_NC}"
  echo -e "${COLOR_GREEN}==========================================${COLOR_NC}"

  check_environment
  setup_apt_mirrors
  update_system_and_tools
  setup_bashrc
  setup_github_hosts
  install_cmake_securely
  setup_samba
  setup_git

  echo -e "\n${COLOR_GREEN}==========================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}[OK] All configurations applied successfully!${COLOR_NC}"
  echo -e "Please run ${COLOR_CYAN}source ~/.bashrc${COLOR_NC} or restart your terminal to apply changes."
  
  trap - ERR
  exit 0
}

# Run the script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi