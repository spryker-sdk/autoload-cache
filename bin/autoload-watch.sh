#!/bin/bash

VERBOSE=0
DEFAULT_WATCH_INCLUDE="/src /tests /vendor"
WATCH_EXCLUDE="/vendor/bin/ /vendor/composer/ /vendor/autoload.php .git node_modules"
HOST_DIR="$PWD"
APP_DIR="$PWD"
REDIS_HOST='localhost'
REDIS_PORT='6379'
REDIS_DATABASE=0
KEY_PREFIX='autoload'
KEY_SEPARATOR=':'

if [ "$1" == 'help' ] || [ "$1" == '--help' ]; then
    script=$(basename "$0")
    echo ""
    echo "The script watches given folders and files and remove related entities from redis by path or class name"
    echo ""
    echo "Usage: ${script} [-v] [-e FILE_PATH_TO_INCLUDE]... [-x FILE_PATH_TO_EXCLUDE]... [-w ROOT_FOLDER_TO_WATCH] [-r ROOT_FOLDER_TO_UPDATE] [-h REDIS_HOST] [-p REDIS_PORT] [-n REDIS_DATABASE] [-k KEY_PREFIX] [-s KEY_SEPARATOR]"
    echo ""
    exit
fi

while getopts "e:x:w:r:h:p:n:k:s:v" opt; do
    case ${opt} in
    # Include file or directory
    e)
        WATCH_INCLUDE="${WATCH_INCLUDE} ${OPTARG}"
        ;;
    # Exclude file or directory
    x)
        WATCH_EXCLUDE="${WATCH_EXCLUDE} ${OPTARG}"
        ;;
    # Watch root folder. That support inotify
    w)
        HOST_DIR=${OPTARG%/}
        HOST_DIR=${HOST_DIR# }
        ;;
    # Read root folder. That provides fast read access.
    r)
        APP_DIR=${OPTARG%/}
        APP_DIR=${APP_DIR# }
        ;;
    # Redis host
    h)
        REDIS_HOST=${OPTARG# }
        ;;
    # Redis port
    p)
        REDIS_PORT=${OPTARG# }
        ;;
    # Redis database
    n)
        REDIS_DATABASE=${OPTARG# }
        ;;
    # Key prefix
    k)
        KEY_PREFIX=${OPTARG# }
        ;;
    # Key separator
    s)
        KEY_SEPARATOR=${OPTARG# }
        ;;
    v)
        VERBOSE=1
        ;;
    *) ;;

    esac
done
shift $((OPTIND - 1))

WATCH=""
WATCH_INCLUDE=${WATCH_INCLUDE:-"${DEFAULT_WATCH_INCLUDE}"}
for path in ${WATCH_INCLUDE}; do
    [ "${path:0:1}" == '/' ] && path="${HOST_DIR}${path}"
    WATCH="${WATCH} ${path}"
done

for path in ${WATCH_EXCLUDE}; do
    [ "${path:0:1}" == '/' ] && path="${HOST_DIR}${path}"
    WATCH="${WATCH} @${path}"
done

function verbose() {
    [ "${VERBOSE}" == 1 ] && echo "[V] ${*}"
}

function deleteKeysByPattern() {
    local MASK="${KEY_PREFIX}${KEY_SEPARATOR}${1}"
    verbose "Deleting keys by mask: ${MASK}"
    redis-cli -n "${REDIS_DATABASE}" -h "${REDIS_HOST}" -p "${REDIS_PORT}" --raw --scan --pattern "${MASK}" |
        xargs --no-run-if-empty -I K_E_Y redis-cli -n "${REDIS_DATABASE}" -h "${REDIS_HOST}" -p "${REDIS_PORT}" --raw del "K_E_Y" >/dev/null
}

function flushMap() {
    deleteKeysByPattern "*"
}

function deleteFileFromMap() {
    local FILE_PATH=$1
    deleteKeysByPattern "${FILE_PATH}*"

    return 0
}

function deleteClassFromMap() {
    local FILE_PATH=$1
    if [[ "${FILE_PATH}" == *\.php ]] && [ -f "${FILE_PATH}" ]; then
        NAMESPACE=$(grep namespace "${FILE_PATH}" | awk '{print $2}' RS=';' | tr '\\' '/' | tr -d " \n\r")
        CLASSNAME=$(grep -e class -e interface -e trait "${FILE_PATH}" | awk '{print $2}' RS=';' | tr -d " \n\r")

        [ -n "${NAMESPACE}" ] && [ -n "${CLASSNAME}" ] && deleteKeysByPattern "*${KEY_SEPARATOR}${NAMESPACE}/${CLASSNAME}"
    fi

    return 0
}

function observeFile() {
    local FILE_PATH=$1
    deleteFileFromMap "${FILE_PATH}"
    deleteClassFromMap "${FILE_PATH}"
    echo "[+] ${FILE_PATH}"

    return 0
}

function observeDirectory() {
    local FILE_PATH="${1%/}/"
    local EVENT_TYPE=$2

    case "$EVENT_TYPE" in
    *DELETE*)
        observeFile "${FILE_PATH}"
        ;;
    *CREATE*)
        [ -d "$FILE_PATH" ] && find "${FILE_PATH}" -type f -name "*.php" |
            while read PHP_FILE; do
                observeFile "$PHP_FILE" "$EVENT_TYPE"
            done
        ;;
    esac

    return 0
}

rm /tmp/.autoload_healthy >/dev/null 2>&1
START_TIME=$(date +%s)

echo "Redis: ${REDIS_HOST}:${REDIS_PORT}[${REDIS_DATABASE}]"
echo "Starting watching: ${WATCH}"

{
    inotifywait -m -r -e create -e delete -e modify -e move -e move_self -e delete_self \
        --format '%w%f %e' \
        ${WATCH} 2>&3 |
        while read EVENT; do
            EVENT_ARRAY=($EVENT)
            FILE=${EVENT_ARRAY[0]}
            EVENT_TYPE=${EVENT_ARRAY[1]}

            # Ignoring event when tilde in the end of the file path
            [[ "${FILE}" == *\~ ]] && continue

            FILE_PATH="$APP_DIR${FILE:${#HOST_DIR}}"

            [[ "${EVENT_TYPE}" == *"ISDIR"* ]] || [[ "${FILE_PATH}" == */ ]] && observeDirectory "${FILE_PATH}" "${EVENT_TYPE}" && continue

            [[ "${FILE}" == *\.php ]] && observeFile "${FILE_PATH}" "${EVENT_TYPE}"
        done
} 3>&1 1>&2 |
    while read OUTPUT; do

        echo "${OUTPUT}"

        if [ "${OUTPUT}" == 'Watches established.' ]; then
            touch /tmp/.autoload_healthy || true
            flushMap
            echo "Time elapsed: $(date -ud "@$(($(date +%s) - "${START_TIME}"))" +%T)"
            echo 'Autoload map has been flushed.'
        fi
    done
