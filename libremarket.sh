#!/bin/bash

start() {
    # Levantar los contenedores en segundo plano
    export DOCKER_UID=$UID
    export DOCKER_GID=$GID
    docker compose up -d "$@"
}

stop() {
    export DOCKER_UID=$UID
    export DOCKER_GID=$GID
    docker compose down
}

# Comprobar el argumento proporcionado
if [[ $1 == "start" ]]; then
    shift
    start "$@"
elif [[ $1 == "stop" ]]; then
    stop
elif [[ $1 == "iex" ]]; then
    docker attach $2
else
    echo "Uso: $0 {start|stop|iex nombre_de_contenedor}"
    exit 1
fi
