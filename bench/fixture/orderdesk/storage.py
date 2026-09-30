"""주문 저장소 (JSON 파일)."""
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
