# components: types a host provides

**Layer:** `components 1.0` (draft) · **Mount:** `$ui/types` ·
**Required:** yes · **Conventions:** [README.md](README.md#shared-conventions)

The core layer says how to make a node; this layer says which kinds of
node exist. A host **publishes** every type it can build, each with a
descriptor, so a client asks what is there instead of assuming. Types
are grouped into **profiles**, and a host names the profiles it
implements in full, so a client can depend on a whole set at once.

This is what lets one spec serve a GPUI host with eighty components and a
libdraw host with a dozen: they share the grammar and differ only in what
`ls $ui/types` prints.

## The catalog in the tree

```text
$ui/types/
    button/
        spec        the descriptor (below)
        version     button 1.0
    table/
        spec
        version
        rows        the format of a data file, when the type has one
    ...
$ui/style/words     every style word the host accepts, one per line
```

- `ls $ui/types` lists every type the host can build. `test -d
  $ui/types/table` is a feature test in rc.
- `new`, `tree` documents and `type` writes fail with `unknown type:
  NAME` for a type not listed.
- The directory is read-only and doesn't change while the host runs.
- A type's `version` is `NAME major.minor`. A minor version adds props,
  words, verbs, events or slots; a major version breaks.

## The descriptor

`types/NAME/spec` describes a type in the protocol's own line grammar,
so a client that reads events can read it with the same code. A host
must accept everything its descriptors list and must refuse, with the
error named below, what they don't.

```text
type    button  tier=component  profile=form  since=1.0
prop    label     text
prop    icon      word
prop    loading   bool  default=off
prop    disabled  bool  default=off
word    primary secondary danger ghost link outline   kind=variant
word    xs sm md lg                                   kind=size
verb    click                                         class=activate
event   click   kind=action
event   focus   kind=state
event   blur    kind=state
slot    prefix  accepts=icon,svg,text
slot    suffix  accepts=icon,svg,text
child   any
```

| Line | Form | Meaning |
| --- | --- | --- |
| `type` | `type NAME tier=element\|component\|overlay profile=P since=V` | The type's name, its tier, the profile that defines it (absent for host extras), and the spec version it appeared in |
| `prop` | `prop NAME FORM [default=V] [min=N] [max=N] [file] [readonly]` | A property. Every prop is settable with `set` and `new`; `file` means it is also a file under the node, `readonly` means only the host writes it. `min` and `max` bound a `number` prop: every number in its value must be within them, or the write fails with `bad value` |
| `word` | `word W ... kind=flag\|variant\|size` | Bare words the type takes in `new` lines and documents. A flag sets a boolean prop of the same name; a variant or size word picks one of a set |
| `verb` | `verb NAME [ARGS] [class=C]` | A verb the node's `ctl` takes beyond the core four. `class` is the right it needs under [policy](policy.md#rights) |
| `event` | `event NAME kind=state\|action\|request [attrs=a,b]` | An event the type sends, its queue kind, and the attributes it carries |
| `slot` | `slot NAME [accepts=T,T]` | A child name the type places specially (a dialog's `footer`) and the types it accepts |
| `child` | `child any\|none\|T,T` | What unnamed children may be |
| `file` | `file NAME format=F` | A data file and its line format (below) |

Prop forms:

| Form | Values |
| --- | --- |
| `text` | any text, raw in its file |
| `word` | one token |
| `bool` | `on`, `off` |
| `number` | decimal |
| `enum=a,b,c` | one of the listed words |
| `path` | a node path in the same window (an overlay's `anchor`) |
| `child` | the name of one of the node's children (a `tabs` value) |
| `data` | a data file; see its `file` line |
| `bytes` | binary (an image), or raw text the type doesn't parse |

### Data file formats

Data files hold one item per line. A line with a tab is tab-separated
fields; a line without one is Plan 9 words. `# ` starts a group header
and a lone `-` is a separator, where the format allows them. Each format
has a name the descriptor's `file` lines use, and a type directory may
include a file of the same name holding an example.

| Format | Line | Used by |
| --- | --- | --- |
| `items` | `id label [icon=name] [disabled]` | `select`, `list`, `combobox`, `radio-group` |
| `columns` | `id label width [sort] [fixed] [align=left\|center\|right]` | `table` |
| `rows` | one field per column, in `columns` order | `table` |
| `tree-items` | `id parent label [icon=name]`, parent `-` for a root | `tree` |
| `desc-items` | `label value` | `description-list` |
| `menu` | core.md's item grammar | menus, `context-menu`, `dropdown-button` |
| `ops` | `kind id geometry attrs` | `canvas` |
| `icon-items` | `id label=text icon=name pos=x,y [selected]` | `icon-view` |

### What descriptors are for

- **Clients and helpers.** A client library can generate typed `new`
  calls and event constants per language from `types/*/spec`. An editor
  can complete `.ui` documents from it.
- **Errors.** `bad value`, `unknown type` and the queue kind of each
  event come from the descriptor, not from host code paths that can
  drift from the docs.
- **Rights.** A public view's `ctl` help is the descriptor's `verb` lines
  with their classes, which is what a broker reads ([policy.md](policy.md)).
- **Docs.** The reference for a host is generated from its descriptors.
- **Conformance.** A test suite reads a host's descriptors and checks
  that the host accepts and refuses exactly what they say.

uitreefs already holds this data as `TypeSpec` values in its `catalog`
crate (props with kinds, verbs, events with kinds, slots, variants,
size). Publishing it is a matter of serving those values in this form.

## Profiles

A profile is a named set of types with fixed descriptors. A host lists a
profile in `version` only if it builds **every** type in it as
specified. A client that checks for `profile form` can use every `form`
type without testing each.

| Profile | Types |
| --- | --- |
| `core` | `div` `text` `styled-text` `img` `svg` `icon` `scroll` `spacer` |
| `canvas` | `canvas` (retained `ops`, item hits, `pixels`) |
| `form` | `button` `checkbox` `radio-group` `switch` `select` `input` `textarea` `number-input` `slider` `form` `field` |
| `data` | `list` `table` `tree` `description-list` |
| `overlay` | `dialog` `alert-dialog` `sheet` `popover` `tooltip` `context-menu` |
| `nav` | `tabs` `tab` `sidebar` `sidebar-group` `sidebar-item` `breadcrumb` `toolbar` `link` |
| `layout` | `grid` `resizable` `panel` `separator` `group-box` `accordion` `collapsible` |
| `feedback` | `progress` `spinner` `badge` `alert` `empty` `kbd` `tag` |
| `desktop` | `icon-view` `console` `file-chooser` |
| `web` | `web` |

`core` is required: every host claims it. The others are optional.

Two scale rules from [core.md § Coordinates](core.md#coordinates) apply
to these profiles: `img` takes `scale=` (its logical size is its pixel
size divided by `scale`, default 1), and a `canvas` has a read-only
`scale` prop with its current device pixels per point; its `pixels`
buffer is `w×scale` by `h×scale` device pixels, and its ops and hits are
in node space, the only place decimals are allowed.

Types not in any profile are **host extras**. They are listed in
`types/` like any other, with no `profile=` on their `type` line. uitreefs
has many (`editor`, `diff`, `markdown`, `chart`, `dock`, `dock-panel`,
`date-picker`, `color-picker`, `message-list`, ...). A host may also
publish a type ahead of the spec under an `x.` name (`x.uitreefs.dock`).
When the spec adopts an extra, it moves into a profile in a minor
version.

### New in this spec

Three types in the profiles above don't exist in uitreefs today, and
come from 9/UX and the toolkit-go proposal.

**`icon-view`** (`desktop`). Icons at free positions, as in a Finder
window. The host does selection, rubber-banding and dragging icons, so
the client sees only results.

```text
type    icon-view  tier=component  profile=desktop  since=1.0
file    items  format=icon-items
prop    selection  text  readonly
prop    arrange    enum=free,grid,list  default=free
verb    select   ID...                  class=activate
verb    open     ID...                  class=activate
verb    move     ID x,y                 class=edit
verb    rename   ID TEXT                class=edit
event   select   kind=state   attrs=sel
event   move     kind=state   attrs=item,pos
event   open     kind=action  attrs=items
event   rename   kind=action  attrs=item
event   drop     kind=request attrs=drag,item
```

**`console`** (`desktop`). A terminal-style text area that is a program's
console: output is appended, typed lines are sent. On 9/UX the host
serves the console as the client's child process's `/dev/cons`, as Run
Command does today.

```text
type    console  tier=component  profile=desktop  since=1.0
prop    value      text  file readonly
prop    input      text  file readonly
prop    raw        bool  default=off
verb    append   TEXT                  class=edit
verb    insert   TEXT                  class=edit
verb    interrupt                      class=activate
verb    clear                          class=edit
event   submit     kind=action   attrs=n
event   interrupt  kind=action
```

**`web`** (`web`). A web view as a node, so a window can mix native nodes
and a page. `window main url=...` in the [shell layer](shell.md) is
shorthand for a window whose only child is a `web` node.

```text
type    web  tier=component  profile=web  since=1.0
prop    url     text  file
prop    html    text  file
prop    script  text  file
verb    reload                          class=activate
verb    back                            class=activate
verb    forward                         class=activate
verb    eval     n=N script=TEXT        class=author
file    message  format=bytes
file    result   format=bytes
event   load      kind=state   attrs=ok
event   title     kind=state
event   navigate  kind=action  attrs=allowed
event   message   kind=action  attrs=n
event   result    kind=action  attrs=n,ok
```

**Talking to the page.** `eval` on the node's `ctl` runs script in the
page, usually as a here-value:

```rc
echo 'eval n=7 script=<<END
document.title
END' >$ui/win/main/view/ctl
# result - view win=main n=7 ok seq=90
cat $ui/win/main/view/result/7
```

An `eval` with `n=` answers with a `result` event and the value, as text,
in `result/N`; `ok` is absent when the script threw, and `result/N` then
holds the error. In the page, `uitree.post(text)` sends `message KEY PATH
win=main n=N seq=...`, with the body in `message/N`. Both directories keep
the last 64 entries. Message bodies are bytes the page chose, and a
client treats them as untrusted input.

### Tooltips

`tooltip` (`overlay`) is a short text the host shows next to an anchor
node while the pointer rests on it.

```text
type    tooltip  tier=overlay  profile=overlay  since=1.0
prop    anchor      path
prop    text        text  file
prop    placement   enum=top-start,top,top-end,bottom-start,bottom,bottom-end,left-start,left,left-end,right-start,right,right-end  default=top
prop    open-delay  number  default=500  min=0
prop    open        bool  default=off  readonly
verb    open   class=activate
verb    close  class=activate
child   none
```

- The host opens it `open-delay` milliseconds after the pointer enters
  `anchor` and stays on it, and closes it as soon as the pointer leaves
  the anchor or presses on it. A press hides it until the pointer leaves
  and comes back. None of this is a round trip: the client sees no
  events, and `open` reads `on` while it shows.
- `open` and `close` on its `ctl` show and hide it at once, anchored or
  not, until the pointer next enters or leaves the anchor.
- With no `anchor`, or an anchor not drawn yet, `open` shows it near the
  top of the window.
- `text` is plain text. A host may wrap a long one.

**The `tooltip` node file** ([core.md § Overlays](core.md#overlays)) is
shorthand for this overlay: `echo 'Save file' >save/tooltip` behaves as
`new tooltip ... anchor=save text='Save file'` with every other prop at
its default, except that it has no `over/` node and no `open` file. A
host draws both kinds with one code path, so they look and time the
same. A node with a `tooltip` file and a `tooltip` overlay anchored to it
shows the overlay.

## Degrading

A document that must run on several hosts names alternatives with
`alt=`:

```text
table reg  alt=list  stripe : flex-1
```

The host builds the first of `table`, `list` it has, and the node's
`type` file reads the one it built. Props the built type doesn't have are
ignored, not refused, on a node made through `alt=`. Without `alt=`, an
unknown type fails the whole write.

## Components from outside the host

A later version may let a program add a type: a library a host loads, or
a separate 9P server that draws into a rectangle the host gives it and
appears as `types/NAME/` with its own descriptor. Nothing in 1.0 depends
on this, but the descriptor is designed so such a type would be
indistinguishable to clients.

## Open questions

1. **All-or-nothing profiles.** A libux host could do most of `data`
   early. Should a host be able to claim a profile with listed gaps
   (`profile data missing=tree`)?
2. **Descriptor versioning.** Per-type versions, profile versions, or
   both? Profiles may need their own `major.minor`.
3. **Style per type.** Should a descriptor list the style words that mean
   something on that type (variants are there already)?
4. ~~Talking to a web page.~~ Settled: `eval`, `message/N` and
   `result/N` on the `web` node (§ New in this spec).
5. **Slots or children.** uitreefs mixes named slots and typed children
   (`sidebar` takes `header`, `footer` and `sidebar-group` children).
   The `slot` and `child` lines cover it, but is there a simpler model?
