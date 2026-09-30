"""주문 처리 서비스."""
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
