# regex.rb: a regular-expression tester in Ruby. Type a pattern and some
# text; every match lights up in the text, and a table lists the matches
# and their groups.
#
#	uitree -t Regex -d ALPINE:#L ruby regex.rb
#
# Ruby is a Linux program here, from an Alpine tree run by h9's Linux ABI,
# with the tree at $ui. Ruby's own Regexp does the matching; the client is
# File.write and File.foreach and nothing else.
#
# Shows: a styled-text node whose runs file (start length style lines, in
# bytes) highlights each match with no markup in the text itself, coalesced
# change events from two inputs and three switches answered by reading
# their value files, a field error for a bad pattern, a table of matches,
# everything for one keystroke in one ctl write.   Needs: M3

UI = ENV.fetch("ui", "/mnt/ui")
WIN = "win/main"

# One open, one write, one close: a ctl applies its lines at close.
def put(path, s) = File.write("#{UI}/#{path}", s)
def get(path) = File.read("#{UI}/#{path}")
def ctl(lines) = put("#{WIN}/ctl", lines.join("\n") + "\n")
# Plan 9 quoting, only where it is needed.
def q(s) = (!s.empty? && s !~ /[\s'=]/) ? s : "'" + s.gsub("'", "''") + "'"

SAMPLE = <<~TEXT
  Plan 9 from Bell Labs shipped in 1992; Inferno followed in 1996.
  Mail rob@plan9.bell-labs.com or ken@plan9.bell-labs.com, or call
  +1 908 582-3000. uitreefs 0.2 was tagged on 2026-11-22.
TEXT

put("#{WIN}/ctl", "set . title=Regex size=900,620 min=640,480 pos=center")
put("#{WIN}/tree", <<~UI)
  div root  : v-flex size-full p=20 gap=14 bg=background
    form f  labels=side  label-width=90  tag=re
      field pat  label=Pattern
        input in  value='\\b\\w+@[\\w.-]+'  : font-family=monospace
      field opts  label=Options
        div row  : h-flex gap=20
          switch i  label='Ignore case'
          switch m  label='Dot matches newline'
          switch x  label=Extended
      field text  label=Text
        textarea in  rows=5  : font-family=monospace
    div out  : v-flex gap=8 flex-1
      text h  text=Matches  : text-sm font-semibold
      styled-text hl  : p=12 rounded-md border-1 border-color=border bg=muted font-family=monospace text-sm
      table t  stripe  : flex-1
UI
put("#{WIN}/f/text/in/value", SAMPLE)
put("#{WIN}/out/t/columns", "n # 40 align=right\nat Offset 70 align=right\nmatch Match 260\ngroups Groups 320\n")

def run
  src = get("#{WIN}/f/pat/in/value").chomp
  text = get("#{WIN}/f/text/in/value")
  flags = 0
  flags |= Regexp::IGNORECASE if get("#{WIN}/f/opts/row/i/value").start_with?("on")
  flags |= Regexp::MULTILINE if get("#{WIN}/f/opts/row/m/value").start_with?("on")
  flags |= Regexp::EXTENDED if get("#{WIN}/f/opts/row/x/value").start_with?("on")
  begin
    re = Regexp.new(src, flags)
  rescue RegexpError => e
    return ctl(["set f/pat error=#{q(e.message)}"])
  end
  ms = []
  text.scan(re) { ms << Regexp.last_match } unless src.empty?
  # runs: byte offsets into text, alternating two highlight colors.
  runs = ms.each_with_index.filter_map do |m, i|
    s, e = m.byteoffset(0)
    next if s == e
    "#{s} #{e - s} bg=#{i.even? ? 'warning' : 'info'} text-color=background font-bold"
  end
  rows = ms.each_with_index.map do |m, i|
    groups = m.captures.each_with_index.map { |g, j| "#{j + 1}=#{g.inspect}" }.join(" ")
    groups += " " + m.named_captures.map { |k, v| "#{k}=#{v.inspect}" }.join(" ") unless m.names.empty?
    "m#{i} #{i + 1} #{m.begin(0)} #{q(m[0].inspect)} #{q(groups.strip)}"
  end
  ctl([
    "set f/pat error=",
    "set out/h text=#{q(ms.empty? ? 'No matches' : "#{ms.size} match#{ms.size == 1 ? '' : 'es'}")}",
    "set out/hl text=<<END_OF_TEXT", text.chomp, "END_OF_TEXT",
    "set out/hl runs=<<END", *runs, "END",
    "set out/t rows=<<END", *rows, "END",
  ])
end

run
File.foreach("#{UI}/events") do |line|
  name, key, _path, *_rest = line.split
  run if key == "re" && %w[change submit].include?(name)
end
