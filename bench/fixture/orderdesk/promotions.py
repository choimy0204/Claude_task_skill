"""프로모션 규칙."""
from dataclasses import dataclass
from decimal import Decimal
from typing import Optional

from .money import to_money


@dataclass
class Adjustment:
    label: str
    amount: Decimal  # 할인액(양수)
    sku: Optional[str] = None


class PercentOff:
    """카테고리 상품에 정률 할인."""

    def __init__(self, category: str, rate):
        self.category = category
        self.rate = Decimal(str(rate))

    def apply(self, items, catalog) -> list:
        out = []
        for item in items:
            if catalog.get(item.sku).category == self.category:
                out.append(Adjustment(f"{self.category} {self.rate:%}", to_money(item.line_total * self.rate), item.sku))
        return out


class BuyXGetY:
    """sku를 buy개 사면 free개를 무료로 준다. (예: 2+1)"""

    def __init__(self, sku: str, buy: int, free: int):
        self.sku = sku
        self.buy = buy
        self.free = free

    def apply(self, items, catalog) -> list:
        out = []
        for item in items:
            if item.sku != self.sku:
                continue
            free_units = (item.qty // (self.buy + self.free)) * self.free
            if free_units:
                out.append(Adjustment(f"{self.buy}+{self.free} {self.sku}", to_money(item.unit_price * free_units), item.sku))
                # 뒤따르는 줄 단위 할인(대량 할인 등)은 유료 수량에만 적용되도록 청구 수량을 맞춘다
                item.qty -= free_units
        return out


DEFAULT_PROMOTIONS = [
    PercentOff("stationery", "0.10"),
    BuyXGetY("TEA-01", 2, 1),
]
