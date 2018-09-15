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
stop-ruby: ## update ruby
	sudo systemctl stop torb.ruby

update: update-ruby update-db update-nginx ## updat all

update-ruby: ## update ruby
	sudo cp /home/isucon/torb/webapp/config/systemd/torb.ruby.service /etc/systemd/system/torb.ruby.service
	sudo systemctl daemon-reload
	cd  /home/isucon/torb/webapp/ruby; /home/isucon/local/ruby/bin/bundle install --path=vendor/bundle
	sudo systemctl restart torb.ruby

update-db: ## update mysql
	sudo cp /home/isucon/torb/webapp/config/mysql/my.cnf /etc/my.cnf
	sudo systemctl restart mysqld

update-nginx: ## update nginx
	sudo cp /home/isucon/torb/webapp/config/nginx/nginx.conf.prod /etc/nginx/nginx.conf
	sudo rm /var/log/nginx/access.log
	sudo systemctl restart nginx

tail: ## tail nginx access.log
	sudo tail -f /var/log/nginx/access.log

alpp: ## Run alp on production
	sudo alp -f /var/log/nginx/access.log --sum -r --aggregates='/admin/api/reports/events/\d+/sales, /api/events/\d+/sheets/\w+/\d+/reservation, /admin/api/events/\d+/actions/edit, /api/events/\d+, /api/users/\d+' --include-statuses='2[00-99]'
	sudo alp -f /var/log/nginx/access.log --sum -r --aggregates='/admin/api/reports/events/\d+/sales, /api/events/\d+/sheets/\w+/\d+/reservation, /admin/api/events/\d+/actions/edit, /api/events/\d+, /api/users/\d+' --include-statuses='3[00-99]'
	sudo alp -f /var/log/nginx/access.log --sum -r --aggregates='/admin/api/reports/events/\d+/sales, /api/events/\d+/sheets/\w+/\d+/reservation, /admin/api/events/\d+/actions/edit, /api/events/\d+, /api/users/\d+' --include-statuses='4[00-99]'
	sudo alp -f /var/log/nginx/access.log --sum -r --aggregates='/admin/api/reports/events/\d+/sales, /api/events/\d+/sheets/\w+/\d+/reservation, /admin/api/events/\d+/actions/edit, /api/events/\d+, /api/users/\d+' --include-statuses='5[00-99]'

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
