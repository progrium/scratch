// Command clock is an analog clock drawn on a canvas. It draws the face
// once, then moves three hands each second with one short ctl write each.
//
//	GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o clock .
//	uitree -t Clock ./clock
//
// Shows: canvas ops written once and then edited by id with set, theme
// tokens for every color (switch the system to dark mode and the clock
// follows), hover:fill= on the center dot with no round trip, a goroutine
// on the events file beside a ticker, a digital readout set with one
// window ctl write per second. Closing the window quits by itself.
// Needs: M4
package main

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"strings"
	"time"
)

var ui = env("ui", "/mnt/ui")

const (
	size = 280.0
	c    = size / 2
)

func main() {
	r := "win/main"
	put(r+"/ctl", "set . title=Clock size=320,380 resizable=off pos=center")
	put(r+"/tree", `div root  : v-flex size-full items-center justify-center gap=12 bg=background
  canvas face  on=click  : size=280
  text time  : text-2xl font-semibold font-family=monospace
  text date  : text-sm text-color=muted-foreground
`)

	var ops strings.Builder
	fmt.Fprintf(&ops, "circle rim %g %g %g fill=muted border=border\n", c, c, c-4)
	for i := 0; i < 60; i++ {
		a := float64(i) * math.Pi / 30
		inner, w, col := c-16, 1.0, "muted-foreground"
		if i%5 == 0 {
			inner, w, col = c-28, 3, "foreground"
		}
		x1, y1 := polar(a, inner)
		x2, y2 := polar(a, c-10)
		fmt.Fprintf(&ops, "path tick%d M%.1f,%.1f L%.1f,%.1f stroke=%s width=%g cap=round\n", i, x1, y1, x2, y2, col, w)
	}
	ops.WriteString(hand("hour", 0, c*0.5, "foreground", 6))
	ops.WriteString(hand("min", 0, c*0.75, "foreground", 4))
	ops.WriteString(hand("sec", 0, c*0.85, "danger", 2))
	fmt.Fprintf(&ops, "circle pin %g %g 6 fill=danger hover:fill=primary\n", c, c)
	put(r+"/face/ops", ops.String())

	go events()
	for now := range tick() {
		h := float64(now.Hour()%12) + float64(now.Minute())/60
		m := float64(now.Minute()) + float64(now.Second())/60
		s := float64(now.Second())
		// set id geometry: one write per hand
		put(r+"/face/ctl", "set hour "+geom(h*math.Pi/6, c*0.5)+"\n"+
			"set min "+geom(m*math.Pi/30, c*0.75)+"\n"+
			"set sec "+geom(s*math.Pi/30, c*0.85))
		put(r+"/ctl", "set time text="+now.Format("15:04:05")+"\n"+
			"set date text='"+now.Format("Monday, 2 January")+"'")
	}
}

func tick() <-chan time.Time {
	ch := make(chan time.Time, 1)
	ch <- time.Now()
	go func() {
		for t := range time.Tick(time.Second) {
			ch <- t
		}
	}()
	return ch
}

func polar(a, r float64) (float64, float64) {
	return c + r*math.Sin(a), c - r*math.Cos(a)
}

func geom(a, r float64) string {
	x, y := polar(a, r)
	return fmt.Sprintf("M%g,%g L%.1f,%.1f", c, c, x, y)
}

func hand(id string, a, r float64, col string, w float64) string {
	return fmt.Sprintf("path %s %s stroke=%s width=%g cap=round\n", id, geom(a, r), col, w)
}

// events exits when the stream ends: the app quit.
func events() {
	f, err := os.Open(ui + "/events")
	check(err)
	in := bufio.NewReader(f)
	for {
		if _, err := in.ReadString('\n'); err != nil {
			os.Exit(0)
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
		fmt.Fprintln(os.Stderr, "clock:", err)
		os.Exit(1)
	}
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}
