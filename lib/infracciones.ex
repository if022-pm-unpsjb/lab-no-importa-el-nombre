defmodule Libremarket.Infracciones do

  def detectar_infraccion() do
    Enum.random(1..100) <= 30
  end

end

#Este es el modulo que se deberia copiar y pegar en cada servidor.
#Cambiar lo correspondiente para cada caso.
defmodule Libremarket.Infracciones.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "infracciones_queue"
  @out_queue "compras_queue"  # resultados van aquí

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    # Solo el PRIMARIO debe suscribirse a AMQP
    role = System.get_env("ROLE") || "PRINCIPAL"
    if role == "PRINCIPAL" do
      send(self(), :setup)
      {:ok, Map.put(state, :role, role)}
    else
      Logger.info("Infracciones.Consumer: modo REPLICA -> no me suscribo a AMQP.")
      {:ok, Map.put(state, :role, role)}
    end
  end

  def handle_info(:setup, state) do
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @in_queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @in_queue, nil, no_ack: false)
        Logger.info("Infracciones listening on #{@in_queue}")
        {:noreply, Map.put(state, :chan, chan)}
      {:error, _} ->
        Logger.error("Infracciones Consumer: sin conexion AMQP, reintentando en 1s")
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
      {:ok, %{"id" => id} = data} ->
        Logger.info("Infracciones: procesando id=#{id} payload=#{inspect(data)}")
        infr = Libremarket.Infracciones.detectar_infraccion()

        # Aquí llamamos al Server primario para aplicar+replicar
        case Libremarket.Infracciones.Server.apply_and_replicate(id, infr) do
          :ok ->
            # Solo cuando primario confirmó replicación (o intentó) publicamos a compras_queue
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{"id" => id, "infraccion" => infr})
            AMQP.Basic.ack(chan, tag)

          {:error, reason} ->
            Logger.warn("Infracciones: replicación falló #{inspect(reason)} — publicando de todas formas.")
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{"id" => id, "infraccion" => infr})
            AMQP.Basic.ack(chan, tag)
        end

      {:error, _} ->
        Logger.error("Infracciones: payload mal formado #{inspect(payload)}")
        AMQP.Basic.reject(chan, tag, requeue: false)
    end
  end

  # Confirmación de que el consumidor se suscribió correctamente
  def handle_info({:basic_consume_ok, _info}, state) do
    Logger.info("Suscripción AMQP confirmada correctamente.")
    {:noreply, state}
  end

  # Aviso de cancelación por parte del broker
  def handle_info({:basic_cancel, info}, state) do
    Logger.warning("Suscripción AMQP cancelada: #{inspect(info)}")
    {:stop, :normal, state}
  end

  # Confirmación de cancelación
  def handle_info({:basic_cancel_ok, _info}, state) do
    Logger.info("Cancelación AMQP confirmada.")
    {:noreply, state}
  end
end

defmodule Libremarket.Infracciones.Server do
  @moduledoc """
  Infracciones
  """

  use GenServer
  use AMQP
  require Logger

  @global_name {:global, __MODULE__}

  # API del cliente

  @doc """
  Crea un nuevo servidor de Infracciones
  """
  def start_link(opts \\ %{}) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    name = if role == "PRINCIPAL", do: @global_name, else: __MODULE__
    GenServer.start_link(__MODULE__, %{role: role}, name: name)
  end

  def detectar_infraccion(pid \\ __MODULE__, id_compra) do
    GenServer.call(@global_name, {:detectar_infraccion, id_compra})
  end

  def listar_infracciones(pid \\ __MODULE__) do
    GenServer.call(@global_name, :listar_infracciones)
  end

  def apply_and_replicate(id_compra, infr) do
    # llamamos al servidor global (esto funcionará si estamos en el PRIMARIO o desde el Consumer del primario)
    GenServer.call(@global_name, {:apply_and_replicate, id_compra, infr}, 10_000)
  catch
    :exit, reason ->
      Logger.error("Infracciones.Server.apply_and_replicate: fallo call al servidor global #{inspect(reason)}")
      {:error, reason}
  end

  def replica_apply(id_compra, infr) do
    GenServer.call(__MODULE__, {:replica_update, id_compra, infr}, 5_000)
  end

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(state) do
    # state: map id_compra -> boolean or info
    {:ok, Map.put(state, :storage, %{})}
  end

  @doc """
  Callback para un call :detectar_infraccion
  """
  @impl true
  def handle_call({:detectar_infraccion, id_compra}, _from, state) do
    infraccion = Libremarket.Infracciones.detectar_infraccion
    new_state = Map.put(state, id_compra, infraccion)
    {:reply, infraccion, new_state}
  end

  @doc """
  Callback para un call :listar_infracciones
  """
  @impl true
  def handle_call(:listar_infracciones, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:apply_and_replicate, id, infr}, _from, state) do
    storage = Map.get(state, :storage, %{})
    new_storage = Map.put(storage, id, infr)
    state2 = Map.put(state, :storage, new_storage)

    replica_nodes = get_replica_nodes()
    Logger.info("Infracciones.Server (primario) replica_nodes=#{inspect(replica_nodes)}")

    # Si no hay réplicas, no hacemos RPC (evita bloquear)
    if replica_nodes == [] do
      Logger.info("Infracciones.Server: no hay réplicas detectadas -> aplicando local y devolviendo :ok")
      {:reply, :ok, state2}
    else
      results =
        replica_nodes
        |> Enum.map(fn node ->
          try do
            :rpc.call(node, Libremarket.Infracciones.Server, :replica_apply, [id, infr], 5_000)
          catch
            :exit, reason ->
              Logger.warn("RPC exit al nodo #{inspect(node)} -> #{inspect(reason)}")
              {:badrpc, reason}
            :error, reason ->
              Logger.warn("RPC error al nodo #{inspect(node)} -> #{inspect(reason)}")
              {:badrpc, reason}
          end
        end)

      Logger.info("Infracciones.Server: resultado replicación=#{inspect(results)}")

      if Enum.all?(results, &(&1 == :ok)) do
        {:reply, :ok, state2}
      else
        Logger.warn("Infracciones.Server: replicación incompleta, resultados=#{inspect(results)}")
        {:reply, {:error, :replication_failed, results}, state2}
      end
    end
  end

  @impl true
  def handle_call({:replica_update, id, infr}, _from, state) do
    storage = Map.get(state, :storage, %{})
    new_storage = Map.put(storage, id, %{infraccion: infr, ts: :os.system_time(:millisecond)})
    state2 = Map.put(state, :storage, new_storage)

    Logger.info("Infracciones REPLICA #{inspect(node())}: replica_update id=#{inspect(id)} infraccion=#{inspect(infr)} ts=#{inspect(DateTime.utc_now())}")

    # ACK al primario devolviendo :ok
    {:reply, :ok, state2}
  end

  defp get_replica_nodes() do
    Node.list()
    |> Enum.filter(fn node ->
      node_str = Atom.to_string(node)
      String.starts_with?(node_str, "infracciones")
    end)
  end
end
