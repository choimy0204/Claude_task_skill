# 정답 구현을 대상 폴더에 적용한다. 숨은 테스트가 풀 수 있는 문제인지 확인하는 용도.
# 사용법: python reference.py <fixture 복사본> [bulk] [mutation] [returns] [export]
import sys
from pathlib import Path


def sub(path, old, new):
    t = path.read_text(encoding="utf-8")
    assert old in t, (path, old)
    path.write_text(t.replace(old, new, 1), encoding="utf-8", newline="\n")


def bulk(root):
    sub(root / "orderdesk/pricing.py", "item.qty > BULK_THRESHOLD", "item.qty >= BULK_THRESHOLD")


def mutation(root):
    p = root / "orderdesk/pricing.py"
    sub(p, "from .promotions import DEFAULT_PROMOTIONS, Adjustment", "from .models import LineItem\nfrom .promotions import DEFAULT_PROMOTIONS, Adjustment")
    sub(p, "    for promo in promotions:\n        bd.adjustments.extend(promo.apply(order.items, catalog))\n\n    for item in order.items:",
        "    # 프로모션이 청구 수량을 조정하므로 복사본에 적용한다\n    items = [LineItem(i.sku, i.qty, i.unit_price) for i in order.items]\n"
        "    for promo in promotions:\n        bd.adjustments.extend(promo.apply(items, catalog))\n\n    for item in items:")


def returns(root):
    sub(root / "orderdesk/models.py", '    CANCELLED = "cancelled"\n',
        '    CANCELLED = "cancelled"\n    PARTIALLY_RETURNED = "partially_returned"\n    RETURNED = "returned"\n')
    sub(root / "orderdesk/models.py", "    history: list = field(default_factory=list)\n",
        "    history: list = field(default_factory=list)\n    returns: dict = field(default_factory=dict)\n")
    sub(root / "orderdesk/models.py", '            "history": [list(h) for h in self.history],\n',
        '            "history": [list(h) for h in self.history],\n            "returns": dict(self.returns),\n')
    sub(root / "orderdesk/models.py", '            history=[tuple(h) for h in d.get("history", [])],\n',
        '            history=[tuple(h) for h in d.get("history", [])],\n            returns={k: int(v) for k, v in d.get("returns", {}).items()},\n')
    sub(root / "orderdesk/service.py", "from .pricing import price_order\n",
        "from .config import TAX_RATES\nfrom .money import to_money\nfrom .pricing import price_order\n")
    (root / "orderdesk/service.py").open("a", encoding="utf-8", newline="\n").write('''
    def return_items(self, order_id, lines: dict, now=None):
        order = self.repo.get(order_id)
        if order.status not in (OrderStatus.SHIPPED, OrderStatus.PARTIALLY_RETURNED):
            raise OrderError(f"{order_id} is {order.status.value}")
        for sku, qty in lines.items():
            item = order.item(sku)
            if item is None or qty <= 0 or qty > item.qty - order.returns.get(sku, 0):
                raise OrderError(f"invalid return {sku}: {qty}")
        customer = self._customer(order.customer_id)
        bd = price_order(order, customer, self.catalog, self.promotions)
        ratio = bd.merchandise_total / bd.subtotal if bd.subtotal else 0
        refund = to_money(sum(order.item(s).unit_price * q for s, q in lines.items()) * ratio * (1 + TAX_RATES[customer.region]))
        for sku, qty in lines.items():
            order.returns[sku] = order.returns.get(sku, 0) + qty
            self.inventory.add_stock(sku, qty)
        done = all(order.returns.get(i.sku, 0) >= i.qty for i in order.items)
        order.status = OrderStatus.RETURNED if done else OrderStatus.PARTIALLY_RETURNED
        order.history.append(("returned", str(refund)))
        self.repo.save(order)
        self._publish("order.returned", order_id=order.id, refund=refund)
        return refund
''')


