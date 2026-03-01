#!/bin/bash
set -uo pipefail

# BBR v3 管理脚本 — c000127 fork
# 原始项目：https://github.com/byJoey/Actions-bbr-v3
#
# 相较上游的主要改进：
#   - set -uo pipefail + root 权限检查
#   - 依赖检查优化（跳过系统内置包，单次 apt-get update）
#   - 安全下载目录（mktemp -d + EXIT trap 自动清理）
#   - API 调用增加重试、分页和 JSON 校验
#   - 版本号规范化（支持 RC / 两段版本号）
#   - 跳过 linux-libc-dev 下载（运行时不需要）
#   - 配置文件命名迁移（自动从旧版迁移）
#   - 版本列表标记已安装版本
#   - 增强状态显示（运行内核、BBR 版本、算法+队列）
#   - apt-get remove 安全选项终结符 (--)

# 限制脚本仅支持基于 Debian/Ubuntu 的系统
if ! command -v apt-get &> /dev/null; then
    echo -e "\033[31m此脚本仅支持基于 Debian/Ubuntu 的系统，请在支持 apt-get 的系统上运行！\033[0m"
    exit 1
fi

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
        echo -e "\033[33m此脚本需要 root 权限，请输入密码以继续...\033[0m"
        sudo true || { echo -e "\033[31m无法获取 root 权限，退出。\033[0m"; exit 1; }
    fi
fi

