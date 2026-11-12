#!/usr/bin/env python3
"""Regenerates the seed corpora under mayhem/<target>/testsuite/ (valid MAVLink frames, CRCs included).

usage: gen_seeds.py <build/mayhem/gen/msg_dispatch.inc>   (the message table order is the fuzz_mavlink_msg index)
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# name: (msgid, crc_extra, struct fmt, sample values)
MSGS = {
    "HEARTBEAT": (0, 50, "<IBBBBB", (0, 2, 3, 0x81, 4, 3)),
    "SYS_STATUS": (1, 124, "<IIIHHhHHHHHHb", (0x1, 0x1, 0x1, 500, 11100, 1500, 7000, 0, 0, 0, 0, 0, 87)),
    "SYSTEM_TIME": (2, 137, "<QI", (1700000000000000, 123456)),
    "PING": (4, 237, "<QIBB", (1234567890, 7, 1, 1)),
    "PARAM_VALUE": (22, 220, "<fHH16sB", (1.5, 800, 12, b"SYSID_THISMAV", 9)),
    "GPS_RAW_INT": (24, 24, "<QiiiHHHHBB", (1000, 473977418, 85455939, 488000, 100, 100, 0, 0, 3, 10)),
    "ATTITUDE": (30, 39, "<I6f", (5000, 0.1, -0.2, 1.5, 0.0, 0.01, -0.01)),
    "GLOBAL_POSITION_INT": (33, 104, "<I4i3hH", (5000, 473977418, 85455939, 488000, 20000, 1, -2, 3, 9000)),
    "COMMAND_LONG": (76, 152, "<7fHBBB", (1, 0, 0, 0, 0, 0, 0, 400, 1, 1, 0)),
    "STATUSTEXT": (253, 83, "<B50s", (6, b"PreArm: Compass not calibrated")),
}


def crc_acc(crc, b):
    tmp = b ^ (crc & 0xFF)
    tmp = (tmp ^ (tmp << 4)) & 0xFF
    return ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xFFFF


def crc(data, extra):
    c = 0xFFFF
    for b in data + bytes([extra]):
        c = crc_acc(c, b)
    return c


def frame_v2(name, seq=0, sysid=1, compid=1, signed=False):
    mid, extra, fmt, vals = MSGS[name]
    payload = struct.pack(fmt, *vals).rstrip(b"\0") or b"\0"
    incompat = 1 if signed else 0
    hdr = bytes([len(payload), incompat, 0, seq, sysid, compid]) + mid.to_bytes(3, "little")
    c = crc(hdr + payload, extra)
    out = b"\xfd" + hdr + payload + struct.pack("<H", c)
    if signed:
        out += bytes([0]) + (1000).to_bytes(6, "little") + bytes(6)
    return out


def frame_v1(name, seq=0, sysid=1, compid=1):
    mid, extra, fmt, vals = MSGS[name]
    if mid > 255:
        raise ValueError(name)
    payload = struct.pack(fmt, *vals)
    hdr = bytes([len(payload), seq, sysid, compid, mid])
    return b"\xfe" + hdr + payload + struct.pack("<H", crc(hdr + payload, extra))


def write(d, name, data):
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)


def main():
    inc = [l.strip() for l in open(sys.argv[1]) if l.strip()]
    parse_dir = os.path.join(HERE, "fuzz_mavconn_parse", "testsuite")
    msg_dir = os.path.join(HERE, "fuzz_mavlink_msg", "testsuite")

    for name in MSGS:
        write(parse_dir, f"v2_{name.lower()}", b"\x00" + frame_v2(name))
        if MSGS[name][0] < 256:
            write(parse_dir, f"v1_{name.lower()}", b"\x04" + frame_v1(name))
    stream = b"".join(frame_v2(n, seq=i) for i, n in enumerate(MSGS))
    write(parse_dir, "v2_stream_all", b"\x00" + stream)
    write(parse_dir, "v2_noise_prefix", b"\x00" + b"\x01\x02\xfd\xfe\x00" + frame_v2("HEARTBEAT") + b"\xfd\xff")
    write(parse_dir, "v1_v2_mixed", b"\x00" + frame_v1("ATTITUDE") + frame_v2("COMMAND_LONG"))
    write(parse_dir, "signed_unsigned_ok", b"\x03" + frame_v2("HEARTBEAT") + frame_v2("ATTITUDE", signed=True))
    write(parse_dir, "signed_only", b"\x01" + frame_v2("PING", signed=True) + frame_v2("PING"))
    write(parse_dir, "v1_out_v2_in", b"\x05" + frame_v2("STATUSTEXT"))

    rnd = random.Random(1)
    for idx, line in enumerate(inc):
        msg = line.split(", ")[1].rstrip(")")
        payload = rnd.randbytes(rnd.choice([8, 16, 33, 60]))
        write(msg_dir, f"{idx:03d}_{msg.lower()}", struct.pack("<H", idx) + payload)
    for name, (mid, extra, fmt, vals) in MSGS.items():
        for idx, line in enumerate(inc):
            if line.endswith(", " + name + ")") and line.startswith(("X(common", "X(minimal")):
                write(msg_dir, f"valid_{name.lower()}", struct.pack("<H", idx) + struct.pack(fmt, *vals))


if __name__ == "__main__":
    main()
