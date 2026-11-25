// Command repl is a small shell in a terminal node in stream mode: the
// node draws what the program writes to `out`, and the keys the user
// types come out of `keys`, already encoded (Enter is CR, Up is ESC [ A).
// Stream mode has no tty and so no line discipline, so this program is
// its own: it echoes what is typed, edits the line (Backspace, Ctrl-U,
// Ctrl-W, Ctrl-A, Ctrl-E, the arrows, Home, End and Delete), keeps a
// history on Up and Down, and ends its lines with CR LF. Its commands are
// built in (ls, cat, cd, pwd, echo, date, colors, calc, clear, help), so
// it never forks.
//
//	GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o repl .
//	uitree -t repl ./repl
//
// Shows: a terminal node's two streams (`prog <$t/keys >$t/out`, in Go),
// colors and cursor movement from escape sequences the host parses (the
// screen file reads back plain text on any renderer or none), the resize
// event with the grid that fits the node, and the reset verb.
// Needs: the terminal node (components.md § terminal)
package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var ui = env("ui", "/mnt/ui")

const (
	win  = "win/main"
	term = win + "/body/sh"
)

const screen = `div root  : v-flex size-full bg=background
  div bar  : h-flex items-center gap=8 px=12 py=6 border-b-1 border-color=border
    text what  text='A shell in Go, in stream mode'  : flex-1 text-sm font-semibold
    text size  : text-xs text-color=muted-foreground font-family=monospace
    button clear  label=Clear  ghost xs
  div body  : flex-1 v-flex p=6 bg=background
    terminal sh  : flex-1
`

// The prompt's colors are SGR: the host's engine parses them, and every
// renderer draws the same cells.
const prompt = "\x1b[1;32mrepl\x1b[0m \x1b[34m%s\x1b[0m; "

var (
	out     *os.File
	outMu   sync.Mutex
	line    []rune // the line being edited
	pos     int    // the cursor, in runes
	history []string
	hpos    int
)

func main() {
	put(win+"/ctl", "set . title=repl size=820,520 pos=center")
	put(win+"/tree", screen)
	put(win+"/focus", "body/sh")
	if h := os.Getenv("home"); h != "" {
		os.Chdir(h)
	}

	var err error
	out, err = os.OpenFile(ui+"/"+term+"/out", os.O_WRONLY, 0)
	check(err)
	write("\x1b[1mA shell in a terminal node, stream mode.\x1b[0m No tty, so it does its own\r\n" +
		"echo and line editing. Try \x1b[33mls /bin\x1b[0m, \x1b[33mcolors\x1b[0m, \x1b[33mcalc 6*7\x1b[0m, Up for history, \x1b[33mhelp\x1b[0m.\r\n\r\n")
	showPrompt()

	go events()
	keys()
}

// keys reads the encoded keys and edits the line.
func keys() {
	f, err := os.Open(ui + "/" + term + "/keys")
	check(err)
	in := bufio.NewReader(f)
	for {
		r, _, err := in.ReadRune()
		if err != nil {
			os.Exit(0)
		}
		switch r {
		case '\r', '\n':
			enter()
		case 0x7f, 0x08: // Backspace
			if pos > 0 {
				line = append(line[:pos-1], line[pos:]...)
				pos--
				redraw()
			}
		case 0x03: // Ctrl-C
			write("^C\r\n")
			line, pos = nil, 0
			showPrompt()
		case 0x15: // Ctrl-U
			line, pos = line[pos:], 0
			redraw()
		case 0x17: // Ctrl-W
			i := pos
			for i > 0 && line[i-1] == ' ' {
				i--
			}
			for i > 0 && line[i-1] != ' ' {
				i--
			}
			line = append(line[:i], line[pos:]...)
			pos = i
			redraw()
		case 0x01: // Ctrl-A
			pos = 0
			redraw()
		case 0x05: // Ctrl-E
			pos = len(line)
			redraw()
		case 0x0c: // Ctrl-L
			write("\x1b[H\x1b[2J")
			showPrompt()
		case 0x1b:
			escape(in)
		default:
			if r >= ' ' {
				line = append(line[:pos], append([]rune{r}, line[pos:]...)...)
				pos++
				redraw()
			}
		}
	}
}

