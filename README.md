# network-egress-doctor

面向“域名在部分网络出口不可访问”的通用排查脚本，重点覆盖：

- 运营商 DNS 解析异常
- 本地 DNS 缓存污染
- 公司网关/代理导致的 HTTPS 访问异常

本仓库提供两个脚本：

- `scripts/egress-doctor.sh`：Linux / macOS / WSL
- `scripts/egress-doctor.ps1`：Windows PowerShell

## 1. Bash 版本用法

```bash
chmod +x ./scripts/egress-doctor.sh

# 仅诊断
./scripts/egress-doctor.sh --domain opc.ren

# 诊断 + 尝试修复（刷新本地 DNS 缓存）
./scripts/egress-doctor.sh --domain opc.ren --repair

# 指定输出报告文件
./scripts/egress-doctor.sh --domain opc.ren --repair --output ./report.txt
```

## 2. PowerShell 版本用法

```powershell
# 仅诊断
powershell -ExecutionPolicy Bypass -File .\scripts\egress-doctor.ps1 -Domain opc.ren

# 诊断 + 修复（ipconfig /flushdns）
powershell -ExecutionPolicy Bypass -File .\scripts\egress-doctor.ps1 -Domain opc.ren -Repair

# 指定输出报告文件
powershell -ExecutionPolicy Bypass -File .\scripts\egress-doctor.ps1 -Domain opc.ren -Repair -Output .\report.txt
```

## 3. 脚本会做什么

- 本机环境采集：OS、用户、代理环境变量、resolver 配置
- DNS 对比：系统解析器 + 223.5.5.5 + 114.114.114.114 + 1.1.1.1 + 8.8.8.8
- 网络连通性：80/443 TCP 探测
- TLS/HTTP 验证：证书握手与 `HTTP/HTTPS` 响应
- 可选修复动作：
  - Linux/macOS：刷新 DNS 缓存（按系统能力自动尝试）
  - Windows：`ipconfig /flushdns`

## 4. 报告判读原则

- `系统 DNS 失败，但公共 DNS 成功`：优先怀疑本地 DNS 或缓存污染
- `DNS 成功，但 TCP/HTTPS 失败`：优先怀疑公司网关/防火墙策略
- `仅浏览器失败，命令行成功`：优先清理浏览器 DNS/HSTS/代理策略

## 5. 适用建议

- 用同一脚本在“可访问网络”和“不可访问网络”各跑一份报告，做差异对比
- 将报告提交给网络管理员时，重点提供：
  - DNS 对比结果
  - TCP 443 探测结果
  - TLS 握手/证书结果

## 6. 常见快速修理

### 6.1 Linux / WSL DNS 解析异常

如果报告显示系统 DNS 失败，可临时改为公共 DNS 复测：

```bash
sudo sh -c 'printf "nameserver 223.5.5.5\nnameserver 114.114.114.114\n" > /etc/resolv.conf'
```

WSL 想长期生效可再加：

```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[network]
generateResolvConf = false
EOF
```

然后重启 WSL：

```powershell
wsl --shutdown
```

### 6.2 公司代理/网关导致 HTTPS 握手失败

先做直连验证：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY curl -I https://opc.ren
```

如果直连成功、代理失败，联系网络管理员放行域名/IP，或将该域名加入代理绕过：

- 域名：`opc.ren`
- 目标 IP：`121.199.8.54`
- 端口：`443`

### 6.3 WSL 一键修理脚本（推荐）

仓库内置了 `scripts/repair-wsl-egress.sh`，会自动完成：

- 固化 `/etc/wsl.conf`（关闭自动生成 `resolv.conf`）
- 写入稳定 DNS（默认 `223.5.5.5` / `114.114.114.114`）
- 写入 `/etc/hosts` 映射（默认 `opc.ren -> 121.199.8.54`）
- 追加 `no_proxy/NO_PROXY` 绕过

执行：

```bash
sudo bash scripts/repair-wsl-egress.sh
```

然后在 Windows PowerShell 执行：

```powershell
wsl --shutdown
```
