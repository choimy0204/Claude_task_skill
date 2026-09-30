"""명령줄 진입점."""
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
