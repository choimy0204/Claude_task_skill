# B3 채점용 (모델에게 보이지 않음). 실행 폴더의 tests/ 에 복사해 돌린다.
import os
import tempfile
import unittest
from datetime import datetime
from decimal import Decimal as D

from orderdesk.events import EventBus
from orderdesk.inventory import Inventory
from orderdesk.models import OrderStatus
from orderdesk.service import OrderError, OrderService
from orderdesk.storage import JsonOrderRepository

from tests import helpers

NOW = datetime(2026, 9, 14, 10, 0, 0)


def shipped(svc, cid, lines):
    o = svc.create_order(cid, lines, now=NOW)
    svc.pay(o.id)
    svc.ship(o.id)
    return o.id


def status(svc, oid):
    return svc.repo.get(oid).status.value


class HiddenReturnsTest(unittest.TestCase):
    def test_partial_then_full_return(self):
        svc, audit = helpers.service()
        oid = shipped(svc, "C1", {"MUG-01": 2})
        self.assertEqual(D(str(svc.return_items(oid, {"MUG-01": 1}))), D("13.20"))
        self.assertEqual(status(svc, oid), "partially_returned")
        self.assertEqual(svc.inventory.on_hand("MUG-01"), 49)
        self.assertEqual(D(str(svc.return_items(oid, {"MUG-01": 1}))), D("13.20"))
        self.assertEqual(status(svc, oid), "returned")
        self.assertEqual(svc.inventory.on_hand("MUG-01"), 50)
        with self.assertRaises(OrderError):
            svc.return_items(oid, {"MUG-01": 1})

    def test_event(self):
        svc, audit = helpers.service()
        oid = shipped(svc, "C1", {"MUG-01": 2})
        svc.return_items(oid, {"MUG-01": 1})
        ev = [p for n, p in audit.entries if n == "order.returned"]
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["order_id"], oid)
        self.assertEqual(D(str(ev[0]["refund"])), D("13.20"))

    def test_tier_discount_ratio(self):
        svc, _ = helpers.service()
        oid = shipped(svc, "C2", {"LAMP-01": 2})
        self.assertEqual(D(str(svc.return_items(oid, {"LAMP-01": 1}))), D("52.25"))

    def test_promo_and_vip_ratio(self):
        svc, _ = helpers.service()
        oid = shipped(svc, "C3", {"NOTE-01": 4})
        self.assertEqual(D(str(svc.return_items(oid, {"NOTE-01": 1}))), D("5.20"))

    def test_invalid_requests_change_nothing(self):
        svc, _ = helpers.service()
        o = svc.create_order("C1", {"MUG-01": 2}, now=NOW)
        svc.pay(o.id)
        with self.assertRaises(OrderError):
            svc.return_items(o.id, {"MUG-01": 1})  # 출고 전
        svc.ship(o.id)
        for bad in ({"PEN-01": 1}, {"MUG-01": 0}, {"MUG-01": 3}):
            with self.assertRaises(OrderError):
                svc.return_items(o.id, bad)
        self.assertEqual(status(svc, o.id), "shipped")
        self.assertEqual(svc.inventory.on_hand("MUG-01"), 48)

    def test_status_enum(self):
        self.assertEqual(OrderStatus("returned").value, "returned")
        self.assertEqual(OrderStatus("partially_returned").value, "partially_returned")

    def test_persisted_returns(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "orders.json")
            svc, _ = helpers.service(path)
            oid = shipped(svc, "C1", {"MUG-01": 2})
            svc.return_items(oid, {"MUG-01": 1})
            svc2 = OrderService(helpers.catalog(), Inventory(helpers.stock()), JsonOrderRepository(path),
                                helpers.customers(), EventBus())
            self.assertEqual(status(svc2, oid), "partially_returned")
            with self.assertRaises(OrderError):
                svc2.return_items(oid, {"MUG-01": 2})
            self.assertEqual(D(str(svc2.return_items(oid, {"MUG-01": 1}))), D("13.20"))
            self.assertEqual(status(svc2, oid), "returned")


if __name__ == "__main__":
    unittest.main()
