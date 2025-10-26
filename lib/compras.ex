defmodule Libremarket.Compras do
  alias Libremarket.AMQPHelper

  def comprar(%{id: id_compra, producto_id: producto_id, forma_de_entrega: envio} = compra) do
    if confirmar_compra?() do
      # Marcamos en el Server que estamos esperando reserva
      GenServer.cast({:global, Libremarket.Compras.Server}, {:actualizar_compra, id_compra, %{estado: :pendiente_reserva, producto_id: producto_id, forma_de_entrega: envio}})

      :ok = Libremarket.AMQPHelper.publish_to_queue("ventas_queue", %{"id" => id_compra, "producto_id" => producto_id})

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
    send(self(), :setup)
    {:ok, %{chan: nil}}
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

              GenServer.cast({:global, Libremarket.Compras.Server}, {:actualizar_compra, id, datos})

              {:ok, compra} = Libremarket.Compras.Server.buscar(id)
              tipo_envio = compra[:forma_de_entrega]

              # Ahora sí notificar a los otros módulos (asincrónico)
              Libremarket.AMQPHelper.publish_to_queue("infracciones_queue", %{"id" => id})
              Libremarket.AMQPHelper.publish_to_queue("pagos_queue", %{"id" => id})
              Libremarket.AMQPHelper.publish_to_queue("envios_queue", %{"id" => id, "tipo_envio" => to_string(tipo_envio)})
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
                GenServer.cast({:global, Libremarket.Compras.Server}, {:actualizar_compra, id, normalized})
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

  def start_link(opts \\ %{}), do: GenServer.start_link(__MODULE__, opts, name: @global_name)

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

  #Esta es la funcion que se debe llamar para enviar un mensaje.
  #Esta hardcodeada para este caso en particular. Pero deberia ser algo "generico".
  def send_message(pid \\ __MODULE__, message) do
    {:ok, connection} =
      Connection.open("amqp://ypznoogz:nqrvK3KQFu1BkqocK3WTTvQtQfqdWyga@shark.rmq.cloudamqp.com/ypznoogz",
        ssl_options: [verify: :verify_none]
      )

    {:ok, channel} = Channel.open(connection)

    queue_name = "infracciones_queue"
    Queue.declare(channel, queue_name, durable: false)

    Basic.publish(channel, "", queue_name, to_string(message))
    IO.puts("Mensaje enviado a #{queue_name}: #{inspect(message)}")

    # Pequeña espera para dar tiempo al broker a procesar (o preferir confirms)
    Process.sleep(500)

    Channel.close(channel)
    Connection.close(connection)

    :ok
  end

  @impl true
  def handle_cast({:actualizar_compra, id, nuevos_campos}, state) do
    compra_actual = Map.get(state, id, %{})
    compra_actualizada = Map.merge(compra_actual, nuevos_campos)

    compra_final =
      cond do
        # Si no hay stock, la compra se cancela definitivamente
        compra_actualizada[:estado] == :sin_stock ->
          Map.put(compra_actualizada, :estado, :sin_stock)

        # Si está en proceso de reserva, no publicamos todavía nada
        compra_actualizada[:estado] == :pendiente_reserva ->
          compra_actualizada

        # Si falló infracción o pago
        compra_actualizada[:infraccion] == true ->
          Map.put(compra_actualizada, :estado, :error_infracciones)

        compra_actualizada[:pago] == false ->
          Map.put(compra_actualizada, :estado, :error_pago)

        # Si ya pasó infracciones y pago correctamente
        compra_actualizada[:estado] == :en_revision and
            compra_actualizada[:pago] == true and
            compra_actualizada[:infraccion] == false ->
          Map.put(compra_actualizada, :estado, :finalizado)

        true ->
          compra_actualizada
      end

    Logger.info("Compras Server: actualizando compra #{inspect(id)} con #{inspect(compra_final)}")
    {:noreply, Map.put(state, id, compra_final)}
  end

  def terminate(reason, state) do
    IO.inspect(reason, label: "Terminating GenServer due to")
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

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
    {:noreply, update_in(state, [id_compra], &Map.put(&1, :medio_de_pago, medio))}
  end

  @impl true
  def handle_cast({:seleccionar_forma_de_entrega, id_compra, entrega}, state) do
    {:noreply, update_in(state, [id_compra], &Map.put(&1, :forma_de_entrega, entrega))}
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
end
