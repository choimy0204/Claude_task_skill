# 벤치마크 픽스처(orderdesk 앱)를 bench/fixture 에 다시 만든다.
# 결과는 항상 같다(난수 시드 고정). 정답 값은 bench/hidden/truth.json 에 쓴다.
# 사용법: python bench/tools/make_fixture.py
import json
import os
import random
import shutil

BENCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FX = os.path.join(BENCH, "fixture")

FILES = {}

FILES["README.md"] = r'''# orderdesk

작은 주문 처리 라이브러리. 상품 카탈로그, 재고 예약, 프로모션·등급 할인, 세금, 배송비, 주문 저장, 일별 리포트를 다룬다.

- 실행: `python -m orderdesk.cli summary --date 2026-09-14`
- 테스트: `python -m unittest discover -s tests -t .`
'''

FILES["orderdesk/__init__.py"] = r'''"""orderdesk: 작은 주문 처리 라이브러리."""

__version__ = "0.3.1"
'''

FILES["orderdesk/config.py"] = r'''"""요율·할인·배송 설정."""
from decimal import Decimal

# 지역별 세율
TAX_RATES = {
    "seoul": Decimal("0.10"),
    "busan": Decimal("0.10"),
    "jeju": Decimal("0.07"),
    "overseas": Decimal("0"),
}

# 고객 등급 할인율 (프로모션·대량 할인 뒤 금액에 적용)
TIER_DISCOUNT = {
    "basic": Decimal("0"),
    "gold": Decimal("0.05"),
    "vip": Decimal("0.10"),
}

# 같은 상품을 이 수량 이상 사면 해당 줄에 대량 할인을 준다.
BULK_THRESHOLD = 10
BULK_RATE = Decimal("0.03")

# 배송 구역과 요금
SHIPPING_ZONES = {"seoul": 1, "busan": 2, "jeju": 3, "overseas": 4}
SHIPPING_BASE = {1: Decimal("3.00"), 2: Decimal("3.50"), 3: Decimal("5.00"), 4: Decimal("15.00")}
SHIPPING_PER_KG = {1: Decimal("0.50"), 2: Decimal("0.60"), 3: Decimal("1.00"), 4: Decimal("4.00")}

# 등급별 무료 배송 기준 (할인 후 상품 금액). None이면 무료 배송 없음.
FREE_SHIPPING_THRESHOLD = {
    "basic": None,
    "gold": Decimal("100.00"),
    "vip": Decimal("0.00"),
}

# 쿠폰: (종류, 값)
COUPONS = {
    "WELCOME5": ("fixed", Decimal("5.00")),
    "SPRING10": ("percent", Decimal("0.10")),
}
'''

FILES["orderdesk/money.py"] = r'''"""금액 계산 도우미. 모든 금액은 Decimal로 다룬다."""
from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")


def to_money(value) -> Decimal:
    """0.01 단위로 반올림(ROUND_HALF_UP)한 Decimal을 돌려준다."""
    if not isinstance(value, Decimal):
        value = Decimal(str(value))
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def split_evenly(amount, parts: int) -> list:
    """amount를 parts개로 나눈다. 나머지 센트는 앞쪽부터 1센트씩 더한다."""
    if parts <= 0:
        raise ValueError("parts must be positive")
    amount = to_money(amount)
    cents = int(amount / CENT)
    base, rest = divmod(cents, parts)
    return [(Decimal(base + (1 if i < rest else 0)) * CENT) for i in range(parts)]


def fmt(amount) -> str:
    return f"{to_money(amount):,.2f}"
'''

FILES["orderdesk/models.py"] = r'''"""도메인 모델."""
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
'''

FILES["orderdesk/catalog.py"] = r'''"""상품 카탈로그."""
import json
from decimal import Decimal

from .models import Product


class UnknownProduct(KeyError):
    pass


class Catalog:
    def __init__(self, products=None):
        self._products = {p.sku: p for p in (products or [])}

    @classmethod
    def from_json(cls, path) -> "Catalog":
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
        return cls([
            Product(r["sku"], r["name"], Decimal(r["price"]), Decimal(r["weight_kg"]), r["category"])
            for r in raw
        ])

    def get(self, sku: str) -> Product:
        try:
            return self._products[sku]
        except KeyError:
            raise UnknownProduct(sku) from None

    def by_category(self, category: str) -> list:
        return [p for p in self._products.values() if p.category == category]

    def __contains__(self, sku) -> bool:
        return sku in self._products

    def __len__(self) -> int:
        return len(self._products)
'''

