"""data/ 폴더에서 카탈로그·고객·재고를 읽는다."""
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