# 检查并安装必要的依赖（仅检查 Debian 非必备包）
# dpkg, awk, sed, sysctl 属于 Debian 必备包（dpkg, mawk, sed, procps），无需检查
declare -A CMD_PKG_MAP=(
    ["curl"]="curl"
    ["wget"]="wget"
    ["jq"]="jq"
)
apt_updated=false
for cmd in "${!CMD_PKG_MAP[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "\033[33m缺少依赖：$cmd，正在安装 ${CMD_PKG_MAP[$cmd]}...\033[0m"
        if ! $apt_updated; then sudo apt-get update > /dev/null 2>&1; apt_updated=true; fi
        sudo apt-get install -y "${CMD_PKG_MAP[$cmd]}" > /dev/null 2>&1
    fi
done

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    echo -e "\033[31m(￣□￣)哇！这个脚本只支持 ARM 和 x86_64 架构哦~ 您的系统架构是：$ARCH\033[0m"
    exit 1
fi

# 内核品牌标识（用于匹配已安装的内核包）
KERNEL_BRAND="c000127-bbrv3"

# sysctl 配置文件路径
SYSCTL_CONF="/etc/sysctl.d/99-${KERNEL_BRAND}.conf"
# 模块自动加载配置文件路径
MODULES_CONF="/etc/modules-load.d/${KERNEL_BRAND}-qdisc.conf"

# 迁移旧版配置文件（从 c000127 → c000127-bbrv3）
OLD_SYSCTL_CONF="/etc/sysctl.d/99-c000127.conf"
OLD_MODULES_CONF="/etc/modules-load.d/c000127-qdisc.conf"
if [[ -f "$OLD_SYSCTL_CONF" && "$OLD_SYSCTL_CONF" != "$SYSCTL_CONF" ]]; then
    sudo mv "$OLD_SYSCTL_CONF" "$SYSCTL_CONF" 2>/dev/null
fi
if [[ -f "$OLD_MODULES_CONF" && "$OLD_MODULES_CONF" != "$MODULES_CONF" ]]; then
    sudo mv "$OLD_MODULES_CONF" "$MODULES_CONF" 2>/dev/null
fi

# 创建安全的下载目录
DOWNLOAD_DIR=$(mktemp -d)
trap "rm -rf '$DOWNLOAD_DIR'" EXIT

# 函数：清理 sysctl.d 中的旧配置
clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

# 函数：加载队列调度模块
load_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"
    
    # 检查队列算法是否已可用（通过尝试读取当前可用的 qdisc）
    # 如果 sysctl 能成功设置，说明模块已存在
    if sudo sysctl -w net.core.default_qdisc="$qdisc_name" > /dev/null 2>&1; then
        # 恢复原设置
        sudo sysctl -w net.core.default_qdisc="$CURRENT_QDISC" > /dev/null 2>&1
        return 0
    fi
    
    # 检查模块是否已加载
    if lsmod | grep -q "^${module_name//-/_}"; then
        return 0
    fi
    
    # 模块不存在，尝试加载
    echo -e "\033[36m正在加载内核模块 $module_name...\033[0m"
    if sudo modprobe "$module_name" 2>/dev/null; then
        echo -e "\033[1;32m✔ 模块 $module_name 加载成功\033[0m"
        return 0
    else
        echo -e "\033[33m⚠ 模块 $module_name 加载失败，可能内核不支持\033[0m"
        return 1
    fi
}

# 函数：询问是否永久保存更改
ask_to_save() {
    # 首先尝试加载队列调度模块
    load_qdisc_module "$QDISC"
    
    # 立即应用设置
    echo -e "\033[36m正在应用配置...\033[0m"
    sudo sysctl -w net.core.default_qdisc="$QDISC" > /dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$ALGO" > /dev/null 2>&1
    
    # 验证是否生效
    NEW_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    NEW_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    if [[ "$NEW_QDISC" == "$QDISC" && "$NEW_ALGO" == "$ALGO" ]]; then
        echo -e "\033[1;32m✔ 配置已立即生效！\033[0m"
        echo -e "\033[36m  当前队列算法：\033[1;32m$NEW_QDISC\033[0m"
        echo -e "\033[36m  当前拥塞控制：\033[1;32m$NEW_ALGO\033[0m"
    else
        echo -e "\033[31m✘ 配置应用失败！\033[0m"
        echo -e "\033[33m  队列算法期望：$QDISC，实际：$NEW_QDISC\033[0m"
        echo -e "\033[33m  拥塞控制期望：$ALGO，实际：$NEW_ALGO\033[0m"
        echo -e "\033[33m  可能原因：当前内核不支持 $QDISC 队列算法\033[0m"
        return 1
    fi
    
    echo -n -e "\033[36m(｡♥‿♥｡) 要将这些配置永久保存到 $SYSCTL_CONF 吗？(y/n): \033[0m"
    read -r SAVE
    if [[ "$SAVE" == "y" || "$SAVE" == "Y" ]]; then
        clean_sysctl_conf
        echo "net.core.default_qdisc=$QDISC" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        echo "net.ipv4.tcp_congestion_control=$ALGO" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        sudo sysctl --system > /dev/null 2>&1
        
        # 配置模块开机自动加载（fq 和 fq_codel 是内置的不需要）
        if [[ "$QDISC" == "fq" || "$QDISC" == "fq_codel" ]]; then
            # fq 和 fq_codel 是内核内置的，删除旧的模块配置文件
            sudo rm -f "$MODULES_CONF"
            echo -e "\033[1;32m(☆^ー^☆) 更改已永久保存啦~\033[0m"
        else
            echo "sch_$QDISC" | sudo tee "$MODULES_CONF" > /dev/null
            echo -e "\033[1;32m(☆^ー^☆) 更改已永久保存，模块 sch_$QDISC 将在开机时自动加载~\033[0m"
        fi
    else
        echo -e "\033[33m(⌒_⌒;) 好吧，没有永久保存，重启后会恢复原设置呢~\033[0m"
    fi
}

# 函数：规范化内核版本号（补齐 SUBLEVEL）
# "7.0-rc1" → "7.0.0-rc1"，"7.0" → "7.0.0"，"6.12.5" 不变
normalize_version() {
    local ver="$1"
    if [[ "$ver" =~ ^([0-9]+\.[0-9]+)(-.*)?$ ]]; then
        echo "${BASH_REMATCH[1]}.0${BASH_REMATCH[2]}"
    else
        echo "$ver"
    fi
}

# 函数：获取已安装的内核版本（去除品牌后缀，返回版本号+分支）
get_installed_version() {
    local pkg
    pkg=$(dpkg -l | grep "linux-image" | grep "$KERNEL_BRAND" | awk '{print $2}' | head -n 1)
    if [[ -n "$pkg" ]]; then
        # linux-image-7.0.0-rc1-mainline-c000127-bbrv3 → 7.0.0-rc1-mainline
        echo "$pkg" | sed "s/linux-image-//;s/-${KERNEL_BRAND}//"
    fi
}

# 函数：获取已安装内核的分支类型
get_installed_branch() {
    local ver
    ver=$(get_installed_version)
    if [[ -z "$ver" ]]; then
        echo ""
    elif [[ "$ver" == *"-beta"* ]]; then
        # beta 判断必须在 mainline/stable 之前，因为 beta tag 包含 mainline 字样
        echo "beta"
    elif [[ "$ver" == *"-mainline"* ]]; then
        echo "mainline"
    elif [[ "$ver" == *"-stable"* ]]; then
        echo "stable"
    else
        echo "unknown"
    fi
}

# 函数：选择内核分支（结果保存在 SELECTED_BRANCH 变量中）
select_branch() {
    echo ""
    echo -e "\033[1;33m  ╔══════════════════════════════════════╗\033[0m"
    echo -e "\033[1;33m  ║       📦 选择内核分支                ║\033[0m"
    echo -e "\033[1;33m  ╚══════════════════════════════════════╝\033[0m"
    echo ""
    echo -e "\033[32m  ┌─\033[1;32m 🟢 1. Mainline（主线）\033[0m"
    echo -e "\033[32m  │\033[0m    \033[36m维护者：Linus Torvalds\033[0m"
    echo -e "\033[32m  │\033[0m    \033[36m特点：最新特性 · 标准编译 · 安全优先\033[0m"
    echo -e "\033[32m  └─\033[0m   \033[36m周期：每 9-10 周发布新版本\033[0m"
    echo ""
    echo -e "\033[34m  ┌─\033[1;34m 🔵 2. Stable（稳定）\033[0m"
    echo -e "\033[34m  │\033[0m    \033[36m特点：Bug 修复回移 · 高可靠性\033[0m"
    echo -e "\033[34m  └─\033[0m   \033[36m周期：每周发布 · 适合生产环境\033[0m"
    echo ""
    echo -e "\033[31m  ┌─\033[1;31m 🔴 3. Beta（测试 - 激进优化）\033[0m"
    echo -e "\033[31m  │\033[0m    \033[36mCachyOS 补丁 · CPU 漏洞缓解\033[0m"
    echo -e "\033[31m  │\033[0m    \033[36mx86-64-v3 · HZ=1000 · BTF/eBPF\033[0m"
    echo -e "\033[31m  └─\033[0m   \033[36m纯 64 位 · \033[33m⚠️ 建议测试环境使用\033[0m"
    echo ""
    echo -e "\033[33m  0. 返回上一级\033[0m"
    echo ""
    while true; do
        echo -n -e "\033[36m请选择 (0-3): \033[0m"
        read -r branch_choice
        case "$branch_choice" in
            1) SELECTED_BRANCH="mainline"; return 0 ;;
            2) SELECTED_BRANCH="stable"; return 0 ;;
            3) SELECTED_BRANCH="beta"; return 0 ;;
            0)
                SELECTED_BRANCH=""
                return 1
                ;;
            *)
                echo -e "\033[31m无效输入，请重新选择\033[0m"
                ;;
        esac
    done
}

