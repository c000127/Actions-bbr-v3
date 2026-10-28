#!/bin/bash
set -uo pipefail

# Use color only for interactive terminals that support it; logs stay readable.
UI_RED='' UI_YELLOW='' UI_CYAN=''
UI_BOLD_GREEN='' UI_BOLD_YELLOW='' UI_BOLD_BLUE='' UI_BOLD_MAGENTA='' UI_RESET=''
if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != dumb && -z "${NO_COLOR:-}" ]]; then
    UI_RED=$'\033[31m' UI_YELLOW=$'\033[33m' UI_CYAN=$'\033[36m'
    UI_BOLD_GREEN=$'\033[1;32m' UI_BOLD_YELLOW=$'\033[1;33m'
    UI_BOLD_BLUE=$'\033[1;34m' UI_BOLD_MAGENTA=$'\033[1;35m' UI_RESET=$'\033[0m'
fi

# BBRv3 VPS 内核安装脚本
# 基于 XanMod 内核 fork，BBRv3 由 Google 官方源码预集成
# https://github.com/c000127/Actions-bbr-v3

# ── 环境检查 ──────────────────────────────────────────────

if ! command -v apt-get &>/dev/null; then
    echo -e "${UI_RED}此脚本需要 apt；项目支持 Debian 13 及以后版本${UI_RESET}"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo &>/dev/null || ! sudo -v; then
        echo -e "${UI_RED}需要 root 权限或可用的 sudo${UI_RESET}"
        exit 1
    fi
    SUDO=(sudo)
else
    SUDO=()
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
    echo -e "${UI_RED}不支持的架构: $ARCH${UI_RESET}"
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
    echo -e "${UI_YELLOW}安装依赖: ${NEED_INSTALL[*]}${UI_RESET}"
    if ! "${SUDO[@]}" apt-get update -qq || \
       ! "${SUDO[@]}" apt-get install -y --no-install-recommends "${NEED_INSTALL[@]}"; then
        echo -e "${UI_RED}依赖安装失败，请检查软件源和网络${UI_RESET}" >&2
        exit 1
    fi
fi

# ── 常量 ──────────────────────────────────────────────────

KERNEL_BRAND="xanmod"
SYSCTL_CONF="${BBRV3_SYSCTL_CONF:-/etc/sysctl.d/99-${KERNEL_BRAND}.conf}"
AGGRESSIVE_CONF="${BBRV3_AGGRESSIVE_CONF:-/etc/sysctl.d/99-xanmod-aggressive.profile}"
AGGRESSIVE_LEGACY_CONF="${BBRV3_AGGRESSIVE_LEGACY_CONF:-/etc/xanmod-bbr/aggressive.conf}"
AGGRESSIVE_HELPER="${BBRV3_AGGRESSIVE_HELPER:-/usr/local/lib/xanmod-bbr/apply-aggressive.sh}"
AGGRESSIVE_UNIT="${BBRV3_AGGRESSIVE_UNIT:-/etc/systemd/system/xanmod-aggressive-bbr.service}"
AGGRESSIVE_MARKER='# Managed by Actions-bbr-v3 aggressive profile'
MANAGED_PACKAGES="${BBRV3_MANAGED_PACKAGES:-/var/lib/xanmod-bbr/managed-packages}"
MANAGED_MARKER='# Managed by Actions-bbr-v3 package registry'
DOWNLOAD_DIR=$(mktemp -d) || { echo -e "${UI_RED}无法创建临时下载目录${UI_RESET}" >&2; exit 1; }
trap 'rm -rf -- "$DOWNLOAD_DIR"' EXIT

# ── 工具函数 ──────────────────────────────────────────────

