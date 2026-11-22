# Payroll app: behavioral spec

Taken from the behavior of `gpuifs/examples/cobol/payroll.cob`. Both builds
(rc on gpuifs, and Rust on gpui + gpui-component) implement this, and both are
checked with the same capture script (below).

## Window

- Title `Payroll`, 820×600, minimum 640×480.
- Vertical layout, 20px padding, 14px gaps, theme background.

From top to bottom:

1. **Header**, one row, baseline-aligned: `ACME Widget Co.` (xl, semibold),
   then `Weekly payroll, computed in COBOL` (small, muted). The Rust and rc
   builds may say "computed in Rust" / "computed in rc".
2. **Form**, laid out horizontally, four fields:
   - `Employee`: text input, placeholder `Grace Hopper`
   - `Hours`: text input, placeholder `40`
   - `Rate per hour`: text input, placeholder `25.00`
   - a blank-labelled field holding a primary button `Run payroll`
3. **Body**, a row filling the rest of the window:
   - left, 300px wide: heading `Pay stub` (semibold) and a bordered,
     one-column description list (label / value rows)
   - right, filling the rest: heading `Register` (semibold), a striped table
     filling the height, and under it a small, right-aligned, muted total line

## Initial state

- Pay stub: one row, `Employee` → `-`.
- Register table: columns `Employee` (170px), `Hours` (70, right-aligned),
  `Rate` (80, right-aligned), `Net pay` (110, right-aligned); no rows.
- Total line: `No one paid yet.`
- Keyboard focus is in the Employee input.

## Running payroll

A run happens on any of: clicking **Run payroll**, pressing Enter in the form
(form submit), or Ctrl-Enter (Cmd-Enter on macOS) anywhere in the window.

Each run validates all three fields, every time, and sets or clears each
field's error message (shown under that field):

| Field | Condition | Error |
| --- | --- | --- |
| Employee | empty or only spaces | `Who are we paying?` |
| Hours | empty, or not a number | `Hours must be a number` |
| Hours | > 168 or ≤ 0 | `There are 168 hours in a week` |
| Rate | empty, or not an amount | `Rate must be an amount` |
| Rate | > 9999.99 or ≤ 0 | `Rate must be 0.01 to 9,999.99` |

- A number for Hours is an optional sign, digits, and an optional decimal
  point, with surrounding spaces allowed.
- An amount for Rate is the same, but may also carry a `$` and thousands
  commas (`$1,250.00`).
- Both are rounded half-up to 2 decimals.
- A field with no error shows no message. Inputs keep their text when any
  field has an error, and nothing else changes.

If all three are valid:

### Pay

- Regular hours = min(hours, 40); overtime hours = hours − 40 if over 40,
  else 0.
- Regular pay = regular hours × rate, rounded to cents.
- Overtime pay = overtime hours × rate × 1.5, rounded to cents.
- Gross = regular + overtime.
- Federal tax: 10% of gross if gross ≤ $500, else $50 + 22% of
  (gross − 500); rounded to cents.
- FICA = 7.65% of gross, rounded to cents.
- Net = gross − federal − FICA.
- Rounding is half away from zero; money is exact decimal (use integer
  cents, not floats).

### Pay stub (replaced on every successful run)

| Label | Value |
| --- | --- |
| `Employee` | the name, trimmed (at most 40 chars) |
| `Regular, 40.00 h` | `$2,500.00` |
| `Overtime, 5.00 h at 1.5` | `$468.75` |
| `Gross pay` | `$2,968.75` |
| `Federal tax` | `-$593.13` |
| `FICA, 7.65%` | `-$227.11` |
| `Net pay` | `$2,148.51` |

Hours print with two decimals and no leading zeros (`5.00`, `0.00`, `40.00`).
Money prints as `$` + thousands commas + two decimals (`$0.00`, `$2,968.75`).
Deductions get a leading `-`.

### Register

- A row is appended: name, hours (`45.00`), rate (`$62.50`), net
  (`$2,148.51`). At most 99 rows.
- Total line becomes `N paid. Gross $G, net $T.`, with N the row count and G,
  T running totals of gross and net (e.g. `3 paid. Gross $10,780.25, net
  $7,763.90.`).

### After a successful run

- All three inputs are cleared, all errors are gone, and focus returns to
  Employee.

## Reference run (the capture script)

1. Click **Run payroll** with the form empty → all three errors show.
2. Type `Grace Hopper` Tab `45` Tab `62.50` Enter.
3. Type `Alan Turing` Tab `38` Tab `71.25` Enter.
4. Type `Ada Lovelace` Tab `52` Tab `88` Enter.

Expected after each:

| Employee | Hours | Rate | Gross | Federal | FICA | Net |
| --- | --- | --- | --- | --- | --- | --- |
| Grace Hopper | 45.00 | $62.50 | $2,968.75 | $593.13 | $227.11 | $2,148.51 |
| Alan Turing | 38.00 | $71.25 | $2,707.50 | $535.65 | $207.12 | $1,964.73 |
| Ada Lovelace | 52.00 | $88.00 | $5,104.00 | $1,062.88 | $390.46 | $3,650.66 |

Final stub shows Ada Lovelace (Regular 40.00 h $3,520.00, Overtime 12.00 h
$1,584.00). Final total: `3 paid. Gross $10,780.25, net $7,763.90.`

## Closing

Closing the window quits the app.