# 函数：智能分支选择（已安装则默认更新同分支，切换需二次确认）
smart_select_branch() {
    local INSTALLED_BRANCH
    INSTALLED_BRANCH=$(get_installed_branch)

    if [[ -n "$INSTALLED_BRANCH" && "$INSTALLED_BRANCH" != "unknown" ]]; then
        local BRANCH_DISPLAY
        case "$INSTALLED_BRANCH" in
            mainline) BRANCH_DISPLAY="Mainline（主线）" ;;
            stable) BRANCH_DISPLAY="Stable（稳定）" ;;
            beta) BRANCH_DISPLAY="Beta（测试 - 激进优化）" ;;
            *) BRANCH_DISPLAY="$INSTALLED_BRANCH" ;;
        esac
        echo ""
        echo -e "\033[36m检测到已安装 ${BRANCH_DISPLAY} 分支内核\033[0m"
        echo -e "\033[33m 1. 更新当前分支 (${BRANCH_DISPLAY}) 到最新版\033[0m"
        echo -e "\033[33m 2. 切换到其他分支\033[0m"
        echo -e "\033[33m 0. 返回主菜单\033[0m"
        while true; do
            echo -n -e "\033[36m请选择 (0-2，默认 1): \033[0m"
            read -r update_choice
            case "${update_choice:-1}" in
                1)
                    SELECTED_BRANCH="$INSTALLED_BRANCH"
                    return 0
                    ;;
                2)
                    select_branch || return 1
                    if [[ "$SELECTED_BRANCH" != "$INSTALLED_BRANCH" ]]; then
                        echo ""
                        echo -e "\033[31m⚠️ 您正在从 ${BRANCH_DISPLAY} 切换到 ${SELECTED_BRANCH} 分支\033[0m"
                        echo -e "\033[33m   切换分支会卸载当前内核，安装新分支的内核。\033[0m"
                        echo -n -e "\033[36m确认切换？(y/n): \033[0m"
                        read -r confirm
                        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                            echo -e "\033[33m已取消操作。\033[0m"
                            return 1
                        fi
                    fi
                    return 0
                    ;;
                0)
                    return 1
                    ;;
                *)
                    echo -e "\033[31m无效输入，请重新选择\033[0m"
                    ;;
            esac
        done
    else
        select_branch || return 1
    fi
}

