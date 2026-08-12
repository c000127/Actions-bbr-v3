#!/bin/bash
set -uo pipefail

# BBRv3 VPS 内核安装脚本
# 基于 XanMod 内核 fork，BBRv3 由 Google 官方源码预集成
# https://github.com/c000127/Actions-bbr-v3

# ── 环境检查 ──────────────────────────────────────────────

if ! command -v apt-get &>/dev/null; then
    echo -e "\033[31m此脚本仅支持 Debian/Ubuntu 系统\033[0m"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo &>/dev/null || ! sudo -v; then
        echo -e "\033[31m需要 root 权限或可用的 sudo\033[0m"
        exit 1
    fi
    SUDO=(sudo)
else
    SUDO=()
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
    echo -e "\033[31m不支持的架构: $ARCH\033[0m"
    exit 1
fi

# ── 依赖安装 ──────────────────────────────────────────────

NEED_INSTALL=()
command -v curl  &>/dev/null || NEED_INSTALL+=(curl)
command -v wget  &>/dev/null || NEED_INSTALL+=(wget)
command -v jq    &>/dev/null || NEED_INSTALL+=(jq)
dpkg -s ca-certificates   &>/dev/null 2>&1 || NEED_INSTALL+=(ca-certificates)
dpkg -s initramfs-tools   &>/dev/null 2>&1 || NEED_INSTALL+=(initramfs-tools)

