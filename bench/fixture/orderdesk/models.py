"""도메인 모델."""
from dataclasses import dataclass, field
from decimal import Decimal
from enum import Enum
from typing import Optional


class OrderStatus(str, Enum):
    NEW = "new"
    PAID = "paid"
    SHIPPED = "shipped"
    CANCELLED = "cancelled"


@dataclass
class Product:
    sku: str
    name: str
    price: Decimal
    weight_kg: Decimal
    category: str


@dataclass
class Customer:
    id: str
    name: str
    tier: str = "basic"
    region: str = "seoul"


@dataclass
class LineItem:
    sku: str
    qty: int
    unit_price: Decimal

    @property
    def line_total(self) -> Decimal:
        return self.unit_price * self.qty


@dataclass
class Order:
    id: str
    customer_id: str
    items: list
    created_at: str
    status: OrderStatus = OrderStatus.NEW
    coupon: Optional[str] = None
    total: Optional[Decimal] = None
    history: list = field(default_factory=list)

    def item(self, sku: str) -> Optional[LineItem]:
        for it in self.items:
            if it.sku == sku:
                return it
        return None

    @property
    def day(self) -> str:
        return self.created_at[:10]

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "customer_id": self.customer_id,
            "items": [{"sku": i.sku, "qty": i.qty, "unit_price": str(i.unit_price)} for i in self.items],
            "created_at": self.created_at,
            "status": self.status.value,
            "coupon": self.coupon,
            "total": None if self.total is None else str(self.total),
            "history": [list(h) for h in self.history],
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Order":
        return cls(
            id=d["id"],
            customer_id=d["customer_id"],
            items=[LineItem(i["sku"], int(i["qty"]), Decimal(i["unit_price"])) for i in d["items"]],
            created_at=d["created_at"],
            status=OrderStatus(d["status"]),
            coupon=d.get("coupon"),
            total=None if d.get("total") is None else Decimal(d["total"]),
            history=[tuple(h) for h in d.get("history", [])],
        )
