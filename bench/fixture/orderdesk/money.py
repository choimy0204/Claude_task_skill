"""금액 계산 도우미. 모든 금액은 Decimal로 다룬다."""
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
