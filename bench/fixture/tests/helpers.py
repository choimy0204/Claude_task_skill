from decimal import Decimal

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