# 函数：智能更新引导加载程序
update_bootloader() {
    echo -e "\033[36m正在更新引导加载程序...\033[0m"
    if command -v update-grub &> /dev/null; then
        echo -e "\033[33m检测到 GRUB，正在执行 update-grub...\033[0m"
        if sudo update-grub; then
            echo -e "\033[1;32mGRUB 更新成功！\033[0m"
            return 0
        else
            echo -e "\033[1;31mGRUB 更新失败！\033[0m"
            return 1
        fi
    else
        echo -e "\033[33m未找到 'update-grub'。您的系统可能使用 U-Boot 或其他引导程序。\033[0m"
        echo -e "\033[33m在许多 ARM 系统上，内核安装包会自动处理引导更新，通常无需手动操作。\033[0m"
        echo -e "\033[33m如果重启后新内核未生效，您可能需要手动更新引导配置，请参考您系统的文档。\033[0m"
        return 0
    fi
}

# 函数：安全地安装下载的包
install_packages() {
    if ! ls "$DOWNLOAD_DIR"/linux-*.deb &> /dev/null; then
        echo -e "\033[31m错误：未在下载目录下找到内核文件，安装中止。\033[0m"
        return 1
    fi
    
    echo -e "\033[36m开始卸载旧版内核... \033[0m"
    INSTALLED_PACKAGES=$(dpkg -l | grep "$KERNEL_BRAND" | awk '{print $2}' | tr '\n' ' ')
    if [[ -n "$INSTALLED_PACKAGES" ]]; then
        sudo apt-get remove --purge -y -- $INSTALLED_PACKAGES > /dev/null 2>&1
    fi

    echo -e "\033[36m开始安装新内核... \033[0m"
    # dpkg postinst 会自动执行 update-initramfs 和 update-grub
    if sudo dpkg -i "$DOWNLOAD_DIR"/linux-*.deb; then
        echo -e "\033[1;32m━━━━━━━━ 安装完成 ━━━━━━━━\033[0m"
        NEW_KERNEL_VER=$(get_installed_version)
        echo -e "\033[36m  新内核：    \033[1;32m${NEW_KERNEL_VER:-"未知"}\033[0m"
        echo -e "\033[33m  重启前：    $(uname -r)（旧内核仍在运行）\033[0m"
        echo -e "\033[33m  ⚠ 需要重启后生效\033[0m"
        echo -n -e "\033[33m是否立即重启？ (y/n): \033[0m"
        read -r REBOOT_NOW
        if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
            echo -e "\033[36m系统即将重启...\033[0m"
            sudo reboot
        else
            echo -e "\033[33m操作完成。请记得稍后手动重启 ('sudo reboot') 来应用新内核。\033[0m"
        fi
    else
        echo -e "\033[1;31m内核安装失败！请检查 dpkg 输出信息并手动修复。\033[0m"
    fi
}

