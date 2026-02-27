# ✨BBR 管理脚本✨ | BBR Management Script

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

- 👑 One-click install BBR v3 kernel (latest mainline or stable)
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
| Timer Frequency | 250 HZ | Balanced latency/throughput for VPS |
| Preemption | PREEMPT_LAZY | Low-latency with minimal overhead (6.12+) |
| BPF/eBPF | Enabled | Modern networking & observability |

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

👑 **一键安装 BBR v3 内核**  
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

**Q: 为什么下载失败啦？**  
A: 有可能是 GitHub API 速率限制或者链接过期了，稍后重试或者来群里反馈！  

**Q: 我不是 BBR 专家，不知道选哪个加速方案？**  
A: 放心，BBR + FQ 是最常见的方案，适用于大多数场景（运行选项 4 即可）～  

**Q: 如果不小心把系统搞崩了怎么办？**  
A: 别慌！记得备份你的内核，或者到 [Joey's Blog](https://joeyblog.net) 查看修复教程。

**Q: arm64 架构的内核包在哪里？**  
A: arm64 构建需要在 GitHub Actions 的 `build.yml` 中取消 arm64 矩阵的注释以启用。启用后会自动使用 `ubuntu-24.04-arm` runner 进行原生编译。

---

### 🌈 作者信息  

**Joey**  
📖 博客：[JoeyBlog](https://joeyblog.net)  
💬 群组：[Telegram Feedback Group](https://t.me/+ft-zI76oovgwNmRh)

---

### ❤️ 开源协议  

欢迎使用、修改和传播这个脚本！如果你觉得它对你有帮助，记得来点个 Star ⭐ 哦～  

> 💡 **免责声明：** 本脚本由作者热爱 Linux 的灵魂驱动编写，虽尽力确保安全，但任何使用问题请自负风险！
### 🌟 特别鸣谢  
感谢 [Naochen2799/Latest-Kernel-BBR3](https://github.com/Naochen2799/Latest-Kernel-BBR3) 项目提供的技术支持与灵感参考。  
感谢 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 项目提供的技术支持与灵感参考。  

🎉 **快来体验不一样的 BBR 管理工具吧！** 🎉  
