#!/bin/bash
set -e

# ==============================================================================
# BaiduNetdisk ReduceCPUusage - 一键智能休眠与无感唤醒补丁 (Scale-to-Zero)
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CONTAINER_NAME="${REDUCECPU_CONTAINER:-baidunetdisk}"
INSTALL_DIR="/opt/baidunetdisk-reduceCPUusage"
SERVICE_NAME="baidunetdisk-reduceCPUusage"
DEFAULT_WAKE_PORT=5802
DEFAULT_WEB_PORT=5800

# 官方验证适配的镜像列表
SUPPORTED_IMAGES=("johngong/baidunetdisk")

echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  BaiduNetdisk ReduceCPUusage 安装向导 / Patch Installer       ${NC}"
echo -e "${GREEN}================================================================${NC}"

# 1. 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}[ERROR] 请使用 root 用户或 sudo 执行此脚本！${NC}"
    exit 1
fi

# 2. 检查依赖
for cmd in docker python3 ss systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 缺少必要组件: $cmd，请先安装！${NC}"
        exit 1
    fi
done

# 3. 检查百度网盘容器是否存在
if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] 未检测到名为 '$CONTAINER_NAME' 的 Docker 容器！${NC}"
    echo -e "${YELLOW}如果你的容器名不同，请先指定环境变量: export REDUCECPU_CONTAINER=你的容器名${NC}"
    exit 1
fi

# 4. 镜像一致性与兼容性校验
CURRENT_IMAGE=$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}' 2>/dev/null || true)
echo -e "检测到目标容器当前镜像: ${YELLOW}$CURRENT_IMAGE${NC}"

MATCHED=0
for sup in "${SUPPORTED_IMAGES[@]}"; do
    if [[ "$CURRENT_IMAGE" == *"$sup"* ]]; then
        MATCHED=1
        break
    fi
done

if [ "$MATCHED" -eq 1 ]; then
    echo -e "${GREEN}[OK] 镜像校验通过 (已认证兼容镜像: $CURRENT_IMAGE)${NC}"
else
    echo -e "${RED}[WARN] 警告：当前镜像 '$CURRENT_IMAGE' 未在经过严格兼容性认证的列表中！${NC}"
    echo -e "${YELLOW}已认证支持的镜像为: ${SUPPORTED_IMAGES[*]}${NC}"
    
    if [ "${SKIP_IMAGE_CHECK:-false}" != "true" ]; then
        if [ -t 0 ]; then
            read -r -p "是否仍然强制继续安装？[y/N]: " choice
            case "$choice" in
                [yY][eE][sS]|[yY]) echo -e "${YELLOW}用户选择强制继续安装...${NC}" ;;
                *) echo -e "${RED}[ABORT] 安装已由用户终止。${NC}"; exit 1 ;;
            esac
        else
            echo -e "${RED}[ERROR] 非交互模式下镜像不匹配，安装终止。如需强制安装，请设置 export SKIP_IMAGE_CHECK=true${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}[INFO] 检测到 SKIP_IMAGE_CHECK=true，跳过镜像一致性校验继续安装...${NC}"
    fi
fi

# 5. 探查环境是否存在 Nginx 反向代理
echo -e "${YELLOW}[1/4] 检测网络拓扑与反向代理环境...${NC}"
NGINX_CONF=""
SEARCH_DIRS=("/home/web/conf.d" "/etc/nginx/conf.d" "/etc/nginx/sites-enabled" "/www/server/panel/vhost/nginx")

