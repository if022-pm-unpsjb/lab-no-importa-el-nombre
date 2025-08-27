defmodule Libremarket.Infracciones do

  def detectar_infraccion() do
    Enum.random([:true, :false])
  end

end

defmodule Libremarket.Infracciones.Server do
  @moduledoc """
  Infracciones
  """

  use GenServer

  # API del cliente

  @doc """
  Crea un nuevo servidor de Infracciones
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def detectar_infraccion(pid \\ __MODULE__) do
    GenServer.call(pid, :detectar_infraccion)
  end

  # Callbacks

  @doc """
  Inicializa el estado del servidor
  """
  @impl true
  def init(state) do
    {:ok, state}
  end

  @doc """
  Callback para un call :detectar_infraccion
  """
  @impl true
  def handle_call(:detectar_infraccion, _from, state) do
    result = Libremarket.Infracciones.detectar_infraccion()
    {:reply, result, state}
  end

end
