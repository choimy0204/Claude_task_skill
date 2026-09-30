"""요율·할인·배송 설정."""
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
