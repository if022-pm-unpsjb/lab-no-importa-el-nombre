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
  use AMQP

  @global_name {:global, __MODULE__}

  # API del cliente

  @doc """
  Crea un nuevo servidor de Pagos
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: @global_name)
  end

  def autorizar_pago(pid \\ __MODULE__, id_compra) do
    GenServer.call(@global_name, {:autorizar_pago, id_compra})
  end

  def listar_pagos(pid \\ __MODULE__) do
    GenServer.call(@global_name, :listar_pagos)
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
  def handle_call({:autorizar_pago, id_compra}, _from, state) do
    pago = Libremarket.Pagos.autorizar_pago()
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

end

defmodule Libremarket.Pagos.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "pagos_queue"
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

  defp process_message(chan, payload, %{delivery_tag: tag}) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id}} ->

        pago_ok = Libremarket.Pagos.autorizar_pago()
        Logger.info("Pagos -> id=#{id} autorizado? #{inspect(pago_ok)}")

        # publicar resultado a compras_queue (solo id y pago)
        Libremarket.AMQPHelper.publish_to_queue(@out_queue, %{"id" => id, "pago" => pago_ok})
        AMQP.Basic.ack(chan, tag)

      {:error, _} ->
        Logger.error("Pagos: payload mal formado #{inspect(payload)}")
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
