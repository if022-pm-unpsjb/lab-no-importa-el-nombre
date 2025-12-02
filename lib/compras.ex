defmodule Libremarket.Compras do
  alias Libremarket.AMQPHelper

  def comprar(%{id: id_compra, producto_id: producto_id, forma_de_entrega: envio} = compra) do
    if confirmar_compra?() do
      # Marcamos en el Server que estamos esperando reserva
      GenServer.cast({:global, Libremarket.Compras.Server}, {:actualizar_compra, id_compra, %{estado: :pendiente_reserva, producto_id: producto_id, forma_de_entrega: envio}})

      # Publicamos a ventas_queue para que el primario de Ventas procese la reserva
      :ok = AMQPHelper.publish_to_queue("ventas_queue", %{"id" => id_compra, "producto_id" => producto_id})

      {:ok, Map.put(compra, :estado, :pendiente_reserva)}
    else
      {:error, Map.put(compra, :estado, :cancelado)}
    end
  end

  defp confirmar_compra?() do
    # Decidir aleatoriamente si se confirma o no
    if Enum.random(1..100) <= 80 do
      true
    else
      false
    end
  end
end

defmodule Libremarket.Compras.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @queue "compras_queue"

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    Logger.info("Compras.Consumer iniciado (esperando liderazgo)")
    {:ok, state}
  end

  def handle_info(:setup, state) do
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @queue, durable: false)
        {:ok, _ctag} = Basic.consume(chan, @queue, nil, no_ack: false)
        Logger.info("Compras Consumer: escuchando en #{@queue}")
        {:noreply, Map.put(state, :chan, chan)}
      {:error, _} ->
        Logger.error("Compras Consumer: sin conexion AMQP, reintentando")
        Process.send_after(self(), :setup, 1000)
        {:noreply, state}
    end
  end

  # Mensajes AMQP
  def handle_info({:basic_deliver, payload, meta}, %{chan: chan} = state) do
    spawn(fn -> process_delivery(chan, meta.delivery_tag, payload) end)
    {:noreply, state}
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

  # Cuando LeaderElection comunica que somos leader, intentamos conectarnos a AMQP
  def handle_info({:leader, true}, state) do
    Logger.info("Compras.Consumer: become LEADER -> sincronizando estado con réplicas")

    # Hacer sync del Server primario (espera hasta timeout)
    case Libremarket.Compras.Server.become_leader_sync(5_000) do
      :ok ->
        Logger.info("Compras.Consumer: sync disparado (async), procedo a enable AMQP")
      {:error, reason} ->
        Logger.warn("Compras.Consumer: sync falló inmediatamente #{inspect(reason)} — intento enable AMQP")
    end

    # Habilitar AMQP (como antes)
    :ok = Libremarket.AMQPConn.enable()

    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @queue, nil, no_ack: false)
        Logger.info("Compras listening on #{@queue}")

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
        Logger.error("Compras Consumer: sin conexion AMQP al convertirse en leader, reintentando en 1s")
        ref = Process.send_after(self(), {:leader, true}, 1_000)
        {:noreply, Map.put(state, :leader_retry_ref, ref)}
    end
  end

  # Cuando dejamos de ser leader, cerramos canal si existe y marcamos estado
  def handle_info({:leader, false}, state) do
    Logger.info("Compras.Consumer: dejar de ser LEADER -> cerrar canal si existe y cancelar retries")
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

  defp process_delivery(chan, tag, payload) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id} = map} ->
        cond do
          Map.has_key?(map, "reservado") ->
            # Mensaje desde Ventas con resultado de reserva
            if map["reservado"] do
              # actualizar purchase en server con precio/nombre/estado
              datos = %{
                precio: map["precio"],
                producto: map["nombre"],
                estado: :en_revision
              }

              case Libremarket.Compras.Server.apply_and_replicate(id, datos) do
                {:ok, compra_actualizada} ->
                  # Obtener tipo_envio desde estado ahora replicado
                  {:ok, compra} = Libremarket.Compras.Server.buscar(id)
                  tipo_envio = compra[:forma_de_entrega]

                  # Notificar a otros módulos (asincrónico)
                  Libremarket.AMQPHelper.publish_to_queue("infracciones_queue", %{"id" => id})
                  Libremarket.AMQPHelper.publish_to_queue("pagos_queue", %{"id" => id})
                  Libremarket.AMQPHelper.publish_to_queue("envios_queue", %{"id" => id, "tipo_envio" => to_string(tipo_envio)})

                {:error, reason, _compra} ->
                  Logger.warn("Compras Consumer: replicación inicial falló #{inspect(reason)} — procederé igual a publicar.")
                  Libremarket.AMQPHelper.publish_to_queue("infracciones_queue", %{"id" => id})
                  Libremarket.AMQPHelper.publish_to_queue("pagos_queue", %{"id" => id})
                  Libremarket.AMQPHelper.publish_to_queue("envios_queue", %{"id" => id})
              end
            else
              # Reserva fallida -> marcar la compra como cancelada/ sin stock
              motivo = Map.get(map, "reason", "sin_stock")
              GenServer.cast({:global, Libremarket.Compras.Server}, {:actualizar_compra, id, %{estado: :sin_stock, reserva_motivo: motivo}})
            end

          # handling para pago/infraccion/envio, normalizar y reenviar al server
          Map.has_key?(map, "infraccion") or Map.has_key?(map, "pago") or Map.has_key?(map, "costo") or Map.has_key?(map, "costo_envio") ->
            attrs = Map.delete(map, "id")
            case Map.to_list(attrs) do
              [{key_str, value}] ->
                Logger.info("Compras Consumer: recibido #{key_str}=#{inspect(value)} para compra #{id}")
                normalized = normalize_key_value(key_str, value)
                case Libremarket.Compras.Server.apply_and_replicate(id, normalized) do
                  {:ok, _compra} ->
                    :ok
                  {:error, reason, _compra} ->
                    Logger.warn("Compras Consumer: replicación parcial falló #{inspect(reason)}")
                end
              _ ->
                Logger.warn("Compras Consumer: mensaje con atributos inesperados #{inspect(map)}")
            end

          true ->
            Logger.warn("Compras Consumer: mensaje desconocido #{inspect(map)}")
        end

        Basic.ack(chan, tag)

      {:error, _} ->
        Logger.error("Compras Consumer: payload inválido #{inspect(payload)}")
        Basic.reject(chan, tag, requeue: false)
    end
  end

  defp process_message(nil, _payload, %{delivery_tag: tag}) do
    # Si por alguna razón no tenemos canal, no podemos ack; solo loggeamos (evitar crash)
    Logger.error("Compras.Consumer: recibí mensaje pero no tengo canal AMQP para ack (tag=#{inspect(tag)})")
    :ok
  end

  defp normalize_key_value("pago", value), do: %{pago: value}
  defp normalize_key_value("infraccion", value), do: %{infraccion: value}
  defp normalize_key_value("costo", value), do: %{costo_envio: value}
  defp normalize_key_value("costo_envio", value), do: %{costo_envio: value}
  defp normalize_key_value("tipo_envio", value), do: %{tipo_envio: value}
