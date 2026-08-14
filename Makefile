SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ──────────────────────────────────────────────────────────────────────────────
#  Colours
# ──────────────────────────────────────────────────────────────────────────────
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
CYAN   := \033[0;36m
BOLD   := \033[1m
NC     := \033[0m

INFO := printf "$(CYAN)› %s$(NC)\n"
OK   := printf "$(GREEN)✓$(NC) %s\n"

GO_PKG  := ./cmd/differ-sidecar
GO_BIN  := bin/differ-sidecar
# stamped into protocol.Binary so the hello handshake reports a real version,
# not "dev"; falls back to "dev" outside a git checkout
GO_VERSION := $(shell git describe --tags --always 2>/dev/null | sed 's/^v//' || echo dev)
GO_LDFLAGS := -X github.com/undont/differ.nvim/internal/protocol.Binary=$(GO_VERSION)

# pinned lua-language-server: its diagnostics shift between releases (a version bump
# alone can turn a clean tree red), so the version is fixed here and fetched into
# .tools rather than taken from PATH/Mason. bump deliberately
LUALS_VERSION := 3.18.2
LUALS_DIR     := .tools/lua-language-server-$(LUALS_VERSION)
LUALS_BIN     := $(LUALS_DIR)/bin/lua-language-server

# fetched into .tools rather than taken from PATH so they can't drift
PANVIMDOC_VERSION := v4.0.1
PANVIMDOC_DIR     := .tools/panvimdoc-$(PANVIMDOC_VERSION:v%=%)
PANVIMDOC_BIN     := $(PANVIMDOC_DIR)/panvimdoc.sh
PANDOC_VERSION    := 3.10.1

GOLANGCI_VERSION := 2.12.2
GOLANGCI_DIR     := .tools/golangci-lint-$(GOLANGCI_VERSION)
GOLANGCI_BIN     := $(GOLANGCI_DIR)/golangci-lint

STYLUA_VERSION := 2.5.2
STYLUA_DIR     := .tools/stylua-$(STYLUA_VERSION)
STYLUA_BIN     := $(STYLUA_DIR)/stylua

LUACHECK_VERSION := 1.2.0
LUACHECK_DIR     := .tools/luacheck-$(LUACHECK_VERSION)
LUACHECK_BIN     := $(LUACHECK_DIR)/bin/luacheck

.PHONY: help \
	lua-test lua-test-unit lua-test-nvim lua-lint lua-luacheck lua-typecheck lua-fmt lua-fmt-check \
	go-build demo-build go-test go-vet go-lint go-fmt go-fmt-check \
	test lint fmt fmt-check check clean \
	vimdoc \
	demo demo-fixtures

# ──────────────────────────────────────────────────────────────────────────────
##@ Lua
# ──────────────────────────────────────────────────────────────────────────────

lua-test: lua-test-unit lua-test-nvim ## Run both Lua suites (unit + headless-nvim)

lua-test-unit: ## Run pure-Lua unit tests only (fast, no Neovim runtime)
	@$(INFO) "Running unit tests"
	@busted --run unit

lua-test-nvim: ## Run headless-nvim tests (needs nlua on PATH)
	@$(INFO) "Running headless-nvim tests"
	@eval $$(luarocks --lua-version=5.1 path) && busted --lua=nlua --run nvim

lua-lint: lua-luacheck lua-fmt-check ## Luacheck + stylua --check on Lua sources

lua-luacheck: $(LUACHECK_BIN) ## Luacheck over lua/
	@$(INFO) "Linting Lua (luacheck $(LUACHECK_VERSION))"
	@$(LUACHECK_BIN) lua
	@$(OK) "Luacheck clean"

lua-fmt: $(STYLUA_BIN) ## Format Lua sources with stylua
	@$(STYLUA_BIN) lua plugin test
	@$(OK) "Lua formatted"

lua-fmt-check: $(STYLUA_BIN) ## Verify Lua formatting without writing
	@$(INFO) "Checking Lua formatting (stylua $(STYLUA_VERSION))"
	@$(STYLUA_BIN) --check lua plugin test
	@$(OK) "Lua formatting clean"

# checks lua/ only; test specs deliberately pass invalid inputs. lua_ls config
# discovery is path-sensitive, so point at the repo-root .luarc.json explicitly
lua-typecheck: $(LUALS_BIN) ## Type-check Lua with pinned lua_ls
	@$(INFO) "Type-checking Lua (lua_ls $(LUALS_VERSION))"
	@$(LUALS_BIN) --check lua --configpath=$(CURDIR)/.luarc.json --checklevel=Warning --logpath=.tools/luals-report
	@$(OK) "Lua type-check clean"

# fetch the pinned lua_ls into .tools on first use; the whole tree is gitignored
$(LUALS_BIN):
	@$(INFO) "Fetching lua-language-server $(LUALS_VERSION)"
	@mkdir -p $(LUALS_DIR)
	@os=$$(uname -s | tr 'A-Z' 'a-z'); \
	arch=$$(uname -m); \
	case "$$arch" in x86_64) arch=x64;; aarch64|arm64) arch=arm64;; esac; \
	case "$$os" in darwin|linux) ;; *) printf "$(RED)unsupported OS: $$os$(NC)\n"; exit 1;; esac; \
	url="https://github.com/LuaLS/lua-language-server/releases/download/$(LUALS_VERSION)/lua-language-server-$(LUALS_VERSION)-$$os-$$arch.tar.gz"; \
	curl -fsSL "$$url" | tar -xz -C $(LUALS_DIR) && $(OK) "Installed lua_ls $(LUALS_VERSION)"

