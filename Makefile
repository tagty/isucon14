HOST ?= isu14-1
BRANCH ?= main
GO := /home/isucon/local/golang/bin/go

.PHONY: deploy
deploy:
	ssh $(HOST) " \
		cd /home/isucon; \
		git checkout .; \
		git fetch; \
		git checkout $(BRANCH); \
		git reset --hard origin/$(BRANCH)"

.PHONY: build
build:
	ssh $(HOST) " \
		cd /home/isucon/webapp/go; \
		$(GO) build -o isuride"

# ローカルでクロスビルドして scp する場合
.PHONY: go-build-local
go-build-local:
	cd ./webapp/go && GOOS=linux GOARCH=amd64 go build -o isuride

.PHONY: go-deploy
go-deploy:
	scp ./webapp/go/isuride $(HOST):/home/isucon/webapp/go/

.PHONY: go-deploy-dir
go-deploy-dir:
	scp -r ./webapp/go $(HOST):/home/isucon/webapp/

.PHONY: restart
restart:
	ssh $(HOST) "sudo systemctl restart isuride-go.service"

# サーバから設定ファイル・Go のソースを取得する（初回用）
.PHONY: get-conf
get-conf:
	mkdir -p ./etc/mysql/mysql.conf.d ./etc/nginx/sites-enabled
	ssh $(HOST) "sudo cat /etc/mysql/mysql.conf.d/mysqld.cnf" > ./etc/mysql/mysql.conf.d/mysqld.cnf
	ssh $(HOST) "sudo cat /etc/nginx/nginx.conf" > ./etc/nginx/nginx.conf
	ssh $(HOST) "sudo cat /etc/nginx/sites-enabled/isuride.conf" > ./etc/nginx/sites-enabled/isuride.conf
	scp $(HOST):/home/isucon/env.sh ./env.sh
	rsync -av --exclude isuride $(HOST):/home/isucon/webapp/go ./webapp/

.PHONY: mysql-deploy
mysql-deploy:
	ssh $(HOST) "sudo dd of=/etc/mysql/mysql.conf.d/mysqld.cnf" < ./etc/mysql/mysql.conf.d/mysqld.cnf

.PHONY: mysql-rotate
mysql-rotate:
	ssh $(HOST) "sudo rm -f /var/log/mysql/mysql-slow.log"

.PHONY: mysql-restart
mysql-restart:
	ssh $(HOST) "sudo systemctl restart mysql.service"

.PHONY: nginx-deploy
nginx-deploy:
	ssh $(HOST) "sudo dd of=/etc/nginx/nginx.conf" < ./etc/nginx/nginx.conf
	ssh $(HOST) "sudo dd of=/etc/nginx/sites-enabled/isuride.conf" < ./etc/nginx/sites-enabled/isuride.conf

.PHONY: nginx-rotate
nginx-rotate:
	ssh $(HOST) "sudo rm -f /var/log/nginx/access.log"

.PHONY: nginx-reload
nginx-reload:
	ssh $(HOST) "sudo systemctl reload nginx.service"

.PHONY: nginx-restart
nginx-restart:
	ssh $(HOST) "sudo systemctl restart nginx.service"

.PHONY: env-deploy
env-deploy:
	ssh $(HOST) "sudo dd of=/home/isucon/env.sh" < ./env.sh

# ベンチ前のログローテート + 再起動
.PHONY: rotate
rotate: mysql-rotate nginx-rotate mysql-restart nginx-reload

BENCH_HOST ?= isu14-bench
# アプリサーバ（isu14-1）の内部 IP
BENCH_ADDR ?= 172.31.6.14:443
# ベンチサーバ（isu14-bench）の内部 IP。アプリから決済サーバとして叩かれる
BENCH_PAYMENT_HOST ?= 172.31.0.187
# isuride-payment_mock.service が 12345 を使っているのでずらす
BENCH_PAYMENT_PORT ?= 12346

.PHONY: bench
bench:
	ssh $(BENCH_HOST) " \
		cd /home/isucon; \
		./bench run --target https://xiv.isucon.net:443 --addr $(BENCH_ADDR) \
			--payment-bind-port $(BENCH_PAYMENT_PORT) --payment-url http://$(BENCH_PAYMENT_HOST):$(BENCH_PAYMENT_PORT)"

.PHONY: journalctl
journalctl:
	ssh $(HOST) "sudo journalctl -xef"

.PHONY: nginx-log
nginx-log:
	ssh $(HOST) "sudo tail -f /var/log/nginx/access.log"

.PHONY: pt-query-digest
pt-query-digest:
	ssh $(HOST) "sudo pt-query-digest --limit 10 /var/log/mysql/mysql-slow.log"

ALPSORT=sum
# /api/app/rides/01JDM0N9W89PK57C7XEVGD5C80/evaluation
# /api/chair/rides/01JDM0N9W89PK57C7XEVGD5C80/status
# /assets/*, /images/*
ALPM=/api/app/rides/[0-9A-Za-z]+/evaluation,/api/chair/rides/[0-9A-Za-z]+/status,/assets/.+,/images/.+
OUTFORMAT=count,method,uri,min,max,sum,avg,p99

.PHONY: alp
alp:
	ssh $(HOST) "sudo alp ltsv --file=/var/log/nginx/access.log --nosave-pos --pos /tmp/alp.pos --sort $(ALPSORT) --reverse -o $(OUTFORMAT) -m $(ALPM)"

.PHONY: pprof
pprof:
	ssh $(HOST) " \
		$(GO) tool pprof -seconds=120 /home/isucon/webapp/go/isuride http://localhost:6060/debug/pprof/profile"

.PHONY: pprof-show
pprof-show:
	$(eval latest := $(shell ssh $(HOST) "ls -rt ~/pprof/ | tail -n 1"))
	mkdir -p ./pprof
	scp $(HOST):~/pprof/$(latest) ./pprof
	go tool pprof -http=":1080" ./pprof/$(latest)

.PHONY: pprof-kill
pprof-kill:
	ssh $(HOST) "pgrep -f 'pprof' | xargs kill;"
