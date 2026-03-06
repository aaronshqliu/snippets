#!/bin/bash

# 开启严格模式: 遇到错误、未定义变量或管道错误即刻停止
set -euo pipefail

# 定义日志打印函数
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 恢复默认颜色

info()    { echo -e "${CYAN}▶ $1${NC}"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }
error()   { echo -e "${RED}✖ $1${NC}"; exit 1; }

# 全局错误捕获机制: 一旦发生未预期的非0退出, 自动打印行号
trap 'echo -e "${RED}✖ 严重错误: 脚本在第 $LINENO 行执行失败退出! 请检查上述报错信息${NC}"' ERR

# 禁止以 root 身份或通过 sudo 直接运行该脚本
if [ "$EUID" -eq 0 ]; then
    error "请不要使用 sudo 运行此脚本! \n正确用法: ./ubuntu_setup.sh\n脚本会在需要管理员权限时自动提示你输入密码"
fi

info "===== 1. 获取当前用户 ====="
USERNAME=$(whoami)
HOME_DIR=$(eval echo "~$USERNAME")

echo "当前用户: $USERNAME"
echo "家目录: $HOME_DIR"
success "环境检查通过"

info "===== 2. 优化 APT 镜像源 (清华源) ====="
UBUNTU_CODENAME=$(lsb_release -cs)

if [ -f "/etc/apt/sources.list.d/ubuntu.sources" ]; then
    if [ ! -f "/etc/apt/sources.list.d/ubuntu.sources.bak" ]; then
        sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
    fi
    sudo tee /etc/apt/sources.list.d/ubuntu.sources > /dev/null <<EOF
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/ubuntu/
Suites: $UBUNTU_CODENAME $UBUNTU_CODENAME-updates $UBUNTU_CODENAME-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/ubuntu/
Suites: $UBUNTU_CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    success "APT (DEB822) 源配置成功"
else
    if [ ! -f "/etc/apt/sources.list.bak" ]; then
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
    success "APT (sources.list) 源配置成功"
fi

info "===== 3. 更新系统 ====="
sudo apt clean
sudo apt update || error "APT 更新失败, 请检查网络"
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y || error "APT 升级失败"
success "系统更新成功"

info "===== 4. 安装基础工具与开发工具 ====="
sudo apt install -y \
    vim git curl wget zip unzip tree build-essential ninja-build \
    python3-pip pipx libssl-dev valgrind samba samba-common \
    openssh-server gnome-tweaks || error "基础工具与开发工具安装失败"
success "基础工具与开发工具安装完成"

info "===== 5. 配置 .bashrc ====="
if ! grep -q "parse_git_info()" "$HOME_DIR/.bashrc"; then
cat << 'EOF' >> "$HOME_DIR/.bashrc"

# ===========================
# Git Info & Terminal Theme
# ===========================
parse_git_info() {
  local branch dirty ahead behind status behind_count ahead_count
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || branch=$(git rev-parse --short HEAD 2>/dev/null) || return
  dirty=""
  if [ -n "$(git status --porcelain 2>/dev/null | head -n 1)" ]; then
    dirty="*"
  fi
  ahead=""
  behind=""
  status=$(git rev-list --left-right --count @{upstream}...HEAD 2>/dev/null)
  if [ -n "$status" ]; then
    read -r behind_count ahead_count <<< "$status"
    [ "$ahead_count" -gt 0 ] && ahead="↑"
    [ "$behind_count" -gt 0 ] && behind="↓"
  fi
  printf " \001\e[36m\002(%s%s%s%s)" "$branch" "$dirty" "$ahead" "$behind"
}

export PS1="\[\e[1;32m\]\u\[\e[m\]@\[\e[1;31m\]\h\[\e[m\]:\[\e[33m\]\w\$(parse_git_info)\[\e[m\]\n$ "

# ===========================
# Proxy Aliases
# ===========================
alias proxy='
export {http,https,all,HTTP,HTTPS,ALL}_proxy="http://127.0.0.1:7890";
echo "Proxy enabled → http://127.0.0.1:7890"
'

alias unproxy='
unset {http,https,all,HTTP,HTTPS,ALL}_proxy;
echo "Proxy disabled"
'
EOF
    success ".bashrc 配置已追加"
else
    success ".bashrc 已经配置过, 跳过"
fi

info "===== 6. 国内访问 GitHub ====="
# 这里如果 raw.hellogithub.com 被墙可能导致 curl 失败
sudo sh -c 'sed -i "/# GitHub520 Host Start/Q" /etc/hosts'
if curl -s -m 10 https://raw.hellogithub.com/hosts | sudo tee -a /etc/hosts > /dev/null; then
    # 刷新 DNS
    sudo resolvectl flush-caches || sudo systemd-resolve --flush-caches || true
    success "GitHub hosts 更新成功"
else
    echo -e "${YELLOW}警告: GitHub hosts 更新失败 (网络超时), 跳过此步${NC}"
fi

info "===== 7. 安装 CMake ====="
CMAKE_VERSION="4.1.5"
if command -v cmake >/dev/null 2>&1; then
    success "CMake 已安装: $(cmake --version | head -n 1)"
