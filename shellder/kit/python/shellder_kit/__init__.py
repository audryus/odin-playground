"""Kit for Shellder plugins written in Python.

    import os, sys
    sys.path.insert(0, os.path.join(os.environ["SHELLDER_KIT"], "python"))
    from shellder_kit import Plugin

Shellder exports SHELLDER_KIT to every plugin. The kit covers:
  Plugin  the protocol loop (stdin/stdout JSON), theme, settings, timers,
          async commands
  loop    the main loop, standard library only (GLib-like API); moves onto
          GLib by itself once gi is imported (GTK panels, D-Bus)
  Theme   the Omarchy theme from the "config" event, as GTK CSS
  PanelApp  base of a manifest entryPoints.panel program (a panel that is
          its own process, started and ended by Shellder)
  Panel   popup following Omarchy's KeyboardPanel (shellder_kit.panel;
          imports GTK only when used)
  nodes   panels described as data (SkaldPanel), drawn by Shellder, by a
          GTK child process or by GTK in the plugin, as the manifest says
"""

from . import loop
from .plugin import PanelApp, Plugin, Proc
from .theme import Theme

__all__ = ["PanelApp", "Plugin", "Proc", "Theme", "loop"]
