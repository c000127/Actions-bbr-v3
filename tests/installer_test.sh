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
        [[ ${1:-} == -m ]] && { echo x86_64; exit 0; }
        [[ ${1:-} == -r ]] && { echo "$TEST_RUNNING"; exit 0; }
        exit 1
        ;;
    curl) echo '[]' ;;
    jq)
        case "$*" in
            *'type == "array"'*) exit 0 ;;
            *'.assets[]'*) cat "$TEST_URLS" ;;
            *'startswith'*) cat "$TEST_TAGS" ;;
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
                        if [[ -f "$TEST_DIR/algorithm" ]]; then cat "$TEST_DIR/algorithm"; else echo "${TEST_ALGO:-bbr}"; fi
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
        esac
        exit 0
        ;;
    systemctl)
        [[ ${TEST_SKYLINE_ACTIVE:-0} == 1 && ${1:-} == is-active ]] && exit 0
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

for cmd in sudo apt-get dpkg dpkg-query dpkg-deb uname curl jq wget sysctl systemctl modinfo tee rm clear reboot; do
    cp "$TEST_DIR/bin/mock-command" "$TEST_DIR/bin/$cmd"
    chmod +x "$TEST_DIR/bin/$cmd"
done

export REAL_RM TEST_DIR
export PATH="$TEST_DIR/bin:$PATH"
export TEST_LOG="$TEST_DIR/commands.log" TEST_PACKAGES="$TEST_DIR/packages"
export TEST_URLS="$TEST_DIR/urls" TEST_TAGS="$TEST_DIR/tags"
export BBRV3_SYSCTL_CONF="$TEST_DIR/sysctl.conf"
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
    rm -f "$BBRV3_SYSCTL_CONF" "$TEST_DIR/algorithm" "$TEST_DIR/tee-content"
    unset TEST_APT_UPDATE_FAIL TEST_APT_REMOVE_FAIL TEST_MISSING_DEP TEST_DPKG_FAIL TEST_DEB_FAIL TEST_WGET_FAIL TEST_TEE_FAIL TEST_ALGO TEST_QDISC TEST_BBR_VERSION TEST_SKYLINE_ACTIVE TEST_AVAILABLE TEST_SYSCTL_FAIL TEST_SYSCTL_OVERRIDE
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

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 linux-image-7.2.0-xanmod1 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_log_contains 'dpkg -i '
assert_log_contains 'apt-get remove --purge -y -- linux-image-7.2.0-xanmod1'
assert_log_not_contains 'apt-get remove --purge -y -- linux-image-7.2.1-xanmod1'
assert_log_not_contains 'sysctl -w'
assert_log_not_contains 'tee '
assert_output_contains '新内核:'
echo 'PASS: upgrade retains the running kernel without changing network settings'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.12-xanmod1 > "$TEST_PACKAGES"
run_installer '1\ny\nn\n0\n'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'apt-get remove'
echo 'PASS: reinstall retains the newly installed package'

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
printf 'installed\t%s\n' linux-image-7.2.9-xanmod1 linux-image-7.2.12-xanmod1 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_output_contains '已是最新版本'
assert_log_not_contains 'dpkg -i'
echo 'PASS: installed versions are compared numerically'

reset_fixture
printf 'installed\t%s\n' linux-image-7.3.0-rc1-xanmod1 linux-image-7.3.0-xanmod1 > "$TEST_PACKAGES"
printf '%s\n' x86_64-7.3 > "$TEST_TAGS"
run_installer '1\nn\n\n0\n'
assert_output_contains '已是最新版本'
assert_log_not_contains 'dpkg -i'
echo 'PASS: a stable installed version sorts after its release candidate'

reset_fixture
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1:amd64 linux-image-7.2.0-xanmod1:amd64 > "$TEST_PACKAGES"
run_installer '1\nn\n\n0\n'
assert_log_contains 'apt-get remove --purge -y -- linux-image-7.2.0-xanmod1:amd64'
assert_log_not_contains 'linux-image-7.2.1-xanmod1:amd64'
echo 'PASS: architecture-qualified running packages are retained'

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
printf 'installed\t%s\n' linux-image-7.2.1-xanmod1 > "$TEST_PACKAGES"
export TEST_DPKG_FAIL=1
run_installer '1\n\n0\n'
assert_log_contains 'dpkg -i '
assert_log_not_contains 'apt-get remove'
assert_log_not_contains 'tee '
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
export TEST_APT_REMOVE_FAIL=1
run_installer '4\n\n0\n'
assert_log_contains 'apt-get remove'
assert_log_not_contains "rm -f $BBRV3_SYSCTL_CONF"
assert_output_contains '卸载失败'
echo 'PASS: failed uninstall preserves the configuration and reports failure'

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
if ! run_installer ''; then
    echo 'Expected end of input to exit cleanly' >&2
    exit 1
fi
echo 'PASS: end of input exits the menu cleanly'
