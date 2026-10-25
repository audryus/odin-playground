SKALD_REPO := https://github.com/BuLEEto/Skald.git
SKALD_DIR  := vendor/Skald
CONFIG_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/shellder

.PHONY: all deps update build run clean

all: build

# Clone Skald into vendor/ (only if missing).
deps: $(SKALD_DIR)

$(SKALD_DIR):
	mkdir -p vendor
	git clone $(SKALD_REPO) $(SKALD_DIR)

# Update Skald to the latest commit of its current branch.
update: deps
	git -C $(SKALD_DIR) pull --ff-only

build: deps
	./build.sh

run: deps
	./build.sh run

clean:
	rm -rf build
