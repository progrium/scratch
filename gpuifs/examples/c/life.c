/*
 * life: Conway's Game of Life on a canvas, as a 9front C client.
 * Click cells to toggle them, Run to animate, Step, Random and Clear.
 *
 *	gpuifs -t Life --root $H9ROOT rc -c 'mk install && ./life'
 *
 * (The built-in root has no compiler, so this builds in a full 9front
 * tree; the built binary then runs on --root builtin.)
 *
 * Shows: a C client with libc's own tokenize(2) for event lines and
 * bio(2) for an 8 KiB events reader, a second process sharing memory
 * (rfork RFMEM) for the event loop, the whole board written as one ops
 * file per generation, mouse_down x= y= mapped to cells, button labels
 * changed from C.   Needs: M4
 */
#include <u.h>
#include <libc.h>
#include <bio.h>

enum {
	N = 48,		/* cells per side */
	Cell = 12,	/* pixels per cell */
};

char *k = "/mnt/gpui";
char *board = "windows/main/root/board";
uchar grid[N][N];
int running;
int dirty = 1;
QLock lk;

void
put(char *file, char *fmt, ...)
{
	char path[256], *s;
	va_list arg;
	int fd, n;

	snprint(path, sizeof path, "%s/%s", k, file);
	va_start(arg, fmt);
	s = vsmprint(fmt, arg);
	va_end(arg);
	if(s == nil)
		sysfatal("vsmprint: %r");
	n = strlen(s);
	if((fd = open(path, OWRITE|OTRUNC)) < 0)
		sysfatal("open %s: %r", path);
	if(write(fd, s, n) != n)
		sysfatal("write %s: %r", path);
	if(close(fd) < 0)	/* data files apply at close */
		sysfatal("%s: %r", path);
	free(s);
}

/* draw: write the whole board as one display list */
void
draw(void)
{
	Fmt f;
	int x, y;
	char *s;

	fmtstrinit(&f);
	fmtprint(&f, "rect bg 0 0 %d %d fill=muted\n", N*Cell, N*Cell);
	for(y = 0; y < N; y++)
		for(x = 0; x < N; x++)
			if(grid[y][x])
				fmtprint(&f, "rect c%d_%d %d %d %d %d fill=primary radius=2 hover:fill=accent\n",
					x, y, x*Cell+1, y*Cell+1, Cell-2, Cell-2);
	s = fmtstrflush(&f);
	put(smprint("%s/ops", board), "%s", s);
	free(s);
}

void
step(void)
{
	static uchar next[N][N];
	int x, y, dx, dy, n;

	for(y = 0; y < N; y++)
		for(x = 0; x < N; x++){
			n = 0;
			for(dy = -1; dy <= 1; dy++)
				for(dx = -1; dx <= 1; dx++)
					if(dx || dy)
						n += grid[(y+dy+N)%N][(x+dx+N)%N];
			next[y][x] = n == 3 || (n == 2 && grid[y][x]);
		}
	memmove(grid, next, sizeof grid);
}

char*
attr(char **w, int n, char *name)
{
	int i, l;

	l = strlen(name);
	for(i = 1; i < n; i++)
		if(strncmp(w[i], name, l) == 0 && w[i][l] == '=')
			return w[i]+l+1;
	return "";
}

/* events runs in its own process, sharing memory with main */
void
events(void)
{
	Biobuf *b;
	char *line, *w[32], *what;
	int n, x, y, fd;

	if((fd = open(smprint("%s/events", k), OREAD)) < 0)
		sysfatal("events: %r");
	b = Bfdopen(fd, OREAD);		/* Bfdopen's buffer is 8 KiB */
	while((line = Brdstr(b, '\n', 1)) != nil){
		n = tokenize(line, w, nelem(w));
		if(n == 0){
			free(line);
			continue;
		}
		qlock(&lk);
		/* a button's tag and a key's action name are the same words */
		what = "";
		if(strcmp(w[0], "click") == 0)
			what = attr(w, n, "tag");
		else if(strcmp(w[0], "action") == 0)
			what = attr(w, n, "id");
		if(strcmp(what, "run") == 0){
			running = !running;
			put("windows/main/root/bar/run/label", running ? "Pause" : "Run");
			put("windows/main/root/bar/run/icon", running ? "pause" : "play");
		}else if(strcmp(what, "step") == 0){
			step();
			dirty = 1;
		}else if(strcmp(what, "clear") == 0){
			memset(grid, 0, sizeof grid);
			dirty = 1;
		}else if(strcmp(what, "random") == 0){
			for(y = 0; y < N; y++)
				for(x = 0; x < N; x++)
					grid[y][x] = nrand(4) == 0;
			dirty = 1;
		}else if(strcmp(w[0], "mouse_down") == 0){
			x = atoi(attr(w, n, "x")) / Cell;
			y = atoi(attr(w, n, "y")) / Cell;
			if(x >= 0 && x < N && y >= 0 && y < N){
				grid[y][x] ^= 1;
				dirty = 1;
			}
		}else if(strcmp(w[0], "close") == 0 || strcmp(w[0], "quit") == 0)
			put("ctl", "quit");
		qunlock(&lk);
		free(line);
	}
	exits(nil);	/* end of file: the app quit */
}

void
main(int argc, char **argv)
{
	char *env;

	ARGBEGIN{
	}ARGEND
	if((env = getenv("gpuifs")) != nil && *env)
		k = env;
	srand(time(0));

	put("ctl", "window main title=Life size=%d,%d resizable=off pos=center", N*Cell+32, N*Cell+96);
	put("windows/main/root/tree",
		"div root  style='v_flex size_full items_center gap=12 p=16 bg=background'\n"
		"  toolbar bar\n"
		"    button run  label=Run  icon=play  style=primary  tag=run\n"
		"    button step  label=Step  style=outline  tag=step\n"
		"    button random  label=Random  style=ghost  tag=random\n"
		"    button clear  label=Clear  style=ghost  tag=clear\n"
		"  canvas board  style='size=%d rounded_md'  on=mouse_down\n", N*Cell);
	put("keymap", "space run\nright step\nr random\nbackspace clear\n");

	/* a glider to start */
	grid[1][2] = grid[2][3] = grid[3][1] = grid[3][2] = grid[3][3] = 1;

	switch(rfork(RFPROC|RFMEM|RFNOWAIT)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		events();
	}
	for(;;){
		qlock(&lk);
		if(running){
			step();
			dirty = 1;
		}
		if(dirty){
			draw();
			dirty = 0;
		}
		qunlock(&lk);
		sleep(100);
	}
}
