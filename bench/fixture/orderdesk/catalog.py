"""상품 카탈로그."""
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