FILES["orderdesk/inventory.py"] = r'''"""재고와 예약."""


class OutOfStock(Exception):
    def __init__(self, sku, wanted, available):
        super().__init__(f"{sku}: wanted {wanted}, available {available}")
        self.sku = sku
        self.wanted = wanted
        self.available = available


class Inventory:
    """on_hand: 창고 수량, reserved: 결제·출고 전 예약 수량."""

    def __init__(self, stock=None):
        self._on_hand = dict(stock or {})
        self._reserved = {}

    def on_hand(self, sku) -> int:
        return self._on_hand.get(sku, 0)

    def reserved(self, sku) -> int:
        return self._reserved.get(sku, 0)

    def available(self, sku) -> int:
        return self.on_hand(sku) - self.reserved(sku)

    def add_stock(self, sku, qty: int):
        if qty <= 0:
            raise ValueError("qty must be positive")
        self._on_hand[sku] = self.on_hand(sku) + qty

    def reserve(self, order):
        # 전부 가능한지 먼저 확인하고 예약한다 (일부만 예약되는 일이 없게)
        for item in order.items:
            if self.available(item.sku) < item.qty:
                raise OutOfStock(item.sku, item.qty, self.available(item.sku))
        for item in order.items:
            self._reserved[item.sku] = self.reserved(item.sku) + item.qty

    def release(self, order):
        for item in order.items:
            self._reserved[item.sku] = max(0, self.reserved(item.sku) - item.qty)

    def commit(self, order):
        """출고: 예약을 풀고 창고 수량에서 뺀다."""
        for item in order.items:
            self._reserved[item.sku] = max(0, self.reserved(item.sku) - item.qty)
            self._on_hand[item.sku] = self.on_hand(item.sku) - item.qty

    def snapshot(self) -> dict:
        skus = sorted(set(self._on_hand) | set(self._reserved))
        return {sku: (self.on_hand(sku), self.reserved(sku)) for sku in skus}
'''

FILES["orderdesk/promotions.py"] = r'''"""프로모션 규칙."""
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
'''

FILES["orderdesk/shipping.py"] = r'''"""배송비 계산."""
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
'''

FILES["orderdesk/pricing.py"] = r'''"""주문 금액 계산."""
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
'''

FILES["orderdesk/events.py"] = r'''"""간단한 이벤트 버스."""
from collections import defaultdict


class EventBus:
    def __init__(self):
        self._handlers = defaultdict(list)

    def subscribe(self, name: str, handler):
        """handler(name, payload: dict). name이 "*"이면 모든 이벤트를 받는다."""
        self._handlers[name].append(handler)

    def publish(self, name: str, **payload):
        for handler in list(self._handlers[name]) + list(self._handlers["*"]):
            handler(name, payload)


class AuditLog:
    """모든 이벤트를 기록한다. bus.subscribe("*", audit) 로 붙인다."""

    def __init__(self):
        self.entries = []

    def __call__(self, name, payload):
        self.entries.append((name, dict(payload)))

    def names(self) -> list:
        return [n for n, _ in self.entries]
'''

FILES["orderdesk/storage.py"] = r'''"""주문 저장소 (JSON 파일)."""
import json
import os

from .models import Order


class OrderNotFound(KeyError):
    pass


class JsonOrderRepository:
    """주문을 메모리에 두고 save()마다 JSON 파일 전체를 다시 쓴다. path가 None이면 메모리 전용."""

    def __init__(self, path=None):
        self.path = path
        self._orders = {}
        if path and os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                for d in json.load(f):
                    o = Order.from_dict(d)
                    self._orders[o.id] = o

    def save(self, order: Order):
        self._orders[order.id] = order
        self._flush()

    def get(self, order_id: str) -> Order:
        try:
            return self._orders[order_id]
        except KeyError:
            raise OrderNotFound(order_id) from None

    def list(self) -> list:
        return sorted(self._orders.values(), key=lambda o: o.id)

    def list_by_day(self, day: str) -> list:
        return [o for o in self.list() if o.day == day]

    def next_id(self) -> str:
        return f"O-{1001 + len(self._orders)}"

    def _flush(self):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump([o.to_dict() for o in self.list()], f, ensure_ascii=False, indent=1)
        os.replace(tmp, self.path)
'''

