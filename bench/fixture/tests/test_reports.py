import unittest
from datetime import datetime
from decimal import Decimal as D

from orderdesk.reports import daily_summary, format_summary

from tests import helpers


class ReportsTest(unittest.TestCase):
    def test_summary_counts_paid_and_shipped(self):
        svc, _ = helpers.service()
        a = svc.create_order("C1", {"MUG-01": 2}, now=datetime(2026, 9, 14, 9))
        b = svc.create_order("C1", {"PEN-01": 4}, now=datetime(2026, 9, 14, 11))
        svc.create_order("C1", {"PEN-01": 1}, now=datetime(2026, 9, 15, 9))
        svc.pay(a.id)
        svc.pay(b.id)
        svc.ship(b.id)
        s = daily_summary(svc.repo, svc.customers, svc.catalog, "2026-09-14")
        self.assertEqual(s["orders"], 2)
        self.assertEqual(s["by_status"], {"paid": 1, "shipped": 1})
        self.assertEqual(s["revenue"], svc.repo.get(a.id).total + svc.repo.get(b.id).total)
        self.assertIn("revenue: ", format_summary(s))
