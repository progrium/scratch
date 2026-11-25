// The component gallery's stories (index.html, gallery.js): one per
// component, each a few sections of variations. A section's `ui` is a
// piece of a tree document (protocols/core.md § Documents), indented from
// zero; gallery.js puts it under a labeled box. `files` are written after
// the tree, at paths under the section's box ('more/menu' is the menu
// file of the node `more` in it), and `over` is lines for the window's
// over/ctl, made once the tree is in: `$0/` in them is the path of
// section 0's box, for an overlay's anchor.
//
// Buttons tagged `open:NAME`, `close:NAME` or `toast:TYPE` are wired by
// the page: they open or close the overlay NAME, or post a notification.
//
// Every type in core/types has a story here. Which ones a renderer draws
// is what its `$ui/types` lists: a section with a type the renderer
// doesn't build is shown as a note instead.

// Charts take TSV with a header row.
const months = 'month\tvisits\nJan\t120\nFeb\t180\nMar\t150\nApr\t240\nMay\t310\nJun\t280\n';
const sales = 'quarter\tnorth\nQ1\t42\nQ2\t55\nQ3\t48\nQ4\t70\n';
const fruit = 'apple Apple icon=apple\nbanana Banana\ncherry Cherry\n-\ndurian Durian disabled\n';
const langs = '# Systems\nc C\nrust Rust\nzig Zig\n# Scripting\nrc rc\nawk awk\npy Python\n';
const menu = 'item copy  label=Copy  key=cmd-c\nitem paste  label=Paste  key=cmd-v\nsep\nitem rename  label=Rename…\nitem del  label=Delete\n';
const tableCols = 'name Name 160 sort\nlang Language 110 sort\nyear Year 70 sort align=right\nby Author 220\n';
const tableRows = [
  "1 rc rc 1990 'Tom Duff'",
  "2 awk awk 1977 'Aho, Weinberger, Kernighan'",
  "3 sam C 1987 'Rob Pike'",
  "4 acme C 1994 'Rob Pike'",
  "5 Go Go 2009 'Griesemer, Pike, Thompson'",
  "6 GPUI Rust 2023 'Zed Industries'",
].join('\n') + '\n';
const treeItems = [
  'src - src icon=folder',
  'src/main src main.rs icon=file',
  'src/tree src tree.rs icon=file',
  'src/ninep src ninep icon=folder',
  'src/ninep/msg src/ninep msg.rs icon=file',
  'docs - docs icon=folder',
  'docs/design docs DESIGN.md icon=file',
].join('\n') + '\n';
const code = `use std::sync::Arc;

fn main() {
    let tree = Arc::new(Tree::new());
    let snapshot = tree.snapshot();
    println!("{} nodes", snapshot.len())
}
`;
const md = `# Markdown

Rendered with **bold**, *italic*, \`code\` and [a link](https://example.com/uitree).

- Any language with file I/O
- \`cat\` shows what is on screen

> A quote, for good measure.

\`\`\`rc
echo 'set out text=hi' >$ui/win/main/ctl
\`\`\`
`;
const messages = `m1 user 09:41
Can a terminal be a **node**?

m2 assistant 09:41
Yes: \`terminal\` draws a program's output as cells, in stream or pty mode.

m3 user 09:42
And the screen is the same on every renderer?

m4 assistant 09:42
The core parses the output, so \`screen\` reads the same everywhere.
`;
// ANSI for the terminal story: colors, styles and a box, as a program would write them.
const E = '\x1b[';
const ansi = [
  `${E}1mterminal${E}0m: bytes written to ${E}4mout${E}0m are drawn as cells\r\n`,
  '\r\n',
  [30, 31, 32, 33, 34, 35, 36, 37].map((c) => `${E}${c + 10}m  ${E}0m`).join('') + '  normal\r\n',
  [90, 91, 92, 93, 94, 95, 96, 97].map((c) => `${E}${c + 10}m  ${E}0m`).join('') + '  bright\r\n',
  Array.from({ length: 24 }, (_, i) => `${E}48;2;${Math.round(255 - i * 10)};${Math.round(80 + i * 7)};${Math.round(40 + i * 9)}m ${E}0m`).join('') + '  24-bit\r\n',
  '\r\n',
  `${E}1mbold${E}0m ${E}2mfaint${E}0m ${E}3mitalic${E}0m ${E}4munderline${E}0m ${E}4:3mcurly${E}0m ${E}9mstrike${E}0m ${E}7minverse${E}0m\r\n`,
  '\r\n',
  '┌──────────────┐\r\n│ ┃ box drawing │\r\n└──────────────┘\r\n',
  `${E}32m$${E}0m ls --color\r\n${E}1;34mcore${E}0m  ${E}1;34mrenderer${E}0m  ${E}1;34mweb${E}0m  README.md  ${E}1;32mbuild.sh${E}0m\r\n${E}32m$${E}0m `,
].join('');
const ops = [
  'rect bg 0 0 320 160 fill=muted',
  'rect card 16 16 120 72 fill=background stroke=border',
  'text lbl 28 44 Revenue size=13',
  'circle a 200 60 28 fill=primary',
  'circle b 250 100 18 fill=chart-2 hover:fill=chart-3',
  'path spark M16,140 L60,118 L104,128 L148,96 L192,110 L236,80 L300,90 stroke=chart-1 width=2',
  'path tri M260,20 L300,20 L280,50 Z fill=chart-4',
].join('\n') + '\n';
const html = `<h3>HTML</h3>
<p>A <b>subset</b> of HTML, drawn natively: <i>emphasis</i>, <code>code</code>, <a href="https://example.com/uitree">links</a>.</p>
<ul><li>lists</li><li>and tables</li></ul>
<table><tr><th>Type</th><th>Profile</th></tr><tr><td>button</td><td>form</td></tr><tr><td>terminal</td><td>desktop</td></tr></table>
`;
const page = `<!doctype html><style>body{font:14px system-ui;margin:16px;background:#f4f7ff;color:#123}button{font:inherit}</style>
<h3 style="margin:0 0 8px">An inline page</h3>
<p>A <code>web</code> node: a page among native nodes.</p>
<button onclick="uitree.post('hello from the page')">uitree.post()</button>
`;
const oldSrc = 'fn greet(name: &str) {\n    println!("Hello, {}", name);\n}\n\nfn main() {\n    greet("world");\n}\n';
const newSrc = 'fn greet(name: &str) -> String {\n    format!("Hello, {name}!")\n}\n\nfn main() {\n    println!("{}", greet("world"));\n}\n';
const sizes = (type, extra = '') => ['xs', 'sm', 'md', 'lg'].map((s) => `${type} ${s}  ${s === 'md' ? '' : s}  ${extra.replaceAll('$s', s)}`).join('\n');
const range = (n, f) => Array.from({ length: n }, (_, i) => f(i)).join('\n');

