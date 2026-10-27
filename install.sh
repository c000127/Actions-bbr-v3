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
    if ! "${SUDO[@]}" apt-get update -qq || \
       ! "${SUDO[@]}" apt-get install -y --no-install-recommends "${NEED_INSTALL[@]}"; then
        echo -e "\033[31m依赖安装失败，请检查软件源和网络\033[0m" >&2
        exit 1
    fi
fi

# ── 常量 ──────────────────────────────────────────────────

KERNEL_BRAND="xanmod"
SYSCTL_CONF="${BBRV3_SYSCTL_CONF:-/etc/sysctl.d/99-${KERNEL_BRAND}.conf}"
AGGRESSIVE_CONF="${BBRV3_AGGRESSIVE_CONF:-/etc/xanmod-bbr/aggressive.conf}"
AGGRESSIVE_HELPER="${BBRV3_AGGRESSIVE_HELPER:-/usr/local/lib/xanmod-bbr/apply-aggressive.sh}"
AGGRESSIVE_UNIT="${BBRV3_AGGRESSIVE_UNIT:-/etc/systemd/system/xanmod-aggressive-bbr.service}"
AGGRESSIVE_MARKER='# Managed by Actions-bbr-v3 aggressive profile'
DOWNLOAD_DIR=$(mktemp -d) || { echo -e "\033[31m无法创建临时下载目录\033[0m" >&2; exit 1; }
trap 'rm -rf -- "$DOWNLOAD_DIR"' EXIT

# ── 工具函数 ──────────────────────────────────────────────

get_installed_packages() {
    local profile="${1:-standard}"
    dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' 'linux-image-*' 2>/dev/null \
        | awk -F '\t' -v brand="$KERNEL_BRAND" -v profile="$profile" '
            $1 == "installed" && index($2, brand) && $2 !~ /-dbg(:.*)?$/ {
                name = $2
                sub(/:.*/, "", name)
                aggressive = (name ~ /-aggressive-xanmod[0-9]+$/)
                if ((profile == "aggressive" && aggressive) || (profile == "standard" && !aggressive)) print $2
            }' || true
}

get_installed_version() {
    local pkg version profile="${1:-standard}"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        pkg=${pkg%%:*}
        version=$(echo "$pkg" | sed -E 's/^linux-image-(unsigned-)?//; s/-aggressive-xanmod[0-9]+.*$//; s/-xanmod[0-9]+.*$//')
        printf '%s\t%s\n' "$(version_sort_key "$version")" "$version"
    done < <(get_installed_packages "$profile") | sort -r | cut -f2 | head -n 1
    return 0
}

normalize_version() {
    local ver="$1"
    [[ "$ver" =~ ^([0-9]+\.[0-9]+)(-.*)?$ ]] && echo "${BASH_REMATCH[1]}.0${BASH_REMATCH[2]}" || echo "$ver"
}

