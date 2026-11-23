# Ported from uitreefs/examples to spec draft 0.2 (dashed names) for the
# conformance suite's tree-building check.
# csvview.awk: a CSV viewer written entirely in awk. Sort by any column,
# filter as you type, open a row to see it as a card.
#
#	uitree -t CSV awk -f csvview.awk planets.csv
#
# Shows: a client in a language with no libraries at all, columns made
# from the header row (numeric ones right-aligned), host-side sorting with
# sorted=on, an input's coalesced change event answered by reading value,
# a sheet with a description-list, events read straight from the events
# file with getline and split into name ($1), key ($2) and path ($3).
# Needs: M3
#
# Fields are split on commas; quoted fields holding commas are not handled.

BEGIN {
	ui = ENVIRON["ui"]; if(ui == "") ui = "/mnt/ui"
	if(ARGC < 2) { print "usage: awk -f csvview.awk file.csv" > "/fd/2"; exit 1 }
	file = ARGV[1]
	M = "win/main"

	while((getline line < file) > 0) {
		sub(/\r$/, "", line)
		if(ncol == 0) {
			ncol = split(line, head, ",")
			for(i = 1; i <= ncol; i++) numeric[i] = 1
			continue
		}
		rows[++nrows] = line
		split(line, f, ",")
		for(i = 1; i <= ncol; i++)
			if(f[i] !~ /^-?[0-9.]+$/) numeric[i] = 0
	}
	close(file)

	name = file; sub(/.*\//, "", name)
	put(M "/ctl", "set . title=" quote(name) " size=920,600 min=520,320 pos=center")
	put(M "/tree", \
		"div root  : v-flex size-full bg=background\n" \
		"  div top  : h-flex items-center gap=8 p=12 border-b-1 border-color=border\n" \
		"    text name  text=" quote(name) "  : font-semibold flex-1\n" \
		"    input q  cleanable  placeholder=Filter…  tag=filter  : w=260\n" \
		"      icon prefix  name=search\n" \
		"  table t  stripe  sortable  sorted  resizable  selectable=row  tag=table  : flex-1\n" \
		"  status-bar st\n" \
		"    text left  : text-xs text-color=muted-foreground\n")

	cols = ""
	for(i = 1; i <= ncol; i++)
		cols = cols "c" i " " quote(head[i]) " " width(i) " sort" (numeric[i] ? " align=right" : "") "\n"
	put(M "/t/columns", cols)
	put(M "/over/ctl", "new sheet card side=right size=380\nnew description-list card/facts bordered columns=1")
	put("keys", "cmd-f find\nescape clear\n")
	show("")

	# Every event line starts name key path; split on blanks is enough.
	events = ui "/events"
	while((getline line < events) > 0) {
		n = split(line, w, " ")
		ev = w[1] " " w[2]
		if(ev == "change filter")
			show(get(M "/top/q/value"))
		else if(ev == "open table")
			card(attr("row"))
		else if(ev == "action find")
			put(M "/focus", "top/q")
		else if(ev == "action clear") {
			put(M "/top/q/value", ""); show("")
		}
	}
	exit 0
}

# show q: write the rows containing q (any case), with their row numbers as ids
function show(q,    i, out, shown, r) {
	q = tolower(q); out = ""; shown = 0
	for(i = 1; i <= nrows; i++) {
		if(q != "" && index(tolower(rows[i]), q) == 0) continue
		r = rows[i]; gsub(/,/, "\t", r)
		out = out i "\t" r "\n"; shown++
	}
	put(M "/t/rows", out)
	put(M "/st/left/text", (shown == nrows ? nrows " rows" : shown " of " nrows " rows"))
}

function card(id,    f, i, out) {
	split(rows[id], f, ",")
	out = ""
	for(i = 1; i <= ncol; i++) out = out quote(head[i]) " " quote(f[i]) "\n"
	put(M "/over/card/facts/items", out)
	put(M "/over/card/title", f[1])
	put(M "/over/card/ctl", "open")
}

# put file text: one open, one write, one close
# A column wide enough for its header: about 8px a character, plus room
# for the sort arrows.
function width(i,    w, h) {
	w = numeric[i] ? 100 : 180
	h = length(head[i]) * 8 + 44
	return h > w ? h : w
}

function put(file, s,    p) {
	p = ui "/" file
	printf "%s", s > p
	close(p)
}

function get(file,    p, s, line) {
	p = ui "/" file; s = ""
	while((getline line < p) > 0) s = s line
	close(p)
	return s
}

function attr(name,    i, l) {
	l = length(name) + 1
	for(i = 4; i <= n; i++)
		if(substr(w[i], 1, l) == name "=") return substr(w[i], l + 1)
	return ""
}

# quote s by Plan 9 rules, only when it needs it
function quote(s) {
	if(s !~ /[ \t'=]/ && s != "") return s
	gsub(/'/, "''", s)
	return "'" s "'"
}
