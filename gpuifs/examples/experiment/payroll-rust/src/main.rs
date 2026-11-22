//! Weekly payroll for a small firm, in Rust on GPUI and GPUI Kit's
//! components. The behavior follows gpuifs/examples/cobol/payroll.cob:
//! time over 40 hours at time and a half, a made-up tax table, a pay stub
//! and a register. Money is integer cents.

use gpui_kit::{
    component::{
        ActiveTheme, StyledExt,
        button::{Button, ButtonVariants},
        description_list::{DescriptionItem, DescriptionList},
        form::{Field, Form},
        h_flex,
        input::{Input, InputEvent, InputState},
        table::{Table, TableBody, TableCell, TableHead, TableHeader, TableRow},
        v_flex,
    },
    *,
};

use payroll::{compute, hours, money, parse_amount, parse_hundredths};

actions!(payroll, [Run]);

// ---- The window ---------------------------------------------------------

struct Row {
    name: String,
    hours: i64,
    rate: i64,
    net: i64,
}

struct Payroll {
    focus: FocusHandle,
    name: Entity<InputState>,
    hours: Entity<InputState>,
    rate: Entity<InputState>,
    errors: [Option<&'static str>; 3],
    stub: Vec<(String, String)>,
    register: Vec<Row>,
    total_gross: i64,
    total_net: i64,
    _subs: Vec<Subscription>,
}

impl Payroll {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let name = cx.new(|cx| InputState::new(window, cx).placeholder("Grace Hopper"));
        let hours = cx.new(|cx| InputState::new(window, cx).placeholder("40"));
        let rate = cx.new(|cx| InputState::new(window, cx).placeholder("25.00"));
        let subs = [&name, &hours, &rate]
            .into_iter()
            .map(|e| {
                cx.subscribe_in(e, window, |this, _, ev: &InputEvent, window, cx| {
                    if let InputEvent::PressEnter { .. } = ev {
                        this.run(window, cx);
                    }
                })
            })
            .collect();
        name.update(cx, |s, cx| s.focus(window, cx));
        Self {
            focus: cx.focus_handle(),
            name,
            hours,
            rate,
            errors: [None; 3],
            stub: vec![("Employee".into(), "-".into())],
            register: Vec::new(),
            total_gross: 0,
            total_net: 0,
            _subs: subs,
        }
    }

    fn run(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let name = self.name.read(cx).value().trim().to_string();
        let hrs = self.hours.read(cx).value().to_string();
        let rate = self.rate.read(cx).value().to_string();

        self.errors[0] = name.is_empty().then_some("Who are we paying?");
        let h = match parse_hundredths(&hrs) {
            None => Err("Hours must be a number"),
            Some(h) if h <= 0 || h > 16800 => Err("There are 168 hours in a week"),
            Some(h) => Ok(h),
        };
        let r = match parse_amount(&rate) {
            None => Err("Rate must be an amount"),
            Some(r) if r <= 0 || r > 999999 => Err("Rate must be 0.01 to 9,999.99"),
            Some(r) => Ok(r),
        };
        self.errors[1] = h.err();
        self.errors[2] = r.err();

        if let (false, Ok(h), Ok(r)) = (name.is_empty(), h, r) {
            let name: String = name.chars().take(40).collect();
            let p = compute(h, r);
            self.stub = vec![
                ("Employee".into(), name.clone()),
                (format!("Regular, {} h", hours(p.reg_h)), money(p.reg)),
                (format!("Overtime, {} h at 1.5", hours(p.ot_h)), money(p.ot)),
                ("Gross pay".into(), money(p.gross)),
                ("Federal tax".into(), format!("-{}", money(p.fed))),
                ("FICA, 7.65%".into(), format!("-{}", money(p.fica))),
                ("Net pay".into(), money(p.net)),
            ];
            if self.register.len() < 99 {
                self.register.push(Row { name, hours: h, rate: r, net: p.net });
            }
            self.total_gross += p.gross;
            self.total_net += p.net;
            for input in [&self.name, &self.hours, &self.rate] {
                input.update(cx, |s, cx| s.set_value("", window, cx));
            }
            self.name.update(cx, |s, cx| s.focus(window, cx));
        }
        cx.notify();
    }