// escape reads the rest of a CSI or SS3 sequence: ESC [ A, or ESC O A
// under application cursor keys, and ESC [ 3 ~ style keys.
func escape(in *bufio.Reader) {
	b, err := in.ReadByte()
	if err != nil || (b != '[' && b != 'O') {
		return
	}
	var seq []byte
	for {
		c, err := in.ReadByte()
		if err != nil {
			return
		}
		seq = append(seq, c)
		if c >= 0x40 && c <= 0x7e {
			break
		}
	}
	switch string(seq) {
	case "A":
		recall(-1)
	case "B":
		recall(+1)
	case "C":
		if pos < len(line) {
			pos++
			redraw()
		}
	case "D":
		if pos > 0 {
			pos--
			redraw()
		}
	case "H", "1~", "7~":
		pos = 0
		redraw()
	case "F", "4~", "8~":
		pos = len(line)
		redraw()
	case "3~": // Delete
		if pos < len(line) {
			line = append(line[:pos], line[pos+1:]...)
			redraw()
		}
	}
}

func recall(d int) {
	if len(history) == 0 {
		return
	}
	hpos += d
	if hpos < 0 {
		hpos = 0
	}
	if hpos >= len(history) {
		hpos = len(history)
		line = nil
	} else {
		line = []rune(history[hpos])
	}
	pos = len(line)
	redraw()
}

func enter() {
	cmd := strings.TrimSpace(string(line))
	write("\r\n")
	line, pos = nil, 0
	if cmd != "" {
		if len(history) == 0 || history[len(history)-1] != cmd {
			history = append(history, cmd)
		}
		hpos = len(history)
		run(strings.Fields(cmd))
	}
	showPrompt()
}

// run is the built-in commands. Each line it prints ends in CR LF, as
// a terminal's output processing (onlcr) would make it.
func run(f []string) {
	errorf := func(format string, a ...any) {
		write("\x1b[31m" + fmt.Sprintf(format, a...) + "\x1b[0m\r\n")
	}
	args := f[1:]
	switch f[0] {
	case "help":
		write("ls [dir]  cat file  cd [dir]  pwd  echo words  date  colors  calc expr  clear\r\n")
	case "ls":
		dir := "."
		if len(args) > 0 {
			dir = args[0]
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			errorf("%v", err)
			return
		}
		sort.Slice(ents, func(i, j int) bool { return ents[i].Name() < ents[j].Name() })
		var b strings.Builder
		for _, e := range ents {
			info, err := e.Info()
			if err != nil {
				continue
			}
			name := e.Name()
			switch {
			case e.IsDir():
				name = "\x1b[1;34m" + name + "/\x1b[0m"
			case info.Mode()&0111 != 0:
				name = "\x1b[32m" + name + "\x1b[0m"
			}
			fmt.Fprintf(&b, "%s %8d %s  %s\r\n", info.Mode(), info.Size(), info.ModTime().Format("Jan _2 15:04"), name)
		}
		write(b.String())
	case "cat":
		for _, a := range args {
			data, err := os.ReadFile(a)
			if err != nil {
				errorf("%v", err)
				continue
			}
			write(strings.ReplaceAll(string(data), "\n", "\r\n"))
		}
	case "cd":
		dir := os.Getenv("home")
		if len(args) > 0 {
			dir = args[0]
		}
		if err := os.Chdir(dir); err != nil {
			errorf("%v", err)
		}
	case "pwd":
		dir, _ := os.Getwd()
		write(dir + "\r\n")
	case "echo":
		write(strings.Join(args, " ") + "\r\n")
	case "date":
		write(time.Now().Format("Mon Jan _2 15:04:05 MST 2006") + "\r\n")
	case "clear":
		write("\x1b[H\x1b[2J")
	case "colors":
		// The 16 ANSI colors, then the 256-color cube and a 24-bit ramp.
		var b strings.Builder
		for i := 0; i < 16; i++ {
			fmt.Fprintf(&b, "\x1b[48;5;%dm  ", i)
		}
		b.WriteString("\x1b[0m\r\n")
		for g := 0; g < 6; g++ {
			for r := 0; r < 6; r++ {
				for bl := 0; bl < 6; bl++ {
					fmt.Fprintf(&b, "\x1b[48;5;%dm ", 16+36*r+6*g+bl)
				}
			}
			b.WriteString("\x1b[0m\r\n")
		}
		for i := 0; i < 72; i++ {
			fmt.Fprintf(&b, "\x1b[48;2;%d;%d;%dm ", 255-i*3, i*3, 128)
		}
		b.WriteString("\x1b[0m\r\n")
		b.WriteString("\x1b[1mbold\x1b[0m \x1b[2mfaint\x1b[0m \x1b[3mitalic\x1b[0m \x1b[4munderline\x1b[0m \x1b[4:3mcurly\x1b[0m \x1b[7minverse\x1b[0m \x1b[9mstrike\x1b[0m\r\n")
		write(b.String())
	case "calc":
		v, err := calc(strings.Join(args, ""))
		if err != nil {
			errorf("calc: %v", err)
			return
		}
		write(strconv.FormatFloat(v, 'g', -1, 64) + "\r\n")
	default:
		errorf("%s: not a command (help lists them)", f[0])
	}
}

