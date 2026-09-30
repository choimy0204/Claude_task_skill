"""재고와 예약."""


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
