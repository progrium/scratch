\ rpn.fs: an RPN calculator in Forth whose stack is Forth's own data
\ stack. The keypad's keys are Forth words, the line takes any Forth at
\ all, and a word you define with : name ... ; becomes a key of its own.
\
\	uitree -t RPN -d ALPINE:#L gforth rpn.fs
\
\ gforth is a Linux program here, from an Alpine tree run by h9's Linux
\ ABI, and it reaches the tree at $ui with open-file and read-line.
\ Nothing the client does leaves anything on the data stack between
\ events, so the user's numbers are simply the stack: a key is the word
\ it names, passed to evaluate, and the stack view is depth and pick.
\ catch keeps a bad word or an underflow from ending the client, and
\ outfile-id points at a scratch file while user code runs, so what . or
\ emit print shows up in the window. BASE is shared too: the DEC, HEX
\ and BIN buttons set it, and typing hex or decimal moves the buttons.
\
\ Shows: a Linux Forth client with no libraries, a keypad in a grid
\ whose tags are Forth source, a button-group following state the user
\ can also change by typing, buttons made with new for words the user
\ defines, the stack view rewritten as one tree document per update,
\ an output panel fed from a here-value, echoes (via=ctl) skipped.
\ Needs: M3

\ The tree, at $ui (uitree sets it), or /mnt/ui in a Plan 9 view.
s" ui" getenv dup 0= [if] 2drop s" /mnt/ui" [then] 2constant ui

\ Strings are built in buffers: p for file paths, o for what goes to a
\ ctl, src for the Forth that runs. Each has a length variable.
create pbuf 512 allot  variable plen
: p+ ( a u -- ) tuck pbuf plen @ + swap move plen +! ;
: path ( a u -- a' u' ) 0 plen ! ui p+ s" /" p+ p+ pbuf plen @ ;

create obuf 65536 allot  variable olen
: o+ ( a u -- ) tuck obuf olen @ + swap move olen +! ;
: oc ( c -- ) obuf olen @ + c! 1 olen +! ;
: eol ( -- ) 10 oc ;
\ Plan 9 quoting: a quoted word, with '' for a quote inside it.
: q+ ( a u -- ) [char] ' oc bounds ?do i c@ dup [char] ' = if dup oc then oc loop [char] ' oc ;

create src 1024 allot  variable slen
: src+ ( a u -- ) tuck src slen @ + swap move slen +! ;

\ put: one open, one write, one close. A ctl applies its lines at close.
: put ( a u name u -- ) path w/o open-file throw >r r@ write-file throw r> close-file throw ;
: ctl ( -- ) obuf olen @ s" win/main/ctl" put 0 olen ! ;
: slurp ( name u buf size -- a u )
	2swap r/o open-file throw >r over swap r@ read-file throw r> close-file throw ;
create vbuf 1024 allot
: value@ ( -- a u ) s" win/main/line/value" path vbuf 1024 slurp -trailing ;

\ Numbers in a given base, then the stack shown in the current one with
\ the other usual base beside it.
: n>s ( n -- a u ) s>d tuck dabs <# #s rot sign #> ;
: n>base ( n b -- a u ) base @ >r base ! n>s r> base ! ;
: alt+ ( n -- ) base @ 10 = if s" $" o+ 16 n>base o+ else s" #" o+ 10 n>base o+ then ;
: base-word ( -- a u ) base @ case 16 of s" hex" endof 2 of s" bin" endof s" dec" rot endcase ;

