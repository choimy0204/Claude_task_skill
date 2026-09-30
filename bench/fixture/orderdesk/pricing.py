"""주문 금액 계산."""
from dataclasses import dataclass, field
from decimal import Decimal

from .config import BULK_RATE, BULK_THRESHOLD, COUPONS, TAX_RATES, TIER_DISCOUNT
from .money import to_money
from .promotions import DEFAULT_PROMOTIONS, Adjustment
from .shipping import shipping_cost


@dataclass
class PriceBreakdown:
    subtotal: Decimal
    adjustments: list = field(default_factory=list)
    tax: Decimal = Decimal("0.00")
    shipping: Decimal = Decimal("0.00")
    total: Decimal = Decimal("0.00")

    @property
    def discount_total(self) -> Decimal:
        return sum((a.amount for a in self.adjustments), Decimal("0.00"))

    @property
    def merchandise_total(self) -> Decimal:
        return max(Decimal("0.00"), self.subtotal - self.discount_total)


class InvalidCoupon(ValueError):
    pass


def _coupon_adjustment(code, amount) -> Adjustment:
    if code not in COUPONS:
        raise InvalidCoupon(code)
    kind, value = COUPONS[code]
    if kind == "fixed":
        return Adjustment(f"coupon {code}", min(value, amount))
    return Adjustment(f"coupon {code}", to_money(amount * value))


def price_order(order, customer, catalog, promotions=None) -> PriceBreakdown:
    """순서: 프로모션 → 대량 할인 → 등급 할인 → 쿠폰 → 세금 → 배송비."""
    promotions = DEFAULT_PROMOTIONS if promotions is None else promotions
    subtotal = to_money(sum((i.line_total for i in order.items), Decimal("0")))
    bd = PriceBreakdown(subtotal=subtotal)

    for promo in promotions:
        bd.adjustments.extend(promo.apply(order.items, catalog))

    for item in order.items:
        if item.qty > BULK_THRESHOLD:
            bd.adjustments.append(Adjustment(f"bulk {item.sku}", to_money(item.line_total * BULK_RATE), item.sku))

    rate = TIER_DISCOUNT[customer.tier]
    if rate:
        bd.adjustments.append(Adjustment(f"tier {customer.tier}", to_money(bd.merchandise_total * rate)))

    if order.coupon:
        bd.adjustments.append(_coupon_adjustment(order.coupon, bd.merchandise_total))

    merchandise = bd.merchandise_total
    bd.tax = to_money(merchandise * TAX_RATES[customer.region])
    bd.shipping = shipping_cost(order, customer, catalog, merchandise)
    bd.total = to_money(merchandise + bd.tax + bd.shipping)
    return bd


def format_receipt(order, bd: PriceBreakdown) -> str:
    lines = [f"Order {order.id}"]
    for i in order.items:
        lines.append(f"  {i.sku:<10} x{i.qty:<3} {i.line_total:>10.2f}")
    lines.append(f"  {'subtotal':<15}{bd.subtotal:>10.2f}")
    for a in bd.adjustments:
        lines.append(f"  - {a.label:<13}{a.amount:>10.2f}")
    lines.append(f"  {'tax':<15}{bd.tax:>10.2f}")
    lines.append(f"  {'shipping':<15}{bd.shipping:>10.2f}")
    lines.append(f"  {'TOTAL':<15}{bd.total:>10.2f}")
    return "\n".join(lines)
