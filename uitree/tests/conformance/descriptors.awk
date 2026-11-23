# descriptors.awk: turn a host's type descriptors ($ui/types/*/spec,
# components.md § The descriptor) into rc checks that the host accepts
# what they list and refuses what they don't. 27-descriptors.rc runs it:
#
#	awk -f descriptors.awk $ui/types/*/spec >/tmp/checks.rc
#
# Each check is a line calling one of 27-descriptors.rc's functions:
#
#	fail TEXT                          a check the awk itself could make: print it as a failure
#	expect WANT LABEL FILE WORDS...   write WORDS to FILE, want "ok" or a phrase
#	expectfile LABEL PATH             PATH exists
#	expectval VALUE LABEL PATH        PATH reads VALUE and one newline
#	expectverb VERB LABEL PATH        the ctl help at PATH lists VERB
#
# Paths are relative to the window: dc/t-NAME for nodes, over/t-NAME for
# overlays, both made on the window ctl ($r/ctl). Props of form child,
# data and bytes have no value this can make up, so only their files and
# readonly refusals are checked.

function q(s) {
	gsub(/\047/, "\047\047", s)
	return "\047" s "\047"
}

function emit(kind, line) {
	if(kind == "pre")
		pre[++npre] = line
	else
		post[++npost] = line
}

function flush(   i) {
	for(i = 1; i <= npre; i++) print pre[i]
	for(i = 1; i <= npost; i++) print post[i]
	npre = npost = 0
}

# attr(name): the value of name= among fields 3..NF, or "".
function attr(name,   i) {
	for(i = 3; i <= NF; i++)
		if(index($i, name "=") == 1)
			return substr($i, length(name) + 2)
	return ""
}

function hasword(w,   i) {
	for(i = 3; i <= NF; i++)
		if($i == w)
			return 1
	return 0
}

function set(want, label, words) {
	emit("post", "expect " q(want) " " q(label) " $r/ctl " q("set " node " " words))
}

FNR == 1 { flush() }

$1 == "type" {
	type = $2
	tier = attr("tier")
	node = (tier == "overlay" ? "over/t-" : "dc/t-") type
	ntypes++
	if(tier != "element" && tier != "component" && tier != "overlay")
		print "fail " q(type ": tier=" tier " is not element, component or overlay")
	emit("pre", "expect ok " q(type ": new") " $r/ctl " q("new " type " " node))
	emit("pre", "expectfile " q(type ": version") " $k/types/" type "/version")
	set("ok", type ": set with no props", "")
	set("not found", type ": a prop it lacks", "zzqq=1")
	set("bad value", type ": a bare word it lacks", "zzqq")
	next
}

$1 == "prop" {
	name = $2
	form = $3
	label = type ": prop " name
	if(hasword("file"))
		emit("pre", "expectfile " q(label " file") " $r/" node "/" name)
	dflt = attr("default")
	if(dflt != "" && hasword("file"))
		emit("pre", "expectval " q(dflt) " " q(label " default") " $r/" node "/" name)
	good = bad = ""
	badwant = "bad value"
	if(form == "text") good = "hello"
	else if(form == "word") { good = "w"; bad = "\047two words\047" }
	else if(form == "bool") { good = "on"; bad = "maybe" }
	else if(form == "number") {
		good = bad = ""
		lo = attr("min"); hi = attr("max")
		good = (lo != "" ? lo : "1")
		bad = "abc"
		if(hi != "") set("bad value", label "=" (hi + 1) " (over max=" hi ")", name "=" (hi + 1))
		if(lo != "") set("bad value", label "=" (lo - 1) " (under min=" lo ")", name "=" (lo - 1))
	}
	else if(index(form, "enum=") == 1) {
		split(substr(form, 6), vals, ",")
		good = vals[1]
		bad = "zzqq"
	}
	else if(form == "path") { good = "dc"; bad = "nope/zzqq"; badwant = "not found" }
	else if(form != "child" && form != "data" && form != "bytes")
		print "fail " q(label ": unknown form " form)
	if(hasword("readonly")) {
		if(good != "") set("bad value", label " is read-only", name "=" good)
	} else {
		if(good != "") set("ok", label "=" good, name "=" good)
		if(bad != "") set(badwant, label "=" bad, name "=" bad)
	}
	next
}

$1 == "word" {
	for(i = 2; i <= NF; i++) {
		if(index($i, "=") > 0) continue
		set("ok", type ": word " $i, $i)
	}
	next
}

$1 == "verb" {
	emit("pre", "expectverb " $2 " " q(type ": verb " $2) " $r/" node "/ctl")
	next
}

$1 == "slot" {
	acc = attr("accepts")
	split(acc, a, ",")
	t = (acc == "" ? "div" : a[1])
	emit("post", "expect ok " q(type ": slot " $2 " takes " t) " $r/ctl " q("new " t " " node "/" $2))
	next
}

$1 == "child" {
	if($2 == "none")
		emit("post", "expect " q("unknown type") " " q(type ": child none") " $r/ctl " q("new div " node "/zzc"))
	else if($2 == "any")
		emit("post", "expect ok " q(type ": child any") " $r/ctl " q("new div " node "/zzc"))
	else {
		split($2, a, ",")
		emit("post", "expect ok " q(type ": child " a[1]) " $r/ctl " q("new " a[1] " " node "/zzc1"))
		listed = 0
		for(i in a) if(a[i] == "div") listed = 1
		if(!listed)
			emit("post", "expect " q("unknown type") " " q(type ": child div not in " $2) " $r/ctl " q("new div " node "/zzc"))
	}
	next
}

$1 == "file" {
	emit("pre", "expectfile " q(type ": file " $2) " $r/" node "/" $2)
	next
}

$1 == "event" || $1 == "" || $1 ~ /^#/ { next }

{ print "fail " q(type ": unknown descriptor line: " $1) }

END {
	flush()
	print "ntypes=" ntypes
}
