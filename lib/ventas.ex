defmodule Libremarket.Ventas do
  @productos ["Laptop", "Teclado", "Mouse", "Monitor", "Auricular", "Impresora", "Camara", "Tablet", "Router", "Microfono"]

  use Application

  def productos_iniciales() do
    Enum.map(@productos, fn prod ->
      {prod, Enum.random(1..10)}
    end)
    |> Map.new()
  end
end

defmodule Libremarket.Ventas.Server do
  use GenServer

  def start_link(opts \\ %{}) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def listar_stock(pid \\ __MODULE__, producto) do
    GenServer.call(pid, :listar)
  end

  def comprar(pid \\ __MODULE__, producto) do
    GenServer.call(pid, {:comprar, producto})
  end

  def liberar(pid \\ __MODULE__, producto) do
    GenServer.call(pid, {:liberar, producto})
  end

  @impl true
  def init(_opts) do
    {:ok, Libremarket.Ventas.productos_iniciales()}
  end

  def handle_call(:listar, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:comprar, producto}, _from, state) do
    case Map.get(state, producto, 0) do
      # Si no hay productos, manda un mensaje de error
      0 -> {:reply, {:error, :sin_stock}, state}
      # Si hay productos, lo descuenta de la lista de productos
      stock ->
        new_state = Map.put(state, producto, stock - 1)
        {:reply, {:ok, producto}, new_state}
    end
  end

  def handle_call({:liberar, producto}, _from, state) do
    case Map.get(state, producto) do
      # Si no existe el producto, manda un mensaje de error
      nil -> {:reply, {:error, :producto_invalido}, state}
      # Si hay productos, lo descuenta de la lista de productos
      stock ->
        new_state = Map.put(state, producto, stock + 1)
        {:reply, {:ok, producto}, new_state}
    end
  end
end
