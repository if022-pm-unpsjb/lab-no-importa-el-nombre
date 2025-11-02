defmodule Libremarket.Pagos do

  def autorizar_pago() do
    Enum.random(1..100) <= 70
  end

end

defmodule Libremarket.Pagos.Server do
  @moduledoc """
  Pagos
  """

  use GenServer
  require Logger
  use AMQP

  @global_name {:global, __MODULE__}

  # API del cliente

  @doc """
  Crea un nuevo servidor de Pagos
  """
  def start_link(opts \\ %{}) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    name = if role == "PRINCIPAL", do: @global_name, else: __MODULE__
    GenServer.start_link(__MODULE__, %{role: role}, name: name)
  end

  def autorizar_pago(pid \\ __MODULE__, id_compra) do
    GenServer.call(@global_name, {:autorizar_pago, id_compra})
  end

  def listar_pagos(pid \\ __MODULE__) do
    GenServer.call(@global_name, :listar_pagos)
  end

  def apply_and_replicate(id_compra, pago_ok) do
    # llamamos al servidor global (esto funcionará si estamos en el PRIMARIO o desde el Consumer del primario)
    GenServer.call(@global_name, {:apply_and_replicate, id_compra, pago_ok}, 10_000)
  catch
    :exit, reason ->
      Logger.error("Pagos.Server.apply_and_replicate: fallo call al servidor global #{inspect(reason)}")
      {:error, reason}
  end

  def replica_apply(id_compra, pago_ok) do
    GenServer.call(__MODULE__, {:replica_update, id_compra, pago_ok}, 5_000)
  end

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(state) do
    {:ok, %{}}
  end

  @doc """
  Callback para un call :detectar_infraccion
  """
  @impl true
  def handle_call({:autorizar_pago, id_compra}, _from, state) do
    pago = Libremarket.Pagos.autorizar_pago()
    new_state = Map.put(state, id_compra, pago)
    {:reply, pago, new_state}
  end

  @doc """
  Callback para un call :listar_pagos
  """
  @impl true
  def handle_call(:listar_pagos, _from, state) do
    {:reply, state, state}
  end


  @impl true
  def handle_call({:apply_and_replicate, id, pago_ok}, _from, state) do
    storage = Map.get(state, :storage, %{})
    new_storage = Map.put(storage, id, pago_ok)
    state2 = Map.put(state, :storage, new_storage)

    replica_nodes = get_replica_nodes()
    Logger.info("Pagos.Server (primario) replica_nodes=#{inspect(replica_nodes)}")

    # Si no hay réplicas, no hacemos RPC (evita bloquear)
    if replica_nodes == [] do
      Logger.info("Pagos.Server: no hay réplicas detectadas -> aplicando local y devolviendo :ok")
      {:reply, :ok, state2}
    else
      results =
        replica_nodes
        |> Enum.map(fn node ->
          try do
            :rpc.call(node, Libremarket.Pagos.Server, :replica_apply, [id, pago_ok], 5_000)
          catch
            :exit, reason ->
              Logger.warn("RPC exit al nodo #{inspect(node)} -> #{inspect(reason)}")
              {:badrpc, reason}
            :error, reason ->
              Logger.warn("RPC error al nodo #{inspect(node)} -> #{inspect(reason)}")
              {:badrpc, reason}
          end
        end)

      Logger.info("Pagos.Server: resultado replicación=#{inspect(results)}")

      if Enum.all?(results, &(&1 == :ok)) do
        {:reply, :ok, state2}
      else
        Logger.warn("Pagos.Server: replicación incompleta, resultados=#{inspect(results)}")
        {:reply, {:error, :replication_failed, results}, state2}
      end
    end
  end

  @impl true
  def handle_call({:replica_update, id, pago_ok}, _from, state) do
    storage = Map.get(state, :storage, %{})
    new_storage = Map.put(storage, id, %{pago: pago_ok, ts: :os.system_time(:millisecond)})
    state2 = Map.put(state, :storage, new_storage)

    Logger.info("Pagos REPLICA #{inspect(node())}: replica_update id=#{inspect(id)} pago=#{inspect(pago_ok)} ts=#{inspect(DateTime.utc_now())}")

    # ACK al primario devolviendo :ok
    {:reply, :ok, state2}
  end

  defp get_replica_nodes() do
    service_prefix =
      __MODULE__
      |> Module.split()
      |> Enum.at(1)
      |> String.downcase()

    nodes = Node.list()
    Logger.debug("[#{service_prefix}] Buscando réplicas entre: #{inspect(nodes)}")

    replicas =
      nodes
      |> Enum.filter(fn node ->
        node_str = Atom.to_string(node)
        String.starts_with?(node_str, service_prefix)
      end)

    Logger.info("[#{service_prefix}] Réplicas detectadas: #{inspect(replicas)}")
    replicas
  end
end

defmodule Libremarket.Pagos.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "pagos_queue"
  @out_queue "compras_queue"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    if role == "PRINCIPAL" do
      send(self(), :setup)
      {:ok, Map.put(state, :role, role)}
    else
      Logger.info("Pagos.Consumer: modo REPLICA -> no me suscribo a AMQP.")
      {:ok, Map.put(state, :role, role)}
    end
  end

  def handle_info(:setup, state) do
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @in_queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @in_queue, nil, no_ack: false)
        Logger.info("Pagos listening on #{@in_queue}")
        {:noreply, Map.put(state, :chan, chan)}
      {:error, _} ->
        Logger.error("Pagos Consumer: sin conexion AMQP, reintentando en 1s")
        Process.send_after(self(), :setup, 1_000)
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, payload, meta}, %{chan: chan} = state) do
    spawn(fn -> process_message(chan, payload, meta) end)
    {:noreply, state}
  end

  defp process_message(chan, payload, %{delivery_tag: tag}) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id}} ->

        pago_ok = Libremarket.Pagos.autorizar_pago()
        Logger.info("Pagos -> id=#{id} autorizado? #{inspect(pago_ok)}")

        case Libremarket.Pagos.Server.apply_and_replicate(id, pago_ok) do
          :ok ->
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{"id" => id, "pago" => pago_ok})
            AMQP.Basic.ack(chan, tag)

          {:error, reason} ->
            Logger.warn("Pagos: replicación falló #{inspect(reason)} — publicando de todas formas.")
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{"id" => id, "pago" => pago_ok})
            AMQP.Basic.ack(chan, tag)
        end

      {:error, _} ->
        Logger.error("Pagos: payload mal formado #{inspect(payload)}")
        AMQP.Basic.reject(chan, tag, requeue: false)
    end
  end

  def handle_info({:basic_consume_ok, _}, state) do
    Logger.info("Suscripción AMQP confirmada correctamente.")
    {:noreply, state}
  end

  def handle_info({:basic_cancel, info}, state) do
    Logger.warning("Suscripción AMQP cancelada: #{inspect(info)}")
    {:stop, :normal, state}
  end

  def handle_info({:basic_cancel_ok, _}, state) do
    Logger.info("Cancelación AMQP confirmada.")
    {:noreply, state}
  end
end