    fn field(&self, label: &str, input: &Entity<InputState>, err: Option<&'static str>, cx: &App) -> Field {
        Field::new().label(label.to_string()).child(
            v_flex()
                .gap_1()
                .child(Input::new(input))
                .children(err.map(|e| div().text_sm().text_color(cx.theme().danger).child(e))),
        )
    }
}

impl Render for Payroll {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let total = if self.register.is_empty() {
            "No one paid yet.".to_string()
        } else {
            format!(
                "{} paid. Gross {}, net {}.",
                self.register.len(),
                money(self.total_gross),
                money(self.total_net)
            )
        };
        let head = |w: f32, right: bool, s: &'static str| {
            let h = TableHead::new().w(px(w)).child(s);
            if right { h.text_right() } else { h }
        };
        let cell = |w: f32, right: bool, s: String| {
            let c = TableCell::new().w(px(w)).child(s);
            if right { c.text_right() } else { c }
        };

        v_flex()
            .id("root")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &Run, window, cx| this.run(window, cx)))
            .size_full()
            .p(px(20.))
            .gap(px(14.))
            .bg(theme.background)
            .child(
                h_flex()
                    .items_baseline()
                    .gap(px(10.))
                    .child(div().text_xl().font_semibold().child("ACME Widget Co."))
                    .child(
                        div()
                            .text_sm()
                            .text_color(theme.muted_foreground)
                            .child("Weekly payroll, computed in Rust"),
                    ),
            )
            .child(
                Form::new()
                    .columns(4)
                    .child(self.field("Employee", &self.name, self.errors[0], cx))
                    .child(self.field("Hours", &self.hours, self.errors[1], cx))
                    .child(self.field("Rate per hour", &self.rate, self.errors[2], cx))
                    .child(
                        Field::new().label(" ").child(
                            Button::new("run")
                                .primary()
                                .label("Run payroll")
                                .on_click(cx.listener(|this, _, window, cx| this.run(window, cx))),
                        ),
                    ),
            )
            .child(
                h_flex()
                    .flex_1()
                    .gap(px(14.))
                    .items_stretch()
                    .child(
                        v_flex()
                            .gap(px(8.))
                            .w(px(300.))
                            .child(div().font_semibold().child("Pay stub"))
                            .child(
                                DescriptionList::new().columns(1).bordered(true).children(
                                    self.stub
                                        .iter()
                                        .map(|(l, v)| DescriptionItem::new(l.clone()).value(v.clone())),
                                ),
                            ),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .gap(px(8.))
                            .child(div().font_semibold().child("Register"))
                            .child(
                                div().flex_1().child(
                                    Table::new()
                                        .child(TableHeader::new().child(
                                            TableRow::new()
                                                .child(head(170., false, "Employee"))
                                                .child(head(70., true, "Hours"))
                                                .child(head(80., true, "Rate"))
                                                .child(head(110., true, "Net pay")),
                                        ))
                                        .child(TableBody::new().children(
                                            self.register.iter().enumerate().map(|(i, r)| {
                                                let row = TableRow::new()
                                                    .child(cell(170., false, r.name.clone()))
                                                    .child(cell(70., true, hours(r.hours)))
                                                    .child(cell(80., true, money(r.rate)))
                                                    .child(cell(110., true, money(r.net)));
                                                if i % 2 == 1 { row.bg(theme.table_even) } else { row }
                                            }),
                                        )),
                                ),
                            )
                            .child(
                                div()
                                    .text_sm()
                                    .text_right()
                                    .text_color(theme.muted_foreground)
                                    .child(total),
                            ),
                    ),
            )
    }
}

fn main() {
    gpui_kit::application().run(|cx| {
        gpui_kit::init(cx);
        // Cmd-Enter on macOS, Ctrl-Enter elsewhere.
        let run_key = if cfg!(target_os = "macos") { "cmd-enter" } else { "ctrl-enter" };
        cx.bind_keys([KeyBinding::new(run_key, Run, None)]);
        let bounds = Bounds::centered(None, size(px(820.), px(600.)), cx);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            window_min_size: Some(size(px(640.), px(480.))),
            titlebar: Some(TitlebarOptions { title: Some("Payroll".into()), ..Default::default() }),
            ..Default::default()
        };
        gpui_kit::open_window(options, cx, |window, cx| cx.new(|cx| Payroll::new(window, cx)))
            .expect("failed to open window");
        cx.on_window_closed(|cx, _| cx.quit()).detach();
    });
}
