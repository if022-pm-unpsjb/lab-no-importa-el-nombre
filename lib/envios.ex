defmodule Libremarket.Envios do
  @costos %{
    correo: 500,
    retiro: 0
  }

  def costo(tipo_envio) do
    Map.get(@costos, tipo_envio, 0)
  end
end

defmodule Libremarket.Envios.Server do
  use GenServer
  require Logger
  use AMQP

  @global_name {:global, __MODULE__}

  # API
  def start_link(opts \\ %{}) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    name = if role == "PRINCIPAL", do: @global_name, else: __MODULE__
    GenServer.start_link(__MODULE__, %{role: role}, name: name)
  end

  def registrar(pid \\ __MODULE__, id_compra, tipo_envio) do
    GenServer.call(@global_name, {:registrar, id_compra, tipo_envio})
  end

  def listar(pid \\ __MODULE__) do
    GenServer.call(@global_name, :listar)
  end

  def apply_and_replicate(id_compra, tipo_envio) do
    # llamamos al servidor global (esto funcionará si estamos en el PRIMARIO o desde el Consumer del primario)
    GenServer.call(@global_name, {:apply_and_replicate, id_compra, tipo_envio}, 10_000)
  catch
    :exit, reason ->
      Logger.error("Pagos.Server.apply_and_replicate: fallo call al servidor global #{inspect(reason)}")
      {:error, reason}
  end

  def replica_apply(id_compra, tipo_envio, costo_envio) do
    GenServer.call(__MODULE__, {:replica_update, id_compra, tipo_envio, costo_envio}, 5_000)
  end

  # Callbacks
  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:registrar, id_compra, tipo_envio}, _from, state) do
    costo_envio = Libremarket.Envios.costo(tipo_envio)

    envio = %{
      id_compra: id_compra,
      tipo_envio: tipo_envio,
      costo_envio: costo_envio
    }

    new_state = Map.put(state, id_compra, envio)
    {:reply, {:ok, envio}, new_state}
  end

  @impl true
  def handle_call(:listar, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:apply_and_replicate, id, tipo_envio}, _from, state) do
    costo_envio = Libremarket.Envios.costo(tipo_envio)

    envio = %{
      id_compra: id,
      tipo_envio: tipo_envio,
      costo_envio: costo_envio,
    }

    new_state = Map.put(state, id, envio)

    replica_nodes = get_replica_nodes()
    Logger.info("Envios.Server (primario) replica_nodes=#{inspect(replica_nodes)}")

    if replica_nodes == [] do
      Logger.info("Envios.Server: no hay réplicas detectadas -> aplicando local y devolviendo :ok")
      {:reply, {:ok, envio}, new_state}
    else
      results =
        replica_nodes
        |> Enum.map(fn node ->
          try do
            :rpc.call(node, Libremarket.Envios.Server, :replica_apply, [id, tipo_envio, costo_envio], 5_000)
          catch
            :exit, reason ->
              Logger.warn("RPC exit al nodo #{inspect(node)} -> #{inspect(reason)}")
              {:badrpc, reason}
            :error, reason ->
              Logger.warn("RPC error al nodo #{inspect(node)} -> #{inspect(reason)}")
              {:badrpc, reason}
          end
        end)

      Logger.info("Envios.Server: resultado replicación=#{inspect(results)}")

      if Enum.all?(results, &(&1 == :ok)) do
        {:reply, {:ok, envio}, new_state}
      else
        Logger.warn("Envios.Server: replicación incompleta, resultados=#{inspect(results)}")
        {:reply, {:error, :replication_failed, envio}, new_state}
      end
    end
  end

  @impl true
  def handle_call({:replica_update, id, tipo_envio, costo_envio}, _from, state) do
    envio = %{
      id_compra: id,
      tipo_envio: tipo_envio,
      costo_envio: costo_envio,
    }

    new_state = Map.put(state, id, envio)

    Logger.info("Envios REPLICA #{inspect(node())}: actualizado id=#{id}, tipo_envio=#{tipo_envio}, costo_envio=#{costo_envio}")

    {:reply, :ok, new_state}
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

defmodule Libremarket.Envios.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "envios_queue"
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
        Logger.info("Envios listening on #{@in_queue}")
        {:noreply, Map.put(state, :chan, chan)}
      {:error, _} ->
        Logger.error("Envios Consumer: sin conexion AMQP, reintentando en 1s")
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
      {:ok, %{"id" => id, "tipo_envio" => tipo_envio}} ->
        tipo_envio_atom = String.to_atom(tipo_envio)
        costo = Libremarket.Envios.costo(tipo_envio_atom)
        Logger.info("Envios -> id=#{id}, tipo=#{tipo_envio}, costo=#{costo}")

        case Libremarket.Envios.Server.apply_and_replicate(id, tipo_envio_atom) do
          {:ok, _envio} ->
            # Publicar resultado a Compras
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{
              "id" => id,
              "costo_envio" => costo
            })
            AMQP.Basic.ack(chan, tag)

          {:error, reason, _envio} ->
            Logger.warn("Envios: replicación falló #{inspect(reason)} — publicando igualmente.")
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{
              "id" => id,
              "costo_envio" => costo
            })
            AMQP.Basic.ack(chan, tag)
        end

      {:error, _} ->
        Logger.error("Envios: payload mal formado #{inspect(payload)}")
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
