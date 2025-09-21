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
