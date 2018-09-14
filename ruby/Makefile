.DEFAULT_GOAL := help

dev: ## Run Serve
	bundle exec unicorn -c unicorn_config.rb

prod: ## Run Serve as production
	bundle exec unicorn -c unicorn_config.rb -E production

pry: ## Run pry
	bundle exec pry

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
