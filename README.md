# ✨BBR 管理脚本✨ | BBR Management Script

> Forked from [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) with significant improvements.
>
> **[English](#english) | [中文](#中文)**

---

<a id="english"></a>

## English

A simple, efficient and feature-rich BBR management script designed for Debian/Ubuntu servers.

Whether you want to install the latest **BBR v3** kernel with one click, or flexibly switch between different network acceleration schemes, this script handles it all.

### Target Environment

| Item | Requirement |
| :--- | :--- |
| **Architecture** | `x86_64` / `aarch64` |
| **OS** | Debian 11+ / Ubuntu 20.04+ |
| **Target** | **Cloud VPS / Dedicated Server** |
| **Bootloader** | Standard `GRUB` bootloader |

> ⚠️ **Important:** This script is **not intended for** most SBCs (e.g., Raspberry Pi, NanoPi) which typically use U-Boot and will fail.

### Features

- 👑 One-click install BBR v3 kernel (latest mainline or stable, including RC versions)
- 🍰 Switch acceleration mode (BBR+FQ, BBR+CAKE, etc.)
- ⚙️ Enable/disable BBR acceleration
- 🗑️ Uninstall custom kernels
- 👀 Check current TCP congestion & qdisc settings

### Quick Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/c000127/Actions-bbr-v3/refs/heads/main/install.sh)
```

### Kernel Configuration Highlights

| Setting | Value | Rationale |
|---|---|---|
| Congestion Control | BBR v3 (built-in) | Best-in-class congestion control |
| Default Qdisc | fq | Optimal pairing with BBR |
| Kernel Compression | ZSTD | 3x faster compression than XZ, faster decompression |
| Timer | NO_HZ_IDLE | Lower overhead than NO_HZ_FULL, ideal for VPS |
| BPF JIT | Always-on | Improved BPF networking performance |
| TCP-AO | Enabled | RFC 5925, modern datacenter authentication |
| zswap | Default on | Compressed swap cache for VPS memory optimization |
| VPS Trimming | ~30 drivers disabled | Sound, physical GPU, WiFi, Bluetooth, InfiniBand, etc. |

### Improvements over Upstream

This fork introduces the following changes compared to [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3):

#### CI / Build Pipeline (`build.yml`)

| Area | Upstream | This Fork |
|---|---|---|
| BBR Patch Source | Google BBR branch checkout (entire tree) | CachyOS community patches (version-matched, smaller) |
| Kernel Versions | Stable only | Mainline + RC + Stable |
| Source Download | Single branch clone | Torvalds repo for RC, Greg KH repo for stable |
| Build Cache | None | ccache (5 GB, compression, depend mode) |
| Disk Space | No cleanup | Removes dotnet/Android/GHC toolchains before build |
| Kernel Config | Base config only, no tuning | VPS-optimized: ZSTD, BPF JIT, TCP-AO, zswap, ~30 drivers stripped |
| Workflow Cleanup | Third-party action (`delete-workflow-runs`) | Inline GitHub API calls (zero external dependency) |
| Release Notes | One-line text | Structured table with config summary and install instructions |
| Error Handling | Basic | `set -euo pipefail` throughout, config verification step |

#### Installation Script (`install.sh`)

| Area | Upstream | This Fork |
|---|---|---|
| Safety | No `set` options | `set -uo pipefail`, root permission check |
| Dependency Check | Checks 7 commands (incl. system builtins) | Only checks non-builtin packages, single `apt-get update` |
| Download Location | `/tmp` (shared, no cleanup) | `mktemp -d` with automatic `EXIT` trap cleanup |
| API Calls | No retry, no pagination | `--retry 3`, `per_page=100`, JSON type validation |
| Version Handling | Prefix match only | Normalization function for RC / two-segment versions |
| Packages | Downloads all assets | Skips `linux-libc-dev` (not needed at runtime) |
| Config Migration | N/A | Auto-migrates from old naming conventions |
| Version List UI | Plain list | Shows "← installed" marker next to current version |
| Status Display | Algo + qdisc only | Running kernel, installed BBR version, algo + qdisc |
| Uninstall Safety | `apt-get remove --purge` | `apt-get remove --purge -y --` (safe option terminator) |

---

<a id="中文"></a>

## 中文

一个为 Debian/Ubuntu 用户设计的，简单、高效且功能丰富的 BBR 管理脚本。

无论是想一键安装最新的 **BBR v3** 内核，还是在不同的网络加速方案之间灵活切换，本脚本都能帮你轻松搞定。

> **我们致力于提供优雅的界面和流畅的操作，让内核管理不再是件头疼事。**

---

### 🎯 **目标用户与支持环境**

在运行脚本前，请确保你的设备符合以下要求：

| 项目 | 要求 |
| :--- | :--- |
| **支持架构** | `x86_64` / `aarch64` |
| **支持系统** | Debian 11+ / Ubuntu 20.04+ |
| **目标设备** | **云服务器 (VPS/Cloud Server)** 或 **独立服务器** |
| **引导方式** | 使用标准 `GRUB` 引导加载程序 |

> ⚠️ **重要说明**
> 本脚本**不适用**于大多数单板计算机（SBC），例如**树莓派 (Raspberry Pi)、NanoPi** 等。这些设备通常使用 U-Boot 等非 GRUB 引导方式，脚本会执行失败。

---

---

### 🌟 功能列表  

👑 **一键安装 BBR v3 内核（支持 mainline / RC / stable）**  
🍰 **切换加速模式（BBR+FQ、BBR+CAKE 等）**  
⚙️ **开启/关闭 BBR 加速**  
🗑️ **卸载内核，告别不需要的内核版本**  
👀 **实时查看当前 TCP 拥塞算法和队列算法**  
🎨 **美化的输出界面，让脚本更有灵魂**  

---

### 🚀 如何使用？

1. **一键运行**  
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/c000127/Actions-bbr-v3/refs/heads/main/install.sh)
   ```

### 🔧 内核配置亮点

| 配置项 | 值 | 说明 |
|---|---|---|
| 拥塞控制 | BBR v3（内置） | 最优拥塞控制算法 |
| 默认队列 | fq | BBR 最佳搭配 |
| 内核压缩 | ZSTD | 比 XZ 快 3 倍压缩，解压更快 |
| 定时器 | NO_HZ_IDLE | 比 NO_HZ_FULL 开销更低，适合 VPS |
| BPF JIT | 始终启用 | 提升 BPF 网络程序性能 |
| TCP-AO | 已启用 | RFC 5925，现代数据中心认证 |
| zswap | 默认开启 | VPS 内存压缩交换优化 |
| VPS 精简 | 禁用 ~30 个驱动 | 声卡、物理显卡、WiFi、蓝牙、InfiniBand 等 |

### 📋 相较上游的改进

本项目 Fork 自 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)，主要改进如下：

