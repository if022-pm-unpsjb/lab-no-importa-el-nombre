defmodule Libremarket.AMQPConn do
  use GenServer
  require Logger
  alias AMQP.Connection

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def get_channel(), do: GenServer.call(__MODULE__, :get_channel)

  def init(_) do
    url = System.get_env("CLOUDAMQP_URL")
    state = %{url: url, conn: nil}
    # intentamos conectar en background
    send(self(), :connect)
    {:ok, state}
  end

  def handle_info(:connect, %{url: nil} = state) do
    Logger.warn("AMQP URL no configurada; AMQPConn funcionando en modo inactivo.")
    {:noreply, state}
  end

  def handle_info(:connect, %{url: url} = state) do
    case Connection.open(url, ssl_options: [verify: :verify_none]) do
      {:ok, conn} ->
        Process.monitor(conn.pid)
        Logger.info("AMQP connected.")
        {:noreply, %{state | conn: conn}}
      {:error, reason} ->
        Logger.error("AMQP connect failed: #{inspect(reason)}, retrying in 2s")
        Process.send_after(self(), :connect, 2_000)
        {:noreply, state}
    end
  end

  def handle_call(:get_channel, _from, %{conn: nil} = state) do
    {:reply, {:error, :no_connection}, state}
  end

  def handle_call(:get_channel, _from, %{conn: conn} = state) do
    case AMQP.Channel.open(conn) do
      {:ok, chan} -> {:reply, {:ok, chan}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warn("AMQP connection DOWN. Reconnect scheduled.")
    Process.send_after(self(), :connect, 1000)
    {:noreply, %{state | conn: nil}}
  end
end
