# KaruCore site — convenience targets.
# The site is an Astro (AstroPaper) project; these wrap the npm scripts.
# Override the package manager if needed: `make serve NPM=pnpm`.

NPM ?= npm

.DEFAULT_GOAL := help

.PHONY: help install serve check build preview clean deploy

help: ## Show this help
	@echo "KaruCore site — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## Install dependencies (clean, lockfile-based)
	$(NPM) ci

serve: ## Run the local dev server at http://localhost:4321
	$(NPM) run dev

check: ## Lint, check formatting, and type-check
	$(NPM) run lint
	$(NPM) run format:check
	$(NPM) run astro check

build: ## Production build (type-check, build, Pagefind index)
	$(NPM) run build

preview: build ## Build, then preview the production output locally
	$(NPM) run preview

clean: ## Remove generated build output
	rm -rf dist .astro public/pagefind

deploy: build ## Build, then push to main to trigger the GitHub Pages deploy
	@echo ">> Pushing current branch to origin/main (triggers .github/workflows/deploy.yml)"
	git push origin main
