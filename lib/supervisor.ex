defmodule Libremarket.Supervisor do
  use Supervisor

  @doc """
  Inicia el supervisor
  """
  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Topología de libcluster
    topologies = [
      gossip: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: "0.0.0.0",
          multicast_addr: "192.168.0.192",
          broadcast_only: true,
          secret: "secret"
        ]
      ]
    ]

    server_to_run =
      case System.get_env("SERVER_TO_RUN") do
        nil ->
          []

        "Elixir.Libremarket.Router" ->
          port = String.to_integer(System.get_env("PORT") || "4000")
          [
            {Plug.Cowboy, scheme: :http, plug: Libremarket.Router,
             options: [port: port, ip: {0, 0, 0, 0}]}
          ]

        server_str ->
          [{String.to_existing_atom(server_str), %{}}]
      end

    children = [
      {Cluster.Supervisor, [topologies, [name: Libremarket.ClusterSupervisor]]}
    ] ++ server_to_run

    Supervisor.init(children, strategy: :one_for_one)
  end
end
