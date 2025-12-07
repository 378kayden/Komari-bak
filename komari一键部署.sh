#!/bin/bash
set -uo pipefail
trap 'echo -e "${RED}❌ 脚本执行出错：$BASH_COMMAND 失败${NC}"; exit 1' ERR

# 核心配置
KOMARI_PORT="25774"
SSL_DIR="/etc/nginx/ssl"
ACME_DIR="$HOME/.acme.sh"
ACME_EXEC="${ACME_DIR}/acme.sh"
DOMAIN=""
EMAIL=""
KOMARI_USER="admin"
KOMARI_PWD=""
LOG_FILE="/tmp/komari_deploy.log"
RETRY_TIMES=3
TIMEOUT=30

# 界面美化配置（缩短横线）
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
PURPLE="\033[35m"
NC="\033[0m"
BOLD="\033[1m"
SUCCESS="${GREEN}✅ ${NC}"
INFO="${YELLOW}ℹ️ ${NC}"
ERROR="${RED}❌ ${NC}"
WARN="${YELLOW}⚠️ ${NC}"
TITLE="${BLUE}┌──────────────────────────┐${NC}"
SUBTITLE="${BLUE}│${NC}"
FOOTER="${BLUE}└──────────────────────────┘${NC}"

# 日志输出函数
log() {
    local MSG="$1"
    local DATE=$(date +%Y-%m-%d_%H:%M:%S)
    echo -e "${BOLD}[${DATE}]${NC} ${MSG}" | tee -a "${LOG_FILE}"
}

# 短分隔线（解决太长问题）
print_separator() {
    echo -e "\n${BLUE}────────────────────────────────${NC}\n" | tee -a "${LOG_FILE}"
}

# 展示关键信息（修复证书有效期显示）
show_key_info() {
    print_separator
    log "${BOLD}${PURPLE}🔍 部署前关键信息核对${NC}"
    echo -e "${TITLE}" | tee -a "${LOG_FILE}"
    # 服务器/基础信息
    local SERVER_IP=$(curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    local SERVER_OS=$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | sed 's/"//g')
    echo -e "${SUBTITLE} 服务器IP：${CYAN}${SERVER_IP}${NC}" | tee -a "${LOG_FILE}"
    echo -e "${SUBTITLE} Komari端口：${CYAN}${KOMARI_PORT}${NC}" | tee -a "${LOG_FILE}"
    echo -e "${SUBTITLE} 部署域名：${CYAN}${DOMAIN}${NC}" | tee -a "${LOG_FILE}"
    echo -e "${SUBTITLE} 证书邮箱：${CYAN}${EMAIL}${NC}" | tee -a "${LOG_FILE}"
    
    # 修复证书有效期显示（适配已存在的证书）
    if [ -f "${SSL_DIR}/${DOMAIN}.crt" ]; then
        local CERT_START=$(openssl x509 -in "${SSL_DIR}/${DOMAIN}.crt" -noout -startdate | cut -d= -f2)
        local CERT_END=$(openssl x509 -in "${SSL_DIR}/${DOMAIN}.crt" -noout -enddate | cut -d= -f2)
        # 计算剩余天数
        local END_TIMESTAMP=$(date -d "${CERT_END}" +%s 2>/dev/null)
        local NOW_TIMESTAMP=$(date +%s)
        if [ -n "${END_TIMESTAMP}" ] && [ "${END_TIMESTAMP}" -gt "${NOW_TIMESTAMP}" ]; then
            local CERT_DAYS=$(( (END_TIMESTAMP - NOW_TIMESTAMP) / 86400 ))
            echo -e "${SUBTITLE} 生效时间：${GREEN}${CERT_START}${NC}" | tee -a "${LOG_FILE}"
            echo -e "${SUBTITLE} 过期时间：${RED}${CERT_END}${NC}" | tee -a "${LOG_FILE}"
            echo -e "${SUBTITLE} 剩余有效期：${YELLOW}${CERT_DAYS} 天${NC}" | tee -a "${LOG_FILE}"
        else
            echo -e "${SUBTITLE} 证书状态：${WARN} 已存在（有效期请手动验证）${NC}" | tee -a "${LOG_FILE}"
        fi
    else
        echo -e "${SUBTITLE} 证书状态：${WARN} 待生成${NC}" | tee -a "${LOG_FILE}"
    fi
    echo -e "${FOOTER}" | tee -a "${LOG_FILE}"
}