FILES["orderdesk/service.py"] = r'''"""주문 처리 서비스."""
from datetime import datetime

from .inventory import Inventory
from .models import LineItem, Order, OrderStatus
from .pricing import price_order


class OrderError(Exception):
    pass


class OrderService:
    def __init__(self, catalog, inventory: Inventory, repo, customers: dict, bus=None, promotions=None):
        self.catalog = catalog
        self.inventory = inventory
        self.repo = repo
        self.customers = customers
        self.bus = bus
        self.promotions = promotions

    def _publish(self, name, **payload):
        if self.bus:
            self.bus.publish(name, **payload)

    def _customer(self, customer_id):
        try:
            return self.customers[customer_id]
        except KeyError:
            raise OrderError(f"unknown customer {customer_id}") from None

    def create_order(self, customer_id, lines: dict, coupon=None, now=None) -> Order:
        """lines: {sku: qty}"""
        self._customer(customer_id)
        if not lines:
            raise OrderError("empty order")
        items = []
        for sku, qty in lines.items():
            if qty <= 0:
                raise OrderError(f"invalid qty for {sku}: {qty}")
            items.append(LineItem(sku, qty, self.catalog.get(sku).price))
        created = (now or datetime.now()).isoformat(timespec="seconds")
        order = Order(self.repo.next_id(), customer_id, items, created, coupon=coupon)
        self.inventory.reserve(order)
        order.history.append(("created", created))
        self.repo.save(order)
        self._publish("order.created", order_id=order.id)
        return order

    def quote(self, order_id):
        order = self.repo.get(order_id)
        return price_order(order, self._customer(order.customer_id), self.catalog, self.promotions)

    def pay(self, order_id):
        order = self.repo.get(order_id)
        if order.status != OrderStatus.NEW:
            raise OrderError(f"{order_id} is {order.status.value}")
        bd = price_order(order, self._customer(order.customer_id), self.catalog, self.promotions)
        order.total = bd.total
        order.status = OrderStatus.PAID
        order.history.append(("paid", str(bd.total)))
        self.repo.save(order)
        self._publish("order.paid", order_id=order.id, total=bd.total)
        return bd.total

    def ship(self, order_id):
        order = self.repo.get(order_id)
        if order.status != OrderStatus.PAID:
            raise OrderError(f"{order_id} is {order.status.value}")
        self.inventory.commit(order)
        order.status = OrderStatus.SHIPPED
        order.history.append(("shipped", None))
        self.repo.save(order)
        self._publish("order.shipped", order_id=order.id)

    def cancel(self, order_id):
        order = self.repo.get(order_id)
        if order.status not in (OrderStatus.NEW, OrderStatus.PAID):
            raise OrderError(f"{order_id} is {order.status.value}")
        self.inventory.release(order)
        order.status = OrderStatus.CANCELLED
        order.history.append(("cancelled", None))
        self.repo.save(order)
        self._publish("order.cancelled", order_id=order.id)
'''

FILES["orderdesk/reports.py"] = r'''"""일별 리포트."""
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
'''

FILES["orderdesk/loader.py"] = r'''"""data/ 폴더에서 카탈로그·고객·재고를 읽는다."""
import json
import os

from .catalog import Catalog
from .inventory import Inventory
from .models import Customer

DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")


def _read(name, data_dir):
    with open(os.path.join(data_dir, name), encoding="utf-8") as f:
        return json.load(f)


def load_catalog(data_dir=DATA_DIR) -> Catalog:
    return Catalog.from_json(os.path.join(data_dir, "products.json"))


def load_customers(data_dir=DATA_DIR) -> dict:
    return {c["id"]: Customer(c["id"], c["name"], c["tier"], c["region"]) for c in _read("customers.json", data_dir)}


def load_inventory(data_dir=DATA_DIR) -> Inventory:
    return Inventory(_read("stock.json", data_dir))
'''