def export(root):
    (root / "orderdesk/reports.py").open("a", encoding="utf-8", newline="\n").write('''

def export_daily_csv(repo, day: str, path) -> int:
    import csv
    rows = [o for o in repo.list_by_day(day) if o.status in REVENUE_STATUSES]
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\\n")
        w.writerow(["order_id", "customer_id", "status", "units", "total"])
        for o in rows:
            w.writerow([o.id, o.customer_id, o.status.value, sum(i.qty for i in o.items), f"{o.total:.2f}"])
    return len(rows)
''')
    p = root / "orderdesk/cli.py"
    sub(p, "from .reports import daily_summary, format_summary", "from .reports import daily_summary, export_daily_csv, format_summary")
    sub(p, '    sub.add_parser("list")\n', '    sub.add_parser("list")\n    ex = sub.add_parser("export")\n    ex.add_argument("--date", required=True)\n    ex.add_argument("--out", required=True)\n')
    sub(p, '    elif args.cmd == "list":', '    elif args.cmd == "export":\n        print(export_daily_csv(repo, args.date, args.out))\n    elif args.cmd == "list":')


def b5(root):
    w = lambda name, text: (root / "orderdesk" / name).write_text(text, encoding="utf-8", newline="\n")
    w("coupons.py", '''from decimal import Decimal

from .config import COUPONS
from .money import to_money


class InvalidCoupon(ValueError):
    pass


def normalize_code(code):
    c = (code or "").strip().upper()
    if c not in COUPONS:
        raise InvalidCoupon(code)
    return c


def coupon_discount(code, merchandise_total):
    kind, value = COUPONS[normalize_code(code)]
    total = Decimal(str(merchandise_total))
    if total <= 0:
        return Decimal("0.00")
    if kind == "fixed":
        return to_money(min(value, total))
    return to_money(total * value)
''')
    w("importer.py", '''import csv
from dataclasses import dataclass, field


@dataclass
class ImportResult:
    created: list = field(default_factory=list)
    errors: list = field(default_factory=list)


def import_orders_csv(path, service, now=None):
    groups, order = {}, []
    with open(path, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            ref = row["order_ref"]
            if ref not in groups:
                groups[ref] = []
                order.append(ref)
            groups[ref].append(row)
    res = ImportResult()
    for ref in order:
        rows = groups[ref]
        try:
            cust = {r["customer_id"] for r in rows}
            if len(cust) != 1:
                raise ValueError("customer mismatch")
            cid = cust.pop()
            if cid not in service.customers:
                raise ValueError(f"unknown customer {cid}")
            lines = {}
            for r in rows:
                qty = int(r["qty"])
                if qty <= 0:
                    raise ValueError(f"bad qty {qty}")
                if r["sku"] not in service.catalog:
                    raise ValueError(f"unknown sku {r['sku']}")
                lines[r["sku"]] = lines.get(r["sku"], 0) + qty
            res.created.append(service.create_order(cid, lines, now=now).id)
        except Exception as e:
            res.errors.append((ref, str(e) or type(e).__name__))
    return res
''')
    w("weekly.py", '''from datetime import date, timedelta
from decimal import Decimal

from .models import OrderStatus
from .money import fmt


def weekly_summary(repo, start_day):
    start = date.fromisoformat(start_day)
    days = []
    for n in range(7):
        day = (start + timedelta(days=n)).isoformat()
        orders = repo.list_by_day(day)
        rev = sum((o.total or Decimal("0") for o in orders if o.status in (OrderStatus.PAID, OrderStatus.SHIPPED)), Decimal("0"))
        days.append({"day": day, "orders": len(orders), "revenue": rev})
    total = sum((d["revenue"] for d in days), Decimal("0"))
    best = max(days, key=lambda d: d["revenue"]) if total > 0 else None
    return {"start": start_day, "days": days, "total_revenue": total, "best_day": best and best["day"]}


def format_weekly(s):
    lines = [f"week of {s['start']}"]
    lines += [f"{d['day']} {d['orders']:>3} {fmt(d['revenue']):>10}" for d in s["days"]]
    lines.append(f"total {fmt(s['total_revenue'])}")
    return "\\n".join(lines)
''')
    w("stock_alerts.py", '''def low_stock(inventory, skus, thresholds=None, default=10):
    thresholds = thresholds or {}
    out = []
    for sku in skus:
        t = thresholds.get(sku, default)
        a = inventory.available(sku)
        if a < t:
            out.append((sku, a, t))
    return sorted(out, key=lambda x: (x[1], x[0]))


def reorder_plan(inventory, skus, target=50, thresholds=None, default=10):
    return {sku: target - a for sku, a, _ in low_stock(inventory, skus, thresholds, default) if target - a > 0}
''')


if __name__ == "__main__":
    root = Path(sys.argv[1])
    for step in sys.argv[2:]:
        globals()[step](root)
