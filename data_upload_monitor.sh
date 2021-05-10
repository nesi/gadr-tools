#!/usr/bin/env bash
# Author: Eirian Owen Perkins
# March 2021


###########################################################
# important configurations (change as needed)
###########################################################

OBJSTORE="/objstor"
BUCKET="testbucket"
PSQL_SERVICE="compose-services_postgres_1"
SCREEN_WIDTH="10000" # for configuring `more` command

MINIO_BASE="https://minio.data.nesi.org.nz"
INDEXD_SERVICE="indexd-service"
INDEXD_USER="indexd_client"
INDEXD_PASS="indexd_client_pass"

LAST_TIMESTAMP_CACHE="gen3_last_upload_time.txt"
EPOCH_START="1970-01-01 00:00:00"

###########################################################
# write error messages to stderr
# (can be used to append to logfile)
###########################################################

function echoerr {
    printf "%s\n" "$*" >&2;
}

###########################################################
# retrieve file size in bytes
#   input: GUID
#   output: file size in bytes
###########################################################

function file_size_in_bytes {
    local GUID=$1
    local fname=$2
    local filepath=${OBJSTORE}"/"${BUCKET}"/"${GUID}"/${fname}"
    # use --format=%n:%s to add the file's absolute path
    local size=$(stat --format=%s ${filepath} | head -n 1)
    echo $size
}

###########################################################
# calculate a file's md5
#   input: GUID
#   output: md5
###########################################################

function file_md5 {
    local GUID=$1
    local fname=$2
    local filepath=${OBJSTORE}"/"${BUCKET}"/"${GUID}"/${fname}"
    local hash=$(md5sum ${filepath} | head -n 1 | cut -d ' ' -f 1)
    echo $hash
}



###########################################################
# retrieve all uploaded files since last timestamp
# using psql on the running indexd container
#   input: timestamp in UTC
#   output: all files that have been uploaded
###########################################################

function uploaded_files_since_last_check {
    # timestamps in indexdb are given in utc by default
    # need to only get "blank" entries, e.g. records
    #   without size and hash
    local timestamp="$1"
    # cut off seconds, if you want
    #timestamp=$(echo $timestamp | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')

    # example command:
    # docker exec -it compose-services_postgres_1 psql -d indexd_db -U indexd_user -c "select file_name, did, rev, created_date from index_record where size is NULL and created_date > '2021-03-02 02:24:29.431852+00';"
    local select="select file_name, did, rev, created_date at time zone 'utc' from index_record where size is NULL and created_date > '${timestamp}'"
    local psql_args="-d indexd_db -U indexd_user -c " #'${select}'"

    # need to add env var so psql output prints properly
    # otherwise, get multiple lines per entry (difficult to detect/parse)
    local docker="docker exec -e PAGER=\"/bin/more -<${SCREEN_WIDTH}>\" ${PSQL_SERVICE} psql ${psql_args} \"${select};\""
    local results=$(eval ${docker})

    # example output:
    #
    #   file_name    |                 did                  |   rev    |        created_date
    #   -------------+--------------------------------------+----------+----------------------------
    #   foo.txt      | 8158ec7d-6bbb-49d1-8606-a4e7fb942b39 | 1ddd18bb | 2021-03-02 02:24:37.845827
    #   bar.txt      | 2e524f14-8b3d-4f3c-be84-defb7570fbac | 48ff19aa | 2021-03-02 02:24:54.604059
    #   baz.txt      | 19d3fc0d-e06c-4782-963d-780fc39407e3 | d92db556 | 2021-03-02 02:25:27.38194
    #   (3 rows)

    # wrap $results in quotes to preserve newlines
    echo "${results}"
}

###########################################################
# construct URL for minio
#   input: file GUID
#   input: file name
#   output: minio URL for download
###########################################################
function construct_minio_download_url {
    local GUID=$1
    local fname=$2
    local URL=${MINIO_BASE}"/"${BUCKET}"/"${GUID}"/"${fname}
    echo $URL
}

