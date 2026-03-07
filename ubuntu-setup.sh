#!/bin/bash
# ==============================================================================
# Script Name: ubuntu-setup.sh
# Description: Ubuntu 初始化配置脚本
# Environment: Ubuntu (x86_64 & aarch64)
# ==============================================================================

# 开启严格模式: 遇到错误、未定义变量或管道错误立即停止
set -euo pipefail

# ==========================================
# 全局配置区
# ==========================================
readonly SCRIPT_VERSION="2.0.0"
readonly CMAKE_VERSION="4.1.5"
readonly PROXY_PORT="7890"

readonly GITHUB_PROXY="https://gh-proxy.org/"
readonly TSINGHUA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
readonly CMAKE_BASE_URL="${GITHUB_PROXY}https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}"
readonly GITHUB_HOSTS_URL="https://raw.hellogithub.com/hosts"

# 颜色定义
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

# ==========================================
# 基础工具与日志函数
# ==========================================
log_info()    { echo -e "${COLOR_CYAN}▶ ${1}${COLOR_NC}"; }
log_success() { echo -e "${COLOR_GREEN}✔ ${1}${COLOR_NC}"; }
log_warning() { echo -e "${COLOR_YELLOW}⚠ ${1}${COLOR_NC}"; }
log_error()   { echo -e "${COLOR_RED}✖ ${1}${COLOR_NC}" >&2; exit 1; }

# 全局错误捕获机制
trap 'echo -e "${COLOR_RED}✖ 严重错误: 脚本在第 ${LINENO} 行执行失败退出! 请检查上述报错信息${COLOR_NC}" >&2' ERR

# 带指数退避的重试机制
retry_command() {
  local max_attempts=3
  local timeout=2
  local attempt=1

  while (( attempt <= max_attempts )); do
    if "$@"; then
      return 0
    fi
    log_warning "命令 '$1' 执行失败, 等待 ${timeout} 秒后重试 (${attempt}/${max_attempts})..."
    sleep "${timeout}"
    (( attempt++ ))
    (( timeout *= 2 ))
  done
  log_error "命令 '$1' 在 ${max_attempts} 次尝试后仍然失败"
}

# 幂等性配置区块写入工具
update_config_block() {
  local file="$1"
  local block_name="$2"
  local content="$3"
  local use_sudo="${4:-false}"

  local start_mark="# --- BEGIN ${block_name} ---"
  local end_mark="# --- END ${block_name} ---"

  if [[ "${use_sudo}" == "true" ]]; then
    # 如果文件不存在则创建
    sudo touch "${file}"
    # 清理旧区块
    sudo sed -i -e "/^${start_mark}$/,/^${end_mark}$/d" "${file}"
    # 写入新区块
    echo -e "${start_mark}\n${content}\n${end_mark}" | sudo tee -a "${file}" > /dev/null
  else
    touch "${file}"
    sed -i -e "/^${start_mark}$/,/^${end_mark}$/d" "${file}"
    echo -e "${start_mark}\n${content}\n${end_mark}" >> "${file}"
  fi
}

# ==========================================
# 核心业务模块
# ==========================================

check_environment() {
  log_info "1. 环境安全检查"
  if [[ "${EUID}" -eq 0 ]]; then
    log_error "请不要使用 sudo 或 root 身份运行此脚本! \n正确用法: ./ubuntu-setup.sh (按需会提示输入密码)"
  fi

  readonly CURRENT_USER="$(whoami)"
  readonly USER_HOME="$(eval echo "~${CURRENT_USER}")"
  
  # 获取系统信息
  if [[ -f "/etc/os-release" ]]; then
    readonly OS_CODENAME="$(source /etc/os-release && echo "${VERSION_CODENAME:-}")"
  else
    log_error "未找到 /etc/os-release, 不支持的 Linux 发行版"
  fi

  # 获取硬件架构
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)  readonly SYS_ARCH="x86_64" ;;
    aarch64) readonly SYS_ARCH="aarch64" ;;
    *)       log_error "不支持的系统架构: ${arch}" ;;
  esac

  echo "当前用户: ${CURRENT_USER} | 家目录: ${USER_HOME}"
  echo "系统代号: ${OS_CODENAME} | 架构: ${SYS_ARCH}"
  log_success "环境检查通过"
}

