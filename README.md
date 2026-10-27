# BBRv3 VPS 内核

基于 [XanMod](https://xanmod.org) 内核 fork，集成 Google [BBRv3](https://github.com/google/bbr/tree/v3)，针对 VPS 深度优化。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/c000127/Actions-bbr-v3/main/install.sh)
```

首页分别显示正在运行的内核、已安装的标准版和激进版，以及当前默认拥塞算法和默认队列。
菜单 **3** 会列出全部已安装的内核版本与 XanMod 修订号，并标记正在运行的版本。
默认队列不等于现有网卡的实际队列；应用也可以为单个连接选择其他拥塞算法。
非交互终端的输出不带颜色；交互终端可以设置 `NO_COLOR=1` 关闭颜色。

## 内核配置

| 配置项 | 值 | 说明 |
|---|---|---|
| 拥塞控制 | BBR v3（内置，默认） | Google 第三代 BBR |
| 队列 | fq | BBR 最佳搭配 |
| 定时器 | NO_HZ_IDLE | VPS 低开销 |
| 抢占 | PREEMPT_LAZY | 平衡延迟和吞吐 |
| 时钟 | HZ=250 | VPS 最佳平衡 |
| 压缩 | ZSTD | 内核 + 模块均使用 |
| eBPF | BTF 已启用 | CO-RE 支持 |
| 精简 | 禁用 ~30 个驱动 | 声卡、显卡、WiFi、蓝牙等 |

## 构建流程

```
XanMod GitLab → GitHub Actions → GCC 16 + ccache → VPS config → .deb → Release
```

`build.yml` 使用 `x86-64.config` 作为基础配置，再设置和验证构建选项；
`optimize-config.ps1` 是单独运行的配置优化工具，不是构建工作流的必经步骤。
`CompatibilityTest.yml` 用于测试 Google BBRv3 源码与 mainline、stable 内核的兼容性。

## 实验性激进版

激进版是独立的 x86_64 内核：使用 `x86-64-aggressive.config`，构建时在 XanMod 自带的 BBRv3 源码上应用以下参数：

| 参数 | 标准版 | 激进版 |
|---|---|---|
| STARTUP 发送速率增益 | 约 2.77× | 3.0× |
| PROBE_BW 巡航增益 | 1.0× | 约 1.2× |
| BBR 内部丢包阈值 | 2% | 25% |
| 因丢包提前退出 STARTUP | 启用 | 禁用 |

25% 是 BBR 内部判断采样的阈值，**不是**保证网络可以承受的物理丢包率。ECN 和其他丢包恢复机制仍保留；
激进参数可能增加重传、排队延迟和对共享链路上其他流量的影响，不保证高丢包场景一定更快。

GitHub Actions 的“检查上游并构建两个 BBRv3 内核”每 6 小时检查一次 XanMod 上游，
新版本会固定使用同一个上游标签并并行构建标准版和激进版。已完整发布的配置会跳过；某个版本缺包或
上次构建失败时，下次检查会补齐。该工作流也可以手动运行，按需选择重新构建或只生成 Actions 产物。
定时任务需要位于仓库默认分支，GitHub 的调度可能延迟。原有的单配置手动构建入口仍可使用。
公开仓库连续 60 天没有仓库活动时，GitHub 可能自动停用定时工作流；可在 Actions 页面重新启用。

激进版产物发布到单独的
`aggressive-x86_64-<版本>` Release，内核版本采用如 `7.3.0-aggressive-xanmod1` 的独立标识。运行一键安装脚本后：

- 菜单 **6** 安装或更新激进版，菜单 **7** 选择激进版版本，菜单 **8** 卸载激进版。
- 菜单 **1、2、4** 仍管理标准版，菜单 **3** 查看两种内核状态；两种内核不会在升级时互相清理。
- 安装会创建激进版专用 BBR 配置及启动服务；如果 Skyline 等服务正在管理拥塞算法，会保留现有设置。
- 安装后 GRUB 的默认项可能仍是标准版，需在高级选项选择激进版；重启后用 `uname -r` 确认。
- 可通过 GRUB 的高级选项选择标准版作为回退。

激进构建遇到不匹配的上游 BBRv3 源码时会停止，避免发布只应用了部分参数的内核。

激进版使用 `/etc/xanmod-bbr/aggressive.conf` 保存 `net.ipv4.tcp_congestion_control=bbr`。
由于普通 `/etc/sysctl.d/` 文件对所有内核都会生效，`xanmod-aggressive-bbr.service` 负责在安装后和每次启动时检查：
仅在正在运行激进版内核、且没有运行 Skyline 或使用其他自定义拥塞算法时应用该文件。标准内核不会被这个服务改写。
检测到冲突时服务会跳过；冲突解除后可运行 `sudo systemctl start xanmod-aggressive-bbr.service` 重新检查。
这是一次性服务，执行结束后显示 `inactive` 属正常现象；可用 `journalctl -u xanmod-aggressive-bbr.service` 查看结果。
卸载激进版时仅移除本项目管理的激进版配置和服务，不删除其他程序的文件。

内核已内置 BBRv3 并将 `fq` 设为默认队列，无需再套用大份 sysctl 参数表才能使用激进算法；
安装器不会强制覆盖现有队列或修改现有网卡 qdisc。其他服务或系统配置可能覆盖默认值，
请用 `sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc` 检查实际状态。

### VPS 一次性启动激进版

如果 VPS 的默认 GRUB 项仍指向标准版，可以使用服务商控制台选择“高级选项”中的激进版内核。
无法交互选择时，也可以在 GRUB 支持 `grub-reboot` 的系统上选择**下一次**启动项：

```bash
sudo grep -E '^submenu |^[[:space:]]*menuentry ' /boot/grub/grub.cfg
# 从输出中找到高级选项子菜单的 ID 和激进版内核条目的 ID，然后替换下面两个占位符。
sudo grub-reboot '子菜单ID>激进版条目ID'
sudo reboot
# 重新连接后确认：
uname -r
sudo grub-editenv - list
```

`grub-reboot` 预期只影响下一次启动，但 GRUB 必须能在启动时写入环境块才能自动清除该选择；
某些 Btrfs 等文件系统或引导配置可能无法清除。如果启动后 `grub-editenv - list` 仍显示指向激进版的
`next_entry`，且希望下次回到原默认项，可运行 `sudo grub-editenv - unset next_entry` 并再次检查。
需要长期使用激进版时，请按发行版的 GRUB 文档设置默认项，并保留可用的标准内核及服务商控制台作为回退。

## 环境要求

- **架构**: x86_64
- **系统**: Debian 11+ / Ubuntu 20.04+
- **引导**: GRUB

## 升级与回退

安装脚本先下载并检查内核镜像包，安装成功后才清理不再运行的旧 XanMod 镜像。
正在运行的内核和本次安装的镜像都会保留；重启并确认新内核正常后，可按需手动清理旧内核。
手动安装较旧版本后，请在 GRUB 中确认选择了目标内核；默认启动项可能仍指向较新的版本。
卸载功能会删除已安装的 XanMod 内核，使用前请确认系统还有其他可启动的内核。
卸载前会列出目标镜像、是否包含当前运行内核以及配置文件的处理方式，只有输入 `y` 才会继续。
若卸载包含当前运行内核，该内核会运行到下次重启；重启前必须确认其他启动项可用。

标准版安装过程不会新建网络配置文件或修改当前网络参数。需要切换到 BBR 时，可在首页选择“手动启用 BBR”，
该选项只修改拥塞算法并保存设置，不更改队列或其他网络参数。检测到正在运行的 Skyline Speeder 服务，
或当前正在使用其他非默认拥塞算法时，脚本会保留现有设置。内核本身的默认值和其他系统服务仍可能影响重启后的实际状态；
可通过菜单的状态检查，或运行 `sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc` 查看。
以前版本留下的 sysctl 配置不会在安装时自动删除，需结合现有服务自行检查。

## 开发与测试

在 Linux 上运行以下命令，可使用模拟的系统命令验证安装、重装、手动启用 BBR、冲突处理和卸载路径，以及兼容性工作流的报告逻辑：

```bash
bash tests/installer_test.sh
python3 tests/compatibility_workflow_test.py
python3 tests/test_aggressive_profile.py
python3 tests/test_build_profiles.py
python3 tests/test_pair_build.py
python3 tests/test_pair_workflow.py
```

这些测试不会安装或卸载内核，也不会修改系统网络配置。GitHub Actions 会在相关文件发生变更时运行测试。

### 隔离丢包试验

`tests/bench-bbr-loss.sh` 使用临时网络命名空间和 veth，在独立的中间路由器设置双向 100 Mbit/s、各方向 50 ms 延迟，
并关闭网卡聚合；它覆盖单向 30%/50% 丢包，以及双向合成约 30%/50% 丢包。
测试需要 root、`ip`、`tc`、`ethtool`、`iperf3` 和 `ping`，且不能应用在生产网卡上。

要在**标准版内核**上与激进参数对照，可从与当前内核完全匹配的 XanMod 源码取出
`net/ipv4/tcp_bbr.c` 和 `net/ipv4/tcp_dctcp.h`，并安装当前内核的 headers，然后运行：

```bash
sudo bash tests/build-bbraggr-module.sh /path/to/tcp_bbr.c /path/to/tcp_dctcp.h /tmp/bbraggr-module
sudo insmod /tmp/bbraggr-module/tcp_bbr_aggr.ko
sudo bash tests/bench-bbr-loss.sh
sudo rmmod tcp_bbr_aggr
```

比较模块名为 `bbraggr`，只供单个测试连接选择，不会切换主机默认算法。测试结果包含 `iperf3` JSON、
队列统计和失败状态；短时合成测试不能替代真实网络长期观察。`BENCH_SECONDS`、`BENCH_REPEATS` 和
`BENCH_OUTPUT` 可调整测试时长、重复次数和结果目录；`BENCH_SHARED=1` 会额外测试两种算法同时共享瓶颈。
运行 `python3 tests/summarize-bbr-loss.py <结果目录>` 可以汇总接收端吞吐和重传。
一次 VPS 的测试条件和结果见 [激进 BBRv3 隔离链路试验](docs/benchmarks/aggressive-bbrv3-2026-10-27.md)。

## FAQ

**Q: BBRv3 和 BBR 有什么区别？**
A: BBRv3 增加了 ECN 感知、更精确的带宽探测、更好的公平性。

**Q: 为什么不直接装 linux-xanmod？**
A: 本项目禁用了 ~30 个 VPS 不需要的驱动，调整了定时器/抢占/时钟参数。

**Q: arm64 支持吗？**
A: 仓库保留了 `arm64.config`，安装脚本也能识别 arm64 版本；但当前构建矩阵和发布标签仅配置了 x86_64，不能只取消注释就生成 arm64 发行包。

## 鸣谢

- [XanMod](https://xanmod.org) — 内核 fork
- [Google BBR](https://github.com/google/bbr) — BBRv3 算法
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) — 原始项目  