for d in "${SEARCH_DIRS[@]}"; do
    if [ -d "$d" ]; then
        FOUND=$(grep -rn "127.0.0.1:$DEFAULT_WEB_PORT" "$d" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
        if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
            NGINX_CONF="$FOUND"
            break
        fi
    fi
done

ENABLE_DIRECT="false"
DIRECT_PORT="$DEFAULT_WEB_PORT"
BACKEND_PORT="58000"

if [ -n "$NGINX_CONF" ]; then
    echo -e "${GREEN}[OK] 检测到已配置的 Nginx 反向代理: $NGINX_CONF${NC}"
    MODE="nginx"
else
    echo -e "${YELLOW}[INFO] 未检测到反代 $DEFAULT_WEB_PORT 的 Nginx 配置文件。${NC}"
    echo -e "${GREEN}--> 自动启用【直连模式 / 透明网桥唤醒】 (无需反向代理，直接访问 IP:$DEFAULT_WEB_PORT 即可自动唤醒)${NC}"
    MODE="direct"
    ENABLE_DIRECT="true"

    # 在直连模式下，需要将容器现有映射端口避让给 sentinel 透明网桥
    HOST_BINDING=$(docker inspect "$CONTAINER_NAME" --format '{{range $p, $conf := .HostConfig.PortBindings}}{{if eq $p "5800/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' 2>/dev/null || true)
    if [ "$HOST_BINDING" = "5800" ]; then
        echo -e "${YELLOW}检测到容器直接占用了宿主机 5800 端口。正在调整映射至内部 58000 端口以启用自愈透明网桥...${NC}"
        # 获取原有容器创建配置
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        # 兼容性热修改 hostconfig.json 端口映射
        CONTAINER_ID=$(docker inspect "$CONTAINER_NAME" --format '{{.Id}}')
        CONFIG_FILE="/var/lib/docker/containers/${CONTAINER_ID}/hostconfig.json"
        if [ -f "$CONFIG_FILE" ]; then
            systemctl stop docker
            sed -i 's/"5800\/tcp":\[{"HostIp":"","HostPort":"5800"}\]/"5800\/tcp":[{"HostIp":"127.0.0.1","HostPort":"58000"}]/g' "$CONFIG_FILE"
            systemctl start docker
            docker start "$CONTAINER_NAME" >/dev/null 2>&1
            echo -e "${GREEN}[OK] 端口已安全平移至内部 127.0.0.1:58000，外部 5800 交由智能看门狗监听！${NC}"
        fi
    fi
fi

# 6. 创建安装目录并安装 sentinel.py
echo -e "${YELLOW}[2/4] 部署后台看门狗守护程序...${NC}"
mkdir -p "$INSTALL_DIR"

if [ -f "$(dirname "$0")/sentinel.py" ]; then
    cp "$(dirname "$0")/sentinel.py" "$INSTALL_DIR/sentinel.py"
else
    REPO_USER="${GITHUB_USER:-redcats2}"
    REPO_NAME="baidunetdisk-reduceCPUusage"
    echo "从远程源拉取 sentinel.py..."
    curl -sSL -o "$INSTALL_DIR/sentinel.py" "https://raw.githubusercontent.com/$REPO_USER/$REPO_NAME/main/sentinel.py" || {
        echo -e "${RED}[ERROR] 无法获取 sentinel.py，请检查网络或源码！${NC}"
        exit 1
    }
fi
chmod +x "$INSTALL_DIR/sentinel.py"

# 7. 注册并启动 Systemd 服务
echo -e "${YELLOW}[3/4] 配置并启动 Systemd 守护服务...${NC}"
cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=BaiduNetdisk ReduceCPUusage Service
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/sentinel.py
Restart=always
RestartSec=5
Environment=REDUCECPU_CONTAINER_NAME=$CONTAINER_NAME
Environment=REDUCECPU_WAKE_PORT=$DEFAULT_WAKE_PORT
Environment=REDUCECPU_WEB_PORT=$DEFAULT_WEB_PORT
Environment=REDUCECPU_SPEED_KB=30
Environment=REDUCECPU_IDLE_SECONDS=180
Environment=REDUCECPU_DIRECT_PROXY=$ENABLE_DIRECT
Environment=REDUCECPU_DIRECT_PORT=$DIRECT_PORT
Environment=REDUCECPU_BACKEND_PORT=$BACKEND_PORT

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
echo -e "${GREEN}[OK] 守护服务已成功启动！${NC}"

# 8. 如果是 Nginx 模式，配置 Nginx 钩子
if [ "$MODE" = "nginx" ]; then
    echo -e "${YELLOW}[4/4] 配置 Nginx 反向代理唤醒钩子...${NC}"
    if grep -q "_wake_reducecpu" "$NGINX_CONF" || grep -q "_wake_sentinel" "$NGINX_CONF"; then
        echo -e "${YELLOW}Nginx 配置已经包含唤醒钩子，跳过修改。${NC}"
    else
        cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        awk '
        /\/_wake_reducecpu/ { found=1 }
        /location \/ \{/ && !injected {
            print "    # [BaiduNetdisk ReduceCPUusage Wake Hook]"
            print "    location = /_wake_reducecpu {"
            print "        internal;"
            print "        proxy_pass http://127.0.0.1:'"$DEFAULT_WAKE_PORT"';"
            print "        proxy_pass_request_body off;"
            print "        proxy_set_header Content-Length \"\";"
            print "        proxy_connect_timeout 2s;"
            print "        proxy_read_timeout 2s;"
            print "    }\n"
            injected=1
        }
        {
            if ($0 ~ /location \/ \{/) {
                print $0
                print "        auth_request /_wake_reducecpu;"
                next
            }
            if ($0 ~ /location ~\* \\\.\(js\|css\|png/) {
                print $0
                print "        auth_request /_wake_reducecpu;"
                next
            }
            print $0
        }
        ' "$NGINX_CONF" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "$NGINX_CONF"

        if docker ps --format '{{.Names}}' | grep -q "^nginx$"; then
            docker exec nginx nginx -t && docker exec nginx nginx -s reload && echo -e "${GREEN}[OK] Docker Nginx 配置已更新并重载生效！${NC}"
        elif command -v nginx >/dev/null 2>&1; then
            nginx -t && systemctl reload nginx && echo -e "${GREEN}[OK] 系统 Nginx 配置已更新并重载生效！${NC}"
        fi
    fi
else
    echo -e "${GREEN}[4/4] 直连模式安装就绪，无需修改 Nginx。${NC}"
fi

# 9. 生成一键卸载脚本
cat << 'EOF' > "$INSTALL_DIR/uninstall.sh"
#!/bin/bash
set -e
echo "正在停止并删除守护服务..."
systemctl stop baidunetdisk-reduceCPUusage 2>/dev/null || true
systemctl disable baidunetdisk-reduceCPUusage 2>/dev/null || true
rm -f /etc/systemd/system/baidunetdisk-reduceCPUusage.service
systemctl daemon-reload

echo "正在确保容器处于解冻唤醒状态..."
docker unpause baidunetdisk 2>/dev/null || true

# 检查是否平移过直连端口
CONTAINER_ID=$(docker inspect baidunetdisk --format '{{.Id}}' 2>/dev/null || true)
CONFIG_FILE="/var/lib/docker/containers/${CONTAINER_ID}/hostconfig.json"
if [ -n "$CONTAINER_ID" ] && [ -f "$CONFIG_FILE" ]; then
    if grep -q "58000" "$CONFIG_FILE"; then
        echo "还原直连端口映射..."
        docker stop baidunetdisk >/dev/null 2>&1 || true
        systemctl stop docker
        sed -i 's/"5800\/tcp":\[{"HostIp":"127.0.0.1","HostPort":"58000"}\]/"5800\/tcp":[{"HostIp":"","HostPort":"5800"}]/g' "$CONFIG_FILE"
        systemctl start docker
        docker start baidunetdisk >/dev/null 2>&1
    fi
fi

echo "寻找 Nginx 备份文件..."
for bak in /home/web/conf.d/*.conf.bak* /etc/nginx/conf.d/*.conf.bak*; do
    if [ -f "$bak" ]; then
        target="${bak%%.bak*}"
        echo "还原 $bak -> $target"
        cp "$bak" "$target"
        if docker ps --format '{{.Names}}' | grep -q "^nginx$"; then
            docker exec nginx nginx -s reload 2>/dev/null || true
        elif command -v nginx >/dev/null 2>&1; then
            nginx -s reload 2>/dev/null || true
        fi
        break
    fi
done

rm -rf /opt/baidunetdisk-reduceCPUusage
echo "=== BaiduNetdisk ReduceCPUusage 卸载完成，已彻底恢复初始状态 ==="
EOF
chmod +x "$INSTALL_DIR/uninstall.sh"

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}  恭喜！BaiduNetdisk ReduceCPUusage 补丁已安装就绪！            ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "当前运行模式: ${GREEN}${MODE}${NC}"
if [ "$MODE" = "direct" ]; then
    echo -e "直连访问地址: http://<你的服务器IP>:5800 (首包 TCP 自动无感拉起唤醒)"
fi
echo -e "功能说明："
echo -e " 1. 无下载 (<30KB/s) 且连续 3 分钟无网页访问时，容器自动暂停 (CPU 0.00%)"
echo -e " 2. 网页访问时，毫秒级无感唤醒"
echo -e " 3. 如需彻底卸载并恢复原状，只需执行: bash $INSTALL_DIR/uninstall.sh\n"
