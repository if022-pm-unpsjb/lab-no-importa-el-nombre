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
    send(self(), :setup)
    {:ok, state}
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
    Logger.debug("Infracciones: basic_deliver raw payload=#{inspect(payload)} meta=#{inspect(meta)}")
    spawn(fn -> process_message(chan, payload, meta) end)
    {:noreply, state}
  end

  defp process_message(chan, payload, %{delivery_tag: tag}) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id} = data} ->
        Logger.info("Infracciones: procesando id=#{id} payload=#{inspect(data)}")

        infr = Libremarket.Infracciones.detectar_infraccion()

        result = %{"id" => id, "infraccion" => infr}
        Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
        AMQP.Basic.ack(chan, tag)

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