setup_apt_mirrors() {
  log_info "2. 优化 APT 镜像源 (清华源)"
  
  if [[ -f "/etc/apt/sources.list.d/ubuntu.sources" ]]; then
    # Ubuntu 24.04+ DEB822 格式
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
    log_success "APT (DEB822) 源配置成功"

  elif [[ -f "/etc/apt/sources.list" ]]; then
    # Ubuntu 22.04 及以下 traditional 格式
    [[ ! -f "/etc/apt/sources.list.bak" ]] && \
      sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak

    # 使用 sed 安全替换默认源, 防止破坏第三方源
    sudo sed -i "s|http://.*archive.ubuntu.com/ubuntu/|${TSINGHUA_MIRROR}|g" /etc/apt/sources.list
    sudo sed -i "s|http://.*security.ubuntu.com/ubuntu/|${TSINGHUA_MIRROR}|g" /etc/apt/sources.list
    log_success "APT (sources.list) 源替换成功"
  else
    log_warning "未找到标准 APT 源配置文件, 跳过此步"
  fi
}

update_system_and_tools() {
  log_info "3. 更新系统与安装基础工具"
  sudo apt-get clean
  retry_command sudo apt-get update
  
  sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

  local packages=(
    vim git curl wget zip unzip tree build-essential ninja-build
    python3-pip pipx libssl-dev valgrind samba samba-common
    openssh-server gnome-tweaks jq
  )

  retry_command sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  log_success "系统更新与基础工具安装完成"
}

setup_bashrc() {
  log_info "4. 配置终端环境 (.bashrc)"

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
    [[ "$ahead_count" -gt 0 ]] && ahead="↑"
    [[ "$behind_count" -gt 0 ]] && behind="↓"
  fi
  printf " \001\e[36m\002(%s%s%s%s)" "$branch" "$dirty" "$ahead" "$behind"
}

export PS1="\[\e[1;32m\]\u\[\e[m\]@\[\e[1;31m\]\h\[\e[m\]:\[\e[33m\]\w\$(parse_git_info)\[\e[m\]\n$ "

# Proxy Aliases
alias proxy='export {http,https,all,HTTP,HTTPS,ALL}_proxy="http://127.0.0.1:__PROXY_PORT__"; echo "Proxy enabled → 127.0.0.1:__PROXY_PORT__"'
alias unproxy='unset {http,https,all,HTTP,HTTPS,ALL}_proxy; echo "Proxy disabled"'
EOF

  # 替换模板中的代理端口变量
  bashrc_content="${bashrc_content//__PROXY_PORT__/${PROXY_PORT}}"

  update_config_block "${USER_HOME}/.bashrc" "UBUNTU_SETUP_TERMINAL" "${bashrc_content}"
  log_success ".bashrc 幂等配置完成"
}

setup_github_hosts() {
  log_info "5. 配置 GitHub Hosts 加速"
  local temp_hosts="/tmp/github_hosts.txt"
  
  if curl -s -m 10 "${GITHUB_HOSTS_URL}" -o "${temp_hosts}"; then
    local hosts_content
    hosts_content="$(cat "${temp_hosts}")"
    update_config_block "/etc/hosts" "GITHUB_HOSTS_520" "${hosts_content}" "true"
    
    # 尝试刷新 DNS 缓存
    if command -v resolvectl >/dev/null 2>&1; then
      sudo resolvectl flush-caches || true
    elif command -v systemd-resolve >/dev/null 2>&1; then
      sudo systemd-resolve --flush-caches || true
    fi
    log_success "GitHub hosts 更新成功"
  else
    log_warning "GitHub hosts 获取失败 (网络超时), 跳过此步 (不影响主流程)"
  fi
  rm -f "${temp_hosts}"
}

