#!/bin/bash
# ============================================================
#  一键配置 Debian SSH Root 密钥登录脚本
#  支持系统: Debian 9/10/11/12
#  功能: 生成 ED25519 密钥对，配置 root 密钥登录，输出私钥
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

BANNER() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║     Debian SSH Root 密钥登录 一键配置脚本        ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

LOG_INFO()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
LOG_WARN()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
LOG_ERROR()   { echo -e "${RED}[ERROR]${NC} $*"; }
LOG_STEP()    { echo -e "${BLUE}[STEP]${NC}  $*"; }

# ── 检查 root 权限 ──────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        LOG_ERROR "此脚本必须以 root 身份运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

# ── 检查系统 ────────────────────────────────────────────────
check_system() {
    if [[ ! -f /etc/debian_version ]]; then
        LOG_WARN "未检测到 Debian 系统，脚本仍将继续尝试执行..."
    else
        local ver
        ver=$(cat /etc/debian_version)
        LOG_INFO "检测到 Debian 版本: ${ver}"
    fi
}

# ── 安装 openssh-server（如未安装）──────────────────────────
ensure_sshd() {
    LOG_STEP "检查 OpenSSH Server 是否已安装..."
    if ! command -v sshd &>/dev/null; then
        LOG_WARN "未找到 sshd，正在安装 openssh-server..."
        apt-get update -qq
        apt-get install -y openssh-server
        LOG_INFO "openssh-server 安装完成"
    else
        LOG_INFO "OpenSSH Server 已安装: $(sshd -V 2>&1 | head -1)"
    fi
}

# ── 备份 sshd_config ────────────────────────────────────────
backup_sshd_config() {
    local cfg="/etc/ssh/sshd_config"
    local bak="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
    LOG_STEP "备份 sshd 配置文件 -> ${bak}"
    cp "$cfg" "$bak"
    LOG_INFO "备份完成: ${bak}"
}

# ── 修改 sshd_config ────────────────────────────────────────
configure_sshd() {
    local cfg="/etc/ssh/sshd_config"
    LOG_STEP "配置 /etc/ssh/sshd_config ..."

    # 设置或替换指令的通用函数
    set_sshd_option() {
        local key="$1"
        local val="$2"
        if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "$cfg"; then
            sed -i -E "s|^#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|g" "$cfg"
        else
            echo "${key} ${val}" >> "$cfg"
        fi
    }

    set_sshd_option "PermitRootLogin"       "yes"
    set_sshd_option "PubkeyAuthentication"  "yes"
    set_sshd_option "AuthorizedKeysFile"    ".ssh/authorized_keys"
    # PasswordAuthentication 保持原有设置，不做修改（保留密码登录用于测试）

    LOG_INFO "sshd_config 已更新"
}

# ── 生成 ED25519 密钥对 ─────────────────────────────────────
generate_keypair() {
    local key_dir="/root/.ssh"
    KEY_FILE="${key_dir}/id_ed25519_root_$(date +%Y%m%d%H%M%S)"

    LOG_STEP "生成 ED25519 密钥对..."
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"

    ssh-keygen -t ed25519 -C "root@$(hostname)-$(date +%Y%m%d)" \
               -f "$KEY_FILE" -N "" -q

    chmod 600 "${KEY_FILE}"
    chmod 644 "${KEY_FILE}.pub"

    LOG_INFO "私钥路径: ${KEY_FILE}"
    LOG_INFO "公钥路径: ${KEY_FILE}.pub"
}

# ── 将公钥写入 authorized_keys ──────────────────────────────
install_pubkey() {
    local auth_keys="/root/.ssh/authorized_keys"
    LOG_STEP "将公钥写入 ${auth_keys} ..."

    touch "$auth_keys"
    chmod 600 "$auth_keys"

    local pubkey
    pubkey=$(cat "${KEY_FILE}.pub")

    # 避免重复写入
    if ! grep -qF "$pubkey" "$auth_keys" 2>/dev/null; then
        echo "$pubkey" >> "$auth_keys"
        LOG_INFO "公钥已写入 authorized_keys"
    else
        LOG_WARN "公钥已存在于 authorized_keys，跳过写入"
    fi
}

# ── 重启 SSH 服务 ────────────────────────────────────────────
restart_sshd() {
    LOG_STEP "重启 SSH 服务..."
    if systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart ssh
        LOG_INFO "ssh 服务已重启 (systemctl restart ssh)"
    elif systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd
        LOG_INFO "sshd 服务已重启 (systemctl restart sshd)"
    else
        # 首次启动
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl start  ssh 2>/dev/null || systemctl start  sshd 2>/dev/null || true
        LOG_INFO "SSH 服务已启动"
    fi
}

# ── 验证配置 ─────────────────────────────────────────────────
verify_config() {
    LOG_STEP "验证 sshd 配置..."
    if sshd -t 2>/dev/null; then
        LOG_INFO "sshd 配置语法检查通过 ✓"
    else
        LOG_ERROR "sshd 配置存在错误，请检查 /etc/ssh/sshd_config"
        exit 1
    fi
}

# ── 输出私钥内容 ─────────────────────────────────────────────
output_private_key() {
    echo ""
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✅  配置完成！以下是您的 SSH 私钥（请妥善保管）${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}# 私钥文件路径: ${KEY_FILE}${NC}"
    echo -e "${YELLOW}# 请将以下内容完整保存为本地 .pem 或 .key 文件${NC}"
    echo ""
    cat "${KEY_FILE}"
    echo ""
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}使用方法:${NC}"

    # 获取服务器 IP
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$server_ip" ]] && server_ip="<服务器IP>"

    # 获取 SSH 端口
    local ssh_port
    ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [[ -z "$ssh_port" ]] && ssh_port="22"

    echo ""
    echo -e "  ${GREEN}1. 将上方私钥保存到本地文件，例如: ~/root_key.pem${NC}"
    echo -e "  ${GREEN}2. 修改权限: chmod 600 ~/root_key.pem${NC}"
    echo -e "  ${GREEN}3. 连接服务器:${NC}"
    echo ""
    echo -e "     ${BOLD}ssh -i ~/root_key.pem -p ${ssh_port} root@${server_ip}${NC}"
    echo ""
    echo -e "${YELLOW}💡 当前密码登录仍保持开启，测试密钥可以正常登录后，再执行以下命令关闭密码登录:${NC}"
    echo ""
    echo -e "     ${BOLD}sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl restart ssh${NC}"
    echo ""
}

# ── 主流程 ───────────────────────────────────────────────────
main() {
    BANNER
    check_root
    check_system
    ensure_sshd
    backup_sshd_config
    configure_sshd
    verify_config
    generate_keypair
    install_pubkey
    restart_sshd
    output_private_key
}

main "$@"
