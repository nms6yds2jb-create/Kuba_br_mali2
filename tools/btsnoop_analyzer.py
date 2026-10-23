#!/usr/bin/env python3
"""Analisa capturas Bluetooth (btsnoop_hci.log) e lista as escritas/notificações BLE (ATT).

Serve para descobrir o protocolo de um fone: capture o tráfego enquanto muda o modo
de ruído, o EQ etc. (com o app oficial no Android, ou o PacketLogger no Mac com o
iPhone), e depois rode:

    python3 tools/btsnoop_analyzer.py captura.log
    python3 tools/btsnoop_analyzer.py captura.log --diff          # o que muda entre comandos
    python3 tools/btsnoop_analyzer.py captura.log --handle 0x0012 --json

Só usa a biblioteca padrão do Python.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from dataclasses import dataclass, asdict
from typing import BinaryIO, Iterator

BTSNOOP_MAGIC = b"btsnoop\x00"
# Diferença entre a época do btsnoop (ano 0) e a época Unix, em microssegundos.
BTSNOOP_EPOCH_DELTA = 0x00DCDDB30F2F8000

ATT_OPS = {
    0x0A: "read_req",
    0x0B: "read_rsp",
    0x12: "write_req",
    0x13: "write_rsp",
    0x52: "write_cmd",
    0x1B: "notify",
    0x1D: "indicate",
    0x01: "error",
}
# Operações que carregam [handle(2)] + valor.
ATT_WITH_HANDLE = {0x0A, 0x12, 0x52, 0x1B, 0x1D}


@dataclass
class AttPacket:
    index: int
    time_us: int
    direction: str  # "app->fone" ou "fone->app"
    op: str
    handle: int | None
    value: bytes

    def to_dict(self) -> dict:
        d = asdict(self)
        d["value"] = self.value.hex(" ").upper()
        d["handle"] = None if self.handle is None else f"0x{self.handle:04X}"
        return d


class BtsnoopError(Exception):
    pass


def read_records(f: BinaryIO) -> Iterator[tuple[int, int, int, bytes]]:
    """Gera (datalink, flags, tempo_us, dados) para cada registro."""
    header = f.read(16)
    if len(header) < 16 or header[:8] != BTSNOOP_MAGIC:
        raise BtsnoopError("não é um arquivo btsnoop")
    version, datalink = struct.unpack(">II", header[8:16])
    if version != 1:
        raise BtsnoopError(f"versão btsnoop {version} não suportada")
    while True:
        rec = f.read(24)
        if len(rec) < 24:
            return
        _orig, incl, flags, _drops, ts = struct.unpack(">IIIIq", rec)
        data = f.read(incl)
        if len(data) < incl:
            return
        yield datalink, flags, ts - BTSNOOP_EPOCH_DELTA, data


def iter_att(path: str) -> Iterator[AttPacket]:
    """Remonta ACL/L2CAP e extrai pacotes ATT (canal 0x0004)."""
    partial: dict[int, bytearray] = {}
    expected: dict[int, int] = {}
    index = 0
    with open(path, "rb") as f:
        for datalink, flags, ts, data in read_records(f):
            if datalink == 1002:  # H4: primeiro byte é o tipo
                if not data or data[0] != 0x02:
                    continue
                acl = data[1:]
            elif datalink == 1001:  # HCI sem cabeçalho H4
                if flags & 0x02:  # comando/evento
                    continue
                acl = data
            else:
                raise BtsnoopError(f"tipo de captura {datalink} não suportado")
            if len(acl) < 4:
                continue
            hdr, length = struct.unpack("<HH", acl[:4])
            conn = hdr & 0x0FFF
            pb = (hdr >> 12) & 0x3
            payload = acl[4 : 4 + length]
            if pb in (0x0, 0x2):  # início de um pacote L2CAP
                if len(payload) < 4:
                    continue
                l2len = struct.unpack("<H", payload[:2])[0]
                partial[conn] = bytearray(payload)
                expected[conn] = l2len + 4
            elif pb == 0x1 and conn in partial:  # continuação
                partial[conn] += payload
            else:
                continue
            buf = partial[conn]
            if len(buf) < expected[conn]:
                continue
            del partial[conn]
            l2len, cid = struct.unpack("<HH", buf[:4])
            if cid != 0x0004:
                continue
            att = bytes(buf[4 : 4 + l2len])
            if not att:
                continue
            op = att[0]
            handle = struct.unpack("<H", att[1:3])[0] if op in ATT_WITH_HANDLE and len(att) >= 3 else None
            value = att[3:] if handle is not None else att[1:]
            direction = "fone->app" if flags & 0x01 else "app->fone"
            yield AttPacket(index, ts, direction, ATT_OPS.get(op, f"op_0x{op:02X}"), handle, value)
            index += 1


def diff_columns(values: list[bytes]) -> str:
    """Mostra os bytes que variam entre pacotes do mesmo handle (.. = sempre igual)."""
    if not values:
        return ""
    width = max(len(v) for v in values)
    fixed = []
    for i in range(width):
        column = {v[i] if i < len(v) else None for v in values}
        fixed.append(len(column) == 1)
    lines = []
    for v in values:
        cells = []
        for i in range(width):
            if i >= len(v):
                cells.append("  ")
            else:
                cells.append(".." if fixed[i] else f"{v[i]:02X}")
        lines.append(" ".join(cells))
    template = " ".join(f"{values[0][i]:02X}" if fixed[i] and i < len(values[0]) else "??" for i in range(width))
    return "modelo: " + template + "\n" + "\n".join("        " + line for line in lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("arquivo", help="captura btsnoop_hci.log")
    ap.add_argument("--handle", help="mostrar só este handle (ex.: 0x0012)")
    ap.add_argument("--op", help="mostrar só esta operação (write_cmd, notify...)")
    ap.add_argument("--diff", action="store_true", help="agrupar por handle e destacar bytes que mudam")
    ap.add_argument("--json", action="store_true", help="saída em JSON")
    args = ap.parse_args(argv)

    try:
        packets = list(iter_att(args.arquivo))
    except (OSError, BtsnoopError) as e:
        print(f"erro: {e}", file=sys.stderr)
        return 1

    if args.handle:
        wanted = int(args.handle, 0)
        packets = [p for p in packets if p.handle == wanted]
    if args.op:
        packets = [p for p in packets if p.op == args.op]

    if args.json:
        json.dump([p.to_dict() for p in packets], sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0

    if args.diff:
        groups: dict[tuple[str, int | None, str], list[bytes]] = {}
        for p in packets:
            if p.op in ("write_cmd", "write_req", "notify", "indicate"):
                groups.setdefault((p.direction, p.handle, p.op), []).append(p.value)
        for (direction, handle, op), values in sorted(groups.items(), key=lambda kv: (kv[0][1] or 0, kv[0][0])):
            h = "-" if handle is None else f"0x{handle:04X}"
            print(f"\n== {direction} handle {h} {op}: {len(values)} pacotes")
            print(diff_columns(values))
        return 0

    start = packets[0].time_us if packets else 0
    for p in packets:
        h = "     -" if p.handle is None else f"0x{p.handle:04X}"
        t = (p.time_us - start) / 1e6
        print(f"{p.index:5d} {t:9.3f}s {p.direction:9s} {p.op:10s} {h}  {p.value.hex(' ').upper()}")
    print(f"\n{len(packets)} pacotes ATT", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
