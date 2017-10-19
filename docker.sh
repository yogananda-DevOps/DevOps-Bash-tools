#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2016-02-07 22:42:47 +0000 (Sun, 07 Feb 2016)
#
#  https://github.com/harisekhon/bash-tools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir_bash_tools_docker="${srcdir:-}"
srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$srcdir/utils.sh"

docker_compose_quiet=""
if [ -n "${TRAVIS:-}" ]; then
    docker_compose_quiet="--quiet"
fi

is_docker_available(){
    #[ -n "${TRAVIS:-}" ] && return 0
    if which docker &>/dev/null; then
        if docker info &>/dev/null; then
            return 0
        fi
    fi
    #echo "Docker not available"
    return 1
}

is_docker_compose_available(){
    #[ -n "${TRAVIS:-}" ] && return 0
    if which docker-compose &>/dev/null; then
        return 0
    fi
    #echo "Docker Compose not available"
    return 1
}

check_docker_available(){
    if ! is_docker_available; then
        echo 'WARNING: Docker not found, skipping checks!!!'
        exit 0
    fi
    if ! is_docker_compose_available; then
        echo 'WARNING: Docker Compose not found in $PATH, skipping checks!!!'
        exit 0
    fi
    # alternative
    #export DOCKER_SERVICE="$(ps -o comm= $PPID)"
    export DOCKER_SERVICE="${BASH_SOURCE[1]#*test_}"
    export DOCKER_SERVICE="${DOCKER_SERVICE%.sh}"
    export DOCKER_CONTAINER="${COMPOSE_PROJECT_NAME:-docker}_${DOCKER_SERVICE}_1"
    # nagios-plugins -> nagiosplugins
    export DOCKER_CONTAINER="${DOCKER_CONTAINER//-}"
    export COMPOSE_FILE="$srcdir/docker/$DOCKER_SERVICE-docker-compose.yml"
}

is_docker_container_running(){
    local containers="$(docker ps)"
    if [ -n "${DEBUG:-}" ]; then
        echo "Containers Running:
$containers
"
    fi
    #if grep -q "[[:space:]]$1$" <<< "$containers"; then
    if [[ "$containers" =~ [[:space:]]$1$ ]]; then
        return 0
    fi
    return 1
}

is_inside_docker(){
    test -f /.dockerenv
}

declare_if_inside_docker(){
    if is_inside_docker; then
        echo
        echo "(running in Docker container $(hostname -f))"
        echo
    fi
}

docker_compose_port(){
    local env_var="${1:-}"
    local name="${2:-}"
    if [ -z "$env_var" ]; then
        echo "ERROR: docker_compose_port() first arg \$1 was not supplied for \$env_var"
        exit 1
    fi
    if [ -z "$name" ]; then
        name="$env_var"
    fi
    name="$name port"
    if ! [[ "$env_var" =~ .*_PORT$ ]]; then
        #env_var="$(tr '[[:lower:]]' '[[:upper:]]' <<< "$env_var")_PORT"
        env_var="$(sed 's/\(.*\)/\U\1/;s/[^[:alnum:]]/_/g' <<< "$env_var")_PORT"
    fi
    if [ -z "${DOCKER_SERVICE:-}" ]; then
        echo "ERROR: \$DOCKER_SERVICE is not set, cannot run docker_compose_port()"
        exit 1
    fi
    if eval [ -z \$"${env_var}_DEFAULT" ]; then
        echo "ERROR: ${env_var}_DEFAULT is not set, cannot run docker_compose_port()"
        exit 1
    fi
    printf "$name => "
    export $env_var="$(eval docker-compose port "$DOCKER_SERVICE" $`echo ${env_var}_DEFAULT` | sed 's/.*://')"
    if eval [ -z \$"$env_var" ]; then
        echo "ERROR: failed to get port mapping for $env_var"
        exit 1
    fi
    if eval [ -z \$"$env_var" ]; then
        echo "FAILED got no port mapping for $env_var... did the container crash?"
        exit 1
    fi
    if eval ! [[ \$"$env_var" =~ ^[[:digit:]]+$ ]]; then
        echo -n "ERROR: failed to get port mapping for $env_var - non-numeric port '"
        eval echo -n \$"$env_var"
        echo "' returned, possible parse error"
        exit 1
    fi
    eval echo "\$$env_var"
}

dockerhub_latest_version(){
    repo="${1-}"
    if [ -z "$repo" ]; then
        echo "Error: no repo passed to dockerhub_latest_version for first arg"
    fi
    set +e
    local version="$(curl -s "https://raw.githubusercontent.com/HariSekhon/Dockerfiles/master/$repo/Dockerfile" | awk -F= '/^ARG[[:space:]]+[A-Za-z_]+_VERSION=/ {print $2; exit}')"
    set -e
    if [ -z "$version" ]; then
        version='.*'
    fi
    echo "$version"
}

external_docker(){
    [ -n "${EXTERNAL_DOCKER:-}" ] && return 0 || return 1
}

launch_container(){
    local image="${1:-${DOCKER_IMAGE}}"
    local container="${2:-${DOCKER_CONTAINER}}"
    local ports="${@:3}"
    if [ -n "${TRAP:-}" ] || is_CI; then
        trap_container "$container"
    fi
    if external_docker; then
        echo "External Docker detected, skipping container creation..."
        return 0
    else
        [ -n "${DOCKER_HOST:-}" ] && echo "using docker address '$DOCKER_HOST'"
        if ! is_docker_available; then
            echo "WARNING: Docker not found, cannot launch container $container"
            return 1
        fi
        # reuse container it's faster
        #docker rm -f "$container" &>/dev/null
        #sleep 1
        if [[ "$container" = *test* ]]; then
            docker rm -f "$container" &>/dev/null || :
        fi
        if ! is_docker_container_running "$container"; then
            # This is just to quiet down the CI logs from useless download clutter as docker pull/run doesn't have a quiet switch as of 2016 Q3
            if is_CI; then
                # pipe to cat tells docker that stdout is not a tty, switches to non-interactive mode with less output
                { docker pull "$image" || :; } | cat
            fi
            port_mappings=""
            for port in $ports; do
                port_mappings="$port_mappings -p $port:$port"
            done
            echo -n "starting container: "
            # need tty for sudo which Apache startup scripts use while SSH'ing localhost
            # eg. hadoop-start.sh, hbase-start.sh, mesos-start.sh, spark-start.sh, tachyon-start.sh, alluxio-start.sh
            docker run -d -t --name "$container" ${DOCKER_OPTS:-} $port_mappings "$image" ${DOCKER_CMD:-}
            hr
            echo "Running containers:"
            docker ps
            hr
            #echo "waiting $startupwait seconds for container to fully initialize..."
            #sleep $startupwait
        else
            echo "Docker container '$container' already running"
        fi
    fi
    if [ -n "${ENTER:-}" ]; then
        docker exec -ti "$DOCKER_CONTAINER" bash
    fi
}

delete_container(){
    local container="${1:-$DOCKER_CONTAINER}"
    local msg="${2:-}"
    echo
    if [ -z "${NODELETE:-}" ] && ! external_docker; then
        if [ -n "$msg" ]; then
            echo "$msg"
        fi
        echo -n "Deleting container "
        docker rm -f "$container"
        untrap
    fi
}

trap_container(){
    local container="${1:-$DOCKER_CONTAINER}"
    trap 'result=$?; '"delete_container $container 'trapped exit, cleaning up container'"' || : ; exit $result' $TRAP_SIGNALS
}

# restore original srcdir
srcdir="$srcdir_bash_tools_docker"