# 确认继续函数
confirm_continue() {
    print_separator
    read -p "$(echo -e "${BOLD}${PURPLE}📋 是否继续部署Komari？(y/n)：${NC}")" CHOICE
    case "${CHOICE}" in
        [Yy]) log "${SUCCESS}确认继续部署";;
        [Nn]) log "${ERROR}用户取消部署，脚本退出"; exit 0;;
        *) log "${WARN}输入无效！请输入y/n"; confirm_continue;;
    esac
}

# 下载重试函数
retry_download() {
    local URL="$1"
    local OUTPUT="$2"
    local COUNT=0
    rm -f "${OUTPUT}"
    while [ ${COUNT} -lt ${RETRY_TIMES} ]; do
        if wget -q --timeout="${TIMEOUT}" --no-check-certificate "${URL}" -O "${OUTPUT}"; then
            if [[ "${OUTPUT}" == *.tar.gz ]] && ! tar -tzf "${OUTPUT}" >/dev/null 2>&1; then
                log "${ERROR}压缩包损坏：${OUTPUT}"; rm -f "${OUTPUT}"
            else
                log "${SUCCESS}下载成功：${URL}"; return 0
            fi
        fi
        COUNT=$((COUNT+1))
        log "${INFO}下载失败，3秒后重试（${COUNT}/${RETRY_TIMES}）"
        sleep 3
    done
    log "${ERROR}下载失败（重试${RETRY_TIMES}次）"; exit 1
}

# 端口占用检查
check_port_used() {
    if ss -tulpn | grep -q ":${KOMARI_PORT} "; then
        log "${ERROR}端口${KOMARI_PORT}已被占用"
        read -p "$(echo -e "${YELLOW}选择：1=换端口 2=停旧服务 (1/2)：${NC}")" CHOICE
        case "${CHOICE}" in
            1) for NEW_PORT in {25775..25800}; do
                if ! ss -tulpn | grep -q ":${NEW_PORT} "; then
                    KOMARI_PORT="${NEW_PORT}"; log "${SUCCESS}已换端口：${NEW_PORT}"; return 0
                fi
            done; log "${ERROR}无可用端口"; exit 1;;
            2) systemctl stop komari 2>/dev/null; pkill -f komari 2>/dev/null; log "${SUCCESS}已停旧服务";;
            *) log "${ERROR}输入无效"; exit 1;;
        esac
    fi
    log "${SUCCESS}端口${KOMARI_PORT}未被占用"
}

# 文件备份
backup_file() {
    local FILE="$1"
    if [ -f "${FILE}" ]; then
        local BACKUP_FILE="${FILE}.bak_$(date +%Y%m%d_%H%M%S)"
        cp -f "${FILE}" "${BACKUP_FILE}"
        log "${INFO}已备份配置：${BACKUP_FILE}"
    fi
}

# 修复apt环境
fix_apt_env() {
    print_separator
    log "${TITLE}${SUBTITLE} 修复apt环境 ${NC}${FOOTER}"
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null
    if [ -f "/etc/apt/sources.list" ]; then
        backup_file "/etc/apt/sources.list"
        cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
    fi
    apt update -y 2>/dev/null
    log "${SUCCESS}apt环境修复完成"
}

# 修复CA证书和时间
fix_ssl_ca_and_time() {
    print_separator
    log "${TITLE}${SUBTITLE} 修复CA证书/时间 ${NC}${FOOTER}"
    apt install -y ca-certificates ntpdate 2>/dev/null
    update-ca-certificates --fresh 2>/dev/null
    ntpdate pool.ntp.org 2>/dev/null || log "${INFO}时间同步失败（继续执行）"
    log "${SUCCESS}CA证书/时间修复完成"
}

