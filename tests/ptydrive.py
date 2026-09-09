#!/usr/bin/env python3
"""Drive a command inside a pseudo-terminal, answer its terminal queries,
record what it draws and keep a model of the screen.

Unlike `script`, this replies to the queries a program sends (DECRQM, kitty
keyboard flags, DA1, cursor position, OSC 10/11 colours, XTVERSION…) the way
foot/alacritty would, so programs like gum 2.0 behave as they do in a real
terminal — including leaving their query replies queued on the tty. A small
VT emulator keeps the current screen so tests can assert on what a user
would see rather than on the raw byte stream.

Usage: ptydrive.py [--cols N] [--rows N] [--term TERM] [--timeout SECS]
                   --log TYPESCRIPT --marks MARKS --results RESULTS
                   [--stderr FILE] [--screens DIR] [--steps FILE] -- cmd [args...]

Steps (one per line, from --steps or stdin):
  wait  <secs> <regex>    wait until regex matches the (control-sequence-
                          stripped) output seen since the last `mark`
  nowait <secs> <regex>   assert regex does NOT appear within secs
  waitscreen <secs> <re>  wait until regex (MULTILINE) matches the screen text
  nowaitscreen <secs> <re>
  screen <name>           dump the screen to <screens>/<name>.txt
  pointer <secs> <re>     wait until "<row>:<text>" of the row that carries the
                          highlighted (green) fzf pointer matches regex
  send  <text>            write text to the pty; Python escapes allowed (\\x1b)
  sleep <secs>
  mark  <name>            note the current output offset; resets the window
  exit  <secs>            expect the command to exit within secs (records code)
  alive                   assert the command is still running
Results file lines: "OK   <step>" / "FAIL <step>" / "INFO …".
"""
import argparse, codecs, fcntl, os, pty, re, select, signal, struct, sys, termios, time, unicodedata

