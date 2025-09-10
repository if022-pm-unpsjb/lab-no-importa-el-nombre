# In order to access and save notebooks directly to your machine
# you can mount a local directory into the container.
# Make sure to specify the user with "-u $(id -u):$(id -g)"
# so that the created files have proper permissions
docker run -it --rm -v "$(pwd)":/app -w /app -u $(id -u):$(id -g) elixir:alpine iex --name $1 --cookie $2 -S mix
