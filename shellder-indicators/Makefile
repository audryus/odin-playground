CONFIG_DIR ?= $(or $(SHELLDER_CONFIG_DIR),$(or $(XDG_CONFIG_HOME),$(HOME)/.config)/shellder)
PLUGIN_DIR := $(CONFIG_DIR)/plugins/shellder-indicators

.PHONY: install uninstall

# Instala como symlink: editar aqui recarrega o plugin sozinho (hot reload).
install:
	mkdir -p $(CONFIG_DIR)/plugins
	ln -sfn $(CURDIR) $(PLUGIN_DIR)
	@echo "instalado em $(PLUGIN_DIR)"

uninstall:
	rm -f $(PLUGIN_DIR)
