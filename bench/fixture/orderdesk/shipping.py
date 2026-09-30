"""배송비 계산."""
from decimal import Decimal, ROUND_CEILING

from .config import FREE_SHIPPING_THRESHOLD, SHIPPING_BASE, SHIPPING_PER_KG, SHIPPING_ZONES
from .money import to_money


def total_weight(order, catalog) -> Decimal:
    return sum((catalog.get(i.sku).weight_kg * i.qty for i in order.items), Decimal("0"))


def shipping_cost(order, customer, catalog, merchandise_total: Decimal) -> Decimal:
    """기본 요금 + 1kg 초과분 kg당 요금. 등급별 기준 이상이면 무료."""
    threshold = FREE_SHIPPING_THRESHOLD[customer.tier]
    if threshold is not None and merchandise_total >= threshold:
        return Decimal("0.00")
    zone = SHIPPING_ZONES[customer.region]
    billable = max(Decimal("1"), total_weight(order, catalog).to_integral_value(rounding=ROUND_CEILING))
    return to_money(SHIPPING_BASE[zone] + SHIPPING_PER_KG[zone] * (billable - 1))
