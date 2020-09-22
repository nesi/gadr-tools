#!/bin/bash

POSTGRES=$(docker ps -aqf "name=compose-services_postgres_1")

docker cp fence_dump.db ${POSTGRES}:/
docker exec -it $POSTGRES bash -c "cat /fence_dump.db | psql fence_db -U fence_user"

docker cp index_dump.db ${POSTGRES}:/
docker exec -it $POSTGRES bash -c "cat indexd_dump.db | psql indexd_db -U fence_user"

docker cp metadata_dump.db ${POSTGRES}:/
docker exec -it $POSTGRES bash -c "cat metadata_dump.db | psql metadata_db -U peregrine_user"

docker cp arborist_dump.db ${POSTGRES}:/
docker exec -it $POSTGRES bash -c "cat arborist_dump.db | psql arborist_db -U arborist_user"