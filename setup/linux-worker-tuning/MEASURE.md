# Measuring a Linux worker

All commands run as root unless noted. `modprobe msr` first for anything that reads
an MSR (`apt install msr-tools linux-tools-generic stress-ng fio smartmontools`).

## Power

**CPU package** (Intel and AMD, via RAPL): turbostat, averaged over a minute.

```bash
turbostat --quiet --show Bzy_MHz,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc8,PkgWatt,PkgTmp \
          --interval 60 --num_iterations 1
```

Idle target: most of the time in PC6 or deeper. Stuck in PC2/PC3 means a device
or the panel is holding the package awake.

**Whole system** (what you pay for):

- **Mac:** the SMC key `PDTR` (DC-in watts) through applesmc:
  `sudo python3 scripts/mac-power.py idle 60` averages it next to turbostat.
- **PC:** a wall meter. Take one reading while someone is at the box, because
  nothing on AC reports system power. After that, package watts and PC6 residency
  are the remote proxy. `/sys/class/power_supply/BAT*/power_now` (µW) reads only on
  battery, where the box may behave differently.

**Before measuring idle:** desktop off, panel blanked (`cat /sys/class/drm/*/dpms`),
no SSH session doing work, a minute after the last keypress.

## What keeps the package awake

```bash
# PCI devices that never runtime-suspend (look for "active" with control "on", state D0)
for d in /sys/bus/pci/devices/*; do
  printf '%s %s %s %s %s\n' "${d##*/}" "$(cat $d/power/control)" "$(cat $d/power/runtime_status)" \
    "$(cat $d/power_state 2>/dev/null)" \
    "$(lspci -s ${d##*/} | cut -d' ' -f2-)"; done
# USB devices
grep . /sys/bus/usb/devices/*/power/control /sys/bus/usb/devices/*/power/runtime_status
```

Try one device at a time: `echo auto > .../power/control`, re-measure. Unbinding the
driver resets `control` to `on`, so set it again. `powertop` lists tunables; use it
to find candidates, never `--auto-tune` blindly (it can suspend your network).

## Why the CPU runs below max turbo

```bash
# Power limits and turbo ceiling
R=/sys/class/powercap/intel-rapl:0
echo "PL1 $(( $(cat $R/constraint_0_power_limit_uw)/1000000 )) W, PL2 $(( $(cat $R/constraint_1_power_limit_uw)/1000000 )) W"
rdmsr -p0 0x1ad                        # turbo ratios, one byte per active-core count (x100 MHz)
rdmsr -p0 -f 23:16 -d 0x1a2            # Tjmax: "heat" means within a few °C of it
rdmsr -p0 0x1fc                        # bit 0 = BD PROCHOT enabled
```

Throttle reasons: sample during a steady load. The register is 0x690 on Haswell and
Broadwell and 0x64F on Skylake and newer (Kaby, Coffee, Comet Lake…); the bits below are live status, and each
bit + 16 is a sticky "happened since cleared" copy (clear with `wrmsr -a <reg> 0`).

```bash
REG=0x690
for i in $(seq 120); do v=$((0x$(rdmsr -p0 $REG)))
  for b in "0 PROCHOT" "1 thermal" "8 VR-current" "10 PL1" "11 PL2" "12 max-turbo"; do
    set -- $b; [ $(( v >> $1 & 1 )) = 1 ] && echo $2; done; sleep 0.5
done | sort | uniq -c                  # share of samples per reason
```

`max-turbo` means nothing is limiting. `thermal` most of the time means cooling is
the limit: repaste, undervolt, airflow. `PL1` means the power limit is: raise it
only if temperatures allow.

## Load and correctness

```bash
stress-ng --cpu 1 --cpu-method all --verify --timeout 60     # top turbo, checks results
stress-ng --cpu 0 --cpu-method matrixprod --verify --timeout 60
stress-ng --cpu 0 --cpu-load 35 --cpu-method all --verify --timeout 60   # clock keeps changing
```

mprime torture (heaviest, FMA3, checks every result): download `p95v*.linux64.tar.gz`
from mersenne.org, add `prime.txt`, then run `timeout 300 ./mprime -t`.

```
StressTester=1
UsePrimenet=0
MinTortureFFT=36
MaxTortureFFT=248
TortureMem=0
TortureTime=1
TortureHyperthreading=1
```

Pass: every `Torture Test completed … 0 errors, 0 warnings` line, no `FATAL`.

**Sustained throughput:** a real build, 3 clean runs back to back, started below
~52 °C. Log clock, temperature and RAPL energy every 2 s. Compare the steady 8-thread
clock too; it's less noisy than wall time.

**Reproducible build** (to catch silent errors): build twice at stock and hash the
objects. They must match before the hash means anything.

```bash
make distclean; make -j"$(nproc)" OPTIMIZATION=-O2      # Redis: LTO objects differ run to run
find . -name '*.o' ! -name release.o | sort | xargs sha256sum | sha256sum
```

## Disk

```bash
F=~/fio.tmp
fio --name=verify --filename=$F --size=2G --bs=1M --rw=write --direct=1 --ioengine=libaio \
    --iodepth=16 --verify=crc32c --do_verify=1               # 0 errors
fio --name=rand --filename=$F --size=2G --bs=4k --rw=randrw --rwmixread=70 --direct=1 \
    --ioengine=libaio --iodepth=32 --runtime=60 --time_based --group_reporting
rm $F
journalctl -k -b | grep -iE 'ata[0-9].*(error|failed)|host bus error|FPDMA|nvme.*(timeout|reset)|I/O error'
smartctl -H -A /dev/sda                                       # or /dev/nvme0
```

libata applies only the first matching `libata.force` entry per device:
`noncq,max_sec=2560` silently drops `max_sec`.

## Undervolt (Intel, MSR 0x150)

Planes: 0 core, 1 GPU, 2 cache, 3 uncore. Core and cache share a rail on these
chips, so set both. The offset is in 1/1.024 mV steps in bits 31:21.

```bash
set_mv() { o=0; [ $1 -ne 0 ] && o=$(( ($1 * 1024 - 500) / 1000 ))
  for p in 0 2; do wrmsr -a 0x150 $(printf '0x80000%d11%08x' $p $(( (o & 0x7ff) << 21 ))); done; }
get_mv() { wrmsr -p0 0x150 0x8000001000000000; o=$(( (0x$(rdmsr -p0 0x150) >> 21) & 0x7ff ))
  [ $o -ge 1024 ] && o=$((o - 2048)); echo $(( (o * 1000 - 512) / 1024 )); }
set_mv -10; get_mv; set_mv 0          # reads back -10: supported; 0: locked
```

The offset resets on every reboot. Each write marks the kernel tainted
(`CPU_OUT_OF_SPEC`); `options msr allow_writes=on` only silences the warning.
