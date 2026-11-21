// Command greet is the design doc's Greeter as a Go client: the same tree
// as examples/rc/hello.rc, written with nothing but package os.
//
//	GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o greet .
//	gpuifs -t Greeter ./greet
//
// Go has no plan9/arm64 port, so on an Apple Silicon Mac this runs on
// h9's amd64 emulator (PLAN.md, design question 13).
//
// Shows: a GOOS=plan9 binary as a client, one write per command, an
// 8 KiB buffered events reader, Plan 9 tokenize rules for event lines.
// Needs: M3
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

var k = env("gpuifs", "/mnt/gpui")

const ui = `div root  style='v_flex size_full p=20 gap=12 bg=background'
  div row  style='h_flex gap=8'
    input name  placeholder='Your name'  style=flex_1  tag=greet
    button go  label=Greet  style=primary  tag=greet
  text out  style='text_lg text_color=muted_foreground'  text='Who are you?'
`

func main() {
	put("ctl", "window main title=Greeter size=360,170 pos=center resizable=off")
	r := "windows/main/root"
	put(r+"/tree", ui)
	put("windows/main/focus", "root/row/name")

	events, err := os.Open(k + "/events")
	check(err)
	in := bufio.NewReaderSize(events, 8192) // a smaller read fails with "short read"
	for {
		line, err := in.ReadString('\n')
		if err != nil {
			return // end of file: the app quit
		}
		ev := parse(line)
		switch ev.name {
		case "click", "submit":
			if ev.attr["tag"] == "greet" {
				name := strings.TrimSpace(get(r + "/row/name/value"))
				if name == "" {
					name = "stranger"
				}
				put(r+"/out/text", "Hello, "+name+"!")
				put(r+"/out/style", "text_lg font_semibold text_color=foreground")
			}
		case "close", "quit":
			put("ctl", "quit")
		}
	}
}

type event struct {
	name string
	attr map[string]string
}

// parse splits an event line by Plan 9's tokenize rules: blanks separate
// words, single quotes group them, and two quotes in a row inside quotes
// make one literal quote.
func parse(line string) event {
	var words []string
	var w strings.Builder
	inq, have := false, false
	s := strings.TrimRight(line, "\n")
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\'' && inq && i+1 < len(s) && s[i+1] == '\'':
			w.WriteByte('\'')
			i++
		case c == '\'':
			inq, have = !inq, true
		case (c == ' ' || c == '\t') && !inq:
			if have || w.Len() > 0 {
				words = append(words, w.String())
				w.Reset()
				have = false
			}
		default:
			w.WriteByte(c)
		}
	}
	if have || w.Len() > 0 {
		words = append(words, w.String())
	}
	ev := event{attr: map[string]string{}}
	for i, word := range words {
		if i == 0 {
			ev.name = word
		} else if k, v, ok := strings.Cut(word, "="); ok {
			ev.attr[k] = v
		}
	}
	return ev
}

// put writes one value or command to a file in one write.
func put(file, s string) {
	f, err := os.OpenFile(k+"/"+file, os.O_WRONLY|os.O_TRUNC, 0)
	check(err)
	_, err = f.WriteString(s)
	check(err)
	check(f.Close()) // text and data files apply at close
}

func get(file string) string {
	b, err := os.ReadFile(k + "/" + file)
	check(err)
	return string(b)
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "greet:", err)
		os.Exit(1)
	}
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}