// calc evaluates + - * / and parentheses over numbers.
func calc(s string) (float64, error) {
	p := &parser{s: s}
	v, err := p.sum()
	if err == nil && p.i < len(p.s) {
		err = fmt.Errorf("unexpected %q", p.s[p.i:])
	}
	return v, err
}

type parser struct {
	s string
	i int
}

func (p *parser) sum() (float64, error) {
	v, err := p.product()
	for err == nil && p.i < len(p.s) && (p.s[p.i] == '+' || p.s[p.i] == '-') {
		op := p.s[p.i]
		p.i++
		var w float64
		if w, err = p.product(); op == '+' {
			v += w
		} else {
			v -= w
		}
	}
	return v, err
}

func (p *parser) product() (float64, error) {
	v, err := p.atom()
	for err == nil && p.i < len(p.s) && (p.s[p.i] == '*' || p.s[p.i] == '/') {
		op := p.s[p.i]
		p.i++
		var w float64
		if w, err = p.atom(); op == '*' {
			v *= w
		} else {
			v /= w
		}
	}
	return v, err
}

func (p *parser) atom() (float64, error) {
	if p.i >= len(p.s) {
		return 0, fmt.Errorf("unexpected end")
	}
	switch c := p.s[p.i]; {
	case c == '(':
		p.i++
		v, err := p.sum()
		if err == nil {
			if p.i >= len(p.s) || p.s[p.i] != ')' {
				return 0, fmt.Errorf("missing )")
			}
			p.i++
		}
		return v, err
	case c == '-':
		p.i++
		v, err := p.atom()
		return -v, err
	}
	j := p.i
	for j < len(p.s) && (p.s[j] == '.' || p.s[j] >= '0' && p.s[j] <= '9') {
		j++
	}
	v, err := strconv.ParseFloat(p.s[p.i:j], 64)
	if err != nil {
		return 0, fmt.Errorf("unexpected %q", p.s[p.i:])
	}
	p.i = j
	return v, nil
}

func showPrompt() {
	dir, _ := os.Getwd()
	if h := os.Getenv("home"); h != "" && strings.HasPrefix(dir, h) {
		dir = "~" + dir[len(h):]
	}
	write(fmt.Sprintf(prompt, dir))
	write("\x1b7") // save the cursor: the line starts here
	redraw()
}

// redraw rewrites the line after the prompt and puts the cursor at pos.
func redraw() {
	s := "\x1b8\x1b[J" + string(line)
	if back := len(line) - pos; back > 0 {
		s += fmt.Sprintf("\x1b[%dD", back)
	}
	write(s)
}

func write(s string) {
	outMu.Lock()
	defer outMu.Unlock()
	out.WriteString(s)
}

// events: the size readout from the terminal's resize events, and Clear.
// Every line starts name key path; attributes follow as name=value.
func events() {
	f, err := os.Open(ui + "/events")
	check(err)
	// The first layout can come before this subscription: start from
	// the grid as it is.
	cols, _ := os.ReadFile(ui + "/" + term + "/cols")
	rows, _ := os.ReadFile(ui + "/" + term + "/rows")
	put(win+"/ctl", "set bar/size text="+strings.TrimSpace(string(cols))+"x"+strings.TrimSpace(string(rows)))
	in := bufio.NewReader(f)
	for {
		l, err := in.ReadString('\n')
		if err != nil {
			os.Exit(0)
		}
		ev := strings.Fields(l)
		if len(ev) < 3 {
			continue
		}
		switch ev[0] + " " + ev[2] {
		case "resize body/sh":
			var cols, rows string
			for _, a := range ev[3:] {
				if v, ok := strings.CutPrefix(a, "cols="); ok {
					cols = v
				} else if v, ok := strings.CutPrefix(a, "rows="); ok {
					rows = v
				}
			}
			put(win+"/ctl", "set bar/size text="+cols+"x"+rows)
		case "click bar/clear":
			put(term+"/ctl", "reset")
			showPrompt()
			put(win+"/focus", "body/sh")
		}
	}
}

func put(file, s string) {
	f, err := os.OpenFile(ui+"/"+file, os.O_WRONLY|os.O_TRUNC, 0)
	check(err)
	_, err = f.WriteString(s)
	check(err)
	check(f.Close())
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "repl:", err)
		os.Exit(1)
	}
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}
