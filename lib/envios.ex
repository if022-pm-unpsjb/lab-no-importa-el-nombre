defmodule Libremarket.Envios do
  @costos %{
    correo: 500,
    retiro: 0
  }

  def costo(tipo_envio) do
    Map.get(@costos, tipo_envio, 0)
  end
end

defmodule Libremarket.Envios.Server do
  use GenServer
  use AMQP

  @global_name {:global, __MODULE__}

  # API
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: @global_name)
  end

  def registrar(pid \\ __MODULE__, id_compra, tipo_envio) do
    GenServer.call(@global_name, {:registrar, id_compra, tipo_envio})
  end

  def listar(pid \\ __MODULE__) do
    GenServer.call(@global_name, :listar)
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

    Channel.close(channel)
    Connection.close(connection)

    :ok
  end

  # Callbacks
  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:registrar, id_compra, tipo_envio}, _from, state) do
    costo_envio = Libremarket.Envios.costo(tipo_envio)

    envio = %{
      id_compra: id_compra,
      tipo_envio: tipo_envio,
      costo_envio: costo_envio
    }

    new_state = Map.put(state, id_compra, envio)
    {:reply, {:ok, envio}, new_state}
  end

  @impl true
  def handle_call(:listar, _from, state) do
    {:reply, state, state}
  end
end

defmodule Libremarket.Envios.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "envios_queue"
  @out_queue "compras_queue"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    send(self(), :setup)
    {:ok, state}
  end

  def handle_info(:setup, state) do
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @in_queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @in_queue, nil, no_ack: false)
        Logger.info("Envios listening on #{@in_queue}")
        {:noreply, Map.put(state, :chan, chan)}
      {:error, _} ->
        Logger.error("Envios Consumer: sin conexion AMQP, reintentando en 1s")
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
      {:ok, %{"id" => id, "tipo_envio" => tipo_envio}} ->
        costo = Libremarket.Envios.costo(String.to_atom(tipo_envio))
        Logger.info("Envios -> id=#{id}, tipo=#{tipo_envio}, costo=#{costo}")

        Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{
          "id" => id,
          "costo_envio" => costo
        })

        AMQP.Basic.ack(chan, tag)

      {:error, _} ->
        Logger.error("Envios: payload mal formado #{inspect(payload)}")
        AMQP.Basic.reject(chan, tag, requeue: false)
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
