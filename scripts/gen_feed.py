#!/usr/bin/env python3
"""Synthetic NASDAQ ITCH 5.0 market-data feed + golden order-book model.

Builds a realistic order flow for 4 tracked instruments (stock-locate 1..4) plus
noise (untracked instruments, other ITCH message types, frames for other UDP
ports, ARP), packs it into Ethernet/IPv4/UDP/MoldUDP64 frames, and computes the
expected best-bid/offer updates with a plain-Python order book.

Outputs (in <outdir>)
  beats.txt   one 64-bit AXI-Stream beat per line: tdata tkeep tlast
  bbo.txt     expected BBO updates:  msg_idx locate side price qty
  msgend.txt  msg_idx -> index of the beat carrying the message's last byte
"""
import random
import struct
import sys

UDP_PORT = 26400
NSYM, NLVL, TBITS = 4, 16, 10
TICK = 100                      # $0.01 in ITCH price units (1e-4 $)


def itch(ty, locate, body):
    ts = random.getrandbits(48)
    return ty.encode() + struct.pack(">HH", locate, random.getrandbits(16)) + ts.to_bytes(6, "big") + body


def frame(payload_msgs, seq, port=UDP_PORT):
    mold = b"SESSION001" + struct.pack(">QH", seq, len(payload_msgs))
    body = mold + b"".join(struct.pack(">H", len(m)) + m for m in payload_msgs)
    udp = struct.pack(">HHHH", 40000, port, 8 + len(body), 0) + body
    ip_len = 20 + len(udp)
    ip = struct.pack(">BBHHHBBH4s4s", 0x45, 0, ip_len, random.getrandbits(16), 0x4000, 64, 17, 0,
                     bytes([10, 0, 0, 1]), bytes([233, 54, 12, 111]))
    csum = sum(struct.unpack(">10H", ip))
    csum = (csum & 0xFFFF) + (csum >> 16)
    ip = ip[:10] + struct.pack(">H", ~csum & 0xFFFF) + ip[12:]
    eth = bytes([0x01, 0x00, 0x5E, 0x36, 0x0C, 0x6F]) + bytes([0x02, 0, 0, 0, 0, 1]) + b"\x08\x00"
    return eth + ip + udp