QUERIES = [
    (re.compile(rb'\x1b\[\?(\d+)\$p'), lambda m, st: b'\x1b[?' + m.group(1) + b';2$y'),
    (re.compile(rb'\x1b\[\?u'), lambda m, st: b'\x1b[?%du' % st['kitty']),
    (re.compile(rb'\x1b\[0?c'), lambda m, st: b'\x1b[?62;4;22c'),
    (re.compile(rb'\x1b\[>0?c'), lambda m, st: b'\x1b[>1;121;0c'),
    (re.compile(rb'\x1b\[>0?q'), lambda m, st: b'\x1bP>|foot(1.21.0)\x1b\\'),
    (re.compile(rb'\x1b\[6n'), lambda m, st: b'\x1b[%d;%dR' % (st['scr'].r + 1, st['scr'].c + 1)),
    (re.compile(rb'\x1b\[\?6n'), lambda m, st: b'\x1b[?%d;%dR' % (st['scr'].r + 1, st['scr'].c + 1)),
    (re.compile(rb'\x1b\[\?996n'), lambda m, st: b'\x1b[?997;1n'),
    (re.compile(rb'\x1b\[14t'), lambda m, st: b'\x1b[4;%d;%dt' % (st['rows'] * 20, st['cols'] * 10)),
    (re.compile(rb'\x1b\[16t'), lambda m, st: b'\x1b[6;20;10t'),
    (re.compile(rb'\x1b\[18t'), lambda m, st: b'\x1b[8;%d;%dt' % (st['rows'], st['cols'])),
    (re.compile(rb'\x1b\]10;\?(?:\x07|\x1b\\)'), lambda m, st: b'\x1b]10;rgb:cccc/cccc/cccc\x1b\\'),
    (re.compile(rb'\x1b\]11;\?(?:\x07|\x1b\\)'), lambda m, st: b'\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\'),
    (re.compile(rb'\x1b\]12;\?(?:\x07|\x1b\\)'), lambda m, st: b'\x1b]12;rgb:cccc/cccc/cccc\x1b\\'),
    (re.compile(rb'\x1bP\+q[0-9a-fA-F;]*\x1b\\'), lambda m, st: b'\x1bP0+r\x1b\\'),
]
KITTY_SET = re.compile(rb'\x1b\[=(\d+);\d*u')
KITTY_PUSH = re.compile(rb'\x1b\[>(\d+)u')
KITTY_POP = re.compile(rb'\x1b\[<\d*u')

# Control sequences, for stripping the raw stream before regex matching.
CTRL = re.compile(rb'\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|P.*?\x1b\\|[()*+][@-~]|[@-Z\\-_])', re.S)


def plain(buf):
    return CTRL.sub(b'', bytes(buf))


class Screen:
    """Just enough of a VT emulator for fzf / gum / plain output."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[' '] * cols for _ in range(rows)]
        self.attr = [[''] * cols for _ in range(rows)]   # SGR params per cell
        self.sgr = ''
        self.r = self.c = 0
        self.saved = (0, 0)
        self.wrap = True
        self.pending_wrap = False
        self.top, self.bot = 0, rows - 1
        self.alt = None
        self.dec = codecs.getincrementaldecoder('utf-8')('replace')
        self.state = 'text'
        self.buf = ''

    # -- output -------------------------------------------------------
    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.grid)

    def pointer_row(self):
        """(row, text) of the row whose first cell is fzf's pointer in green."""
        for i, row in enumerate(self.grid):
            a = self.attr[i][0]
            if row[0] == '\u258c' and re.search(r'(^|;)32(;|$)', a) and '38;5;32' not in a:
                return i, ''.join(row).rstrip()
        return None

    # -- helpers ------------------------------------------------------
    def scroll_up(self, n=1):
        for _ in range(n):
            del self.grid[self.top]; del self.attr[self.top]
            self.grid.insert(self.bot, [' '] * self.cols); self.attr.insert(self.bot, [''] * self.cols)

    def scroll_down(self, n=1):
        for _ in range(n):
            del self.grid[self.bot]; del self.attr[self.bot]
            self.grid.insert(self.top, [' '] * self.cols); self.attr.insert(self.top, [''] * self.cols)

    def linefeed(self):
        if self.r == self.bot:
            self.scroll_up()
        elif self.r < self.rows - 1:
            self.r += 1

    def put(self, ch):
        w = 0 if unicodedata.combining(ch) or unicodedata.category(ch) in ('Mn', 'Me', 'Cf') else \
            (2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1)
        if w == 0:
            if self.c > 0:
                self.grid[self.r][self.c - 1] += ch
            return
        if self.pending_wrap or self.c + w > self.cols:
            if self.wrap:
                self.c = 0
                self.linefeed()
            else:
                self.c = self.cols - w
            self.pending_wrap = False
        self.grid[self.r][self.c] = ch
        self.attr[self.r][self.c] = self.sgr
        if w == 2 and self.c + 1 < self.cols:
            self.grid[self.r][self.c + 1] = ''
            self.attr[self.r][self.c + 1] = self.sgr
        self.c += w
        if self.c >= self.cols:
            self.c = self.cols - 1
            self.pending_wrap = self.wrap

    def erase(self, r0, c0, r1, c1):
        for r in range(r0, r1 + 1):
            a = c0 if r == r0 else 0
            b = c1 if r == r1 else self.cols - 1
            for c in range(a, b + 1):
                self.grid[r][c] = ' '
                self.attr[r][c] = ''

    # -- input --------------------------------------------------------
    def feed(self, data):
        for ch in self.dec.decode(data):
            self.step(ch)

    def step(self, ch):
        st = self.state
        if st == 'text':
            if ch == '\x1b':
                self.state, self.buf = 'esc', ''
            elif ch == '\r':
                self.c = 0; self.pending_wrap = False
            elif ch == '\n' or ch == '\x0b' or ch == '\x0c':
                self.linefeed(); self.pending_wrap = False
            elif ch == '\b':
                self.c = max(0, self.c - 1); self.pending_wrap = False
            elif ch == '\t':
                self.c = min(self.cols - 1, (self.c // 8 + 1) * 8); self.pending_wrap = False
            elif ch < ' ' or ch == '\x7f':
                pass
            else:
                self.put(ch)
        elif st == 'esc':
            if ch == '[':
                self.state = 'csi'
            elif ch == ']':
                self.state = 'osc'
            elif ch == 'P' or ch == '_' or ch == '^' or ch == 'X':
                self.state = 'str'
            elif ch in '()*+#%':
                self.state = 'esc2'
            else:
                self.state = 'text'
                if ch == '7': self.saved = (self.r, self.c)
                elif ch == '8': self.r, self.c = self.saved
                elif ch == 'M':
                    if self.r == self.top: self.scroll_down()
                    else: self.r = max(0, self.r - 1)
                elif ch == 'D': self.linefeed()
                elif ch == 'E': self.c = 0; self.linefeed()
                elif ch == 'c': self.__init__(self.rows, self.cols)
        elif st == 'esc2':
            self.state = 'text'
        elif st == 'csi':
            if '@' <= ch <= '~':
                self.state = 'text'
                self.csi(self.buf, ch)
            else:
                self.buf += ch
        elif st == 'osc':
            if ch == '\x07':
                self.state = 'text'
            elif ch == '\x1b':
                self.state = 'osc_esc'
        elif st == 'osc_esc':
            self.state = 'text' if ch == '\\' else 'osc'
        elif st == 'str':
            if ch == '\x1b':
                self.state = 'str_esc'
        elif st == 'str_esc':
            self.state = 'text' if ch == '\\' else 'str'

    def csi(self, params, final):
        private = params[:1] in ('?', '>', '=', '<')
        body = params[1:] if private else params
        body = body.split('$')[0].split(' ')[0]
        nums = [int(x) if x.isdigit() else 0 for x in body.split(';')] if body else []
        n = nums[0] if nums and nums[0] else 1
        self.pending_wrap = False
        if private:
            if params[0] == '?' and final in 'hl':
                on = final == 'h'
                for m in nums:
                    if m == 7:
                        self.wrap = on
                    elif m in (1049, 1047, 47):
                        if on and self.alt is None:
                            self.alt = (self.grid, self.attr, self.r, self.c)
                            self.grid = [[' '] * self.cols for _ in range(self.rows)]
                            self.attr = [[''] * self.cols for _ in range(self.rows)]
                            self.r = self.c = 0
                        elif not on and self.alt is not None:
                            self.grid, self.attr, self.r, self.c = self.alt
                            self.alt = None
            return
        if final == 'A': self.r = max(self.top if self.r >= self.top else 0, self.r - n)
        elif final == 'B': self.r = min(self.bot if self.r <= self.bot else self.rows - 1, self.r + n)
        elif final == 'C': self.c = min(self.cols - 1, self.c + n)
        elif final == 'D': self.c = max(0, self.c - n)
        elif final == 'E': self.c = 0; self.r = min(self.rows - 1, self.r + n)
        elif final == 'F': self.c = 0; self.r = max(0, self.r - n)
        elif final in 'G`': self.c = min(self.cols - 1, n - 1)
        elif final == 'd': self.r = min(self.rows - 1, n - 1)
        elif final in 'Hf':
            r = nums[0] if nums else 1
            c = nums[1] if len(nums) > 1 else 1
            self.r = min(self.rows - 1, max(0, (r or 1) - 1))
            self.c = min(self.cols - 1, max(0, (c or 1) - 1))
        elif final == 'J':
            m = nums[0] if nums else 0
            if m == 0: self.erase(self.r, self.c, self.rows - 1, self.cols - 1)
            elif m == 1: self.erase(0, 0, self.r, self.c)
            else: self.erase(0, 0, self.rows - 1, self.cols - 1)
        elif final == 'K':
            m = nums[0] if nums else 0
            if m == 0: self.erase(self.r, self.c, self.r, self.cols - 1)
            elif m == 1: self.erase(self.r, 0, self.r, self.c)
            else: self.erase(self.r, 0, self.r, self.cols - 1)
        elif final == 'X': self.erase(self.r, self.c, self.r, min(self.cols - 1, self.c + n - 1))
        elif final == 'P':
            for row, blank in ((self.grid[self.r], ' '), (self.attr[self.r], '')):
                del row[self.c:self.c + n]
                row.extend([blank] * (self.cols - len(row)))
        elif final == '@':
            for row, blank in ((self.grid[self.r], ' '), (self.attr[self.r], '')):
                row[self.c:self.c] = [blank] * n
                del row[self.cols:]
        elif final == 'L':
            if self.top <= self.r <= self.bot:
                for _ in range(n):
                    for g, blank in ((self.grid, ' '), (self.attr, '')):
                        del g[self.bot]
                        g.insert(self.r, [blank] * self.cols)
        elif final == 'M':
            if self.top <= self.r <= self.bot:
                for _ in range(n):
                    for g, blank in ((self.grid, ' '), (self.attr, '')):
                        del g[self.r]
                        g.insert(self.bot, [blank] * self.cols)
        elif final == 'm':
            self.sgr = params
        elif final == 'S': self.scroll_up(n)
        elif final == 'T': self.scroll_down(n)
        elif final == 'r':
            t = (nums[0] if nums else 1) or 1
            b = (nums[1] if len(nums) > 1 else self.rows) or self.rows
            self.top, self.bot = max(0, t - 1), min(self.rows - 1, b - 1)
            self.r = self.c = 0
        elif final == 's': self.saved = (self.r, self.c)
        elif final == 'u': self.r, self.c = self.saved
        # m (SGR), n, t, h/l (non-private) and the rest: no effect on the model


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cols', type=int, default=160)
    ap.add_argument('--rows', type=int, default=45)
    ap.add_argument('--term', default='xterm-256color')
    ap.add_argument('--timeout', type=float, default=60)
    ap.add_argument('--log', required=True)
    ap.add_argument('--marks', required=True)
    ap.add_argument('--results', required=True)
    ap.add_argument('--stderr', default=None)
    ap.add_argument('--screens', default=None)
    ap.add_argument('--steps', default='-')
    ap.add_argument('cmd', nargs='+')
    a = ap.parse_args()

    steps_src = sys.stdin if a.steps == '-' else open(a.steps)
    steps = [l.rstrip('\n') for l in steps_src if l.strip() and not l.lstrip().startswith('#')]

    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = a.term
        os.environ['COLUMNS'] = str(a.cols)
        os.environ['LINES'] = str(a.rows)
        if a.stderr:
            err = os.open(a.stderr, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.dup2(err, 2)
        os.execvp(a.cmd[0], a.cmd)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', a.rows, a.cols, 0, 0))
    scr = Screen(a.rows, a.cols)
    st = {'kitty': 0, 'rows': a.rows, 'cols': a.cols, 'scr': scr}
    log = open(a.log, 'wb')
    marks = open(a.marks, 'w')
    results = open(a.results, 'w')
    if a.screens:
        os.makedirs(a.screens, exist_ok=True)
    out = bytearray()          # everything the child wrote
    pending = b''              # unparsed tail for query detection
    deadline = time.monotonic() + a.timeout
    child_status = None
    window_start = 0

    def reap(block=False):
        nonlocal child_status
        if child_status is not None:
            return True
        wpid, status = os.waitpid(pid, 0 if block else os.WNOHANG)
        if wpid == pid:
            child_status = status
            return True
        return False

    def absorb(data):
        nonlocal pending
        out.extend(data)
        log.write(data); log.flush()
        scr.feed(data)
        pending += data
        for m in KITTY_SET.finditer(pending):
            st['kitty'] = int(m.group(1))
        for m in KITTY_PUSH.finditer(pending):
            st['kitty'] = int(m.group(1))
        if KITTY_POP.search(pending):
            st['kitty'] = 0
        last = 0
        hits = []
        for rx, build in QUERIES:
            for m in rx.finditer(pending):
                hits.append((m.start(), m.end(), build(m, st)))
        reply = b''
        for s, e, rep in sorted(hits):
            reply += rep
            last = max(last, e)
        if reply:
            os.write(fd, reply)
        pending = pending[last:]
        if len(pending) > 4096:
            pending = pending[-256:]

    def pump(t):
        """Read pty output for up to t seconds. Returns False once the child is gone."""
        end = time.monotonic() + t
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return True
            try:
                r, _, _ = select.select([fd], [], [], min(left, 0.05))
            except InterruptedError:
                continue
            if fd in r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b''
                if not data:
                    reap(block=True)
                    return False
                absorb(data)
            elif reap():
                try:
                    while True:
                        data = os.read(fd, 65536)
                        if not data:
                            break
                        absorb(data)
                except OSError:
                    pass
                return False

    def record(ok, what):
        results.write(('OK   ' if ok else 'FAIL ') + what + '\n'); results.flush()

    def wait_for(secs, test):
        end = time.monotonic() + float(secs)
        while True:
            if test():
                return True
            if time.monotonic() >= end:
                return False
            if not pump(0.05) and child_status is not None:
                return test()

    rc = 0
    for step in steps:
        if time.monotonic() > deadline:
            record(False, 'global timeout before: ' + step)
            rc = 124
            break
        op, _, rest = step.partition(' ')
        if op == 'mark':
            pump(0.05)
            window_start = len(out)
            marks.write('%s %d\n' % (rest.strip(), window_start)); marks.flush()
        elif op == 'send':
            data = codecs.decode(rest, 'unicode_escape').encode('latin-1')
            if child_status is not None:
                record(False, 'send %r (child already exited)' % rest)
                continue
            os.write(fd, data)
            pump(0.02)
        elif op == 'sleep':
            pump(float(rest))
        elif op in ('wait', 'nowait'):
            secs, _, pat = rest.partition(' ')
            rx = re.compile(pat.encode('utf-8'), re.S)
            found = wait_for(secs, lambda: rx.search(plain(out[window_start:])) is not None)
            record(found if op == 'wait' else not found, '%s %s' % (op, pat))
        elif op in ('waitscreen', 'nowaitscreen'):
            secs, _, pat = rest.partition(' ')
            rx = re.compile(pat, re.M)
            found = wait_for(secs, lambda: rx.search(scr.text()) is not None)
            record(found if op == 'waitscreen' else not found, '%s %s' % (op, pat))
        elif op == 'screen':
            pump(0.05)
            if a.screens:
                with open(os.path.join(a.screens, rest.strip() + '.txt'), 'w') as f:
                    f.write(scr.text() + '\n')
                    pr = scr.pointer_row()
                    f.write('\n[pointer row: %s]\n' % (('%d: %s' % pr) if pr else 'none'))
        elif op == 'pointer':
            secs, _, pat = rest.partition(' ')
            rx = re.compile(pat)
            def hit():
                pr = scr.pointer_row()
                return pr is not None and rx.search('%d:%s' % pr) is not None
            found = wait_for(secs, hit)
            pr = scr.pointer_row()
            record(found, 'pointer %s (row: %s)' % (pat, ('%d: %s' % pr).strip() if pr else 'none'))
        elif op == 'alive':
            pump(0.05)
            reap()
            record(child_status is None, 'alive')
        elif op == 'exit':
            end = time.monotonic() + float(rest)
            while child_status is None and time.monotonic() < end:
                pump(0.05)
                reap()
            if child_status is None:
                record(False, 'exit (still running after %ss)' % rest)
            else:
                code = os.waitstatus_to_exitcode(child_status)
                record(code == 0, 'exit code %d' % code)
        else:
            record(False, 'unknown step: ' + step)

    pump(0.1)
    if not reap():
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        end = time.monotonic() + 2
        while child_status is None and time.monotonic() < end:
            pump(0.05); reap()
        if child_status is None:
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            reap(block=True)
        results.write('INFO child killed at end (status %s)\n' % child_status)
    else:
        results.write('INFO child exit code %d\n' % os.waitstatus_to_exitcode(child_status))
    if a.screens:
        with open(os.path.join(a.screens, 'final.txt'), 'w') as f:
            f.write(scr.text() + '\n')
    marks.write('END %d\n' % len(out))
    log.close(); marks.close(); results.close()
    sys.exit(rc)


if __name__ == '__main__':
    main()
