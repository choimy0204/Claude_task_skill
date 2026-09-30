"""일별 리포트."""
from collections import Counter
from decimal import Decimal

from .models import OrderStatus
from .money import fmt
from .pricing import price_order

REVENUE_STATUSES = (OrderStatus.PAID, OrderStatus.SHIPPED)


def daily_summary(repo, customers, catalog, day: str, promotions=None) -> dict:
    """day(YYYY-MM-DD)에 생성된 주문의 상태별 건수, 매출, 많이 팔린 상품."""
    orders = repo.list_by_day(day)
    by_status = Counter(o.status.value for o in orders)
    revenue = Decimal("0.00")
    units = Counter()
    for o in orders:
        if o.status not in REVENUE_STATUSES:
            continue
        # 할인 규칙이 바뀌어도 리포트는 현재 규칙 기준으로 다시 계산한다
        revenue += price_order(o, customers[o.customer_id], catalog, promotions).total
        for i in o.items:
            units[i.sku] += i.qty
    return {
        "day": day,
        "orders": len(orders),
        "by_status": dict(by_status),
        "revenue": revenue,
        "top_products": units.most_common(3),
    }


def format_summary(s: dict) -> str:
    lines = [f"== {s['day']} ==", f"orders: {s['orders']}"]
    for status, n in sorted(s["by_status"].items()):
        lines.append(f"  {status:<10}{n:>5}")
    lines.append(f"revenue: {fmt(s['revenue'])}")
    for sku, n in s["top_products"]:
        lines.append(f"  top {sku:<10}{n:>5}")
    return "\n".join(lines)