# 函数：检查并安装最新版本
install_latest_version() {
    smart_select_branch || return 1

    echo -e "\033[36m正在从 GitHub 获取 ${SELECTED_BRANCH} 分支最新版本信息...\033[0m"
    BASE_URL="https://api.github.com/repos/c000127/Actions-bbr-v3/releases?per_page=100"
    RELEASE_DATA=$(curl -sL --retry 3 --retry-delay 2 "$BASE_URL")
    if [[ -z "$RELEASE_DATA" ]] || ! echo "$RELEASE_DATA" | jq -e 'type == "array"' > /dev/null 2>&1; then
        echo -e "\033[31m从 GitHub 获取版本信息失败。请检查网络连接或 API 状态。\033[0m"
        return 1
    fi

    local ARCH_FILTER=""
    [[ "$ARCH" == "aarch64" ]] && ARCH_FILTER="arm64"
    [[ "$ARCH" == "x86_64" ]] && ARCH_FILTER="x86_64"

    # 构建 tag 匹配正则：
    #   mainline: 包含 "mainline" 且不包含 "beta"
    #   stable:   包含 "stable" 且不包含 "beta"
    #   beta:     包含 "beta"
    local TAG_REGEX
    if [[ "$SELECTED_BRANCH" == "beta" ]]; then
        TAG_REGEX="beta"
    else
        TAG_REGEX="${SELECTED_BRANCH}(?!.*beta)"
    fi

    LATEST_TAG_NAME=$(echo "$RELEASE_DATA" | jq -r --arg filter "$ARCH_FILTER" --arg branch "$TAG_REGEX" \
        '[.[] | select(.tag_name | test($filter; "i")) | select(.tag_name | test($branch))][0].tag_name')

    if [[ -z "$LATEST_TAG_NAME" || "$LATEST_TAG_NAME" == "null" ]]; then
        echo -e "\033[31m未找到适合当前架构 ($ARCH) 的 ${SELECTED_BRANCH} 分支最新版本。\033[0m"
        return 1
    fi
    CORE_LATEST_VERSION="${LATEST_TAG_NAME#x86_64-}"
    CORE_LATEST_VERSION="${CORE_LATEST_VERSION#arm64-}"
    INSTALLED_VERSION=$(get_installed_version)
    echo -e "\033[36m${SELECTED_BRANCH} 最新版本：\033[0m\033[1;32m$CORE_LATEST_VERSION\033[0m  \033[36m已安装：\033[0m\033[1;32m${INSTALLED_VERSION:-"未安装"}\033[0m"

    # 规范化版本号：tag 中 "7.0-rc1-mainline" → "7.0.0-rc1-mainline"，与 dpkg 包名对齐
    CORE_LATEST_NORMALIZED=$(normalize_version "$CORE_LATEST_VERSION")

    if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" == "$CORE_LATEST_NORMALIZED" ]]; then
        echo -e "\033[1;32m(o'▽'o) 您已安装最新版本！\033[0m"
        echo -n -e "\033[36m是否仍要重新安装（例如内核已重新编译）？(y/n): \033[0m"
        read -r REINSTALL
        if [[ "$REINSTALL" != "y" && "$REINSTALL" != "Y" ]]; then
            return 0
        fi
    fi

    echo -e "\033[33m准备下载新版本...\033[0m"
    ASSET_URLS=$(echo "$RELEASE_DATA" | jq -r --arg tag "$LATEST_TAG_NAME" '.[] | select(.tag_name == $tag) | .assets[].browser_download_url')
    
    rm -f "$DOWNLOAD_DIR"/linux-*.deb

    for URL in $ASSET_URLS; do
        # 跳过 linux-libc-dev（仅包含 C 库头文件，运行内核不需要）
        [[ "$URL" == *"linux-libc-dev"* ]] && continue
        local FILENAME
        FILENAME=$(basename "$URL")
        echo -e "\033[36m正在下载：$FILENAME\033[0m"
        wget -q --show-progress "$URL" -P "$DOWNLOAD_DIR"/ || { echo -e "\033[31m下载失败：$FILENAME\033[0m"; return 1; }
    done
    
    install_packages
}

