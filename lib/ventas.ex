defmodule Libremarket.Ventas do
  @productos [
    "Laptop", "Teclado", "Mouse", "Monitor", "Auricular",
    "Impresora", "Camara", "Tablet", "Router", "Microfono"
  ]

  def productos_iniciales() do
    Enum.into(1..length(@productos), %{}, fn id ->
      name = Enum.at(@productos, id - 1)
      stock = Enum.random(1..10)
      precio = Enum.random(100..2000)
      {id, %{name: name, stock: stock, precio: precio}}
    end)
  end
end

defmodule Libremarket.Ventas.Server do
  use GenServer

  # API
  def start_link(opts \\ %{}), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def listar_stock(pid \\ __MODULE__), do: GenServer.call(pid, :listar)

  def reservar(pid \\ __MODULE__, producto_id, cantidad \\ 1),
    do: GenServer.call(pid, {:reservar, producto_id, cantidad})

  def liberar(pid \\ __MODULE__, producto_id, cantidad \\ 1),
    do: GenServer.call(pid, {:liberar, producto_id, cantidad})

  def listar(pid \\ __MODULE__),
    do: GenServer.call(pid, :listar)

  # Callbacks
  @impl true
  def init(_opts) do
    {:ok, Libremarket.Ventas.productos_iniciales()}
  end

  @impl true
  def handle_call(:listar, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:reservar, id, cantidad}, _from, state)
      when is_integer(id) and is_integer(cantidad) and cantidad > 0 do
    case Map.fetch(state, id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} when stock < cantidad ->
        {:reply, {:error, :sin_stock}, state}

      {:ok, %{stock: stock} = prod} ->
        new_prod = Map.put(prod, :stock, stock - cantidad)
        new_state = Map.put(state, id, new_prod)
        {:reply, {:ok, new_prod}, new_state}
    end
  end

  @impl true
  def handle_call({:liberar, id, cantidad}, _from, state)
      when is_integer(id) and is_integer(cantidad) and cantidad > 0 do
    case Map.fetch(state, id) do
      :error ->
        {:reply, {:error, :producto_invalido}, state}

      {:ok, %{stock: stock} = prod} ->
        new_prod = Map.put(prod, :stock, stock + cantidad)
        new_state = Map.put(state, id, new_prod)
        {:reply, {:ok, new_prod}, new_state}
    end
  end
end
