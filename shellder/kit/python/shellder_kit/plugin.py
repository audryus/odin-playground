"""Shellder protocol runtime (see shellder/README.md)."""

import json
import os
import shlex
import subprocess
import sys

from gi.repository import Gio, GLib

from .theme import Theme


class Plugin:
    """Plugin base class. Override the on_* methods and call run().

    State available after the first "config":
      self.theme     Theme
      self.bar       {"position": "bottom", "size": 26}
      self.settings  the plugin's shell.json entry (without "id")
    """

    def __init__(self):
        self.theme = Theme(None)
        self.bar = {"position": "bottom", "size": 26}
        self.settings = {}
        self.loop = GLib.MainLoop()
        self._buf = b""
        self._last = {}
        self._configured = False

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
        """ev: hovered (bool), monitor."""

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
        """Call fn() every `seconds` (fn returning False stops it)."""
        def tick():
            return fn() is not False
        if now:
            GLib.idle_add(lambda: fn() and False)
        return GLib.timeout_add(int(seconds * 1000), tick)

    def later(self, seconds, fn):
        return GLib.timeout_add(int(seconds * 1000), lambda: fn() and False)

    def run_cmd(self, argv, callback=None, stdin=None):
        """Run argv without blocking; callback(ok, stdout, stderr)."""
        if isinstance(argv, str):
            argv = ["sh", "-c", argv]
        flags = Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
        if stdin is not None:
            flags |= Gio.SubprocessFlags.STDIN_PIPE
        try:
            proc = Gio.Subprocess.new(argv, flags)
        except GLib.Error as e:
            if callback:
                callback(False, "", str(e))
            return None

        def done(p, res):
            try:
                _, out, err = p.communicate_utf8_finish(res)
            except GLib.Error as e:
                out, err = "", str(e)
            if callback:
                callback(p.get_successful(), out or "", err or "")
        proc.communicate_utf8_async(stdin, None, done)
        return proc

    def run_detached(self, argv):
        """Fire and forget (apps, Omarchy menus)."""
        if isinstance(argv, str):
            argv = shlex.split(argv)
        try:
            subprocess.Popen(argv, start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            print("%s: could not run %s: %s" % (self.name(), argv, e), file=sys.stderr)

    def watch_lines(self, argv, on_line, on_exit=None):
        """Long-running process; on_line(str) for each stdout line."""
        try:
            proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE)
        except GLib.Error as e:
            print("%s: %s" % (self.name(), e), file=sys.stderr)
            if on_exit:
                on_exit()
            return None
        stream = Gio.DataInputStream.new(proc.get_stdout_pipe())

        def read(s, res):
            try:
                line, _ = s.read_line_finish_utf8(res)
            except GLib.Error:
                line = None
            if line is None:
                if on_exit:
                    on_exit()
                return
            on_line(line)
            s.read_line_async(GLib.PRIORITY_DEFAULT, None, read)
        stream.read_line_async(GLib.PRIORITY_DEFAULT, None, read)
        return proc

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
            self._configured = True
            self._last.clear()  # re-send: position/theme may change the drawing
            self.on_config(ev)
        elif kind == "click":
            self.on_click(ev)
        elif kind == "scroll":
            self.on_scroll(ev)
        elif kind == "hover":
            self.on_hover(ev)

    def run(self):
        try:
            os.set_blocking(0, False)
            GLib.io_add_watch(0, GLib.IO_IN | GLib.IO_HUP, self._on_stdin)
        except OSError:
            pass  # stdin is not a pipe (run by hand)
        self.on_start()
        try:
            self.loop.run()
        except KeyboardInterrupt:
            pass
