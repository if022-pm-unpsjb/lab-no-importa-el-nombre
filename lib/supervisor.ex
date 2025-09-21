defmodule Libremarket.Supervisor do
  use Supervisor

  @doc """
  Inicia el supervisor
  """
  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
        topologies = [
      gossip: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: "0.0.0.0",
          multicast_addr: "127.0.0.1",
          broadcast_only: true,
          secret: "secret"
        ]
      ]
    ]

    server_to_run =
      case System.get_env("SERVER_TO_RUN") do
        nil -> []
        server_to_run -> [{String.to_existing_atom(server_to_run), %{}}]
      end

    childrens = [
      { Cluster.Supervisor, [topologies, [name: Libremarket.ClusterSupervisor]]},
    ] ++ server_to_run

    Supervisor.init(childrens, strategy: :one_for_one)
  end
end
