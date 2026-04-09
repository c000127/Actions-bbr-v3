#!/bin/bash
# ============================================================
# extract-bbr3.sh — BBRv3 补丁提取工具
# 用途：当新内核版本发布时，从上游提取 BBRv3 补丁
# 用法：./extract-bbr3.sh <kernel_series>
# 示例：./extract-bbr3.sh 7.1
# ============================================================
set -euo pipefail

KERNEL_SERIES="${1:?用法: $0 <kernel_series>  (例如: 7.1)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/bbr3-extract-${KERNEL_SERIES}"
OUTPUT="${SCRIPT_DIR}/${KERNEL_SERIES}/0002-bbr3.patch"

echo "=========================================="
echo "BBRv3 补丁提取工具"
echo "目标内核版本: ${KERNEL_SERIES}"
echo "输出路径: ${OUTPUT}"
echo "=========================================="

mkdir -p "${SCRIPT_DIR}/${KERNEL_SERIES}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# ================================================================
# 来源 1：CachyOS kernel-patches（最简单，直接下载）
# ================================================================
echo ""
echo "=== 来源 1: CachyOS kernel-patches ==="

# 尝试 master 分支
CACHYOS_URL="https://raw.githubusercontent.com/CachyOS/kernel-patches/master/${KERNEL_SERIES}/0002-bbr3.patch"
echo "  检查: ${CACHYOS_URL}"
if curl -sfL --head "$CACHYOS_URL" >/dev/null 2>&1; then
    echo "  ✅ 找到！下载中..."
    curl -fL "$CACHYOS_URL" -o "${OUTPUT}"
    echo "  ✅ 已保存到: ${OUTPUT}"
    echo "  文件大小: $(wc -c < "${OUTPUT}") 字节"
    echo ""
    echo "验证补丁内容..."
    if grep -qP 'BBR_VERSION\s+3' "${OUTPUT}" 2>/dev/null; then
        echo "  ✅ 包含 BBR_VERSION 3 定义"
    else
        echo "  ⚠️ 未找到 BBR_VERSION 3，请手动检查"
    fi
    echo ""
    echo "完成！请运行以下命令提交:"
    echo "  git add patches/${KERNEL_SERIES}/0002-bbr3.patch"
    echo "  git commit -m 'patches: add BBRv3 for ${KERNEL_SERIES} (source: CachyOS)'"
    exit 0
fi
echo "  ℹ️ CachyOS master 无此版本补丁"

# 尝试历史 commits（搜索最近的包含该版本的 commit）
echo "  搜索 CachyOS 历史 commits..."
CACHYOS_COMMITS=$(curl -sf "https://api.github.com/repos/CachyOS/kernel-patches/commits?path=${KERNEL_SERIES}&per_page=5" 2>/dev/null | \
    grep -oP '"sha"\s*:\s*"\K[a-f0-9]{40}' | head -5) || true

for sha in $CACHYOS_COMMITS; do
    URL="https://raw.githubusercontent.com/CachyOS/kernel-patches/${sha}/${KERNEL_SERIES}/0002-bbr3.patch"
    if curl -sfL --head "$URL" >/dev/null 2>&1; then
        echo "  ✅ 在历史 commit ${sha:0:7} 找到补丁！"
        curl -fL "$URL" -o "${OUTPUT}"
        echo "  ✅ 已保存到: ${OUTPUT}"
        echo ""
        echo "完成！请运行以下命令提交:"
        echo "  git add patches/${KERNEL_SERIES}/0002-bbr3.patch"
        echo "  git commit -m 'patches: add BBRv3 for ${KERNEL_SERIES} (source: CachyOS@${sha:0:7})'"
        exit 0
    fi
done
echo "  ℹ️ CachyOS 历史中也无此版本"

# ================================================================
# 来源 2：XanMod 源码树 diff
# XanMod 将 BBRv3 直接 cherry-pick 进源码树
# 通过对比 XanMod 与 vanilla 内核的 diff 来提取补丁
# ================================================================
echo ""
echo "=== 来源 2: XanMod 源码树 diff ==="

# 查找 XanMod 对应的分支
XANMOD_BRANCH="${KERNEL_SERIES}"
echo "  检查 XanMod 分支: ${XANMOD_BRANCH}"

