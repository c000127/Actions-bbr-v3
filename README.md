# BBRv3 VPS 内核

> 基于 [XanMod](https://xanmod.org) 内核 fork，集成 Google [BBRv3](https://github.com/google/bbr/tree/v3) 拥塞控制算法，针对 VPS 场景深度优化。

**[English](#english) | [中文](#中文)**

---

<a id="english"></a>

## English

### What Is This?

An automated kernel build pipeline that produces **BBRv3-enabled Debian packages** optimized for cloud VPS, powered by GitHub Actions.

| Component | Source |
|---|---|
| **Kernel** | [XanMod/linux](https://gitlab.com/xanmod/linux) (GitLab) |
| **BBRv3** | [Google BBR v3](https://github.com/google/bbr/tree/v3) — pre-integrated by XanMod |
| **Build** | GitHub Actions + GCC 15 + ccache |
| **Config** | Custom VPS-optimized `.config` |

### Target Environment

| Item | Requirement |
|---|---|
| **Architecture** | `x86_64` |
| **OS** | Debian 11+ / Ubuntu 20.04+ |
| **Target** | Cloud VPS / Dedicated Server |
| **Bootloader** | GRUB |

### Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/c000127/Actions-bbr-v3/main/install.sh)
```

Or manually:
```bash
sudo dpkg -i linux-*.deb && sudo update-grub && sudo reboot
```

### Kernel Configuration Highlights

| Setting | Value | Rationale |
|---|---|---|
| Congestion Control | **BBR v3** (built-in, default) | Best-in-class congestion control |
| Default Qdisc | **fq** | Optimal pairing with BBR |
| Kernel Compression | **ZSTD** | 3x faster than XZ |
| Timer | **NO_HZ_IDLE** | Lower overhead than NO_HZ_FULL for VPS |
| Preemption | **PREEMPT_LAZY** | Balances latency and throughput |
| Timer Frequency | **HZ=250** | Good balance for VPS |
| BPF JIT | **Always-on** | Improved BPF networking |
| TCP-AO | **Enabled** | RFC 5925 authentication |
| MPTCP | **Enabled** | Multi-path TCP |
| zswap | **Default on (ZSTD)** | Compressed swap cache |
| eBPF/BTF | **Enabled** | CO-RE support |
| VPS Trimming | **~30 drivers disabled** | Sound, GPU, WiFi, BT, InfiniBand, etc. |

### How It Works

```
XanMod GitLab (latest tag) → GitHub Actions → GCC 15 + ccache → VPS config → .deb → Release
```

1. Fetches the latest XanMod kernel tag from GitLab
2. Clones the XanMod source (BBRv3 pre-integrated)
3. Applies VPS-optimized kernel config
4. Builds with GCC 15 + ccache (~50 min)
5. Publishes `.deb` packages to GitHub Releases

---

<a id="中文"></a>

## 中文

### 这是什么？

一个基于 GitHub Actions 的自动化内核构建流水线，产出**启用 BBRv3 的 Debian 内核包**，针对云 VPS 场景深度优化。

| 组件 | 来源 |
|---|---|
| **内核源码** | [XanMod/linux](https://gitlab.com/xanmod/linux)（GitLab） |
| **BBRv3** | [Google BBR v3](https://github.com/google/bbr/tree/v3) — 由 XanMod 预集成 |
| **构建** | GitHub Actions + GCC 15 + ccache |
| **配置** | 自定义 VPS 优化 `.config` |

### 支持环境

| 项目 | 要求 |
|---|---|
| **架构** | `x86_64` |
| **系统** | Debian 11+ / Ubuntu 20.04+ |
| **目标设备** | 云服务器 (VPS) 或独立服务器 |
| **引导方式** | GRUB |

> ⚠️ 不适用于大多数单板计算机（树莓派、NanoPi 等），这些设备通常使用 U-Boot。

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/c000127/Actions-bbr-v3/main/install.sh)
```

或手动下载 `.deb` 文件后执行：
```bash
sudo dpkg -i linux-*.deb && sudo update-grub && sudo reboot
```

### 内核配置亮点

| 配置项 | 值 | 说明 |
|---|---|---|
| 拥塞控制 | **BBR v3**（内置，默认） | 最优拥塞控制算法 |
| 默认队列 | **fq** | BBR 最佳搭配 |
| 内核压缩 | **ZSTD** | 比 XZ 快 3 倍 |
| 定时器 | **NO_HZ_IDLE** | 比 NO_HZ_FULL 开销更低，适合 VPS |
| 抢占模型 | **PREEMPT_LAZY** | 平衡延迟和吞吐 |
| 时钟频率 | **HZ=250** | VPS 最佳平衡 |
| BPF JIT | **始终启用** | 提升 BPF 网络性能 |
| TCP-AO | **已启用** | RFC 5925 认证 |
| MPTCP | **已启用** | 多路径 TCP |
| zswap | **默认开启（ZSTD）** | VPS 内存压缩优化 |
| eBPF/BTF | **已启用** | CO-RE 支持 |
| VPS 精简 | **禁用 ~30 个驱动** | 声卡、显卡、WiFi、蓝牙、InfiniBand 等 |

### 构建流程

```
XanMod GitLab (最新 tag) → GitHub Actions → GCC 15 + ccache → VPS 配置 → .deb → Release
```

1. 从 XanMod GitLab 获取最新内核 tag
2. 克隆 XanMod 源码（BBRv3 已预集成）
3. 应用 VPS 优化内核配置
4. 使用 GCC 15 + ccache 编译（约 50 分钟）
5. 发布 `.deb` 包到 GitHub Releases

### 常见问题

**Q: BBRv3 和普通 BBR 有什么区别？**
A: BBRv3 是 Google 开发的第三代 BBR 拥塞控制算法，增加了 ECN 感知、更精确的带宽探测、更好的公平性等改进。

**Q: 为什么不直接安装 `linux-xanmod`？**
A: 本项目在 XanMod 基础上做了 VPS 专用优化：禁用 ~30 个不需要的硬件驱动（减少编译时间和包体积）、调整定时器/抢占模型/时钟频率等参数，更适合 VPS 场景。

**Q: arm64 支持吗？**
A: `build.yml` 中有 arm64 矩阵配置（已注释），取消注释即可启用。

**Q: 如何手动触发构建？**
A: 在 GitHub Actions 页面手动运行 `build.yml` 的 `workflow_dispatch`。

### 开源协议

欢迎使用、修改和传播。觉得有帮助记得点个 Star ⭐

### 特别鸣谢

- [XanMod](https://xanmod.org) — 提供高质量的内核 fork
- [Google BBR Team](https://github.com/google/bbr) — BBRv3 算法
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) — 原始项目  
