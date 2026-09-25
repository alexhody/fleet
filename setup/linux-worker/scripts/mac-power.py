#!/usr/bin/env python3
# Mac only: average DC-in power (SMC key PDTR, via applesmc) next to turbostat package
# stats over N seconds. Run as root: mac-power.py LABEL SECS
import struct, subprocess, sys, time
SMC = "/sys/devices/platform/applesmc.768"
label, secs = sys.argv[1], int(sys.argv[2])

def idx(name):
    for i in range(int(open(SMC + "/key_count").read())):
        open(SMC + "/key_at_index", "w").write(str(i))
        if open(SMC + "/key_at_index_name").read().strip() == name:
            return i

i = idx("PDTR")
ts = subprocess.Popen(["turbostat", "--quiet", "--show", "Bzy_MHz,Pkg%pc6,PkgWatt,PkgTmp",
                       "--interval", str(secs), "--num_iterations", "1"],
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
vals, end = [], time.time() + secs
while time.time() < end:
    open(SMC + "/key_at_index", "w").write(str(i))
    t = open(SMC + "/key_at_index_type").read().strip("\x00 \n")
    b = open(SMC + "/key_at_index_data", "rb").read()
    vals.append(struct.unpack("<f", b[:4])[0] if t.startswith("flt") else int.from_bytes(b[:2], "big") / 256)
    time.sleep(0.5)
out = ts.communicate()[0].split("\n")
hdr, row = out[0].split(), out[1].split()
stats = " ".join(f"{h}={v}" for h, v in zip(hdr, row))
print(f"{label:28s} DC-in {sum(vals)/len(vals):5.2f} W  {stats}")
