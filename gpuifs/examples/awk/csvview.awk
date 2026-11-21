# csvview.awk: a CSV viewer written entirely in awk. Sort by any column,
# filter as you type, open a row to see it as a card.
#
#	gpuifs -t CSV awk -f csvview.awk planets.csv
#
# Shows: a client in a language with no libraries at all, columns made
# from the header row (numeric ones right-aligned), host-side sorting with
# sorted=on, an input's coalesced change event answered by reading value,
# a sheet with a description-list, events read through a cat pipe because
# awk's own reads are small.   Needs: M3
#
# Fields are split on commas; quoted fields holding commas are not handled.

BEGIN {
	k = ENVIRON["gpuifs"]; if(k == "") k = "/mnt/gpui"
	if(ARGC < 2) { print "usage: awk -f csvview.awk file.csv" > "/fd/2"; exit 1 }
	file = ARGV[1]
	R = "windows/main/root"

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
	put("ctl", "window main title=" quote(name) " size=920,600 min=520,320 pos=center")
	put(R "/tree", \
		"div root  style='v_flex size_full bg=background'\n" \
		"  div top  style='h_flex items_center gap=8 p=12 border_b_1 border_color=border'\n" \
		"    text name  style='font_semibold flex_1'  text=" quote(name) "\n" \
		"    input q  placeholder=Filter…  flags=cleanable  style=w=260\n" \
		"      icon prefix  name=search\n" \
		"  table t  stripe=on  selectable=row  sortable=on  sorted=on  resizable=on  style=flex_1\n" \
		"  status-bar st\n" \
		"    text left  style='text_xs text_color=muted_foreground'\n")

	cols = ""
	for(i = 1; i <= ncol; i++)
		cols = cols "c" i "\t" head[i] "\t" (numeric[i] ? 100 : 180) "\tsort" (numeric[i] ? "\talign=right" : "") "\n"
	put(R "/t/columns", cols)
	put("windows/main/overlays/ctl", "new sheet card side=right size=380")
	put("windows/main/overlays/card/ctl", "new description-list facts columns=1 bordered=on")
	put("keymap", "cmd-f find\nescape clear\n")
	show("")

	ev = "cat " k "/events"
	while((ev | getline line) > 0) {
		n = split(line, w, " ")
		e = w[1]
		if(e == "change" && has("node=root/top/q"))
			show(get(R "/top/q/value"))
		else if(e == "open" && has("node=root/t"))
			card(attr("row"))
		else if(e == "action" && attr("id") == "find")
			put("windows/main/focus", "root/top/q")
		else if(e == "action" && attr("id") == "clear") {
			put(R "/top/q/value", ""); show("")
		} else if(e == "close" || e == "quit")
			put("ctl", "quit")
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
	put(R "/t/rows", out)
	put(R "/st/left/text", (shown == nrows ? nrows " rows" : shown " of " nrows " rows"))
}

function card(id,    f, i, out) {
	split(rows[id], f, ",")
	out = ""
	for(i = 1; i <= ncol; i++) out = out head[i] "\t" f[i] "\n"
	put("windows/main/overlays/card/facts/items", out)
	put("windows/main/overlays/card/title", f[1])
	put("windows/main/overlays/card/ctl", "open")
}

# put file text: one open, one write, one close
function put(file, s,    p) {
	p = k "/" file
	printf "%s", s > p
	close(p)
}

function get(file,    p, s, line) {
	p = k "/" file; s = ""
	while((getline line < p) > 0) s = s line
	close(p)
	return s
}

function attr(name,    i, l) {
	l = length(name) + 1
	for(i = 2; i <= n; i++)
		if(substr(w[i], 1, l) == name "=") return substr(w[i], l + 1)
	return ""
}

function has(word,    i) {
	for(i = 2; i <= n; i++) if(w[i] == word) return 1
	return 0
}

# quote s by Plan 9 rules, only when it needs it
function quote(s) {
	if(s !~ /[ \t'=]/ && s != "") return s
	gsub(/'/, "''", s)
	return "'" s "'"
}
