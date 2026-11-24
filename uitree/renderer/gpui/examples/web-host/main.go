// Command web-host is a demo of the `web` node, run on the host (not in
// h9) with the GPUI renderer, which it dials over 9P (ninep.go and
// files_host.go are bench/latency/counter-go's):
//
//	go build -o web-host . && UITREE_HOST_APP=$PWD/web-host ../../target/release/uitree -k
//
// A toolbar of native buttons above a page: back, forward and reload are
// the node's verbs, "Title" runs `eval n=N script=document.title` and
// shows the result, and the page's own button calls uitree.post, which
// comes back as a `message` event. Every event is logged to stderr.
// With $WEB_URL set the node loads that address instead (url=).
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
)

const page = `<!doctype html>
<html><head><title>uitree web demo</title>
<style>
body { font: 15px system-ui, sans-serif; margin: 0; padding: 24px; background: #f6f7fb; color: #1d2433 }
.card { background: white; border-radius: 12px; padding: 20px; box-shadow: 0 1px 4px #0002; max-width: 520px }
button { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid #c9cfdc; background: #2f6feb; color: white }
#n { font-weight: 600 }
</style></head>
<body><div class="card">
<h1>Hello from a page</h1>
<p>This is a <code>web</code> node: a native web view inside a uitree window,
laid out by GPUI between native nodes.</p>
<p><button onclick="uitree.post('clicked ' + (++window.clicks))">Post to the app</button>
clicks: <span id="n">0</span></p>
<p><a href="https://example.com/">A link (navigate event)</a></p>
</div>
<script>window.clicks = 0; setInterval(() => document.getElementById('n').textContent = window.clicks, 100)</script>
</body></html>`

func screen() string {
	if os.Getenv("WEB_TRANSPARENT") != "" {
		return transparent()
	}
	return `set . title='Web node' size=900,600 pos=center : v-flex size-full bg=background
new div bar : h-flex items-center gap=8 p=8 border-b-1 border-color=border
new button bar/back label=Back tag=back
new button bar/fwd label=Forward tag=fwd
new button bar/reload label=Reload tag=reload
new button bar/title label=Title tag=title
new text bar/status text='—' : text-sm text-color=muted-foreground
` + source() + "\n"
}

// With $WEB_TRANSPARENT set: a transparent window holding only a
// transparent web node, whose page paints one card and leaves the rest
// bare, so the desktop shows around it (Topframe's case).
func transparent() string {
	return `set . title='Web node' size=900,600 pos=center transparent=on : v-flex size-full
new web view : bg=#00000000
set view html=<<END
` + strings.Replace(page, "background: #f6f7fb", "background: transparent", 1) + `
END
`
}

// The page: $WEB_URL if set (url=), else the demo document (html=).
func source() string {
	if u := os.Getenv("WEB_URL"); u != "" {
		return "new web view url=" + quote(u)
	}
	return "new web view html=<<END\n" + page + "\nEND"
}

func readAll(fs *uiFS, path string) string {
	f, err := fs.Open(path, false)
	if err != nil {
		return "(" + err.Error() + ")"
	}
	b, _ := io.ReadAll(f)
	return strings.TrimSpace(string(b))
}

func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func main() {
	fs, err := openUI()
	if err != nil {
		fmt.Fprintln(os.Stderr, "web-host:", err)
		os.Exit(1)
	}
	ctl, err := fs.Open("win/main/ctl", true)
	if err != nil {
		fmt.Fprintln(os.Stderr, "web-host: ctl:", err)
		os.Exit(1)
	}
	if _, err := ctl.Write([]byte(screen())); err != nil {
		fmt.Fprintln(os.Stderr, "web-host: build:", err)
		os.Exit(1)
	}
	view, err := fs.Open("win/main/view/ctl", true)
	if err != nil {
		fmt.Fprintln(os.Stderr, "web-host: view ctl:", err)
		os.Exit(1)
	}
	ev, err := fs.Open("events", false)
	if err != nil {
		fmt.Fprintln(os.Stderr, "web-host: events:", err)
		os.Exit(1)
	}
	status := func(s string) { ctl.Write([]byte("set bar/status text=" + quote(s) + "\n")) }
	n := 0
	sc := bufio.NewScanner(ev)
	for sc.Scan() {
		line := sc.Text()
		fmt.Fprintln(os.Stderr, "event:", line)
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		switch f[0] + ":" + f[1] {
		case "click:back":
			view.Write([]byte("back\n"))
		case "click:fwd":
			view.Write([]byte("forward\n"))
		case "click:reload":
			view.Write([]byte("reload\n"))
		case "click:title":
			n++
			view.Write([]byte(fmt.Sprintf("eval n=%d script=document.title\n", n)))
		}
		switch f[0] {
		case "result":
			r := readAll(fs, "win/main/view/result")
			fmt.Fprintln(os.Stderr, "result:", r)
			status("title: " + r)
		case "message":
			m := readAll(fs, "win/main/view/message")
			fmt.Fprintln(os.Stderr, "message:", m)
			status("page says: " + m)
		case "load":
			status("loaded")
		}
	}
}
