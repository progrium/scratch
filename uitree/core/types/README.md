# types

The component catalog as data: one directory per type, `NAME/spec`, in the
descriptor grammar of [components.md](../../protocols/components.md#the-descriptor).

Owner: workstream W1 (types). `uitree-headless` embeds every descriptor
here (`embed.zig`, written by `gen-embed.sh`; rerun it after adding or
removing a type). A renderer passes the subset it implements in
`UitConfig.types`, and the core checks the two agree at `uit_create`
(`Catalog.checkRegistered`).

`style-words` (`name argkind`) and `theme-tokens` (`name light dark`) live
here too, generated with the GPUI renderer's dispatch table by
[`renderer/gpui/tools/style-gen`](../../renderer/gpui/tools/style-gen/gen.sh)
from GPUI's source, so the core checks style without knowing GPUI. Don't
edit them by hand.

The parser and checks are in [`src/types/`](../src/types/root.zig) (`Catalog`,
interface I3).

## Where the descriptors come from

80 types are uitreefs's `catalog` crate, renamed to 0.2. `icon-view`,
`console` and `web` are copied from components.md § New in this spec.

How uitreefs's `TypeSpec`s map to descriptors:

| uitreefs | descriptor |
| --- | --- |
| `name_with_underscores` (props, events) | dashed: `max-len`, `scrolled-to-end`, `mouse-down` |
| `Text` | `text file` |
| `Word`, `Bool`, `Number`, `Child`, `NodePath` | `word`, `bool`, `number`, `child`, `path` |
| `Enum(a, b)` | `enum=a,b` |
| `Data(format)` | `data file` plus `file NAME format=F` |
| `Bytes` | `bytes file` |
| `ReadOnly` | `readonly` (`bool` for `open`, else `text file`) |
| every writable `Bool` prop | also a `word ... kind=flag` |
| `variants` | `word ... kind=variant` |
| `sizable` | `word xs sm md lg kind=size` |
| `Tier::Overlay` | `verb open` and `verb close`, `class=activate` (the tree added them) |
| `Slots::Named` / `ChildTypes` / `NamedAnd` | `slot` lines and `child none` / `child T,T` |

Choices where 0.2 and uitreefs differ:

- **`flags`** (`text`, `styled-text`, `input`, `textarea`, `otp-input`) is
  split into one `bool` prop and flag word per flag (`secret`,
  `cleanable`, `readonly`, `selectable`, `truncate`), since core.md says
  "`secret` sets an input's flag" as a bare word.
- **`button`** follows the components.md example as well as uitreefs:
  `verb click`, `focus` and `blur` events, `prefix` and `suffix` slots,
  `default=off` on `loading` and `disabled`.
- **`canvas`**'s `set id geometry` verb is `update`, because `set PATH` is
  one of the core four on every `ctl`. It also gets the read-only `scale`
  prop components.md asks for, and `img` gets `scale` (default 1).
- **`progress`** `value` is `number`; uitreefs's 0..100 enum doesn't fit
  the grammar. The tree should range-check it.
- **Booleans** are `on` or `off` (and empty to clear). uitreefs also took
  `true` and `false`.
- **`file`** is on every `text`, `bytes` and `data` prop, following
  core.md ("text-valued properties are files of their own"); the
  components.md button example leaves it off `label`. Every prop is still
  a file under the node, as in uitreefs.
- Data formats beyond components.md's table, for host extras:
  `diagnostics`, `selection`, `completions`, `messages`, `json`, `keymap`.
  `radio-group` uses `items`.
- **Profiles.** `accordion-item` is tagged `layout` (an `accordion` holds
  nothing else). `overlay` and `desktop` can't be claimed yet: `tooltip`
  and `file-chooser` exist in neither uitreefs nor a spec descriptor.
- Element events (`click hover mouse-down ...` from a node's `on` file)
  are not in descriptors; `types.element_events` lists them.
- Request answers (`close`, `keep`, `accept`, `refuse` with `seq=`) are
  the tree's, not per-type verbs.
