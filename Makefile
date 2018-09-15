.DEFAULT_GOAL := help

build: ## build develoment environment
	docker-compose build
	docker-compose run --rm web bundle install

serve: up attach ## Run Serve

up: ## Run web container
	docker-compose up -d web

attach: ## Attach running web container for binding.pry
	docker attach `docker ps -f name=isucon8q_web -f status=running --format "{{.ID}}"`

bundle: ## Run Bundle install
	docker-compose run --rm web bundle install

myprofiler: ## Run myprofiler
	docker-compose run --rm myprofiler

alp: ## Run alp
	 docker-compose run --rm alp -f access.log --sum -r --aggregates='/candidates/\d+, /political_parties/\w+' --include-statuses='2[00-99]'
	 docker-compose run --rm alp -f access.log --sum -r --aggregates='/candidates/\d+, /political_parties/\w+' --include-statuses='3[00-99]'
	 docker-compose run --rm alp -f access.log --sum -r --aggregates='/candidates/\d+, /political_parties/\w+' --include-statuses='4[00-99]'
	 docker-compose run --rm alp -f access.log --sum -r --aggregates='/candidates/\d+, /political_parties/\w+' --include-statuses='5[00-99]'

goose-up: ## Run goose up
	docker-compose run --rm goose up

goose-down: ## Run goose down
	docker-compose run --rm goose down

goose-status: ## Run goose status
	docker-compose run --rm goose status

mitmweb: ## Run mitmweb
	mitmweb --mode reverse:http://localhost:8888/ -p 80
	mitmdump -n -C flows.dms

db-reset: ## Reset DB
	docker-compose up -d db
	docker-compose exec db sh /var/tmp/wait.sh
	docker-compose exec db sh /var/tmp/init.sh

## 本番用

update-ruby: ## update ruby
	sudo cp /home/isucon/torb/webapp/config/systemd/torb.ruby.service /etc/systemd/system/torb.ruby.service
	sudo systemctl daemon-reload
	cd  /home/isucon/torb/webapp/ruby; /home/isucon/local/ruby/bin/bundle install
	sudo systemctl restart torb.ruby

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