\ The screen.
s" set . title=RPN size=440,720 min=380,600 pos=center" s" win/main/ctl" put
\ | puts the rest of its line into o, so the screen is written as it looks.
: | ( "line" -- ) 0 parse o+ eol ;
| div root  : v-flex size-full p=16 gap=12 bg=background
|   div stack  : v-flex justify-end gap=2 px=14 py=10 h=228 rounded-lg bg=muted overflow-hidden
|     text empty  text='The stack is empty.'  : text-sm text-color=muted-foreground
|   div out  : h-flex gap=8 items-start min-h=24
|     text t  text='Type Forth below, or use the keys.'  : flex-1 text-sm text-color=muted-foreground font-family=monospace
|     text st  text='depth 0'  : text-xs text-color=muted-foreground
|   input line  placeholder='3 4 +   or   : sq dup * ;'  tag=line  : font-family=monospace
|   button-group base  value=dec  tag=base
|     button dec  label=DEC
|     button hex  label=HEX
|     button bin  label=BIN
|   grid pad  cols=4  gap=6
|     button kdup  label=dup  tag=k:dup  secondary
|     button kdrop  label=drop  tag=k:drop  secondary
|     button kswap  label=swap  tag=k:swap  secondary
|     button kover  label=over  tag=k:over  secondary
|     button d7  label=7  tag=d:7
|     button d8  label=8  tag=d:8
|     button d9  label=9  tag=d:9
|     button kdiv  label=/  tag=k:/  primary
|     button d4  label=4  tag=d:4
|     button d5  label=5  tag=d:5
|     button d6  label=6  tag=d:6
|     button kmul  label=*  tag=k:*  primary
|     button d1  label=1  tag=d:1
|     button d2  label=2  tag=d:2
|     button d3  label=3  tag=d:3
|     button ksub  label=-  tag=k:-  primary
|     button d0  label=0  tag=d:0
|     button kneg  label=negate  tag=k:negate  secondary
|     button kmod  label=mod  tag=k:mod  secondary
|     button kadd  label=+  tag=k:+  primary
|     button kenter  label=Enter  tag=enter  primary  : col-span=2
|     button kback  label=⌫  tag=back  outline
|     button kclear  label=clear  tag=k:clearstack  outline
|   text wl  text='Your words'  : text-sm font-semibold
|   div words  : h-flex flex-wrap gap=6
|     text none  text='Define one with  : name ... ;  and it becomes a key.'  : text-sm text-color=muted-foreground
obuf olen @ s" win/main/tree" put 0 olen !

\ The stack view: levels 1 (the top) up to 8, top at the bottom, as on
\ an HP calculator. Nothing of ours is on the stack here, so depth is
\ the user's depth and i pick reaches their items.
variable d
: row ( level -- ) \ with level on top, the item it names is level pick
	s"   div r" o+ dup n>s o+ s"   : h-flex w-full items-center gap=10" o+ eol
	s"     text l  text=" o+ dup n>s o+ s" :  : w=28 text-sm text-color=muted-foreground font-family=monospace" o+ eol
	s"     text a  text=" o+ dup pick alt+ s"   : text-xs text-color=muted-foreground font-family=monospace" o+ eol
	s"     div sp  : flex-1" o+ eol
	s"     text v  text=" o+ 1- pick n>s q+ s"   : text-xl font-semibold font-family=monospace" o+ eol ;
: stack+ ( -- )
	depth d !
	s" tree stack <<END" o+ eol
	s" div stack  : v-flex justify-end gap=2 px=14 py=10 h=228 rounded-lg bg=muted overflow-hidden" o+ eol
	d @ 0= if s"   text empty  text='The stack is empty.'  : text-sm text-color=muted-foreground" o+ eol then
	d @ 8 > if s"   text more  text=" o+ s" ⋮ " pad place d @ 8 - n>s pad +place s"  more" pad +place pad count q+
		s"   : text-xs text-color=muted-foreground" o+ eol then
	d @ 8 min 0 ?do d @ 8 min i - row loop
	s" END" o+ eol
	s" set out/st text=" o+ s" depth " pad place d @ n>s pad +place pad count q+ eol ;

