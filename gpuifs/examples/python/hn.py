#!/usr/bin/env python3
"""hn.py: a Hacker News reader. Top, New and Best stories in a list with
rich rows; pick one to read its comments; scroll to the end for more.

    gpuifs -t 'Hacker News' --dir ./alpine:#L python3 hn.py

A Linux client: CPython from an Alpine tree, run by h9's Linux ABI. It
assumes /mnt/gpui is visible to Linux programs, which is DESIGN.md open
question 8; until that is settled it runs against `gpuifs -a` with the
tree mounted some other way, and k below points there.

Shows: a list with a row template stamped from TSV fields (100 stories
are one file), loading and scrolled_to_end paging, tabs switching feeds,
html for comment bodies (HN returns HTML), links the host opens itself,
work on a background thread while the event loop stays responsive, a
standard-library-only client.   Needs: M3
"""
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

K = os.environ.get("gpuifs", "/mnt/gpui")
API = "https://hacker-news.firebaseio.com/v0"
PAGE = 30

UI = """\
div root  style='v_flex size_full bg=background'
  div top  style='h_flex items_center gap=12 px=16 py=8 border_b_1 border_color=border'
    text logo  style='font_bold text_color=primary'  text=HN
    tabs feed  value=top  style='pill sm'
      tab top  label=Top
      tab new  label=New
      tab best  label=Best
    spacer s
    button refresh  icon=refresh-cw  style='ghost sm'  tag=refresh
  resizable split  dir=h  style=flex_1
    panel left  size=440  min=300
      list stories  selectable=on  loading=on  style=size_full
        div row  style='v_flex gap=2 px=12 py=8'
          text title  style='text_sm font_medium'  text={title}
          text meta  style='text_xs text_color=muted_foreground'  text='{score} points by {by} · {comments} comments · {site}'
    panel right
      scroll read  style='size_full overflow_y_scroll p=24'
        empty none  title='Pick a story'  icon=newspaper
"""

STORY = """\
scroll read  style='size_full overflow_y_scroll p=24'
  div v  style='v_flex gap=16 max_w=720'
    text title  style='text_xl font_semibold'
    link url  style=text_sm
    text meta  style='text_sm text_color=muted_foreground'
    separator s
    div comments  style='v_flex gap=16'
"""


def put(path, data):
    """One open, one write, one close: text and data files apply at close."""
    fd = os.open(f"{K}/{path}", os.O_WRONLY | os.O_TRUNC)
    try:
        os.write(fd, data.encode() if isinstance(data, str) else data)
    finally:
        os.close(fd)


def get(path):
    with open(f"{K}/{path}") as f:
        return f.read()


def quote(s):
    """Plan 9 quoting, for prop=value pairs in ctl writes."""
    if s and not re.search(r"[\s'=]", s):
        return s
    return "'" + s.replace("'", "''") + "'"


def tokenize(line):
    words, w, inq, have, i = [], [], False, False, 0
    while i < len(line):
        c = line[i]
        if c == "'" and inq and line[i + 1 : i + 2] == "'":
            w.append("'")
            i += 1
        elif c == "'":
            inq, have = not inq, True
        elif c in " \t\n" and not inq:
            if have or w:
                words.append("".join(w))
            w, have = [], False
        else:
            w.append(c)
        i += 1
    if have or w:
        words.append("".join(w))
    return words


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
        self.w = "windows/main"
        self.L = f"{self.w}/root/split/left/stories"

    def start(self):
        put("ctl", "window main title='Hacker News' size=1100,760 min=700,480 pos=center")
        put(f"{self.w}/root/tree", UI)
        put(f"{self.L}/fields", "title\tscore\tby\tcomments\tsite\n")
        put("keymap", "cmd-r refresh\nj select-next\nk select-prev\n")
        self.load(self.feed)

    def load(self, feed):
        self.feed, self.shown = feed, 0
        put(f"{self.L}/loading", "on")
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
        put(f"{self.L}/items", "\n".join(rows) + "\n")
        put(f"{self.L}/loading", "off")

    def open(self, sid):
        it = self.items.get(int(sid))
        if not it:
            return
        r = f"{self.w}/root/split/right/read"
        put(f"{self.w}/ctl", "begin")
        put(f"{r}/tree", STORY)
        put(f"{r}/v/title/text", clean(it.get("title")))
        url = it.get("url") or f"https://news.ycombinator.com/item?id={sid}"
        put(f"{r}/v/url/label", url)
        put(f"{r}/v/url/href", url)
        when = time.strftime("%b %d, %H:%M", time.localtime(it.get("time", 0)))
        put(f"{r}/v/meta/text", f"{it.get('score', 0)} points by {it.get('by', '')}, {when}")
        put(f"{r}/v/comments/ctl", "new spinner wait")
        put(f"{self.w}/ctl", "commit")
        threading.Thread(target=self._comments, args=(it, r), daemon=True).start()

    def _comments(self, it, r):
        kids = [c for c in self.pool.map(lambda i: fetch(f"item/{i}"), it.get("kids", [])[:20]) if c and not c.get("deleted")]
        c = f"{r}/v/comments"
        cmds = ["delete wait"]
        for n, k in enumerate(kids):
            cmds.append(f"new div c{n} style='v_flex gap=4'")
        put(f"{c}/ctl", "\n".join(cmds))
        for n, k in enumerate(kids):
            put(f"{c}/c{n}/ctl", "new text by style='text_xs font_semibold text_color=muted_foreground'\nnew html body style=text_sm")
            put(f"{c}/c{n}/by/text", k.get("by", ""))
            put(f"{c}/c{n}/body/text", k.get("text", ""))

    def run(self):
        with open(f"{K}/events", "rb", buffering=65536) as ev:  # reads of at least 8 KiB
            for raw in ev:
                w = tokenize(raw.decode())
                if not w:
                    continue
                name, attrs = w[0], dict(x.split("=", 1) for x in w[1:] if "=" in x)
                node = attrs.get("node", "")
                if name == "change" and node == "root/top/feed":
                    self.load(attrs["value"])
                elif name == "select" and node.endswith("/stories"):
                    self.open(attrs["value"])
                elif name == "scrolled_to_end":
                    threading.Thread(target=self.more, daemon=True).start()
                elif (name == "click" and attrs.get("tag") == "refresh") or (name == "action" and attrs.get("id") == "refresh"):
                    self.items.clear()
                    self.load(self.feed)
                elif name in ("close", "quit"):
                    put("ctl", "quit")


if __name__ == "__main__":
    app = App()
    app.start()
    app.run()
