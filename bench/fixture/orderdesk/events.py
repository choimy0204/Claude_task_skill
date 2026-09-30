"""간단한 이벤트 버스."""
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