export const groups = [
  ['core', 'Core'], ['form', 'Form'], ['data', 'Data'], ['overlay', 'Overlay'], ['nav', 'Navigation'],
  ['layout', 'Layout'], ['feedback', 'Feedback'], ['text', 'Text & code'], ['desktop', 'Desktop & web'], ['theme', 'Theme'],
];

export const stories = [
  // core
  {
    id: 'text', group: 'core', title: 'Text', desc: 'Plain text with style words: size, weight, color, emphasis, truncation.',
    sections: [
      { label: 'Sizes and weights', col: true, ui: `
text a  text='Extra small, muted'  : text-xs text-color=muted-foreground
text b  text='Small text'  : text-sm
text c  text='Base text, the default'
text d  text='Large and semibold'  : text-lg font-semibold
text e  text='Extra large and bold'  : text-xl font-bold` },
      { label: 'Emphasis and color', ui: `
text a  text=Italic  : italic
text b  text=Underline  : underline
text c  text=Strike  : line-through
text d  text=Light  : font-light
text e  text=Primary  : text-color=primary font-semibold
text f  text=Danger  : text-color=danger
text g  text=Success  : text-color=success` },
      { label: 'Truncate and select', col: true, ui: `
text a  truncate  text='A long line that does not fit in its box is cut short with an ellipsis at the end'  : w=280
text b  selectable  text='Selectable: drag across me to select'` },
    ],
  },
  {
    id: 'styled-text', group: 'core', title: 'Styled text', desc: 'One text with styled runs: byte ranges and the words for each.',
    sections: [
      { label: 'Runs', ui: `
styled-text s  text='Error: file not found (exit 2), see the log'`, files: { 's/runs': '0 6 font-bold text-color=danger\n7 14 italic\n16 6 bg=muted\n28 3 underline text-color=primary\n' } },
    ],
  },
  {
    id: 'icon', group: 'core', title: 'Icon', desc: 'GPUI Kit icons by name, at four sizes and in theme colors.',
    sections: [
      { label: 'Icons', ui: ['search', 'bell', 'inbox', 'folder', 'file', 'settings', 'user', 'trash', 'plus', 'check', 'play', 'pause', 'send', 'palette', 'terminal', 'upload', 'undo', 'refresh-cw', 'layout-grid', 'layout-dashboard'].map((n, i) => `icon i${i}  name=${n}  tooltip=${n}  : size=20`).join('\n') },
      { label: 'Sizes', ui: [['xs', 12], ['sm', 16], ['md', 20], ['lg', 24]].map(([w, n]) => `icon ${w}  ${w}  name=star  : size=${n}`).join('\n') },
      { label: 'Colors', ui: `
icon a  name=check  : size=20 text-color=success
icon b  name=bell  : size=20 text-color=warning
icon c  name=trash  : size=20 text-color=danger
icon d  name=star  : size=20 text-color=info` },
    ],
  },
  {
    id: 'img', group: 'core', title: 'Image and SVG', desc: 'img from bytes the app writes (scale= for its logical size); svg from an asset the app wrote.',
    assets: { star: 'assets/icons/star.svg', heart: 'assets/icons/heart.svg' },
    sections: [
      { label: 'img data, scale 1 and 2', ui: `
img a  : size=64
img b  scale=2
img c  : size=32` , bytes: { 'a/data': 'apps/tour/pic.png', 'b/data': 'apps/tour/pic.png', 'c/data': 'apps/tour/pic.png' } },
      { label: 'svg, from an asset ($ui/asset/NAME, src=@NAME)', ui: `
svg s  src=@star  : size=32 text-color=info
svg t  src=@heart  : size=32 text-color=danger` },
    ],
  },
  {
    id: 'div', group: 'core', title: 'Div, scroll and spacer', desc: 'The layout elements: flex boxes, a scroll view, and a spacer that takes the free room.',
    sections: [
      { label: 'Flex row with a spacer', full: true, ui: `
div row  : h-flex items-center gap=8 p=8 border-1 border-color=border rounded-md
  text l  text=Left
  spacer s
  text r  text=Right` },
      { label: 'Boxes', ui: `
div a  : size=48 bg=primary rounded-md
div b  : size=48 bg=secondary border-1 border-color=border rounded-md
div c  : size=48 bg=accent rounded-full
div d  : w=96 h=48 bg=muted rounded-md items-center justify-center flex
  text t  text=centered  : text-xs` },
      { label: 'Scroll', full: true, ui: `
scroll sc  : h=96 overflow-y-scroll border-1 border-color=border rounded-md
  div v  : v-flex px=8
${range(12, (i) => `    text t${i}  text='Row ${i + 1}'`)}` },
    ],
  },
  {
    id: 'canvas', group: 'core', title: 'Canvas', desc: 'A retained display list (ops): rects, circles, paths and text, with hover attributes.',
    sections: [{ label: 'Ops', ui: 'canvas c  : w=320 h=160', files: { 'c/ops': ops } }],
  },

  // form
  {
    id: 'button', group: 'form', title: 'Button', desc: 'Variants, sizes, icons and states.',
    sections: [
      { label: 'Variants', ui: ['primary', 'secondary', 'danger', 'info', 'success', 'warning', 'outline', 'ghost', 'link'].map((v) => `button ${v}  label=${v[0].toUpperCase() + v.slice(1)}  ${v}`).join('\n') },
      { label: 'Sizes', ui: sizes('button', 'label=$s  primary') },
      { label: 'States', ui: `
button icon  label=Search  icon=search
button only  icon=settings  ghost  tooltip=Settings
button load  loading  label=Saving
button off  disabled  label=Disabled
button sel  selected  outline  label=Selected` },
    ],
  },
  {
    id: 'button-group', group: 'form', title: 'Button group, toggle, dropdown', desc: 'Joined buttons with a value, toggles, and a button with a menu.',
    sections: [
      { label: 'Button group', ui: `
button-group g  value=b
  button a  label=Day
  button b  label=Week
  button c  label=Month
button-group m  multiple  value='b i'  outline
  button b  icon=bold
  button i  icon=italic
  button u  icon=underline` },
      { label: 'Toggle', ui: `
toggle a  label=Bold  icon=bold
toggle b  label=Pinned  value=on
toggle c  label=Ghost  ghost
toggle d  label=Outline  outline  value=on
toggle e  label=Off  disabled` },
      { label: 'Dropdown button', ui: `
dropdown-button d  label=More
dropdown-button p  label=Actions  primary
dropdown-button o  icon=settings  outline`, files: { 'd/menu': menu, 'p/menu': menu, 'o/menu': menu } },
    ],
  },
  {
    id: 'checkbox', group: 'form', title: 'Checkbox, switch, radio', desc: 'Binary, tri-state and one-of choices.',
    sections: [
      { label: 'Checkbox', ui: `
checkbox a  label=Off
checkbox b  label=On  value=on
checkbox c  label=Mixed  value=mixed
checkbox d  disabled  label=Disabled` },
      { label: 'Checkbox sizes', ui: sizes('checkbox', 'label=$s  value=on') },
      { label: 'Switch', ui: `
switch a  label=Off
switch b  label=On  value=on
switch c  disabled  label=Disabled
switch s  sm  label=Small  value=on
switch l  lg  label=Large  value=on` },
      { label: 'Radio group, column and row', ui: `
radio-group a  value=md
radio-group b  value=lg  dir=row
radio-group c  value=sm  disabled`, files: { 'a/items': 'sm Small\nmd Medium\nlg Large\n', 'b/items': 'sm Small\nmd Medium\nlg Large\n', 'c/items': 'sm Small\nmd Medium\nlg Large\n' } },
    ],
  },
  {
    id: 'input', group: 'form', title: 'Input', desc: 'Text, secrets, masks, slots, sizes and states.',
    sections: [
      { label: 'Kinds', col: true, ui: `
input plain  placeholder='Type something'  : w=320
input search  cleanable  placeholder=Search…  : w=320
  icon prefix  name=search
input pw  secret  value=hunter2  : w=320
input phone  placeholder='(000) 000-0000'  mask='(999) 999-9999'  : w=320
input url  placeholder=example.com  : w=320
  text prefix  text=https://  : text-color=muted-foreground` },
      { label: 'Sizes', col: true, ui: sizes('input', "placeholder=$s  : w=320") },
      { label: 'States', col: true, ui: `
input ro  readonly  value='Read only'  : w=320
input off  disabled  value=Disabled  : w=320` },
    ],
  },
  {
    id: 'textarea', group: 'form', title: 'Textarea', desc: 'Multi-line text: rows, auto-grow, read-only.',
    sections: [
      { label: 'Rows', col: true, ui: `
textarea a  placeholder='Three rows…'  rows=3  : w=360
textarea b  placeholder='Grows from 2 to 6 rows'  auto-grow=2,6  : w=360
textarea c  readonly  rows=2  : w=360`, files: { 'c/value': 'Read only,\nacross two lines.' } },
    ],
  },
  {
    id: 'number-input', group: 'form', title: 'Number input, OTP', desc: 'Steppers with bounds, and one-time codes.',
    sections: [
      { label: 'Number input', ui: `
number-input a  value=3  min=0  max=10  : w=160
number-input b  value=2.5  step=0.5  : w=160
number-input c  disabled  value=7  : w=160` },
      { label: 'OTP input', col: true, ui: `
otp-input a  length=6
otp-input b  length=4  secret  value=12` },
    ],
  },
  {
    id: 'select', group: 'form', title: 'Select, combobox', desc: 'Single choice, searchable with groups, and multi-select.',
    sections: [
      { label: 'Select', ui: `
select a  placeholder='Pick a fruit'  : w=220
select b  searchable  placeholder=Language  : w=220
select c  value=banana  disabled  : w=220`, files: { 'a/items': fruit, 'b/items': langs, 'c/items': fruit } },
      { label: 'Combobox', ui: `
combobox a  placeholder=Fruit  : w=220
combobox b  multiple  placeholder=Tags  value='bug docs'  : w=260`, files: { 'a/items': fruit, 'b/items': "bug bug\nfeature feature\ndocs docs\ngood 'good first issue'\n" } },
      { label: 'Sizes', ui: sizes('select', 'placeholder=$s  : w=140'), files: Object.fromEntries(['xs', 'sm', 'md', 'lg'].map((s) => [`${s}/items`, fruit])) },
    ],
  },
  {
    id: 'slider', group: 'form', title: 'Slider, rating', desc: 'Values and ranges, vertical, stepped; star ratings.',
    sections: [
      { label: 'Slider', col: true, ui: `
slider a  value=40  : w=320
slider b  value='20 80'  : w=320
slider c  min=0  max=10  step=2  value=4  : w=320
slider d  disabled  value=60  : w=320` },
      { label: 'Vertical', ui: `
slider v  dir=col  value=30  : h=120
slider w  dir=col  value='25 75'  : h=120` },
      { label: 'Rating', col: true, ui: `
rating a  value=3
rating b  max=10  value=7  sm
rating c  value=4  disabled  lg` },
    ],
  },
  {
    id: 'form', group: 'form', title: 'Form and field', desc: 'Fields with labels, descriptions, required marks and errors; labels on top or at the side.',
    sections: [
      { label: 'Labels on top', full: true, ui: `
form f  : max-w=420
  field name  required  label=Name  description='As on your passport.'
    input in  placeholder='Ada Lovelace'
  field mail  label=Email  error='Not an email address'
    input in  value=ada@
  field plan  label=Plan
    select in  value=pro`, files: { 'f/plan/in/items': 'free Free\npro Pro\nteam Team\n' } },
      { label: 'Labels at the side', full: true, ui: `
form g  labels=side  label-width=100  : max-w=420
  field a  label=Host
    input in  value=localhost
  field b  label=Port
    number-input in  value=8000
  field c  label=TLS
    switch in  value=on` },
    ],
  },
  {
    id: 'date-picker', group: 'form', title: 'Date picker, calendar', desc: 'A picker, a range with presets, and an inline calendar.',
    sections: [
      { label: 'Date picker', ui: `
date-picker a  value=2026-11-25  : w=220
date-picker b  range  value='2026-11-01 2026-11-30'  presets=on  : w=280
date-picker c  placeholder='No date'  : w=220` },
      { label: 'Calendar', ui: `
calendar c  value=2026-11-25
calendar r  range  value='2026-11-10 2026-11-14'` },
    ],
  },
  {
    id: 'color-picker', group: 'form', title: 'Color picker', desc: 'A color value with swatches.',
    sections: [{ label: 'Color picker', ui: `
color-picker a  value=#0b5cffff
color-picker b  value=#e5484dff  sm
color-picker c  value=#30a46cff  lg` }],
  },

  // data
  {
    id: 'table', group: 'data', title: 'Table', desc: 'Columns and rows from data files: stripes, borders, sorting, selection, sizes.',
    sections: [
      { label: 'Striped, sortable, resizable', full: true, ui: 'table t  stripe  sortable  resizable  selectable=row  : h=230', files: { 't/columns': tableCols, 't/rows': tableRows } },
      { label: 'Small, no border, cell selection', full: true, ui: 'table s  sm  bordered=off  selectable=cell  : h=200', files: { 's/columns': tableCols, 's/rows': tableRows } },
      { label: 'Loading', full: true, ui: 'table l  loading  : h=120', files: { 'l/columns': tableCols } },
    ],
  },
  {
    id: 'list', group: 'data', title: 'List, virtual list', desc: 'Items with groups and icons; selectable and searchable; ten thousand rows virtualized.',
    sections: [
      { label: 'List', ui: `
list a  selectable  value=rust  : w=220 h=220 border-1 border-color=border rounded-md
list b  searchable  selectable  : w=220 h=220 border-1 border-color=border rounded-md`, files: { 'a/items': langs, 'b/items': fruit } },
      { label: 'Virtual list (10,000 items)', full: true, ui: 'virtual-list v  selectable  item-size=28  : h=200 border-1 border-color=border rounded-md', files: { 'v/items': range(10000, (i) => `r${i} 'Row ${i + 1}'`) + '\n' } },
    ],
  },
  {
    id: 'tree', group: 'data', title: 'Tree', desc: 'Nested items with expand state and selection.',
    sections: [{ label: 'Tree', ui: `
tree t  selectable  value=src/tree  : w=260 h=220 border-1 border-color=border rounded-md
tree m  selectable  multiple  : w=260 h=220 border-1 border-color=border rounded-md`, files: { 't/items': treeItems, 't/expanded': 'src\nsrc/ninep\n', 'm/items': treeItems, 'm/expanded': 'src docs\n' } }],
  },
  {
    id: 'description-list', group: 'data', title: 'Description list', desc: 'Label and value pairs in columns, bordered or not, labels beside or above.',
    sections: [
      { label: 'Bordered, three columns', full: true, ui: 'description-list a  bordered', files: { 'a/items': "Type terminal\nProfile desktop\nSince 1.0\nModes 'stream, pty'\nEngine libghostty-vt\nRenderers 'GPUI, terminal'\n" } },
      { label: 'Labels on top, two columns', full: true, ui: 'description-list b  labels=top  columns=2  sm', files: { 'b/items': "Name 'Ada Lovelace'\nRole Analyst\nEmail ada@example.com\nJoined 1843\n" } },
    ],
  },
  {
    id: 'chart', group: 'data', title: 'Chart', desc: 'Line, bar, area and pie, from a data file with a header row.',
    sections: [{ label: 'Kinds', full: true, ui: `
div g  : grid grid-cols=2 gap=16
  chart line  kind=line  x=month  y=visits  : h=160
  chart bar  kind=bar  x=month  y=visits  : h=160
  chart area  kind=area  x=quarter  y=north  : h=160
  chart pie  kind=pie  x=month  y=visits  : h=160`, files: { 'g/line/data': months, 'g/bar/data': months, 'g/area/data': sales, 'g/pie/data': months } }],
  },
  {
    id: 'message-list', group: 'data', title: 'Messages, bubble', desc: 'A chat transcript with markdown bodies; single bubbles by role and variant.',
    sections: [
      { label: 'Message list', full: true, ui: 'message-list m  : h=260 border-1 border-color=border rounded-md p=8', files: { 'm/items': messages } },
      { label: 'Bubble roles', col: true, ui: `
bubble u  role=user  text='A message from the user'
bubble a  role=assistant  text='A reply, **with markdown**'
bubble s  role=system  text='A system note'
bubble t  role=tool  text='tool output'` },
      { label: 'Bubble variants', ui: ['filled', 'secondary', 'muted', 'tinted', 'outline', 'ghost', 'destructive'].map((v) => `bubble ${v}  ${v}  text=${v}`).join('\n') },
    ],
  },

  // overlay
  {
    id: 'dialog', group: 'overlay', title: 'Dialog, alert dialog, sheet', desc: 'Overlays in over/, opened with a ctl write. The buttons here open them.',
    sections: [{ label: 'Open one', ui: `
button d  label='Open dialog'  tag=open:dlg
button a  label=Delete…  tag=open:del  danger
button s  label='Sheet (right)'  tag=open:sheet  outline
button l  label='Sheet (left)'  tag=open:left  outline
button b  label='Sheet (bottom)'  tag=open:bottom  outline` }],
    over: `new dialog dlg keyboard overlay-closable title='Edit profile' description='Make changes to your profile here.' width=420
new input dlg/name value='Ada Lovelace'
new div dlg/footer : h-flex justify-end gap=8
new button dlg/footer/cancel label=Cancel tag=close:dlg ghost
new button dlg/footer/save label=Save tag=close:dlg primary
new alert-dialog del title='Delete 3 files?' description='This cannot be undone.' confirm=Delete cancel=Keep variant=danger
new sheet sheet side=right size=320 title=Filters overlay-closable
new checkbox sheet/a label='Only open'
new checkbox sheet/b label='Assigned to me' value=on
new sheet left side=left size=260 title=Navigation overlay-closable
new text left/t text='A sheet from the left.'
new sheet bottom side=bottom size=180 title=Details overlay-closable
new text bottom/t text='A sheet from the bottom.'`,
  },
  {
    id: 'popover', group: 'overlay', title: 'Popover, hover card', desc: 'Anchored overlays that open on click or hover, with no round trip.',
    sections: [{ label: 'Anchored', ui: `
button p  label='Click me'
button h  label='Hover me'  outline
button v  label='Hover card'  ghost` }],
    over: `new popover pop anchor=$0/p placement=bottom-start
new text pop/t text='A popover, opened by its anchor.' : p=12
new popover hov anchor=$0/h placement=top trigger=hover
new text hov/t text='Opened by hovering.' : p=8 text-sm
new hover-card card anchor=$0/v
new div card/c : v-flex gap=4 p=12 w=240
new text card/c/n text=@uitree : font-semibold
new text card/c/d text='Files all the way down.' : text-sm`,
  },
  {
    id: 'tooltip', group: 'overlay', title: 'Tooltip', desc: 'A node\'s tooltip file, and tooltip overlays with a placement and delay.',
    sections: [
      { label: 'The tooltip file', ui: `
button a  label=Save  tooltip='Save the file'
icon i  name=settings  tooltip=Settings` },
      { label: 'Overlays: placement', ui: ['top', 'bottom', 'left', 'right'].map((p) => `button ${p}  label=${p}  outline`).join('\n') },
    ],
    over: ['top', 'bottom', 'left', 'right'].map((p) => `new tooltip tip-${p} anchor=$1/${p} placement=${p} open-delay=150 text='Placed ${p}'`).join('\n'),
  },
  {
    id: 'context-menu', group: 'overlay', title: 'Context menu, notification', desc: 'A menu on a secondary click, and toasts from the window\'s notify verb.',
    sections: [
      { label: 'Right-click the box', ui: `
div area  : w=280 h=100 border-1 border-dashed border-color=border rounded-md items-center justify-center flex
  text t  text='Right-click here'  : text-color=muted-foreground` },
      { label: 'Notifications', ui: `
button i  label=Info  tag=toast:info
button s  label=Success  tag=toast:success  success
button w  label=Warning  tag=toast:warning  warning
button e  label=Error  tag=toast:error  danger` },
    ],
    over: `new context-menu menu anchor=$0/area`,
    overFiles: { 'menu/menu': menu },
  },

  // nav
  {
    id: 'tabs', group: 'nav', title: 'Tabs', desc: 'Underline, pill, outline, segmented and folder; icons, closable and disabled tabs.',
    sections: ['underline', 'pill', 'outline', 'segmented', 'folder'].map((v) => ({
      label: v, full: true, ui: `
tabs ${v}  value=one  ${v}
  tab one  label=Account  icon=user
    text t  text='The ${v} variant'  : p=8
  tab two  label=Password
    text t  text='Password panel'  : p=8
  tab three  closable  label=Billing
  tab four  disabled  label=Disabled`,
    })),
  },
  {
    id: 'sidebar', group: 'nav', title: 'Sidebar', desc: 'A header, groups of items with icons and badges, nested items and a footer.',
    sections: [{ label: 'Sidebar', full: true, ui: `
div box  : h-flex h=400 border-1 border-color=border rounded-md
  sidebar nav  : w=220
    div header  : h-flex items-center gap=8 p=12
      icon logo  name=layout-dashboard  : text-color=primary
      text name  text=Workspace  : font-semibold
    sidebar-group main  label=Main
      sidebar-item home  active  label=Home  icon=layout-dashboard
      sidebar-item inbox  label=Inbox  icon=inbox  badge=12
      sidebar-item files  label=Files  icon=folder
        sidebar-item docs  label=Docs
        sidebar-item pics  label=Pictures
    sidebar-group more  label=More
      sidebar-item set  label=Settings  icon=settings
      sidebar-item off  disabled  label=Disabled  icon=circle-off
    div footer  : p=12
      text t  text=v1.0  : text-xs text-color=muted-foreground
  div main  : flex-1 p=16
    text t  text='The page'` }],
  },
  {
    id: 'breadcrumb', group: 'nav', title: 'Breadcrumb, pagination, stepper', desc: 'Where you are, which page, which step.',
    sections: [
      { label: 'Breadcrumb', ui: 'breadcrumb b', files: { 'b/items': 'home Home\nsrc src\ncore core\nmain main.zig\n' } },
      { label: 'Pagination', col: true, ui: `
pagination p  page=3  total=240  per-page=20
pagination s  page=1  total=50  sm` },
      { label: 'Stepper', col: true, ui: `
stepper s  value=ship  : w=480
stepper v  value=pay  dir=col`, files: { 's/items': 'cart Cart\npay Payment\nship Shipping\ndone Done\n', 'v/items': 'cart Cart\npay Payment\nship Shipping\n' } },
    ],
  },
  {
    id: 'toolbar', group: 'nav', title: 'Toolbar, link', desc: 'A row of tools; links the host opens.',
    sections: [
      { label: 'Toolbar', full: true, ui: `
toolbar t  : border-1 border-color=border rounded-md p=4
  button a  icon=undo  ghost  tooltip=Undo
  button b  icon=refresh-cw  ghost  tooltip=Redo
  separator s  dir=col
  toggle c  icon=bold
  toggle d  icon=italic
  spacer x
  button e  label=Share  primary  sm` },
      { label: 'Link', ui: `
link a  label='uitree docs'  href=https://example.com/uitree
link b  label=Disabled  disabled  href=https://example.com` },
    ],
  },
  {
    id: 'title-bar', group: 'nav', title: 'Title bar, status bar', desc: 'Window chrome as nodes.',
    sections: [
      { label: 'Title bar', full: true, ui: `
title-bar t  title=Document.md
  button b  icon=settings  ghost  sm` },
      { label: 'Status bar', full: true, ui: `
status-bar s
  text left  text='Ln 12, Col 4'
  text center  text=main
  text right  text=UTF-8` },
    ],
  },

  // layout
  {
    id: 'grid', group: 'layout', title: 'Grid', desc: 'Rows of cells sharing the width, with a gap.',
    sections: [
      { label: 'cols=3 gap=8', full: true, ui: `
grid g  cols=3  gap=8
${range(6, (i) => `  div c${i}  : p=12 bg=muted rounded-md\n    text t  text='Cell ${i + 1}'`)}` },
      { label: 'cols=4', full: true, ui: `
grid h  cols=4  gap=4
${range(8, (i) => `  div c${i}  : h=24 bg=chart-${(i % 5) + 1} rounded-sm`)}` },
    ],
  },
  {
    id: 'resizable', group: 'layout', title: 'Resizable and panel', desc: 'Panels with sizes, mins and maxes, nested in both directions.',
    sections: [{ label: 'Row of panels, a column inside', full: true, ui: `
resizable r  dir=row  : h=240 border-1 border-color=border rounded-md
  panel a  size=180  min=120
    div x  : size-full p=12 bg=muted
      text t  text=Left
  panel b
    resizable c  dir=col  : size-full
      panel top
        text t  text=Top  : p=12
      panel bottom  size=100
        text t  text=Bottom  : p=12` }],
  },
  {
    id: 'dock', group: 'layout', title: 'Dock', desc: 'Panels in center, left, right and bottom zones, with tabs, closable and zoomable.',
    sections: [{ label: 'Dock', full: true, ui: `
dock d  : h=320 border-1 border-color=border rounded-md
  dock-panel files  title=Files  icon=folder  zone=left
    text t  text='A file tree'  : p=8
  dock-panel edit  title=main.zig  zone=center  closable
    text t  text='An editor'  : p=8
  dock-panel notes  title=Notes  zone=center  closable
    text t  text='Second tab'  : p=8
  dock-panel out  title=Output  icon=terminal  zone=bottom
    text t  text='Build output'  : p=8
  dock-panel info  title=Outline  zone=right
    text t  text=Symbols  : p=8` }],
  },
  {
    id: 'accordion', group: 'layout', title: 'Accordion, collapsible', desc: 'Sections that open one or many at a time.',
    sections: [
      { label: 'Accordion', full: true, ui: `
accordion a  value=one  : max-w=480
  accordion-item one  title='What is uitree?'
    text t  text='A UI served as a 9P file tree.'
  accordion-item two  title='Which languages can use it?'
    text t  text='Any that can read and write files.'
  accordion-item three  disabled  title=Disabled
    text t  text=Hidden` },
      { label: 'Multiple open', full: true, ui: `
accordion m  multiple  value='one two'  sm  : max-w=480
  accordion-item one  title=First
    text t  text='Open'
  accordion-item two  title=Second
    text t  text='Also open'` },
      { label: 'Collapsible', full: true, ui: `
collapsible c  open
  button trigger  label='Toggle details'  ghost
  div content  : p=8 bg=muted rounded-md
    text t  text='Collapsible content'` },
    ],
  },
  {
    id: 'separator', group: 'layout', title: 'Separator, group box', desc: 'Lines between things, with a label; boxes with a title.',
    sections: [
      { label: 'Separator', full: true, ui: `
separator a
separator b  label=or
div r  : h-flex items-center gap=8 h=24
  text x  text=Left
  separator v  dir=col
  text y  text=Right` },
      { label: 'Group box variants', ui: ['normal', 'fill', 'outline'].map((v) => `group-box ${v}  ${v}  title=${v}  : w=180\n  text t  text='Inside a ${v} box'`).join('\n') },
    ],
  },

  // feedback
  {
    id: 'progress', group: 'feedback', title: 'Progress, spinner', desc: 'Bars and circles at values and sizes; spinners.',
    sections: [
      { label: 'Bar', col: true, ui: [0, 30, 72, 100].map((v) => `progress p${v}  value=${v}  : w=320`).join('\n') },
      { label: 'Circle', ui: [25, 50, 75].map((v) => `progress c${v}  value=${v}  variant=circle`).join('\n') + '\n' + sizes('progress', 'value=60  variant=circle') },
      { label: 'Spinner sizes', ui: sizes('spinner') },
    ],
  },
  {
    id: 'skeleton', group: 'feedback', title: 'Skeleton, shimmer', desc: 'Placeholders while content loads.',
    sections: [
      { label: 'Skeleton', col: true, ui: `
skeleton a  : h=16 w=320
skeleton b  secondary  : h=16 w=200
skeleton c  : size=48 rounded-full` },
      { label: 'Shimmer', col: true, ui: `
shimmer a  text='Thinking…'
shimmer b  text='Loading results'  lg` },
    ],
  },
  {
    id: 'badge', group: 'feedback', title: 'Badge, tag', desc: 'Counts and dots on things; labels in colors.',
    sections: [
      { label: 'Badge', ui: `
badge a  count=5
  icon i  name=bell
badge b  count=120  max=99
  icon i  name=inbox
badge c  dot
  avatar i  name='Grace Hopper'  sm
badge d  icon=check
  icon i  name=user` },
      { label: 'Tag variants', ui: ['primary', 'secondary', 'danger', 'success', 'warning', 'info', 'outline'].map((v) => `tag ${v}  label=${v}  ${v}`).join('\n') },
      { label: 'Tag colors', ui: ['amber', 'blue', 'cyan', 'emerald', 'fuchsia', 'gray', 'green', 'indigo', 'lime', 'orange', 'pink', 'purple', 'red', 'rose', 'sky', 'teal', 'violet', 'yellow'].map((v) => `tag ${v}  label=${v}  ${v}`).join('\n') },
      { label: 'Tag sizes, closable', ui: sizes('tag', 'label=$s') + '\ntag x  closable  label=Closable' },
    ],
  },
  {
    id: 'alert', group: 'feedback', title: 'Alert', desc: 'Info, success, warning and error; closable, banner.',
    sections: [
      { label: 'Variants', full: true, ui: ['info', 'success', 'warning', 'error'].map((v) => `alert ${v}  ${v}  title='${v[0].toUpperCase() + v.slice(1)}'  text='Something to know about.'`).join('\n') },
      { label: 'Closable and banner', full: true, ui: `
alert c  closable  warning  title='Unsaved changes'  text='Close to dismiss.'
alert b  banner  info  text='A banner across the top of a page.'` },
    ],
  },
  {
    id: 'empty', group: 'feedback', title: 'Empty, kbd', desc: 'Nothing to show yet; keystrokes drawn for the platform.',
    sections: [
      { label: 'Empty', full: true, ui: `
empty e  icon=inbox  title='No messages'  description='Messages you receive show up here.'
  button b  label=Refresh  outline  sm` },
      { label: 'Kbd', ui: ['cmd-shift-p', 'cmd-s', 'ctrl-tab', 'enter', 'escape'].map((k, i) => `kbd k${i}  key=${k}`).join('\n') },
    ],
  },
  {
    id: 'avatar', group: 'feedback', title: 'Avatar', desc: 'Initials and images at four sizes, and groups with a limit.',
    sections: [
      { label: 'Sizes', ui: sizes('avatar', "name='Ada Lovelace'") },
      { label: 'Group, max=3', ui: `
avatar-group g  max=3
  avatar a  name='Ken Thompson'
  avatar b  name='Dennis Ritchie'
  avatar c  name='Rob Pike'
  avatar d  name='Russ Cox'
  avatar e  name='Dave Presotto'` },
    ],
  },

  // text
  {
    id: 'markdown', group: 'text', title: 'Markdown, HTML', desc: 'Rich text drawn natively; links come back as events.',
    sections: [
      { label: 'Markdown', full: true, ui: 'markdown m  selectable  : max-w=560', files: { 'm/text': md } },
      { label: 'HTML', full: true, ui: 'html h  : max-w=560', files: { 'h/text': html } },
    ],
  },
  {
    id: 'editor', group: 'text', title: 'Editor', desc: 'Code with highlighting, line numbers, diagnostics, soft wrap, read-only.',
    sections: [
      { label: 'Line numbers and a diagnostic', full: true, ui: 'editor e  line-numbers  language=rust  : h=180 border-1 border-color=border rounded-md', files: { 'e/value': code, 'e/diagnostics': "6 37 1 warning 'missing semicolon'\n" } },
      { label: 'Read only, soft wrap, placeholder', full: true, ui: `
editor r  readonly  soft-wrap  language=markdown  : h=80 border-1 border-color=border rounded-md
editor p  placeholder='Type here…'  : h=60 border-1 border-color=border rounded-md`, files: { 'r/value': 'A read-only editor with soft wrap on, so a long line like this one wraps at the edge of its box instead of scrolling sideways.\n' } },
    ],
  },
  {
    id: 'diff', group: 'text', title: 'Diff', desc: 'Old and new text, unified or side by side.',
    sections: [
      { label: 'Unified', full: true, ui: 'diff u  path=main.rs  : h=200', files: { 'u/old': oldSrc, 'u/new': newSrc } },
      { label: 'Split', full: true, ui: 'diff s  view=split  path=main.rs  : h=200', files: { 's/old': oldSrc, 's/new': newSrc } },
    ],
  },

  // desktop and web
  {
    id: 'terminal', group: 'desktop', title: 'Terminal', desc: 'A VT terminal as a node (stream mode): the page writes ANSI to out; the core parses it, so screen reads the same on every renderer.',
    sections: [{ label: 'Stream mode', full: true, ui: 'div x  : v-flex h=260\n  terminal t  : flex-1 border-1 border-color=border rounded-md', files: { 'x/t/out': ansi } }],
  },
  {
    id: 'web', group: 'desktop', title: 'Web', desc: 'A web view among native nodes: inline HTML here; the page can post messages back.',
    sections: [{ label: 'Inline page', full: true, ui: 'div x  : v-flex h=180\n  web w  : flex-1 border-1 border-color=border rounded-md', files: { 'x/w/html': page } }],
  },

  // theme
  {
    id: 'theme', group: 'theme', title: 'Theme tokens', desc: 'The colors every component draws with. Change the theme and mode above to see them move.',
    sections: [
      { label: 'Surfaces', ui: ['background', 'foreground', 'muted', 'muted-foreground', 'accent', 'secondary', 'border', 'popover', 'sidebar', 'list-active'].map((t) => swatch(t)).join('\n') },
      { label: 'Intents', ui: ['primary', 'primary-foreground', 'info', 'success', 'warning', 'danger', 'ring', 'selection'].map((t) => swatch(t)).join('\n') },
      { label: 'Charts', ui: ['chart-1', 'chart-2', 'chart-3', 'chart-4', 'chart-5'].map((t) => swatch(t)).join('\n') },
      { label: 'Everything together', ui: `
button p  label=Primary  primary
button s  label=Secondary
checkbox c  label=Check  value=on
switch w  label=Switch  value=on
progress g  value=60  : w=120
tag t  label=Tag  info
badge b  count=3
  icon i  name=bell` },
    ],
  },
];

function swatch(t) {
  return `div ${t}  : v-flex gap=4 w=88\n  div c  : h=40 bg=${t} border-1 border-color=border rounded-md\n  text n  text=${t}  : text-xs text-color=muted-foreground truncate`;
}
