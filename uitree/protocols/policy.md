# policy: the public view and rights

**Layer:** `policy 1.0` (draft) · **Mount:** `/mnt/ux` (a broker) ·
**Required:** no · **Conventions:** [README.md](README.md#shared-conventions)

The core layer serves an app's tree to its author, the client that
builds it. That view has every right and reads `secret` values, because
the author is the app. This layer adds a second view of the same tree
for everyone else, with rights per verb, and a broker that collects the
public views of every app in a session. It is 9/UX's
[ux.md](https://github.com/progrium/9ux/blob/main/docs/protocols/ux.md)
model applied to uitree trees, as the uxkit draft proposed.

## Two views of one tree

| | Author view (`$ui`) | Public view |
| --- | --- | --- |
| Who | the client that builds the app | a broker, and through it scripts, tests, other apps, assistive tools |
| Shape | changed with `new`, `delete`, `tree`, `mkdir`, `rm` | fixed: those fail with `permission denied` |
| `secret` values | readable | always empty; `change` events carry `redacted=on` |
| `sensitive` values | readable | readable only with the `sensitive` right |
| Verbs | all | those the attach's rights allow |
| Paths and events | core's | identical, so the same script reads both |

Everything a public client does goes through the same model and queues
as a person using the window: an `activate` from the public view sends
the same `click` with `via=ctl` to the author's `events`.

A host that implements this layer can hand out its public view; one that
doesn't serves only the author view, and uitreefs's single-client model
is exactly that.

## Rights

| Right | Allows |
| --- | --- |
| `read` | reading every file except `sensitive` values; every attach has it |
| `sensitive` | reading values, items and selections of nodes flagged `sensitive` |
| `activate` | verbs of class `activate`: press, choose, focus, scroll, invoke, open, close, quit |
| `edit` | verbs of class `edit`, `set` of text-valued props, writing value files |
| `keys` | verbs of class `keys`: synthetic key input |
| `admin` | the broker's `grants/` |

Which right a verb needs comes from its type's descriptor (`verb click
class=activate`, [components.md](components.md#the-descriptor)). A
public view's `ctl` help lists `verb class` per line, so a broker needs
no type knowledge of its own. Core's `set` needs `edit`, or `activate`
for props a descriptor marks so (a checkbox's `value`). A write is
checked line by line and nothing is applied if any line is refused.

Display focus is never authority. Rights come from how a client
attached.

## The broker

The broker collects every app's public view in one tree and applies
policy. On 9/UX it is uxd.

```text
/mnt/ux/
    version        policy 1.0, features
    rights         this attach's rights: read activate
    register       app registration
    events         register - apps/sketch-1 name=sketch; unregister ...
    apps/
        sketch-1/  that app's public view: version ctl events win/ menu/ types/ ...
    grants/        only with admin
        new  list  ctl
```

### Registration

A host serves its public view on a fresh pipe, posts the other end once
(on Plan 9, `/srv/ux.$user.$pid.$nonce`, mode 0600), and writes
`register NAME srv=PATH [id=APPID]` to the broker's `register`. The
broker opens the posted entry, removes it, and attaches, so the only way
into an app's public view is through the broker. A read of the same fid
returns the app id. The registration lasts while the fid stays open.

When the broker restarts, the host's blocked read fails; the host waits
for the broker to return and registers again with `id=` set to its old
id. No app state is lost, because the broker keeps none.

### Attaching

The broker posts two services: a public one, where an empty attach name
gives `read` and a grant token gives that grant's rights, and an admin
one with every right, which the session mounts for the user's own
shells. A grant is made on `grants/new` with `grant rights=activate,edit
[app=pattern] [note=text]` and read back as a token.

Files under `apps/` are passed through unchanged: the same contents, the
same `seq` numbers, the same errors. Each open is one open of the app's
file, so every subscriber has its own queue in the app, and a stalled
reader stalls only itself. Public subscriptions may use the core queue
rules or a smaller lossy queue (256, then `lost`); a public reader always
recovers by rereading state.

## Without a session

A uitree host on macOS, Linux or Windows can implement this layer with a
broker of its own, giving uitreefs's "a second client attaches" question
an answer: the second client gets the public view, with the rights its
token grants.

## Open questions

1. **Per-node sensitivity.** Is a `sensitive` flag in the core node files
   enough, or should descriptors mark sensitive props?
2. **Grant scope.** Grants match apps by pattern. Should they also match
   paths within an app?
3. **Public queues.** One queue policy for both views is simpler; lossy
   public queues protect the app from many slow readers. Which?
