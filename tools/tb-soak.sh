#!/bin/bash
# Filesystem-level soak of a Thunderbolt NVMe behind APCIEC (pcie-apple-apciec).
#   sudo tb-soak.sh PART HOURS [REPLUG_MIN] [PORT]
#   e.g. sudo tb-soak.sh /dev/disk/by-partlabel/tbsoak 2 30 3
# PART holds a scratch btrfs (label tbsoak) - its contents are destroyed.
# Each round: fio verify workload on files (direct I/O, crc32c), re-verify of a
# reference file written once at the start, idle period, btrfs device stats.
# Every REPLUG_MIN minutes (0 = never): umount, software replug of PORT,
# wait for the namespace, mount, full btrfs scrub.
# Output in $SOAK_DIR/<UTC start>/ (default /var/tmp/tb-soak): metrics.csv (5 s samples),
# events.csv, fio-*.json per phase, smart-{before,after}.txt, summary.txt.
set -uo pipefail
part=${1:?usage: $0 PART HOURS [REPLUG_MIN] [PORT]}; hours=${2:?hours}
replug_min=${3:-0}; port=${4:-3}
part=$(readlink -f "$part")
mnt=/mnt/tbsoak
run=${SOAK_DIR:-/var/tmp/tb-soak}/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$run" "$mnt"
ev() { echo "$(date +%s),$1,${2:-}" >> "$run/events.csv"; echo "tb-soak: $1 ${2:-}" > /dev/kmsg; }
disk() { lsblk -no PKNAME "$part" 2>/dev/null; }
hwmon() { ls -d /sys/block/"$(disk)"/device/hwmon* /sys/block/"$(disk)"/device/device/hwmon* 2>/dev/null | head -1; }
echo "epoch,event,detail" > "$run/events.csv"
smartctl -a "/dev/$(disk)" > "$run/smart-before.txt"
ev start "part=$part hours=$hours replug_min=$replug_min port=$port kernel=$(uname -r)"

# 5 s sampler: cumulative sectors, NVMe temperature, USB4 link errors, port regs
sampler() {
    echo "epoch,disk,rd_sectors,wr_sectors,inflight,temp_mC,link_errors,tunstat,intstat" > "$run/metrics.csv"
    while :; do
        d=$(disk)
        if [ -n "$d" ] && [ -r /sys/block/$d/stat ]; then
            read -r r _ rs _ w _ ws _ inf _ < /sys/block/$d/stat
            h=$(hwmon); t=$(cat "$h/temp1_input" 2>/dev/null || echo)
        else
            rs=; ws=; inf=; t=; d=
        fi
        le=$(dmesg | grep -c "link error")
        dbg=$(cat /sys/kernel/debug/*.apciec/regs 2>/dev/null)
        ts=$(echo "$dbg" | awk '$1 == "TUNSTAT" { print $3 }')
        is=$(echo "$dbg" | awk '$1 == "INTSTAT" { print $3 }')
        echo "$(date +%s),$d,$rs,$ws,$inf,$t,$le,$ts,$is" >> "$run/metrics.csv"
        sleep 5
    done
}
sampler & spid=$!
trap 'kill $spid 2>/dev/null; umount $mnt 2>/dev/null' EXIT

mount_fs() {
    mount -o noatime "$part" "$mnt" || return 1
    mkdir -p "$mnt/work"
}
fail() { ev FAIL "$1"; echo "FAIL: $1" | tee -a "$run/summary.txt"; exit 1; }

findmnt "$mnt" >/dev/null && umount "$mnt"
mkfs.btrfs -q -f -L tbsoak "$part" || fail mkfs
mount_fs || fail mount
# reference file, verified every round (detects silent corruption of data at rest)
fio --name=ref --directory="$mnt/work" --filename=ref.dat --size=8G --rw=write --bs=1M \
    --direct=1 --ioengine=io_uring --iodepth=16 --verify=crc32c --do_verify=0 \
    --output-format=json --output="$run/fio-ref-write.json" || fail "ref write"
ev ref_written 8G

end=$(( $(date +%s) + $(echo "$hours * 3600 / 1" | bc) )); next_replug=$(( $(date +%s) + replug_min * 60 ))
round=0; replugs=0
while [ "$(date +%s)" -lt "$end" ]; do
    round=$((round + 1))
    ev round_start "$round"
    # ROUND_SEC (default 900) mixed workload: random 4k-1M write+verify, sequential read, random 4k read
    fio --output-format=json --output="$run/fio-r$round.json" \
        --directory="$mnt/work" --direct=1 --ioengine=io_uring --time_based --runtime=${ROUND_SEC:-900} \
        --group_reporting=0 \
        --name=rw --filename=rw.dat --size=24G --rw=randwrite --bsrange=4k-1M \
            --iodepth=16 --verify=crc32c --verify_fatal=1 --verify_backlog=4096 \
        --name=seq --filename=seq.dat --size=16G --rw=read --bs=1M --iodepth=8 \
        --name=rnd --filename=seq.dat --size=16G --rw=randread --bs=4k --iodepth=32 \
        > /dev/null 2>"$run/fio-r$round.err"
    rc=$?
    [ $rc = 0 ] || fail "round $round fio rc=$rc: $(head -c 300 "$run/fio-r$round.err")"
    fio --name=ref --directory="$mnt/work" --filename=ref.dat --size=8G --rw=write --bs=1M \
        --direct=1 --ioengine=io_uring --iodepth=16 --verify=crc32c --verify_only=1 \
        --verify_fatal=1 --output-format=json --output="$run/fio-ref-r$round.json" \
        2>>"$run/fio-r$round.err" || fail "round $round reference verify"
    st=$(btrfs device stats -c "$mnt" 2>&1) || fail "round $round btrfs errors: $(echo $st)"
    ev round_ok "$round"
    ev idle_start ${IDLE_SEC:-120}
    sleep ${IDLE_SEC:-120}
    if [ "$replug_min" -gt 0 ] && [ "$(date +%s)" -ge "$next_replug" ]; then
        replugs=$((replugs + 1))
        sync; umount "$mnt" || fail "umount before replug"
        ev replug_start "$replugs"
        t0=$(date +%s.%N)
        tb-port-cycle "$port" 4 >/dev/null 2>&1
        ok=
        for i in $(seq 1 300); do [ -b "$part" ] && blkid "$part" >/dev/null 2>&1 && ok=1 && break; sleep 0.1; done
        [ -n "$ok" ] || fail "replug $replugs: partition did not return"
        ev replug_back "$(echo "$(date +%s.%N) - $t0" | bc)"
        mount_fs || fail "mount after replug $replugs"
        btrfs scrub start -B "$mnt" > "$run/scrub-$replugs.txt" 2>&1 || fail "scrub after replug $replugs"
        grep -q "no errors found\|Error summary: *no errors" "$run/scrub-$replugs.txt" ||
            fail "scrub errors after replug $replugs"
        ev scrub_ok "$replugs"
        next_replug=$(( $(date +%s) + replug_min * 60 ))
    fi
done
btrfs scrub start -B "$mnt" > "$run/scrub-final.txt" 2>&1 || fail "final scrub"
umount "$mnt"
smartctl -a "/dev/$(disk)" > "$run/smart-after.txt"
ev done "rounds=$round replugs=$replugs"
echo "PASS: $round rounds, $replugs replugs, $(dmesg | grep -c 'link error') link errors in dmesg" | tee "$run/summary.txt"