#### CI / 构建流水线 (`build.yml`)

| 方面 | 上游 | 本 Fork |
|---|---|---|
| BBR 补丁来源 | Google BBR 分支检出（整棵树） | CachyOS 社区补丁（版本匹配，体积更小） |
| 内核版本 | 仅 stable | Mainline + RC + Stable |
| 源码下载 | 单分支克隆 | RC 从 Torvalds 仓库、stable 从 Greg KH 仓库 |
| 构建缓存 | 无 | ccache（5 GB，压缩，depend 模式） |
| 磁盘空间 | 无清理 | 构建前删除 dotnet/Android/GHC 工具链 |
| 内核配置 | 仅基础配置 | VPS 优化：ZSTD、BPF JIT、TCP-AO、zswap、精简 ~30 个驱动 |
| 工作流清理 | 第三方 Action (`delete-workflow-runs`) | 内联 GitHub API（零外部依赖） |
| Release 说明 | 单行文本 | 结构化表格，含配置摘要和安装说明 |
| 错误处理 | 基础 | 全程 `set -euo pipefail`，配置验证步骤 |

#### 安装脚本 (`install.sh`)

| 方面 | 上游 | 本 Fork |
|---|---|---|
| 安全性 | 无 `set` 选项 | `set -uo pipefail`，root 权限检查 |
| 依赖检查 | 检查 7 个命令（含系统内置） | 仅检查非内置包，单次 `apt-get update` |
| 下载目录 | `/tmp`（共享，无清理） | `mktemp -d` + `EXIT` trap 自动清理 |
| API 调用 | 无重试、无分页 | `--retry 3`、`per_page=100`、JSON 类型校验 |
| 版本处理 | 仅前缀匹配 | 版本号规范化（支持 RC / 两段版本号） |
| 下载包 | 下载全部资产 | 跳过 `linux-libc-dev`（运行时不需要） |
| 配置迁移 | 无 | 自动迁移旧命名约定的配置文件 |
| 版本列表 | 纯列表 | 已安装版本标记"← 已安装" |
| 状态显示 | 仅显示算法 + 队列 | 显示运行内核、已安装 BBR 版本、算法 + 队列 |
| 卸载安全 | `apt-get remove --purge` | `apt-get remove --purge -y --`（安全选项终结符） |

---

### 🌟 操作界面  

每次运行脚本，你都会进入一个活泼又实用的选项界面：

```bash
╭( ･ㅂ･)و ✧ 你可以选择以下操作哦：
  1. � 安装或更新 BBR v3 (最新版)
  2. 📚 指定版本安装
  3. 🔍 检查 BBR v3 状态
  4. ⚡ 启用 BBR + FQ
  5. ⚡ 启用 BBR + FQ_CODEL
  6. ⚡ 启用 BBR + FQ_PIE
  7. ⚡ 启用 BBR + CAKE
  8. 🗑️  卸载 BBR 内核
```

> **小提示：** 如果选错了也没关系，脚本会乖乖告诉你该怎么办！  

---

### 🌟 常见问题  

**Q: 我不是 BBR 专家，不知道选哪个加速方案？**  
A: 放心，BBR + FQ 是最常见的方案，适用于大多数场景～  

**Q: arm64 架构的内核包在哪里？**  
A: arm64 构建需要在 GitHub Actions 的 `build.yml` 中取消 arm64 矩阵的注释以启用。启用后会自动使用 `ubuntu-24.04-arm` runner 进行原生编译。

**Q: 与上游相比，BBR 补丁来源有什么不同？**  
A: 上游直接检出 Google BBR 整个源码树，本 Fork 使用 CachyOS 社区维护的版本匹配补丁，体积更小且更新更及时。

**Q: 为什么支持 RC 版本？**  
A: RC（Release Candidate）版本可以第一时间体验最新内核特性。安装脚本会自动识别 RC 版本并正确处理版本号。

---

### ❤️ 开源协议  

欢迎使用、修改和传播这个脚本！如果你觉得它对你有帮助，记得来点个 Star ⭐ 哦～  

> 💡 **免责声明：** 本脚本由作者热爱 Linux 的灵魂驱动编写，虽尽力确保安全，但任何使用问题请自负风险！
### 🌟 特别鸣谢  
感谢 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 原始项目。  
感谢 [Naochen2799/Latest-Kernel-BBR3](https://github.com/Naochen2799/Latest-Kernel-BBR3) 项目提供的技术支持与灵感参考。  
感谢 [CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches) 提供版本匹配的 BBRv3 补丁。  

🎉 **快来体验不一样的 BBR 管理工具吧！** 🎉  
