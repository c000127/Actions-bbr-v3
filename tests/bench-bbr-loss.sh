#!/usr/bin/env bash
set -euo pipefail

# Compare two TCP congestion controls using only disposable network namespaces.
# Never attach netem to an existing host interface.
if [[ $EUID -ne 0 ]]; then
    echo "Run as root: network namespaces and netem require CAP_NET_ADMIN." >&2
    exit 1
fi

ETHTOOL=${ETHTOOL:-ethtool}
for tool in ip tc iperf3 ping timeout "$ETHTOOL"; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

DURATION=${BENCH_SECONDS:-20}
REPEATS=${BENCH_REPEATS:-2}
[[ $DURATION =~ ^[0-9]+$ && $DURATION -ge 5 && $DURATION -le 300 ]] || { echo "Invalid BENCH_SECONDS" >&2; exit 1; }
[[ $REPEATS =~ ^[0-9]+$ && $REPEATS -ge 1 && $REPEATS -le 10 ]] || { echo "Invalid BENCH_REPEATS" >&2; exit 1; }
read -r -a algorithms <<< "${ALGORITHMS:-bbr bbraggr}"
[[ ${#algorithms[@]} -gt 0 ]] || { echo "No congestion algorithms specified" >&2; exit 1; }
available=" $(sysctl -n net.ipv4.tcp_available_congestion_control) "
for algorithm in "${algorithms[@]}"; do
    [[ $algorithm =~ ^[a-zA-Z0-9_]{1,15}$ && $available == *" $algorithm "* ]] || {
        echo "Congestion control is unavailable: $algorithm" >&2
        exit 1
    }
done

OUT=${BENCH_OUTPUT:-$(mktemp -d /var/tmp/bbr-loss-results.XXXXXXXX)}
mkdir -p "$OUT"
[[ ! -e "$OUT/results.tsv" ]] || { echo "Results already exist in $OUT" >&2; exit 1; }
suffix="$$"
client_ns="bbrc-$suffix"
router_ns="bbrr-$suffix"
server_ns="bbrs-$suffix"
client_dev="bc${suffix}"
router_client_dev="brc${suffix}"
router_server_dev="brs${suffix}"
server_dev="bs${suffix}"
server_pid=
extra_server_pid=
first_client_pid=
second_client_pid=
client_created=0
router_created=0
server_created=0
client_link_created=0
server_link_created=0

cleanup() {
    local pid
    for pid in "$server_pid" "$extra_server_pid" "$first_client_pid" "$second_client_pid"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    [[ $client_created -eq 0 ]] || ip netns del "$client_ns" 2>/dev/null || true
    [[ $router_created -eq 0 ]] || ip netns del "$router_ns" 2>/dev/null || true
    [[ $server_created -eq 0 ]] || ip netns del "$server_ns" 2>/dev/null || true
    [[ $client_link_created -eq 0 ]] || ip link del "$client_dev" 2>/dev/null || true
    [[ $server_link_created -eq 0 ]] || ip link del "$server_dev" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ip netns list | awk '{print $1}' | grep -Fxq -e "$client_ns" -e "$router_ns" -e "$server_ns" || \
   ip link show "$client_dev" >/dev/null 2>&1 || ip link show "$router_client_dev" >/dev/null 2>&1 || \
   ip link show "$router_server_dev" >/dev/null 2>&1 || ip link show "$server_dev" >/dev/null 2>&1; then
    echo "Namespace or veth name already exists; refusing to alter it" >&2
    # Do not remove a namespace or interface that was not created by this run.
    trap - EXIT
    exit 1
fi

ip netns add "$client_ns"
client_created=1
ip netns add "$router_ns"
router_created=1
ip netns add "$server_ns"
server_created=1
ip link add "$client_dev" type veth peer name "$router_client_dev"
client_link_created=1
ip link add "$router_server_dev" type veth peer name "$server_dev"
server_link_created=1
ip link set "$client_dev" netns "$client_ns"
ip link set "$router_client_dev" netns "$router_ns"
ip link set "$router_server_dev" netns "$router_ns"
ip link set "$server_dev" netns "$server_ns"
ip -n "$client_ns" addr add 198.18.0.1/30 dev "$client_dev"
ip -n "$router_ns" addr add 198.18.0.2/30 dev "$router_client_dev"
ip -n "$router_ns" addr add 198.18.0.5/30 dev "$router_server_dev"
ip -n "$server_ns" addr add 198.18.0.6/30 dev "$server_dev"
ip -n "$client_ns" link set lo up
ip -n "$router_ns" link set lo up
ip -n "$server_ns" link set lo up
ip -n "$client_ns" link set "$client_dev" up
ip -n "$router_ns" link set "$router_client_dev" up
ip -n "$router_ns" link set "$router_server_dev" up
ip -n "$server_ns" link set "$server_dev" up
ip -n "$client_ns" route add default via 198.18.0.2
ip -n "$server_ns" route add default via 198.18.0.5
ip netns exec "$router_ns" sysctl -qw net.ipv4.ip_forward=1

# Disable aggregation so netem loss applies to packets rather than GSO batches.
ip netns exec "$client_ns" "$ETHTOOL" -K "$client_dev" tso off gso off gro off
ip netns exec "$router_ns" "$ETHTOOL" -K "$router_client_dev" tso off gso off gro off
ip netns exec "$router_ns" "$ETHTOOL" -K "$router_server_dev" tso off gso off gro off
ip netns exec "$server_ns" "$ETHTOOL" -K "$server_dev" tso off gso off gro off
ip netns exec "$client_ns" sysctl -qw net.ipv4.tcp_ecn=0
ip netns exec "$server_ns" sysctl -qw net.ipv4.tcp_ecn=0
ip netns exec "$client_ns" tc qdisc add dev "$client_dev" root fq
ip netns exec "$server_ns" tc qdisc add dev "$server_dev" root fq

{
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'iperf=%s\n' "$(iperf3 --version | head -1)"
    printf 'delay_each_direction=50ms\nrate_each_direction=100mbit\necn=0\n'
    printf 'topology=client-router-server (netem on router egress)\n'
    printf 'seconds=%s\nrepeats=%s\nalgorithms=%s\n' "$DURATION" "$REPEATS" "${algorithms[*]}"
    printf 'started_utc=%s\n' "$(date -u +%FT%TZ)"
} > "$OUT/metadata.txt"
printf 'scenario\tsend_loss_pct\tack_loss_pct\talgo\trepeat\texit_code\tjson\n' > "$OUT/results.tsv"

# In the symmetric cases, 1 - (1 - p)^2 is about 30% or 50% across the two
# directions. One-way cases separately exercise 30% and 50% data packet loss.
scenarios=(
    'clean 0 0'
    'one_way_30 30 0'
    'one_way_50 50 0'
    'symmetric_total_30 16.33 16.33'
    'symmetric_total_50 29.29 29.29'
)

set_impairment() {
    local send_loss=$1 ack_loss=$2 seed=$3
    ip netns exec "$router_ns" tc qdisc del dev "$router_server_dev" root 2>/dev/null || true
    ip netns exec "$router_ns" tc qdisc del dev "$router_client_dev" root 2>/dev/null || true
    ip netns exec "$router_ns" tc qdisc add dev "$router_server_dev" root handle 1: \
        netem limit 10000 delay 50ms loss "$send_loss%" rate 100mbit seed "$seed"
    ip netns exec "$router_ns" tc qdisc add dev "$router_client_dev" root handle 1: \
        netem limit 10000 delay 50ms loss "$ack_loss%" rate 100mbit seed "$((seed + 100))"
    ip netns exec "$router_ns" tc qdisc add dev "$router_server_dev" parent 1:1 handle 10: fq
    ip netns exec "$router_ns" tc qdisc add dev "$router_client_dev" parent 1:1 handle 10: fq
}

selected=0
if [[ ${BENCH_SHARED_ONLY:-0} != 1 ]]; then
for scenario in "${scenarios[@]}"; do
    read -r name send_loss ack_loss <<< "$scenario"
    [[ -z ${BENCH_CASE_FILTER:-} || $name == "$BENCH_CASE_FILTER" ]] || continue
    selected=$((selected + 1))
    for ((iteration = 1; iteration <= REPEATS; iteration++)); do
        for algorithm in "${algorithms[@]}"; do
            run="$name-$algorithm-$iteration"
            # Each run starts with fresh queues and a repeatable netem seed.
            seed=$((1000 + iteration))
            set_impairment "$send_loss" "$ack_loss" "$seed"
            if [[ "$name" == clean && "$iteration" -eq 1 && "$algorithm" == "${algorithms[0]}" ]]; then
                ip netns exec "$client_ns" ping -n -c 3 -i 0.2 -W 3 198.18.0.6 > "$OUT/calibration-ping.txt"
            fi

            ip netns exec "$server_ns" iperf3 -s -1 -p 5201 > "$OUT/$run-server.log" 2>&1 &
            server_pid=$!
            sleep 0.3
            echo "Running $run (data loss $send_loss%, ACK loss $ack_loss%)"
            rc=0
            timeout "$((DURATION + 65))s" ip netns exec "$client_ns" iperf3 \
                -c 198.18.0.6 -p 5201 -C "$algorithm" -t "$DURATION" \
                --connect-timeout 30000 -J > "$OUT/$run.json" 2> "$OUT/$run.err" || rc=$?
            kill "$server_pid" 2>/dev/null || true
            wait "$server_pid" 2>/dev/null || true
            server_pid=
            ip netns exec "$router_ns" tc -s qdisc show dev "$router_server_dev" > "$OUT/$run-data-qdisc.txt"
            ip netns exec "$router_ns" tc -s qdisc show dev "$router_client_dev" > "$OUT/$run-ack-qdisc.txt"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$name" "$send_loss" "$ack_loss" "$algorithm" "$iteration" "$rc" "$run.json" >> "$OUT/results.tsv"
        done
    done
done
[[ $selected -gt 0 ]] || { echo "No scenario matched BENCH_CASE_FILTER" >&2; exit 1; }
fi

# Concurrent streams share the same router bottleneck. Begin without loss so
# both control connections complete, then enable loss during iperf's omitted
# warmup. The reported interval therefore measures the same impaired period.
if [[ ${BENCH_SHARED:-0} == 1 || ${BENCH_SHARED_ONLY:-0} == 1 ]]; then
    [[ ${#algorithms[@]} -eq 2 ]] || { echo "Shared test requires exactly two algorithms" >&2; exit 1; }
    for scenario in 'shared_total_30 16.33 16.33' 'shared_total_50 29.29 29.29'; do
        read -r name send_loss ack_loss <<< "$scenario"
        for ((iteration = 1; iteration <= REPEATS; iteration++)); do
            seed=$((3000 + iteration))
            set_impairment 0 0 "$seed"
            first_run="$name-${algorithms[0]}-$iteration"
            second_run="$name-${algorithms[1]}-$iteration"
            ip netns exec "$server_ns" iperf3 -s -1 -p 5201 > "$OUT/$first_run-server.log" 2>&1 &
            server_pid=$!
            ip netns exec "$server_ns" iperf3 -s -1 -p 5202 > "$OUT/$second_run-server.log" 2>&1 &
            extra_server_pid=$!
            sleep 0.3
            echo "Running $name shared bottleneck, repeat $iteration"
            timeout "$((DURATION + 70))s" ip netns exec "$client_ns" iperf3 -c 198.18.0.6 -p 5201 \
                -C "${algorithms[0]}" -O 5 -t "$DURATION" --connect-timeout 30000 -J \
                > "$OUT/$first_run.json" 2> "$OUT/$first_run.err" &
            first_client_pid=$!
            timeout "$((DURATION + 70))s" ip netns exec "$client_ns" iperf3 -c 198.18.0.6 -p 5202 \
                -C "${algorithms[1]}" -O 5 -t "$DURATION" --connect-timeout 30000 -J \
                > "$OUT/$second_run.json" 2> "$OUT/$second_run.err" &
            second_client_pid=$!
            sleep 2
            set_impairment "$send_loss" "$ack_loss" "$seed"
            first_rc=0
            wait "$first_client_pid" || first_rc=$?
            second_rc=0
            wait "$second_client_pid" || second_rc=$?
            first_client_pid=
            second_client_pid=
            kill "$server_pid" "$extra_server_pid" 2>/dev/null || true
            wait "$server_pid" 2>/dev/null || true
            wait "$extra_server_pid" 2>/dev/null || true
            server_pid=
            extra_server_pid=
            ip netns exec "$router_ns" tc -s qdisc show dev "$router_server_dev" > "$OUT/$name-$iteration-data-qdisc.txt"
            ip netns exec "$router_ns" tc -s qdisc show dev "$router_client_dev" > "$OUT/$name-$iteration-ack-qdisc.txt"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$send_loss" "$ack_loss" "${algorithms[0]}" "$iteration" "$first_rc" "$first_run.json" >> "$OUT/results.tsv"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$send_loss" "$ack_loss" "${algorithms[1]}" "$iteration" "$second_rc" "$second_run.json" >> "$OUT/results.tsv"
        done
    done
fi
echo "Results saved in $OUT"
