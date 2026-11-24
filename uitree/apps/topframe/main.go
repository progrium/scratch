// Command topframe-client is Topframe (github.com/progrium/topframe) as a
// uitree app: a local webpage as a fullscreen, transparent, click-through,
// always-on-top overlay, with a menu bar extra to control it.
//
// Topframe's Go program does three things: serve a directory over HTTP
// (with executable files streamed as server-sent events), watch it for
// changes, and drive a Cocoa window, web view and status item through
// macdriver. This client keeps the first two as they were and does the
// third by writing uitree files, so the same page runs on any uitree host
// that draws `web` nodes and the shell layer's window props.
//
//	GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o topframe-client .
//	cd DIR && uitree --net enable -C DIR ./topframe-client
//
// It runs in h9 and needs `--net enable` there, since h9 refuses servers
// otherwise. The directory it serves is its working directory; the
// `topframe` launcher beside it makes and seeds ~/.topframe and starts it.
//
// Files it writes, and what each stands for in topframe.go:
//
//	set app agent                    cocoa.TerminateAfterWindowsClose = false
//	set . titlebar=none fill=display NSBorderlessWindowMask, NSScreen_Main().Frame()
//	      top=overlay                SetLevel(NSMainMenuWindowLevel + 2)
//	      all-spaces=on shadow=off   CanJoinAllSpaces, setHasShadow:false
//	      transparent=on             SetOpaque(false), NSColor_Clear()
//	      click-through=on           SetIgnoresMouseEvents(true)
//	web page url=http://...          WKWebView, LoadRequest
//	tray main title=🔲 menu=tray     NSStatusBar item and its NSMenu
//	page/ctl reload                  wv.Reload on every file change
//	open file://DIR                  Show Source...: `open dir`
package main

import (
	"bufio"
	"embed"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

var version = "0.1.0-uitree"

//go:embed data
var data embed.FS

var ui = env("ui", "/mnt/ui")

const win = "win/main"

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "-v" || os.Args[1] == "-version") {
		fmt.Println(version)
		return
	}
	dir, err := os.Getwd()
	check(err)
	// The directory as the host names it, for Show Source.
	hostDir := env("TOPFRAME_DIR", dir)

	addr := startServer(dir)
	log.Printf("topframe %s on uitree, serving %s at http://%s/", version, hostDir, addr)

	setup(addr)
	go watch(dir, 450*time.Millisecond)
	run(hostDir)
}

// setup builds the overlay window and the menu bar extra.
func setup(addr string) {
	put("ctl", "set app agent name=Topframe version="+version)
	// The overlay: no frame, covering the main display, above the menu
	// bar, on every Space, no shadow.
	put(win+"/ctl", "set . title=Topframe titlebar=none resizable=off fill=display top=overlay all-spaces=on shadow=off")
	// Transparency and click-through, on a host that has them. A host
	// without them refuses the line; the overlay still works, opaque.
	try(win+"/ctl", "set . transparent=on click-through=on")
	put(win+"/tree", "div root  : size-full\n"+
		"  web page  url='http://"+addr+"/'  : size-full bg=#00000000\n")
	put("menu/tray", `item enabled label=Enabled check=on
item interactive label=Interactive check=off
sep
item source label='Show Source...'
sep
item quit label=Quit
`)
	put("ctl", "tray main title=🔲 tooltip=Topframe menu=tray")
}

// run answers the tray menu until the app quits.
func run(hostDir string) {
	f, err := os.Open(ui + "/events")
	check(err)
	in := bufio.NewReader(f)
	enabled, interactive := true, false
	for {
		line, err := in.ReadString('\n')
		if err != nil {
			os.Exit(0) // the app quit
		}
		w := strings.Fields(line)
		if len(w) < 2 || w[0] != "action" {
			continue
		}
		switch w[1] {
		case "enabled":
			enabled = !enabled
			if enabled {
				put(win+"/ctl", "state normal")
				put("ctl", "set enabled check=on\nset interactive enabled=on")
			} else {
				put(win+"/ctl", "state hidden")
				put("ctl", "set enabled check=off\nset interactive enabled=off")
			}
		case "interactive":
			interactive = !interactive
			// Interactive: take clicks, and drop below the menu bar so
			// the menu bar extra is still reachable. Topframe does the
			// same with NSMainMenuWindowLevel - 1.
			if interactive {
				try(win+"/ctl", "set . click-through=off")
				put(win+"/ctl", "set . top=on")
				put("ctl", "set interactive check=on")
			} else {
				try(win+"/ctl", "set . click-through=on")
				put(win+"/ctl", "set . top=overlay")
				put("ctl", "set interactive check=off")
			}
		case "source":
			u := url.URL{Scheme: "file", Path: hostDir}
			put("ctl", "open "+quote(u.String()))
		case "quit":
			put("ctl", "quit")
		}
	}
}

