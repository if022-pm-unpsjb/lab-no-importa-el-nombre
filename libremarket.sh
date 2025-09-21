#!/bin/bash

start() {
    # Levantar los contenedores en segundo plano
    export SECRET=secret
    export DOCKER_UID=$UID
    export DOCKER_GID=$GID
    docker compose up -d "$@"
}

stop() {
    export SECRET=secret
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
elif [[ $1 == "build" ]]; then
    docker run -it --rm -v "$(pwd)":/app -w /app -u $(id -u):$(id -g) -e MIX_HOME=/app/mix_home -e HEX_HOME=/app/hex_home --network host elixir:alpine mix compile
elif [[ $1 == "iex" ]]; then
    docker attach $2
else
    echo "Uso: $0 {start|stop|iex nombre_de_contenedor}"
    exit 1
fi