# 函数：手动选择分支和版本安装（先选分支，再选版本，最后确认）
install_specific_version() {
    while true; do
        select_branch || return 0

        BASE_URL="https://api.github.com/repos/c000127/Actions-bbr-v3/releases?per_page=100"
        RELEASE_DATA=$(curl -sL --retry 3 --retry-delay 2 "$BASE_URL")
        if [[ -z "$RELEASE_DATA" ]] || ! echo "$RELEASE_DATA" | jq -e 'type == "array"' > /dev/null 2>&1; then
            echo -e "\033[31m从 GitHub 获取版本信息失败。请检查网络连接或 API 状态。\033[0m"
            return 1
        fi

        local ARCH_FILTER=""
        [[ "$ARCH" == "aarch64" ]] && ARCH_FILTER="arm64"
        [[ "$ARCH" == "x86_64" ]] && ARCH_FILTER="x86_64"
        
        # 构建 tag 匹配正则（与 install_latest_version 相同逻辑）
        local TAG_REGEX
        if [[ "$SELECTED_BRANCH" == "beta" ]]; then
            TAG_REGEX="beta"
        else
            TAG_REGEX="${SELECTED_BRANCH}(?!.*beta)"
        fi

        MATCH_TAGS=$(echo "$RELEASE_DATA" | jq -r --arg filter "$ARCH_FILTER" --arg branch "$TAG_REGEX" \
            '.[] | select(.tag_name | test($filter; "i")) | select(.tag_name | test($branch)) | .tag_name')

        if [[ -z "$MATCH_TAGS" ]]; then
            echo -e "\033[31m未找到适合当前架构的 ${SELECTED_BRANCH} 分支版本。\033[0m"
            return 1
        fi

        echo -e "\033[36m以下为 ${SELECTED_BRANCH} 分支适用于当前架构的版本：\033[0m"
        IFS=$'\n' read -rd '' -a TAG_ARRAY <<<"$MATCH_TAGS"
        local INSTALLED_VERSION
        INSTALLED_VERSION=$(get_installed_version)

        for i in "${!TAG_ARRAY[@]}"; do
            local tag_ver="${TAG_ARRAY[$i]#${ARCH_FILTER}-}"
            local norm_ver
            norm_ver=$(normalize_version "$tag_ver")
            if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" == "$norm_ver" ]]; then
                echo -e "\033[33m $((i+1)). $tag_ver \033[1;32m← 已安装\033[0m"
            else
                echo -e "\033[33m $((i+1)). $tag_ver\033[0m"
            fi
        done

        echo -n -e "\033[36m请输入要安装的版本编号（0 返回）：\033[0m"
        read -r CHOICE
        
        if [[ "$CHOICE" == "0" ]]; then
            continue  # 返回分支选择
        fi
        
        if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#TAG_ARRAY[@]} )); then
            echo -e "\033[31m输入无效编号，取消操作。\033[0m"
            continue  # 返回分支选择
        fi
        
        INDEX=$((CHOICE-1))
        SELECTED_TAG="${TAG_ARRAY[$INDEX]}"
        local selected_ver="${SELECTED_TAG#${ARCH_FILTER}-}"
        echo -e "\033[36m已选择版本：\033[0m\033[1;32m$selected_ver\033[0m"

        # 检查是否切换分支，需二次确认
        local INSTALLED_BRANCH
        INSTALLED_BRANCH=$(get_installed_branch)
        if [[ -n "$INSTALLED_BRANCH" && "$INSTALLED_BRANCH" != "unknown" && "$INSTALLED_BRANCH" != "$SELECTED_BRANCH" ]]; then
            local BRANCH_DISPLAY
            case "$INSTALLED_BRANCH" in
                mainline) BRANCH_DISPLAY="Mainline（主线）" ;;
                stable) BRANCH_DISPLAY="Stable（稳定）" ;;
                beta) BRANCH_DISPLAY="Beta（测试 - 激进优化）" ;;
                *) BRANCH_DISPLAY="$INSTALLED_BRANCH" ;;
            esac
            echo ""
            echo -e "\033[31m⚠️ 您正在从 ${BRANCH_DISPLAY} 切换到 ${SELECTED_BRANCH} 分支\033[0m"
            echo -e "\033[33m   切换分支会卸载当前内核，安装新分支的内核。\033[0m"
            echo -n -e "\033[36m确认切换？(y/n): \033[0m"
            read -r confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "\033[33m已取消操作。\033[0m"
                return 0
            fi
        fi

        ASSET_URLS=$(echo "$RELEASE_DATA" | jq -r --arg tag "$SELECTED_TAG" '.[] | select(.tag_name == $tag) | .assets[].browser_download_url')
        
        rm -f "$DOWNLOAD_DIR"/linux-*.deb
        
        for URL in $ASSET_URLS; do
            [[ "$URL" == *"linux-libc-dev"* ]] && continue
            local FILENAME
            FILENAME=$(basename "$URL")
            echo -e "\033[36m下载中：$FILENAME\033[0m"
            wget -q --show-progress "$URL" -P "$DOWNLOAD_DIR"/ || { echo -e "\033[31m下载失败：$FILENAME\033[0m"; return 1; }
        done

        install_packages
        return 0
    done
}

# 美化输出的分隔线
print_separator() {
    echo -e "\033[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# --- 主要执行流程 ---

RUNNING_KERNEL=$(uname -r)

while true; do

clear
print_separator
echo -e "\033[1;35m(☆ω☆)✧*｡ 欢迎来到 BBR 管理脚本世界哒！ ✧*｡(☆ω☆)\033[0m"
print_separator
# 每次循环刷新状态信息
INSTALLED_BBR_VER=$(get_installed_version)
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
CURRENT_QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')
if [[ -n "$INSTALLED_BBR_VER" ]]; then
    INSTALLED_BRANCH=$(get_installed_branch)
    case "$INSTALLED_BRANCH" in
        mainline) BRANCH_LABEL="Mainline（主线）" ;;
        stable) BRANCH_LABEL="Stable（稳定）" ;;
        beta) BRANCH_LABEL="Beta（测试 - 激进优化）" ;;
        *) BRANCH_LABEL="未知分支" ;;
    esac
    echo -e "\033[36m内核版本：\033[0m\033[1;32m${INSTALLED_BBR_VER}\033[0m"
    echo -e "\033[36m内核分支：\033[0m\033[1;32m${BRANCH_LABEL}\033[0m"