\ Running Forth: whatever is in src, with output to a scratch file. catch
\ puts the stack back as it was if the source throws, apart from the
\ source string itself, which we drop.
s" /tmp/rpn.out" 2constant outname
0 value ofid
variable err
: run ( -- )
	outname w/o create-file throw to ofid
	outfile-id >r ofid to outfile-id
	src slen @ ['] evaluate catch
	r> to outfile-id ofid close-file throw
	dup err ! if 2drop state off then 0 slen ! ;
: msg ( n -- a u )
	case
	-4 of s" stack underflow" endof
	-3 of s" stack overflow" endof
	-10 of s" division by zero" endof
	-13 of s" undefined word" endof
	-14 of s" compile-only word" endof
	-9 of s" invalid memory address" endof
	-24 of s" invalid numeric argument" endof
	s" error " pad place dup n>s pad +place pad count rot
	endcase ;
create outb 2048 allot
: mono ( -- ) s"  : flex-1 text-sm font-family=monospace text-color=" o+ ;
\ What the source printed, then ok, as Forth's own prompt says it; or
\ compiled, when a definition is still open; or the error.
: output+ ( -- )
	err @ if s" set out/t text=" o+ err @ msg q+ mono s" danger" o+ eol exit then
	s" set out/t text=<<END" o+ eol outname outb 2048 slurp o+
	state @ if s"  compiled" else s"  ok" then o+ eol s" END" o+ eol
	s" set out/t" o+ mono s" foreground" o+ eol ;

\ A word the user defines gets a key: new button, tagged with its name,
\ so clicking it is the same as typing it. Names already given keys are
\ kept in a buffer as " a b c ".
variable lastnt  latest lastnt !
create names 4096 allot  s"  " names place
variable nwords
: words+ ( -- )
	latest dup lastnt @ = if drop exit then dup lastnt !
	name>string
	s"  " pad place 2dup pad +place s"  " pad +place
	names count pad count search nip nip if 2drop exit then
	2dup names +place s"  " names +place
	nwords @ 0= if s" delete words/none" o+ eol then 1 nwords +!
	s" new button words/w" o+ nwords @ n>s o+ s"  label=" o+ 2dup q+
	s"  tag=" o+ s" k:" pad place pad +place pad count q+ s"  outline sm  : font-family=monospace" o+ eol ;

: base+ ( -- ) s" set base value=" o+ base-word o+ eol ;
: show ( -- ) output+ words+ stack+ base+ ctl ;
: clearline ( -- ) s" set line value=" o+ eol ;

\ Events. Each line is name key path attr=value ...; split takes a word.
create ebuf 4096 allot
2variable ev-name  2variable ev-key  2variable ev-rest
: split ( a u -- rest u word u ) bl skip over >r bl scan over r@ - r> swap ;
: parse-ev ( a u -- ) split ev-name 2! split ev-key 2! ev-rest 2! ;
: name? ( a u -- f ) ev-name 2@ compare 0= ;
: is-key? ( a u -- f ) ev-key 2@ compare 0= ;
: starts? ( a u p u -- f ) tuck 2>r min 2r> compare 0= ;
: attr ( a u -- a' u' ) ev-rest 2@ 2swap search if split 2nip [char] = scan 1 /string else 2drop 0 0 then ;
: echo? ( -- f ) s" via=ctl" ev-rest 2@ 2swap search nip nip ;

\ The line's text first, if any, then the key's word, as one source.
: entry+ ( -- ) value@ dup if src+ s"  " src+ clearline else 2drop then ;
: press ( -- ) entry+ ev-key 2@ 2 /string src+ run show ;
: enter ( -- ) value@ dup 0= if 2drop s" dup" then src+ clearline run show ;
: digit ( -- ) s" set line value=" o+ value@ pad place ev-key 2@ 2 /string pad +place pad count q+ eol ctl ;
: back ( -- )
	value@ dup if s" set line value=" o+ 1- q+ eol ctl exit then
	2drop s" drop" src+ run show ;
: base! ( -- )
	s" value=" attr 2dup s" hex" compare 0= if 2drop 16 base ! else
	2dup s" bin" compare 0= if 2drop 2 base ! else 2drop decimal then then
	0 err ! stack+ ctl ;

: handle ( a u -- )
	parse-ev echo? if exit then
	s" click" name? s" action" name? or if
		ev-key 2@ s" k:" starts? if press exit then
		ev-key 2@ s" d:" starts? if digit exit then
		s" enter" is-key? if enter exit then
		s" back" is-key? if back exit then
	then
	s" submit" name? s" line" is-key? and if enter exit then
	s" change" name? s" base" is-key? and if base! exit then ;

0 value efid
: main ( -- )
	latest lastnt !
	s" events" path r/o open-file throw to efid
	begin ebuf 4096 efid read-line throw while ebuf swap handle repeat drop
	bye ;
main
