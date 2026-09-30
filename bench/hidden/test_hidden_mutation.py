# B4 2번 주제(어려운 디버깅) 채점용. 2+1 프로모션이 주문 수량을 바꾸는 버그를 고쳤는지 본다.
import unittest
from datetime import datetime
from decimal import Decimal as D

from orderdesk.reports import daily_summary

from tests import helpers

NOW = datetime(2026, 9, 14, 10, 0, 0)


class HiddenMutationTest(unittest.TestCase):
    def test_pay_keeps_quantity_and_quote_is_stable(self):
        svc, _ = helpers.service()
        o = svc.create_order("C1", {"TEA-01": 3}, now=NOW)
        self.assertEqual(svc.pay(o.id), D("20.60"))
        self.assertEqual(svc.repo.get(o.id).item("TEA-01").qty, 3)
        self.assertEqual(svc.quote(o.id).total, D("20.60"))
        self.assertEqual(svc.quote(o.id).total, D("20.60"))

    def test_cancel_after_pay_restores_stock(self):
        svc, _ = helpers.service()
        o = svc.create_order("C1", {"TEA-01": 3}, now=NOW)
        svc.pay(o.id)
        svc.cancel(o.id)
        self.assertEqual(svc.inventory.available("TEA-01"), 60)
        self.assertEqual(svc.inventory.reserved("TEA-01"), 0)

    def test_ship_moves_all_units(self):
        svc, _ = helpers.service()
        o = svc.create_order("C1", {"TEA-01": 6}, now=NOW)
        svc.pay(o.id)
        svc.ship(o.id)
        self.assertEqual(svc.inventory.on_hand("TEA-01"), 54)

    def test_report_matches_stored_totals(self):
        svc, _ = helpers.service()
        a = svc.create_order("C1", {"TEA-01": 3}, now=NOW)
        b = svc.create_order("C2", {"TEA-01": 6, "MUG-01": 1}, now=NOW)
        svc.pay(a.id)
        svc.pay(b.id)
        s = daily_summary(svc.repo, svc.customers, svc.catalog, "2026-09-14")
        self.assertEqual(s["revenue"], svc.repo.get(a.id).total + svc.repo.get(b.id).total)
        s2 = daily_summary(svc.repo, svc.customers, svc.catalog, "2026-09-14")
        self.assertEqual(s2["revenue"], s["revenue"])

    def test_bulk_counts_paid_units_only(self):
        # 2+1 에서 유료 수량(12개 중 8개)만 대량 할인 기준에 쓴다 → 8 < 10 이라 대량 할인 없음
        svc, _ = helpers.service()
        o = svc.create_order("C1", {"TEA-01": 12}, now=NOW)
        bd = svc.quote(o.id)
        self.assertEqual(bd.discount_total, D("32.00"))
        self.assertEqual(svc.quote(o.id).discount_total, D("32.00"))


if __name__ == "__main__":
    unittest.main()