# 版本排序键: 7.0.2 > 7.0.2-rc1
version_sort_key() {
    local tag="${1#aggressive-}"
    tag="${tag#x86_64-}"
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
        --retry 3 --retry-delay 2 \
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

get_release_prefix() {
    local profile="${1:-standard}" arch_filter
    arch_filter=$(get_arch_filter)
    if [[ "$profile" == "aggressive" ]]; then
        if [[ "$arch_filter" != "x86_64" ]]; then
            echo -e "\033[31m激进版目前仅支持 x86_64\033[0m" >&2
            return 1
        fi
        printf 'aggressive-%s\n' "$arch_filter"
    else
        printf '%s\n' "$arch_filter"
    fi
}

configure_aggressive_bbr() {
    local target current_algo current_qdisc
    # Do not replace files that another administrator or program owns.
    for target in "$AGGRESSIVE_CONF" "$AGGRESSIVE_HELPER" "$AGGRESSIVE_UNIT"; do
        if "${SUDO[@]}" test -L "$target"; then
            echo -e "\033[31m配置路径是符号链接，未覆盖: $target\033[0m" >&2
            return 1
        fi
        if "${SUDO[@]}" test -e "$target" && ! "${SUDO[@]}" grep -Fxq "$AGGRESSIVE_MARKER" "$target"; then
            echo -e "\033[31m配置文件已存在且不属于本项目，未覆盖: $target\033[0m" >&2
            return 1
        fi
    done
    if [[ "$AGGRESSIVE_CONF$AGGRESSIVE_HELPER" =~ [[:space:]\"\'] ]]; then
        echo -e "\033[31m配置路径含不支持的空白或引号\033[0m" >&2
        return 1
    fi

    cat > "$DOWNLOAD_DIR/aggressive.conf" <<'EOF'
# Managed by Actions-bbr-v3 aggressive profile
# Only applied when an aggressive XanMod kernel is running and no other
# congestion-control service or custom algorithm is active.
net.ipv4.tcp_congestion_control=bbr
EOF
    cat > "$DOWNLOAD_DIR/aggressive-helper" <<'EOF'
#!/bin/bash
# Managed by Actions-bbr-v3 aggressive profile
set -eu
config=${1:?missing configuration file}
kernel=$(uname -r)
[[ "$kernel" =~ -aggressive-xanmod[0-9]+$ ]] || exit 0
if systemctl is-active --quiet skyline-speederd.service || \
   systemctl is-active --quiet skyline-speeder-enable.service; then
    echo 'Skyline is active; leaving congestion control unchanged.'
    exit 0
fi
current=$(sysctl -n net.ipv4.tcp_congestion_control)
case "$current" in
    bbr|cubic|reno) ;;
    *) echo "Custom congestion control $current is active; leaving it unchanged."; exit 0 ;;
esac
available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
if [[ " $available " != *" bbr "* ]]; then
    echo 'BBR is unavailable; leaving congestion control unchanged.' >&2
    exit 1
fi
sysctl -p "$config"
EOF
    cat > "$DOWNLOAD_DIR/aggressive-unit" <<EOF
# Managed by Actions-bbr-v3 aggressive profile
[Unit]
Description=Apply BBR settings only on the aggressive XanMod kernel
After=systemd-sysctl.service skyline-speederd.service skyline-speeder-enable.service

[Service]
Type=oneshot
ExecStart=/bin/bash $AGGRESSIVE_HELPER $AGGRESSIVE_CONF

[Install]
WantedBy=multi-user.target
EOF
    if ! "${SUDO[@]}" test -e "$AGGRESSIVE_CONF" && \
       ! "${SUDO[@]}" install -D -m 0644 "$DOWNLOAD_DIR/aggressive.conf" "$AGGRESSIVE_CONF"; then
        return 1
    fi
    if ! "${SUDO[@]}" install -D -m 0755 "$DOWNLOAD_DIR/aggressive-helper" "$AGGRESSIVE_HELPER" || \
       ! "${SUDO[@]}" install -D -m 0644 "$DOWNLOAD_DIR/aggressive-unit" "$AGGRESSIVE_UNIT" || \
       ! "${SUDO[@]}" systemctl daemon-reload || \
       ! "${SUDO[@]}" systemctl enable "${AGGRESSIVE_UNIT##*/}" || \
       ! "${SUDO[@]}" systemctl start "${AGGRESSIVE_UNIT##*/}"; then
        echo -e "\033[31m激进版自动 BBR 配置未能启用\033[0m" >&2
        return 1
    fi
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    echo -e "\033[36m  激进版 BBR 配置: $AGGRESSIVE_CONF\033[0m"
    echo -e "\033[36m  仅激进内核运行且无其他拥塞控制冲突时生效；当前算法: ${current_algo:-未知}，队列: ${current_qdisc:-未知}\033[0m"
    return 0
}

remove_aggressive_bbr_config() {
    local target removed_unit=0
    for target in "$AGGRESSIVE_CONF" "$AGGRESSIVE_HELPER" "$AGGRESSIVE_UNIT"; do
        if "${SUDO[@]}" test -L "$target" || \
           { "${SUDO[@]}" test -e "$target" && ! "${SUDO[@]}" grep -Fxq "$AGGRESSIVE_MARKER" "$target"; }; then
            echo -e "\033[33m发现非本项目的配置，保留全部激进版配置文件: $target\033[0m" >&2
            return 1
        fi
    done
    if "${SUDO[@]}" test -e "$AGGRESSIVE_UNIT"; then
        if ! "${SUDO[@]}" systemctl disable --now "${AGGRESSIVE_UNIT##*/}"; then
            echo -e "\033[33m无法禁用激进版 BBR 服务，请手动检查\033[0m" >&2
            return 1
        fi
        removed_unit=1
    fi
    for target in "$AGGRESSIVE_CONF" "$AGGRESSIVE_HELPER" "$AGGRESSIVE_UNIT"; do
        if "${SUDO[@]}" test -e "$target"; then
            "${SUDO[@]}" rm -f -- "$target" || return 1
        fi
    done
    if [[ "$removed_unit" -eq 1 ]]; then
        "${SUDO[@]}" systemctl daemon-reload || return 1
    fi
    return 0
}

download_and_install() {
    local tag="$1" release_data="$2" profile="${3:-standard}"
    local urls url deb package_name pkg pkg_name running_kernel keep downloaded=0
    local -a old_pkgs=() image_pkgs=() remove_pkgs=()
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

    # 仅头文件等辅助包不能视为内核镜像；同时记录本次安装的包名，避免重装后误删。
    for deb in "$DOWNLOAD_DIR"/linux-*.deb; do
        if ! package_name=$(dpkg-deb -f "$deb" Package 2>/dev/null) || [[ -z "$package_name" ]]; then
            echo -e "\033[31m无法读取 Debian 包信息，保留当前已安装内核\033[0m"
            return 1
        fi
        case "$package_name" in
            linux-image-*-dbg) ;;
            linux-image-*)
                if [[ "$profile" == "aggressive" && ! "$package_name" =~ -aggressive-xanmod[0-9]+$ ]] || \
                   [[ "$profile" == "standard" && "$package_name" =~ -aggressive-xanmod[0-9]+$ ]]; then
                    echo -e "\033[31m内核镜像与选择的配置不匹配，保留当前已安装内核\033[0m"
                    return 1
                fi
                image_pkgs+=("$package_name")
                ;;
        esac
    done
    if [[ ${#image_pkgs[@]} -eq 0 ]]; then
        echo -e "\033[31m未下载到内核镜像包，保留当前已安装内核\033[0m"
        return 1
    fi

    # 先记录旧包；新包安装成功前绝不删除它们。
    mapfile -t old_pkgs < <(get_installed_packages "$profile")

    echo -e "\033[36m安装内核...\033[0m"
    if ! "${SUDO[@]}" dpkg -i "$DOWNLOAD_DIR"/linux-*.deb; then
        echo -e "\033[31m安装失败，已保留当前内核！\033[0m"
        return 1
    fi

    # 新包安装后只清理未运行的旧版；运行中的内核和本次安装的镜像均保留。
    if running_kernel=$(uname -r) && [[ -n "$running_kernel" ]]; then
        for pkg in "${old_pkgs[@]}"; do
            pkg_name=${pkg%%:*}
            [[ "$pkg_name" == "linux-image-$running_kernel" || "$pkg_name" == "linux-image-unsigned-$running_kernel" ]] && continue
            keep=0
            for package_name in "${image_pkgs[@]}"; do
                [[ "$pkg_name" == "$package_name" ]] && keep=1 && break
            done
            [[ $keep -eq 0 ]] && remove_pkgs+=("$pkg")
        done
    else
        echo -e "\033[33m无法确定运行中的内核，跳过旧内核清理\033[0m"
    fi
    if [[ ${#remove_pkgs[@]} -gt 0 ]] && ! "${SUDO[@]}" apt-get remove --purge -y -- "${remove_pkgs[@]}" >/dev/null; then
        echo -e "\033[33m旧内核清理失败，请在确认新内核可启动后手动处理\033[0m"
    fi

    echo -e "\033[1;32m━━━━━━ 安装完成 ━━━━━━\033[0m"
    local installed_tag="${tag#aggressive-}"
    installed_tag="${installed_tag#x86_64-}"
    installed_tag="${installed_tag#arm64-}"
    local current_algo current_qdisc
    echo -e "\033[36m  新内核: \033[1;32m$(normalize_version "$installed_tag") ($profile)\033[0m"
    if [[ "$profile" == "aggressive" ]]; then
        if ! configure_aggressive_bbr; then
            echo -e "\033[33m  内核已安装，但自动 BBR 配置未完成；请检查上方错误\033[0m"
        fi
        local installed_kernel="${image_pkgs[0]#linux-image-}"
        installed_kernel="${installed_kernel#unsigned-}"
        echo -e "\033[33m  ⚠ GRUB 默认可能仍选择标准内核；请在高级选项中选择 $installed_kernel\033[0m"
        echo -e "\033[33m    VPS 无交互启动方法请参阅 README；启动后请检查一次性启动项是否清除\033[0m"
    else
        echo -e "\033[36m  安装未修改网络配置；可在菜单中手动启用 BBR\033[0m"
        echo -e "\033[33m  ⚠ 使用该内核需要重启；安装旧版时请确认 GRUB 选择的版本\033[0m"
    fi
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    echo -e "\033[36m  当前拥塞控制: \033[1;32m${current_algo:-未知}  队列: \033[1;32m${current_qdisc:-未知}\033[0m"
    echo -n -e "\033[36m立即重启？(y/n): \033[0m"
    local ans
    read -r ans || return 0
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        "${SUDO[@]}" reboot
    fi
    return 0
}

# ── 菜单操作 ──────────────────────────────────────────────

do_enable_bbr() {
    local current_algo available config_tmp="$DOWNLOAD_DIR/bbr-sysctl.conf"

    # Skyline 会在后台选择自己的拥塞算法；即使当前暂时为 BBR，也不能覆盖它。
    if command -v systemctl >/dev/null 2>&1 && \
       { systemctl is-active --quiet skyline-speederd.service || \
         systemctl is-active --quiet skyline-speeder-enable.service; }; then
        echo -e "\033[33m检测到 Skyline Speeder 服务正在运行，保留当前拥塞控制和配置\033[0m"
        return 0
    fi

    if ! current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || [[ -z "$current_algo" ]]; then
        echo -e "\033[31m无法读取当前拥塞控制，未修改配置\033[0m"
        return 1
    fi
    case "$current_algo" in
        bbr|cubic|reno) ;;
        *)
            echo -e "\033[33m当前使用其他拥塞算法 $current_algo，保留现有设置\033[0m"
            return 0
            ;;
    esac

    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ " $available " != *" bbr "* ]]; then
        echo -e "\033[31m当前内核未提供 BBR，请在重启到新内核后重试\033[0m"
        return 1
    fi

    # 更新项目配置时保留文件中已有的其他设置。
    if [[ -f "$SYSCTL_CONF" ]]; then
        if ! awk '
            /^[[:space:]]*net[.]ipv4[.]tcp_congestion_control[[:space:]]*=/ {
                if (!written) print "net.ipv4.tcp_congestion_control=bbr"
                written = 1
                next
            }
            { print }
            END { if (!written) print "net.ipv4.tcp_congestion_control=bbr" }
        ' "$SYSCTL_CONF" > "$config_tmp"; then
            echo -e "\033[31m无法读取现有 BBR 配置，未修改拥塞控制\033[0m"
            return 1
        fi
    else
        printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr' > "$config_tmp" || return 1
    fi

    if ! "${SUDO[@]}" sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        echo -e "\033[31m无法启用 BBR，未写入持久配置\033[0m"
        return 1
    fi
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" != "bbr" ]]; then
        echo -e "\033[33m拥塞控制已被其他设置覆盖，未写入持久配置\033[0m"
        return 1
    fi
    if ! "${SUDO[@]}" tee "$SYSCTL_CONF" < "$config_tmp" >/dev/null; then
        echo -e "\033[33m无法保存 BBR 配置，重启后可能需要手动配置\033[0m"
        return 1
    fi
    echo -e "\033[1;32m已启用 BBR 并保存配置；队列和其他网络设置未更改\033[0m"
}

do_install_latest() {
    local profile="${1:-standard}"
    echo -e "\033[36m获取最新版本...\033[0m"
    local data arch_filter tags latest_tag
    arch_filter=$(get_release_prefix "$profile") || return 1
    data=$(fetch_releases) || return 1
    tags=$(echo "$data" | jq -r --arg f "${arch_filter}-" '.[] | select(.tag_name | startswith($f)) | .tag_name')
    if [[ -z "$tags" ]]; then
        echo -e "\033[31m未找到 $profile 配置的可用版本\033[0m"
        [[ "$profile" == "aggressive" ]] && echo -e "\033[33m请先运行 GitHub Actions 的激进版构建并发布 Release\033[0m"
        return 1
    fi
    tags=$(sort_tags_desc "$tags")
    latest_tag=$(echo "$tags" | head -1)

    local version="${latest_tag#"$arch_filter"-}"
    local installed
    installed=$(get_installed_version "$profile")
    echo -e "\033[36m最新版本: \033[1;32m$version\033[0m  已安装: \033[1;32m${installed:-无}\033[0m"

    if [[ -n "$installed" && "$installed" == "$(normalize_version "$version")" ]]; then
        echo -e "\033[1;32m已是最新版本\033[0m"
        echo -n -e "\033[36m仍要重新安装？(y/n): \033[0m"
        local ans
        read -r ans || return 0
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            if [[ "$profile" == "aggressive" ]] && ! configure_aggressive_bbr; then
                echo -e "\033[33m激进版已安装，但自动 BBR 配置未完成\033[0m"
            fi
            return 0
        fi
    fi

    download_and_install "$latest_tag" "$data" "$profile"
}

do_install_specific() {
    local profile="${1:-standard}"
    echo -e "\033[36m获取可用版本...\033[0m"
    local data arch_filter tags
    arch_filter=$(get_release_prefix "$profile") || return 1
    data=$(fetch_releases) || return 1
    tags=$(echo "$data" | jq -r --arg f "${arch_filter}-" '.[] | select(.tag_name | startswith($f)) | .tag_name')
    if [[ -z "$tags" ]]; then
        echo -e "\033[31m未找到 $profile 配置的可用版本\033[0m"
        [[ "$profile" == "aggressive" ]] && echo -e "\033[33m请先运行 GitHub Actions 的激进版构建并发布 Release\033[0m"
        return 1
    fi
    tags=$(sort_tags_desc "$tags")

    local installed
    installed=$(get_installed_version "$profile")
    echo ""
    local i=0
    while IFS= read -r tag; do
        i=$((i+1))
        local ver="${tag#"$arch_filter"-}"
        if [[ -n "$installed" && "$installed" == "$(normalize_version "$ver")" ]]; then
            echo -e "\033[33m  $i. $ver \033[1;32m← 已安装\033[0m"
        else
            echo -e "\033[33m  $i. $ver\033[0m"
        fi
    done <<< "$tags"

    echo ""
    echo -n -e "\033[36m选择版本编号 (0 取消): \033[0m"
    read -r choice || return 0
    [[ "$choice" == "0" ]] && return 0
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { echo -e "\033[31m无效输入\033[0m"; return 1; }

    local selected_tag
    selected_tag=$(echo "$tags" | sed -n "${choice}p")
    [[ -z "$selected_tag" ]] && { echo -e "\033[31m无效编号\033[0m"; return 1; }

    echo -e "\033[36m已选择: \033[1;32m${selected_tag#"$arch_filter"-}\033[0m"
    download_and_install "$selected_tag" "$data" "$profile"
}

do_check_status() {
    echo ""
    local installed aggressive running running_version active_installed
    installed=$(get_installed_version standard)
    aggressive=$(get_installed_version aggressive)
    running=$(uname -r)
    running_version=${running%%-xanmod*}
    running_version=${running_version%-aggressive}

    echo -e "\033[34m  ┌─\033[1;34m 📋 内核信息\033[0m"
    if [[ -n "$installed" || -n "$aggressive" ]]; then
        [[ -n "$installed" ]] && echo -e "\033[34m  │\033[0m    \033[36m已安装: \033[1;32m$installed\033[0m"
        [[ -n "$aggressive" ]] && echo -e "\033[34m  │\033[0m    \033[36m激进版: \033[1;32m$aggressive\033[0m"
        if [[ "$running" =~ -aggressive-xanmod[0-9]+$ ]]; then
            active_installed="$aggressive"
        else
            active_installed="$installed"
        fi
        if [[ "$running" == *"$KERNEL_BRAND"* && -n "$active_installed" && "$(normalize_version "$running_version")" == "$(normalize_version "$active_installed")" ]]; then
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
    if [[ "$bbr_ver" == "3" && "$algo" == "bbr" ]]; then
        echo -e "\033[34m  └\033[0m    \033[36mBBR 版本: \033[1;32mv3（已启用）\033[0m"
    elif [[ "$bbr_ver" == "3" ]]; then
        echo -e "\033[34m  └\033[0m    \033[36mBBR 版本: \033[1;32mv3（可用，当前未启用）\033[0m"
    elif [[ -n "$bbr_ver" ]]; then
        echo -e "\033[34m  └\033[0m    \033[33mBBR 版本: $bbr_ver（非 v3）\033[0m"
    elif [[ "$algo" == "bbr" ]]; then
        # 内建或缺少模块信息时，不能仅凭拥塞算法名称确定 BBR 版本。
        echo -e "\033[34m  └\033[0m    \033[36mBBR: \033[1;32m已启用（无法确定版本）\033[0m"
    else
        echo -e "\033[34m  └\033[0m    \033[33mBBR 未启用\033[0m"
    fi
}

do_uninstall() {
    local profile="${1:-standard}" other_profile
    local -a pkgs=()
    mapfile -t pkgs < <(get_installed_packages "$profile")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        echo -e "\033[33m未找到已安装的 $profile 配置内核\033[0m"
        return
    fi
    echo -e "\033[36m将卸载: \033[33m${pkgs[*]}\033[0m"
    if ! "${SUDO[@]}" apt-get remove --purge -y -- "${pkgs[@]}"; then
        echo -e "\033[31m卸载失败，已保留 BBR 配置\033[0m"
        return 1
    fi
    if [[ "$profile" == "aggressive" ]] && ! remove_aggressive_bbr_config; then
        echo -e "\033[33m激进版配置清理不完整，请手动检查\033[0m"
    fi
    if [[ "$profile" == "aggressive" ]]; then other_profile=standard; else other_profile=aggressive; fi
    if [[ -z "$(get_installed_packages "$other_profile")" ]]; then
        "${SUDO[@]}" rm -f "$SYSCTL_CONF" || echo -e "\033[33m无法删除 BBR 配置，请手动处理\033[0m"
    else
        echo -e "\033[36m另一个配置仍已安装，保留共享的 BBR 配置\033[0m"
    fi
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
    local_ver=$(get_installed_version standard)
    aggressive_ver=$(get_installed_version aggressive)
    cur_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    echo -e "\033[36m  内核: \033[1;32m${local_ver:-未安装}\033[0m  拥塞: \033[1;32m$cur_algo\033[0m  队列: \033[1;32m$cur_qdisc\033[0m"
    [[ -n "$aggressive_ver" ]] && echo -e "\033[36m  激进版: \033[1;32m$aggressive_ver\033[0m"
    echo ""
    echo -e "  \033[33m1.\033[0m 安装/更新标准版到最新版本"
    echo -e "  \033[33m2.\033[0m 手动选择标准版版本"
    echo -e "  \033[33m3.\033[0m 查看内核与 BBR 状态"
    echo -e "  \033[33m4.\033[0m 卸载标准版内核"
    echo -e "  \033[33m5.\033[0m 手动启用 BBR（保存配置）"
    echo -e "  \033[33m6.\033[0m 安装/更新激进版（实验性）"
    echo -e "  \033[33m7.\033[0m 选择激进版版本安装"
    echo -e "  \033[33m8.\033[0m 卸载激进版内核"
    echo -e "  \033[33m0.\033[0m 退出"
    echo ""
    echo -n -e "\033[36m选择 (0-8): \033[0m"
    if ! read -r action; then
        echo ""
        exit 0
    fi

    case "$action" in
        0) echo -e "\033[1;35m再见！\033[0m"; exit 0 ;;
        1) do_install_latest ;;
        2) do_install_specific ;;
        3) do_check_status ;;
        4) do_uninstall ;;
        5) do_enable_bbr ;;
        6) do_install_latest aggressive ;;
        7) do_install_specific aggressive ;;
        8) do_uninstall aggressive ;;
        *) echo -e "\033[31m无效选择\033[0m" ;;
    esac

    echo ""
    echo -n -e "\033[36m按 Enter 返回菜单...\033[0m"
    read -r || exit 0
done
