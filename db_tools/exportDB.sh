#!/bin/bash

POSTGRES=$(docker ps -aqf "name=compose-services_postgres_1")

docker exec -it $POSTGRES pg_dump -C -h localhost -U fence_user fence_db > fence_dump.db
docker exec -it $POSTGRES pg_dump -C -h localhost -U fence_user indexd_db > indexd_dump.db
docker exec -it $POSTGRES pg_dump -C -h localhost -U peregrine_user metadata_db > metadata_dump.db
docker exec -it $POSTGRES pg_dump -C -h localhost -U arborist_user arborist_db > arborist_dump.db