FILES["orderdesk/cli.py"] = r'''"""명령줄 진입점."""
import argparse
import os
import sys

from .loader import DATA_DIR, load_catalog, load_customers
from .pricing import format_receipt, price_order
from .reports import daily_summary, format_summary
from .storage import JsonOrderRepository, OrderNotFound


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="orderdesk")
    p.add_argument("--data", default=DATA_DIR)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary")
    s.add_argument("--date", required=True)
    sh = sub.add_parser("show")
    sh.add_argument("order_id")
    sub.add_parser("list")
    args = p.parse_args(argv)

    catalog = load_catalog(args.data)
    customers = load_customers(args.data)
    repo = JsonOrderRepository(os.path.join(args.data, "orders.json"))

    if args.cmd == "summary":
        print(format_summary(daily_summary(repo, customers, catalog, args.date)))
    elif args.cmd == "show":
        try:
            order = repo.get(args.order_id)
        except OrderNotFound:
            print(f"not found: {args.order_id}", file=sys.stderr)
            return 1
        print(format_receipt(order, price_order(order, customers[order.customer_id], catalog)))
    elif args.cmd == "list":
        for o in repo.list():
            print(f"{o.id}  {o.created_at}  {o.customer_id:<6} {o.status.value:<10} {o.total or '-'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
'''

FILES["tests/__init__.py"] = ""

FILES["tests/helpers.py"] = r'''from decimal import Decimal

from orderdesk.catalog import Catalog
from orderdesk.events import AuditLog, EventBus
from orderdesk.inventory import Inventory
from orderdesk.models import Customer, Product
from orderdesk.service import OrderService
from orderdesk.storage import JsonOrderRepository

D = Decimal


def catalog():
    return Catalog([
        Product("PEN-01", "Gel pen", D("2.50"), D("0.02"), "stationery"),
        Product("NOTE-01", "Notebook A5", D("6.00"), D("0.30"), "stationery"),
        Product("MUG-01", "Mug", D("12.00"), D("0.45"), "kitchen"),
        Product("TEA-01", "Green tea 50g", D("8.00"), D("0.10"), "tea"),
        Product("LAMP-01", "Desk lamp", D("50.00"), D("1.80"), "home"),
        Product("CHAIR-01", "Chair", D("120.00"), D("7.50"), "home"),
    ])


def customers():
    return {
        "C1": Customer("C1", "Kim", "basic", "seoul"),
        "C2": Customer("C2", "Lee", "gold", "busan"),
        "C3": Customer("C3", "Park", "vip", "jeju"),
        "C4": Customer("C4", "Choi", "basic", "overseas"),
    }


def stock():
    return {"PEN-01": 500, "NOTE-01": 200, "MUG-01": 50, "TEA-01": 60, "LAMP-01": 20, "CHAIR-01": 5}


def service(path=None):
    bus = EventBus()
    audit = AuditLog()
    bus.subscribe("*", audit)
    svc = OrderService(catalog(), Inventory(stock()), JsonOrderRepository(path), customers(), bus)
    return svc, audit
'''

FILES["tests/test_money.py"] = r'''import unittest
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
'''

FILES["tests/test_pricing.py"] = r'''import unittest
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
'''

FILES["tests/test_shipping.py"] = r'''import unittest
from decimal import Decimal as D

from orderdesk.models import Customer, LineItem, Order
from orderdesk.shipping import shipping_cost

from tests import helpers


class ShippingTest(unittest.TestCase):
    def setUp(self):
        self.cat = helpers.catalog()

    def _order(self, sku, qty):
        return Order("O-1", "C1", [LineItem(sku, qty, self.cat.get(sku).price)], "2026-09-14T10:00:00")

    def test_minimum_one_kg(self):
        c = Customer("C1", "Kim", "basic", "seoul")
        self.assertEqual(shipping_cost(self._order("PEN-01", 3), c, self.cat, D("7.50")), D("3.00"))

    def test_weight_rounds_up(self):
        c = Customer("C4", "Choi", "basic", "overseas")
        # 7.5kg -> 8kg: 15 + 4*7
        self.assertEqual(shipping_cost(self._order("CHAIR-01", 1), c, self.cat, D("120")), D("43.00"))

    def test_vip_always_free(self):
        c = Customer("C3", "Park", "vip", "jeju")
        self.assertEqual(shipping_cost(self._order("CHAIR-01", 1), c, self.cat, D("1")), D("0.00"))
'''