# 安装acme.sh
install_acme_sh_manual() {
    print_separator
    log "${TITLE}${SUBTITLE} 安装acme.sh ${NC}${FOOTER}"
    mkdir -p "${ACME_DIR}"; chmod 700 "${ACME_DIR}"
    local DOWNLOAD_SOURCES=("https://cdn.jsdelivr.net/gh/acmesh-official/acme.sh@3.0.7/acme.sh")
    retry_download "${DOWNLOAD_SOURCES[0]}" "${ACME_EXEC}"
    chmod +x "${ACME_EXEC}"
    "${ACME_EXEC}" --set-default-ca --server zerossl 2>/dev/null
    "${ACME_EXEC}" --register-account -m "${EMAIL}" --force 2>/dev/null
    if ! crontab -l | grep -q "${ACME_EXEC} --cron"; then
        (crontab -l 2>/dev/null; echo "0 0 * * * ${ACME_EXEC} --cron --log ${LOG_FILE} > /dev/null") | crontab -
    fi
    log "${SUCCESS}acme.sh安装完成"
}

# 提取Komari密码
extract_komari_password() {
    print_separator
    log "${TITLE}${SUBTITLE} 提取Komari密码 ${NC}${FOOTER}"
    KOMARI_PWD=$(grep "初始登录信息" -A1 komari_install.log | grep -o "Password: [^, ]*" | awk '{print $2}')
    if [ -z "${KOMARI_PWD}" ]; then
        KOMARI_PWD=$(grep -E "Password: [A-Za-z0-9]+" komari_install.log | awk '{print $2}')
    fi
    if [ -z "${KOMARI_PWD}" ]; then
        log "${ERROR}自动提取失败！请从安装日志复制密码"
        KOMARI_PWD="请手动复制"
    else
        log "${SUCCESS}密码提取成功：${BOLD}${PURPLE}${KOMARI_PWD}${NC}"
    fi
}

# 检查Nginx Gzip模块
check_nginx_gzip_module() {
    print_separator
    log "${TITLE}${SUBTITLE} 检查Gzip模块 ${NC}${FOOTER}"
    NGINX_V_OUTPUT=$(nginx -V 2>&1)
    if echo "${NGINX_V_OUTPUT}" | grep -q -- "--with-http_gzip"; then
        log "${SUCCESS}Gzip模块已加载"
    else
        log "${INFO}Debian nginx-full默认包含Gzip功能"
    fi
}

# 强化Nginx配置
nginx_security_harden() {
    print_separator
    log "${TITLE}${SUBTITLE} 强化Nginx配置 ${NC}${FOOTER}"
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm -f "/etc/nginx/sites-enabled/default"; log "${SUCCESS}已删默认配置"
    fi
    if ! grep -q "X-XSS-Protection" /etc/nginx/conf.d/komari.conf; then
        sed -i '/listen \[::\]:443 ssl http2;/a \    add_header X-XSS-Protection "1; mode=block" always;' /etc/nginx/conf.d/komari.conf
        log "${SUCCESS}已加安全响应头"
    fi
}

# Nginx速度测试
nginx_speed_test() {
    print_separator
    log "${TITLE}${SUBTITLE} 测试Nginx速度 ${NC}${FOOTER}"
    local TEST_URL="https://${DOMAIN}/admin"
    apt install -y apache2-utils 2>/dev/null
    # 基础响应时间
    local TOTAL_TIME=0; local VALID_COUNT=0
    for i in {1..3}; do
        local RESP_TIME=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 "${TEST_URL}")
        if [ -n "${RESP_TIME}" ] && [ "${RESP_TIME}" != "0.000000" ]; then
            TOTAL_TIME=$(echo "${TOTAL_TIME} + ${RESP_TIME}" | bc -l)
            VALID_COUNT=$((VALID_COUNT+1))
            log "${INFO}第${i}次响应：${CYAN}${RESP_TIME}秒${NC}"
        fi
        sleep 1
    done
    if [ ${VALID_COUNT} -gt 0 ]; then
        local AVG_TIME=$(echo "scale=3; ${TOTAL_TIME}/${VALID_COUNT}" | bc -l)
        log "${SUCCESS}平均响应：${GREEN}${AVG_TIME}秒${NC}"
    fi
    # 并发测试
    ab -n 100 -c 10 -s 10 "${TEST_URL}" > /tmp/ab.log 2>&1
    if [ $? -eq 0 ]; then
        local RPS=$(grep "Requests per second" /tmp/ab.log | awk '{print $4}')
        log "${SUCCESS}每秒请求：${CYAN}${RPS} req/s${NC}"
    fi
    # Gzip验证
    local GZIP_CHECK=$(curl -s -L -I -H "Accept-Encoding: gzip" "${TEST_URL}" | grep -i "Content-Encoding")
    if [ -n "${GZIP_CHECK}" ]; then
        log "${SUCCESS}Gzip已生效：${GREEN}${GZIP_CHECK}${NC}"
    else
        log "${INFO}Gzip配置已开启（Debian特性）"
    fi
    rm -f /tmp/ab.log
}

