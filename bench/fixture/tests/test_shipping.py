import unittest
from decimal import Decimal as D

from orderdesk.models import Customer, LineItem, Order
from orderdesk.shipping import shipping_cost

from tests import helpers


class ShippingTest(unittest.TestCase):
    def setUp(self):
        self.cat = helpers.catalog()

    def _order(self, sku, qty):
        return Order("O-1", "C1", [LineItem(sku, qty, self.cat.get(sku).price)], "2026-09-14T10:00:00")

    def test_minimum_one_kg(self):
        c = Customer("C1", "Kim", "basic", "seoul")
        self.assertEqual(shipping_cost(self._order("PEN-01", 3), c, self.cat, D("7.50")), D("3.00"))

    def test_weight_rounds_up(self):
        c = Customer("C4", "Choi", "basic", "overseas")
        # 7.5kg -> 8kg: 15 + 4*7
        self.assertEqual(shipping_cost(self._order("CHAIR-01", 1), c, self.cat, D("120")), D("43.00"))

    def test_vip_always_free(self):
        c = Customer("C3", "Park", "vip", "jeju")
        self.assertEqual(shipping_cost(self._order("CHAIR-01", 1), c, self.cat, D("1")), D("0.00"))