FILES["tests/test_inventory.py"] = r'''import unittest

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
'''

FILES["tests/test_service.py"] = r'''import os
import tempfile
import unittest
from datetime import datetime
from decimal import Decimal as D

from orderdesk.models import OrderStatus
from orderdesk.service import OrderError
from orderdesk.storage import JsonOrderRepository

from tests import helpers

NOW = datetime(2026, 9, 14, 10, 0, 0)


class ServiceTest(unittest.TestCase):
    def test_lifecycle(self):
        svc, audit = helpers.service()
        o = svc.create_order("C1", {"MUG-01": 2}, now=NOW)
        self.assertEqual(svc.inventory.available("MUG-01"), 48)
        self.assertEqual(svc.pay(o.id), D("29.40"))
        svc.ship(o.id)
        self.assertEqual(svc.inventory.on_hand("MUG-01"), 48)
        self.assertEqual(audit.names(), ["order.created", "order.paid", "order.shipped"])

    def test_cancel_restores_stock(self):
        svc, _ = helpers.service()
        o = svc.create_order("C2", {"LAMP-01": 2}, now=NOW)
        svc.pay(o.id)
        svc.cancel(o.id)
        self.assertEqual(svc.inventory.available("LAMP-01"), 20)
        self.assertEqual(svc.repo.get(o.id).status, OrderStatus.CANCELLED)

    def test_cannot_ship_unpaid(self):
        svc, _ = helpers.service()
        o = svc.create_order("C1", {"PEN-01": 1}, now=NOW)
        with self.assertRaises(OrderError):
            svc.ship(o.id)

    def test_persistence(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "orders.json")
            svc, _ = helpers.service(path)
            o = svc.create_order("C3", {"NOTE-01": 1}, now=NOW)
            svc.pay(o.id)
            again = JsonOrderRepository(path).get(o.id)
            self.assertEqual(again.status, OrderStatus.PAID)
            self.assertEqual(again.total, svc.repo.get(o.id).total)
'''

FILES["tests/test_reports.py"] = r'''import unittest
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
'''

PRODUCTS = [
    ("PEN-01", "Gel pen", "2.50", "0.02", "stationery"),
    ("PEN-02", "Fountain pen", "18.00", "0.05", "stationery"),
    ("NOTE-01", "Notebook A5", "6.00", "0.30", "stationery"),
    ("NOTE-02", "Notebook A4", "9.00", "0.55", "stationery"),
    ("MUG-01", "Mug", "12.00", "0.45", "kitchen"),
    ("BOTTLE-01", "Water bottle", "15.00", "0.35", "kitchen"),
    ("TEA-01", "Green tea 50g", "8.00", "0.10", "tea"),
    ("TEA-02", "Black tea 100g", "11.00", "0.15", "tea"),
    ("LAMP-01", "Desk lamp", "50.00", "1.80", "home"),
    ("CHAIR-01", "Chair", "120.00", "7.50", "home"),
    ("MAT-01", "Desk mat", "22.00", "0.90", "home"),
    ("BAG-01", "Tote bag", "14.00", "0.25", "fashion"),
]
CUSTOMERS = [
    ("C1", "Kim", "basic", "seoul"), ("C2", "Lee", "gold", "busan"), ("C3", "Park", "vip", "jeju"),
    ("C4", "Choi", "basic", "overseas"), ("C5", "Jung", "gold", "seoul"), ("C6", "Kang", "basic", "busan"),
    ("C7", "Cho", "vip", "seoul"), ("C8", "Yoon", "basic", "jeju"),
]

