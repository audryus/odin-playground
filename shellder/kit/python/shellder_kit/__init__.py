"""Kit for Shellder plugins written in Python.

    import os, sys
    sys.path.insert(0, os.path.join(os.environ["SHELLDER_KIT"], "python"))
    from shellder_kit import Plugin

Shellder exports SHELLDER_KIT to every plugin. The kit covers:
  Plugin  the protocol loop (stdin/stdout JSON), theme, settings, timers,
          async commands
  Theme   the Omarchy theme from the "config" event, as GTK CSS
  Panel   popup following Omarchy's KeyboardPanel (shellder_kit.panel;
          imports GTK only when used)
"""

from .plugin import Plugin
from .theme import Theme

__all__ = ["Plugin", "Theme"]