if [[ ${#NEED_INSTALL[@]} -gt 0 ]]; then
    echo -e "\033[33m安装依赖: ${NEED_INSTALL[*]}\033[0m"
    "${SUDO[@]}" apt-get update -qq && "${SUDO[@]}" apt-get install -y --no-install-recommends "${NEED_INSTALL[@]}"
fi

# ── 常量 ──────────────────────────────────────────────────

KERNEL_BRAND="xanmod"
SYSCTL_CONF="/etc/sysctl.d/99-${KERNEL_BRAND}.conf"
DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf -- "$DOWNLOAD_DIR"' EXIT

# 迁移旧版配置
OLD_CONF="/etc/sysctl.d/99-c000127-bbrv3.conf"
[[ -f "$OLD_CONF" && "$OLD_CONF" != "$SYSCTL_CONF" ]] && "${SUDO[@]}" mv "$OLD_CONF" "$SYSCTL_CONF" 2>/dev/null

# ── 工具函数 ──────────────────────────────────────────────

get_installed_packages() {
    dpkg-query -W -f='${binary:Package}\n' 'linux-image-*' 2>/dev/null \
        | grep -F -- "$KERNEL_BRAND" || true
}

get_installed_version() {
    local pkg
    pkg=$(get_installed_packages | head -n 1)
    pkg=${pkg%%:*}
    if [[ -n "$pkg" ]]; then
        echo "$pkg" | sed -E 's/^linux-image-//; s/-xanmod[0-9]+.*$//'
    fi
    return 0
}

normalize_version() {
    local ver="$1"
    [[ "$ver" =~ ^([0-9]+\.[0-9]+)(-.*)?$ ]] && echo "${BASH_REMATCH[1]}.0${BASH_REMATCH[2]}" || echo "$ver"
}

# 版本排序键: 7.0.2 > 7.0.2-rc1
version_sort_key() {
    local tag="${1#x86_64-}"
    tag="${tag#arm64-}"
    tag=$(normalize_version "$tag")
    if [[ "$tag" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-rc([0-9]+))?$ ]]; then
        local rc="${BASH_REMATCH[5]:-}"
        if [[ -n "$rc" ]]; then
            printf "%08d.%08d.%08d.0.%08d" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$rc"
        else
            printf "%08d.%08d.%08d.1.999999" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        fi
    else
        echo "00000000.00000000.00000000.0.00000000"
    fi
}

sort_tags_desc() {
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        printf "%s\t%s\n" "$(version_sort_key "$tag")" "$tag"
    done <<< "$1" | sort -r | cut -f2
}

# ── 核心函数 ──────────────────────────────────────────────

fetch_releases() {
    local data
    data=$(curl --fail --silent --show-error --location \
        --retry 3 --retry-all-errors --retry-delay 2 \
        --connect-timeout 15 --max-time 60 \
        "https://api.github.com/repos/c000127/Actions-bbr-v3/releases?per_page=100") || return 1
    if [[ -z "$data" ]] || ! echo "$data" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo -e "\033[31m获取版本信息失败，请检查网络\033[0m" >&2
        return 1
    fi
    echo "$data"
}

get_arch_filter() {
    [[ "$ARCH" == "aarch64" ]] && echo "arm64" || echo "x86_64"
}

download_and_install() {
    local tag="$1" release_data="$2"
    local urls url old_pkgs downloaded=0
    urls=$(echo "$release_data" | jq -r --arg tag "$tag" \
        '.[] | select(.tag_name == $tag) | .assets[].browser_download_url')

    if [[ -z "$urls" ]]; then
        echo -e "\033[31m该 Release 没有可下载的资源\033[0m"
        return 1
    fi

    rm -f "$DOWNLOAD_DIR"/linux-*.deb
    while IFS= read -r url; do
        [[ -z "$url" || "$url" == *"linux-libc-dev"* ]] && continue
        echo -e "\033[36m下载: $(basename "$url")\033[0m"
        if ! wget --https-only --timeout=30 --tries=3 -q --show-progress "$url" -P "$DOWNLOAD_DIR"/; then
            echo -e "\033[31m下载失败，保留当前已安装内核\033[0m"
            return 1
        fi
        downloaded=$((downloaded + 1))
    done <<< "$urls"

    if [[ "$downloaded" -eq 0 ]] || ! compgen -G "$DOWNLOAD_DIR/linux-*.deb" >/dev/null; then
        echo -e "\033[31m未下载到内核 Debian 包，保留当前已安装内核\033[0m"
        return 1
    fi

    # 先记录旧包；新包安装成功前绝不删除它们，保留可启动的回退内核。
    old_pkgs=$(get_installed_packages | tr '\n' ' ')

    echo -e "\033[36m安装内核...\033[0m"
    if ! "${SUDO[@]}" dpkg -i "$DOWNLOAD_DIR"/linux-*.deb; then
        echo -e "\033[31m安装失败，已保留当前内核！\033[0m"
        return 1
    fi

    # 新包已成功安装后再清理旧版；清理失败不影响已安装的新内核。
    if [[ -n "$old_pkgs" ]] && ! "${SUDO[@]}" apt-get remove --purge -y -- $old_pkgs >/dev/null; then
        echo -e "\033[33m旧内核清理失败，请在确认新内核可启动后手动处理\033[0m"
    fi

    # 自动配置 BBR + FQ
    echo -e "\033[36m配置 BBR + FQ...\033[0m"
    "${SUDO[@]}" sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    "${SUDO[@]}" sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    "${SUDO[@]}" sysctl -w net.ipv4.tcp_ecn=2 >/dev/null 2>&1 || true
    "${SUDO[@]}" sysctl -w net.ipv4.tcp_fastopen=1027 >/dev/null 2>&1 || true

    # 持久化配置
    "${SUDO[@]}" tee "$SYSCTL_CONF" >/dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_ecn=2
net.ipv4.tcp_fastopen=1027
EOF
    "${SUDO[@]}" sysctl --system >/dev/null 2>&1 || true
    "${SUDO[@]}" rm -f "/etc/modules-load.d/${KERNEL_BRAND}-qdisc.conf"

    echo -e "\033[1;32m━━━━━━ 安装完成 ━━━━━━\033[0m"
    echo -e "\033[36m  新内核: \033[1;32m$(get_installed_version)\033[0m"
    echo -e "\033[36m  拥塞控制: \033[1;32mbbr  队列: \033[1;32mfq\033[0m"
    echo -e "\033[33m  ⚠ 需要重启生效\033[0m"
    echo -n -e "\033[36m立即重启？(y/n): \033[0m"
    read -r ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] && "${SUDO[@]}" reboot
}

# ── 菜单操作 ──────────────────────────────────────────────

do_install_latest() {
    echo -e "\033[36m获取最新版本...\033[0m"
    local data arch_filter tags latest_tag
    data=$(fetch_releases) || return 1
    arch_filter=$(get_arch_filter)
    tags=$(echo "$data" | jq -r --arg f "$arch_filter" '.[] | select(.tag_name | startswith($f)) | .tag_name')
    [[ -z "$tags" ]] && { echo -e "\033[31m未找到可用版本\033[0m"; return 1; }
    tags=$(sort_tags_desc "$tags")
    latest_tag=$(echo "$tags" | head -1)

    local version="${latest_tag#${arch_filter}-}"
    local installed
    installed=$(get_installed_version)
    echo -e "\033[36m最新版本: \033[1;32m$version\033[0m  已安装: \033[1;32m${installed:-无}\033[0m"

    if [[ -n "$installed" && "$installed" == "$(normalize_version "$version")" ]]; then
        echo -e "\033[1;32m已是最新版本\033[0m"
        echo -n -e "\033[36m仍要重新安装？(y/n): \033[0m"
        read -r ans
        [[ "$ans" != "y" && "$ans" != "Y" ]] && return 0
    fi

    download_and_install "$latest_tag" "$data"
}

do_install_specific() {
    echo -e "\033[36m获取可用版本...\033[0m"
    local data arch_filter tags
    data=$(fetch_releases) || return 1
    arch_filter=$(get_arch_filter)
    tags=$(echo "$data" | jq -r --arg f "$arch_filter" '.[] | select(.tag_name | startswith($f)) | .tag_name')
    [[ -z "$tags" ]] && { echo -e "\033[31m未找到可用版本\033[0m"; return 1; }
    tags=$(sort_tags_desc "$tags")

    local installed
    installed=$(get_installed_version)
    echo ""
    local i=0
    while IFS= read -r tag; do
        i=$((i+1))
        local ver="${tag#${arch_filter}-}"
        if [[ -n "$installed" && "$installed" == "$(normalize_version "$ver")" ]]; then
            echo -e "\033[33m  $i. $ver \033[1;32m← 已安装\033[0m"
        else
            echo -e "\033[33m  $i. $ver\033[0m"
        fi
    done <<< "$tags"

    echo ""
    echo -n -e "\033[36m选择版本编号 (0 取消): \033[0m"
    read -r choice
    [[ "$choice" == "0" ]] && return 0
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { echo -e "\033[31m无效输入\033[0m"; return 1; }

    local selected_tag
    selected_tag=$(echo "$tags" | sed -n "${choice}p")
    [[ -z "$selected_tag" ]] && { echo -e "\033[31m无效编号\033[0m"; return 1; }

    echo -e "\033[36m已选择: \033[1;32m${selected_tag#${arch_filter}-}\033[0m"
    download_and_install "$selected_tag" "$data"
}

do_check_status() {
    echo ""
    local installed running
    installed=$(get_installed_version)
    running=$(uname -r)

    echo -e "\033[34m  ┌─\033[1;34m 📋 内核信息\033[0m"
    if [[ -n "$installed" ]]; then
        echo -e "\033[34m  │\033[0m    \033[36m已安装: \033[1;32m$installed\033[0m"
        if [[ "$running" == *"$KERNEL_BRAND"* ]]; then
            echo -e "\033[34m  │\033[0m    \033[36m运行中: \033[1;32m$running ✔\033[0m"
        else
            echo -e "\033[34m  │\033[0m    \033[33m运行中: $running（需重启）\033[0m"
        fi
    else
        echo -e "\033[34m  │\033[0m    \033[36m运行中: \033[1;32m$running\033[0m"
        echo -e "\033[34m  │\033[0m    \033[33m未安装优化内核\033[0m"
    fi

    # BBR 状态
    local algo qdisc bbr_ver
    algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    bbr_ver=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')

    echo -e "\033[34m  │\033[0m"
    echo -e "\033[34m  │\033[0m    \033[36m拥塞控制: \033[1;32m$algo\033[0m  队列: \033[1;32m$qdisc\033[0m"
    if [[ "$bbr_ver" == "3" ]]; then
        echo -e "\033[34m  └\033[0m    \033[36mBBR 版本: \033[1;32mv3 ✔\033[0m"
    elif [[ "$algo" == "bbr" ]]; then
        # BBR 被编译进内核时不会有独立 .ko，modinfo 无法返回版本字段。
        echo -e "\033[34m  └\033[0m    \033[36mBBR: \033[1;32m已启用（内建，无 modinfo 版本字段）\033[0m"
    elif [[ -n "$bbr_ver" ]]; then
        echo -e "\033[34m  └\033[0m    \033[33mBBR 版本: $bbr_ver（非 v3）\033[0m"
    else
        echo -e "\033[34m  └\033[0m    \033[33mBBR 未启用\033[0m"
    fi
}

do_uninstall() {
    local pkgs
    pkgs=$(get_installed_packages | tr '\n' ' ')
    if [[ -z "$pkgs" ]]; then
        echo -e "\033[33m未找到已安装的优化内核\033[0m"
        return
    fi
    echo -e "\033[36m将卸载: \033[33m$pkgs\033[0m"
    "${SUDO[@]}" apt-get remove --purge -y -- $pkgs
    "${SUDO[@]}" rm -f "$SYSCTL_CONF"
    echo -e "\033[1;32m已卸载，请重启系统\033[0m"
}

# ── 主循环 ────────────────────────────────────────────────

while true; do
    clear
    echo ""
    echo -e "\033[1;33m  ╔═══════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;33m  ║    BBRv3 VPS 内核管理 · XanMod + Google BBRv3 ║\033[0m"
    echo -e "\033[1;33m  ╚═══════════════════════════════════════════════╝\033[0m"
    echo ""

    # 状态栏
    local_ver=$(get_installed_version)
    cur_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    echo -e "\033[36m  内核: \033[1;32m${local_ver:-未安装}\033[0m  拥塞: \033[1;32m$cur_algo\033[0m  队列: \033[1;32m$cur_qdisc\033[0m"
    echo ""
    echo -e "  \033[33m1.\033[0m 安装/更新到最新版本"
    echo -e "  \033[33m2.\033[0m 手动选择版本安装"
    echo -e "  \033[33m3.\033[0m 查看内核与 BBR 状态"
    echo -e "  \033[33m4.\033[0m 卸载优化内核"
    echo -e "  \033[33m0.\033[0m 退出"
    echo ""
    echo -n -e "\033[36m选择 (0-4): \033[0m"
    read -r action

    case "$action" in
        0) echo -e "\033[1;35m再见！\033[0m"; exit 0 ;;
        1) do_install_latest ;;
        2) do_install_specific ;;
        3) do_check_status ;;
        4) do_uninstall ;;
        *) echo -e "\033[31m无效选择\033[0m" ;;
    esac

    echo ""
    echo -n -e "\033[36m按 Enter 返回菜单...\033[0m"
    read -r
done
