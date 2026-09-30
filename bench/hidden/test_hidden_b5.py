# B5(나눌 수 있는 큰 구현) 채점용. 모듈 4개.
import os
import tempfile
import unittest
from datetime import datetime
from decimal import Decimal as D

from tests import helpers


class HiddenCouponTest(unittest.TestCase):
    def test_normalize(self):
        from orderdesk.coupons import InvalidCoupon, normalize_code
        self.assertEqual(normalize_code("  welcome5 "), "WELCOME5")
        with self.assertRaises(InvalidCoupon):
            normalize_code("NOPE")
        self.assertTrue(issubclass(InvalidCoupon, ValueError))

    def test_discount(self):
        from orderdesk.coupons import coupon_discount
        self.assertEqual(coupon_discount("WELCOME5", D("30.00")), D("5.00"))
        self.assertEqual(coupon_discount("welcome5", D("3.20")), D("3.20"))
        self.assertEqual(coupon_discount("SPRING10", D("33.35")), D("3.34"))
        self.assertEqual(coupon_discount("SPRING10", D("0")), D("0.00"))


CSV = """order_ref,customer_id,sku,qty
R1,C1,MUG-01,2
R2,C2,LAMP-01,1
R1,C1,MUG-01,1
R3,C9,PEN-01,1
R4,C1,PEN-01,x
R5,C1,NOPE-01,1
R6,C1,CHAIR-01,6
R7,C3,TEA-01,3
R8,C1,PEN-01,1
R8,C2,PEN-01,1
"""


class HiddenImporterTest(unittest.TestCase):
    def test_import(self):
        from orderdesk.importer import import_orders_csv
        svc, _ = helpers.service()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "in.csv")
            with open(p, "w", encoding="utf-8", newline="") as f:
                f.write(CSV)
            res = import_orders_csv(p, svc, now=datetime(2026, 9, 14, 9))
        self.assertEqual(len(res.created), 3)
        orders = [svc.repo.get(i) for i in res.created]
        self.assertEqual([(o.customer_id, {i.sku: i.qty for i in o.items}) for o in orders],
                         [("C1", {"MUG-01": 3}), ("C2", {"LAMP-01": 1}), ("C3", {"TEA-01": 3})])
        self.assertEqual(sorted(r for r, _ in res.errors), ["R3", "R4", "R5", "R6", "R8"])
        self.assertTrue(all(m for _, m in res.errors))
        self.assertEqual(svc.inventory.reserved("CHAIR-01"), 0)
        self.assertEqual(svc.inventory.reserved("PEN-01"), 0)
        self.assertEqual(svc.inventory.reserved("MUG-01"), 3)


class HiddenWeeklyTest(unittest.TestCase):
    def build(self):
        svc, _ = helpers.service()
        a = svc.create_order("C1", {"MUG-01": 2}, now=datetime(2026, 9, 14, 9))
        b = svc.create_order("C2", {"LAMP-01": 3}, now=datetime(2026, 9, 16, 10))
        svc.create_order("C1", {"PEN-01": 1}, now=datetime(2026, 9, 16, 11))
        c = svc.create_order("C1", {"PEN-01": 1}, now=datetime(2026, 9, 21, 9))
        svc.pay(a.id)
        svc.pay(b.id)
        svc.ship(b.id)
        svc.pay(c.id)
        return svc

    def test_summary(self):
        from orderdesk.weekly import weekly_summary
        s = weekly_summary(self.build().repo, "2026-09-14")
        self.assertEqual(s["start"], "2026-09-14")
        self.assertEqual([d["day"] for d in s["days"]], [f"2026-09-{n}" for n in range(14, 21)])
        self.assertEqual([d["orders"] for d in s["days"]], [1, 0, 2, 0, 0, 0, 0])
        self.assertEqual(s["days"][0]["revenue"], D("29.40"))
        self.assertEqual(s["days"][2]["revenue"], D("156.75"))
        self.assertEqual(s["total_revenue"], D("186.15"))
        self.assertEqual(s["best_day"], "2026-09-16")

    def test_empty_and_format(self):
        from orderdesk.weekly import format_weekly, weekly_summary
        svc = self.build()
        e = weekly_summary(svc.repo, "2026-01-01")
        self.assertIsNone(e["best_day"])
        self.assertEqual(e["total_revenue"], D("0"))
        lines = format_weekly(weekly_summary(svc.repo, "2026-09-14")).splitlines()
        self.assertEqual(lines[0], "week of 2026-09-14")
        self.assertEqual(lines[1], "2026-09-14   1      29.40")
        self.assertEqual(lines[3], "2026-09-16   2     156.75")
        self.assertEqual(lines[-1], "total 186.15")
        self.assertEqual(len(lines), 9)


class HiddenStockAlertTest(unittest.TestCase):
    def test_low_stock_and_plan(self):
        from orderdesk.inventory import Inventory
        from orderdesk.stock_alerts import low_stock, reorder_plan
        inv = Inventory({"A": 3, "B": 12, "C": 9, "D": 30})
        inv._reserved["B"] = 4  # 가용 8
        skus = ["A", "B", "C", "D", "E"]
        self.assertEqual(low_stock(inv, skus),
                         [("E", 0, 10), ("A", 3, 10), ("B", 8, 10), ("C", 9, 10)])
        self.assertEqual(low_stock(inv, skus, thresholds={"C": 5, "D": 40}, default=4),
                         [("E", 0, 4), ("A", 3, 4), ("D", 30, 40)])
        self.assertEqual(reorder_plan(inv, skus, target=20),
                         {"E": 20, "A": 17, "B": 12, "C": 11})


if __name__ == "__main__":
    unittest.main()