$(STYLUA_BIN):
	@$(INFO) "Fetching stylua $(STYLUA_VERSION)"
	@mkdir -p $(STYLUA_DIR)
	@os=$$(uname -s | tr 'A-Z' 'a-z'); \
	arch=$$(uname -m); \
	case "$$os" in darwin) os=macos;; linux) ;; *) printf "$(RED)unsupported OS: $$os$(NC)\n"; exit 1;; esac; \
	case "$$arch" in x86_64) arch=x86_64;; aarch64|arm64) arch=aarch64;; esac; \
	url="https://github.com/JohnnyMorganz/StyLua/releases/download/v$(STYLUA_VERSION)/stylua-$$os-$$arch.zip"; \
	tmp=$$(mktemp -d); \
	curl -fsSL -o "$$tmp/stylua.zip" "$$url" && unzip -qj -d $(STYLUA_DIR) "$$tmp/stylua.zip"; \
	rm -rf "$$tmp"; \
	test -x $(STYLUA_BIN) || { printf "$(RED)stylua missing from the archive$(NC)\n"; exit 1; }
	@$(OK) "Installed stylua $(STYLUA_VERSION)"

# luacheck ships as a rock, so it pins into its own luarocks tree rather than an archive.
# the interpreter is half the pin: 1.2.0 does not run on lua 5.5, and 5.1 is what the
# rest of the suite uses
$(LUACHECK_BIN):
	@$(INFO) "Fetching luacheck $(LUACHECK_VERSION)"
	@luarocks install --tree $(LUACHECK_DIR) --lua-version 5.1 luacheck $(LUACHECK_VERSION) >/dev/null
	@test -x $(LUACHECK_BIN) || { printf "$(RED)luacheck missing from $(LUACHECK_DIR)$(NC)\n"; exit 1; }
	@$(OK) "Installed luacheck $(LUACHECK_VERSION)"

# ──────────────────────────────────────────────────────────────────────────────
##@ Go sidecar
# ──────────────────────────────────────────────────────────────────────────────

go-build: ## Build the differ-sidecar binary into bin/
	@$(INFO) "Building $(GO_BIN) ($(GO_VERSION))"
	@go build -ldflags "$(GO_LDFLAGS)" -o $(GO_BIN) $(GO_PKG)
	@$(OK) "Built $(GO_BIN)"

