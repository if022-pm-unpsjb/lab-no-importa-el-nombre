defmodule Libremarket.Pagos do

  def autorizar_pago() do
    :rand.uniform(100) < 70
  end

end

defmodule Libremarket.Pagos.Server do
  @moduledoc """
  Pagos
  """

  use GenServer

  # API del cliente

  @doc """
  Crea un nuevo servidor de Pagos
  """
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def autorizar_pago(pid \\ __MODULE__, id_compra) do
    GenServer.call(pid, {:autorizar_pago, id_compra})
  end

  def listar_pagos(pid \\ __MODULE__) do
    GenServer.call(pid, :listar_pagos)
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
    pago = Libremarket.Pagos.autorizar_pago
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
