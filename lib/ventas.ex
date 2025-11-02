defmodule Libremarket.Ventas do
  @productos [
    "Laptop", "Teclado", "Mouse", "Monitor", "Auricular",
    "Impresora", "Camara", "Tablet", "Router", "Microfono"
  ]

  def productos_iniciales() do
    Enum.into(1..length(@productos), %{}, fn id ->
      name = Enum.at(@productos, id - 1)
      stock = Enum.random(1..10)
      precio = Enum.random(100..2000)
      {id, %{name: name, stock: stock, precio: precio}}
    end)
  end
end

defmodule Libremarket.Ventas.Server do
  use GenServer
  require Logger

  @global_name {:global, __MODULE__}

  def start_link(opts \\ %{}) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    name = if role == "PRINCIPAL", do: @global_name, else: __MODULE__
    GenServer.start_link(__MODULE__, %{role: role}, name: name)
  end

  def get_snapshot() do
    GenServer.call(@global_name, :get_snapshot)
  end

  def listar_stock(pid \\ __MODULE__), do: GenServer.call(@global_name, :listar)

  def reservar(pid \\ __MODULE__, producto_id, cantidad \\ 1),
    do: GenServer.call(@global_name, {:reservar, producto_id, cantidad})

  def liberar(pid \\ __MODULE__, producto_id, cantidad \\ 1),
    do: GenServer.call(@global_name, {:liberar, producto_id, cantidad})

  def apply_and_replicate(id_compra, producto_id, cantidad \\ 1) do
    GenServer.call(@global_name, {:apply_and_replicate, id_compra, producto_id, cantidad}, 10_000)
  catch
    :exit, reason ->
      Logger.error("Ventas.Server.apply_and_replicate: fallo call al servidor global #{inspect(reason)}")
      {:error, reason}
  end

  def replica_apply(producto_id, producto_map) do
    GenServer.call(__MODULE__, {:replica_update, producto_id, producto_map}, 5_000)
  end

  def replica_set_state(snapshot) do
    GenServer.call(__MODULE__, {:replica_set_state, snapshot}, 10_000)
  end

  @impl true
  def init(%{role: role}) do
    products = Libremarket.Ventas.productos_iniciales()

    if role == "PRINCIPAL" do
      Logger.info("Ventas.Server (PRINCIPAL) arrancado.")
    else
      # réplica: intentar obtener snapshot del primario
      Logger.info("Ventas.Server (REPLICA) arrancado. Intentaré pedir snapshot al primario.")

      Process.send_after(self(), :fetch_snapshot, 0)
    end

    {:ok, products}
  end

  @impl true
  def handle_call(:get_snapshot, _from, state) do
    {:reply, state, state}
  end

  # Réplica: intento de pedir snapshot al primario
  @impl true
  def handle_info(:fetch_snapshot, state) do
    service_prefix =
      __MODULE__
      |> Module.split()
      |> Enum.at(1)
      |> String.downcase()

    maybe_primary =
      Node.list()
      |> Enum.filter(fn node ->
        node_str = Atom.to_string(node)
        String.starts_with?(node_str, service_prefix)
      end)
      |> Enum.find(fn node ->
        case :rpc.call(node, System, :get_env, ["ROLE"], 1_000) do
          "PRINCIPAL" -> true
          _ -> false
        end
      end)

    case maybe_primary do
      nil ->
        Logger.info("Ventas.REPLICA: primario no encontrado aún, reintentando en 2s")
        Process.send_after(self(), :fetch_snapshot, 2_000)
        {:noreply, state}

      primary_node ->
        Logger.info("Ventas.REPLICA: pidiendo snapshot al primario #{inspect(primary_node)}")
        case :rpc.call(primary_node, Libremarket.Ventas.Server, :get_snapshot, [], 8_000) do
          {:badrpc, _reason} = bad ->
            Logger.warn("Ventas.REPLICA: fallo al pedir snapshot -> #{inspect(bad)}. Reintentando en 2s")
            Process.send_after(self(), :fetch_snapshot, 2_000)
            {:noreply, state}

          snapshot when is_map(snapshot) ->
            Logger.info("Ventas.REPLICA: snapshot recibido del primario (productos #{map_size(snapshot)}) — aplicando.")
            {:noreply, snapshot}

          other ->
            Logger.warn("Ventas.REPLICA: respuesta inesperada al pedir snapshot: #{inspect(other)} — reintentando en 2s")
            Process.send_after(self(), :fetch_snapshot, 2_000)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_call(:listar, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:reservar, id, cantidad}, _from, state)
      when is_integer(id) and is_integer(cantidad) and cantidad > 0 do
    case Map.fetch(state, id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} when stock < cantidad ->
        {:reply, {:error, :sin_stock}, state}

      {:ok, %{stock: stock} = prod} ->
        new_prod = Map.put(prod, :stock, stock - cantidad)
        new_state = Map.put(state, id, new_prod)
        {:reply, {:ok, new_prod}, new_state}
    end
  end

  @impl true
  def handle_call({:liberar, id, cantidad}, _from, state)
      when is_integer(id) and is_integer(cantidad) and cantidad > 0 do
    case Map.fetch(state, id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} ->
        new_prod = Map.put(prod, :stock, stock + cantidad)
        new_state = Map.put(state, id, new_prod)
        {:reply, {:ok, new_prod}, new_state}
    end
  end

  # Primario: aplicar reserva y replicar
  @impl true
  def handle_call({:apply_and_replicate, _id_compra, producto_id, cantidad}, _from, state) do
    case Map.fetch(state, producto_id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} when stock < cantidad ->
        {:reply, {:error, :sin_stock}, state}

      {:ok, %{stock: stock} = prod} ->
        new_prod = Map.put(prod, :stock, stock - cantidad)
        new_state = Map.put(state, producto_id, new_prod)

        replica_nodes = get_replica_nodes()
        Logger.info("Ventas.Server (primario) replicando reserva a nodos=#{inspect(replica_nodes)}")

        results =
          replica_nodes
          |> Enum.map(fn node ->
            try do
              :rpc.call(node, Libremarket.Ventas.Server, :replica_apply, [producto_id, new_prod], 5_000)
            catch
              :exit, reason ->
                Logger.warn("Ventas.Server RPC exit al nodo #{inspect(node)} -> #{inspect(reason)}")
                {:badrpc, reason}
              :error, reason ->
                Logger.warn("Ventas.Server RPC error al nodo #{inspect(node)} -> #{inspect(reason)}")
                {:badrpc, reason}
            end
          end)

        Logger.debug("Ventas.Server: resultados_replicación=#{inspect(results)}")

        {:reply, {:ok, new_prod}, new_state}
    end
  end

  @impl true
  def handle_call({:replica_update, producto_id, producto_map}, _from, state) do
    new_state = Map.put(state, producto_id, producto_map)
    Logger.info("Ventas REPLICA #{inspect(node())}: actualizado producto #{inspect(producto_id)} stock=#{inspect(producto_map[:stock])}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:replica_set_state, snapshot}, _from, _state) do
    Logger.info("Ventas REPLICA #{inspect(node())}: recibiendo snapshot (#{map_size(snapshot)} productos).")
    {:reply, :ok, snapshot}
  end

  defp get_replica_nodes() do
    service_prefix =
      __MODULE__
      |> Module.split()
      |> Enum.at(1)
      |> String.downcase()

    Node.list()
    |> Enum.filter(fn node ->
      node_str = Atom.to_string(node)
      String.starts_with?(node_str, service_prefix)
    end)
  end
end

defmodule Libremarket.Ventas.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "ventas_queue"
  @out_queue "compras_queue"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    if role == "PRINCIPAL" do
      send(self(), :setup)
      {:ok, Map.put(state, :role, role)}
    else
      Logger.info("Ventas.Consumer: modo REPLICA -> no me suscribo a AMQP.")
      {:ok, Map.put(state, :role, role)}
    end
  end

  def handle_info(:setup, state) do
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @in_queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @in_queue, nil, no_ack: false)
        Logger.info("Ventas Consumer: escuchando #{@in_queue}")
        {:noreply, Map.put(state, :chan, chan)}
      {:error, _} ->
        Logger.error("Ventas Consumer: sin conexión AMQP, reintentando en 1s")
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
      {:ok, %{"id" => id, "producto_id" => producto_id}} ->
        Logger.info("Ventas: petición reserva id=#{id} producto_id=#{producto_id}")

        case Libremarket.Ventas.Server.apply_and_replicate(id, producto_id, 1) do
          {:ok, producto_actualizado} ->
            result = %{
              "id" => id,
              "reservado" => true,
              "producto_id" => producto_id,
              "precio" => producto_actualizado[:precio] || producto_actualizado[:precio],
              "nombre" => producto_actualizado[:name] || producto_actualizado[:name]
            }
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)

          {:error, :sin_stock} ->
            result = %{"id" => id, "reservado" => false, "reason" => "sin_stock"}
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)

          {:error, :producto_invalido} ->
            result = %{"id" => id, "reservado" => false, "reason" => "producto_invalido"}
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)

          other ->
            Logger.warn("Ventas Consumer: respuesta inesperada #{inspect(other)}")
            # publicar fallback / ack para no bloquear la cola
            result = %{"id" => id, "reservado" => false, "reason" => "error_interno"}
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)
        end

      {:error, _} ->
        Logger.error("Ventas: payload inválido #{inspect(payload)}")
        Basic.reject(chan, tag, requeue: false)
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
