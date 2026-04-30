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
XanMod GitLab → GitHub Actions → GCC 15 + ccache → VPS config → .deb → Release
```

## 环境要求

- **架构**: x86_64
- **系统**: Debian 11+ / Ubuntu 20.04+
- **引导**: GRUB

## FAQ

**Q: BBRv3 和 BBR 有什么区别？**
A: BBRv3 增加了 ECN 感知、更精确的带宽探测、更好的公平性。

**Q: 为什么不直接装 linux-xanmod？**
A: 本项目禁用了 ~30 个 VPS 不需要的驱动，调整了定时器/抢占/时钟参数。

**Q: arm64 支持吗？**
A: `build.yml` 中有 arm64 配置（已注释），取消注释即可。

## 鸣谢

- [XanMod](https://xanmod.org) — 内核 fork
- [Google BBR](https://github.com/google/bbr) — BBRv3 算法
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) — 原始项目  