# 로그 구성: 에러 유형별 건수(정답)와 몰린 시간대
ERRORS = {
    "PaymentDeclined": (137, "payment", "code={code} order={oid}"),
    "InventoryMismatch": (58, "inventory", "sku={sku} expected={a} actual={b}"),
    "ShippingRateTimeout": (211, "shipping", "zone={zone} timeout_ms={ms}"),
    "OrderNotFound": (19, "api", "order={oid}"),
    "JsonDecodeError": (7, "storage", "file=orders.json pos={pos}"),
}
PEAK_TYPE, PEAK_HOUR, PEAK_SHARE = "ShippingRateTimeout", 14, 0.7


def make_log(rng):
    lines = []
    base_days = ["2026-09-12", "2026-09-13", "2026-09-14"]
    def ts(hour=None):
        d = rng.choice(base_days)
        h = rng.randint(8, 21) if hour is None else hour
        return f"{d} {h:02d}:{rng.randint(0, 59):02d}:{rng.randint(0, 59):02d},{rng.randint(0, 999):03d}"
    skus = [p[0] for p in PRODUCTS]
    for name, (n, comp, fmt) in ERRORS.items():
        for k in range(n):
            hour = PEAK_HOUR if (name == PEAK_TYPE and k < int(n * PEAK_SHARE)) else None
            msg = fmt.format(code=rng.choice([5, 14, 51, 54]), oid=f"O-{rng.randint(1001, 1999)}", sku=rng.choice(skus),
                             a=rng.randint(1, 50), b=rng.randint(1, 50), zone=rng.randint(1, 4), ms=rng.randint(3000, 9000),
                             pos=rng.randint(1, 90000))
            lines.append(f"{ts(hour)} ERROR [{comp}] {name} {msg}")
    info_msgs = ["order created order=O-{}", "order paid order=O-{} total={}.{:02d}", "order shipped order=O-{}",
                 "cache refresh products={}", "health ok latency_ms={}"]
    for _ in range(3600):
        m = rng.choice(info_msgs)
        lines.append(f"{ts()} INFO [{rng.choice(['api', 'payment', 'shipping', 'worker'])}] "
                     + m.format(rng.randint(1001, 1999), rng.randint(5, 400), rng.randint(0, 99)))
    for _ in range(420):
        lines.append(f"{ts()} WARN [shipping] rate api slow latency_ms={rng.randint(1500, 2999)} zone={rng.randint(1, 4)}")
    # 여러 줄짜리 트레이스백 (에러 건수에 포함되지 않음)
    for _ in range(12):
        lines.append(f"{ts()} DEBUG [worker] retry scheduled")
    lines.sort()
    return lines


def main():
    rng = random.Random(20260914)
    if os.path.exists(FX):
        shutil.rmtree(FX)
    for rel, content in FILES.items():
        p = os.path.join(FX, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
    os.makedirs(os.path.join(FX, "data"), exist_ok=True)
    with open(os.path.join(FX, "data", "products.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump([dict(zip(["sku", "name", "price", "weight_kg", "category"], p)) for p in PRODUCTS], f, indent=1)
    with open(os.path.join(FX, "data", "customers.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump([dict(zip(["id", "name", "tier", "region"], c)) for c in CUSTOMERS], f, indent=1)
    with open(os.path.join(FX, "data", "stock.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({p[0]: rng.randint(20, 300) for p in PRODUCTS}, f, indent=1)
    lines = make_log(rng)
    os.makedirs(os.path.join(FX, "logs"), exist_ok=True)
    with open(os.path.join(FX, "logs", "app.log"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    # 정답: 에러 유형별 건수, 가장 많은 유형, 몰린 시간대
    truth = {
        "errors": {k: v[0] for k, v in ERRORS.items()},
        "top_error": PEAK_TYPE,
        "top_error_count": ERRORS[PEAK_TYPE][0],
        "peak_hour": PEAK_HOUR,
        "error_total": sum(v[0] for v in ERRORS.values()),
        "log_lines": len(lines),
    }
    with open(os.path.join(BENCH, "hidden", "truth.json"), "w", encoding="utf-8") as f:
        json.dump(truth, f, ensure_ascii=False, indent=1)
    print("fixture written:", FX, "log lines", len(lines))


if __name__ == "__main__":
    main()
