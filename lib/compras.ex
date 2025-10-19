defmodule Libremarket.Compras do
  use AMQP
  def comprar(%{id: id_compra, producto_id: producto_id, medio_de_pago: medio, forma_de_entrega: envio} = compra) do
    if confirmar_compra?() do
      case Libremarket.Ventas.Server.reservar(producto_id) do
        {:error, :producto_invalido} ->
          {:error, %{producto_id: producto_id, estado: :producto_invalido}}

        {:error, :sin_stock} ->
          {:error, %{producto_id: producto_id, estado: :sin_stock}}

        {:ok, producto_actualizado} ->

          # Detectar infracciones
          #send_message(id_compra, infracciones_queue)
          #send_message(id, pagos_queue)
          case Libremarket.Infracciones.Server.detectar_infraccion(id_compra) do
            true ->
              Libremarket.Ventas.Server.liberar(producto_id)
              compra_actualizada =
                  compra
                  |> Map.put(:nombre, producto_actualizado.name)
                  |> Map.put(:precio, producto_actualizado.precio)
                  |> Map.put(:estado, :infraccion_detectada)

              {:error, compra_actualizada}

            false ->
              # Autorizar pago
              case Libremarket.Pagos.Server.autorizar_pago(id_compra) do
                false ->
                  # Si el pago se rechaza, se libera producto
                  Libremarket.Ventas.Server.liberar(producto_id)
                  compra_actualizada =
                    compra
                      |> Map.put(:nombre, producto_actualizado.name)
                      |> Map.put(:precio, producto_actualizado.precio)
                      |> Map.put(:estado, :pago_rechazado)

                  {:error, compra_actualizada}

                true ->
                  compra_actualizada =
                    compra
                    |> Map.put(:nombre, producto_actualizado.name)
                    |> Map.put(:precio, producto_actualizado.precio)
                    |> Map.put(:estado, :completada)

                  {:ok, compra_actualizada}
              end
          end
      end
    else
      Libremarket.Ventas.Server.liberar(producto_id)
        compra_actualizada =
        compra
        |> Map.put(:estado, :cancelado)

      {:error, compra_actualizada}
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



  # helper
  defp erpc(node, mod, fun, args) do
    Node.connect(node)
    :erpc.call(node, mod, fun, args)
  end
end

defmodule Libremarket.Compras.Consumer do
  use GenServer
  alias AMQP.{Connection, Channel, Queue, Basic}
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{})
  end

  @impl true
  def init(_) do
    {:ok, conn} = Connection.open("amqp://ypznoogz:nqrvK3KQFu1BkqocK3WTTvQtQfqdWyga@shark.rmq.cloudamqp.com/ypznoogz",
      ssl_options: [verify: :verify_none]
    )

    {:ok, chan} = Channel.open(conn)
    Queue.declare(chan, "compras_queue", durable: false)
    Basic.consume(chan, "compras_queue", nil, no_ack: true)

    Logger.info("Esperando mensajes en compras_queue...")
    {:ok, %{channel: chan}}
  end

  @impl true
def handle_info({:basic_deliver, payload, _meta}, state) do
  IO.puts("Mensaje recibido en COMPRAS: #{payload}")

  # Decodificamos el mensaje JSON (asegúrate de que el mensaje venga como JSON)
  case Jason.decode(payload) do
    {:ok, data} ->
      id_compra = data["id"] || data[:id]

      # Buscamos si existe una compra con ese ID
      compras = state[:compras] || %{}
      compra_actual = Map.get(compras, id_compra, %{})

      # Hacemos merge profundo con los nuevos datos
      compra_actualizada = Map.merge(compra_actual, Map.new(data))

      # Actualizamos el estado del servidor
      compras_actualizadas = Map.put(compras, id_compra, compra_actualizada)
      nuevo_state = Map.put(state, :compras, compras_actualizadas)

      IO.puts("Compra actualizada: #{inspect(compra_actualizada)}")
      {:noreply, nuevo_state}

    {:error, _} ->
      IO.puts("Error al decodificar mensaje en COMPRAS.")
      {:noreply, state}
  end
end

  @impl true
  def handle_info({:basic_consume_ok, _info}, state) do
    Logger.info("Suscripción a la cola AMQP confirmada.")
    {:noreply, state}
  end

  @impl true
  def handle_info({:basic_cancel, _info}, state) do
    Logger.warning("Suscripción AMQP cancelada.")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:basic_cancel_ok, _info}, state) do
    Logger.info("Cancelación de suscripción AMQP confirmada.")
    {:noreply, state}
  end
end


defmodule Libremarket.Compras.Server do
  use GenServer
  use AMQP

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
  def terminate(_reason, %{chan: chan, conn: conn}) do
    Channel.close(chan)
    Connection.close(conn)
    :ok
  end


  @impl true
  def init(_opts), do: {:ok, %{}}

  def handle_call({:comprar, id_compra}, _from, state) do
    case Map.fetch(state, id_compra) do
      :error ->
        {:reply, {:error, :compra_no_encontrada}, state}

      {:ok, compra} ->
        result = Libremarket.Compras.comprar(compra)
      {:reply, result, state}
    end
  end

  def handle_call({:buscar, id_compra}, _from, state) do
    case Map.fetch(state, id_compra) do
      :error ->
        {:reply, {:error, :compra_no_encontrada}, state}

      {:ok, compra} ->
        {:reply, {:ok, compra}, state}
    end
  end

  @impl true
  def handle_cast({:seleccionar_medio_de_pago, id_compra, medio}, state) do
    {:noreply, update_in(state, [id_compra], &Map.put(&1, :medio_de_pago, medio))}
  end

  @impl true
  def handle_cast({:seleccionar_forma_de_entrega, id_compra, entrega}, state) do
    case Map.fetch(state, id_compra) do
      :error ->
        {:noreply, state}

      {:ok, compra} ->
        {:ok, envio_info} =
          #Libremarket.Compras.Server.send_message(id_compra, entrega)
          Libremarket.Envios.Server.registrar(
            id_compra,
            entrega
            )

        compra_actualizada =
          compra
          |> Map.put(:forma_de_entrega, envio_info.tipo_envio)
          |> Map.put(:costo_envio, envio_info.costo_envio)

        {:noreply, Map.put(state, id_compra, compra_actualizada)}
    end
  end

  @impl true
  def handle_call({:seleccionar_producto, producto_id}, _from, state) do
    id_compra = :erlang.unique_integer([:positive])
    compra = %{id: id_compra, producto_id: producto_id, medio_de_pago: nil, forma_de_entrega: nil}
    {:reply, {:ok, id_compra}, Map.put(state, id_compra, compra)}
  end
end
