defmodule Libremarket.Compras do

  def comprar(producto) do
    Libremarket.Infracciones.Server.detectar_infraccion(producto)
    Libremarket.Pagos.Server.autorizar_pago(producto)
  end

end

defmodule Libremarket.Compras.Server do
  @moduledoc """
  Compras
  """

  use GenServer

  # API del cliente

  @doc """
  Crea un nuevo servidor de Compras
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def comprar(pid \\ __MODULE__, producto) do
    GenServer.call(pid, {:comprar, producto})
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
  Callback para un call :comprar
  """
  @impl true
  def handle_call({:comprar, producto}, _from, state) do
    result = Libremarket.Compras.comprar(producto)
    {:reply, result, state}
  end

end
