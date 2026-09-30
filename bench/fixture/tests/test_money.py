import unittest
from decimal import Decimal

from orderdesk.money import fmt, split_evenly, to_money


class MoneyTest(unittest.TestCase):
    def test_to_money_rounds_half_up(self):
        self.assertEqual(to_money("2.675"), Decimal("2.68"))
        self.assertEqual(to_money(1.005), Decimal("1.01"))

    def test_split_evenly(self):
        self.assertEqual(split_evenly("10.00", 3), [Decimal("3.34"), Decimal("3.33"), Decimal("3.33")])
        with self.assertRaises(ValueError):
            split_evenly("1", 0)

    def test_fmt(self):
        self.assertEqual(fmt(Decimal("1234.5")), "1,234.50")