###########################################################
# update record using cURL PUT request on
# the running indexd container
#   input: file GUID
#   input: file name
#   input: record revision (rev in indexd)
#   output: log messages (pass/fail)
###########################################################
function update_blank_record {
    local fname=$1
    local GUID=$2
    local rev=$3
    local URL=$(construct_minio_download_url ${GUID} ${fname})
    local size=$(file_size_in_bytes ${GUID} ${fname})
    local md5=$(file_md5 ${GUID} ${fname})
    local payload="{\"size\": ${size}, \"hashes\": {\"md5\": \"${md5}\"}, \"urls\": [\"${URL}\"] }"
    # construct cURL command
    local curl_cmd="curl -H 'Content-Type: application/json' -X PUT -u ${INDEXD_USER}:${INDEXD_PASS} -d "
    local curl_args="'${payload}' http://localhost/index/blank/${GUID}?rev=${rev}"
    # perform PUT from inside indexd
    local docker="docker exec -i ${INDEXD_SERVICE} ${curl_cmd} ${curl_args}"
    # the command that was run
    #echo $docker
    local results=$(eval ${docker})
    # results from running command
    echo "${results}"
}


###########################################################
# helper function for `loop_through_new_blank_records`
# extract filename from PSQL output
#   input: data line from PSQL output
#   output: filename
###########################################################
function extract_filename {
    echo "$1" | cut -d '|' -f 1
}

###########################################################
# helper function for `loop_through_new_blank_records`
# extract GUID from PSQL output
#   input: data line from PSQL output
#   output: GUID
###########################################################
function extract_guid {
    #result=$(echo "$1" | cut -d '|' -f 2)
    #echo $result
    echo "$1" | cut -d '|' -f 2
}

###########################################################
# helper function for `loop_through_new_blank_records`
# extract rev from PSQL output
#   input: data line from PSQL output
#   output: rev
###########################################################
function extract_rev {
    echo "$1" | cut -d '|' -f 3
}


###########################################################
# loop through new files data and invoke indexd updater.
# NOTE: a "blank record" is the term Gen3 uses for file
#       entries that do not yet have size/hash information
#   input: timestamp (from which to retrieve new entries)
#   output:
###########################################################
function loop_through_new_blank_records {
    local timestamp="$1"

    # on OSX, get "illegal line count -- -1", works on NeSI prod though
    # sed works in both places, prefer for portability
    #output=$(uploaded_files_since_last_check $timestamp | tail -n +3 | head -n -1)

    local output=$(uploaded_files_since_last_check "$timestamp" |
        sed /file_name/d | sed -e /.*[-]+.*/d | sed -e /^$/d | sed \$d)

    echo "${output}" |
        while read x; do
            local fname=$(extract_filename "${x}" | xargs)
            local guid=$(extract_guid "${x}" | xargs)
            local rev=$(extract_rev "${x}" | xargs)
            # here is where I want to check if file exists in
            local filepath=${OBJSTORE}"/"${BUCKET}"/"${guid}"/${fname}"
            if [[ -a ${filepath} && ! -z ${fname} ]]
            then
                # currently assuming this works
                local results=$(update_blank_record ${fname} ${guid} ${rev})
                # check if it is ok to uncomment -- does that mess up other fn calls?
                # echo does, try echoerr instead
                echoerr $(date -u) $results
            else
                # file DNE; complain in stderr
                echoerr $(date -u) "file does not exist in minio; path: ${filepath}; entry: ${x}"
            fi
        done

    # extract last timestamp
    local last_timestamp=$(echo "${output}" | cut -d '|' -f 4 | sort | tail -n 1)
    # write to file
    if [[ ! -z $last_timestamp ]]
    then
    	echo $last_timestamp > ${LAST_TIMESTAMP_CACHE}
    fi
}

###########################################################
# check that indexd, PSQL are running
###########################################################

function healthcheck {
    local status=$(/bin/docker-compose ps)
    local psql_status=$(echo "${status}" | grep ${PSQL_SERVICE})
    local indexd_status="$(echo "${status}" | grep ${INDEXD_SERVICE})"
    local healthy="Up (healthy)"

    if [[ $psql_status == *${healthy}* ]] && [[ $indexd_status == *${healthy}* ]]
    then
        return 0
    else
        return 1
    fi
}

###########################################################
#   "main"
###########################################################

function main {
    # what if it is empty?
    local last_timestamp=$(cat ${LAST_TIMESTAMP_CACHE} | sed -e /^$/d )
    if [[ -z $last_timestamp ]]
    then
        last_timestamp=$EPOCH_START
    fi

    #perform healthcheck
    if $(healthcheck)
    then
        $(loop_through_new_blank_records "${last_timestamp}")
    else
        echoerr $(date -u) "check container health"
    fi

}


main
