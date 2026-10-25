#!/usr/bin/env python3
"""shellder-system-update — port of omarchy.system-update.

Original: /usr/share/omarchy/shell/plugins/bar/widgets/SystemUpdate.qml.

  bar     \uf021 in a statusSlot, caption size, "Pending Omarchy Updates";
          shown only while omarchy-update-available exits 0
  click   omarchy-launch-floating-terminal-with-presentation omarchy-update

Checks on start and every 6 h, like Omarchy. Omarchy's refresh/clear IPC
(sent by omarchy-update-status after an update) has no Shellder equivalent,
so the check also re-runs when the pacman database changes, i.e. after any
install, update or removal.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))

from shellder_kit import Plugin  # noqa: E402

GLYPH = "\uf021"
INTERVAL_S = 6 * 3600
PACMAN_DB = "/var/lib/pacman/local"
SETTLE_S = 5  # wait for pacman to finish before checking


class SystemUpdate(Plugin):
    def on_start(self):
        self.available = False
        self.checking = False
        self.db_mtime = self._db_mtime()
        self.db_changed_at = None
        self.check()
        self.every(INTERVAL_S, self.check)
        self.every(2, self._watch_db)

    def _db_mtime(self):
        try:
            return os.stat(PACMAN_DB).st_mtime
        except OSError:
            return None

    def _watch_db(self):
        m = self._db_mtime()
        if m != self.db_mtime:
            self.db_mtime = m
            self.db_changed_at = m
            self.later(SETTLE_S, self._settled)

    def _settled(self):
        # Only the last change of a burst checks.
        if self._db_mtime() == self.db_changed_at:
            self.check()

    def check(self):
        if self.checking:
            return
        self.checking = True
        self.run_cmd(["omarchy-update-available"], self._done)

    def _done(self, ok, out, err):
        self.checking = False
        self.available = ok
        self.render()

    def render(self):
        if not self.available:
            self.emit(visible=False)
            return
        self.emit(visible=True, segments=[{"id": "update", "icon": GLYPH, "font": "caption",
                                           "width": self.theme.bar_token("statusSlot", 22),
                                           "tooltip": "Pending Omarchy Updates"}])

    def on_config(self, ev):
        self.render()

    def on_click(self, ev):
        self.run_detached(["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"])


if __name__ == "__main__":
    SystemUpdate().run()
