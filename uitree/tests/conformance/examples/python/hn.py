#!/usr/bin/env python3
"""hn.py: a Hacker News reader. Top, New and Best stories in a list with
rich rows; pick one to read its comments; scroll to the end for more.

    uitree -t 'Hacker News' -d ALPINE:#L python3 hn.py

A Linux client: CPython from an Alpine tree, run by h9's Linux ABI, where
the tree is at $ui as for a Plan 9 client. It needs outbound network to
the Hacker News API.

Shows: a list with a row template stamped from item fields (100 stories
are one file), loading and scrolled-to-end paging, tabs switching feeds,
html for comment bodies (HN returns HTML), links the host opens itself,
work on a background thread while the event loop stays responsive, a
standard-library-only client. Events are split with str.split(): the
name, key and path come first.   Needs: M3
"""
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UI_ROOT = os.environ.get("ui", "/mnt/ui")
API = "https://hacker-news.firebaseio.com/v0"
PAGE = 30

UI = """\
div root  : v-flex size-full bg=background
  div top  : h-flex items-center gap=12 px=16 py=8 border-b-1 border-color=border
    text logo  text=HN  : font-bold text-color=primary
    tabs feed  value=top  pill sm
      tab top  label=Top
      tab new  label=New
      tab best  label=Best
    spacer s
    button refresh  icon=refresh-cw  tag=refresh  ghost sm
  resizable split  dir=row  : flex-1
    panel left  size=440  min=300
      list stories  selectable  loading  : size-full
        div row  : v-flex gap=2 px=12 py=8
          text title  text={title}  : text-sm font-medium
          text meta  text='{score} points by {by} · {comments} comments · {site}'  : text-xs text-color=muted-foreground
    panel right
      scroll read  : size-full overflow-y-scroll p=24
        empty none  title='Pick a story'  icon=newspaper
"""

STORY = """\
scroll read  : size-full overflow-y-scroll p=24
  div v  : v-flex gap=16 max-w=720
    text title  : text-xl font-semibold
    link url  : text-sm
    text meta  : text-sm text-color=muted-foreground
    separator s
    div comments  : v-flex gap=16
"""


def put(path, data):
    """One open, one write, one close: text and data files apply at close."""
    fd = os.open(f"{UI_ROOT}/{path}", os.O_WRONLY | os.O_TRUNC)
    try:
        os.write(fd, data.encode() if isinstance(data, str) else data)
    finally:
        os.close(fd)


def get(path):
    with open(f"{UI_ROOT}/{path}") as f:
        return f.read()


def quote(s):
    """Plan 9 quoting, for prop=value pairs in ctl writes."""
    if s and not re.search(r"[\s'=]", s):
        return s
    return "'" + s.replace("'", "''") + "'"


def fetch(path):
    with urllib.request.urlopen(f"{API}/{path}.json", timeout=10) as r:
        return json.load(r)


def clean(s):
    return re.sub(r"[\t\n]+", " ", s or "")


class App:
    def __init__(self):
        self.feed = "top"
        self.ids = []
        self.items = {}
        self.shown = 0
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(8)
        self.w = "win/main"
        self.L = f"{self.w}/split/left/stories"

    def start(self):
        put(f"{self.w}/ctl", "set . title='Hacker News' size=1100,760 min=700,480 pos=center")
        put(f"{self.w}/tree", UI)
        put(f"{self.L}/fields", "title score by comments site\n")
        put("keys", "cmd-r refresh\nj select-next\nk select-prev\n")
        self.load(self.feed)

    def load(self, feed):
        self.feed, self.shown = feed, 0
        put(f"{self.w}/ctl", "set split/left/stories loading=on")
        threading.Thread(target=self._load, args=(feed,), daemon=True).start()

    def _load(self, feed):
        ids = fetch(f"{feed}stories")
        with self.lock:
            if feed != self.feed:
                return
            self.ids = ids
        self.more()

    def more(self):
        with self.lock:
            page = self.ids[self.shown : self.shown + PAGE]
        for item in self.pool.map(lambda i: self.items.get(i) or fetch(f"item/{i}"), page):
            if item:
                self.items[item["id"]] = item
        with self.lock:
            self.shown += len(page)
            ids = self.ids[: self.shown]
        rows = []
        for i in ids:
            it = self.items.get(i)
            if not it:
                continue
            site = re.sub(r"^www\.", "", urllib.parse.urlparse(it.get("url", "")).netloc) or "news.ycombinator.com"
            rows.append(f"{i}\t{clean(it.get('title'))}\t{it.get('score', 0)}\t{it.get('by', '')}\t{it.get('descendants', 0)}\t{site}")
        # Tab-separated lines work as they are; titles hold blanks.
        put(f"{self.L}/items", "\n".join(rows) + "\n")
        put(f"{self.w}/ctl", "set split/left/stories loading=off")

    def open(self, sid):
        it = self.items.get(int(sid))
        if not it:
            return
        url = it.get("url") or f"https://news.ycombinator.com/item?id={sid}"
        when = time.strftime("%b %d, %H:%M", time.localtime(it.get("time", 0)))
        meta = f"{it.get('score', 0)} points by {it.get('by', '')}, {when}"
        # One ctl write: the story's subtree, its text, and a spinner.
        put(f"{self.w}/ctl", "\n".join([
            "tree split/right/read <<END", STORY.rstrip("\n"), "END",
            f"set split/right/read/v/title text={quote(clean(it.get('title')))}",
            f"set split/right/read/v/url label={quote(url)} href={quote(url)}",
            f"set split/right/read/v/meta text={quote(meta)}",
            "new spinner split/right/read/v/comments/wait",
        ]))
        r = f"{self.w}/split/right/read"
        threading.Thread(target=self._comments, args=(it, r), daemon=True).start()

    def _comments(self, it, r):
        kids = [c for c in self.pool.map(lambda i: fetch(f"item/{i}"), it.get("kids", [])[:20]) if c and not c.get("deleted")]
        c = f"{r}/v/comments"
        # Every comment in one write; bodies are HTML, so here-values.
        cmds = ["delete wait"]
        for n, k in enumerate(kids):
            cmds += [
                f"new div c{n} : v-flex gap=4",
                f"new text c{n}/by text={quote(k.get('by', ''))} : text-xs font-semibold text-color=muted-foreground",
                f"new html c{n}/body text=<<END_OF_COMMENT",
                k.get("text", "").replace("\nEND_OF_COMMENT", "\n END_OF_COMMENT"),
                "END_OF_COMMENT",
                f"set c{n}/body : text-sm",
            ]
        put(f"{c}/ctl", "\n".join(cmds))

    def run(self):
        with open(f"{UI_ROOT}/events") as ev:
            for line in ev:
                name, key, path, *rest = line.split()
                attrs = dict(x.split("=", 1) for x in rest if "=" in x)
                if name == "change" and path == "top/feed":
                    self.load(attrs["value"])
                elif name == "select" and path == "split/left/stories":
                    self.open(attrs["value"])
                elif name == "scrolled-to-end":
                    threading.Thread(target=self.more, daemon=True).start()
                elif name in ("click", "action") and key == "refresh":
                    self.items.clear()
                    self.load(self.feed)


if __name__ == "__main__":
    app = App()
    app.start()
    app.run()