# 检查分支是否存在
if git ls-remote --heads https://gitlab.com/xanmod/linux.git "${XANMOD_BRANCH}" >/dev/null 2>&1; then
    echo "  ✅ 分支存在，开始提取..."
    cd "${WORK_DIR}"

    # 浅克隆 XanMod（只取网络相关文件）
    echo "  克隆 XanMod (shallow)..."
    git clone --depth=1 --single-branch --branch "${XANMOD_BRANCH}" \
        --filter=blob:none --sparse \
        https://gitlab.com/xanmod/linux.git xanmod 2>/dev/null || {
        echo "  ⚠️ XanMod 克隆失败"
        cd "${SCRIPT_DIR}"
    }

    if [ -d xanmod ]; then
        cd xanmod
        git sparse-checkout set net/ipv4 include/net include/uapi/linux

        # 获取对应的 vanilla 内核 tag
        echo "  查找对应的 vanilla 基线..."
        # XanMod 分支通常基于 vX.Y 或 vX.Y.Z
        VANILLA_TAG=$(git log --oneline --all | grep -oP 'v\d+\.\d+(\.\d+)?' | head -1) || true
        if [ -z "$VANILLA_TAG" ]; then
            VANILLA_TAG="v${KERNEL_SERIES}"
        fi

        echo "  克隆 vanilla 内核 ${VANILLA_TAG} (shallow)..."
        cd "${WORK_DIR}"
        git clone --depth=1 --single-branch --branch "${VANILLA_TAG}" \
            --filter=blob:none --sparse \
            https://github.com/torvalds/linux.git vanilla 2>/dev/null || {
            echo "  ⚠️ Vanilla 内核克隆失败"
        }

        if [ -d vanilla ]; then
            cd vanilla
            git sparse-checkout set net/ipv4 include/net include/uapi/linux

            # 生成 BBRv3 相关文件的 diff
            echo "  生成 BBRv3 diff..."
            cd "${WORK_DIR}"

            # BBRv3 涉及的核心文件
            BBR_FILES=(
                "net/ipv4/tcp_bbr.c"
                "include/net/tcp.h"
                "include/uapi/linux/inet_diag.h"
                "net/ipv4/tcp_input.c"
                "net/ipv4/tcp_output.c"
                "net/ipv4/tcp_rate.c"
                "net/ipv4/tcp_minisocks.c"
                "net/ipv4/bpf_tcp_ca.c"
            )

            DIFF_FILE="${WORK_DIR}/bbr3-xanmod.patch"
            echo "--- BBRv3 extracted from XanMod ${XANMOD_BRANCH} ---" > "${DIFF_FILE}"
            for f in "${BBR_FILES[@]}"; do
                if [ -f "xanmod/$f" ] && [ -f "vanilla/$f" ]; then
                    diff -u "vanilla/$f" "xanmod/$f" >> "${DIFF_FILE}" 2>/dev/null || true
                elif [ -f "xanmod/$f" ]; then
                    diff -u /dev/null "xanmod/$f" >> "${DIFF_FILE}" 2>/dev/null || true
                fi
            done

            # 修正路径（diff -u 输出的路径需要调整为 a/path, b/path 格式）
            sed -i "s|--- vanilla/|--- a/|g; s|+++ xanmod/|+++ b/|g" "${DIFF_FILE}"
            sed -i "s|--- /dev/null|--- /dev/null|g" "${DIFF_FILE}"

            LINE_COUNT=$(wc -l < "${DIFF_FILE}")
            if [ "$LINE_COUNT" -gt 10 ]; then
                cp "${DIFF_FILE}" "${OUTPUT}"
                echo "  ✅ XanMod diff 已保存到: ${OUTPUT}"
                echo "  文件大小: $(wc -c < "${OUTPUT}") 字节, ${LINE_COUNT} 行"
                echo ""
                echo "  ⚠️ 注意: XanMod diff 可能包含非 BBRv3 的改动"
                echo "  建议手动检查 ${OUTPUT} 确认内容正确"
                echo ""
                echo "完成！请运行以下命令提交:"
                echo "  git add patches/${KERNEL_SERIES}/0002-bbr3.patch"
                echo "  git commit -m 'patches: add BBRv3 for ${KERNEL_SERIES} (source: XanMod diff)'"
                exit 0
            else
                echo "  ⚠️ diff 内容过少，可能无 BBRv3 差异"
            fi
        fi
    fi
else
    echo "  ℹ️ XanMod 暂无 ${XANMOD_BRANCH} 分支"
fi

# ================================================================
# 来源 3：复用上一版本补丁（需手动调整）
# ================================================================
echo ""
echo "=== 来源 3: 复用已有补丁 ==="

# 查找最近版本的补丁
LATEST_PATCH=""
for dir in "${SCRIPT_DIR}"/*/; do
    if [ -f "${dir}0002-bbr3.patch" ]; then
        LATEST_PATCH="${dir}0002-bbr3.patch"
    fi
done

if [ -n "$LATEST_PATCH" ]; then
    LATEST_VER=$(basename "$(dirname "$LATEST_PATCH")")
    echo "  找到已有补丁: ${LATEST_VER}/0002-bbr3.patch"
    echo ""
    echo "  可以尝试将 ${LATEST_VER} 的补丁应用到 ${KERNEL_SERIES} 内核:"
    echo "  1. 下载 ${KERNEL_SERIES} 内核源码"
    echo "  2. 尝试 patch --dry-run -p1 < patches/${LATEST_VER}/0002-bbr3.patch"
    echo "  3. 如果成功，直接复制:"
    echo "     cp patches/${LATEST_VER}/0002-bbr3.patch patches/${KERNEL_SERIES}/0002-bbr3.patch"
    echo ""
    echo "  BBRv3 补丁在不同内核小版本间通常兼容（如 7.0→7.1）"
    echo "  大版本升级（如 6.x→7.x）时可能需要修改"
else
    echo "  ℹ️ 未找到任何已有补丁"
fi

# ================================================================
# 来源 4：Google BBR v3 分支
# ================================================================
echo ""
echo "=== 来源 4: Google BBR 官方 v3 分支 ==="
echo "  仓库: https://github.com/google/bbr/tree/v3"
echo ""
echo "  手动提取步骤:"
echo "  1. git clone --depth=1 -b v3 https://github.com/google/bbr.git /tmp/google-bbr"
echo "  2. cd /tmp/google-bbr"
echo "  3. # 查看 BBRv3 的 commit 历史"
echo "  4. git log --oneline -- net/ipv4/tcp_bbr.c"
echo "  5. # 提取整个 BBRv3 patchset（相对于其基线 tag）"
echo "  6. git diff v6.8..HEAD -- net/ipv4/ include/net/tcp.h include/uapi/linux/inet_diag.h > bbr3.patch"
echo ""
echo "  ⚠️ Google BBR v3 分支基于较旧的内核（~6.8），"
echo "  提取的 diff 需要手动适配到 ${KERNEL_SERIES} 内核"

echo ""
echo "=========================================="
echo "所有自动来源已尝试完毕。"
echo "如需手动提取，请参考上述来源 3 或 4 的指引。"
echo "=========================================="
exit 1
