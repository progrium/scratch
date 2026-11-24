// Command greet is the design doc's Greeter as a Go client: the same tree
// as examples/rc/hello.rc, written with nothing but package os.
//
//	GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o greet .
//	uitree -t Greeter ./greet
//
// Go has no plan9/arm64 port, so on an Apple Silicon Mac this runs on
// h9's amd64 emulator (PLAN.md, design question 13).
//
// Shows: a GOOS=plan9 binary as a client, one write per command, events
// split with strings.Fields: every line starts name key path, and
// attribute values never hold blanks, so no tokenizer is needed.
// Needs: M3
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

var ui = env("ui", "/mnt/ui")

const screen = `div root  : v-flex size-full p=20 gap=12 bg=background
  div row  tag=greet  : h-flex gap=8
    input name  placeholder='Your name'  : flex-1
    button go  label=Greet  primary
  text out  text='Who are you?'  : text-lg text-color=muted-foreground
`

func main() {
	m := "win/main"
	put(m+"/ctl", "set . title=Greeter size=360,170 pos=center resizable=off")
	put(m+"/tree", screen)
	put(m+"/focus", "row/name")

	events, err := os.Open(ui + "/events")
	check(err)
	in := bufio.NewReader(events)
	for {
		line, err := in.ReadString('\n')
		if err != nil {
			return // end of file: the app quit
		}
		w := strings.Fields(line) // name key path attr=value...
		if len(w) < 3 || w[1] != "greet" {
			continue
		}
		switch w[0] {
		case "click", "submit":
			name := strings.TrimSpace(get(m + "/row/name/value"))
			if name == "" {
				name = "stranger"
			}
			put(m+"/out/text", "Hello, "+name+"!")
			put(m+"/ctl", "set out : text-lg font-semibold text-color=foreground")
		}
	}
}

// put writes one value or command to a file in one write.
func put(file, s string) {
	f, err := os.OpenFile(ui+"/"+file, os.O_WRONLY|os.O_TRUNC, 0)
	check(err)
	_, err = f.WriteString(s)
	check(err)
	check(f.Close()) // text and data files apply at close
}

func get(file string) string {
	b, err := os.ReadFile(ui + "/" + file)
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
