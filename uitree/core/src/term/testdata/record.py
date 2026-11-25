# rec.py OUT STEPS_JSON -- CMD...: run CMD on an 80x24 pty, record what it
# writes. STEPS: [[delay_s, "keys"], ...] sent in order; the recording
# stops when CMD exits (or 1.5s after the last step).
import os, pty, sys, json, time, select, fcntl, termios, struct, signal
out, steps = sys.argv[1], json.loads(sys.argv[2])
cmd = sys.argv[sys.argv.index('--')+1:]
here = os.path.dirname(os.path.abspath(__file__))
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    os.chdir(here)
    os.environ.update(TERM='xterm-256color', LANG='C.UTF-8', LC_ALL='C.UTF-8', HOME=here + '/home')
    os.environ.pop('LS_COLORS', None)
    os.execvp(cmd[0], cmd)
data = bytearray()
def pump(t):
    end = time.time() + t
    while True:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            return True
        try:
            b = os.read(fd, 65536)
        except OSError:
            return False
        if not b:
            return False
        data.extend(b)
alive = True
for delay, keys in steps:
    alive = pump(delay)
    if not alive: break
    os.write(fd, keys.encode())
if alive: pump(1.5)
try: os.kill(pid, 9)
except: pass
open(out, 'wb').write(data)
print(out, len(data))
