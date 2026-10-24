#!/usr/bin/env python3
"""shellder-clock — data/hora na barra do Shellder, com calendário ao clicar.

Porte do clock do Omarchy (omarchy.clock):
  clique esquerdo  abre/fecha o calendário
  clique direito   percorre os formatos do rótulo (e grava o escolhido)
  clique do meio   seletor de fuso (omarchy-menu-timezone)

Protocolo do Shellder: atualizações JSON no stdout, eventos JSON no stdin
(ver o README do Shellder). Preferências na entrada do plugin no shell.json
do Shellder, com as mesmas chaves do omarchy.clock no shell.json do Omarchy:
format, formatAlt, verticalFormat, verticalFormatAlt, weekStartDay,
birthYear, lifeExpectancy.
"""

import datetime as dt
import json
import os
import shutil
import subprocess
import sys

from gi.repository import GLib

import model as M
from panel import CalendarPanel


class Settings(dict):
    """Preferências do plugin: a entrada dele no shell.json do Shellder
    (bar.layout[...] = {"id": "shellder.clock", "format": ...}), recebida no
    evento "config". Gravar = mandar {"settings": {...}} no stdout; o Shellder
    atualiza o shell.json e devolve o "config" novo."""

    def replace(self, values):
        self.clear()
        if isinstance(values, dict):
            self.update(values)

    def save(self, values):
        self.update(values)
        sys.stdout.write(json.dumps({"settings": values}, ensure_ascii=False) + "\n")
        sys.stdout.flush()


class Clock:
    def __init__(self):
        self.settings = Settings()
        self.position = "bottom"
        self.panel = CalendarPanel(self.settings, self.settings.save)
        self.loop = GLib.MainLoop()
        self.buf = b""
        self.last_text = None

    @property
    def vertical(self):
        return self.position in ("left", "right")

    def format_key(self):
        return "verticalFormat" if self.vertical else "format"

    def configured_format(self):
        default = M.DEFAULT_VERTICAL_FORMAT if self.vertical else M.DEFAULT_FORMAT
        return self.settings.get(self.format_key()) or default

    def configured_alt_format(self):
        key = "verticalFormatAlt" if self.vertical else "formatAlt"
        default = M.DEFAULT_VERTICAL_FORMAT_ALT if self.vertical else M.DEFAULT_FORMAT_ALT
        return self.settings.get(key) or default

    # ---- barra -----------------------------------------------------------

    def emit(self, force=False):
        text = M.format_qt(dt.datetime.now(), self.configured_format())
        if text == self.last_text and not force:
            return
        self.last_text = text
        sys.stdout.write(json.dumps({"text": text}, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    def schedule_tick(self):
        # Acorda logo depois da virada do minuto.
        now = dt.datetime.now()
        ms = (60 - now.second) * 1000 - now.microsecond // 1000 + 50
        GLib.timeout_add(ms, self.on_tick)

    def on_tick(self):
        self.emit()
        self.panel.tick()
        self.schedule_tick()
        return False

    def cycle_format(self):
        ring = M.clock_format_ring(self.configured_format(), self.configured_alt_format(),
                                   M.clock_formats(self.vertical))
        nxt = M.next_clock_format(ring, self.configured_format())
        if nxt and nxt != self.configured_format():
            self.settings.save({self.format_key(): nxt})
            self.emit(force=True)

    # ---- eventos do Shellder ---------------------------------------------

    def on_stdin(self, fd, condition):
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            return True
        if not chunk:
            self.loop.quit()  # o Shellder saiu
            return False
        self.buf += chunk
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            try:
                event = json.loads(line)
            except ValueError:
                continue
            self.handle(event)
        return True

    def handle(self, ev):
        kind = ev.get("event")
        if kind == "config":
            self.position = ev.get("bar", {}).get("position", self.position)
            self.settings.replace(ev.get("settings"))
            self.panel.set_theme(ev.get("theme"))
            self.emit(force=True)
        elif kind == "click":
            button = ev.get("button")
            if button == "left":
                self.panel.toggle(ev)
            elif button == "right":
                self.cycle_format()
            elif button == "middle":
                self.open_timezone_picker()

    def open_timezone_picker(self):
        cmd = shutil.which("omarchy-menu-timezone")
        if not cmd:
            print("shellder-clock: omarchy-menu-timezone não encontrado", file=sys.stderr)
            return
        subprocess.Popen([cmd], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)

    def run(self):
        os.set_blocking(0, False)
        GLib.io_add_watch(0, GLib.IO_IN | GLib.IO_HUP, self.on_stdin)
        self.emit(force=True)
        self.schedule_tick()
        try:
            self.loop.run()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    Clock().run()
