"""Shellder protocol runtime (see shellder/README.md)."""

import json
import os
import shlex
import subprocess
import sys

from . import loop
from .theme import Theme


class Proc:
    """A command started by run_cmd / watch_lines."""

    def __init__(self, popen):
        self.popen = popen

    @property
    def pid(self):
        return self.popen.pid

    def force_exit(self):
        try:
            self.popen.kill()
        except OSError:
            pass


def _read_pipe(pipe, on_data, on_eof):
    """Feed a non-blocking pipe's bytes to on_data(bytes), then on_eof()."""
    fd = pipe.fileno()
    os.set_blocking(fd, False)

    def readable(_fd, cond):
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            return True
        except OSError:
            chunk = b""
        if chunk:
            on_data(chunk)
            return True
        pipe.close()
        on_eof()
        return False
    loop.io_add_watch(fd, loop.IO_IN | loop.IO_HUP | loop.IO_ERR, readable)


def _when_exited(popen, done):
    """done(returncode) once popen exits, without blocking the loop."""
    if popen.poll() is not None:
        done(popen.returncode)
        return

    def check():
        if popen.poll() is None:
            return True
        done(popen.returncode)
        return False
    loop.timeout_add(20, check)


class Plugin:
    """Plugin base class. Override the on_* methods and call run().

    State available after the first "config":
      self.theme     Theme
      self.bar       {"position": "bottom", "size": 26}
      self.settings  the plugin's shell.json entry (without "id")
      self.panel_mode  manifest barWidget.panel ("plugin", "skald", "process")
    """

    def __init__(self):
        self.theme = Theme(None)
        self.bar = {"position": "bottom", "size": 26}
        self.settings = {}
        self.loop = loop  # .quit() ends run()
        self._buf = b""
        self._last = {}
        self._configured = False
        self._popups = []  # Panel / HoverPopup instances, closed on "dismiss"
        self._panel = None  # the nodes.SkaldPanel, which gets the "panel" events
        self.panel_mode = "plugin"  # manifest barWidget.panel: plugin / skald / process

    # ---- override ---------------------------------------------------------

    def on_start(self):
        """Once, before the loop (the first config may arrive later)."""

    def on_config(self, ev):
        """Theme, bar or settings changed (also on the first config)."""

    def on_click(self, ev):
        """ev: button (left/middle/right), monitor, bar, item, segment."""

    def on_scroll(self, ev):
        """ev: direction (up/down), monitor, bar, item, segment."""

    def on_hover(self, ev):
        """ev: hovered (bool), monitor, bar, item (the hovered zone)."""

    def on_dismiss(self, ev):
        """Another bar item was clicked: the kit already closed this plugin's
        panels; close anything else that should not stay open."""

    def on_menu(self, ev):
        """A right-click menu entry without "exec" was picked. ev: id, monitor."""

    # ---- state ------------------------------------------------------------

    @property
    def position(self):
        return self.bar.get("position", "bottom")

    @property
    def vertical(self):
        return self.position in ("left", "right")

    def setting(self, key, default=None):
        v = self.settings.get(key)
        return default if v is None else v

    # ---- output -----------------------------------------------------------

    def emit(self, monitor=None, **fields):
        """Update the item (on every output, or only on `monitor`).
        Lines identical to the previous one are not re-sent."""
        update = dict(fields)
        if monitor:
            update["monitor"] = monitor
        line = json.dumps(update, ensure_ascii=False, sort_keys=True)
        key = monitor or ""
        if self._last.get(key) == line:
            return
        self._last[key] = line
        self._write(update)

    def save_settings(self, values):
        """Save settings into the plugin's shell.json entry."""
        self.settings.update(values)
        self._write({"settings": values})

    def _write(self, obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    # ---- timers and processes -----------------------------------------------

    def every(self, seconds, fn, now=False):
        """Call fn() every `seconds` (fn returning False stops it). Returns
        an id for loop.source_remove."""
        def tick():
            return fn() is not False
        if now:
            loop.idle_add(lambda: fn() and False)
        return loop.timeout_add(int(seconds * 1000), tick)

    def later(self, seconds, fn):
        return loop.timeout_add(int(seconds * 1000), lambda: fn() and False)

    def run_cmd(self, argv, callback=None, stdin=None):
        """Run argv without blocking; callback(ok, stdout, stderr). Returns a
        Proc (force_exit()) or None if it could not start."""
        if isinstance(argv, str):
            argv = ["sh", "-c", argv]
        try:
            popen = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as e:
            if callback:
                msg = str(e)
                loop.idle_add(lambda: callback(False, "", msg) and False)
            return None
        if stdin is not None:
            try:
                popen.stdin.write(stdin.encode())
                popen.stdin.close()
            except OSError:
                pass
        out, err, open_pipes = [], [], [2]

        def eof():
            open_pipes[0] -= 1
            if open_pipes[0] == 0:
                _when_exited(popen, finished)

        def finished(code):
            if callback:
                callback(code == 0, b"".join(out).decode("utf-8", "replace"),
                         b"".join(err).decode("utf-8", "replace"))
        _read_pipe(popen.stdout, out.append, eof)
        _read_pipe(popen.stderr, err.append, eof)
        return Proc(popen)

    def run_detached(self, argv):
        """Fire and forget (apps, Omarchy menus)."""
        if isinstance(argv, str):
            argv = shlex.split(argv)
        try:
            subprocess.Popen(argv, start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            print("%s: could not run %s: %s" % (self.name(), argv, e), file=sys.stderr)

    def watch_lines(self, argv, on_line, on_exit=None, stdin=False, env=None):
        """Long-running process; on_line(str) for each stdout line (without
        the newline), on_exit() after it ends. stdin=True keeps a pipe to it
        (proc.popen.stdin); env replaces the environment."""
        try:
            popen = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, env=env)
        except OSError as e:
            print("%s: %s" % (self.name(), e), file=sys.stderr)
            if on_exit:
                loop.idle_add(lambda: on_exit() and False)
            return None
        buf = [b""]

        def data(chunk):
            buf[0] += chunk
            while b"\n" in buf[0]:
                line, buf[0] = buf[0].split(b"\n", 1)
                on_line(line.decode("utf-8", "replace"))

        def eof():
            if buf[0]:
                on_line(buf[0].decode("utf-8", "replace"))
                buf[0] = b""
            _when_exited(popen, lambda code: on_exit and on_exit())
        _read_pipe(popen.stdout, data, eof)
        return Proc(popen)

    def name(self):
        return os.environ.get("SHELLDER_PLUGIN_ID", type(self).__name__)

    # ---- loop ---------------------------------------------------------------

    def _on_stdin(self, fd, cond):
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            return True
        if not chunk:
            self.loop.quit()  # Shellder exited
            return False
        self._buf += chunk
        while b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            self._dispatch(ev)
        return True

    def _dispatch(self, ev):
        kind = ev.get("event")
        if kind == "config":
            self.bar = ev.get("bar") or self.bar
            self.theme = Theme(ev.get("theme"))
            settings = ev.get("settings")
            self.settings = settings if isinstance(settings, dict) else {}
            self.panel_mode = ev.get("panel") or "plugin"
            self._configured = True
            self._last.clear()  # re-send: position/theme may change the drawing
            self.on_config(ev)
        elif kind == "click":
            self.on_click(ev)
        elif kind == "scroll":
            self.on_scroll(ev)
        elif kind == "hover":
            self.on_hover(ev)
        elif kind == "menu":
            self.on_menu(ev)
        elif kind == "panel":
            if self._panel is not None:
                self._panel._event(ev)
        elif kind == "dismiss":
            for popup in self._popups:
                popup.dismiss()
            self.on_dismiss(ev)

    def run(self):
        try:
            os.set_blocking(0, False)
            loop.io_add_watch(0, loop.IO_IN | loop.IO_HUP, self._on_stdin)
        except OSError:
            pass  # stdin is not a pipe (run by hand)
        self.on_start()
        try:
            loop.run()
        except KeyboardInterrupt:
            pass


class PanelApp(Plugin):
    """The program behind the manifest's entryPoints.panel (barWidget.panel:
    "process"). Shellder starts it on a left click on the item and ends it
    on the next click or when another popup opens; it exits by itself when
    the panel closes (Esc, a click outside). Set self.panel (a panel.Panel)
    in on_start; it opens on the click that started the process.

        class NetPanelApp(PanelApp):
            def on_start(self):
                self.panel = MyPanel(self, "shellder-network", width=380)
        NetPanelApp().run()

    The bar process runs separately and needs no GUI toolkit; the two share
    nothing but what they read from the system.
    """

    panel = None

    def on_click(self, ev):
        if self.panel is None or self.panel.opened:
            return
        self.panel.closed_hooks.append(self.loop.quit)
        self.panel.open(ev)
        if not self.panel.opened:  # no GTK
            self.loop.quit()
