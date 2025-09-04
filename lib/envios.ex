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

  # API
  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def registrar(pid \\ __MODULE__, id_compra, producto, tipo_envio, precio_producto) do
    GenServer.call(pid, {:registrar, id_compra, producto, tipo_envio, precio_producto})
  end

  def listar(pid \\ __MODULE__) do
    GenServer.call(pid, :listar)
  end

  # Callbacks
  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:registrar, id_compra, producto, tipo_envio, precio_producto}, _from, state) do
    costo_envio = Libremarket.Envios.costo(tipo_envio)
    total = precio_producto + costo_envio
    envio = %{
      producto: producto,
      tipo_envio: tipo_envio,
      costo_envio: costo_envio,
      precio_producto: precio_producto,
      total: total
    }
    new_state = Map.put(state, id_compra, envio)
    {:reply, {:ok, envio}, new_state}
  end

  @impl true
  def handle_call(:listar, _from, state) do
    {:reply, state, state}
  end
end
