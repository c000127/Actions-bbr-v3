# BBRv3 VPS 内核

基于 [XanMod](https://xanmod.org) 内核 fork，集成 Google [BBRv3](https://github.com/google/bbr/tree/v3)，针对 VPS 深度优化。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/c000127/Actions-bbr-v3/main/install.sh)
```

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

## 环境要求

- **架构**: x86_64
- **系统**: Debian 11+ / Ubuntu 20.04+
- **引导**: GRUB

## 升级与回退

安装脚本先下载并检查内核镜像包，安装成功后才清理不再运行的旧 XanMod 镜像。
正在运行的内核和本次安装的镜像都会保留；重启并确认新内核正常后，可按需手动清理旧内核。
手动安装较旧版本后，请在 GRUB 中确认选择了目标内核；默认启动项可能仍指向较新的版本。
卸载功能会删除已安装的 XanMod 内核，使用前请确认系统还有其他可启动的内核。

安装过程不会新建网络配置文件或修改当前网络参数。需要切换到 BBR 时，可在首页选择“手动启用 BBR”，
该选项只修改拥塞算法并保存设置，不更改队列或其他网络参数。检测到正在运行的 Skyline Speeder 服务，
或当前正在使用其他非默认拥塞算法时，脚本会保留现有设置。内核本身的默认值和其他系统服务仍可能影响重启后的实际状态；
可通过菜单的状态检查，或运行 `sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc` 查看。
以前版本留下的 sysctl 配置不会在安装时自动删除，需结合现有服务自行检查。

## 开发与测试

在 Linux 上运行以下命令，可使用模拟的系统命令验证安装、重装、手动启用 BBR、冲突处理和卸载路径，以及兼容性工作流的报告逻辑：

```bash
bash tests/installer_test.sh
python3 tests/compatibility_workflow_test.py
```

这些测试不会安装或卸载内核，也不会修改系统网络配置。GitHub Actions 会在相关文件发生变更时运行测试。

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