else
    echo -e "\033[36m运行内核：\033[0m\033[1;32m$RUNNING_KERNEL\033[0m\033[33m（未安装优化内核）\033[0m"
fi
echo -e "\033[36m拥塞控制：\033[0m\033[1;32m$CURRENT_ALGO\033[0m  \033[36m队列算法：\033[0m\033[1;32m$CURRENT_QDISC\033[0m"
print_separator
echo -e "\033[1;33m作者：C000127  |  Fork of byJoey/Actions-bbr-v3"
print_separator

echo -e "\033[1;33m╭( ･ㅂ･)و ✧ 你可以选择以下操作哦：\033[0m"
echo -e "\033[33m 1. 🚀 安装或更新 VPS 优化内核 (选择分支，安装最新版)\033[0m"
echo -e "\033[33m 2. 📚 手动选择分支和版本安装\033[0m"
echo -e "\033[33m 3. 🔍 查看内核与 BBR 状态\033[0m"
echo -e "\033[33m 4. ⚡ 启用 BBR + FQ\033[0m"
echo -e "\033[33m 5. ⚡ 启用 BBR + FQ_CODEL\033[0m"
echo -e "\033[33m 6. ⚡ 启用 BBR + FQ_PIE\033[0m"
echo -e "\033[33m 7. ⚡ 启用 BBR + CAKE\033[0m"
echo -e "\033[33m 8. 🗑️  卸载优化内核\033[0m"
print_separator
echo -e "\033[33m 0. 🚪 退出脚本\033[0m"
print_separator
echo -n -e "\033[36m请选择一个操作 (0-8) (｡・ω・｡): \033[0m"
read -r ACTION

