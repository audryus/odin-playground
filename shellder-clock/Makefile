CONFIG_DIR ?= $(or $(SHELLDER_CONFIG_DIR),$(or $(XDG_CONFIG_HOME),$(HOME)/.config)/shellder)
PLUGIN_DIR := $(CONFIG_DIR)/plugins/shellder-clock

.PHONY: test install uninstall

test:
	python3 -m unittest discover -s tests -v

# Install as a symlink: editing here hot-reloads the plugin.
install:
	mkdir -p $(CONFIG_DIR)/plugins
	ln -sfn $(CURDIR) $(PLUGIN_DIR)
	@echo "installed at $(PLUGIN_DIR)"

uninstall:
	rm -f $(PLUGIN_DIR)