# 清理冗余
clean_redundant() {
    print_separator
    log "${TITLE}${SUBTITLE} 清理冗余文件 ${NC}${FOOTER}"
    rm -rf "${ACME_DIR}/tmp" komari_install.log 2>/dev/null
    chmod -R 600 "${SSL_DIR}"
    systemctl reload nginx 2>/dev/null
    log "${SUCCESS}清理完成"
}

# 验证SSL证书
verify_ssl_cert() {
    print_separator
    log "${TITLE}${SUBTITLE} 验证SSL证书 ${NC}${FOOTER}"
    if openssl x509 -in "${SSL_DIR}/${DOMAIN}.crt" -noout -checkend 86400 2>/dev/null; then
        log "${SUCCESS}证书有效（剩余>24小时）"
    else
        log "${ERROR}证书无效！"; exit 1
    fi
}

# ===================== 主流程 =====================
clear
print_separator
log "${BOLD}${PURPLE}🚀 Komari 一键部署脚本${NC}"
print_separator

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
    log "${ERROR}请用root权限运行（sudo ./脚本名.sh）"; exit 1
fi

# 端口检查
check_port_used

# 简化输入：仅保留域名+邮箱（加解析提示）
log "${INFO}请先解析域名到本服务器公网IP"
read -p "$(echo -e "${SUCCESS}请输入你的域名：${NC}")" DOMAIN
while [ -z "${DOMAIN}" ] || ! echo "${DOMAIN}" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; do
    log "${ERROR}域名格式错误！请输入如tz.2z99.com"
    read -p "$(echo -e "${SUCCESS}请输入你的域名：${NC}")" DOMAIN
done
log "${SUCCESS}域名确认：${DOMAIN}"

read -p "$(echo -e "${SUCCESS}请输入你的邮箱：${NC}")" EMAIL
while [ -z "${EMAIL}" ] || ! echo "${EMAIL}" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; do
    log "${ERROR}邮箱格式错误！请输入如xxx@xxx.com"
    read -p "$(echo -e "${SUCCESS}请输入你的邮箱：${NC}")" EMAIL
done
log "${SUCCESS}邮箱确认：${EMAIL}"

# 修复apt环境
fix_apt_env

# 修复CA证书和时间
fix_ssl_ca_and_time

# 安装基础工具
print_separator
log "${TITLE}${SUBTITLE} 安装基础工具 ${NC}${FOOTER}"
apt install -y curl wget nano nginx-full socat cron openssl 2>/dev/null
log "${SUCCESS}基础工具安装完成"

# 检查Gzip模块
check_nginx_gzip_module

# 安装acme.sh
if [ ! -f "${ACME_EXEC}" ]; then
    install_acme_sh_manual
else
    log "${SUCCESS}acme.sh已安装"
fi

# 申请SSL证书
print_separator
log "${TITLE}${SUBTITLE} 申请SSL证书 ${NC}${FOOTER}"
ACME_CERT_PATH="${ACME_DIR}/${DOMAIN}_ecc"
if [ ! -d "${ACME_CERT_PATH}" ]; then
    systemctl stop nginx 2>/dev/null
    "${ACME_EXEC}" --issue -d "${DOMAIN}" --standalone -k ec-256 --force 2>/dev/null
    systemctl start nginx 2>/dev/null
    log "${SUCCESS}证书申请成功"
else
    log "${SUCCESS}证书已存在"
fi

# 配置证书
mkdir -p "${SSL_DIR}"
cp -f "${ACME_CERT_PATH}/${DOMAIN}.key" "${SSL_DIR}/"
cp -f "${ACME_CERT_PATH}/fullchain.cer" "${SSL_DIR}/${DOMAIN}.crt"
chmod 600 "${SSL_DIR}/${DOMAIN}.key"
verify_ssl_cert

# 部署前展示信息+确认
show_key_info
confirm_continue

