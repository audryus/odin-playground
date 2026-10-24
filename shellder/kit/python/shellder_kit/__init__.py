"""Kit para plugins do Shellder em Python.

    import os, sys
    sys.path.insert(0, os.path.join(os.environ["SHELLDER_KIT"], "python"))
    from shellder_kit import Plugin

O Shellder exporta SHELLDER_KIT para cada plugin. O kit cobre:
  Plugin  laço do protocolo (stdin/stdout JSON), tema, preferências, timers,
          comandos assíncronos
  Theme   tema do Omarchy recebido no evento "config", em CSS para GTK
  Panel   popup no padrão do KeyboardPanel do Omarchy (shellder_kit.panel;
          importa GTK só quando usado)
"""

from .plugin import Plugin
from .theme import Theme

__all__ = ["Plugin", "Theme"]