case "$ACTION" in
    0)
        echo -e "\033[1;35m(｡･ω･｡)ﾉ 拜拜~ 下次再见哦！\033[0m"
        exit 0
        ;;
    1)
        echo -e "\033[1;32m٩(｡•́‿•̀｡)۶ 您选择了安装或更新内核！\033[0m"
        install_latest_version
        continue
        ;;
    2)
        echo -e "\033[1;32m(｡･∀･)ﾉﾞ 您选择了手动选择版本安装！\033[0m"
        install_specific_version
        continue
        ;;
    3)
        echo ""
        # 内核版本信息
        INSTALLED_VER=$(get_installed_version)
        INSTALLED_BR=$(get_installed_branch)
        echo -e "\033[34m──────────── \033[1;33m📋 内核信息 \033[0m\033[34m────────────\033[0m"
        RUNNING_VER=$(uname -r)
        if [[ -z "$INSTALLED_VER" ]]; then
            echo -e "\033[36m  运行内核：\033[0m\033[1;32m$RUNNING_VER\033[0m"
            echo -e "\033[33m  未检测到由本脚本安装的优化内核。\033[0m"
        elif [[ "$RUNNING_VER" == *"$KERNEL_BRAND"* ]]; then
            # 运行的就是已安装的优化内核
            echo -e "\033[36m  内核：    \033[0m\033[1;32m$INSTALLED_VER\033[0m"
        else
            # 已安装但未重启，运行的是旧内核
            echo -e "\033[36m  已安装：  \033[0m\033[1;32m$INSTALLED_VER\033[0m\033[33m（重启后生效）\033[0m"
            echo -e "\033[33m  运行中：  $RUNNING_VER（旧内核）\033[0m"
        fi
        if [[ -n "$INSTALLED_VER" ]]; then
            case "$INSTALLED_BR" in
                mainline)
                    echo -e "\033[36m  分支：    \033[0m\033[1;32mMainline（主线）\033[0m"
                    echo -e "\033[36m  特点：    标准编译 | CPU 漏洞缓解 | 安全优先\033[0m"
                    ;;
                stable)
                    echo -e "\033[36m  分支：    \033[0m\033[1;32mStable（稳定）\033[0m"
                    echo -e "\033[36m  特点：    稳定分支 | 仅含 Bug 修复\033[0m"
                    ;;
                beta)
                    echo -e "\033[36m  分支：    \033[0m\033[1;31mBeta（测试 - 激进优化）\033[0m"
                    echo -e "\033[36m  特点：    CPU 漏洞缓解 | x86-64-v3 | HZ=1000\033[0m"
                    echo -e "\033[36m            BTF/eBPF | 纯 64 位 | CachyOS 补丁\033[0m"
                    ;;
                *)
                    echo -e "\033[36m  分支：    \033[0m\033[33m未知\033[0m"
                    ;;
            esac
        fi
        echo ""
        # BBR 状态检查
        echo -e "\033[34m──────────── \033[1;33m🔍 BBR 状态 \033[0m\033[34m────────────\033[0m"
        BBR_MODULE_INFO=$(modinfo tcp_bbr 2>/dev/null)
        if [[ -z "$BBR_MODULE_INFO" ]]; then
            echo -e "\033[36m  正在刷新模块依赖...\033[0m"
            sudo depmod -a
            BBR_MODULE_INFO=$(modinfo tcp_bbr 2>/dev/null)
        fi
        if [[ -z "$BBR_MODULE_INFO" ]]; then
            echo -e "\033[31m  ⚠ 未加载 tcp_bbr 模块，请先安装内核并重启\033[0m"
        else
            BBR_VERSION=$(echo "$BBR_MODULE_INFO" | awk '/^version:/ {print $2}')
            CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
            CURRENT_QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')

            if [[ "$BBR_VERSION" == "3" ]]; then
                echo -e "\033[36m  BBR 版本：\033[0m\033[1;32m$BBR_VERSION (v3) ✔\033[0m"
            else
                echo -e "\033[33m  BBR 版本：$BBR_VERSION（非 v3）⚠\033[0m"
            fi
            if [[ "$CURRENT_ALGO" == "bbr" ]]; then
                echo -e "\033[36m  拥塞控制：\033[0m\033[1;32m$CURRENT_ALGO ✔\033[0m"
            else
                echo -e "\033[33m  拥塞控制：$CURRENT_ALGO（非 bbr）⚠\033[0m"
            fi
            echo -e "\033[36m  队列算法：\033[0m\033[1;32m$CURRENT_QDISC ✔\033[0m"

            echo -e "\033[34m─────────────────────────────────────\033[0m"
            if [[ "$BBR_VERSION" == "3" && "$CURRENT_ALGO" == "bbr" ]]; then
                echo -e "\033[1;32m  ヽ(✿ﾟ▽ﾟ)ノ BBR v3 已正确安装并生效！\033[0m"
            else
                echo -e "\033[33m  BBR v3 未完全生效，请安装内核并重启后使用选项 4-7 启用\033[0m"
            fi
        fi
        ;;
    4)
        echo -e "\033[1;32m(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧ 使用 BBR + FQ 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq"
        ask_to_save
        ;;
    5)
        echo -e "\033[1;32m(๑•̀ㅂ•́)و✧ 使用 BBR + FQ_CODEL 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq_codel"
        ask_to_save
        ;;
    6)
        echo -e "\033[1;32m٩(•‿•)۶ 使用 BBR + FQ_PIE 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq_pie"
        ask_to_save
        ;;
    7)
        echo -e "\033[1;32m(ﾉ≧∀≦)ﾉ 使用 BBR + CAKE 加速！\033[0m"
        ALGO="bbr"
        QDISC="cake"
        ask_to_save
        ;;
    8)
        echo -e "\033[1;32mヽ(・∀・)ノ 您选择了卸载 BBR 内核！\033[0m"
        PACKAGES_TO_REMOVE=$(dpkg -l | grep "$KERNEL_BRAND" | awk '{print $2}' | tr '\n' ' ')
        if [[ -n "$PACKAGES_TO_REMOVE" ]]; then
            echo -e "\033[36m将要卸载以下内核包: \033[33m$PACKAGES_TO_REMOVE\033[0m"
            sudo apt-get remove --purge -y -- $PACKAGES_TO_REMOVE
            update_bootloader
            echo -e "\033[1;32m内核包已卸载。请记得重启系统。\033[0m"
        else
            echo -e "\033[33m未找到由本脚本安装的 '$KERNEL_BRAND' 内核包。\033[0m"
        fi
        ;;
    *)
        echo -e "\033[31m(￣▽￣)ゞ 无效输入，请输入 0-8 之间的数字哦~\033[0m"
        continue
        ;;
esac

# 操作完成后暂停，让用户查看输出
echo ""
echo -n -e "\033[36m按回车键返回主菜单...\033[0m"
read -r

done  # while true
