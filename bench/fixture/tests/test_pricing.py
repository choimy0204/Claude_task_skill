import unittest
from decimal import Decimal as D

from orderdesk.models import Customer, LineItem, Order
from orderdesk.pricing import InvalidCoupon, price_order

from tests import helpers


def order(*lines, coupon=None):
    cat = helpers.catalog()
    return Order("O-1", "C1", [LineItem(sku, qty, cat.get(sku).price) for sku, qty in lines], "2026-09-14T10:00:00", coupon=coupon)


class PricingTest(unittest.TestCase):
    def setUp(self):
        self.cat = helpers.catalog()
        self.basic = Customer("C1", "Kim", "basic", "seoul")

    def test_simple_order_with_tax_and_shipping(self):
        bd = price_order(order(("MUG-01", 2)), self.basic, self.cat)
        self.assertEqual(bd.subtotal, D("24.00"))
        self.assertEqual(bd.tax, D("2.40"))
        self.assertEqual(bd.shipping, D("3.00"))
        self.assertEqual(bd.total, D("29.40"))

    def test_category_promotion(self):
        bd = price_order(order(("NOTE-01", 2)), self.basic, self.cat)
        self.assertEqual(bd.discount_total, D("1.20"))
        self.assertEqual(bd.total, D("14.88"))

    def test_bulk_discount_applies_at_threshold(self):
        # 같은 상품 10개(BULK_THRESHOLD)부터 대량 할인 3%
        bd = price_order(order(("MUG-01", 10)), self.basic, self.cat)
        self.assertEqual(bd.discount_total, D("3.60"))
        self.assertEqual(bd.total, D("133.04"))

    def test_bulk_discount_above_threshold(self):
        bd = price_order(order(("MUG-01", 11)), self.basic, self.cat)
        self.assertEqual(bd.discount_total, D("3.96"))

    def test_gold_tier_free_shipping(self):
        gold = Customer("C2", "Lee", "gold", "busan")
        bd = price_order(order(("LAMP-01", 3)), gold, self.cat)
        self.assertEqual(bd.discount_total, D("7.50"))
        self.assertEqual(bd.shipping, D("0.00"))
        self.assertEqual(bd.total, D("156.75"))

    def test_coupon(self):
        bd = price_order(order(("MUG-01", 1), coupon="WELCOME5"), self.basic, self.cat)
        self.assertEqual(bd.discount_total, D("5.00"))
        with self.assertRaises(InvalidCoupon):
            price_order(order(("MUG-01", 1), coupon="NOPE"), self.basic, self.cat)