install_cmake_securely() {
  log_info "6. 安全安装 CMake ${CMAKE_VERSION}"
  
  if command -v cmake >/dev/null 2>&1 && cmake --version | grep -q "${CMAKE_VERSION}"; then
    log_success "CMake ${CMAKE_VERSION} 已安装, 跳过"
    return 0
  fi

  # 使用 subshell 防止污染全局工作目录
  (
    cd /tmp || log_error "无法进入 /tmp 目录"
    
    local tar_file="cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}.tar.gz"
    local sha_file="cmake-${CMAKE_VERSION}-SHA-256.txt"
    
    # 下载归档文件与哈希文件
    log_info "正在下载 CMake 二进制文件与 SHA256 校验文件..."
    retry_command wget -q --show-progress -O "${tar_file}" "${CMAKE_BASE_URL}/${tar_file}"
    retry_command wget -q -O "${sha_file}" "${CMAKE_BASE_URL}/${sha_file}"

    # 供应链安全: 严格校验 SHA256
    log_info "正在校验文件完整性 (SHA256)..."
    if ! grep "${tar_file}" "${sha_file}" | sha256sum -c - >/dev/null 2>&1; then
      log_error "安全警报: CMake 包 SHA256 校验失败, 可能被篡改或下载不完整"
    fi
    log_success "校验通过"

    # 解压并部署
    tar -zxf "${tar_file}"
    sudo rm -rf "/opt/cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}"
    sudo mv "cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}" /opt/
    sudo ln -sf /opt/cmake-${CMAKE_VERSION}-linux-${SYS_ARCH}/bin/* /usr/local/bin/

    # 清理
    rm -f "${tar_file}" "${sha_file}"
  )
  log_success "CMake ${CMAKE_VERSION} 安全安装完成"
}

setup_samba() {
  log_info "7. 配置 Samba 共享服务"
  
  local smb_conf
  smb_conf="[Share]
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

  local is_interactive
  [[ -t 0 ]] && is_interactive=1 || is_interactive=0

  if [[ -n "${SAMBA_PASS:-}" ]]; then
    log_info "读取到环境变量 SAMBA_PASS, 执行非交互式配置..."
    echo -e "${SAMBA_PASS}\n${SAMBA_PASS}" | sudo smbpasswd -s -a "${CURRENT_USER}" >/dev/null 2>&1 || true
    sudo systemctl restart smbd
    log_success "Samba 密码设置及服务重启完成"
  elif [[ "${is_interactive}" -eq 1 ]]; then
    log_info "请为 Samba 共享用户 (${CURRENT_USER}) 设置访问密码 (直接回车可跳过):"
    
    # Interactive mode: rely on native smbpasswd secure prompt instead of capturing plain text variables
    if sudo smbpasswd -a "${CURRENT_USER}"; then
       sudo systemctl restart smbd
       log_success "Samba 密码设置完成"
    else
       log_warning "用户跳过了 Samba 密码设置或输入有误"
    fi
  else
    log_warning "检测到非交互模式且未提供环境变量 SAMBA_PASS, 跳过 Samba 密码设置"
  fi
}

setup_git() {
  log_info "8. 配置 Git 全局属性"
  
  local is_interactive
  [[ -t 0 ]] && is_interactive=1 || is_interactive=0

  if [[ -n "${GIT_NAME:-}" ]] && [[ -n "${GIT_EMAIL:-}" ]]; then
    log_info "通过环境变量静默配置 Git..."
    git config --global user.name "${GIT_NAME}"
    git config --global user.email "${GIT_EMAIL}"
    git config --global credential.helper store
    log_success "Git 已配置为: ${GIT_NAME} <${GIT_EMAIL}>"
  elif [[ "${is_interactive}" -eq 1 ]]; then
    echo -ne "${COLOR_CYAN}是否需要配置 Git 全局用户名和邮箱? (y/n) [n]: ${COLOR_NC}"
    local do_config
    read -r do_config
    do_config="${do_config:-n}"

    if [[ "${do_config}" =~ ^[Yy]$ ]]; then
      local g_name g_email
      read -r -p "请输入 Git 用户名 (user.name): " g_name
      read -r -p "请输入 Git 邮箱 (user.email): " g_email

      if [[ -n "${g_name}" ]] && [[ -n "${g_email}" ]]; then
        git config --global user.name "${g_name}"
        git config --global user.email "${g_email}"
        git config --global credential.helper store
        log_success "Git 身份已配置为: ${g_name} <${g_email}>"
      else
        log_warning "输入信息不完整, 已跳过 Git 配置"
      fi
    else
      log_warning "已跳过 Git 配置"
    fi
  else
    log_warning "非交互模式, 跳过 Git 配置"
  fi
}

# ==========================================
# 主程序入口
# ==========================================
main() {
  # 打印执行横幅
  echo -e "${COLOR_GREEN}==========================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}      Ubuntu 自动化初始化脚本 v${SCRIPT_VERSION}     ${COLOR_NC}"
  echo -e "${COLOR_GREEN}==========================================${COLOR_NC}"

  check_environment
  
  # 支持通过环境变量跳过某些耗时阶段
  [[ "${SKIP_APT:-0}" -eq 0 ]]   && setup_apt_mirrors
  [[ "${SKIP_TOOLS:-0}" -eq 0 ]] && update_system_and_tools
  [[ "${SKIP_BASHRC:-0}" -eq 0 ]] && setup_bashrc
  [[ "${SKIP_HOSTS:-0}" -eq 0 ]] && setup_github_hosts
  [[ "${SKIP_CMAKE:-0}" -eq 0 ]] && install_cmake_securely
  [[ "${SKIP_SAMBA:-0}" -eq 0 ]] && setup_samba
  [[ "${SKIP_GIT:-0}" -eq 0 ]]   && setup_git

  echo -e "\n${COLOR_GREEN}==========================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}✔ 系统配置脚本全部执行完毕!${COLOR_NC}"
  echo -e "请执行 ${COLOR_CYAN}source ~/.bashrc${COLOR_NC} 刷新终端生效"
  
  # 移除错误捕获, 正常退出
  trap - ERR
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi