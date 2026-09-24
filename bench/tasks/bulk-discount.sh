#!/usr/bin/env bash
# A real benchmark task: long, multi-turn, big files read early.
#
# Builds a throwaway pricing package (~2,300 lines over three modules, all above
# the shunt threshold), then asks for a feature that needs all three: a bulk
# discount in the pricing engine, its tests, and a new field in the report.
# The parent has to understand the rule pipeline before editing it, then keeps
# working for many turns (edits, pytest, fixes) -- which is where context read
# early gets re-sent.
#
# task_verify runs the repo's tests AND a hidden check that compares the new
# pricing against a pristine copy of the original rules, so an arm that "saves"
# by getting the feature wrong fails the gate.

TASK_NAME="bulk-discount"
TASK_BASE="${TMPDIR:-/tmp}/shunt-bulk-discount"
TASK_REPO="$TASK_BASE/repo"
TASK_ORIG="$TASK_BASE/orig"

if [ ! -f "$TASK_REPO/inv/pricing.py" ]; then
  rm -rf "$TASK_BASE"; mkdir -p "$TASK_REPO/inv" "$TASK_REPO/tests"
  python3 - "$TASK_REPO" <<'PY'
import random, sys, os
root = sys.argv[1]
rnd = random.Random(7)
CATS = ["grocery", "hardware", "garden", "toys", "books", "clearance", "apparel", "office"]

# ---------------------------------------------------------------- models.py
m = ['"""Catalog, orders and lookup helpers."""\n',
     "from dataclasses import dataclass, field\n\n",
     "CATEGORIES = %r\n\n" % CATS,
     "\n@dataclass(frozen=True)\nclass Product:\n    code: str\n    name: str\n"
     "    unit_price: float\n    category: str\n    weight_kg: float = 1.0\n\n",
     "\n@dataclass\nclass Line:\n    code: str\n    qty: int\n\n",
     "\n@dataclass\nclass Order:\n    id: str\n    customer_tier: str  # bronze | silver | gold\n"
     "    lines: list = field(default_factory=list)\n    region: str = \"eu\"\n\n",
     "\n# The catalog. Codes are stable; prices are list prices before any rule.\n",
     "CATALOG = {\n"]
for i in range(420):
    cat = CATS[rnd.randrange(len(CATS))]
    m.append(f'    "P{i:03d}": Product("P{i:03d}", "item {i} ({cat})", '
             f'{rnd.randint(100, 9000) / 100:.2f}, "{cat}", {rnd.randint(1, 40) / 4:.2f}),\n')
m.append("}\n\n")
m.append('''
def get_product(code):
    """Return the Product for `code`, or raise KeyError with a clear message."""
    try:
        return CATALOG[code]
    except KeyError:
        raise KeyError(f"unknown product code: {code}") from None


def products_in(category):
    """All products of one category, sorted by code."""
    return sorted((p for p in CATALOG.values() if p.category == category),
                  key=lambda p: p.code)


def order_weight(order):
    """Total shipping weight of an order, in kg."""
    return sum(get_product(l.code).weight_kg * l.qty for l in order.lines)
''')
for i in range(40):
    m.append(f'''

def validate_line_{i:02d}(line):
    """Validation hook {i}: reject malformed lines early.

    Hooks run in order during order intake; each checks one invariant.
    """
    if line.qty < 0:
        raise ValueError("negative quantity")
    if line.qty > {5000 + i * 10}:
        raise ValueError("quantity above intake cap {5000 + i * 10}")
    return True
''')
open(os.path.join(root, "inv", "models.py"), "w").write("".join(m))

# --------------------------------------------------------------- pricing.py
p = ['"""Pricing engine.\n\nEach line is priced as unit_price * qty, then passed through every rule in\n'
     'RULES, in order. A rule takes (order, line, product, price) and returns the\nnew price of '
     'that line. Line prices are rounded to cents after the last rule;\nthe order total is the '
     'sum of the rounded line prices.\n"""\n',
     "from inv.models import get_product\n\n"]