# the demo's fixture sidecar compiles against internal/github, so a type change there can
# break it. `./...` never expands into a dot-directory, so it needs the explicit path
demo-build: ## Type-check the demo fixture sidecar (.demo is invisible to ./...)
	@go build -o /dev/null ./.demo/fake-sidecar
	@$(OK) "Demo fixture sidecar builds"

go-test: ## Run Go tests with the race detector
	@go test -race ./...

go-vet: ## Run go vet over the module
	@go vet ./...

go-lint: $(GOLANGCI_BIN) ## Run golangci-lint over the module
	@$(INFO) "Linting Go (golangci-lint $(GOLANGCI_VERSION))"
	@$(GOLANGCI_BIN) run ./...
	@$(OK) "Go lint clean"

$(GOLANGCI_BIN):
	@$(INFO) "Fetching golangci-lint $(GOLANGCI_VERSION)"
	@mkdir -p $(GOLANGCI_DIR)
	@os=$$(uname -s | tr 'A-Z' 'a-z'); \
	arch=$$(uname -m); \
	case "$$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac; \
	case "$$os" in darwin|linux) ;; *) printf "$(RED)unsupported OS: $$os$(NC)\n"; exit 1;; esac; \
	url="https://github.com/golangci/golangci-lint/releases/download/v$(GOLANGCI_VERSION)/golangci-lint-$(GOLANGCI_VERSION)-$$os-$$arch.tar.gz"; \
	curl -fsSL "$$url" | tar -xz --strip-components=1 -C $(GOLANGCI_DIR); \
	test -x $(GOLANGCI_BIN) || { printf "$(RED)golangci-lint missing from the archive$(NC)\n"; exit 1; }
	@$(OK) "Installed golangci-lint $(GOLANGCI_VERSION)"

go-fmt: ## Format Go sources with gofmt
	@gofmt -w cmd internal .demo
	@$(OK) "Go formatted"

go-fmt-check: ## Verify Go formatting without writing
	@out=$$(gofmt -l cmd internal .demo); \
	if [ -n "$$out" ]; then \
		printf "$(RED)gofmt needed:$(NC)\n%s\n" "$$out"; \
		exit 1; \
	fi

# ──────────────────────────────────────────────────────────────────────────────
##@ Docs
# ──────────────────────────────────────────────────────────────────────────────

vimdoc: $(PANVIMDOC_BIN) ## Regenerate doc/differ.txt from README.md (needs pandoc)
	@have=$$(pandoc --version 2>/dev/null | head -1 | awk '{print $$2}'); \
	if [ -z "$$have" ]; then \
		printf "$(RED)pandoc not found on PATH$(NC) (brew install pandoc)\n"; \
		exit 1; \
	elif [ "$$have" != "$(PANDOC_VERSION)" ]; then \
		printf "$(RED)pandoc $$have, need $(PANDOC_VERSION)$(NC) (output differs between versions)\n"; \
		exit 1; \
	fi
	@$(INFO) "Generating doc/differ.txt (panvimdoc $(PANVIMDOC_VERSION), pandoc $(PANDOC_VERSION))"
	@# LC_ALL=C keeps the nbsp pandoc puts after "e.g." intact: the writer wraps with
	@# lua patterns, and %s is locale-dependent, so bsd libc in a utf-8 locale counts
	@# 0xa0 as space and splits it into u+fffd. --description replaces the header's
	@# daily "Last change" stamp, and GITHUB_ACTIONS is cleared because panvimdoc.sh
	@# hardcodes /scripts when it's set, over --scripts-dir. output prints on failure
	@out=$$(LC_ALL=C GITHUB_ACTIONS=false bash $(PANVIMDOC_BIN) \
		--scripts-dir "$(PANVIMDOC_DIR)/scripts" \
		--project-name differ \
		--input-file README.md \
		--description "For Neovim >= 0.12" \
		--toc true \
		--demojify true \
		--dedup-subheadings true \
		--shift-heading-level-by -1 2>&1) || { printf '%s\n' "$$out"; exit 1; }
	@$(OK) "doc/differ.txt regenerated"
	@# doc/tags is gitignored and lazy only generates helptags for plugins it installed,
	@# never for a `dir` dev checkout, so :help differ breaks in-tree without this. skipped
	@# where there's no nvim (ci runs pandoc only), and invisible to ci's differ.txt diff
	@if command -v nvim >/dev/null 2>&1; then \
		nvim --headless -c "helptags doc" -c "qa!" >/dev/null 2>&1; \
		$(OK) "doc/tags regenerated"; \
	fi

