defmodule Libremarket.AMQPConn do
  use GenServer
  require Logger
  alias AMQP.Connection

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def get_channel(), do: GenServer.call(__MODULE__, :get_channel)

  def init(_) do
    role = System.get_env("ROLE") || "PRINCIPAL"

    if role == "REPLICA" do
      Logger.info("AMQPConn: ROLE=REPLICA -> no inicializo conexión AMQP")
      # estado consistente para réplicas (no confundir con un átomo)
      {:ok, %{conn: nil, disabled: true}}
    else
      url = System.get_env("CLOUDAMQP_URL")
      state = %{url: url, conn: nil, disabled: false}
      # intentamos conectar en background
      send(self(), :connect)
      {:ok, state}
    end
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

  # Si estamos deshabilitados (réplica) devolvemos un error concreto
  def handle_call(:get_channel, _from, %{disabled: true} = state) do
    {:reply, {:error, :no_amqp}, state}
  end

  # Caso normal: no hay conexión todavía
  def handle_call(:get_channel, _from, %{conn: nil} = state) do
    {:reply, {:error, :no_connection}, state}
  end

  # Si hay conexión intentamos abrir canal
  def handle_call(:get_channel, _from, %{conn: conn} = state) do
    case AMQP.Channel.open(conn) do
      {:ok, chan} -> {:reply, {:ok, chan}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Manejo de DOWN: desconectar y reintentar (solo si no está disabled)
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{disabled: true} = state) do
    Logger.warn("AMQP connection DOWN but disabled (replica).")
    {:noreply, %{state | conn: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warn("AMQP connection DOWN. Reconnect scheduled.")
    Process.send_after(self(), :connect, 1000)
    {:noreply, %{state | conn: nil}}
  end

  # seguridad: si llega un get inesperado y state no tiene la forma prevista
  def handle_call(:get_channel, _from, state) do
    {:reply, {:error, :no_amqp}, state}
  end
end
