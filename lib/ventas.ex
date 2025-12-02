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
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # API
  def get_snapshot(), do: GenServer.call(@global_name, :get_snapshot)
  def listar_stock(pid \\ __MODULE__), do: GenServer.call(@global_name, :listar)
  def reservar(pid \\ __MODULE__, producto_id, cantidad \\ 1), do: GenServer.call(@global_name, {:reservar, producto_id, cantidad})
  def liberar(pid \\ __MODULE__, producto_id, cantidad \\ 1), do: GenServer.call(@global_name, {:liberar, producto_id, cantidad})

  def apply_and_replicate(id_compra, producto_id, cantidad \\ 1) do
    GenServer.call(@global_name, {:apply_and_replicate, id_compra, producto_id, cantidad}, 10_000)
  catch
    :exit, reason ->
      Logger.error("Ventas.Server.apply_and_replicate: fallo call al servidor global #{inspect(reason)}")
      {:error, reason}
  end

  # RPCs que usan las réplicas
  def replica_apply(producto_id, producto_map, seq) do
    GenServer.call(__MODULE__, {:replica_update, producto_id, producto_map, seq}, 5_000)
  end

  def replica_set_state(new_storage, new_seq) do
    GenServer.call(__MODULE__, {:replace_state, new_storage, new_seq}, 10_000)
  end

  def get_state(), do: GenServer.call(__MODULE__, :get_state)
  def replace_state(new_storage, new_seq), do: GenServer.call(__MODULE__, {:replace_state, new_storage, new_seq})

  # become_leader_sync pública
  def become_leader_sync(timeout \\ 5_000) do
    try do
      GenServer.call(@global_name, {:become_leader_sync, timeout}, timeout + 1_000)
    catch
      :exit, reason ->
        Logger.warn("Ventas.become_leader_sync: call falló -> #{inspect(reason)}; devolviendo :error")
        {:error, reason}
    end
  end

  ## Callbacks
  @impl true
  def init(_opts) do
    # estado uniforme para todos los servicios
    new_state = %{storage: %{}, seq: 0}
    :net_kernel.monitor_nodes(true, node_type: :visible)
    Process.send_after(self(), :pull_leader_state, 500)
    {:ok, new_state}
  end

  # pública; la llama el Consumer cuando recibe {:leader, true}
  def ensure_seeded() do
    GenServer.call(@global_name, :ensure_seeded)
  end

  @impl true
  def handle_call(:get_snapshot, _from, state) do
    # devolvemos solo el storage (sin role/seq wrapper) para compatibilidad
    {:reply, state.storage, state}
  end

  @impl true
  def handle_call(:listar, _from, state) do
    {:reply, state, state}
  end

  # reservar/liberar mantienen mismo comportamiento pero con state wrapped
  @impl true
  def handle_call({:reservar, id, cantidad}, _from, state) when is_integer(id) and is_integer(cantidad) and cantidad > 0 do
    case Map.fetch(state.storage, id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} when stock < cantidad ->
        {:reply, {:error, :sin_stock}, state}

      {:ok, %{stock: stock} = prod} ->
        new_prod = Map.put(prod, :stock, stock - cantidad)
        # mantener seq/timestamps tal como vienen
        new_storage = Map.put(state.storage, id, new_prod)
        new_state = %{state | storage: new_storage}
        {:reply, {:ok, new_prod}, new_state}
    end
  end

  @impl true
  def handle_call({:liberar, id, cantidad}, _from, state) when is_integer(id) and is_integer(cantidad) and cantidad > 0 do
    case Map.fetch(state.storage, id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} ->
        new_prod = Map.put(prod, :stock, stock + cantidad)
        new_storage = Map.put(state.storage, id, new_prod)
        new_state = %{state | storage: new_storage}
        {:reply, {:ok, new_prod}, new_state}
    end
  end

  # Primario: aplicar reserva y replicar (ahora con seq)
  @impl true
  def handle_call({:apply_and_replicate, _id_compra, producto_id, cantidad}, _from, state) do
    case Map.fetch(state.storage, producto_id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} when stock < cantidad ->
        {:reply, {:error, :sin_stock}, state}

      {:ok, %{stock: stock} = prod} ->
        new_stock = stock - cantidad
        new_seq = state.seq + 1

        new_prod = prod |> Map.put(:stock, new_stock) |> Map.put(:seq, new_seq) |> Map.put(:ts, :os.system_time(:millisecond))
        new_storage = Map.put(state.storage, producto_id, new_prod)
        new_state = %{state | storage: new_storage, seq: new_seq}

        replica_nodes = get_replica_nodes()
        Logger.info("Ventas.Server (primario) seq=#{new_seq} replicando reserva a nodos=#{inspect(replica_nodes)}")

        results =
          replica_nodes
          |> Enum.map(fn node ->
            try do
              :rpc.call(node, Libremarket.Ventas.Server, :replica_apply, [producto_id, new_prod, new_seq], 5_000)
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
  def handle_call({:replica_update, producto_id, producto_map, seq}, _from, state) do
    local_seq = state.seq

    cond do
      seq > local_seq ->
        new_storage = Map.put(state.storage, producto_id, producto_map)
        new_state = %{state | storage: new_storage, seq: seq}
        Logger.info("Ventas REPLICA #{inspect(node())}: replica_update id=#{inspect(producto_id)} seq=#{seq} stock=#{producto_map[:stock]}")
        {:reply, :ok, new_state}

      seq == local_seq ->
        new_storage = Map.put(state.storage, producto_id, producto_map)
        new_state = %{state | storage: new_storage}
        {:reply, :ok, new_state}

      true ->
        Logger.debug("Ventas REPLICA #{inspect(node())}: ignorando replica_update con seq antiguo #{seq} < #{local_seq}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:replace_state, new_storage, new_seq}, _from, state) do
    local_seq = state.seq || 0

    cond do
      not is_integer(new_seq) ->
        Logger.warn("replace_state: seq inválido #{inspect(new_seq)}, ignorando")
        {:reply, {:error, :invalid_seq}, state}

      new_seq > local_seq ->
        new_state = %{state | storage: new_storage, seq: new_seq}
        Logger.info("[#{inspect(node())}] replace_state aplicado seq=#{new_seq}")
        {:reply, :ok, new_state}

      true ->
        Logger.debug("[#{inspect(node())}] replace_state recibido con seq=#{new_seq} <= local_seq=#{local_seq}, ignorando")
        {:reply, :ok, state}
    end
  end

  # become_leader_sync: asincrónico (worker hará RPCs y enviará resultado)
  @impl true
  def handle_call({:become_leader_sync, timeout}, _from, state) do
    caller = self()
    Task.start(fn ->
      result =
        try do
          do_become_leader_sync_worker(timeout)
        catch
          kind, reason ->
            Logger.warn("Ventas.become_leader_sync worker fallo #{inspect({kind, reason})}")
            {:error, :worker_failed}
        end

      send(caller, {:become_leader_sync_result, result})
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:ensure_seeded, _from, state) do
    # si seq == 0 => estado no inicializado
    case state.seq do
      0 ->
        products = Libremarket.Ventas.productos_iniciales()
        # decidir seq inicial; yo recomiendo 1 para que ya haya un seq
        new_state = %{storage: products, seq: 1}
        # push a réplicas para convergencia
        Enum.each(get_replica_nodes(), fn node ->
          spawn(fn ->
            try do
              :rpc.call(node, __MODULE__, :replace_state, [products, 1], 3_000)
            catch
              _, _ -> :ok
            end
          end)
        end)
        {:reply, :ok, new_state}
      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    # devuelve {storage, seq} — coherente con otros servicios
    {:reply, {state.storage, state.seq}, state}
  end

  defp do_become_leader_sync_worker(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    {replicas, _} =
      Enum.reduce_while(1..1000, {get_replica_nodes(), deadline}, fn _i, {replicas_acc, dl} ->
        if replicas_acc == [] and System.monotonic_time(:millisecond) < dl do
          Process.sleep(150)
          {:cont, {get_replica_nodes(), dl}}
        else
          {:halt, {replicas_acc, dl}}
        end
      end)

    if replicas == [] do
      Logger.info("Ventas.become_leader_sync_worker: no réplicas detectadas (timeout).")
      {:no_state}
    else
      states =
        replicas
        |> Enum.map(fn node ->
          try do
            :rpc.call(node, __MODULE__, :get_state, [], 3_000)
          catch
            _, reason ->
              Logger.warn("Ventas.become_leader_sync_worker: rpc fallo a #{inspect(node)} -> #{inspect(reason)}")
              {:badrpc, reason}
          end
        end)
        |> Enum.filter(fn x -> is_tuple(x) and tuple_size(x) == 2 end)

      best =
        states
        |> Enum.map(fn {s, seq} -> {seq, s} end)
        |> Enum.sort_by(fn {seq, _} -> seq end, &>=/2)
        |> List.first()

      case best do
        nil -> {:no_state}
        {best_seq, best_storage} -> {best_storage, best_seq}
      end
    end
  end

  @impl true
  def handle_info(:pull_leader_state, state) do
    case :global.whereis_name(__MODULE__) do
      :undefined ->
        Process.send_after(self(), :pull_leader_state, 1_000)
        {:noreply, state}

      leader_pid when is_pid(leader_pid) ->
        leader_node = node(leader_pid)
        if leader_node != node() do
          case :rpc.call(leader_node, __MODULE__, :get_state, [], 3_000) do
            {remote_storage, remote_seq} when is_integer(remote_seq) ->
              if remote_seq > state.seq do
                Logger.info("Ventas.pull_leader_state: aplicando estado remoto seq=#{remote_seq} desde #{inspect(leader_node)}")
                {:noreply, %{state | storage: remote_storage, seq: remote_seq}}
              else
                {:noreply, state}
              end
            _ ->
              Process.send_after(self(), :pull_leader_state, 1_000)
              {:noreply, state}
          end
        else
          {:noreply, state}
        end
    end
  end

  # nodeup/nodedown handlers (2/3-tupla)
  @impl true
  def handle_info({:nodeup, up_node}, state), do: handle_nodeup(up_node, state)
  @impl true
  def handle_info({:nodeup, up_node, _info}, state), do: handle_nodeup(up_node, state)

  @impl true
  def handle_info({:nodedown, down_node}, state) do
    Logger.info("Ventas.nodedown: #{inspect(down_node)}")
    {:noreply, state}
  end
  @impl true
  def handle_info({:nodedown, down_node, _info}, state) do
    Logger.info("Ventas.nodedown: #{inspect(down_node)} (with info)")
    {:noreply, state}
  end

  defp handle_nodeup(up_node, state) do
    service_prefix = __MODULE__ |> Module.split() |> Enum.at(1) |> String.downcase()
    node_str = Atom.to_string(up_node)

    if String.starts_with?(node_str, service_prefix) and up_node != node() do
      Logger.info("Ventas.nodeup: #{inspect(up_node)} - detected service replica join")

      case :global.whereis_name(__MODULE__) do
        owner_pid when is_pid(owner_pid) and owner_pid == self() ->
          # soy leader: push snapshot solo si tengo estado significativo (seq>0)
          if state.seq > 0 do
            spawn(fn ->
              try do
                :rpc.call(up_node, __MODULE__, :replace_state, [state.storage, state.seq], 5_000)
              catch
                _, reason -> Logger.warn("Ventas.nodeup: push replace_state fallo a #{inspect(up_node)} -> #{inspect(reason)}")
              end
            end)
          else
            Logger.debug("Ventas.nodeup: no push porque seq local es 0 (estado vacío)")
          end

        _ ->
          # no soy leader: intentar pull desde leader en background
          spawn(fn ->
            try do
              case :global.whereis_name(__MODULE__) do
                leader_pid when is_pid(leader_pid) ->
                  leader_node = node(leader_pid)
                  if leader_node != node() do
                    case :rpc.call(leader_node, __MODULE__, :get_state, [], 3_000) do
                      {remote_storage, remote_seq} when is_integer(remote_seq) ->
                        if remote_seq > state.seq do
                          send(self(), {:apply_remote_state, remote_storage, remote_seq})
                        end
                      _ -> :noop
                    end
                  end
                :undefined -> :noop
              end
            catch
              _, _ -> :noop
            end
          end)
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:apply_remote_state, remote_storage, remote_seq}, state) do
    if remote_seq > state.seq do
      Logger.info("Ventas.apply_remote_state: aplicando estado remoto seq=#{remote_seq}")
      {:noreply, %{state | storage: remote_storage, seq: remote_seq}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:become_leader_sync_result, {:no_state}}, state) do
    Logger.info("Ventas.become_leader_sync_result: no se obtuvo estado de réplicas.")
    {:noreply, state}
  end

  @impl true
  def handle_info({:become_leader_sync_result, {best_storage, best_seq}}, state) do
    Logger.info("Ventas.become_leader_sync_result: aplicando estado con seq=#{best_seq}")
    new_state = %{state | storage: best_storage, seq: best_seq}

    # push para convergencia
    Enum.each(get_replica_nodes(), fn node ->
      spawn(fn ->
        try do
          :rpc.call(node, __MODULE__, :replace_state, [best_storage, best_seq], 3_000)
        catch
          _, _ -> :ok
        end
      end)
    end)

    {:noreply, new_state}
  end

  defp get_replica_nodes() do
    service_prefix = __MODULE__ |> Module.split() |> Enum.at(1) |> String.downcase()

    Node.list()
    |> Enum.filter(fn n -> n != node() end)
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

  def init(_state) do
    Logger.info("#{inspect(__MODULE__)} iniciado (esperando liderazgo)")
    {:ok, %{chan: nil, leader?: false}}
  end

  # Cuando LeaderElection comunica que somos leader, intentamos sincronizar y conectarnos a AMQP
  def handle_info({:leader, true}, state) do
    Logger.info("Ventas.Consumer: become LEADER -> sincronizando estado con réplicas")
    # asegurar snapshot inicial si aplica
    case Libremarket.Ventas.Server.become_leader_sync(5_000) do
      :ok -> Logger.info("Ventas.Consumer: sync completado (async)")
      other -> Logger.warn("Ventas.Consumer: sync devolvió #{inspect(other)}")
    end

    # A continuación: asegurar seed (si el seq local es 0 lo crea)
    case Libremarket.Ventas.Server.ensure_seeded() do
      :ok ->
        Logger.info("Ventas.Consumer: seed asegurado (ok)")
      {:error, reason} ->
        Logger.warn("Ventas.Consumer: fallo al seedear -> #{inspect(reason)}")
      other ->
        Logger.debug("Ventas.Consumer: ensure_seeded devolvió #{inspect(other)}")
    end

    :ok = Libremarket.AMQPConn.enable()

    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @in_queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @in_queue, nil, no_ack: false)
        Logger.info("Ventas listening on #{@in_queue}")

        if Map.has_key?(state, :leader_retry_ref), do: Process.cancel_timer(state.leader_retry_ref)

        new_state = state |> Map.put(:chan, chan) |> Map.put(:leader?, true) |> Map.delete(:leader_retry_ref)
        {:noreply, new_state}

      {:error, _reason} ->
        Logger.error("Ventas Consumer: sin conexion AMQP al convertirse en leader, reintentando en 1s")
        ref = Process.send_after(self(), {:leader, true}, 1_000)
        {:noreply, Map.put(state, :leader_retry_ref, ref)}
    end
  end

  def handle_info({:leader, false}, state) do
    Logger.info("Ventas.Consumer: dejar de ser LEADER -> cerrar canal si existe y cancelar retries")
    if ref = Map.get(state, :leader_retry_ref), do: Process.cancel_timer(ref)

    if chan = Map.get(state, :chan) do
      try do
        AMQP.Channel.close(chan)
      rescue
        _ -> :ok
      end
    end

    :ok = Libremarket.AMQPConn.disable()

    new_state = state |> Map.put(:chan, nil) |> Map.put(:leader?, false) |> Map.delete(:leader_retry_ref)
    {:noreply, new_state}
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
              "precio" => producto_actualizado[:precio],
              "nombre" => producto_actualizado[:name]
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
            result = %{"id" => id, "reservado" => false, "reason" => "error_interno"}
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)
        end

      {:error, _} ->
        Logger.error("Ventas: payload inválido #{inspect(payload)}")
        Basic.reject(chan, tag, requeue: false)
    end
  end

  defp process_message(nil, _payload, %{delivery_tag: tag}) do
    # Si por alguna razón no tenemos canal, no podemos ack; solo loggeamos (evitar crash)
    Logger.error("Pagos.Consumer: recibí mensaje pero no tengo canal AMQP para ack (tag=#{inspect(tag)})")
    :ok
  end
end
