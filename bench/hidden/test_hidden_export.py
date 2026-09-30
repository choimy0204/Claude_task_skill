# B4 3번 주제(기능 추가) 채점용. CSV 내보내기.
import json
import os
import shutil
import tempfile
import unittest
from datetime import datetime

from orderdesk import cli
from orderdesk.reports import export_daily_csv
from orderdesk.storage import JsonOrderRepository

from tests import helpers

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
EXPECTED = [
    "order_id,customer_id,status,units,total",
    "O-1001,C1,paid,2,29.40",
    "O-1002,C2,shipped,3,156.75",
]


def build(path):
    svc, _ = helpers.service(path)
    a = svc.create_order("C1", {"MUG-01": 2}, now=datetime(2026, 9, 14, 9))
    b = svc.create_order("C2", {"LAMP-01": 3}, now=datetime(2026, 9, 14, 10))
    c = svc.create_order("C1", {"PEN-01": 1}, now=datetime(2026, 9, 14, 11))
    d = svc.create_order("C1", {"PEN-01": 1}, now=datetime(2026, 9, 15, 9))
    svc.pay(a.id)
    svc.pay(b.id)
    svc.ship(b.id)
    svc.pay(d.id)
    svc.cancel(c.id)
    return svc


def read_lines(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read().splitlines()


class HiddenExportTest(unittest.TestCase):
    def test_export_function(self):
        with tempfile.TemporaryDirectory() as d:
            svc = build(None)
            out = os.path.join(d, "x.csv")
            n = export_daily_csv(svc.repo, "2026-09-14", out)
            self.assertEqual(n, 2)
            self.assertEqual(read_lines(out), EXPECTED)

    def test_export_empty_day(self):
        with tempfile.TemporaryDirectory() as d:
            svc = build(None)
            out = os.path.join(d, "x.csv")
            self.assertEqual(export_daily_csv(svc.repo, "2026-01-01", out), 0)
            self.assertEqual(read_lines(out), EXPECTED[:1])

    def test_cli_export(self):
        with tempfile.TemporaryDirectory() as d:
            data = os.path.join(d, "data")
            shutil.copytree(DATA, data)
            # 카탈로그·고객은 테스트 도우미와 같은 값으로 맞춘다
            build(os.path.join(data, "orders.json"))
            out = os.path.join(d, "out.csv")
            rc = cli.main(["--data", data, "export", "--date", "2026-09-14", "--out", out])
            self.assertIn(rc, (0, None))
            self.assertEqual(read_lines(out), EXPECTED)


if __name__ == "__main__":
    unittest.main()
