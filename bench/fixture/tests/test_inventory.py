import unittest

from orderdesk.inventory import Inventory, OutOfStock
from orderdesk.models import LineItem, Order


def order(**lines):
    return Order("O-1", "C1", [LineItem(s, q, 0) for s, q in lines.items()], "2026-09-14T10:00:00")


class InventoryTest(unittest.TestCase):
    def test_reserve_and_release(self):
        inv = Inventory({"A": 5})
        o = order(A=3)
        inv.reserve(o)
        self.assertEqual(inv.available("A"), 2)
        inv.release(o)
        self.assertEqual(inv.available("A"), 5)

    def test_reserve_is_all_or_nothing(self):
        inv = Inventory({"A": 5, "B": 1})
        with self.assertRaises(OutOfStock):
            inv.reserve(order(A=2, B=2))
        self.assertEqual(inv.available("A"), 5)

    def test_commit(self):
        inv = Inventory({"A": 5})
        o = order(A=2)
        inv.reserve(o)
        inv.commit(o)
        self.assertEqual((inv.on_hand("A"), inv.reserved("A")), (3, 0))