# fetch the pinned panvimdoc into .tools on first use; the whole tree is gitignored
$(PANVIMDOC_BIN):
	@$(INFO) "Fetching panvimdoc $(PANVIMDOC_VERSION)"
	@mkdir -p .tools
	@curl -fsSL "https://github.com/kdheepak/panvimdoc/archive/refs/tags/$(PANVIMDOC_VERSION).tar.gz" \
		| tar -xz -C .tools && $(OK) "Installed panvimdoc $(PANVIMDOC_VERSION)"

# ──────────────────────────────────────────────────────────────────────────────
##@ Aggregate
# ──────────────────────────────────────────────────────────────────────────────

test: lua-test go-test ## Run every test suite (Lua + Go)

lint: lua-lint go-lint ## Lint the whole codebase (Lua + Go)

fmt: lua-fmt go-fmt ## Format the whole codebase (Lua + Go)

fmt-check: lua-fmt-check go-fmt-check ## Verify formatting across the codebase

check: fmt-check lint lua-typecheck go-vet demo-build test ## Run the full quality gate

clean: ## Remove build artefacts
	@rm -rf bin differ-sidecar
	@$(OK) "Cleaned"

# ──────────────────────────────────────────────────────────────────────────────
##@ Demo
# ──────────────────────────────────────────────────────────────────────────────

demo-fixtures: ## Build the throwaway git fixtures the demo records against
	@$(INFO) "Building demo fixtures"
	@bash .demo/setup.sh

demo: demo-fixtures ## Re-record .demo/demo.gif and .demo/demo.mp4 (needs vhs + ffmpeg)
	@$(INFO) "Recording demo (vhs)"
	@vhs .demo/demo.tape
	@$(OK) "Recorded .demo/demo.gif"

# ──────────────────────────────────────────────────────────────────────────────
##@ Meta
# ──────────────────────────────────────────────────────────────────────────────

help: ## Show this help message
	@cols=$$( { stty size </dev/tty; } 2>/dev/null | cut -d' ' -f2 ); \
	[ -n "$$cols" ] || cols=$$(tput cols 2>/dev/null); \
	case "$$cols" in ''|*[!0-9]*) cols=100;; esac; \
	[ "$$cols" -ge 40 ] || cols=100; \
	printf "\n  $(BOLD)differ.nvim$(NC) — make targets\n\n"; \
	awk -v width="$$cols" ' \
		function wrap(text, w, ind,    n, words, i, line, out, pad) { \
			pad = sprintf("%" ind "s", ""); \
			n = split(text, words, " "); line = ""; out = ""; \
			for (i = 1; i <= n; i++) { \
				if (line == "") line = words[i]; \
				else if (length(line) + 1 + length(words[i]) <= w - ind) line = line " " words[i]; \
				else { out = out line "\n" pad; line = words[i]; } \
			} \
			return out line; \
		} \
		/^##@ / { order[++cnt] = "S\t" substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*## / { \
			split($$0, a, /:.*## /); \
			order[++cnt] = "T\t" a[1] "\t" a[2]; \
			if (length(a[1]) > maxname) maxname = length(a[1]); \
		} \
		END { \
			ind = maxname + 5; \
			fmt = "  $(GREEN)%-" maxname "s$(NC)  %s\n"; \
			for (i = 1; i <= cnt; i++) { \
				split(order[i], p, "\t"); \
				if (p[1] == "S") printf "\n  $(YELLOW)%s$(NC)\n", p[2]; \
				else printf fmt, p[2], wrap(p[3], width, ind); \
			} \
			printf "\n"; \
		} \
	' $(MAKEFILE_LIST)