kinds = []
for i in range(64):
    k = i % 8
    cat = CATS[(i * 3) % len(CATS)]
    if cat == "clearance":
        cat = "grocery"
    tier = ["bronze", "silver", "gold"][i % 3]
    pct = (i % 5 + 1) / 100
    if k == 0:
        body = f'''    if product.category == "{cat}" and order.customer_tier == "{tier}":
        return price * (1 - {pct})
    return price'''
    elif k == 1:
        body = f'''    if line.qty >= {10 + i % 7} and product.category == "{cat}":
        return price - min({i % 4 + 1}.0, price * 0.05)
    return price'''
    elif k == 2:
        body = f'''    if order.region == "us" and product.unit_price > {20 + i}:
        return price * 1.0{i % 3 + 1}
    return price'''
    elif k == 3:
        body = f'''    if product.code.endswith("{i % 10}") and order.customer_tier != "bronze":
        return price * (1 - {pct / 2:.3f})
    return price'''
    elif k == 4:
        body = f'''    # Loyalty floor: never discount below 60% of list.
    floor = product.unit_price * line.qty * 0.60
    return max(price, floor)'''
    elif k == 5:
        body = f'''    if len(order.lines) >= {3 + i % 4}:
        return price * (1 - {pct / 4:.4f})
    return price'''
    elif k == 6:
        body = f'''    if product.category == "clearance":
        return price  # clearance prices are final; rule {i} does not apply
    if product.weight_kg > {5 + i % 6}:
        return price + {i % 3 + 1}.50
    return price'''
    else:
        body = f'''    if order.customer_tier == "gold" and line.qty % {2 + i % 3} == 0:
        return price * (1 - {pct / 3:.4f})
    return price'''
    p.append(f'''

def rule_{i:02d}(order, line, product, price):
    """Pricing rule {i}.

    Kind {k}. See the module docstring for the rule contract.
    """
{body}
''')
p.append("\n\nRULES = [\n" + "".join(f"    rule_{i:02d},\n" for i in range(64)) + "]\n")
p.append('''

def price_line(order, line):
    """Price one line through every rule, rounded to cents."""
    product = get_product(line.code)
    price = product.unit_price * line.qty
    for rule in RULES:
        price = rule(order, line, product, price)
    return round(price, 2)


def apply_rules(order):
    """Total price of an order, in currency units, rounded to cents."""
    return round(sum(price_line(order, line) for line in order.lines), 2)
''')
open(os.path.join(root, "inv", "pricing.py"), "w").write("".join(p))

# ---------------------------------------------------------------- report.py
r = ['"""Order reports."""\n', "from inv.models import get_product\n",
     "from inv.pricing import apply_rules, price_line\n\n"]
r.append('''

def summary(orders):
    """Aggregate a list of orders.

    Returns a dict with:
      order_count  number of orders
      gross        sum of list prices (unit_price * qty), rounded to cents
      net          sum of apply_rules(order), rounded to cents
      by_category  {category: net line total}
    """
    gross = 0.0
    net = 0.0
    by_category = {}
    for order in orders:
        for line in order.lines:
            product = get_product(line.code)
            gross += product.unit_price * line.qty
            lp = price_line(order, line)
            by_category[product.category] = round(by_category.get(product.category, 0.0) + lp, 2)
        net += apply_rules(order)
    return {"order_count": len(orders), "gross": round(gross, 2),
            "net": round(net, 2), "by_category": by_category}
''')
for i in range(50):
    r.append(f'''

def format_section_{i:02d}(data, width={60 + i}):
    """Render report section {i} as fixed-width text."""
    rows = []
    for key in sorted(data):
        value = data[key]
        if isinstance(value, float):
            value = f"{{value:,.2f}}"
        rows.append(f"{{str(key):<{{width // 2}}}}{{str(value):>{{width // 2}}}}")
    return "\\n".join(rows)
''')
open(os.path.join(root, "inv", "report.py"), "w").write("".join(r))
open(os.path.join(root, "inv", "__init__.py"), "w").write("")