else
    cd /tmp
    rm -f cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz*
    echo "正在下载 CMake ${CMAKE_VERSION} (可能受 GitHub 网络影响, 请耐心等待)..."
    wget -O "cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz" -q --show-progress https://gh-proxy.org/https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz \
    || error "CMake 下载失败! \n建议: 1. 执行 \`proxy\` 命令开启终端代理后再运行脚本. 2. 手动下载后放在 /tmp 目录下"

    echo "下载完毕, 开始解压..."
    tar -zxvf cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz > /dev/null || error "解压 CMake 压缩包失败"

    sudo rm -rf "/opt/cmake-${CMAKE_VERSION}-linux-x86_64"
    sudo mv "cmake-${CMAKE_VERSION}-linux-x86_64" /opt/ || error "移动 CMake 到 /opt 失败"
    sudo ln -sf /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/* /usr/local/bin/ || error "创建 CMake 软链接失败"

    rm "cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"
    success "CMake ${CMAKE_VERSION} 安装成功"
fi

# 检查当前是否在交互式终端中 (判断标准输入是否连接到了终端)
if [ -t 0 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

info "===== 8. 配置 Samba ====="
if ! grep -q "\[Share\]" /etc/samba/smb.conf; then
sudo bash -c "cat << EOF >> /etc/samba/smb.conf
[Share]
   comment = Shared Folder
   path = $HOME_DIR
   valid users = $USERNAME
   directory mask = 0775
   create mask = 0775
   public = yes
   writable = yes
   available = yes
   browseable = yes
EOF"
    success "Samba 配置已写入"
else
    success "Samba 已经配置过, 跳过写入"
fi

if [ -n "${SAMBA_PASS:-}" ]; then
    echo "读取到环境变量 SAMBA_PASS, 执行自动配置..."
elif [ "$INTERACTIVE" -eq 1 ]; then
    echo -e "${CYAN}请为 Samba 共享用户 ($USERNAME) 设置访问密码${NC}"

    # 开启循环, 直到两次输入一致或用户放弃
    while true; do
        read -s -p "请输入密码 (直接回车可跳过设置): " SAMBA_PASS
        echo ""

        # 如果用户直接按了回车, 留空跳过
        if [ -z "$SAMBA_PASS" ]; then
            echo -e "${YELLOW}用户选择跳过 Samba 密码设置。${NC}"
            break
        fi

        read -s -p "请再次确认密码: " SAMBA_PASS_CONFIRM
        echo ""

        if [ "$SAMBA_PASS" == "$SAMBA_PASS_CONFIRM" ]; then
            break # 密码一致, 跳出循环
        else
            echo -e "${RED}✖ 两次输入的密码不一致, 请重新输入! ${NC}"
        fi
    done
else
    echo -e "${YELLOW}检测到非交互模式且未提供环境变量, 跳过 Samba 密码设置。${NC}"
    SAMBA_PASS=""
fi

# 只有当 SAMBA_PASS 不为空时, 才执行设置密码的操作
if [ -n "$SAMBA_PASS" ]; then
    (echo -e "$SAMBA_PASS\n$SAMBA_PASS" | sudo smbpasswd -s -a "$USERNAME") > /dev/null 2>&1 || true
    sudo systemctl restart smbd
    success "Samba 密码设置及服务重启完成"
else
    success "Samba 服务已启动 (未设置密码)"
    echo -e "提示: 以后可随时执行 ${CYAN}sudo smbpasswd -a $USERNAME${NC} 手动设置密码。"
fi

info "===== 9. 配置 Git ====="
if [ -n "${GIT_NAME:-}" ] &&[ -n "${GIT_EMAIL:-}" ]; then
    echo "读取到环境变量，自动配置 Git..."
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global credential.helper store
    success "Git 已配置为: $GIT_NAME <$GIT_EMAIL>"
elif [ "$INTERACTIVE" -eq 1 ]; then
    echo -ne "${CYAN}是否需要配置 Git 全局用户名和邮箱? (y/n) [n]: ${NC}"
    read -r DO_GIT_CONFIG
    DO_GIT_CONFIG=${DO_GIT_CONFIG:-n}

    if [[ "$DO_GIT_CONFIG" =~ ^[Yy]$ ]]; then
        read -p "请输入 Git 用户名 (user.name): " GIT_NAME
        read -p "请输入 Git 邮箱 (user.email): " GIT_EMAIL

        if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
            git config --global user.name "$GIT_NAME"
            git config --global user.email "$GIT_EMAIL"
            git config --global credential.helper store
            success "Git 身份已配置为: $GIT_NAME <$GIT_EMAIL>"
        else
            echo -e "${YELLOW}输入为空，已跳过 Git 配置${NC}"
        fi
    else
        echo -e "${YELLOW}已跳过 Git 配置${NC}"
    fi
else
    echo -e "${YELLOW}非交互模式，已跳过 Git 配置${NC}"
fi

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}系统配置脚本全部执行完毕!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo -e "请执行 ${CYAN}source ~/.bashrc${NC} 刷新终端, 或重新打开终端即可生效"

# 移除 trap, 以免脚本正常退出时触发报错逻辑
trap - ERR