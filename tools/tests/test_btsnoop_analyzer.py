import io
import os
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import btsnoop_analyzer as bt  # noqa: E402


def att_acl(conn, att, pb=0x2):
    l2 = struct.pack("<HH", len(att), 0x0004) + att
    return struct.pack("<HH", conn | (pb << 12), len(l2)) + l2


def write_capture(path, records, datalink=1002):
    with open(path, "wb") as f:
        f.write(bt.BTSNOOP_MAGIC + struct.pack(">II", 1, datalink))
        for i, (flags, data) in enumerate(records):
            ts = bt.BTSNOOP_EPOCH_DELTA + i * 1000
            f.write(struct.pack(">IIIIq", len(data), len(data), flags, 0, ts) + data)


class AnalyzerTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "cap.log")

    def tearDown(self):
        self.dir.cleanup()

    def test_extracts_writes_and_notifications(self):
        write_cmd = bytes([0x52]) + struct.pack("<H", 0x0012) + bytes.fromhex("55AA0300010105")
        notify = bytes([0x1B]) + struct.pack("<H", 0x0015) + bytes.fromhex("55AA0300810183")
        hci_cmd = bytes([0x01, 0x03, 0x0C, 0x00])  # comando HCI deve ser ignorado
        write_capture(self.path, [
            (0x00, hci_cmd),
            (0x00, b"\x02" + att_acl(0x40, write_cmd)),
            (0x01, b"\x02" + att_acl(0x40, notify)),
        ])
        pkts = list(bt.iter_att(self.path))
        self.assertEqual(len(pkts), 2)
        self.assertEqual(pkts[0].op, "write_cmd")
        self.assertEqual(pkts[0].direction, "app->fone")
        self.assertEqual(pkts[0].handle, 0x0012)
        self.assertEqual(pkts[0].value.hex(), "55aa0300010105")
        self.assertEqual(pkts[1].op, "notify")
        self.assertEqual(pkts[1].direction, "fone->app")

    def test_reassembles_fragmented_l2cap(self):
        att = bytes([0x12]) + struct.pack("<H", 0x0020) + bytes(range(40))
        full = att_acl(0x41, att)
        # Divide em início + continuação.
        l2 = full[4:]
        first = struct.pack("<HH", 0x41 | (0x2 << 12), 20) + l2[:20]
        cont = struct.pack("<HH", 0x41 | (0x1 << 12), len(l2) - 20) + l2[20:]
        write_capture(self.path, [(0x00, b"\x02" + first), (0x00, b"\x02" + cont)])
        pkts = list(bt.iter_att(self.path))
        self.assertEqual(len(pkts), 1)
        self.assertEqual(pkts[0].value, bytes(range(40)))

    def test_datalink_1001(self):
        att = bytes([0x52]) + struct.pack("<H", 0x0012) + b"\x01"
        write_capture(self.path, [(0x02, b"\x00" * 4), (0x00, att_acl(0x40, att))], datalink=1001)
        pkts = list(bt.iter_att(self.path))
        self.assertEqual(len(pkts), 1)
        self.assertEqual(pkts[0].value, b"\x01")

    def test_rejects_other_files(self):
        with open(self.path, "wb") as f:
            f.write(b"not a capture")
        with self.assertRaises(bt.BtsnoopError):
            list(bt.iter_att(self.path))

    def test_diff_columns(self):
        out = bt.diff_columns([bytes.fromhex("55AA0300010105"), bytes.fromhex("55AA0301010207")])
        self.assertTrue(out.startswith("modelo: 55 AA 03 ?? 01 ?? ??"))

    def test_cli_diff_and_json(self):
        writes = [bytes([0x52]) + struct.pack("<H", 0x12) + bytes([0xAA, 0x01, m]) for m in (0, 1, 2)]
        write_capture(self.path, [(0x00, b"\x02" + att_acl(0x40, w)) for w in writes])
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(bt.main([self.path, "--diff"]), 0)
        self.assertIn("modelo: AA 01 ??", buf.getvalue())
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(bt.main([self.path, "--json", "--handle", "0x12"]), 0)
        self.assertIn('"value": "AA 01 02"', buf.getvalue())


if __name__ == "__main__":
    unittest.main()
