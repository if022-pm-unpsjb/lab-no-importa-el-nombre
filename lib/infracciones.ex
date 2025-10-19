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
  alias AMQP.{Connection, Channel, Queue, Basic}

  @queue "infracciones_queue"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    {:ok, conn} =
      Connection.open("amqp://ypznoogz:nqrvK3KQFu1BkqocK3WTTvQtQfqdWyga@shark.rmq.cloudamqp.com/ypznoogz",
        ssl_options: [verify: :verify_none]
      )

    {:ok, chan} = Channel.open(conn)
    Queue.declare(chan, @queue, durable: false)
    Basic.consume(chan, @queue, nil, no_ack: true)

    Logger.info("Esperando mensajes en #{@queue}...")
    {:ok, %{conn: conn, channel: chan}}
  end

  @impl true
  # Mensaje entrante desde RabbitMQ
  def handle_info({:basic_deliver, payload, _meta}, state) do
    Logger.info("Mensaje recibido en infracciones: #{inspect(payload)}")

    infraccion = Libremarket.Infracciones.detectar_infraccion()
    Logger.info("Resultado infracción: #{inspect(infraccion)}")

    # Actualizamos estado local (si querés guardar historial)
    new_state = Map.update(state, :messages, [%{payload: payload, infraccion: infraccion}], fn msgs ->
      [%{payload: payload, infraccion: infraccion} | msgs]
    end)

    # Reenviamos mensaje a compras
    Libremarket.Infracciones.Server.send_message(infraccion)

    {:noreply, new_state}
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

  @impl true
  def terminate(_reason, %{channel: chan, conn: conn}) do
    Logger.info("Cerrando canal y conexión AMQP del consumer")
    try do
      Channel.close(chan)
    rescue
      _ -> :ok
    end

    try do
      Connection.close(conn)
    rescue
      _ -> :ok
    end

    :ok
  end




end


defmodule Libremarket.Infracciones.Server do
  @moduledoc """
  Infracciones
  """

  use GenServer
  use AMQP

  @global_name {:global, __MODULE__}

  # API del cliente

  @doc """
  Crea un nuevo servidor de Infracciones
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: @global_name)
  end

  def detectar_infraccion(pid \\ __MODULE__, id_compra) do
    GenServer.call(@global_name, {:detectar_infraccion, id_compra})
  end

  def listar_infracciones(pid \\ __MODULE__) do
    GenServer.call(@global_name, :listar_infracciones)
  end

  def send_message(pid \\ __MODULE__, message) do
    {:ok, connection} =
      Connection.open("amqp://ypznoogz:nqrvK3KQFu1BkqocK3WTTvQtQfqdWyga@shark.rmq.cloudamqp.com/ypznoogz",
        ssl_options: [verify: :verify_none]
      )

    {:ok, channel} = Channel.open(connection)

    queue_name = "compras_queue"
    Queue.declare(channel, queue_name, durable: false)

    Basic.publish(channel, "", queue_name, to_string(message))
    IO.puts("Mensaje enviado a #{queue_name}: #{inspect(message)}")

    # Pequeña espera para dar tiempo al broker a procesar (o preferir confirms)
    Process.sleep(500)

    Channel.close(channel)
    Connection.close(connection)

    :ok
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

end
