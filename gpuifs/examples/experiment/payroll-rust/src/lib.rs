//! Payroll arithmetic: integer cents, half-up rounding.

// ---- Money --------------------------------------------------------------

/// `n / d` rounded half away from zero, for n >= 0.
pub fn div_round(n: i64, d: i64) -> i64 {
    (n + d / 2) / d
}

/// Parses an optional sign, digits and an optional decimal point into
/// hundredths, rounded half up. `None` if it is not a number.
pub fn parse_hundredths(s: &str) -> Option<i64> {
    let s = s.trim();
    let (neg, s) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, s),
    };
    let (int, frac) = match s.split_once('.') {
        Some((i, f)) => (i, f),
        None => (s, ""),
    };
    if int.is_empty() && frac.is_empty() {
        return None;
    }
    if !int.bytes().all(|b| b.is_ascii_digit()) || !frac.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if int.len() > 12 {
        return Some(if neg { -1 } else { i64::MAX / 4 });
    }
    let whole: i64 = if int.is_empty() { 0 } else { int.parse().ok()? };
    let mut digits = frac.bytes().map(|b| (b - b'0') as i64);
    let d1 = digits.next().unwrap_or(0);
    let d2 = digits.next().unwrap_or(0);
    let d3 = digits.next().unwrap_or(0);
    let v = whole * 100 + d1 * 10 + d2 + if d3 >= 5 { 1 } else { 0 };
    Some(if neg { -v } else { v })
}

/// An amount: a number that may also carry a `$` and thousands commas.
pub fn parse_amount(s: &str) -> Option<i64> {
    let t = s.trim();
    let t = t.strip_prefix('$').unwrap_or(t);
    parse_hundredths(&t.replace(',', ""))
}

/// 1234567 -> "12,345.67"
pub fn fmt_num(h: i64) -> String {
    let int = (h / 100).to_string();
    let mut out = String::new();
    for (i, c) in int.chars().enumerate() {
        if i > 0 && (int.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    format!("{out}.{:02}", h % 100)
}

pub fn money(cents: i64) -> String {
    format!("${}", fmt_num(cents))
}

pub fn hours(h: i64) -> String {
    format!("{}.{:02}", h / 100, h % 100)
}

pub struct Pay {
    pub reg_h: i64,
    pub ot_h: i64,
    pub reg: i64,
    pub ot: i64,
    pub gross: i64,
    pub fed: i64,
    pub fica: i64,
    pub net: i64,
}

/// Hours in hundredths, rate in cents.
pub fn compute(h: i64, rate: i64) -> Pay {
    let (reg_h, ot_h) = if h > 4000 { (4000, h - 4000) } else { (h, 0) };
    let reg = div_round(reg_h * rate, 100);
    let ot = div_round(ot_h * rate * 3, 200);
    let gross = reg + ot;
    // 10% of the first $500 a week, 22% of the rest.
    let fed = if gross > 50000 {
        5000 + div_round((gross - 50000) * 22, 100)
    } else {
        div_round(gross * 10, 100)
    };
    let fica = div_round(gross * 765, 10000);
    Pay { reg_h, ot_h, reg, ot, gross, fed, fica, net: gross - fed - fica }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reference_run() {
        let p = compute(4500, 6250);
        assert_eq!((p.gross, p.fed, p.fica, p.net), (296875, 59313, 22711, 214851));
        let p = compute(3800, 7125);
        assert_eq!((p.gross, p.fed, p.fica, p.net), (270750, 53565, 20712, 196473));
        let p = compute(5200, 8800);
        assert_eq!((p.reg, p.ot, p.gross, p.fed, p.fica, p.net), (352000, 158400, 510400, 106288, 39046, 365066));
        assert_eq!(money(1078025), "$10,780.25");
        assert_eq!(money(0), "$0.00");
        assert_eq!(parse_amount("$1,250.00"), Some(125000));
        assert_eq!(parse_hundredths("abc"), None);
        assert_eq!(parse_hundredths(""), None);
    }
}
