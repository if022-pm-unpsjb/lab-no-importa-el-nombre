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
    role = System.get_env("ROLE") || "PRINCIPAL"

    if role == "PRINCIPAL" do
      send(self(), :setup)
      {:ok, %{chan: nil, role: role}}
    else
      Logger.info("Compras.Consumer: modo REPLICA -> no me suscribo a AMQP.")
      {:ok, %{chan: nil, role: role}}
    end
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
                  Libremarket.AMQPHelper.publish_to_queue("envios_queue", %{"id" => id,
                  })
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

  defp normalize_key_value("pago", value), do: %{pago: value}
  defp normalize_key_value("infraccion", value), do: %{infraccion: value}
  defp normalize_key_value("costo", value), do: %{costo_envio: value}
  defp normalize_key_value("costo_envio", value), do: %{costo_envio: value}
  defp normalize_key_value("tipo_envio", value), do: %{tipo_envio: value}

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

defmodule Libremarket.Compras.Server do
  use GenServer
  use AMQP
  require Logger
  alias Libremarket.AMQPHelper
  alias AMQP.{Connection, Channel, Queue, Basic}

  @global_name {:global, __MODULE__}

  def start_link(opts \\ %{}) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    name = if role == "PRINCIPAL", do: @global_name, else: __MODULE__
    GenServer.start_link(__MODULE__, %{role: role}, name: name)
  end

  def comprar(pid \\ __MODULE__, id_compra), do: GenServer.call(@global_name, {:comprar, id_compra})

  def buscar(pid \\ __MODULE__, id_compra), do: GenServer.call(@global_name, {:buscar, id_compra})

  def seleccionar_producto(pid \\ __MODULE__, producto_id) do
    GenServer.call(@global_name, {:seleccionar_producto, producto_id})
  end

  def seleccionar_medio_de_pago(pid \\ __MODULE__, id_compra, medio) do
    GenServer.cast(@global_name, {:seleccionar_medio_de_pago, id_compra, medio})
  end

  def seleccionar_forma_de_entrega(pid \\ __MODULE__, id_compra, entrega) do
    GenServer.cast(@global_name, {:seleccionar_forma_de_entrega, id_compra, entrega})
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

  def replica_apply(id, nuevos_campos) do
    GenServer.call(__MODULE__, {:replica_update, id, nuevos_campos}, 5_000)
  end

  def fetch_local(id_compra) do
    name =
      case System.get_env("ROLE") do
        "PRINCIPAL" -> @global_name
        _ -> __MODULE__
      end

    # Hacemos el call localmente al GenServer con la misma API que ya tienes
    try do
      GenServer.call(name, {:buscar, id_compra})
    catch
      :exit, reason -> {:error, {:exit, reason}}
      :error, reason -> {:error, reason}
    end
  end

  def inspeccionar_compra_en_nodos(id, timeout \\ 5_000) do
    service_prefix = "compras"

    # incluímos el nodo local también en caso de que no figure en Node.list()
    all_nodes = Enum.uniq([node() | Node.list()])

    nodes =
      all_nodes
      |> Enum.filter(fn n ->
        n_str = Atom.to_string(n)
        String.starts_with?(n_str, service_prefix)
      end)

    nodes
    |> Enum.map(fn n ->
      res =
        case :rpc.call(n, Libremarket.Compras.Server, :fetch_local, [id], timeout) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> err
          {:badrpc, reason} -> {:error, {:badrpc, reason}}
          other -> {:error, {:unexpected, other}}
        end

      {n, res}
    end)
  end

  @impl true
  def handle_cast({:actualizar_compra, id, nuevos_campos}, state) do
    {compra_final, nuevo_state} = apply_update(state, id, nuevos_campos)
    Logger.info("Compras Server: actualizando compra #{inspect(id)} con #{inspect(compra_final)}")

    # Si soy primario, replico asincrónicamente (no bloqueo el handle_cast)
    if System.get_env("ROLE") == "PRINCIPAL" do
      Task.start(fn ->
        # replicar sólo los cambios (mantener la semántica actual)
        replica_nodes = get_replica_nodes()
        Enum.each(replica_nodes, fn node ->
          :rpc.call(node, Libremarket.Compras.Server, :replica_apply, [id, nuevos_campos], 5_000)
        end)
      end)
    end

    {:noreply, nuevo_state}
  end

  def terminate(reason, state) do
    IO.inspect(reason, label: "Terminating GenServer due to")
    :ok
  end

  @impl true
  def init(%{role: role}) do
    {:ok, %{}}
  end

  def handle_call({:comprar, id_compra}, _from, state) do
    case Map.fetch(state, id_compra) do
      {:ok, compra} -> {:reply, Libremarket.Compras.comprar(compra), state}
      :error -> {:reply, {:error, :no_encontrada}, state}
    end
  end

  def handle_call({:buscar, id_compra}, _from, state) do
    case Map.fetch(state, id_compra) do
      :error ->
        {:reply, {:error, :compra_no_encontrada}, state}

      {:ok, compra} ->
        {:reply, Map.fetch(state, id_compra), state}
    end
  end

  @impl true
  def handle_cast({:seleccionar_medio_de_pago, id_compra, medio}, state) do
    {compra_final, nuevo_state} = apply_update(state, id_compra, %{medio_de_pago: medio})
    Logger.info("Compras Server: seleccionar_medio_de_pago id=#{inspect(id_compra)} medio=#{inspect(medio)} -> #{inspect(compra_final)}")

    # replico si este nodo es PRIMARIO
    if System.get_env("ROLE") == "PRINCIPAL" do
      Task.start(fn -> replicate_change_to_replicas(id_compra, %{medio_de_pago: medio}) end)
    end

    {:noreply, nuevo_state}
  end

  @impl true
  def handle_cast({:seleccionar_forma_de_entrega, id_compra, entrega}, state) do
    {compra_final, nuevo_state} = apply_update(state, id_compra, %{forma_de_entrega: entrega})
    Logger.info("Compras Server: seleccionar_forma_de_entrega id=#{inspect(id_compra)} entrega=#{inspect(entrega)} -> #{inspect(compra_final)}")

    if System.get_env("ROLE") == "PRINCIPAL" do
      Task.start(fn -> replicate_change_to_replicas(id_compra, %{forma_de_entrega: entrega}) end)
    end

    {:noreply, nuevo_state}
  end

  @impl true
  def handle_call({:seleccionar_producto, producto_id}, _from, state) do
    id_compra = :erlang.unique_integer([:positive])
    compra = %{id: id_compra, producto_id: producto_id, medio_de_pago: nil, forma_de_entrega: nil}
    {:reply, {:ok, id_compra}, Map.put(state, id_compra, compra)}
  end

  defp marcar_finalizada(compra) do
    compra
    |> Map.put("estado", :finalizado)
  end

  defp replicate_change_to_replicas(id, cambios) do
    replica_nodes = get_replica_nodes()

    Enum.each(replica_nodes, fn node ->
      try do
        :rpc.call(node, Libremarket.Compras.Server, :replica_apply, [id, cambios], 5_000)
      catch
        :exit, reason ->
          Logger.warn("Replica async: RPC exit a #{inspect(node)} -> #{inspect(reason)}")
        :error, reason ->
          Logger.warn("Replica async: RPC error a #{inspect(node)} -> #{inspect(reason)}")
      end
    end)
  end

  @impl true
  def handle_call({:apply_and_replicate, id, nuevos_campos}, _from, state) do
    # aplicamos la actualización localmente (misma semántica que handle_cast)
    {compra_final, state2} = apply_update(state, id, nuevos_campos)
    Logger.info("Compras Server (PRINCIPAL): apply_and_replicate id=#{inspect(id)} cambios=#{inspect(nuevos_campos)} -> #{inspect(compra_final)}")

    # replicar sólo si existe alguna réplica
    replica_nodes = get_replica_nodes()
    Logger.info("Compras.Server (primario) replicando a nodos=#{inspect(replica_nodes)}")

    results =
      replica_nodes
      |> Enum.map(fn node ->
        try do
          :rpc.call(node, Libremarket.Compras.Server, :replica_apply, [id, nuevos_campos], 5_000)
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
  def handle_call({:replica_update, id, nuevos_campos}, _from, state) do
    {compra_final, nuevo_state} = apply_update(state, id, nuevos_campos)
    Logger.info("Compras REPLICA #{inspect(node())}: replica_update id=#{inspect(id)} cambios=#{inspect(nuevos_campos)} -> #{inspect(compra_final)}")
    {:reply, :ok, nuevo_state}
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

  defp apply_update(state, id, nuevos_campos) do
    compra_actual = Map.get(state, id, %{})
    compra_actualizada = Map.merge(compra_actual, nuevos_campos)
    compra_actualizada = Map.put_new(compra_actualizada, :id, id)   # <- aseguro id

    compra_final =
      cond do
        compra_actualizada[:estado] == :sin_stock ->
          Map.put(compra_actualizada, :estado, :sin_stock)

        compra_actualizada[:estado] == :pendiente_reserva ->
          compra_actualizada

        compra_actualizada[:infraccion] == true ->
          Map.put(compra_actualizada, :estado, :error_infracciones)

        compra_actualizada[:pago] == false ->
          Map.put(compra_actualizada, :estado, :error_pago)

        compra_actualizada[:estado] == :en_revision and Map.get(compra_actualizada, :pago) == true and Map.get(compra_actualizada, :infraccion) == false ->
          Map.put(compra_actualizada, :estado, :finalizado)

        true ->
          compra_actualizada
      end

    nuevo_state = Map.put(state, id, compra_final)
    {compra_final, nuevo_state}
  end
end