# 安装Komari
print_separator
log "${TITLE}${SUBTITLE} 安装Komari ${NC}${FOOTER}"
if [ -f "/opt/komari/komari" ]; then
    read -p "$(echo -e "${YELLOW}Komari已安装，是否覆盖？(y/n)：${NC}")" CHOICE
    if [ "${CHOICE}" = "y" ]; then
        systemctl stop komari 2>/dev/null; pkill -f komari 2>/dev/null
        retry_download "https://raw.githubusercontent.com/komari-monitor/komari/main/install-komari.sh" "install-komari.sh"
        chmod +x install-komari.sh; ./install-komari.sh -q 2>&1 | tee komari_install.log
        log "${SUCCESS}Komari覆盖完成"
    else
        log "${SUCCESS}跳过Komari安装"
    fi
else
    retry_download "https://raw.githubusercontent.com/komari-monitor/komari/main/install-komari.sh" "install-komari.sh"
    chmod +x install-komari.sh; ./install-komari.sh -q 2>&1 | tee komari_install.log
    log "${SUCCESS}Komari全新安装完成"
fi

# 提取密码
extract_komari_password

# 配置Komari服务
print_separator
log "${TITLE}${SUBTITLE} 配置Komari服务 ${NC}${FOOTER}"
backup_file "/etc/systemd/system/komari.service"
cat > /etc/systemd/system/komari.service << EOF
[Unit]
Description=Komari Monitor
After=network.target nginx.service

[Service]
Type=simple
ExecStart=/opt/komari/komari server -l 0.0.0.0:${KOMARI_PORT}
Restart=on-failure
RestartSec=3
User=root
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload 2>/dev/null
systemctl restart komari 2>/dev/null; systemctl enable komari 2>/dev/null
if systemctl is-active --quiet komari; then
    log "${SUCCESS}Komari服务已启动"
else
    log "${ERROR}Komari启动失败！查看日志：${LOG_FILE}"
fi

# 配置Nginx
print_separator
log "${TITLE}${SUBTITLE} 配置Nginx ${NC}${FOOTER}"
backup_file "/etc/nginx/nginx.conf"
backup_file "/etc/nginx/conf.d/komari.conf"
cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 10240;
    use epoll;
}

http {
    gzip on;
    gzip_vary on;
    gzip_comp_level 9;
    gzip_min_length 1;
    gzip_types *;
    gzip_static on;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" "\$http_user_agent"';
    access_log /var/log/nginx/access.log main;
    include /etc/nginx/mime.types;
    include /etc/nginx/conf.d/*.conf;
}
EOF
cat > /etc/nginx/conf.d/komari.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate ${SSL_DIR}/${DOMAIN}.crt;
    ssl_certificate_key ${SSL_DIR}/${DOMAIN}.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        gzip on;
        proxy_pass http://127.0.0.1:${KOMARI_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
nginx_security_harden
if nginx -t 2>/dev/null; then
    systemctl restart nginx 2>/dev/null; log "${SUCCESS}Nginx已重启"
else
    log "${ERROR}Nginx配置错误！执行nginx -t查看"
fi

# 测试服务状态
print_separator
log "${TITLE}${SUBTITLE} 服务状态测试 ${NC}${FOOTER}"
if systemctl is-active --quiet komari && systemctl is-active --quiet nginx; then
    log "${SUCCESS}Komari+Nginx均运行正常"
    nginx_speed_test
else
    log "${ERROR}服务未正常运行！"
fi

# 清理冗余
clean_redundant

# 部署完成汇总
print_separator
log "${BOLD}${PURPLE}🎉 部署完成！${NC}"
echo -e "${TITLE}" | tee -a "${LOG_FILE}"
echo -e "${SUBTITLE} 访问地址：${GREEN}https://${DOMAIN}/admin${NC}" | tee -a "${LOG_FILE}"
echo -e "${SUBTITLE} 登录账号：${CYAN}${KOMARI_USER}${NC}" | tee -a "${LOG_FILE}"
echo -e "${SUBTITLE} 登录密码：${RED}${KOMARI_PWD}${NC}" | tee -a "${LOG_FILE}"
echo -e "${SUBTITLE} ${WARN} 请立即修改默认密码${NC}" | tee -a "${LOG_FILE}"
echo -e "${FOOTER}" | tee -a "${LOG_FILE}"
print_separator
