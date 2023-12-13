.PHONY: build deploy image-create image-populate image-finalize lint tests

SERVICE=$(shell basename $(shell git rev-parse --show-toplevel))
REGISTRY=registry.openculinary.org
PROJECT=reciperadar

IMAGE_NAME=${REGISTRY}/${PROJECT}/${SERVICE}
IMAGE_COMMIT := $(shell git rev-parse --short HEAD)
IMAGE_TAG := $(strip $(if $(shell git status --porcelain --untracked-files=no), latest, ${IMAGE_COMMIT}))

YYYYMMDD := $(shell date "+%Y%m%d")

build: image

deploy:
	kubectl apply -f k8s
	kubectl set image deployments -l app=${SERVICE} ${SERVICE}=${IMAGE_NAME}:${IMAGE_TAG}-${YYYYMMDD}

image: image-create collect-postgresql collect-opensearch image-populate image-finalize

image-create:
	$(eval container=$(shell buildah from docker.io/library/nginx:alpine))
	buildah copy $(container) 'etc/nginx/conf.d' '/etc/nginx/conf.d'
	buildah run --network none $(container) -- rm -rf '/usr/share/nginx/html' --
	rm -rf public && mkdir public

collect-postgresql:
	$(eval POSTGRESQL_FILENAME=postgresql-${YYYYMMDD}.sql)
	pg_dump --host postgresql --username backend --dbname backend --exclude-table-data 'domains' --exclude-table-data 'events.*' > /mnt/backup/postgresql/${YYYYMMDD}.sql
	cp /mnt/backup/postgresql/${YYYYMMDD}.sql public/${POSTGRESQL_FILENAME}
	gzip --keep public/${POSTGRESQL_FILENAME}

collect-opensearch:
	$(eval OPENSEARCH_FILENAME=opensearch-${YYYYMMDD}.tar)
	curl -XDELETE 'http://opensearch:9200/_snapshot/reciperadar/singleton'
	curl -XPOST 'http://opensearch:9200/_snapshot/reciperadar/singleton?wait_for_completion=true'
	tar --create --file public/${OPENSEARCH_FILENAME} --directory /mnt/backup opensearch
	curl -XDELETE 'http://opensearch:9200/_snapshot/reciperadar/singleton'
	gzip --keep public/${OPENSEARCH_FILENAME}

image-populate:
	$(eval emails=$(shell grep --count '[a-Z][@][a-Z]*[.][a-Z]' public/${POSTGRESQL_FILENAME}))
	@if [ "${emails}" -ne "0" ]; then echo "error: the database backup may unexpectedly contain email addresses; please inspect the contents before proceeding"; exit 1; fi;
	cp src/odbl-10.txt public/odbl-10.txt
	venv/bin/jinja2 \
		-D yyyymmdd=${YYYYMMDD} \
		-D postgresql_filename=${POSTGRESQL_FILENAME}.gz \
		-D postgresql_size_compressed=$(shell stat -c '%s' public/${POSTGRESQL_FILENAME}.gz | numfmt --to=iec) \
		-D postgresql_size_uncompressed=$(shell stat -c '%s' public/${POSTGRESQL_FILENAME} | numfmt --to=iec) \
		-D postgresql_hash_compressed=$(shell sha256sum public/${POSTGRESQL_FILENAME}.gz | cut -d ' ' -f 1) \
		-D opensearch_filename=${OPENSEARCH_FILENAME}.gz \
		-D opensearch_size_compressed=$(shell stat -c '%s' public/${OPENSEARCH_FILENAME}.gz | numfmt --to=iec) \
		-D opensearch_size_uncompressed=$(shell stat -c '%s' public/${OPENSEARCH_FILENAME} | numfmt --to=iec) \
		-D opensearch_hash_compressed=$(shell sha256sum public/${OPENSEARCH_FILENAME}.gz | cut -d ' ' -f 1) \
		--strict src/index.html.jinja \
		--outfile public/index.html
	rm -f public/${POSTGRESQL_FILENAME}
	rm -f public/${OPENSEARCH_FILENAME}

image-finalize:
	buildah copy $(container) 'public' '/usr/share/nginx/html'
	buildah config --cmd '/usr/sbin/nginx -g "daemon off;"' --port 80 $(container)
	buildah commit --quiet --rm --squash $(container) ${IMAGE_NAME}:${IMAGE_TAG}-${YYYYMMDD}

# Virtualenv Makefile pattern derived from https://github.com/bottlepy/bottle/
venv: venv/.installed requirements-dev.txt
	venv/bin/pip install --requirement requirements-dev.txt --quiet
	touch venv
venv/.installed:
	python3 -m venv venv
	venv/bin/pip install pip-tools
	touch venv/.installed

requirements-dev.txt: requirements-dev.in
	venv/bin/pip-compile --allow-unsafe --generate-hashes --no-config --no-header --quiet --strip-extras requirements-dev.in

lint:
	true

tests:
	true
