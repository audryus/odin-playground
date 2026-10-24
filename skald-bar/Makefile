SKALD_REPO := https://github.com/BuLEEto/Skald.git
SKALD_DIR  := vendor/Skald

.PHONY: all deps update build run clean

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

clean:
	rm -rf build