class Model:
    def __init__(self):
        self.orders = {}                 # ref -> [book, price, qty]
        self.books = [dict() for _ in range(2 * NSYM)]
        self.bbo_out = []

    def top(self, b):
        lv = self.books[b]
        if not lv:
            return (0, 0)
        p = (min if b & 1 else max)(lv)
        return (p, lv[p])

    def level(self, b, price, delta, idx):
        before = self.top(b)
        lv = self.books[b]
        lv[price] = lv.get(price, 0) + delta
        assert lv[price] >= 0
        if lv[price] == 0:
            del lv[price]
        assert len(lv) <= NLVL
        after = self.top(b)
        if after != before:
            self.bbo_out.append((idx, b // 2 + 1, b & 1, after[0], after[1]))


def main(outdir, n_msgs=40000, seed=1):
    random.seed(seed)
    m = Model()
    base = [1_000_000 + 250_000 * s for s in range(NSYM)]
    next_ref = 1000
    live_slots = set()                # order-table slots used by live tracked orders

    def new_ref():
        nonlocal next_ref
        while True:
            next_ref += random.randrange(1, 40)
            if (next_ref & ((1 << TBITS) - 1)) not in live_slots:
                return next_ref

    def rand_price(sym, side):
        k = random.randrange(1, NLVL + 1)
        return base[sym] - k * TICK if side == 0 else base[sym] + k * TICK

    msgs = []                          # (bytes, model-callback or None)
    for _ in range(n_msgs):
        r = random.random()
        live = list(m.orders)
        if r < 0.32 and len(live) >= 300:     # keep the resting book bounded (and the order table sparse)
            r = 0.60                          # -> delete instead of add
        if r < 0.32 or len(live) < 20:
            sym, side = random.randrange(NSYM), random.randrange(2)
            ref, px, qty = new_ref(), rand_price(sym, side), random.choice([100, 200, 300, 500, 1000, random.randrange(1, 5000)])
            body = struct.pack(">Q", ref) + (b"S" if side else b"B") + struct.pack(">I", qty) + b"SYM%d    " % sym + struct.pack(">I", px)
            msgs.append((itch("A", sym + 1, body), ("A", ref, 2 * sym + side, px, qty)))
            live_slots.add(ref & ((1 << TBITS) - 1))
            m.orders[ref] = [2 * sym + side, px, qty]       # tentatively, replayed in order below
        elif r < 0.47:
            ref = random.choice(live)
            q = random.randrange(1, m.orders[ref][2] + 1)
            body = struct.pack(">QIQ", ref, q, random.getrandbits(64))
            msgs.append((itch("E", m.orders[ref][0] // 2 + 1, body), ("R", ref, q)))
            m.orders[ref][2] -= q
            if m.orders[ref][2] == 0:
                del m.orders[ref]; live_slots.discard(ref & ((1 << TBITS) - 1))
        elif r < 0.57:
            ref = random.choice(live)
            q = random.randrange(1, m.orders[ref][2] + 1)
            msgs.append((itch("X", m.orders[ref][0] // 2 + 1, struct.pack(">QI", ref, q)), ("R", ref, q)))
            m.orders[ref][2] -= q
            if m.orders[ref][2] == 0:
                del m.orders[ref]; live_slots.discard(ref & ((1 << TBITS) - 1))
        elif r < 0.70:
            ref = random.choice(live)
            msgs.append((itch("D", m.orders[ref][0] // 2 + 1, struct.pack(">Q", ref)), ("D", ref)))
            del m.orders[ref]; live_slots.discard(ref & ((1 << TBITS) - 1))
        elif r < 0.80:
            ref = random.choice(live)
            b = m.orders[ref][0]
            live_slots.discard(ref & ((1 << TBITS) - 1))
            nref, px, qty = new_ref(), rand_price(b // 2, b & 1), random.randrange(1, 3000)
            live_slots.add(nref & ((1 << TBITS) - 1))
            msgs.append((itch("U", b // 2 + 1, struct.pack(">QQII", ref, nref, qty, px)), ("U", ref, nref, px, qty)))
            del m.orders[ref]
            m.orders[nref] = [b, px, qty]
        elif r < 0.90:                                      # untracked instrument: must be ignored
            body = struct.pack(">Q", random.getrandbits(40)) + b"B" + struct.pack(">I", 100) + b"OTHER   " + struct.pack(">I", 12345)
            msgs.append((itch("A", random.randrange(NSYM + 1, 9000), body), None))
        elif r < 0.95:                                      # executes / deletes for unknown refs
            unknown = random.getrandbits(62) | 1 << 62
            if random.random() < 0.5:
                msgs.append((itch("E", random.randrange(1, 9000), struct.pack(">QIQ", unknown, 10, 0)), None))
            else:
                msgs.append((itch("D", random.randrange(1, 9000), struct.pack(">Q", unknown)), None))
        else:                                               # other message types, various lengths
            ty, ln = random.choice([("S", 12), ("H", 25), ("R", 39), ("P", 44), ("Q", 40), ("I", 50)])
            msgs.append((itch(ty, random.randrange(0, 9000), bytes(random.getrandbits(8) for _ in range(ln - 11))), None))

    # replay against a fresh model in message order to produce expected BBOs
    m = Model()
    for idx, (_, op) in enumerate(msgs):
        if op is None:
            continue
        if op[0] == "A":
            _, ref, b, px, qty = op
            m.orders[ref] = [b, px, qty]
            m.level(b, px, qty, idx)
        elif op[0] == "R":
            _, ref, q = op
            b, px, _ = m.orders[ref]
            m.orders[ref][2] -= q
            if m.orders[ref][2] == 0:
                del m.orders[ref]
            m.level(b, px, -q, idx)
        elif op[0] == "D":
            b, px, qty = m.orders.pop(op[1])
            m.level(b, px, -qty, idx)
        else:
            _, ref, nref, px, qty = op
            b, opx, oqty = m.orders.pop(ref)
            m.level(b, opx, -oqty, idx)
            m.orders[nref] = [b, px, qty]
            m.level(b, px, qty, idx)

    # pack into frames, with noise frames in between
    beats, msgend = [], []
    seq, i, idx = 1, 0, 0

    def emit(data, record=None):
        start = len(beats)
        for o in range(0, len(data), 8):
            chunk = data[o:o + 8]
            word = int.from_bytes(chunk.ljust(8, b"\0"), "little")
            beats.append((word, (1 << len(chunk)) - 1, int(o + 8 >= len(data))))
        if record:
            for msg_idx, end_byte in record:
                msgend.append((msg_idx, start + end_byte // 8))

    while i < len(msgs):
        k = random.choice([1, 2, 3, 5, 8, 12, 20, 30])
        group = [mm for mm, _ in msgs[i:i + k]]
        f = frame(group, seq)
        pos, rec = 62, []
        for g in group:
            pos += 2 + len(g)
            rec.append((idx, pos - 1))
            idx += 1
        emit(f, rec)
        seq += len(group)
        i += len(group)
        r = random.random()
        if r < 0.05:                                       # same feed format, other port: drop
            emit(frame([itch("A", 1, bytes(25))], 1, port=UDP_PORT + 1))
        elif r < 0.07:                                     # ARP
            emit(bytes(12) + b"\x08\x06" + bytes(46))

    with open(f"{outdir}/beats.txt", "w") as fh:
        for w, k, l in beats:
            fh.write(f"{w:016x} {k:02x} {l}\n")
    with open(f"{outdir}/bbo.txt", "w") as fh:
        for e in m.bbo_out:
            fh.write("%d %d %d %d %d\n" % e)
    with open(f"{outdir}/msgend.txt", "w") as fh:
        for a, b in msgend:
            fh.write(f"{a} {b}\n")
    print(f"{len(msgs)} messages in {seq - 1} sequenced msgs, {len(beats)} beats, "
          f"{len(m.bbo_out)} expected BBO updates")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 40000)
