import os
import tempfile
import unittest
from datetime import datetime
from decimal import Decimal as D

from orderdesk.models import OrderStatus
from orderdesk.service import OrderError
from orderdesk.storage import JsonOrderRepository

from tests import helpers

NOW = datetime(2026, 9, 14, 10, 0, 0)


class ServiceTest(unittest.TestCase):
    def test_lifecycle(self):
        svc, audit = helpers.service()
        o = svc.create_order("C1", {"MUG-01": 2}, now=NOW)
        self.assertEqual(svc.inventory.available("MUG-01"), 48)
        self.assertEqual(svc.pay(o.id), D("29.40"))
        svc.ship(o.id)
        self.assertEqual(svc.inventory.on_hand("MUG-01"), 48)
        self.assertEqual(audit.names(), ["order.created", "order.paid", "order.shipped"])

    def test_cancel_restores_stock(self):
        svc, _ = helpers.service()
        o = svc.create_order("C2", {"LAMP-01": 2}, now=NOW)
        svc.pay(o.id)
        svc.cancel(o.id)
        self.assertEqual(svc.inventory.available("LAMP-01"), 20)
        self.assertEqual(svc.repo.get(o.id).status, OrderStatus.CANCELLED)

    def test_cannot_ship_unpaid(self):
        svc, _ = helpers.service()
        o = svc.create_order("C1", {"PEN-01": 1}, now=NOW)
        with self.assertRaises(OrderError):
            svc.ship(o.id)

    def test_persistence(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "orders.json")
            svc, _ = helpers.service(path)
            o = svc.create_order("C3", {"NOTE-01": 1}, now=NOW)
            svc.pay(o.id)
            again = JsonOrderRepository(path).get(o.id)
            self.assertEqual(again.status, OrderStatus.PAID)
            self.assertEqual(again.total, svc.repo.get(o.id).total)
