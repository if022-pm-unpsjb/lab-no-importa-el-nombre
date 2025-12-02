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
    GenServer.start_link(__MODULE__, %{role: System.get_env("ROLE") || "REPLICA"}, name: __MODULE__)
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

  def replica_apply(id_compra, pago_ok, seq) do
    GenServer.call(__MODULE__, {:replica_update, id_compra, pago_ok, seq}, 5_000)
  end

  # RPC que devuelve el estado completo y seq actual
  def get_state() do
    GenServer.call(__MODULE__, :get_state)
  end

  # RPC para reemplazar/recibir un estado completo desde el líder
  def replace_state(new_storage, new_seq) do
    GenServer.call(__MODULE__, {:replace_state, new_storage, new_seq})
  end

  # API pública para que el Consumer la llame
  def become_leader_sync(timeout \\ 5_000) do
    # Intentamos llamar al servidor global (owner) para pedir sync.
    # Usamos @global_name para que la llamada vaya al owner si existe.
    try do
      GenServer.call(@global_name, {:become_leader_sync, timeout}, timeout + 1_000)
    catch
      :exit, reason ->
        Logger.warn("become_leader_sync: call falló -> #{inspect(reason)}; devolviendo :error")
        {:error, reason}
    end
  end

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(state) do
    new_state = Map.merge(%{storage: %{}, seq: 0}, state)
    # monitor de nodos para reaccionar a conexiones
    :net_kernel.monitor_nodes(true, node_type: :visible)
    Process.send_after(self(), :pull_leader_state, 500)
    {:ok, new_state}
  end

  @doc """
  Callback para un call :autorizar_pago
  """
  @impl true
  def handle_call({:autorizar_pago, id_compra}, _from, state) do
    pago = Libremarket.Pagos.autorizar_pago()
    new_seq = state.seq + 1
    new_storage = Map.put(state.storage, id_compra, %{pago: pago, seq: new_seq, ts: :os.system_time(:millisecond)})
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
    # líder: incrementar seq, aplicar local, replicar con seq
    new_seq = state.seq + 1
    new_storage = Map.put(state.storage, id, %{pago: pago_ok, seq: new_seq, ts: :os.system_time(:millisecond)})
    state2 = %{state | storage: new_storage, seq: new_seq}

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
            :rpc.call(node, Libremarket.Pagos.Server, :replica_apply, [id, pago_ok, new_seq], 5_000)
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
  def handle_call({:replica_update, id, pago_ok, seq}, _from, state) do
    # solo aplicar si seq >= seq local para evitar reordenamientos
    local_seq = state.seq
    cond do
      seq > local_seq ->
        new_storage = Map.put(state.storage, id, %{pago: pago_ok, seq: seq, ts: :os.system_time(:millisecond)})
        new_state = %{state | storage: new_storage, seq: seq}
        Logger.info("Pagos REPLICA #{inspect(node())}: replica_update id=#{inspect(id)} seq=#{seq} pago=#{inspect(pago_ok)}")
        {:reply, :ok, new_state}

      seq == local_seq ->
        # aplicar igualmente (idempotente)
        new_storage = Map.put(state.storage, id, %{pago: pago_ok, seq: seq, ts: :os.system_time(:millisecond)})
        new_state = %{state | storage: new_storage}
        {:reply, :ok, new_state}

      true ->
        # actualización vieja -> ignorar
        Logger.debug("Pagos REPLICA #{inspect(node())}: ignorando replica_update con seq antiguo #{seq} < #{local_seq}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    # devolvemos una copia segura
    {:reply, {state.storage, state.seq}, state}
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

  ## función que el consumer/leader llamará al convertirse en leader para sincronizar
  @impl true
  def handle_call({:become_leader_sync, timeout}, _from, state) do
    # Lanzamos la tarea en background para hacer el trabajo pesado (RPCs).
    caller = self()
    Task.start(fn ->
      result =
        try do
          # llamamos a la función local que contiene la lógica de búsqueda/merge
          do_become_leader_sync_worker(timeout)
        catch
          kind, reason ->
            Logger.warn("become_leader_sync worker fallo #{inspect({kind, reason})}")
            {:error, :worker_failed}
        end

      # enviamos el resultado al GenServer para que aplique estado (no bloquear acá)
      send(caller, {:become_leader_sync_result, result})
    end)

    # respondemos al caller inmediatamente (no bloquear)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:pull_leader_state, state) do
    case :global.whereis_name(__MODULE__) do
      :undefined ->
        # no hay leader registrado aún — reintentar dentro de un rato (pero sin bloquear)
        Process.send_after(self(), :pull_leader_state, 1_000)
        {:noreply, state}

      leader_pid when is_pid(leader_pid) ->
        leader_node = node(leader_pid)
        # si el leader está en otro nodo consultamos su estado
        if leader_node != node() do
          case :rpc.call(leader_node, __MODULE__, :get_state, [], 3_000) do
            {remote_storage, remote_seq} when is_integer(remote_seq) ->
              # aplicamos solo si remote_seq > local seq
              if remote_seq > state.seq do
                Logger.info("pull_leader_state: aplicando estado remoto seq=#{remote_seq} desde #{inspect(leader_node)}")
                new_state = %{state | storage: remote_storage, seq: remote_seq}
                {:noreply, new_state}
              else
                {:noreply, state}
              end
            _ ->
              # no obtuvimos estado válido; reintentar luego
              Process.send_after(self(), :pull_leader_state, 1_000)
              {:noreply, state}
          end
        else
          # el owner global está en este mismo nodo => ya somos owner o no hay que pedir
          {:noreply, state}
        end
    end
  end

  # nodeup con 2-tupla y 3-tupla (ya tenías 2-tupla)
  @impl true
  def handle_info({:nodeup, up_node}, state), do: handle_nodeup(up_node, state)

  @impl true
  def handle_info({:nodeup, up_node, _info}, state), do: handle_nodeup(up_node, state)

  # nodedown con 2-tupla y 3-tupla
  @impl true
  def handle_info({:nodedown, down_node}, state) do
    Logger.info("nodedown: #{inspect(down_node)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, down_node, _info}, state) do
    Logger.info("nodedown: #{inspect(down_node)} (with info)")
    {:noreply, state}
  end

  # handler para aplicar estado remoto enviado desde background
  @impl true
  def handle_info({:apply_remote_state, remote_storage, remote_seq}, state) do
    if remote_seq > state.seq do
      Logger.info("apply_remote_state: aplicando estado remoto seq=#{remote_seq}")
      new_state = %{state | storage: remote_storage, seq: remote_seq}
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:become_leader_sync_result, {:no_state}}, state) do
    Logger.info("become_leader_sync_result: no se obtuvo estado de réplicas.")
    {:noreply, state}
  end

  @impl true
  def handle_info({:become_leader_sync_result, {best_storage, best_seq}}, state) do
    Logger.info("become_leader_sync_result: aplicando estado con seq=#{best_seq}")
    new_state = %{state | storage: best_storage, seq: best_seq}
    # opcional: push a réplicas para convergencia en background
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
      |> Enum.filter(fn n -> n != node() end) # excluir self

    Logger.info("[#{service_prefix}] Réplicas detectadas: #{inspect(replicas)}")
    replicas
  end

  defp do_become_leader_sync_worker(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    # reutilizamos get_replica_nodes() para detectar réplicas
    replica_nodes = get_replica_nodes()

    # reintentar hasta timeout buscando réplicas
    {replicas, _} =
      Enum.reduce_while(1..1000, {replica_nodes, deadline}, fn _i, {replicas_acc, dl} ->
        if replicas_acc == [] and System.monotonic_time(:millisecond) < dl do
          Process.sleep(150)
          {:cont, {get_replica_nodes(), dl}}
        else
          {:halt, {replicas_acc, dl}}
        end
      end)

    if replicas == [] do
      Logger.info("become_leader_sync_worker: no réplicas detectadas (timeout).")
      {:no_state}
    else
      states =
        replicas
        |> Enum.map(fn node ->
          try do
            :rpc.call(node, __MODULE__, :get_state, [], 3_000)
          catch
            _, reason ->
              Logger.warn("become_leader_sync_worker: rpc fallo a #{inspect(node)} -> #{inspect(reason)}")
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

  defp handle_nodeup(up_node, state) do
    service_prefix =
      __MODULE__
      |> Module.split()
      |> Enum.at(1)
      |> String.downcase()

    node_str = Atom.to_string(up_node)

    if String.starts_with?(node_str, service_prefix) and up_node != node() do
      Logger.info("nodeup: #{inspect(up_node)} - detected service replica join")

      case :global.whereis_name(__MODULE__) do
        owner_pid when is_pid(owner_pid) and owner_pid == self() ->
          if state.seq > 0 do
            spawn(fn ->
              try do
                :rpc.call(up_node, __MODULE__, :replace_state, [state.storage, state.seq], 5_000)
              catch
                _, reason -> Logger.warn("nodeup: push replace_state fallo a #{inspect(up_node)} -> #{inspect(reason)}")
              end
            end)
          else
            Logger.debug("nodeup: no push porque seq local es 0 (estado vacío)")
          end

        _ ->
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
end

defmodule Libremarket.Pagos.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "pagos_queue"
  @out_queue "compras_queue"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    Logger.info("Pagos.Consumer iniciado (esperando liderazgo)")
    {:ok, state}
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

  # Cuando LeaderElection comunica que somos leader, intentamos conectarnos a AMQP
  def handle_info({:leader, true}, state) do
    Logger.info("Pagos.Consumer: become LEADER -> sincronizando estado con réplicas")

    # Hacer sync del Server primario (espera hasta timeout)
    case Libremarket.Pagos.Server.become_leader_sync(5_000) do
      :ok ->
        Logger.info("Pagos.Consumer: sync disparado (async), procedo a enable AMQP")
      {:error, reason} ->
        Logger.warn("Pagos.Consumer: sync falló inmediatamente #{inspect(reason)} — intento enable AMQP")
    end

    # Habilitar AMQP (como antes)
    :ok = Libremarket.AMQPConn.enable()

    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @in_queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @in_queue, nil, no_ack: false)
        Logger.info("Pagos listening on #{@in_queue}")

        if Map.has_key?(state, :leader_retry_ref) do
          Process.cancel_timer(state.leader_retry_ref)
        end

        new_state =
          state
          |> Map.put(:chan, chan)
          |> Map.put(:leader?, true)
          |> Map.delete(:leader_retry_ref)

        {:noreply, new_state}

      {:error, _reason} ->
        Logger.error("Pagos Consumer: sin conexion AMQP al convertirse en leader, reintentando en 1s")
        ref = Process.send_after(self(), {:leader, true}, 1_000)
        {:noreply, Map.put(state, :leader_retry_ref, ref)}
    end
  end

  # Cuando dejamos de ser leader, cerramos canal si existe y marcamos estado
  def handle_info({:leader, false}, state) do
    Logger.info("Pagos.Consumer: dejar de ser LEADER -> cerrar canal si existe y cancelar retries")
    # cancelar retry si existe
    if ref = Map.get(state, :leader_retry_ref), do: Process.cancel_timer(ref)

    # cerrar canal si existe
    if chan = Map.get(state, :chan) do
      try do
        AMQP.Channel.close(chan)
      rescue
        _ -> :ok
      end
    end

    :ok = Libremarket.AMQPConn.disable()

    new_state =
      state
      |> Map.put(:chan, nil)
      |> Map.put(:leader?, false)
      |> Map.delete(:leader_retry_ref)

    {:noreply, new_state}
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

  defp process_message(nil, _payload, %{delivery_tag: tag}) do
    # Si por alguna razón no tenemos canal, no podemos ack; solo loggeamos (evitar crash)
    Logger.error("Pagos.Consumer: recibí mensaje pero no tengo canal AMQP para ack (tag=#{inspect(tag)})")
    :ok
  end
end
