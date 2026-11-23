// The cases test/run.mjs runs: one per feature, on the example that uses
// it (or tour, for what no example uses). `renderers` limits a case to the
// renderers that draw that feature: the terminal renderer draws a subset
// (renderer/tui/README.md), so tables, sheets, sidebars and menus are
// GPUI's only.

const text = async (t, p) => (await t.ui.read(`win/main/${p}`)).trim();
const value = (t, p) => text(t, `${p}/value`);
const is = (t, what, p, want) => t.until(`${what} (${p} = ${want})`, async () => (await text(t, p)) === want);
const exited = (t, want) => t.until(`exit ${want}`, () => t.page.evaluate((w) => window.appExit === w, want));
const gpui = ['gpui'];

export const cases = [
  {
    app: 'counter', name: 'click, keys',
    async run(t) {
      await t.retry('count 1', () => t.click('inc'), async () => (await text(t, 'n/text')) === '1');
      await t.click('inc');
      await is(t, 'second click', 'n/text', '2');
      await t.press('Minus');
      await is(t, 'the - key', 'n/text', '1');
    },
  },
  {
    app: 'hello', name: 'type in an input, Enter submits',
    async run(t) {
      await t.ready('row/name');
      await t.click('row/name');
      await t.type('Ada');
      await t.until('value Ada', async () => (await value(t, 'row/name')) === 'Ada');
      await t.press('Enter');
      await is(t, 'greeting', 'out/text', 'Hello, Ada!');
    },
  },
  {
    app: 'confirm', name: 'Enter binding, the app quits with its status',
    async run(t) {
      await t.ready('bar/yes');
      await t.press('Enter');
      await exited(t, 0);
    },
  },
  {
    app: 'confirm', name: 'Escape binding, exit status',
    async run(t) {
      await t.ready('bar/no');
      await t.press('Escape');
      await t.until('a non-zero exit', () => t.page.evaluate(() => window.appExit > 0));
    },
  },
  {
    app: 'signin', name: 'field errors, secret input, dialog',
    async run(t) {
      await t.ready('f/go/submit');
      await t.retry('errors', () => t.click('f/go/submit'), async () => (await text(t, 'f/pass/error')) !== '');
      await t.click('f/user/in');
      await t.type('ada@example.com');
      await t.click('f/pass/in');
      await t.type('hunter2');
      await t.until('password value', async () => (await value(t, 'f/pass/in')) === 'hunter2');
      await t.click('f/go/submit');
      await is(t, 'dialog open', 'over/hi/open', 'on');
      await is(t, 'dialog text', 'over/hi/description', 'Signed in as ada@example.com');
      await t.click('over/hi/footer/ok');
      // The loop's read sees end of file when the app quits; rc's status is
      // the read's, so only the exit itself is checked.
      await t.until('the app exits', () => t.page.evaluate(() => window.appExit !== undefined));
    },
  },
  {
    app: 'settings', name: 'sidebar, switch, number-input', renderers: gpui,
    async run(t) {
      await t.ready('page/general/startup/rows/login');
      await t.retry('switch on', () => t.click('page/general/startup/rows/login'), async () => (await value(t, 'page/general/startup/rows/login')) === 'on');
      await t.click('page/general/lang/f/n/in', { fx: 0.97 });
      await t.until('number 11', async () => (await value(t, 'page/general/lang/f/n/in')) === '11');
      // Sidebar items are drawn from data, not as nodes of their own, so
      // they have no bounds to click by (README.md): the keys go there too.
      await t.press('Control+2');
      await is(t, 'page switched by its key', 'page/order', 'look');
    },
  },
  {
    app: 'settings', name: 'select popup, radio-group, slider, theme', renderers: gpui,
    async run(t) {
      await t.ready('nav');
      await t.retry('page switched', () => t.press('Control+2'), async () => (await text(t, 'page/order')) === 'look');
      await t.click('page/look/theme/f/radius/in', { fx: 0.995 });
      await t.until('slider at max', async () => (await value(t, 'page/look/theme/f/radius/in')) === '16');
      await t.until('radius token', async () => /radius 16/.test(await t.ui.read('theme/tokens')));
      // The group's box is the field's width; Dark is its second item, near the left.
      await t.click('page/look/theme/f/mode/in', { fx: 0.22 });
      await t.until('dark mode', async () => (await t.ui.read('theme/mode')).trim() === 'dark');
      await t.click('page/look/theme/f/name/in');
      await t.wait(500);
      await t.press('ArrowDown');
      await t.press('ArrowDown');
      await t.press('Enter');
      await t.until('a theme picked', async () => (await value(t, 'page/look/theme/f/name/in')) !== 'Default');
    },
  },
  {
    app: 'csvview', name: 'table, filter as you type, sheet', renderers: gpui,
    async run(t) {
      await t.ready('top/q');
      await is(t, 'rows', 'st/left/text', '10 rows');
      await t.click('top/q');
      await t.type('giant');
      await is(t, 'filtered', 'st/left/text', '4 of 10 rows');
      const [, , , h] = await t.node('t');
      await t.click('t', { fy: 60 / h, fx: 0.1, count: 2 });
      await is(t, 'sheet open', 'over/card/open', 'on');
    },
  },
  {
    app: 'files', name: 'tree, context menu, alert dialog', renderers: gpui,
    async run(t) {
      const T = 'split/right/v/list';
      await t.ready(T);
      await t.until('dirs listed', async () => (await t.ui.read(`win/main/split/left/dirs/items`)).trim() !== '');
      const [, , , h] = await t.node(T);
      await t.click(T, { fy: 50 / h, fx: 0.1 });
      await t.click(T, { fy: 50 / h, fx: 0.1, button: 'right' });
      await is(t, 'context menu', 'over/menu/open', 'on');
      // Its items aren't nodes either: Delete is the second row of the
      // menu, which opens at the pointer.
      const [x, y, w] = await t.node(T);
      await t.page.mouse.click(x + w * 0.1 + 40, y + 50 + 42);
      await is(t, 'alert dialog', 'over/del/open', 'on');
      await t.press('Escape');
      await is(t, 'alert dialog closed', 'over/del/open', 'off');
    },
  },
];
