"""The kit's main loop, standard library only, so a plugin that needs no GUI
toolkit or D-Bus never loads gi (PyGObject + GLib cost ~10 MiB a process).

The API follows GLib's, so `GLib.` becomes `loop.`:

    from shellder_kit import loop
    t = loop.timeout_add(300, fn)          # fn() returning True repeats it
    loop.timeout_add_seconds(60, fn)
    loop.idle_add(fn)
    loop.io_add_watch(fd, loop.IO_IN | loop.IO_HUP, cb)   # cb(fd, cond) -> bool
    loop.source_remove(t)

Once gi's GLib is imported (a GTK panel in the plugin, Gio for D-Bus) the
loop hands everything over to a GLib main loop — the ids stay valid — since
GTK only runs there. A plugin that imports gi before run() starts on GLib.
"""

import heapq
import itertools
import select
import sys
import time

IO_IN, IO_PRI, IO_OUT, IO_ERR, IO_HUP, IO_NVAL = 1, 2, 4, 8, 16, 32  # = GLib's = poll's


class _Source:
    __slots__ = ("fn", "args", "interval", "when", "fd", "cond", "glib_id", "dead")

    def __init__(self, fn, args, interval=None, fd=None, cond=0):
        self.fn, self.args = fn, args
        self.interval = interval  # ms, for timers
        self.when = 0.0
        self.fd, self.cond = fd, cond
        self.glib_id = None
        self.dead = False


class _Loop:
    def __init__(self):
        self.ids = itertools.count(1)
        self.sources = {}   # id -> _Source
        self.heap = []      # (when, seq, id)
        self.seq = itertools.count()
        self.poller = select.poll()
        self.fds = {}       # fd -> id
        self.running = False
        self.quitting = False
        self.glib = None    # the GLib module once handed over
        self.glib_loop = None

    # ---- sources -------------------------------------------------------------

    def timeout_add(self, ms, fn, *args):
        sid = next(self.ids)
        s = _Source(fn, args, interval=max(0, int(ms)))
        self.sources[sid] = s
        if self.glib:
            self._glib_timer(sid, s, s.interval)
        else:
            self._schedule(sid, s, s.interval)
        return sid

    def io_add_watch(self, fd, cond, fn, *args):
        fd = fd if isinstance(fd, int) else fd.fileno()
        sid = next(self.ids)
        s = _Source(fn, args, fd=fd, cond=cond)
        self.sources[sid] = s
        if self.glib:
            self._glib_io(sid, s)
        else:
            self.fds[fd] = sid
            self.poller.register(fd, cond)
        return sid

    def source_remove(self, sid):
        s = self.sources.pop(sid, None)
        if s is None:
            return False
        s.dead = True
        if s.glib_id is not None:
            self.glib.source_remove(s.glib_id)
        elif s.fd is not None and self.fds.get(s.fd) == sid:
            del self.fds[s.fd]
            self.poller.unregister(s.fd)
        return True

    def _schedule(self, sid, s, ms):
        s.when = time.monotonic() + ms / 1000
        heapq.heappush(self.heap, (s.when, next(self.seq), sid))

    # ---- running ------------------------------------------------------------------

    def run(self):
        self.quitting = False
        if self._gi_loaded():
            self._hand_over()
        while not self.quitting and not self.glib:
            self._iterate()
        if self.glib and not self.quitting:
            self.glib_loop = self.glib.MainLoop()
            self.glib_loop.run()

    def quit(self):
        self.quitting = True
        if self.glib_loop is not None:
            self.glib_loop.quit()

    def _iterate(self):
        timeout = -1
        if self.heap:
            timeout = max(0, int((self.heap[0][0] - time.monotonic()) * 1000) + 1)
        try:
            events = self.poller.poll(timeout)
        except InterruptedError:
            events = []
        for fd, cond in events:
            sid = self.fds.get(fd)
            s = self.sources.get(sid)
            if s is None:
                continue
            if not s.fn(fd, cond, *s.args):
                self.source_remove(sid)
            if self._after_callback():
                return
        now = time.monotonic()
        while self.heap and self.heap[0][0] <= now:
            when, _, sid = heapq.heappop(self.heap)
            s = self.sources.get(sid)
            if s is None or s.dead or s.when != when:
                continue
            if s.fn(*s.args):
                if not s.dead:
                    self._schedule(sid, s, s.interval)
            else:
                self.sources.pop(sid, None)
            if self._after_callback():
                return

    def _after_callback(self):
        """True when the loop must stop iterating here (quit, or GLib)."""
        if self.quitting:
            return True
        if self._gi_loaded():
            self._hand_over()
            return True
        return False

    # ---- GLib -------------------------------------------------------------------

    @staticmethod
    def _gi_loaded():
        return "gi.repository.GLib" in sys.modules

    def _hand_over(self):
        from gi.repository import GLib
        self.glib = GLib
        now = time.monotonic()
        for fd in list(self.fds):
            self.poller.unregister(fd)
        self.fds = {}
        self.heap = []
        for sid, s in list(self.sources.items()):
            if s.fd is not None:
                self._glib_io(sid, s)
            else:
                self._glib_timer(sid, s, max(0, int((s.when - now) * 1000)))

    def _glib_timer(self, sid, s, first_ms):
        def fire():
            if s.dead:
                return False
            if s.fn(*s.args) and not s.dead:
                if s.interval != first_ms:
                    s.glib_id = self.glib.timeout_add(s.interval, fire)
                    return False
                return True
            self.sources.pop(sid, None)
            s.glib_id = None
            return False
        s.glib_id = self.glib.timeout_add(first_ms, fire)

    def _glib_io(self, sid, s):
        def fire(fd, cond):
            if s.dead:
                return False
            if s.fn(fd, int(cond), *s.args):
                return True
            self.sources.pop(sid, None)
            s.glib_id = None
            return False
        s.glib_id = self.glib.io_add_watch(s.fd, self.glib.PRIORITY_DEFAULT, s.cond, fire)


_loop = _Loop()


def timeout_add(ms, fn, *args):
    return _loop.timeout_add(ms, fn, *args)


def timeout_add_seconds(seconds, fn, *args):
    return _loop.timeout_add(seconds * 1000, fn, *args)


def idle_add(fn, *args):
    return _loop.timeout_add(0, fn, *args)


def io_add_watch(fd, cond, fn, *args):
    return _loop.io_add_watch(fd, cond, fn, *args)


def source_remove(sid):
    return _loop.source_remove(sid)


def run():
    _loop.run()


def quit():
    _loop.quit()