// startServer serves dir as topframe.go does: executable files as
// event streams for an EventSource, `/-/` from the embedded data, the
// rest as files. It returns host:port.
func startServer(dir string) string {
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := filepath.Join(dir, filepath.FromSlash(r.URL.Path))
		if isExecScript(p) && r.Header.Get("Accept") == "text/event-stream" {
			streamExecScript(w, p, strings.Split(r.URL.RawQuery, "+"))
			return
		}
		if strings.HasPrefix(r.URL.Path, "/-/") {
			http.StripPrefix("/-/", http.FileServer(http.FS(data))).ServeHTTP(w, r)
			return
		}
		http.FileServer(http.Dir(dir)).ServeHTTP(w, r)
	})
	ln, err := listen(os.Getenv("TOPFRAME_ADDR"))
	check(err)
	go func() { check(http.Serve(ln, h)) }()
	a := ln.Addr().(*net.TCPAddr)
	host := a.IP.String()
	if a.IP == nil || a.IP.IsUnspecified() {
		host = "127.0.0.1"
	}
	return net.JoinHostPort(host, fmt.Sprint(a.Port))
}

// listen announces on addr, or on a free local port. h9's /net/cs can't
// translate port 0, so a free port is found by trying.
func listen(addr string) (net.Listener, error) {
	if addr != "" {
		return net.Listen("tcp", addr)
	}
	var err error
	base := 40000 + int(time.Now().UnixNano()%20000)
	for i := 0; i < 50; i++ {
		var ln net.Listener
		if ln, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", base+i*7)); err == nil {
			return ln, nil
		}
	}
	return nil, err
}

// streamExecScript runs the script with the query's `+`-separated words
// as arguments and sends each line of its output as an `stdout` event.
func streamExecScript(w http.ResponseWriter, p string, args []string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "script unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	cmd := exec.Command(p, args...)
	cmd.Dir = filepath.Dir(p)
	cmd.Stderr = os.Stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		log.Println("script:", err)
		return
	}
	if err := cmd.Start(); err != nil {
		log.Println("script:", err)
		return
	}
	sc := bufio.NewScanner(out)
	for sc.Scan() {
		if _, err := io.WriteString(w, "event: stdout\ndata: "+sc.Text()+"\n\n"); err != nil {
			log.Println("script:", err)
			break
		}
		flusher.Flush()
	}
	if err := cmd.Wait(); err != nil {
		log.Println("script:", err)
	}
}

func isExecScript(p string) bool {
	fi, err := os.Stat(p)
	// Not IsRegular: h9 serves host files with the device bit set.
	return err == nil && !fi.IsDir() && fi.Mode()&0111 != 0
}

// watch reloads the page when any file under dir changes, appears or
// goes, checking every interval (progrium/watcher polls the same way).
func watch(dir string, every time.Duration) {
	last := scan(dir)
	for range time.Tick(every) {
		now := scan(dir)
		if !same(last, now) {
			try(win+"/page/ctl", "reload")
		}
		last = now
	}
}

type stamp struct {
	mod  time.Time
	size int64
}

func scan(dir string) map[string]stamp {
	m := map[string]stamp{}
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if fi, err := d.Info(); err == nil {
			m[p] = stamp{fi.ModTime(), fi.Size()}
		}
		return nil
	})
	return m
}

func same(a, b map[string]stamp) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// quote makes s one word for a ctl line.
func quote(s string) string {
	if !strings.ContainsAny(s, " \t'") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func write(file, s string) error {
	f, err := os.OpenFile(ui+"/"+file, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	if _, err = f.WriteString(s); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func put(file, s string) {
	if err := write(file, s); err != nil {
		log.Fatalf("topframe: %s: %v", file, err)
	}
}

// try is put for lines a host may not take.
func try(file, s string) {
	if err := write(file, s); err != nil {
		log.Printf("topframe: %s: %v", file, err)
	}
}

func check(err error) {
	if err != nil {
		log.Fatal("topframe: ", err)
	}
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}
