.PHONY: up down logs ps psql redis-cli load maintain reset

up:            ## start database service (postgres + redis + maintainer)
	docker compose up -d

down:          ## stop everything, keep data
	docker compose down

logs:          ## follow logs
	docker compose logs -f --tail=100

ps:
	docker compose ps

psql:          ## SQL shell as the admin role
	docker compose exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

redis-cli:
	docker compose exec redis redis-cli

load:          ## load a GTFS feed:  make load FEED=S1000542
	@test -n "$(FEED)" || (echo "usage: make load FEED=<feed_version>"; exit 1)
	docker compose run --rm loader /data $(FEED)

maintain:      ## run the upkeep job now and print the health report
	docker compose exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -c "SELECT jsonb_pretty(ops.maintain())"'

reset:         ## DANGER: stop and delete the database volume
	docker compose down -v

bootstrap:        ## apply all pending schema folders (idempotent)
	docker compose up -d bootstrap
	docker compose logs bootstrap

user:             ## apply only the user/ folder
	docker compose run --rm -e TARGET=user bootstrap

trip:             ## apply only the trip/ folder
	docker compose run --rm -e TARGET=trip bootstrap

journey:          ## apply only the journey/ folder
	docker compose run --rm -e TARGET=journey bootstrap