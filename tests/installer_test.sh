#!/usr/bin/env bash
set -euo pipefail

# Exercise the real menu and installer with mocked system commands. No packages,
# sysctl settings, or files outside the temporary directory are modified.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
REAL_RM=$(command -v rm)
trap '"$REAL_RM" -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/tmp"

cat > "$TEST_DIR/bin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
cmd=${0##*/}
case "$cmd" in
    sudo)
        [[ ${1:-} == -v ]] && exit 0
        exec "$@"
        ;;
    apt-get)
        printf 'apt-get %s\n' "$*" >> "$TEST_LOG"
        [[ ${1:-} == update && ${TEST_APT_UPDATE_FAIL:-0} == 1 ]] && exit 1
        [[ ${1:-} == remove && ${TEST_APT_REMOVE_FAIL:-0} == 1 ]] && exit 1
        exit 0
        ;;
    dpkg)
        if [[ ${1:-} == -s ]]; then
            [[ ${2:-} == initramfs-tools && ${TEST_MISSING_DEP:-0} == 1 ]] && exit 1
            exit 0
        fi
        printf 'dpkg %s\n' "$*" >> "$TEST_LOG"
        [[ ${TEST_DPKG_FAIL:-0} == 1 ]] && exit 1
        if [[ ${1:-} == -i ]]; then
            printf '%s\n' "${@:2}" > "$TEST_DIR/dpkg-installed"
        fi
        exit 0
        ;;
    update-grub)
        echo update-grub >> "$TEST_LOG"
        [[ ${TEST_GRUB_FAIL:-0} == 1 ]] && exit 1
        if [[ ${TEST_GRUB_NO_CONFIG:-0} == 1 ]]; then
            rm -f "$BBRV3_GRUB_CONFIG"
            exit 0
        fi
        : > "$BBRV3_GRUB_CONFIG"
        [[ ${TEST_GRUB_EMPTY:-0} == 1 ]] && exit 0
        printf '\tlinux /boot/vmlinuz-6.12.0-debian root=/dev/vda1\n' >> "$BBRV3_GRUB_CONFIG"
        if [[ -f "$TEST_DIR/dpkg-installed" && ${TEST_GRUB_NO_ENTRY:-0} != 1 ]]; then
            while IFS= read -r deb; do
                package=${deb##*/}
                package=${package%%_*}
                [[ $package == linux-image-* && $package != *-dbg ]] || continue
                kernel=${package#linux-image-}
                kernel=${kernel#unsigned-}
                printf '\tlinux /boot/vmlinuz-%s%s root=/dev/vda1\n' "$kernel" "${TEST_GRUB_SUFFIX:-}" >> "$BBRV3_GRUB_CONFIG"
            done < "$TEST_DIR/dpkg-installed"
        fi
        if [[ -n ${TEST_GRUB_STALE:-} ]]; then
            printf '\tlinux /boot/vmlinuz-%s root=/dev/vda1\n' "$TEST_GRUB_STALE" >> "$BBRV3_GRUB_CONFIG"
        fi
        exit 0
        ;;
    dpkg-query)
        if [[ "$*" == *'${db:Status-Status}'* ]]; then
            cat "$TEST_PACKAGES"
        else
            cut -f2 "$TEST_PACKAGES"
        fi
        ;;
    dpkg-deb)
        [[ ${TEST_DEB_FAIL:-0} == 1 ]] && exit 1
        package=${2##*/}
        printf '%s\n' "${package%%_*}"
        ;;
    uname)
        [[ ${1:-} == -m ]] && { echo "${TEST_ARCH:-x86_64}"; exit 0; }
        [[ ${1:-} == -r ]] && { echo "$TEST_RUNNING"; exit 0; }
        exit 1
        ;;
    curl)
        [[ ${TEST_CURL_FAIL:-0} == 1 ]] && exit 22
        echo '[]'
        ;;
    jq)
        case "$*" in
            *'type == "array"'*) exit 0 ;;
            *'.assets[]'*) cat "$TEST_URLS" ;;
            *'startswith'*)
                prefix=
                while [[ $# -gt 0 ]]; do
                    if [[ $1 == --arg && ${2:-} == f ]]; then prefix=${3:-}; break; fi
                    shift
                done
                awk -v prefix="$prefix" 'index($0, prefix) == 1' "$TEST_TAGS"
                ;;
            *) echo "Unexpected jq invocation: $*" >&2; exit 1 ;;
        esac
        ;;
    wget)
        [[ ${TEST_WGET_FAIL:-0} == 1 ]] && exit 1
        url= dir=
        while [[ $# -gt 0 ]]; do
            case "$1" in
                https://*) url=$1 ;;
                -P) shift; dir=$1 ;;
            esac
            shift
        done
        [[ -n "$url" && -n "$dir" ]] || exit 1
        : > "$dir/${url##*/}"
        ;;
    sysctl)
        case ${1:-} in
            -n)
                case ${2:-} in
                    net.core.default_qdisc) echo "${TEST_QDISC:-fq}" ;;
                    net.ipv4.tcp_available_congestion_control) echo "${TEST_AVAILABLE:-reno cubic bbr}" ;;
                    net.ipv4.tcp_congestion_control)
                        if [[ -f "$TEST_DIR/algorithm" ]]; then cat "$TEST_DIR/algorithm"; else echo "${TEST_ALGO-bbr}"; fi
                        ;;
                esac
                ;;
            -w)
                printf 'sysctl %s\n' "$*" >> "$TEST_LOG"
                [[ ${TEST_SYSCTL_FAIL:-0} == 1 ]] && exit 1
                if [[ ${2:-} == net.ipv4.tcp_congestion_control=bbr && ${TEST_SYSCTL_OVERRIDE:-0} != 1 ]]; then
                    echo bbr > "$TEST_DIR/algorithm"
                fi
                ;;
            -p)
                printf 'sysctl %s\n' "$*" >> "$TEST_LOG"
                [[ ${TEST_SYSCTL_FAIL:-0} == 1 ]] && exit 1
                [[ -f ${2:-} ]] || exit 1
                echo bbr > "$TEST_DIR/algorithm"
                ;;
        esac
        exit 0
        ;;
    systemctl)
        case ${1:-} in
            is-active) [[ ${TEST_SKYLINE_ACTIVE:-0} == 1 ]] && exit 0; exit 3 ;;
            daemon-reload|enable|start|disable)
                printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
                [[ ${TEST_SYSTEMCTL_FAIL:-} == "$1" ]] && exit 1
                if [[ $1 == start && ${TEST_EXECUTE_START:-0} == 1 ]]; then
                    bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF" || exit 1
                fi
                exit 0
                ;;
        esac
        exit 3
        ;;
    modinfo)
        [[ -n ${TEST_BBR_VERSION:-} ]] && printf 'version: %s\n' "$TEST_BBR_VERSION"
        exit 0
        ;;
    tee)
        printf 'tee %s\n' "$*" >> "$TEST_LOG"
        cat > "$TEST_DIR/tee-content"
        [[ ${TEST_TEE_FAIL:-0} == 1 ]] && exit 1
        exit 0
        ;;
    rm)
        for arg in "$@"; do
            if [[ $arg == /etc/* ]]; then
                printf 'rm %s\n' "$*" >> "$TEST_LOG"
                exit 0
            fi
        done
        exec "$REAL_RM" "$@"
        ;;
    clear) exit 0 ;;
    reboot) echo reboot >> "$TEST_LOG" ;;
    *) echo "Unexpected mock command: $cmd" >&2; exit 1 ;;
esac
MOCK

for cmd in sudo apt-get dpkg dpkg-query dpkg-deb update-grub uname curl jq wget sysctl systemctl modinfo tee rm clear reboot; do
    cp "$TEST_DIR/bin/mock-command" "$TEST_DIR/bin/$cmd"
    chmod +x "$TEST_DIR/bin/$cmd"
done

export REAL_RM TEST_DIR
export PATH="$TEST_DIR/bin:$PATH"
export TEST_LOG="$TEST_DIR/commands.log" TEST_PACKAGES="$TEST_DIR/packages"
export TEST_URLS="$TEST_DIR/urls" TEST_TAGS="$TEST_DIR/tags"
export BBRV3_SYSCTL_CONF="$TEST_DIR/sysctl.conf"
export BBRV3_AGGRESSIVE_CONF="$TEST_DIR/aggressive/config.profile"
export BBRV3_AGGRESSIVE_LEGACY_CONF="$TEST_DIR/aggressive/legacy.conf"
export BBRV3_AGGRESSIVE_HELPER="$TEST_DIR/aggressive/apply.sh"
export BBRV3_AGGRESSIVE_UNIT="$TEST_DIR/aggressive/xanmod-aggressive-bbr.service"
export BBRV3_MANAGED_PACKAGES="$TEST_DIR/registry/managed-packages"
export BBRV3_GRUB_CONFIG="$TEST_DIR/grub.cfg"
export TEST_RUNNING=7.2.1-xanmod1
export TMPDIR="$TEST_DIR/tmp"

reset_fixture() {
    : > "$TEST_LOG"
    : > "$TEST_PACKAGES"
    printf '%s\n' 'x86_64-7.2.12' > "$TEST_TAGS"
    printf '%s\n' \
        'https://example.test/linux-image-7.2.12-xanmod1_1_amd64.deb' \
        'https://example.test/linux-headers-7.2.12-xanmod1_1_amd64.deb' > "$TEST_URLS"
    TEST_RUNNING=7.2.1-xanmod1
    rm -f "$BBRV3_SYSCTL_CONF" "$BBRV3_GRUB_CONFIG" "$TEST_DIR/algorithm" "$TEST_DIR/tee-content" "$TEST_DIR/dpkg-installed"
    rm -rf "$TEST_DIR/aggressive"
    rm -rf "$TEST_DIR/registry"
    unset TEST_APT_UPDATE_FAIL TEST_APT_REMOVE_FAIL TEST_MISSING_DEP TEST_DPKG_FAIL TEST_DEB_FAIL TEST_CURL_FAIL TEST_WGET_FAIL TEST_TEE_FAIL TEST_ALGO TEST_QDISC TEST_BBR_VERSION TEST_SKYLINE_ACTIVE TEST_AVAILABLE TEST_SYSCTL_FAIL TEST_SYSCTL_OVERRIDE TEST_SYSTEMCTL_FAIL TEST_EXECUTE_START TEST_ARCH TEST_GRUB_FAIL TEST_GRUB_NO_CONFIG TEST_GRUB_NO_ENTRY TEST_GRUB_EMPTY TEST_GRUB_SUFFIX TEST_GRUB_STALE
}

run_installer() {
    local input=$1
    printf '%b' "$input" | timeout 15s bash "$ROOT_DIR/install.sh" > "$TEST_DIR/output" 2>&1
}

assert_log_contains() {
    grep -Fq -- "$1" "$TEST_LOG" || { echo "Missing command: $1" >&2; cat "$TEST_LOG" >&2; exit 1; }
}

assert_log_not_contains() {
    if grep -Fq -- "$1" "$TEST_LOG"; then
        echo "Unexpected command: $1" >&2
        cat "$TEST_LOG" >&2
        exit 1
    fi
}

assert_output_contains() {
    grep -Fq -- "$1" "$TEST_DIR/output" || { echo "Missing output: $1" >&2; cat "$TEST_DIR/output" >&2; exit 1; }
}

assert_output_not_contains() {
    if grep -Fq -- "$1" "$TEST_DIR/output"; then
        echo "Unexpected output: $1" >&2
        cat "$TEST_DIR/output" >&2
        exit 1
    fi
}

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.0-xanmod1 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_log_contains 'dpkg -i '
assert_log_contains 'update-grub'
assert_output_contains 'GRUB 菜单已更新，已找到新内核启动项'
assert_log_not_contains 'apt-get remove'
assert_log_not_contains 'apt-get remove --purge -y -- linux-image-7.2.1-xanmod1'
assert_log_not_contains 'sysctl -w'
assert_log_not_contains 'tee '
assert_output_contains '新内核:'
echo 'PASS: upgrade retains previous kernels without changing network settings'

reset_fixture
export TEST_GRUB_FAIL=1
run_installer '1\ny\n0\n'
assert_log_contains 'dpkg -i '
assert_log_contains 'update-grub'
assert_log_not_contains 'reboot'
assert_output_contains '内核包已安装，但 GRUB 更新或菜单检查未完成'
assert_output_not_contains '立即重启？'
grep -Fxq $'standard\tlinux-image-7.2.12-xanmod1' "$BBRV3_MANAGED_PACKAGES"
echo 'PASS: failed GRUB update preserves the installed package record and does not offer reboot'

reset_fixture
export TEST_GRUB_NO_ENTRY=1
run_installer '1\ny\n0\n'
assert_output_contains 'GRUB 菜单中未找到新内核 7.2.12-xanmod1'
assert_output_not_contains '立即重启？'
assert_log_not_contains 'reboot'
echo 'PASS: an absent installed-kernel entry blocks the reboot prompt'

reset_fixture
export TEST_GRUB_SUFFIX=-other
run_installer '1\ny\n0\n'
assert_output_contains 'GRUB 菜单中未找到新内核 7.2.12-xanmod1'
assert_output_not_contains '立即重启？'
echo 'PASS: a similarly named kernel is not mistaken for the installed image'

reset_fixture
export TEST_GRUB_NO_CONFIG=1
run_installer '1\ny\n0\n'
assert_output_contains '无法读取'
assert_output_not_contains '立即重启？'
echo 'PASS: a missing GRUB configuration is reported before reboot'

reset_fixture
run_installer '1\ny\n\n0\n'
assert_log_contains 'reboot'
assert_output_contains '默认启动项由 GRUB 配置决定'
echo 'PASS: a successful installation offers reboot without claiming the default entry is known'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.6-x64v3-xanmod1 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_log_not_contains 'apt-get remove'
assert_output_not_contains '已安装标准版（最高）: 7.2.6-x64v3-xanmod1'
grep -Fxq $'standard\tlinux-image-7.2.12-xanmod1' "$BBRV3_MANAGED_PACKAGES"
grep -Fxq $'standard\tlinux-headers-7.2.12-xanmod1' "$BBRV3_MANAGED_PACKAGES"
echo 'PASS: third-party XanMod images are excluded and newly installed packages are recorded'

reset_fixture
mkdir -p "$TEST_DIR/registry"
printf '%s\n' '# User-managed file' > "$BBRV3_MANAGED_PACKAGES"
run_installer '1\nn\n\n0\n'
grep -Fxq '# User-managed file' "$BBRV3_MANAGED_PACKAGES"
assert_output_contains '包记录文件不属于本项目'
assert_log_contains 'dpkg -i '
echo 'PASS: installation preserves an unowned package registry'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod1 > "$TEST_PACKAGES"
run_installer '1\ny\nn\n0\n'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'apt-get remove'
echo 'PASS: reinstall retains the newly installed package'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod1 linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' \
    'https://example.test/linux-image-7.2.12-xanmod2_1_amd64.deb' \
    'https://example.test/linux-headers-7.2.12-xanmod2_1_amd64.deb' > "$TEST_URLS"
TEST_RUNNING=7.2.12-xanmod1
run_installer '1\nn\n\n0\n'
assert_output_contains 'xanmod1 → xanmod2'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'apt-get remove --purge -y -- linux-image-7.2.12-xanmod1'
assert_log_not_contains 'apt-get remove --purge -y -- linux-image-7.2.12-aggressive-xanmod1'
echo 'PASS: a newer standard XanMod revision upgrades while preserving the running and aggressive kernels'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod1 linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' \
    'https://example.test/linux-image-7.2.12-aggressive-xanmod2_1_amd64.deb' \
    'https://example.test/linux-headers-7.2.12-aggressive-xanmod2_1_amd64.deb' > "$TEST_URLS"
TEST_RUNNING=7.2.12-xanmod1
run_installer '6\nn\n\n0\n'
assert_output_contains 'xanmod1 → xanmod2'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'apt-get remove'
assert_log_not_contains 'apt-get remove --purge -y -- linux-image-7.2.12-xanmod1'
echo 'PASS: a newer aggressive XanMod revision upgrades independently'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod2 linux-image-7.2.12-xanmod10 > "$TEST_PACKAGES"
printf '%s\n' \
    'https://example.test/linux-image-7.2.12-xanmod3_1_amd64.deb' \
    'https://example.test/linux-headers-7.2.12-xanmod3_1_amd64.deb' > "$TEST_URLS"
run_installer '1\nn\n\n0\n'
assert_output_contains '高于 Release 的 xanmod3'
assert_log_not_contains 'dpkg -i '
echo 'PASS: the highest installed XanMod revision prevents an automatic downgrade'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-xanmod1 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_output_contains '已安装的 Linux 版本高于最新可用 Release'
assert_output_contains '已取消安装'
assert_log_not_contains 'dpkg -i '
echo 'PASS: an older Release needs confirmation before installing over a newer Linux version'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' \
    'https://example.test/linux-image-7.2.12-b0123456789r2a1-xanmod1_1_amd64.deb' \
    'https://example.test/linux-headers-7.2.12-b0123456789r2a1-xanmod1_1_amd64.deb' > "$TEST_URLS"
run_installer '1\nn\n\n0\n'
assert_output_contains '发现相同 Linux 版本的新构建'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'apt-get remove'
echo 'PASS: a new same-version build installs alongside the earlier kernel'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' x86_64-7.2.9 x86_64-7.2.12 > "$TEST_TAGS"
run_installer '2\n1\nn\n\n0\n'
assert_output_contains '已选择:'
assert_output_contains '7.2.12'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'sysctl -w'
echo 'PASS: manual version selection installs the numerically latest listed version'

reset_fixture
run_installer '2\n0\n\n0\n'
assert_log_not_contains 'dpkg -i'
echo 'PASS: manual version selection can be cancelled'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.9-xanmod1 linux-image-7.2.12-xanmod2 > "$TEST_PACKAGES"
printf '%s\n' x86_64-7.2.9 x86_64-7.2.12 > "$TEST_TAGS"
run_installer '2\n0\n\n0\n'
assert_output_contains '7.2.9 ← 已安装同一 Linux 版本（最高修订 xanmod1）'
assert_output_contains '7.2.12 ← 已安装同一 Linux 版本（最高修订 xanmod2）'
assert_output_contains '已取消选择'
echo 'PASS: version selection labels each installed Linux version and its highest revision'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.9-xanmod1 linux-image-7.2.12-xanmod1 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_output_contains '已安装相同 Linux 版本和修订'
assert_output_contains '未比较构建内容'
assert_log_not_contains 'dpkg -i'
echo 'PASS: installed versions are compared numerically'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-rc1-xanmod1 linux-image-7.3.0-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' x86_64-7.3 > "$TEST_TAGS"
run_installer '1\nn\n\n0\n'
assert_output_contains '无法确认 XanMod 修订是否相同'
assert_log_not_contains 'dpkg -i'
echo 'PASS: a stable installed version sorts after its release candidate'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1:amd64 linux-image-7.2.0-xanmod1:amd64 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_log_not_contains 'apt-get remove'
assert_log_not_contains 'linux-image-7.2.1-xanmod1:amd64'
echo 'PASS: architecture-qualified running packages are retained'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.0-xanmod1 linux-image-7.1.9-aggressive-xanmod1 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_log_not_contains 'apt-get remove'
assert_log_not_contains 'linux-image-7.1.9-aggressive-xanmod1'
echo 'PASS: standard upgrades do not remove the separate aggressive kernel'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.1.9-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' x86_64-7.2.12 aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' \
    'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' \
    'https://example.test/linux-headers-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
run_installer '6\nn\n\n0\n'
assert_log_contains 'linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb'
assert_log_not_contains 'apt-get remove'
assert_output_contains '请确认 GRUB 选择的是 7.2.12-aggressive-xanmod1'
assert_output_contains '7.2.12-aggressive-xanmod1'
assert_log_not_contains 'apt-get remove --purge -y -- linux-image-7.2.1-xanmod1'
assert_log_not_contains 'sysctl -w'
assert_log_not_contains 'tee '
grep -Fxq 'net.ipv4.tcp_congestion_control=bbr' "$BBRV3_AGGRESSIVE_CONF"
assert_log_contains 'systemctl enable xanmod-aggressive-bbr.service'
assert_log_contains 'systemctl start xanmod-aggressive-bbr.service'
assert_output_contains '仅激进内核运行且无其他拥塞控制冲突时生效'
echo 'PASS: aggressive upgrades select their own release and preserve the standard kernel'

# Run the installed boot helper against independent kernel and service states.
: > "$TEST_LOG"
TEST_RUNNING=7.2.1-xanmod1 bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF"
assert_log_not_contains 'sysctl -p'
TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_SKYLINE_ACTIVE=1 bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF"
assert_log_not_contains 'sysctl -p'
TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=custom_cc bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF"
assert_log_not_contains 'sysctl -p'
if TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_AVAILABLE=reno bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF"; then
    echo 'Expected automatic activation to fail when BBR is unavailable' >&2
    exit 1
fi
assert_log_not_contains 'sysctl -p'
TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=cubic bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF"
assert_log_not_contains 'sysctl -p'
TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=reno bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF"
assert_log_not_contains 'sysctl -p'
TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=bbr bash "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_CONF"
assert_log_contains "sysctl -p $BBRV3_AGGRESSIVE_CONF"
assert_log_not_contains 'net.core.default_qdisc'
echo 'PASS: automatic BBR applies only to the aggressive kernel without a conflicting service or algorithm'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
export TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=bbr TEST_EXECUTE_START=1
run_installer '6\nn\n\n0\n'
assert_log_contains "sysctl -p $BBRV3_AGGRESSIVE_CONF"
grep -Fxq 'bbr' "$TEST_DIR/algorithm"
assert_output_contains '当前默认拥塞控制:'
echo 'PASS: installing on the running aggressive kernel immediately applies BBR'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
export TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=skyline_cc TEST_SKYLINE_ACTIVE=1 TEST_EXECUTE_START=1
run_installer '6\nn\n\n0\n'
[[ -f "$BBRV3_AGGRESSIVE_CONF" ]] || { echo 'Expected a saved aggressive configuration' >&2; exit 1; }
assert_log_not_contains 'sysctl -p'
assert_output_contains '检测到 Skyline 正在运行，已保留其拥塞控制'
echo 'PASS: installation saves the profile but reports and preserves an active Skyline service'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
run_installer '6\nn\n\n0\n'
assert_output_contains '无法确认 XanMod 修订是否相同'
assert_log_not_contains 'dpkg -i'
grep -Fxq 'net.ipv4.tcp_congestion_control=bbr' "$BBRV3_AGGRESSIVE_CONF"
assert_log_contains 'systemctl enable xanmod-aggressive-bbr.service'
echo 'PASS: an existing aggressive installation gains the automatic configuration without reinstalling'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' 'net.ipv4.tcp_congestion_control=bbr' '# User note' > "$BBRV3_AGGRESSIVE_CONF"
run_installer '6\nn\n\n0\n'
grep -Fxq '# User note' "$BBRV3_AGGRESSIVE_CONF"
assert_log_contains 'systemctl enable xanmod-aggressive-bbr.service'
echo 'PASS: updating the automatic service preserves an existing managed configuration'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' 'net.ipv4.tcp_congestion_control=bbr' '# Custom note' > "$BBRV3_AGGRESSIVE_LEGACY_CONF"
run_installer '6\nn\n\n0\n'
assert_output_contains '已将旧版激进 BBR 配置迁移至'
grep -Fxq '# Custom note' "$BBRV3_AGGRESSIVE_CONF"
grep -Fxq "ExecStart=/bin/bash $BBRV3_AGGRESSIVE_HELPER $BBRV3_AGGRESSIVE_CONF" "$BBRV3_AGGRESSIVE_UNIT"
[[ ! -e "$BBRV3_AGGRESSIVE_LEGACY_CONF" ]] || { echo 'Expected the identical old configuration to be removed after migration' >&2; exit 1; }
echo 'PASS: managed legacy settings migrate without losing edits and the service uses the new path'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' '# Old user setting' > "$BBRV3_AGGRESSIVE_LEGACY_CONF"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' '# New user setting' > "$BBRV3_AGGRESSIVE_CONF"
run_installer '6\nn\n\n0\n'
assert_output_contains '新旧配置内容不同，已保留旧配置供检查'
grep -Fxq '# Old user setting' "$BBRV3_AGGRESSIVE_LEGACY_CONF"
grep -Fxq '# New user setting' "$BBRV3_AGGRESSIVE_CONF"
echo 'PASS: different managed old and new configurations are both preserved'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# User owned legacy configuration' > "$BBRV3_AGGRESSIVE_LEGACY_CONF"
run_installer '6\nn\n\n0\n'
assert_output_contains '旧配置不属于本项目或是符号链接，将保留'
grep -Fxq '# User owned legacy configuration' "$BBRV3_AGGRESSIVE_LEGACY_CONF"
grep -Fxq 'net.ipv4.tcp_congestion_control=bbr' "$BBRV3_AGGRESSIVE_CONF"
echo 'PASS: an unmanaged legacy configuration is not copied or removed'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' '# Symlink target' > "$TEST_DIR/other-config"
ln -s "$TEST_DIR/other-config" "$BBRV3_AGGRESSIVE_LEGACY_CONF"
run_installer '6\nn\n\n0\n'
assert_output_contains '旧配置不属于本项目或是符号链接，将保留'
[[ -L "$BBRV3_AGGRESSIVE_LEGACY_CONF" ]] || { echo 'Removed a user symlink' >&2; exit 1; }
grep -Fxq '# Symlink target' "$TEST_DIR/other-config"
grep -Fxq 'net.ipv4.tcp_congestion_control=bbr' "$BBRV3_AGGRESSIVE_CONF"
echo 'PASS: a legacy symlink and its target are not copied or removed'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' '# Old settings' > "$BBRV3_AGGRESSIVE_LEGACY_CONF"
export TEST_SYSTEMCTL_FAIL=enable
run_installer '6\nn\n\n0\n'
assert_output_contains '激进版已安装，但自动 BBR 配置未完成'
grep -Fxq '# Old settings' "$BBRV3_AGGRESSIVE_LEGACY_CONF"
grep -Fxq '# Old settings' "$BBRV3_AGGRESSIVE_CONF"
echo 'PASS: migration preserves the old configuration if service activation fails'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# User owned configuration' > "$BBRV3_AGGRESSIVE_CONF"
run_installer '6\nn\n\n0\n'
assert_output_contains '配置文件已存在且不属于本项目'
assert_output_contains '内核已安装，但自动 BBR 配置未完成'
grep -Fxq '# User owned configuration' "$BBRV3_AGGRESSIVE_CONF"
assert_log_not_contains 'systemctl enable'
echo 'PASS: automatic configuration does not overwrite an unmanaged file'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
mkdir -p "$TEST_DIR/aggressive"
ln -s "$TEST_DIR/elsewhere" "$BBRV3_AGGRESSIVE_CONF"
run_installer '6\nn\n\n0\n'
assert_output_contains '配置路径是符号链接，未覆盖'
[[ ! -e "$TEST_DIR/elsewhere" ]] || { echo 'Followed an unmanaged symlink' >&2; exit 1; }
assert_log_not_contains 'systemctl enable'
echo 'PASS: automatic configuration refuses symlink targets'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
export TEST_SYSTEMCTL_FAIL=enable
run_installer '6\nn\n\n0\n'
assert_output_contains '内核已安装，但自动 BBR 配置未完成'
assert_log_contains 'dpkg -i '
echo 'PASS: failed service activation is reported without hiding successful kernel installation'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
export TEST_DPKG_FAIL=1
run_installer '6\n\n0\n'
[[ ! -e "$BBRV3_AGGRESSIVE_CONF" ]] || { echo 'Configuration created after failed installation' >&2; exit 1; }
assert_log_not_contains 'systemctl enable'
echo 'PASS: failed aggressive package installation does not create or enable the configuration'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.9 aggressive-x86_64-7.2.12 > "$TEST_TAGS"
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
run_installer '7\n1\nn\n\n0\n'
assert_output_contains '已选择:'
assert_output_contains '7.2.12'
assert_log_contains 'dpkg -i '
echo 'PASS: the aggressive version selector sorts and installs its own releases'

reset_fixture
printf '%s\n' aggressive-x86_64-7.2.12 > "$TEST_TAGS"
run_installer '6\n\n0\n'
assert_output_contains '内核镜像与选择的配置不匹配'
assert_log_not_contains 'dpkg -i'
echo 'PASS: an aggressive release containing a standard image is rejected'

reset_fixture
printf '%s\n' 'https://example.test/linux-image-7.2.12-aggressive-xanmod1_1_amd64.deb' > "$TEST_URLS"
run_installer '1\n\n0\n'
assert_output_contains '内核镜像与选择的配置不匹配'
assert_log_not_contains 'dpkg -i'
echo 'PASS: a standard release containing an aggressive image is rejected'

reset_fixture
run_installer '6\n\n0\n'
assert_output_contains '未找到激进版的可用版本'
assert_log_not_contains 'dpkg -i'
echo 'PASS: an unpublished aggressive release is reported without affecting standard releases'

reset_fixture
export TEST_ARCH=aarch64
run_installer '6\n\n0\n'
assert_output_contains '激进版目前仅支持 x86_64'
assert_log_not_contains 'dpkg -i'
echo 'PASS: unsupported aggressive architectures are rejected'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' 'https://example.test/linux-headers-7.2.12-xanmod1_1_amd64.deb' > "$TEST_URLS"
run_installer '1\n\n0\n'
assert_log_not_contains 'dpkg -i'
assert_log_not_contains 'apt-get remove'
assert_output_contains '未下载到内核镜像包'
echo 'PASS: headers alone are not treated as a kernel installation'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
export TEST_DEB_FAIL=1
run_installer '1\n\n0\n'
assert_log_not_contains 'dpkg -i'
assert_log_not_contains 'apt-get remove'
assert_output_contains '无法读取 Debian 包信息'
echo 'PASS: unreadable package metadata stops before installation'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
export TEST_WGET_FAIL=1
run_installer '1\n\n0\n'
assert_log_not_contains 'dpkg -i'
assert_log_not_contains 'apt-get remove'
assert_output_contains '下载失败'
echo 'PASS: failed downloads preserve the installed kernel'

reset_fixture
printf '%s\t%s\n' 'https://example.test/linux-image-7.2.12-xanmod1_1_amd64.deb' \
    '0000000000000000000000000000000000000000000000000000000000000000' > "$TEST_URLS"
run_installer '1\n\n0\n'
assert_output_contains 'SHA-256 不匹配'
assert_log_not_contains 'dpkg -i'
echo 'PASS: a checksum mismatch is rejected before installation'

reset_fixture
export TEST_CURL_FAIL=1
run_installer '1\n\n0\n'
assert_output_contains '无法查询 GitHub Release'
assert_log_not_contains 'dpkg -i'
echo 'PASS: release lookup failures explain where to investigate'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
export TEST_DPKG_FAIL=1
run_installer '1\n\n0\n'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'apt-get remove'
assert_log_not_contains 'tee '
assert_output_contains '安装未完成，未执行旧内核清理'
echo 'PASS: failed installation preserves the existing kernel and configuration'

reset_fixture
export TEST_ALGO=cubic
run_installer '5\n\n0\n'
assert_log_contains 'sysctl -w net.ipv4.tcp_congestion_control=bbr'
assert_log_contains "tee $BBRV3_SYSCTL_CONF"
assert_log_not_contains 'sysctl -w net.core.default_qdisc'
grep -Fxq 'net.ipv4.tcp_congestion_control=bbr' "$TEST_DIR/tee-content"
assert_output_contains '已启用 BBR 并保存配置'
echo 'PASS: manual BBR selection changes only the congestion algorithm and persists it'

reset_fixture
printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control = cubic' 'net.ipv4.tcp_ecn=0' > "$BBRV3_SYSCTL_CONF"
export TEST_ALGO=cubic
run_installer '5\n\n0\n'
grep -Fxq 'net.core.default_qdisc=fq' "$TEST_DIR/tee-content"
grep -Fxq 'net.ipv4.tcp_congestion_control=bbr' "$TEST_DIR/tee-content"
grep -Fxq 'net.ipv4.tcp_ecn=0' "$TEST_DIR/tee-content"
echo 'PASS: existing unrelated settings survive manual BBR configuration'

reset_fixture
export TEST_ALGO=bbr TEST_SKYLINE_ACTIVE=1
run_installer '5\n\n0\n'
assert_log_not_contains 'sysctl -w'
assert_log_not_contains 'tee '
assert_output_contains '检测到 Skyline Speeder 服务正在运行'
echo 'PASS: an active Skyline service is preserved even if BBR is temporarily active'

reset_fixture
export TEST_ALGO=skyline_cc
run_installer '5\n\n0\n'
assert_log_not_contains 'sysctl -w'
assert_log_not_contains 'tee '
assert_output_contains '当前使用其他拥塞算法 skyline_cc'
echo 'PASS: a custom congestion algorithm is not overwritten'

reset_fixture
export TEST_ALGO=cubic TEST_AVAILABLE='reno cubic'
run_installer '5\n\n0\n'
assert_log_not_contains 'sysctl -w'
assert_log_not_contains 'tee '
assert_output_contains '当前内核未提供 BBR'
echo 'PASS: a missing BBR algorithm leaves the network configuration alone'

reset_fixture
export TEST_ALGO=cubic TEST_SYSCTL_OVERRIDE=1
run_installer '5\n\n0\n'
assert_log_contains 'sysctl -w net.ipv4.tcp_congestion_control=bbr'
assert_log_not_contains 'tee '
assert_output_contains '拥塞控制已被其他设置覆盖'
echo 'PASS: an immediate conflicting override is not saved persistently'

reset_fixture
export TEST_ALGO=cubic TEST_TEE_FAIL=1
run_installer '5\n\n0\n'
assert_log_contains 'sysctl -w net.ipv4.tcp_congestion_control=bbr'
assert_output_contains '无法保存 BBR 配置'
echo 'PASS: a manual BBR persistence failure is reported'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
run_installer '4\n\n\n0\n'
assert_output_contains 'linux-image-7.2.1-xanmod1（当前正在运行）'
assert_output_contains '请先确认系统有其他可启动内核'
assert_output_contains '已取消卸载'
assert_log_not_contains 'apt-get remove'
assert_log_not_contains 'rm -f'
echo 'PASS: uninstall displays the running kernel and defaults to cancellation'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
run_installer '4\n'
assert_output_contains '已取消卸载'
assert_log_not_contains 'apt-get remove'
echo 'PASS: end of input at the uninstall confirmation performs no removal'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
export TEST_APT_REMOVE_FAIL=1
run_installer '4\ny\n\n0\n'
assert_log_contains 'apt-get remove'
assert_log_not_contains "rm -f $BBRV3_SYSCTL_CONF"
assert_output_contains '卸载未完成'
assert_log_not_contains 'update-grub'
echo 'PASS: failed uninstall preserves the configuration and reports failure'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_GRUB_FAIL=1
run_installer '8\ny\n\n0\n'
assert_log_contains 'apt-get remove'
assert_log_contains 'update-grub'
assert_output_contains '内核包已卸载，但 GRUB 更新或菜单检查未完成'
assert_output_not_contains '激进版内核卸载完成'
echo 'PASS: a failed GRUB refresh after uninstall reports the actual package state'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_GRUB_STALE=7.2.12-aggressive-xanmod1
run_installer '8\ny\n\n0\n'
assert_output_contains 'GRUB 菜单仍引用已卸载内核 7.2.12-aggressive-xanmod1'
assert_output_not_contains '激进版内核卸载完成'
echo 'PASS: a stale removed-kernel entry is reported'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_GRUB_EMPTY=1
run_installer '8\ny\n\n0\n'
assert_output_contains '未在'
assert_output_contains '中识别到 Linux 启动项'
assert_output_not_contains '激进版内核卸载完成'
echo 'PASS: an empty GRUB menu is not reported as a successful uninstall'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
run_installer '8\ny\n\n0\n'
assert_log_contains 'apt-get remove --purge -y -- linux-image-7.2.12-aggressive-xanmod1'
assert_log_contains 'update-grub'
assert_output_contains 'GRUB 菜单已更新，未发现已卸载内核的启动项'
assert_log_not_contains 'apt-get remove --purge -y -- linux-image-7.2.1-xanmod1'
assert_log_not_contains "rm -f $BBRV3_SYSCTL_CONF"
echo 'PASS: aggressive uninstall preserves the standard kernel and shared configuration'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_ecn=2' > "$BBRV3_SYSCTL_CONF"
run_installer '8\ny\n\n0\n'
grep -Fxq 'net.ipv4.tcp_ecn=2' "$BBRV3_SYSCTL_CONF"
assert_output_contains '无法确认来源'
assert_output_contains '保留共享网络配置'
echo 'PASS: uninstall with no other profile keeps the existing shared network file'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 linux-headers-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
mkdir -p "$TEST_DIR/registry"
printf '%s\n' '# Managed by Actions-bbr-v3 package registry' \
    $'aggressive\tlinux-image-7.2.12-aggressive-xanmod1' \
    $'aggressive\tlinux-headers-7.2.12-aggressive-xanmod1' > "$BBRV3_MANAGED_PACKAGES"
run_installer '8\ny\n\n0\n'
assert_log_contains 'apt-get remove --purge -y -- linux-headers-7.2.12-aggressive-xanmod1'
! grep -Fq 'linux-headers-7.2.12-aggressive-xanmod1' "$BBRV3_MANAGED_PACKAGES"
echo 'PASS: uninstall removes only a recorded header for a removed non-running image'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-aggressive-xanmod1 linux-headers-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
mkdir -p "$TEST_DIR/registry"
printf '%s\n' '# Managed by Actions-bbr-v3 package registry' \
    $'aggressive\tlinux-image-7.2.12-aggressive-xanmod1' \
    $'aggressive\tlinux-headers-7.2.12-aggressive-xanmod1' > "$BBRV3_MANAGED_PACKAGES"
export TEST_RUNNING=7.2.12-aggressive-xanmod1
run_installer '8\ny\n\n0\n'
assert_log_not_contains 'apt-get remove --purge -y -- linux-headers-7.2.12-aggressive-xanmod1'
grep -Fq 'linux-headers-7.2.12-aggressive-xanmod1' "$BBRV3_MANAGED_PACKAGES"
echo 'PASS: uninstall preserves headers for the running kernel'

reset_fixture
printf 'installed\t%s\n' linux-headers-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
mkdir -p "$TEST_DIR/registry"
printf '%s\n' '# Managed by Actions-bbr-v3 package registry' \
    $'aggressive\tlinux-headers-7.2.12-aggressive-xanmod1' > "$BBRV3_MANAGED_PACKAGES"
run_installer '8\ny\n\n0\n'
assert_log_contains 'apt-get remove --purge -y -- linux-headers-7.2.12-aggressive-xanmod1'
assert_log_not_contains 'update-grub'
assert_output_contains '未找到激进版镜像，可清理以下已记录头文件'
echo 'PASS: orphaned recorded headers can be cleaned after reboot'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
mkdir -p "$TEST_DIR/aggressive"
for path in "$BBRV3_AGGRESSIVE_CONF" "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_UNIT"; do
    printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' > "$path"
done
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' > "$BBRV3_AGGRESSIVE_LEGACY_CONF"
run_installer '8\ny\n\n0\n'
assert_log_contains 'systemctl disable --now xanmod-aggressive-bbr.service'
[[ ! -e "$BBRV3_AGGRESSIVE_CONF" && ! -e "$BBRV3_AGGRESSIVE_HELPER" && ! -e "$BBRV3_AGGRESSIVE_UNIT" ]] || {
    echo 'Managed aggressive configuration was not removed' >&2; exit 1;
}
[[ ! -e "$BBRV3_AGGRESSIVE_LEGACY_CONF" ]] || { echo 'Managed legacy configuration was not removed' >&2; exit 1; }
assert_log_not_contains "rm -f $BBRV3_SYSCTL_CONF"
echo 'PASS: aggressive uninstall removes only its own automatic configuration'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
mkdir -p "$TEST_DIR/aggressive"
for path in "$BBRV3_AGGRESSIVE_CONF" "$BBRV3_AGGRESSIVE_HELPER" "$BBRV3_AGGRESSIVE_UNIT"; do
    printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' > "$path"
done
printf '%s\n' '# User owned legacy configuration' > "$BBRV3_AGGRESSIVE_LEGACY_CONF"
run_installer '8\ny\n\n0\n'
grep -Fxq '# User owned legacy configuration' "$BBRV3_AGGRESSIVE_LEGACY_CONF"
[[ ! -e "$BBRV3_AGGRESSIVE_CONF" ]] || { echo 'Expected the managed new configuration to be removed' >&2; exit 1; }
echo 'PASS: aggressive uninstall preserves an unmanaged legacy configuration'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
mkdir -p "$TEST_DIR/aggressive"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' > "$BBRV3_AGGRESSIVE_CONF"
printf '%s\n' '# Managed by Actions-bbr-v3 aggressive profile' > "$BBRV3_AGGRESSIVE_HELPER"
printf '%s\n' '# User replacement unit' > "$BBRV3_AGGRESSIVE_UNIT"
run_installer '8\ny\n\n0\n'
assert_output_contains '发现非本项目的配置，保留全部激进版配置文件'
[[ -e "$BBRV3_AGGRESSIVE_CONF" && -e "$BBRV3_AGGRESSIVE_HELPER" && -e "$BBRV3_AGGRESSIVE_UNIT" ]] || {
    echo 'Removed files used by an unmanaged service' >&2; exit 1;
}
assert_log_not_contains 'systemctl disable --now'
echo 'PASS: uninstall preserves all files if a service file is no longer managed by the project'

reset_fixture
export TEST_MISSING_DEP=1 TEST_APT_UPDATE_FAIL=1
if run_installer ''; then
    echo 'Expected dependency installation failure to terminate the installer' >&2
    exit 1
fi
assert_output_contains '依赖安装失败'
echo 'PASS: dependency installation failure stops before the menu'

reset_fixture
printf 'config-files\t%s\n' linux-image-7.2.12-xanmod1 > "$TEST_PACKAGES"
run_installer '3\n\n0\n'
assert_output_contains '未安装优化内核'
echo 'PASS: removed packages are not reported as installed'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod1 linux-image-7.2.12-xanmod2 linux-image-7.2.12-xanmod10 linux-image-7.2.12-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=7.2.12-xanmod2 TEST_ALGO=skyline_cc
run_installer '3\n\n0\n'
assert_output_contains '正在运行: 7.2.12-xanmod2'
assert_output_contains '已安装标准版（最高）: 7.2.12-xanmod10'
assert_output_contains '已安装激进版（最高）: 7.2.12-aggressive-xanmod1'
assert_output_contains '7.2.12-xanmod2（正在运行）'
assert_output_contains '较新版本 7.2.12-xanmod10'
assert_output_contains '默认 TCP 拥塞控制: skyline_cc'
assert_output_contains '默认队列: fq（不代表现有网卡的实际队列）'
echo 'PASS: home and status distinguish running and installed revisions and label default network settings'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-xanmod1 linux-image-7.3.0-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=7.3.0-xanmod1 TEST_ALGO=bbr TEST_BBR_VERSION=3
run_installer '3\n\n0\n'
assert_output_contains '当前生效内核: 标准版（依据运行内核标识）'
assert_output_contains 'BBR 生效情况: 标准版 BBR（新连接默认使用，按内核标识推断）'
assert_output_contains '激进版已安装但未运行；切换需重启并选择激进版启动项'
assert_output_not_contains '当前生效内核: 激进版'
echo 'PASS: both profiles installed, running standard BBR is identified explicitly'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-xanmod1 linux-image-7.3.0-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=bbr TEST_BBR_VERSION=3
run_installer '3\n\n0\n'
assert_output_contains '当前生效内核: 激进版（依据运行内核标识）'
assert_output_contains 'BBR 生效情况: 激进版 BBR（新连接默认使用，按内核标识推断）'
assert_output_contains '标准版已安装但未运行；切换需重启并选择标准版启动项'
assert_output_not_contains '当前生效内核: 标准版'
echo 'PASS: both profiles installed, running aggressive BBR is identified explicitly'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-xanmod1 linux-image-7.3.0-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_ALGO=skyline_cc TEST_SKYLINE_ACTIVE=1 TEST_BBR_VERSION=3
run_installer '3\n\n0\n'
assert_output_contains '当前生效内核: 激进版（依据运行内核标识）'
assert_output_contains 'BBR 生效情况: 未作为默认算法（当前默认 skyline_cc）'
assert_output_not_contains 'BBR 生效情况: 激进版 BBR'
assert_log_not_contains 'sysctl -w'
echo 'PASS: an aggressive kernel with Skyline does not claim that BBR is the default'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-b0123456789r1a1-aggressive-xanmod1 linux-image-7.3.0-b0123456789r2a1-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=7.3.0-b0123456789r1a1-aggressive-xanmod1 TEST_ALGO=bbr
run_installer '3\n\n0\n'
assert_output_contains '当前生效内核: 激进版（依据运行内核标识）'
assert_output_contains '已安装激进版（最高）: 7.3.0-b0123456789r2a1-aggressive-xanmod1'
assert_output_contains '较新版本 7.3.0-b0123456789r2a1-aggressive-xanmod1'
echo 'PASS: distinct builds are identified and ordered by Actions run number'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-xanmod1 linux-image-7.3.0-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=6.8.0-35-generic TEST_ALGO=bbr
run_installer '3\n\n0\n'
assert_output_contains '当前生效内核: 无法识别（运行内核不符合本项目命名）'
assert_output_contains 'BBR 生效情况: BBR 已设为默认，但无法确认标准版或激进版'
assert_output_not_contains '当前生效内核: 标准版'
assert_output_not_contains '当前生效内核: 激进版'
echo 'PASS: unrelated running kernels do not inherit an installed profile label'

reset_fixture
export TEST_RUNNING='' TEST_ALGO=''
run_installer '3\n\n0\n'
assert_output_contains '当前生效内核: 无法识别（无法读取运行内核）'
assert_output_contains 'BBR 生效情况: 未知（无法读取默认拥塞算法）'
echo 'PASS: missing kernel or algorithm information is reported as unknown'

reset_fixture
export TEST_RUNNING=7.3.0-rc2-xanmod3 TEST_ALGO=bbr
run_installer '0\n'
assert_output_contains '当前生效内核: 标准版（依据运行内核标识）'
echo 'PASS: release-candidate kernel names identify their running profile'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-xanmod1 > "$TEST_PACKAGES"
export TEST_ALGO=skyline_cc TEST_BBR_VERSION=3
run_installer '3\n\n0\n'
assert_output_contains '需重启'
assert_output_contains 'v3（可用，当前未启用）'
echo 'PASS: status distinguishes an older running kernel and an inactive BBRv3'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=7.3.0-xanmod1 TEST_BBR_VERSION=3
run_installer '3\n\n0\n'
assert_output_contains 'v3（已启用）'
echo 'PASS: status reports BBRv3 when it is the active congestion algorithm'

reset_fixture
export TEST_RUNNING=7.3.0-xanmod1 TEST_BBR_VERSION=3 TEST_ALGO=cubic TEST_AVAILABLE='reno cubic'
run_installer '3\n\n0\n'
assert_output_contains 'v3（模块信息；当前可用状态未知或尚未加载）'
assert_output_not_contains 'v3（可用，当前未启用）'
echo 'PASS: module metadata alone is not reported as an available algorithm'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod1 linux-image-7.3.0-aggressive-xanmod1 > "$TEST_PACKAGES"
export TEST_RUNNING=7.3.0-aggressive-xanmod1 TEST_BBR_VERSION=3
run_installer '3\n\n0\n'
assert_output_contains '激进版:'
assert_output_contains '7.3.0-aggressive-xanmod1'
echo 'PASS: status recognizes the separately installed running aggressive kernel'

reset_fixture
if ! run_installer ''; then
    echo 'Expected end of input to exit cleanly' >&2
    exit 1
fi
echo 'PASS: end of input exits the menu cleanly'

reset_fixture
run_installer '0\n'
if LC_ALL=C grep -q $'\033' "$TEST_DIR/output"; then
    echo 'Unexpected ANSI escape codes in redirected output' >&2
    exit 1
fi
echo 'PASS: redirected output is readable without ANSI escape codes'