get_installed_packages() {
    local profile="${1:-standard}"
    dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' 'linux-image-*' 2>/dev/null \
        | awk -F '\t' -v brand="$KERNEL_BRAND" -v profile="$profile" '
            $1 == "installed" {
                name = $2
                sub(/:.*/, "", name)
                # Upstream x64v2/x64v3 and other third-party XanMod variants
                # do not use this project package naming pattern.
                if (name !~ /^linux-image-(unsigned-)?[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?(-b[0-9a-f]{10}r[0-9a-f]+a[0-9]+)?(-aggressive)?-xanmod[0-9]+$/) next
                aggressive = (name ~ /-aggressive-xanmod[0-9]+$/)
                if ((profile == "aggressive" && aggressive) || (profile == "standard" && !aggressive)) print $2
            }' || true
}

get_managed_packages() {
    if "${SUDO[@]}" test -L "$MANAGED_PACKAGES" || \
       ! "${SUDO[@]}" test -f "$MANAGED_PACKAGES" || \
       ! "${SUDO[@]}" grep -Fxq "$MANAGED_MARKER" "$MANAGED_PACKAGES"; then
        return 0
    fi
    "${SUDO[@]}" cat "$MANAGED_PACKAGES" | awk -F '\t' \
        '($1 == "standard" || $1 == "aggressive") && $2 ~ /^linux-(image|headers)-[a-zA-Z0-9.+-]+$/ { print $1 "\t" $2 }'
}

write_managed_packages() {
    local source=$1 staged="${MANAGED_PACKAGES}.tmp.$$"
    if "${SUDO[@]}" test -e "$staged" || "${SUDO[@]}" test -L "$staged"; then
        return 1
    fi
    if ! "${SUDO[@]}" install -D -m 0644 "$source" "$staged"; then
        "${SUDO[@]}" rm -f -- "$staged" || true
        return 1
    fi
    if "${SUDO[@]}" test -L "$MANAGED_PACKAGES" || ! "${SUDO[@]}" mv -f -- "$staged" "$MANAGED_PACKAGES"; then
        "${SUDO[@]}" rm -f -- "$staged" || true
        return 1
    fi
}

record_managed_packages() {
    local profile=$1 package temp="$DOWNLOAD_DIR/managed-packages"
    shift
    if "${SUDO[@]}" test -L "$MANAGED_PACKAGES" || \
       { "${SUDO[@]}" test -e "$MANAGED_PACKAGES" && ! "${SUDO[@]}" grep -Fxq "$MANAGED_MARKER" "$MANAGED_PACKAGES"; }; then
        echo -e "${UI_YELLOW}包记录文件不属于本项目或是符号链接，未覆盖: $MANAGED_PACKAGES${UI_RESET}" >&2
        return 1
    fi
    get_managed_packages > "$temp.existing" || return 1
    {
        cat "$temp.existing"
        for package in "$@"; do
            [[ "$package" =~ ^linux-(image|headers)-[a-zA-Z0-9.+-]+$ ]] || continue
            printf '%s\t%s\n' "$profile" "$package"
        done
    } | LC_ALL=C sort -u > "$temp.entries" || return 1
    { printf '%s\n' "$MANAGED_MARKER"; cat "$temp.entries"; } > "$temp" || return 1
    write_managed_packages "$temp"
}

forget_managed_packages() {
    local temp="$DOWNLOAD_DIR/managed-packages" package
    [[ $# -gt 0 ]] || return 0
    if "${SUDO[@]}" test -L "$MANAGED_PACKAGES" || \
       ! "${SUDO[@]}" test -f "$MANAGED_PACKAGES" || \
       ! "${SUDO[@]}" grep -Fxq "$MANAGED_MARKER" "$MANAGED_PACKAGES"; then
        return 0
    fi
    get_managed_packages > "$temp.entries" || return 1
    for package in "$@"; do
        awk -F '\t' -v package="${package%%:*}" '$2 != package' "$temp.entries" > "$temp.next" || return 1
        mv "$temp.next" "$temp.entries" || return 1
    done
    { printf '%s\n' "$MANAGED_MARKER"; cat "$temp.entries"; } > "$temp" || return 1
    write_managed_packages "$temp"
}

get_installed_version() {
    local pkg version profile="${1:-standard}"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        pkg=${pkg%%:*}
        version=$(echo "$pkg" | sed -E 's/^linux-image-(unsigned-)?//; s/-aggressive-xanmod[0-9]+.*$//; s/-xanmod[0-9]+.*$//; s/-b[0-9a-f]{10}r[0-9a-f]+a[0-9]+$//')
        printf '%s\t%s\n' "$(version_sort_key "$version")" "$version"
    done < <(get_installed_packages "$profile") | sort -r | cut -f2 | head -n 1
    return 0
}

normalize_version() {
    local ver="$1"
    [[ "$ver" =~ ^([0-9]+\.[0-9]+)(-.*)?$ ]] && echo "${BASH_REMATCH[1]}.0${BASH_REMATCH[2]}" || echo "$ver"
}

# Installed package names and release asset URLs both carry the XanMod revision.
get_xanmod_revision() {
    local version="$1" profile="$2" entry name candidate revision highest=""
    while IFS= read -r entry; do
        name=${entry##*/}
        name=${name%%_*}
        name=${name%%:*}
        [[ "$name" =~ ^linux-image-(unsigned-)?(.+)-xanmod([0-9]{1,6})$ ]] || continue
        candidate=${BASH_REMATCH[2]}
        revision=$((10#${BASH_REMATCH[3]}))
        if [[ "$profile" == "aggressive" ]]; then
            [[ "$candidate" == *-aggressive ]] || continue
            candidate=${candidate%-aggressive}
        else
            [[ "$candidate" != *-aggressive ]] || continue
        fi
        if [[ "$candidate" =~ ^(.+)-b[0-9a-f]{10}r[0-9a-f]+a[0-9]+$ ]]; then
            candidate=${BASH_REMATCH[1]}
        fi
        [[ "$(normalize_version "$candidate")" == "$(normalize_version "$version")" ]] || continue
        if [[ -z "$highest" ]] || (( revision > highest )); then
            highest=$revision
        fi
    done
    [[ -z "$highest" ]] || printf '%s\n' "$highest"
    return 0
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

# Show the actual Debian image names, including the XanMod revision.
get_installed_kernels() {
    local profile="${1:-standard}" pkg kernel version revision build_run build_attempt
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        pkg=${pkg%%:*}
        kernel=${pkg#linux-image-}
        kernel=${kernel#unsigned-}
        version=${kernel%-xanmod*}
        version=${version%-aggressive}
        if [[ "$version" =~ ^(.+)-b[0-9a-f]{10}r[0-9a-f]+a[0-9]+$ ]]; then
            version=${BASH_REMATCH[1]}
        fi
        revision=0
        if [[ "$kernel" =~ -xanmod([0-9]{1,6})$ ]]; then
            revision=$((10#${BASH_REMATCH[1]}))
        fi
        build_run=0; build_attempt=0
        if [[ "$kernel" =~ -b[0-9a-f]{10}r([0-9a-f]+)a([0-9]+)(-aggressive)?-xanmod[0-9]+$ ]]; then
            build_run=$((16#${BASH_REMATCH[1]}))
            build_attempt=$((10#${BASH_REMATCH[2]}))
        fi
        printf '%s\t%06d\t%020d\t%06d\t%s\n' "$(version_sort_key "$version")" "$revision" "$build_run" "$build_attempt" "$kernel"
    done < <(get_installed_packages "$profile") | LC_ALL=C sort -ru | cut -f5
    return 0
}

profile_label() {
    if [[ "${1:-standard}" == aggressive ]]; then printf '激进版'; else printf '标准版'; fi
}

# Identify the running profile from uname, never from the newest installed image.
running_profile() {
    local kernel="${1:-}"
    if [[ "$kernel" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?(-b[0-9a-f]{10}r[0-9a-f]+a[0-9]+)?-aggressive-xanmod[0-9]+$ ]]; then
        printf 'aggressive'
    elif [[ "$kernel" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?(-b[0-9a-f]{10}r[0-9a-f]+a[0-9]+)?-xanmod[0-9]+$ ]]; then
        printf 'standard'
    else
        printf 'unknown'
    fi
}

running_profile_description() {
    case "$1" in
        standard) printf '标准版（依据运行内核标识）' ;;
        aggressive) printf '激进版（依据运行内核标识）' ;;
        *)
            if [[ -z "${2:-}" ]]; then
                printf '无法识别（无法读取运行内核）'
            else
                printf '无法识别（运行内核不符合本项目命名）'
            fi
            ;;
    esac
}

default_bbr_description() {
    local profile="$1" algo="$2"
    if [[ -z "$algo" ]]; then
        printf '未知（无法读取默认拥塞算法）'
    elif [[ "$algo" != bbr ]]; then
        printf '未作为默认算法（当前默认 %s）' "$algo"
    else
        case "$profile" in
            standard) printf '标准版 BBR（新连接默认使用，按内核标识推断）' ;;
            aggressive) printf '激进版 BBR（新连接默认使用，按内核标识推断）' ;;
            *) printf 'BBR 已设为默认，但无法确认标准版或激进版' ;;
        esac
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
    if ! data=$(curl --fail --silent --show-error --location \
        --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 60 \
        "https://api.github.com/repos/c000127/Actions-bbr-v3/releases?per_page=100"); then
        echo -e "${UI_RED}无法查询 GitHub Release；请检查网络、API 限流及上方错误后重试。${UI_RESET}" >&2
        return 1
    fi
    if [[ -z "$data" ]] || ! echo "$data" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo -e "${UI_RED}获取版本信息失败，请检查网络${UI_RESET}" >&2
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
            echo -e "${UI_RED}激进版目前仅支持 x86_64${UI_RESET}" >&2
            return 1
        fi
        printf 'aggressive-%s\n' "$arch_filter"
    else
        printf '%s\n' "$arch_filter"
    fi
}

# A published manifest is the atomic pointer to a complete build. Uploaded
# assets from an interrupted build are ignored until that pointer changes.
get_release_assets() {
    local tag=$1 release_data=$2 deb_arch=amd64
    [[ "${ARCH:-x86_64}" == aarch64 ]] && deb_arch=arm64
    if ! printf '%s\n' "$release_data" | jq -er --arg tag "$tag" --arg arch "$deb_arch" '
        def selected($release; $entry):
            if (($entry.name | type) != "string") or
               (($entry.name | endswith("_" + $arch + ".deb")) | not) or
               (($entry.sha256 | type) != "string") or
               (($entry.sha256 | test("^[0-9a-f]{64}$")) | not) or
               (($entry.size | type) != "number") then error("invalid manifest asset") else . end |
            [$release.assets[] | select(.name == $entry.name and .state == "uploaded" and .size == $entry.size)] |
            if length != 1 then error("missing manifest asset") else .[0] end |
            [.browser_download_url, $entry.sha256] | @tsv;
        [.[] | select(.tag_name == $tag)] |
        (if length != 1 then error("release not found") else .[0] end) as $release |
        if (($release.body // "") | contains("<!-- BBR_BUILD_V1 ")) then
            (($release.body | capture("<!-- BBR_BUILD_V1 (?<json>[^\\r\\n]*) -->").json) | fromjson) as $m |
            if $m.schema != 1 or ($m.assets | type) != "object" then error("invalid build manifest") else . end |
            selected($release; $m.assets.image), selected($release; $m.assets.headers)
        else
            [$release.assets[] | select(.state == "uploaded") |
                select((.name | test("-build[0-9]+a[0-9]+_(amd64|arm64)\\.deb$")) | not) |
                select(.name | endswith("_" + $arch + ".deb"))] as $legacy |
            ([$legacy[] | select(.name | test("^linux-image-(unsigned-)?[0-9]+\\.[0-9]+(\\.[0-9]+)?(-rc[0-9]+)?(-aggressive)?-xanmod[0-9]+_.*_(amd64|arm64)\\.deb$"))] |
                sort_by(.name | capture("-xanmod(?<revision>[0-9]+)_").revision | tonumber) | last) as $image |
            if $image == null then error("no complete legacy image") else . end |
            ($image.name | capture("^linux-image-(?:unsigned-)?(?<kernel>[^_]+)_").kernel) as $kernel |
            ([$legacy[] | select(.name | startswith("linux-headers-" + $kernel + "_"))] | sort_by(.name) | last) as $headers |
            ([$image.browser_download_url, "-"] | @tsv),
            (if $headers == null then empty else [$headers.browser_download_url, "-"] | @tsv end)
        end
    '; then
        echo -e "${UI_RED}Release 的构建记录或资源不完整，已保留当前内核。${UI_RESET}" >&2
        return 1
    fi
}

configure_aggressive_bbr() {
    local target current_algo current_qdisc running_kernel legacy_managed=0 config_source
    # Do not replace files that another administrator or program owns.
    for target in "$AGGRESSIVE_CONF" "$AGGRESSIVE_HELPER" "$AGGRESSIVE_UNIT"; do
        if "${SUDO[@]}" test -L "$target"; then
            echo -e "${UI_RED}配置路径是符号链接，未覆盖: $target${UI_RESET}" >&2
            return 1
        fi
        if "${SUDO[@]}" test -e "$target" && ! "${SUDO[@]}" grep -Fxq "$AGGRESSIVE_MARKER" "$target"; then
            echo -e "${UI_RED}配置文件已存在且不属于本项目，未覆盖: $target${UI_RESET}" >&2
            return 1
        fi
    done
    if [[ "$AGGRESSIVE_CONF$AGGRESSIVE_HELPER" =~ [[:space:]\"\'] ]]; then
        echo -e "${UI_RED}配置路径含不支持的空白或引号${UI_RESET}" >&2
        return 1
    fi
    if [[ "$AGGRESSIVE_LEGACY_CONF" != "$AGGRESSIVE_CONF" ]] && \
       "${SUDO[@]}" test -e "$AGGRESSIVE_LEGACY_CONF"; then
        if ! "${SUDO[@]}" test -L "$AGGRESSIVE_LEGACY_CONF" && \
           "${SUDO[@]}" test -f "$AGGRESSIVE_LEGACY_CONF" && \
           "${SUDO[@]}" grep -Fxq "$AGGRESSIVE_MARKER" "$AGGRESSIVE_LEGACY_CONF"; then
            legacy_managed=1
        else
            echo -e "${UI_YELLOW}旧配置不属于本项目或是符号链接，将保留: $AGGRESSIVE_LEGACY_CONF${UI_RESET}" >&2
        fi
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
    bbr) ;;
    *) echo "Congestion control $current may be managed elsewhere; leaving it unchanged."; exit 0 ;;
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
    if ! "${SUDO[@]}" test -e "$AGGRESSIVE_CONF"; then
        config_source="$DOWNLOAD_DIR/aggressive.conf"
        [[ "$legacy_managed" -eq 1 ]] && config_source="$AGGRESSIVE_LEGACY_CONF"
        if ! "${SUDO[@]}" install -D -m 0644 "$config_source" "$AGGRESSIVE_CONF"; then
            echo -e "${UI_RED}无法保存激进版 BBR 配置，旧配置将保留${UI_RESET}" >&2
            return 1
        fi
    fi
    if ! "${SUDO[@]}" install -D -m 0755 "$DOWNLOAD_DIR/aggressive-helper" "$AGGRESSIVE_HELPER" || \
       ! "${SUDO[@]}" install -D -m 0644 "$DOWNLOAD_DIR/aggressive-unit" "$AGGRESSIVE_UNIT" || \
       ! "${SUDO[@]}" systemctl daemon-reload || \
       ! "${SUDO[@]}" systemctl enable "${AGGRESSIVE_UNIT##*/}" || \
       ! "${SUDO[@]}" systemctl start "${AGGRESSIVE_UNIT##*/}"; then
        echo -e "${UI_RED}激进版自动 BBR 配置未能启用${UI_RESET}" >&2
        return 1
    fi
    if [[ "$legacy_managed" -eq 1 ]]; then
        if "${SUDO[@]}" cmp -s -- "$AGGRESSIVE_LEGACY_CONF" "$AGGRESSIVE_CONF"; then
            if "${SUDO[@]}" rm -f -- "$AGGRESSIVE_LEGACY_CONF"; then
                echo -e "${UI_CYAN}  已将旧版激进 BBR 配置迁移至 $AGGRESSIVE_CONF${UI_RESET}"
            else
                echo -e "${UI_YELLOW}  新配置已保存，旧配置无法删除，请手动检查: $AGGRESSIVE_LEGACY_CONF${UI_RESET}" >&2
            fi
        else
            echo -e "${UI_YELLOW}  新旧配置内容不同，已保留旧配置供检查: $AGGRESSIVE_LEGACY_CONF${UI_RESET}" >&2
        fi
    fi
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    running_kernel=$(uname -r 2>/dev/null || true)
    echo -e "${UI_CYAN}  激进版 BBR 配置: $AGGRESSIVE_CONF${UI_RESET}"
    echo -e "${UI_CYAN}  .profile 由激进版服务按条件加载，不会被 sysctl --system 无条件应用。${UI_RESET}"
    echo -e "${UI_CYAN}  仅激进内核运行且无其他拥塞控制冲突时生效；当前默认算法: ${current_algo:-未知}，默认队列: ${current_qdisc:-未知}${UI_RESET}"
    if systemctl is-active --quiet skyline-speederd.service || \
       systemctl is-active --quiet skyline-speeder-enable.service; then
        echo -e "${UI_YELLOW}  检测到 Skyline 正在运行，已保留其拥塞控制${UI_RESET}"
    elif [[ -n "$current_algo" && "$current_algo" != bbr ]]; then
        echo -e "${UI_YELLOW}  检测到其他拥塞算法 $current_algo，已保留现有设置；如确认没有其他服务管理，可在菜单中手动启用 BBR${UI_RESET}"
    elif [[ ! "$running_kernel" =~ -aggressive-xanmod[0-9]+$ ]]; then
        echo -e "${UI_CYAN}  配置将在启动激进内核后重新检查${UI_RESET}"
    elif [[ "$current_algo" != bbr ]]; then
        echo -e "${UI_YELLOW}  当前算法不是 BBR，请检查服务日志及其他网络配置${UI_RESET}"
    fi
    return 0
}

remove_aggressive_bbr_config() {
    local target removed_unit=0
    for target in "$AGGRESSIVE_CONF" "$AGGRESSIVE_HELPER" "$AGGRESSIVE_UNIT"; do
        if "${SUDO[@]}" test -L "$target" || \
           { "${SUDO[@]}" test -e "$target" && ! "${SUDO[@]}" grep -Fxq "$AGGRESSIVE_MARKER" "$target"; }; then
            echo -e "${UI_YELLOW}发现非本项目的配置，保留全部激进版配置文件: $target${UI_RESET}" >&2
            return 1
        fi
    done
    if "${SUDO[@]}" test -e "$AGGRESSIVE_UNIT"; then
        if ! "${SUDO[@]}" systemctl disable --now "${AGGRESSIVE_UNIT##*/}"; then
            echo -e "${UI_YELLOW}无法禁用激进版 BBR 服务，请手动检查${UI_RESET}" >&2
            return 1
        fi
        removed_unit=1
    fi
    for target in "$AGGRESSIVE_CONF" "$AGGRESSIVE_HELPER" "$AGGRESSIVE_UNIT"; do
        if "${SUDO[@]}" test -e "$target"; then
            "${SUDO[@]}" rm -f -- "$target" || return 1
        fi
    done
    if [[ "$AGGRESSIVE_LEGACY_CONF" != "$AGGRESSIVE_CONF" ]] && \
       ! "${SUDO[@]}" test -L "$AGGRESSIVE_LEGACY_CONF" && \
       "${SUDO[@]}" test -f "$AGGRESSIVE_LEGACY_CONF" && \
       "${SUDO[@]}" grep -Fxq "$AGGRESSIVE_MARKER" "$AGGRESSIVE_LEGACY_CONF"; then
        "${SUDO[@]}" rm -f -- "$AGGRESSIVE_LEGACY_CONF" || return 1
    fi
    if [[ "$removed_unit" -eq 1 ]]; then
        "${SUDO[@]}" systemctl daemon-reload || return 1
    fi
    return 0
}

download_and_install() {
    local tag="$1" release_data="$2" profile="${3:-standard}"
    local urls url digest actual deb package_name kernel_name header_name downloaded=0
    local -a image_pkgs=() header_pkgs=() selected_headers=()
    urls=$(get_release_assets "$tag" "$release_data") || return 1

    if [[ -z "$urls" ]]; then
        echo -e "${UI_RED}该 Release 没有可下载的资源${UI_RESET}"
        return 1
    fi

    rm -f "$DOWNLOAD_DIR"/linux-*.deb
    while IFS=$'\t' read -r url digest; do
        [[ -z "$url" || "$url" == *"linux-libc-dev"* ]] && continue
        echo -e "${UI_CYAN}下载: $(basename "$url")${UI_RESET}"
        if ! wget --https-only --timeout=30 --tries=3 -q --show-progress "$url" -P "$DOWNLOAD_DIR"/; then
            echo -e "${UI_RED}下载失败，保留当前已安装内核${UI_RESET}"
            return 1
        fi
        if [[ -n "$digest" && "$digest" != '-' ]]; then
            actual=$(sha256sum "$DOWNLOAD_DIR/${url##*/}") || return 1
            if [[ ! "$digest" =~ ^[0-9a-f]{64}$ || "${actual%% *}" != "$digest" ]]; then
                echo -e "${UI_RED}下载文件的 SHA-256 不匹配，保留当前已安装内核${UI_RESET}" >&2
                return 1
            fi
        fi
        downloaded=$((downloaded + 1))
    done <<< "$urls"

    if [[ "$downloaded" -eq 0 ]] || ! compgen -G "$DOWNLOAD_DIR/linux-*.deb" >/dev/null; then
        echo -e "${UI_RED}未下载到内核 Debian 包，保留当前已安装内核${UI_RESET}"
        return 1
    fi

    # 仅头文件等辅助包不能视为内核镜像；同时记录本次安装的包名，避免重装后误删。
    for deb in "$DOWNLOAD_DIR"/linux-*.deb; do
        if ! package_name=$(dpkg-deb -f "$deb" Package 2>/dev/null) || [[ -z "$package_name" ]]; then
            echo -e "${UI_RED}无法读取 Debian 包信息，保留当前已安装内核${UI_RESET}"
            return 1
        fi
        case "$package_name" in
            linux-image-*-dbg) ;;
            linux-image-*)
                if [[ "$profile" == "aggressive" && ! "$package_name" =~ -aggressive-xanmod[0-9]+$ ]] || \
                   [[ "$profile" == "standard" && "$package_name" =~ -aggressive-xanmod[0-9]+$ ]]; then
                    echo -e "${UI_RED}内核镜像与选择的配置不匹配，保留当前已安装内核${UI_RESET}"
                    return 1
                fi
                image_pkgs+=("$package_name")
                ;;
            linux-headers-*) header_pkgs+=("$package_name") ;;
        esac
    done
    if [[ ${#image_pkgs[@]} -eq 0 ]]; then
        echo -e "${UI_RED}未下载到内核镜像包，保留当前已安装内核${UI_RESET}"
        return 1
    fi

    echo -e "${UI_CYAN}安装内核...${UI_RESET}"
    echo "  已安装的其他内核会保留，以便重启后回退。"
    if ! "${SUDO[@]}" dpkg -i "$DOWNLOAD_DIR"/linux-*.deb; then
        echo -e "${UI_RED}安装未完成，未执行旧内核清理；请检查上方 dpkg 输出。${UI_RESET}"
        return 1
    fi

    # Only record headers that correspond to an image installed by this run.
    for package_name in "${image_pkgs[@]}"; do
        kernel_name=${package_name#linux-image-}
        kernel_name=${kernel_name#unsigned-}
        for header_name in "${header_pkgs[@]}"; do
            [[ "$header_name" == "linux-headers-$kernel_name" ]] && selected_headers+=("$header_name")
        done
    done
    if ! record_managed_packages "$profile" "${image_pkgs[@]}" "${selected_headers[@]}"; then
        echo -e "${UI_YELLOW}内核已安装，但无法记录包来源；以后卸载时会要求确认。${UI_RESET}"
    fi

    echo -e "${UI_BOLD_GREEN}━━━━━━ 安装完成 ━━━━━━${UI_RESET}"
    local current_algo current_qdisc installed_kernel="${image_pkgs[0]#linux-image-}"
    installed_kernel="${installed_kernel#unsigned-}"
    echo -e "${UI_CYAN}  新内核: ${UI_BOLD_GREEN}$installed_kernel（$(profile_label "$profile")）${UI_RESET}"
    if [[ "$profile" == "aggressive" ]]; then
        if ! configure_aggressive_bbr; then
            echo -e "${UI_YELLOW}  内核已安装，但自动 BBR 配置未完成；请检查上方错误${UI_RESET}"
        fi
        echo -e "${UI_YELLOW}  ⚠ GRUB 默认可能仍选择标准内核；请在高级选项中选择 $installed_kernel${UI_RESET}"
        echo -e "${UI_YELLOW}    VPS 无交互启动方法请参阅 README；启动后请检查一次性启动项是否清除${UI_RESET}"
    else
        echo -e "${UI_CYAN}  安装未修改网络配置；可在菜单中手动启用 BBR${UI_RESET}"
        echo -e "${UI_YELLOW}  ⚠ 使用该内核需要重启；安装旧版时请确认 GRUB 选择的版本${UI_RESET}"
    fi
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    echo -e "${UI_CYAN}  当前默认拥塞控制: ${UI_BOLD_GREEN}${current_algo:-未知}${UI_RESET}  默认队列: ${UI_BOLD_GREEN}${current_qdisc:-未知}${UI_RESET}"
    echo -n -e "${UI_CYAN}立即重启？(y/N): ${UI_RESET}"
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
        echo -e "${UI_YELLOW}检测到 Skyline Speeder 服务正在运行，保留当前拥塞控制和配置${UI_RESET}"
        return 0
    fi

    if ! current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || [[ -z "$current_algo" ]]; then
        echo -e "${UI_RED}无法读取当前拥塞控制，未修改配置${UI_RESET}"
        return 1
    fi
    case "$current_algo" in
        bbr|cubic|reno) ;;
        *)
            echo -e "${UI_YELLOW}当前使用其他拥塞算法 $current_algo，保留现有设置${UI_RESET}"
            return 0
            ;;
    esac

    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ " $available " != *" bbr "* ]]; then
        echo -e "${UI_RED}当前内核未提供 BBR，请在重启到新内核后重试${UI_RESET}"
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
            echo -e "${UI_RED}无法读取现有 BBR 配置，未修改拥塞控制${UI_RESET}"
            return 1
        fi
    else
        printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr' > "$config_tmp" || return 1
    fi

    if ! "${SUDO[@]}" sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        echo -e "${UI_RED}无法启用 BBR，未写入持久配置${UI_RESET}"
        return 1
    fi
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" != "bbr" ]]; then
        echo -e "${UI_YELLOW}拥塞控制已被其他设置覆盖，未写入持久配置${UI_RESET}"
        return 1
    fi
    if ! "${SUDO[@]}" tee "$SYSCTL_CONF" < "$config_tmp" >/dev/null; then
        echo -e "${UI_YELLOW}无法保存 BBR 配置，重启后可能需要手动配置${UI_RESET}"
        return 1
    fi
    echo -e "${UI_BOLD_GREEN}已启用 BBR 并保存配置；队列和其他网络设置未更改${UI_RESET}"
    echo "  BBR 作为默认拥塞控制用于新连接；已有连接可能继续使用原算法。"
}

do_install_latest() {
    local profile="${1:-standard}"
    echo -e "${UI_CYAN}正在查询$(profile_label "$profile")的可用版本...${UI_RESET}"
    local data arch_filter tags latest_tag
    arch_filter=$(get_release_prefix "$profile") || return 1
    data=$(fetch_releases) || return 1
    tags=$(echo "$data" | jq -r --arg f "${arch_filter}-" '.[] | select(.tag_name | startswith($f)) | .tag_name')
    if [[ -z "$tags" ]]; then
        echo -e "${UI_RED}未找到$(profile_label "$profile")的可用版本${UI_RESET}"
        [[ "$profile" == "aggressive" ]] && echo -e "${UI_YELLOW}请先运行 GitHub Actions 的激进版构建并发布 Release${UI_RESET}"
        return 1
    fi
    tags=$(sort_tags_desc "$tags")
    latest_tag=$(echo "$tags" | head -1)

    local version="${latest_tag#"$arch_filter"-}"
    local installed installed_kernel installed_revision='' release_revision='' release_assets release_url release_image_pkg='' ans
    installed=$(get_installed_version "$profile")
    installed_kernel=$(get_installed_kernels "$profile" | head -n 1)
    release_assets=$(get_release_assets "$latest_tag" "$data") || return 1
    release_revision=$(printf '%s\n' "$release_assets" | cut -f1 | get_xanmod_revision "$version" "$profile")
    while IFS=$'\t' read -r release_url _; do
        release_image_pkg=${release_url##*/}
        [[ "$release_image_pkg" == linux-image-* ]] || continue
        release_image_pkg=${release_image_pkg%%_*}
        break
    done <<< "$release_assets"
    echo -e "${UI_CYAN}最新可用: ${UI_BOLD_GREEN}$version${UI_RESET}${release_revision:+ / xanmod$release_revision}"
    echo -e "${UI_CYAN}已安装（最高版本）: ${UI_BOLD_GREEN}${installed_kernel:-无}${UI_RESET}"

    if [[ -n "$installed" && "$installed" == "$(normalize_version "$version")" ]]; then
        installed_revision=$(get_installed_packages "$profile" | get_xanmod_revision "$version" "$profile")
    fi
    if [[ -n "$installed" && "$installed" == "$(normalize_version "$version")" && \
          -n "$installed_revision" && -n "$release_revision" ]] && (( release_revision > installed_revision )); then
        echo -e "${UI_CYAN}发现 XanMod 修订更新: xanmod${installed_revision} → xanmod${release_revision}${UI_RESET}"
    elif [[ -n "$installed" && "$installed" == "$(normalize_version "$version")" && \
            -n "$installed_revision" && "$installed_revision" == "$release_revision" && \
            "$release_image_pkg" =~ -b[0-9a-f]{10}r[0-9a-f]+a[0-9]+(-aggressive)?-xanmod[0-9]+$ ]] && \
         ! get_installed_packages "$profile" | cut -d: -f1 | grep -Fx "$release_image_pkg" >/dev/null; then
        echo -e "${UI_CYAN}发现相同 Linux 版本的新构建: $release_image_pkg；当前内核会保留。${UI_RESET}"
    elif [[ -n "$installed" && "$installed" == "$(normalize_version "$version")" ]]; then
        if [[ -n "$installed_revision" && -n "$release_revision" ]] && (( installed_revision > release_revision )); then
            echo -e "${UI_YELLOW}已安装的修订 xanmod${installed_revision} 高于 Release 的 xanmod${release_revision}；继续会安装较旧修订。${UI_RESET}"
        elif [[ -n "$installed_revision" && -n "$release_revision" ]]; then
            echo -e "${UI_BOLD_GREEN}已安装相同 Linux 版本和修订 xanmod${installed_revision}；未比较构建内容。${UI_RESET}"
        else
            echo -e "${UI_YELLOW}已安装相同 Linux 版本，但无法确认 XanMod 修订是否相同。${UI_RESET}"
        fi
        [[ "$profile" == aggressive ]] && echo -e "${UI_CYAN}跳过安装时仍会检查激进版自动 BBR 配置。${UI_RESET}"
        echo -n -e "${UI_CYAN}仍要安装此 Release？(y/N): ${UI_RESET}"
        read -r ans || return 0
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            if [[ "$profile" == "aggressive" ]] && ! configure_aggressive_bbr; then
                echo -e "${UI_YELLOW}激进版已安装，但自动 BBR 配置未完成${UI_RESET}"
            fi
            return 0
        fi
    elif [[ -n "$installed" && "$(version_sort_key "$installed")" > "$(version_sort_key "$version")" ]]; then
        echo -e "${UI_YELLOW}已安装的 Linux 版本高于最新可用 Release；继续会安装较旧版本。${UI_RESET}"
        echo -n -e "${UI_CYAN}仍要安装此 Release？(y/N): ${UI_RESET}"
        read -r ans || return 0
        if [[ "$ans" != y && "$ans" != Y ]]; then
            echo -e "${UI_CYAN}已取消安装。${UI_RESET}"
            return 0
        fi
    fi

    download_and_install "$latest_tag" "$data" "$profile"
}

do_install_specific() {
    local profile="${1:-standard}"
    echo -e "${UI_CYAN}获取可用版本...${UI_RESET}"
    local data arch_filter tags
    arch_filter=$(get_release_prefix "$profile") || return 1
    data=$(fetch_releases) || return 1
    tags=$(echo "$data" | jq -r --arg f "${arch_filter}-" '.[] | select(.tag_name | startswith($f)) | .tag_name')
    if [[ -z "$tags" ]]; then
        echo -e "${UI_RED}未找到$(profile_label "$profile")的可用版本${UI_RESET}"
        [[ "$profile" == "aggressive" ]] && echo -e "${UI_YELLOW}请先运行 GitHub Actions 的激进版构建并发布 Release${UI_RESET}"
        return 1
    fi
    tags=$(sort_tags_desc "$tags")

    local installed_packages
    installed_packages=$(get_installed_packages "$profile")
    echo ""
    local i=0 tag ver installed_revision
    while IFS= read -r tag; do
        i=$((i+1))
        ver="${tag#"$arch_filter"-}"
        installed_revision=$(printf '%s\n' "$installed_packages" | get_xanmod_revision "$ver" "$profile")
        if [[ -n "$installed_revision" ]]; then
            echo -e "${UI_YELLOW}  $i. $ver ${UI_BOLD_GREEN}← 已安装同一 Linux 版本（最高修订 xanmod${installed_revision}）${UI_RESET}"
        else
            echo -e "${UI_YELLOW}  $i. $ver${UI_RESET}"
        fi
    done <<< "$tags"

    echo ""
    echo -n -e "${UI_CYAN}选择版本编号 (0 取消): ${UI_RESET}"
    local choice
    read -r choice || return 0
    [[ "$choice" == "0" ]] && { echo -e "${UI_CYAN}已取消选择。${UI_RESET}"; return 0; }
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { echo -e "${UI_RED}无效输入${UI_RESET}"; return 1; }

    local selected_tag
    selected_tag=$(echo "$tags" | sed -n "${choice}p")
    [[ -z "$selected_tag" ]] && { echo -e "${UI_RED}无效编号${UI_RESET}"; return 1; }

    echo -e "${UI_CYAN}已选择: ${UI_BOLD_GREEN}${selected_tag#"$arch_filter"-}${UI_RESET}"
    download_and_install "$selected_tag" "$data" "$profile"
}

do_check_status() {
    echo ""
    local running active_profile profile kernels kernel highest running_found=0 installed_found=0 newer=''
    running=$(uname -r 2>/dev/null || true)
    active_profile=$(running_profile "$running")
    echo -e "${UI_BOLD_BLUE}  内核状态${UI_RESET}"
    echo -e "  当前生效内核: ${UI_BOLD_GREEN}$(running_profile_description "$active_profile" "$running")${UI_RESET}"
    echo -e "  正在运行: ${UI_BOLD_GREEN}${running:-未知}${UI_RESET}"
    for profile in standard aggressive; do
        kernels=$(get_installed_kernels "$profile")
        if [[ -z "$kernels" ]]; then
            echo -e "  已安装$(profile_label "$profile"): 无"
            continue
        fi
        installed_found=1
        highest=${kernels%%$'\n'*}
        echo -e "  已安装$(profile_label "$profile"):"
        while IFS= read -r kernel; do
            [[ -z "$kernel" ]] && continue
            if [[ "$kernel" == "$running" ]]; then
                running_found=1
                [[ "$highest" != "$running" ]] && newer="$highest"
                echo -e "    ${UI_BOLD_GREEN}$kernel（正在运行）${UI_RESET}"
            else
                echo "    $kernel"
            fi
        done <<< "$kernels"
    done
    if [[ "$installed_found" -eq 0 ]]; then
        echo -e "${UI_YELLOW}  未安装优化内核。${UI_RESET}"
    elif [[ "$running_found" -eq 0 ]]; then
        echo -e "${UI_YELLOW}  当前运行版本不在已安装列表中；如需使用已安装内核，需重启并选择对应启动项。${UI_RESET}"
    elif [[ -n "$newer" ]]; then
        echo -e "${UI_YELLOW}  同一配置还安装了较新版本 $newer；如需使用，需重启并选择对应启动项。${UI_RESET}"
    fi

    # The default applies to new connections; individual sockets can select another algorithm.
    local algo qdisc bbr_ver available
    algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    bbr_ver=$(modinfo -k "$running" tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')

    echo ""
    echo -e "${UI_BOLD_BLUE}  网络状态${UI_RESET}"
    echo -e "  默认 TCP 拥塞控制: ${UI_BOLD_GREEN}${algo:-未知}${UI_RESET}"
    echo -e "  BBR 生效情况: $(default_bbr_description "$active_profile" "$algo")"
    echo -e "  可用拥塞算法: ${available:-未知}"
    echo -e "  默认队列: ${qdisc:-未知}（不代表现有网卡的实际队列）"
    if [[ "$bbr_ver" == "3" && "$algo" == "bbr" ]]; then
        echo -e "  BBR 版本: ${UI_BOLD_GREEN}v3（已启用）${UI_RESET}"
    elif [[ "$bbr_ver" == "3" && " $available " == *" bbr "* ]]; then
        echo -e "  BBR 版本: ${UI_BOLD_GREEN}v3（可用，当前未启用）${UI_RESET}"
    elif [[ "$bbr_ver" == "3" ]]; then
        echo -e "  BBR 版本: v3（模块信息；当前可用状态未知或尚未加载）"
    elif [[ -n "$bbr_ver" ]]; then
        echo -e "  BBR 版本: $bbr_ver（模块信息）"
    elif [[ "$algo" == "bbr" ]]; then
        echo -e "  BBR: ${UI_BOLD_GREEN}已启用（无法确定版本）${UI_RESET}"
    elif [[ " $available " == *" bbr "* ]]; then
        echo "  BBR: 可用但未启用（无法确定版本）"
    else
        echo "  BBR: 当前未启用（可用状态或版本未知）"
    fi
    echo "  注：默认拥塞控制主要用于新连接，应用可为单个连接选择其他算法。"
    echo "  内核类型依据版本标识判断；无法仅凭名称验证第三方内核的源码。"
}

do_uninstall() {
    local profile="${1:-standard}" running pkg pkg_name kernel header installed_header installed_image managed installed_headers installed_images ans removing_running=0 unverified=0 image_found
    local -a pkgs=() headers=() removed=()
    mapfile -t pkgs < <(get_installed_packages "$profile")
    running=$(uname -r 2>/dev/null || true)
    managed=$(get_managed_packages)
    installed_headers=$(dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' 'linux-headers-*' 2>/dev/null \
        | awk -F '\t' '$1 == "installed" { print $2 }' || true)
    if [[ -n "$running" ]] && installed_images=$(dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' 'linux-image-*' 2>/dev/null \
        | awk -F '\t' '$1 == "installed" && $2 ~ /^linux-image-/ { print $2 }'); then
        # A previous uninstall may have kept the running kernel headers. Offer
        # them only after reboot, once no corresponding image remains.
        while IFS=$'\t' read -r record_profile header; do
            [[ "$record_profile" == "$profile" && "$header" == linux-headers-* ]] || continue
            kernel=${header#linux-headers-}
            [[ "$kernel" != "$running" ]] || continue
            image_found=0
            while IFS= read -r installed_image; do
                pkg_name=${installed_image%%:*}
                if [[ "$pkg_name" == "linux-image-$kernel" || "$pkg_name" == "linux-image-unsigned-$kernel" ]]; then
                    image_found=1; break
                fi
            done <<< "$installed_images"
            [[ "$image_found" -eq 0 ]] || continue
            while IFS= read -r installed_header; do
                [[ "${installed_header%%:*}" == "$header" ]] && headers+=("$installed_header") && break
            done <<< "$installed_headers"
        done <<< "$managed"
    fi
    if [[ ${#pkgs[@]} -eq 0 && ${#headers[@]} -eq 0 ]]; then
        echo -e "${UI_YELLOW}未找到已安装的$(profile_label "$profile")内核或可清理的已记录头文件${UI_RESET}"
        return
    fi
    [[ -n "$running" ]] || echo -e "${UI_YELLOW}无法确认运行中内核，跳过头文件清理。${UI_RESET}"
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        echo -e "${UI_CYAN}将卸载以下$(profile_label "$profile")镜像包:${UI_RESET}"
    else
        echo -e "${UI_CYAN}未找到$(profile_label "$profile")镜像，可清理以下已记录头文件。${UI_RESET}"
    fi
    for pkg in "${pkgs[@]}"; do
        pkg_name=${pkg%%:*}
        if ! printf '%s\n' "$managed" | grep -Fxq "$profile"$'\t'"$pkg_name"; then
            unverified=1
            echo -e "  ${UI_YELLOW}$pkg（历史安装，无法确认来源）${UI_RESET}"
        elif [[ "$pkg_name" != "linux-image-$running" && "$pkg_name" != "linux-image-unsigned-$running" ]]; then
            echo "  $pkg（本项目记录）"
        fi
        if [[ "$pkg_name" == "linux-image-$running" || "$pkg_name" == "linux-image-unsigned-$running" ]]; then
            removing_running=1
            echo -e "  ${UI_YELLOW}$pkg（当前正在运行）${UI_RESET}"
            continue
        fi
        kernel=${pkg_name#linux-image-}; kernel=${kernel#unsigned-}
        header="linux-headers-$kernel"
        if [[ -n "$running" ]] && printf '%s\n' "$managed" | grep -Fxq "$profile"$'\t'"$header"; then
            while IFS= read -r installed_header; do
                [[ "${installed_header%%:*}" == "$header" ]] && headers+=("$installed_header") && break
            done <<< "$installed_headers"
        fi
    done
    [[ "$unverified" -eq 1 ]] && echo -e "${UI_YELLOW}未记录来源的历史内核仅按名称识别；确认后才会卸载，请仔细核对。${UI_RESET}"
    if [[ ${#headers[@]} -gt 0 ]]; then
        echo "  同时清理本项目记录、对应待卸载或已不存在的非运行镜像的头文件: ${headers[*]}"
    fi
    if [[ "$removing_running" -eq 1 ]]; then
        echo -e "${UI_YELLOW}当前内核将运行至重启；请先确认系统有其他可启动内核。${UI_RESET}"
    else
        echo -e "${UI_YELLOW}请先确认系统有其他可启动内核。${UI_RESET}"
    fi
    [[ "$profile" == aggressive ]] && echo "  将尝试移除本项目管理的激进版自动 BBR 配置。"
    echo "  保留共享网络配置 $SYSCTL_CONF 及其中的其他设置。"
    echo -n -e "${UI_CYAN}确认卸载？(y/N): ${UI_RESET}"
    read -r ans || { echo ""; echo "已取消卸载。"; return 0; }
    if [[ "$ans" != y && "$ans" != Y ]]; then
        echo "已取消卸载。"
        return 0
    fi
    if [[ ${#pkgs[@]} -gt 0 ]] && ! "${SUDO[@]}" apt-get remove --purge -y -- "${pkgs[@]}"; then
        echo -e "${UI_RED}卸载未完成，未清理 BBR 配置；请检查上方 apt 输出。${UI_RESET}"
        return 1
    fi
    removed=("${pkgs[@]}")
    if [[ ${#headers[@]} -gt 0 ]]; then
        if "${SUDO[@]}" apt-get remove --purge -y -- "${headers[@]}"; then
            removed+=("${headers[@]}")
        else
            echo -e "${UI_YELLOW}镜像已卸载，但对应头文件未能清理；请手动检查。${UI_RESET}"
        fi
    fi
    if ! forget_managed_packages "${removed[@]}"; then
        echo -e "${UI_YELLOW}无法更新本项目包记录，请手动检查 $MANAGED_PACKAGES${UI_RESET}"
    fi
    if [[ "$profile" == "aggressive" ]] && ! remove_aggressive_bbr_config; then
        echo -e "${UI_YELLOW}激进版配置清理不完整，请手动检查${UI_RESET}"
    fi
    echo -e "${UI_BOLD_GREEN}$(profile_label "$profile")内核卸载完成。${UI_RESET}"
    [[ "$removing_running" -eq 1 ]] && echo -e "${UI_YELLOW}重启前请确认其他内核可启动。${UI_RESET}"
    return 0
}

# ── 主循环 ────────────────────────────────────────────────

while true; do
    if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != dumb ]] && command -v clear >/dev/null 2>&1; then
        clear || true
    fi
    echo ""
    echo -e "${UI_BOLD_YELLOW}  BBRv3 VPS 内核管理${UI_RESET}"
    echo ""

    # 状态栏
    running_kernel=$(uname -r 2>/dev/null || true)
    active_profile=$(running_profile "$running_kernel")
    local_ver=$(get_installed_kernels standard | head -n 1)
    aggressive_ver=$(get_installed_kernels aggressive | head -n 1)
    cur_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    echo -e "  当前生效内核: ${UI_BOLD_GREEN}$(running_profile_description "$active_profile" "$running_kernel")${UI_RESET}"
    echo -e "  正在运行: ${UI_BOLD_GREEN}${running_kernel:-未知}${UI_RESET}"
    echo -e "  已安装标准版（最高）: ${local_ver:-无}"
    echo -e "  已安装激进版（最高）: ${aggressive_ver:-无}"
    echo -e "  默认 TCP 拥塞: ${cur_algo:-未知}  |  默认队列: ${cur_qdisc:-未知}"
    echo -e "  BBR 生效情况: $(default_bbr_description "$active_profile" "$cur_algo")"
    if [[ "$active_profile" == standard && -n "$aggressive_ver" ]]; then
        echo -e "${UI_CYAN}  激进版已安装但未运行；切换需重启并选择激进版启动项。${UI_RESET}"
    elif [[ "$active_profile" == aggressive && -n "$local_ver" ]]; then
        echo -e "${UI_CYAN}  标准版已安装但未运行；切换需重启并选择标准版启动项。${UI_RESET}"
    fi
    if command -v systemctl >/dev/null 2>&1 && \
       { systemctl is-active --quiet skyline-speederd.service || systemctl is-active --quiet skyline-speeder-enable.service; }; then
        echo -e "${UI_YELLOW}  Skyline 正在运行，安装器会保留其拥塞控制。${UI_RESET}"
    fi
    echo ""
    echo -e "  ${UI_YELLOW}1.${UI_RESET} 安装/更新标准版到最新版本"
    echo -e "  ${UI_YELLOW}2.${UI_RESET} 手动选择标准版版本"
    echo -e "  ${UI_YELLOW}3.${UI_RESET} 查看内核与 BBR 状态"
    echo -e "  ${UI_YELLOW}4.${UI_RESET} 卸载标准版内核"
    echo -e "  ${UI_YELLOW}5.${UI_RESET} 手动启用 BBR（保存配置）"
    echo -e "  ${UI_YELLOW}6.${UI_RESET} 安装/更新激进版（实验性）"
    echo -e "  ${UI_YELLOW}7.${UI_RESET} 选择激进版版本安装"
    echo -e "  ${UI_YELLOW}8.${UI_RESET} 卸载激进版内核"
    echo -e "  ${UI_YELLOW}0.${UI_RESET} 退出"
    echo ""
    echo -n -e "${UI_CYAN}选择 (0-8): ${UI_RESET}"
    if ! read -r action; then
        echo ""
        exit 0
    fi

    case "$action" in
        0) echo -e "${UI_BOLD_MAGENTA}再见！${UI_RESET}"; exit 0 ;;
        1) do_install_latest ;;
        2) do_install_specific ;;
        3) do_check_status ;;
        4) do_uninstall ;;
        5) do_enable_bbr ;;
        6) do_install_latest aggressive ;;
        7) do_install_specific aggressive ;;
        8) do_uninstall aggressive ;;
        *) echo -e "${UI_RED}无效选择${UI_RESET}" ;;
    esac

    echo ""
    echo -n -e "${UI_CYAN}按 Enter 返回菜单...${UI_RESET}"
    read -r || exit 0
done