end

defmodule Libremarket.Compras.Server do
  use GenServer
  use AMQP
  require Logger
  alias Libremarket.AMQPHelper
  alias AMQP.{Connection, Channel, Queue, Basic}

  @global_name {:global, __MODULE__}

  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def comprar(pid \\ __MODULE__, id_compra), do: GenServer.call(@global_name, {:comprar, id_compra})

  def buscar(pid \\ __MODULE__, id_compra), do: GenServer.call(@global_name, {:buscar, id_compra})

  def seleccionar_producto(pid \\ __MODULE__, producto_id) do
    GenServer.call(@global_name, {:seleccionar_producto, producto_id})
  end

  def seleccionar_medio_de_pago(pid \\ __MODULE__, id_compra, medio) do
    GenServer.call(@global_name, {:seleccionar_medio_de_pago, id_compra, medio})
  end

  def seleccionar_forma_de_entrega(pid \\ __MODULE__, id_compra, entrega) do
    GenServer.call(@global_name, {:seleccionar_forma_de_entrega, id_compra, entrega})
  end

  def apply_and_replicate(id, nuevos_campos) do
    try do
      GenServer.call(@global_name, {:apply_and_replicate, id, nuevos_campos}, 10_000)
    catch
      :exit, reason ->
        Logger.error("Compras.Server.apply_and_replicate: fallo call al servidor global #{inspect(reason)}")
        {:error, reason}
    end
  end

  def replica_apply(id, nuevos_campos, seq) do
    GenServer.call(__MODULE__, {:replica_update, id, nuevos_campos, seq}, 5_000)
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

  def terminate(reason, state) do
    IO.inspect(reason, label: "Terminating GenServer due to")
    :ok
  end

  # Callbacks

  @impl true
  def init(state) do
    new_state = Map.merge(%{storage: %{}, seq: 0}, state)
    # monitor de nodos para reaccionar a conexiones
    :net_kernel.monitor_nodes(true, node_type: :visible)
    Process.send_after(self(), :pull_leader_state, 500)
    {:ok, new_state}
  end

  @impl true
  def handle_cast({:actualizar_compra, id, nuevos_campos}, state) do
    # Si soy leader (owner global) -> asigno seq, aplico y replico con ese seq
    if :global.whereis_name(__MODULE__) == self() do
      new_seq = (state.seq || 0) + 1
      {compra_final, state2} = apply_update(state, id, nuevos_campos, seq: new_seq)
      # asegurar seq global en state
      state2 = %{state2 | seq: new_seq}

      Logger.info("Compras Server (PRIMARIO): actualizando compra #{inspect(id)} seq=#{new_seq} -> #{inspect(compra_final)}")

      # replicar async pasando el seq correcto
      Task.start(fn ->
        replicate_change_to_replicas(id, nuevos_campos, new_seq)
      end)

      {:noreply, state2}
    else
      # Réplica: aplicar localmente sin tocar seq (aplicar cambios pero no incrementar seq)
      {compra_final, nuevo_state} = apply_update(state, id, nuevos_campos)
      Logger.info("Compras Server (REPLICA): aplicando actualización local id=#{inspect(id)} -> #{inspect(compra_final)}")
      {:noreply, nuevo_state}
    end
  end

  @impl true
  def handle_call({:comprar, id_compra}, _from, state) do
    storage = Map.get(state, :storage, %{})

    case Map.fetch(storage, id_compra) do
      {:ok, compra} ->
        # Nota: la función pública Libremarket.Compras.comprar/1 espera recibir
        # el mapa de compra para ejecutar la lógica de confirmación + publish.
        {:reply, Libremarket.Compras.comprar(compra), state}

      :error ->
        {:reply, {:error, :no_encontrada}, state}
    end
  end

  @impl true
  def handle_call({:buscar, id_compra}, _from, state) do
    storage = Map.get(state, :storage, %{})

    case Map.fetch(storage, id_compra) do
      :error ->
        {:reply, {:error, :compra_no_encontrada}, state}

      {:ok, compra} ->
        {:reply, {:ok, compra}, state}
    end
  end

  @impl true
  def handle_call({:seleccionar_medio_de_pago, id_compra, medio}, _from, state) do
    # Si soy leader: asigno seq, aplico con seq y replico async
    if :global.whereis_name(__MODULE__) == self() do
      new_seq = (state.seq || 0) + 1
      {compra_final, state2} = apply_update(state, id_compra, %{medio_de_pago: medio}, seq: new_seq)
      state2 = %{state2 | seq: new_seq}

      Logger.info("Compras Server (PRINCIPAL): seleccionar_medio_de_pago id=#{inspect(id_compra)} medio=#{inspect(medio)} seq=#{new_seq} -> #{inspect(compra_final)}")

      Task.start(fn ->
        replicate_change_to_replicas(id_compra, %{medio_de_pago: medio}, new_seq)
      end)

      {:reply, {:ok, compra_final}, state2}
    else
      # réplica: aplicar localmente sin modificar seq
      {compra_final, nuevo_state} = apply_update(state, id_compra, %{medio_de_pago: medio})
      Logger.info("Compras Server (REPLICA): aplicar seleccionar_medio_de_pago id=#{inspect(id_compra)} -> #{inspect(compra_final)}")
      {:reply, {:ok, compra_final}, nuevo_state}
    end
  end

  @impl true
  def handle_call({:seleccionar_forma_de_entrega, id_compra, entrega}, _from, state) do
    if :global.whereis_name(__MODULE__) == self() do
      new_seq = (state.seq || 0) + 1
      {compra_final, state2} = apply_update(state, id_compra, %{forma_de_entrega: entrega}, seq: new_seq)
      state2 = %{state2 | seq: new_seq}

      Logger.info("Compras Server (PRINCIPAL): seleccionar_forma_de_entrega id=#{inspect(id_compra)} entrega=#{inspect(entrega)} seq=#{new_seq} -> #{inspect(compra_final)}")

      Task.start(fn ->
        replicate_change_to_replicas(id_compra, %{forma_de_entrega: entrega}, new_seq)
      end)

      {:reply, {:ok, compra_final}, state2}
    else
      {compra_final, nuevo_state} = apply_update(state, id_compra, %{forma_de_entrega: entrega})
      Logger.info("Compras Server (REPLICA): aplicar seleccionar_forma_de_entrega id=#{inspect(id_compra)} -> #{inspect(compra_final)}")
      {:reply, {:ok, compra_final}, nuevo_state}
    end
  end

  @impl true
  def handle_call({:seleccionar_producto, producto_id}, _from, state) do
    id_compra = :erlang.unique_integer([:positive])
    compra = %{id: id_compra, producto_id: producto_id, medio_de_pago: nil, forma_de_entrega: nil}

    storage = Map.get(state, :storage, %{})
    new_storage = Map.put(storage, id_compra, compra)
    new_state = %{state | storage: new_storage}

    {:reply, {:ok, id_compra}, new_state}
  end

  @impl true
  def handle_call({:apply_and_replicate, id, nuevos_campos}, _from, state) do
    new_seq = (state.seq || 0) + 1
    {compra_final, state2} = apply_update(state, id, nuevos_campos, seq: new_seq)

    Logger.info("Compras.Server (PRINCIPAL): apply_and_replicate id=#{inspect(id)} cambios=#{inspect(nuevos_campos)} -> #{inspect(compra_final)}")

    replica_nodes = get_replica_nodes()
    Logger.info("Compras.Server (primario) replicando a nodos=#{inspect(replica_nodes)} seq=#{new_seq}")

    results =
      replica_nodes
      |> Enum.map(fn node ->
        try do
          :rpc.call(node, Libremarket.Compras.Server, :replica_apply, [id, nuevos_campos, new_seq], 5_000)
        catch
          :exit, reason ->
            Logger.warn("RPC exit al nodo #{inspect(node)} -> #{inspect(reason)}")
            {:badrpc, reason}
          :error, reason ->
            Logger.warn("RPC error al nodo #{inspect(node)} -> #{inspect(reason)}")
            {:badrpc, reason}
        end
      end)

    if replica_nodes == [] or Enum.all?(results, &(&1 == :ok)) do
      Logger.info("Compras.Server: replicación OK (resultados=#{inspect(results)})")
      {:reply, {:ok, compra_final}, state2}
    else
      Logger.warn("Compras.Server: replicación incompleta, resultados=#{inspect(results)}")
      {:reply, {:error, :replication_failed, results, compra_final}, state2}
    end
  end

  @impl true
  def handle_call({:replica_update, id, nuevos_campos, seq}, _from, state) do
    local_seq = state.seq || 0

    cond do
      seq > local_seq ->
        # actualización más nueva -> aplicar y avanzar seq
        {compra_final, nuevo_state} = apply_update(state, id, nuevos_campos, seq: seq)
        nuevo_state = %{nuevo_state | seq: seq}
        Logger.info("Compras REPLICA #{inspect(node())}: replica_update id=#{inspect(id)} seq=#{seq} cambios=#{inspect(nuevos_campos)} -> #{inspect(compra_final)}")
        {:reply, :ok, nuevo_state}

      seq == local_seq ->
        # misma versión: aplicar (idempotente) pero no subir seq
        {compra_final, nuevo_state} = apply_update(state, id, nuevos_campos, seq: seq)
        # mantener state.seq igual
        Logger.debug("Compras REPLICA #{inspect(node())}: replica_update id=#{inspect(id)} seq=#{seq} aplicado idempotente")
        {:reply, :ok, nuevo_state}

      true ->
        # actualización vieja -> ignorar
        Logger.debug("Compras REPLICA #{inspect(node())}: ignorando replica_update seq=#{seq} < local_seq=#{local_seq}")
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

  defp apply_update(state, id, nuevos_campos, opts \\ []) do
    # state es el estado del GenServer ({storage, seq} wrapper)
    storage = Map.get(state, :storage, %{})
    compra_actual = Map.get(storage, id, %{})
    compra_actualizada = Map.merge(compra_actual, nuevos_campos)
    compra_actualizada = Map.put_new(compra_actualizada, :id, id)

    # primero aplicamos seq/ts como antes (si nos pasaron seq)
    compra_con_meta =
      compra_actualizada
      |> maybe_put_seq(opts[:seq])
      |> Map.put_new(:ts, :os.system_time(:millisecond))

    # AHORA: comprobar si con los campos actuales hay que finalizar o marcar error
    compra_final = maybe_finalize(compra_con_meta)

    nuevo_storage = Map.put(storage, id, compra_final)
    nuevo_state = %{state | storage: nuevo_storage}
    {compra_final, nuevo_state}
  end

  defp maybe_finalize(compra) when is_map(compra) do
    estado = Map.get(compra, :estado)

    # Sólo intentamos finalizar si estamos en revisión (o en el estado que quieras)
    if estado == :en_revision do
      has_pago? = Map.has_key?(compra, :pago)
      has_infraccion? = Map.has_key?(compra, :infraccion)
      has_precio? = Map.has_key?(compra, :precio)

      # definir cuándo consideramos "completo" — adaptalo si necesitas más campos
      if has_pago? and has_infraccion? and has_precio? do
        pago_ok = compra[:pago]
        infraccion_ok = compra[:infraccion]

        cond do
          pago_ok == true and infraccion_ok == false ->
            compra |> Map.put(:estado, :finalizado)

          pago_ok == false ->
            compra |> Map.put(:estado, :error) |> Map.put_new(:error_motivo, :pago_rechazado)

          infraccion_ok == true ->
            compra |> Map.put(:estado, :error) |> Map.put_new(:error_motivo, :infraccion)

          true ->
            compra
        end
      else
        # Aún faltan datos; no cambiar estado
        compra
      end
    else
      # Si no está en_revision no forzamos nada aquí
      compra
    end
  end

  defp maybe_finalize(other), do: other
  defp maybe_put_seq(map, nil), do: map
  defp maybe_put_seq(map, seq) when is_integer(seq), do: Map.put(map, :seq, seq)

  defp marcar_finalizada(compra) do
    compra
    |> Map.put("estado", :finalizado)
  end

  defp replicate_change_to_replicas(id, cambios, seq) do
    replica_nodes = get_replica_nodes()

    Enum.each(replica_nodes, fn node ->
      try do
        :rpc.call(node, Libremarket.Compras.Server, :replica_apply, [id, cambios, seq], 5_000)
      catch
        :exit, reason ->
          Logger.warn("Replica async: RPC exit a #{inspect(node)} -> #{inspect(reason)}")
        :error, reason ->
          Logger.warn("Replica async: RPC error a #{inspect(node)} -> #{inspect(reason)}")
      end
    end)
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