open(os.path.join(root, "tests", "test_basic.py"), "w").write('''import unittest

from inv.models import Order, Line
from inv.pricing import apply_rules
from inv.report import summary


class BasicTest(unittest.TestCase):
    def test_single_line_positive(self):
        o = Order("o1", "silver", [Line("P001", 2)])
        self.assertGreater(apply_rules(o), 0)

    def test_summary_counts(self):
        orders = [Order("o1", "gold", [Line("P002", 3)]), Order("o2", "bronze", [Line("P010", 1)])]
        s = summary(orders)
        self.assertEqual(s["order_count"], 2)
        self.assertGreater(s["net"], 0)
''')
open(os.path.join(root, "tests", "__init__.py"), "w").write("")
PY
  cp -r "$TASK_REPO/inv" "$TASK_BASE/orig_inv_src"
  mkdir -p "$TASK_ORIG" && mv "$TASK_BASE/orig_inv_src" "$TASK_ORIG/inv"
  printf '__pycache__/\n' > "$TASK_REPO/.gitignore"
  ( cd "$TASK_REPO" && git init -q . && git add -A && git commit -qm fixture )
fi

TASK_PROMPT="In this repo, inv/ is a small pricing package (models.py, pricing.py,
report.py). Implement a bulk discount:

1. In inv/pricing.py: any order line with qty >= 50 gets an extra 7% off its
   price, applied AFTER all existing rules and before the line is rounded to
   cents. Lines whose product category is \"clearance\" are excluded. Keep
   apply_rules(order) and price_line(order, line) working with the same
   signatures.
2. In inv/report.py: summary(orders) must return a new key
   \"bulk_discount_total\": the total amount (rounded to cents) that the bulk
   discount took off across all orders.
3. Add unittest tests in tests/test_bulk.py covering: a qualifying line, the 49/50
   boundary, the clearance exclusion, and bulk_discount_total.

Understand how the existing rule pipeline works before changing it. Run the
test suite with python3 -m unittest discover -s tests -t . and do not stop
until it passes."

task_verify() {
  ( cd "$TASK_REPO" && python3 -m unittest discover -s tests -t . >/dev/null 2>&1 ) || return 1
  # the new tests must exist and actually run
  [ -f "$TASK_REPO/tests/test_bulk.py" ] || return 1
  ORIG="$TASK_ORIG" NEW="$TASK_REPO" python3 - <<'PY'
import importlib, os, sys

def load(root):
    for k in [k for k in sys.modules if k == "inv" or k.startswith("inv.")]:
        del sys.modules[k]
    sys.path.insert(0, root)
    try:
        return (importlib.import_module("inv.models"), importlib.import_module("inv.pricing"),
                importlib.import_module("inv.report"))
    finally:
        sys.path.pop(0)

om, op, _ = load(os.environ["ORIG"])
def ref(order, line):
    # the original rules, unrounded, then the expected bulk step
    product = om.get_product(line.code)
    price = product.unit_price * line.qty
    for rule in op.RULES:
        price = rule(order, line, product, price)
    return price, product.category

cases = []
cats = {}
for code, p in om.CATALOG.items():
    cats.setdefault(p.category, code)
normal = next(c for c, p in om.CATALOG.items() if p.category != "clearance")
clear = cats["clearance"]
for tier in ("bronze", "silver", "gold"):
    for code in (normal, clear):
        for qty in (49, 50, 120):
            cases.append((tier, code, qty))

nm, np_, nr = load(os.environ["NEW"])
expected_bulk = 0.0
orders = []
for i, (tier, code, qty) in enumerate(cases):
    o_old = om.Order(f"o{i}", tier, [om.Line(code, qty)])
    o_new = nm.Order(f"o{i}", tier, [nm.Line(code, qty)])
    price, cat = ref(o_old, o_old.lines[0])
    bulk = qty >= 50 and cat != "clearance"
    want = round(price * 0.93, 2) if bulk else round(price, 2)
    got = np_.apply_rules(o_new)
    if abs(got - want) > 0.011:
        print(f"FAIL {tier} {code} qty={qty}: got {got} want {want}")
        sys.exit(1)
    if bulk:
        expected_bulk += price * 0.07
    orders.append(o_new)
s = nr.summary(orders)
if "bulk_discount_total" not in s:
    print("FAIL no bulk_discount_total"); sys.exit(1)
if abs(s["bulk_discount_total"] - round(expected_bulk, 2)) > 0.05 * len(orders) / 10 + 0.02:
    print(f"FAIL bulk_discount_total {s['bulk_discount_total']} want ~{expected_bulk:.2f}")
    sys.exit(1)
PY
}
