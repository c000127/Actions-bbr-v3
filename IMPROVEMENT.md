# Improvements over Upstream | 相较上游的改进

> **[English](#english) | [中文](#中文)**

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
| Aggressive Mode | N/A | CPU mitigations off, HZ=1000, NR_CPUS=256, x86-64-v3, BTF, IA32 off |
| Performance Patches | None | CachyOS base + fixes patches (best-effort) + BBRv3 |
| Build Optimization | N/A | GCC 15, `-march=x86-64-v3`, ccache, latest pahole/zstd/lz4 |
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
| 激进模式 | 无 | CPU 缓解关闭、HZ=1000、NR_CPUS=256、x86-64-v3、BTF、IA32 关闭 |
| 性能补丁 | 无 | CachyOS base + fixes 补丁 (best-effort) + BBRv3 |
| 编译优化 | 无 | GCC 15、`-march=x86-64-v3`、ccache、最新 pahole/zstd/lz4 |
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