# BaiduNetdisk ReduceCPUusage 智能降频与无感唤醒补丁 (Scale-to-Zero)

为基于 Docker 部署的百度网盘客户端量身打造的**按需休眠与秒级唤醒守护工具**。

通过 Linux 原生 `cgroups freezer`（`docker pause`）技术，彻底解决百度网盘空闲时持续偷跑 3%~5% CPU 的底噪问题，实现**闲时 CPU 绝对 0.00%，访问时毫秒级无感唤醒，且绝对不中断后台正在下载的任务**。

---

## 🌟 特性

- **双模自适应支持（有无反代均可无缝使用）**：
  - **模式 A（Nginx 反向代理）**：自动注入 `auth_request` 高性能子请求钩子，访问域名秒级唤醒。
  - **模式 B（直连无反代模式）**：无需任何反向代理，看门狗内置原生零开销透明网桥。用户直接浏览器访问 `http://IP:5800`，首包 TCP 握手瞬间自动拉起解冻！
- **镜像兼容性安全校验**：安装时自动校验镜像（认证支持 `johngong/baidunetdisk`），防止在不兼容镜像上误安装导致异常。
- **CPU 绝对归零 (0.00%)**：闲置时挂起容器内所有进程，彻底释放 CPU 和降低能耗发热。
- **毫秒级无感唤醒**：首包或请求发起瞬间（约 10~50ms）自动解冻容器，体验无缝、无需繁琐二次登录。
- **智能下载保护（防误杀）**：
  - 实时从内核 `/proc/<pid>/net/dev` 统计网卡瞬时下行流量。
  - 只有当 **下载网速 < 30 KB/s** 且 **连续 3 分钟无网页连接** 时，才判定为真正闲置并执行休眠。
  - 只要后台有下载任务（如挂机大文件下载），**永不休眠**！
- **零破坏性 & 100% 可逆**：不修改容器内任何数据、不重建容器、不破坏登录态，随时提供一键彻底卸载恢复。

---

## 📋 认证兼容镜像

- ✅ **`johngong/baidunetdisk`**（已认证、完全适配 Web 端口 5800 与网络拓扑）

> 如果使用其他镜像，脚本会给出警告阻断。如确认结构兼容，可通过设置环境变量 `export SKIP_IMAGE_CHECK=true` 强制安装。

---

## 🚀 一键安装命令

在宿主机上执行以下单行命令即可自动完成部署：

```bash
curl -sSL https://raw.githubusercontent.com/redcats2/baidunetdisk-reduceCPUusage/main/install.sh | bash
```

*(若本地已有源码，亦可在项目根目录直接执行 `sudo bash install.sh`)*

---

## ⚙️ 环境变量自定义（可选）

你可以在执行前通过环境变量进行自定义配置：

```bash
# 指定容器名称（默认为 baidunetdisk）
export REDUCECPU_CONTAINER=baidunetdisk

# 跳过镜像安全校验（默认 false）
export SKIP_IMAGE_CHECK=false

# 指定判定为闲置的下载网速阈值（默认 30 KB/s）
export REDUCECPU_SPEED_KB=30

# 指定闲置超时时长（默认 180 秒 / 3分钟）
export REDUCECPU_IDLE_SECONDS=180

# 唤醒内部微服务端口（默认 5802）
export REDUCECPU_WAKE_PORT=5802
```

---

## 🔍 服务状态与日志查看

```bash
# 查看守护服务运行状态
systemctl status baidunetdisk-reduceCPUusage

# 实时查看休眠与唤醒日志
journalctl -u baidunetdisk-reduceCPUusage -f

# 查看网盘容器 CPU 占用（休眠时应显示 0.00%）
docker stats baidunetdisk --no-stream
```

---

## 🗑️ 一键卸载与彻底还原

如果不想再使用此休眠补丁，执行以下命令即可彻底清除守护服务、恢复 Nginx 原始配置，让网盘恢复 24 小时全天候常驻运行：

```bash
bash /opt/baidunetdisk-reduceCPUusage/uninstall.sh
```

---

## 📄 开源协议
MIT License
