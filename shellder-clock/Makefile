CONFIG_DIR ?= $(or $(SHELLDER_CONFIG_DIR),$(or $(XDG_CONFIG_HOME),$(HOME)/.config)/shellder)
PLUGIN_DIR := $(CONFIG_DIR)/plugins/shellder-clock

.PHONY: test install uninstall

test:
	python3 -m unittest discover -s tests -v

# Instala como symlink: editar aqui vale direto (reinicie o Shellder).
install:
	mkdir -p $(CONFIG_DIR)/plugins
	ln -sfn $(CURDIR) $(PLUGIN_DIR)
	@echo "instalado em $(PLUGIN_DIR); reinicie o Shellder"

uninstall:
	rm -f $(PLUGIN_DIR)
