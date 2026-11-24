#!/usr/bin/env python3
"""expenses.py: a small expense tracker. Add what you spent, see it in a
table and a chart by category, delete a row, and it all keeps in
/tmp/expenses.txt, so a run leaves nothing in the directory it ran in.

    uitree -t Expenses -d ALPINE:#L python3 expenses.py

CPython from an Alpine tree, run by h9's Linux ABI, with the tree at $ui.
No network and no packages: os and the event loop's line.split().

Shows: a form with labels=top and dir=col, field errors, a select whose
items are plain words, the form's tag inherited by its inputs (Enter in
any of them submits), the table's rows and the chart's data rewritten as
here-values in one ctl write, so the table, chart and totals always change
together, row selection read from the select event, keys.   Needs: M3
"""
import os
import time

UI = os.environ.get("ui", "/mnt/ui")
WIN = "win/main"
DB = "/tmp/expenses.txt"
CATS = ["Food", "Transport", "Home", "Fun", "Health", "Other"]

SCREEN = """\
div root  : h-flex items-stretch size-full bg=background
  div side  : v-flex w=300 p=20 gap=16 border-r-1 border-color=border
    text h  text='Add an expense'  : text-lg font-semibold
    form f  labels=top  dir=col  tag=add
      field what  label=What
        input in  placeholder='Coffee beans'
      field amount  label=Amount
        input in  placeholder=12.50
      field cat  label=Category
        select in  value=Food
      field go
        button add  label=Add  icon=plus  primary  : w-full
    separator s
    description-list totals  bordered  columns=1
  div main  : v-flex flex-1 p=20 gap=16
    div head  : h-flex items-center gap=8
      text h  text=Spending  : text-lg font-semibold flex-1
      button del  label='Delete row'  icon=trash  disabled  tag=del  ghost sm
    chart bycat  kind=bar  x=category  y=amount  : h=200
    table rows  stripe  sortable  sorted  selectable=row  tag=pick  : flex-1
"""


def put(path, data):
    """One open, one write, one close: a ctl applies its lines at close."""
    with open(f"{UI}/{path}", "w") as f:
        f.write(data)


def get(path):
    with open(f"{UI}/{path}") as f:
        return f.read().strip()


def q(s):
    """Plan 9 quoting, only where it is needed."""
    s = str(s)
    return s if s and not any(c in s for c in " \t'=") else "'" + s.replace("'", "''") + "'"


def ctl(*lines):
    put(f"{WIN}/ctl", "\n".join(lines) + "\n")


def load():
    rows = []
    if os.path.exists(DB):
        with open(DB) as f:
            for line in f:
                day, cat, amount, what = line.rstrip("\n").split("\t", 3)
                rows.append([day, cat, float(amount), what])
    return rows


def save(rows):
    with open(DB, "w") as f:
        for day, cat, amount, what in rows:
            f.write(f"{day}\t{cat}\t{amount:.2f}\t{what}\n")


def show(rows, sel=None):
    """Table, chart and totals, as one ctl write."""
    by = {c: 0.0 for c in CATS}
    for _, cat, amount, _ in rows:
        by[cat] = by.get(cat, 0.0) + amount
    total = sum(by.values())
    ctl(
        "set main/rows rows=<<END",
        *(f"r{i} {q(what)} {cat} {day} {amount:.2f}" for i, (day, cat, amount, what) in enumerate(rows)),
        "END",
        "set main/bycat data=<<END",
        "category amount",
        *(f"{c} {by[c]:.2f}" for c in CATS),
        "END",
        "set side/totals items=<<END",
        f"Total {total:.2f}",
        f"Entries {len(rows)}",
        f"Biggest {q(max(by, key=by.get) if total else '-')}",
        "END",
        f"set main/head/del disabled={'off' if sel is not None else 'on'}",
    )


def add(rows):
    what = get(f"{WIN}/side/f/what/in/value")
    amount = get(f"{WIN}/side/f/amount/in/value").lstrip("$")
    cat = get(f"{WIN}/side/f/cat/in/value") or "Other"
    err_what = "" if what else "What was it?"
    try:
        value = float(amount)
        err_amount = "" if 0 < value < 1e7 else "More than zero, please"
    except ValueError:
        value, err_amount = 0, "A number, like 12.50"
    lines = [f"set side/f/what error={q(err_what)}", f"set side/f/amount error={q(err_amount)}"]
    if not err_what and not err_amount:
        rows.append([time.strftime("%Y-%m-%d"), cat, value, what])
        save(rows)
        lines += ["set side/f/what/in value=", "set side/f/amount/in value=", "set . focus=side/f/what/in"]
    ctl(*lines)
    return not (err_what or err_amount)


def main():
    rows = load()
    ctl("set . title=Expenses size=980,620 min=760,480 pos=center")
    put(f"{WIN}/tree", SCREEN)
    put(f"{WIN}/side/f/cat/in/items", "".join(f"{c} {c}\n" for c in CATS))
    put(f"{WIN}/main/rows/columns", "what What 260 sort\ncat Category 120 sort\nday Date 120 sort\namount Amount 100 sort align=right\n")
    put("keys", "cmd-backspace del\n")
    put(f"{WIN}/focus", "side/f/what/in")
    show(rows)
    sel = None
    with open(f"{UI}/events") as ev:
        for line in ev:
            name, key, path, *rest = line.split()
            attrs = dict(w.split("=", 1) for w in rest if "=" in w)
            if name in ("click", "submit") and key == "add":
                if add(rows):
                    sel = None
                    show(rows)
            elif name == "select" and key == "pick":
                row = attrs.get("row", "")
                sel = int(row[1:]) if row.startswith("r") else None
                ctl(f"set main/head/del disabled={'off' if sel is not None else 'on'}")
            elif name in ("click", "action") and key == "del" and sel is not None and sel < len(rows):
                del rows[sel]
                save(rows)
                sel = None
                show(rows)


if __name__ == "__main__":
    main()
