SKALD_REPO := https://github.com/BuLEEto/Skald.git
SKALD_DIR  := vendor/Skald
CONFIG_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/shellder

.PHONY: all deps update build run install-examples clean

all: build

# Clona o Skald em vendor/ (só se ainda não existir).
deps: $(SKALD_DIR)

$(SKALD_DIR):
	mkdir -p vendor
	git clone $(SKALD_REPO) $(SKALD_DIR)

# Atualiza o Skald para o último commit da branch atual.
update: deps
	git -C $(SKALD_DIR) pull --ff-only

build: deps
	./build.sh

run: deps
	./build.sh run

# Copia os plugins de exemplo para a pasta de plugins (não sobrescreve).
install-examples:
	mkdir -p $(CONFIG_DIR)/plugins
	cp -rn examples/plugins/* $(CONFIG_DIR)/plugins/

clean:
	rm -rf build
