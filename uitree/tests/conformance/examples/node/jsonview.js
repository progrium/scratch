// jsonview.js: a JSON explorer in Node. Open a JSON file as a tree,
// filter it by key or value, and pick a node to see its path, type and
// value.
//
//	uitree -t JSON -d ALPINE:#L node jsonview.js [file.json]
//
// Node is a Linux program here, from an Alpine tree run by h9's Linux ABI,
// and it reaches the tree at $ui with fs alone: no packages. Every event
// line starts name key path, so line.split(" ") is the whole parser, and
// every update is one fs.writeFileSync of set lines to the window's ctl,
// applied together in one frame.
//
// Shows: a tree component fed as lines of words (no tabs) with its
// expanded file, a cleanable search input whose coalesced change event is
// answered by reading value, an editor holding the picked value, a
// description-list, a status bar, data with quotes and blanks quoted by
// the one Plan 9 rule.   Needs: M3

const fs = require("fs");
const readline = require("readline");

const ui = process.env.ui || "/mnt/ui";
const win = "win/main";

// One open, one write, one close: a ctl applies its lines at close.
const put = (path, s) => fs.writeFileSync(`${ui}/${path}`, s);
const get = (path) => fs.readFileSync(`${ui}/${path}`, "utf8");
const ctl = (lines) => put(`${win}/ctl`, lines.join("\n") + "\n");
// Plan 9 quoting: only what needs it.
const q = (s) => (s !== "" && !/[\s'=]/.test(s) ? s : `'${s.replace(/'/g, "''")}'`);

const file = process.argv[2] || "sample.json";
const doc = JSON.parse(fs.readFileSync(file, "utf8"));

// Number every value: ids are words, labels can be anything.
const nodes = []; // {id, parent, key, path, value}
(function walk(v, parent, key, path) {
	const id = `n${nodes.length}`;
	nodes.push({ id, parent, key, path, value: v });
	if (v && typeof v === "object")
		for (const [k, c] of Object.entries(v))
			walk(c, id, Array.isArray(v) ? `[${k}]` : k,
				Array.isArray(v) ? `${path}[${k}]` : /^[A-Za-z_$][\w$]*$/.test(k) ? `${path}.${k}` : `${path}[${JSON.stringify(k)}]`);
})(doc, "-", file.replace(/.*\//, ""), "$");
const byId = new Map(nodes.map((n) => [n.id, n]));

const kind = (v) => (v === null ? "null" : Array.isArray(v) ? "array" : typeof v);
const icon = { object: "folder", array: "list", string: "type", number: "hash", boolean: "toggle-left", null: "circle-off" };
function short(v) {
	switch (kind(v)) {
		case "object": return `{${Object.keys(v).length}}`;
		case "array": return `[${v.length}]`;
		case "string": { const s = JSON.stringify(v); return s.length > 48 ? s.slice(0, 47) + "…\"" : s; }
		default: return String(v);
	}
}
// A tree item line: id parent label icon=
const item = (n) => `${n.id} ${n.parent} ${q(`${n.key}: ${short(n.value)}`)} icon=${icon[kind(n.value)]}`;

// The nodes a filter keeps: matching nodes and their ancestors.
function keep(filter) {
	const f = filter.trim().toLowerCase();
	if (!f) return nodes;
	const keep = new Set();
	for (const n of nodes) {
		const leaf = !(n.value && typeof n.value === "object");
		if (n.key.toLowerCase().includes(f) || (leaf && String(n.value).toLowerCase().includes(f)))
			for (let p = n; p && !keep.has(p.id); p = byId.get(p.parent)) keep.add(p.id);
	}
	return nodes.filter((n) => keep.has(n.id));
}

put(`${win}/ctl`, "set . title=" + q(`${file.replace(/.*\//, "")} — JSON`) + " size=1000,640 min=700,420 pos=center");
put(`${win}/tree`, `div root  : v-flex size-full bg=background
  div top  : h-flex items-center gap=8 px=12 py=8 border-b-1 border-color=border
    icon i  name=braces  : size=18 text-color=primary
    text name  text=${q(file.replace(/.*\//, ""))}  : font-semibold flex-1
    input q  cleanable  placeholder='Filter keys and values'  tag=filter  : w=300
  resizable split  dir=row  : flex-1
    panel left  size=420  min=260
      tree t  selectable  tag=pick  : size-full p=4
    panel right
      div v  : v-flex size-full p=16 gap=12
        text path  text='Pick a value'  : font-family=monospace text-sm font-semibold
        description-list facts  bordered  columns=1
        editor val  readonly  soft-wrap  language=json  : flex-1
  status-bar st
    text left  : text-xs text-color=muted-foreground
`);
put("keys", "cmd-f find\nescape clear\n");

function show(filter) {
	const shown = keep(filter);
	// Unfiltered, the top two levels are open; filtered, every match's path.
	const open = filter
		? shown.filter((n) => n.value && typeof n.value === "object")
		: shown.filter((n) => n.parent === "-" || byId.get(n.parent)?.parent === "-");
	// The whole list as a here-value, and what is open, in one write.
	ctl([
		"set split/left/t items=<<END", ...shown.map(item), "END",
		`set split/left/t expanded=${q(open.map((n) => n.id).join(" "))}`,
		`set st/left text=${q(filter ? `${shown.length} of ${nodes.length} values match` : `${nodes.length} values`)}`,
	]);
}

function pick(id) {
	const n = byId.get(id);
	if (!n) return;
	const v = n.value;
	const facts = [`Type ${kind(v)}`];
	if (kind(v) === "object") facts.push(`Keys ${Object.keys(v).length}`);
	if (kind(v) === "array") facts.push(`Items ${v.length}`);
	if (kind(v) === "string") facts.push(`Length ${v.length}`);
	facts.push(`Bytes ${Buffer.byteLength(JSON.stringify(v))}`);
	ctl([
		`set split/right/v/path text=${q(n.path)}`,
		"set split/right/v/facts items=<<END", ...facts, "END",
		"set split/right/v/val value=<<END", JSON.stringify(v, null, 2), "END",
	]);
}

show("");
const ev = readline.createInterface({ input: fs.createReadStream(`${ui}/events`) });
ev.on("line", (line) => {
	const [name, key, path, ...rest] = line.split(" ");
	const a = Object.fromEntries(rest.map((w) => w.split("=")).filter((p) => p.length === 2));
	if (name === "change" && key === "filter") show(get(`${win}/top/q/value`));
	else if (name === "select" && key === "pick") pick(a.value);
	else if (name === "action" && key === "find") put(`${win}/focus`, "top/q");
	else if (name === "action" && key === "clear") { ctl(["set top/q value="]); show(""); }
});
ev.on("close", () => process.exit(0));
