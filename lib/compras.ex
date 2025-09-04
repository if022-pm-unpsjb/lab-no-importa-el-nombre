defmodule Libremarket.Compras do

  @doc """
  Modificar el metodo para ingresar el numero del pedido compra
  """
  def comprar(producto) do
    case Libremarket.Ventas.Server.comprar(producto) do
      {:error, :sin_stock} ->
        {:error, :sin_stock}

      {:ok, producto} ->
        if confirmar_compra?() do
          id_compra = :erlang.unique_integer([:positive])
          case Libremarket.Pagos.Server.autorizar_pago(id_compra) do
            true ->
              envio = elegir_envio()
              {:ok, %{id: id_compra, producto: producto, envio: envio}}

            false ->
              # Pago rechazado, entonces libera producto
              Libremarket.Ventas.Server.liberar(producto)
              {:error, :pago_rechazado}
          end
        else
          # Cliente canceló, entonces se libera producto
          Libremarket.Ventas.Server.liberar(producto)
          {:cancelada, producto}
        end
    end
  end

  defp confirmar_compra?() do
    Enum.random(1..100) <= 80
  end

  defp elegir_envio() do
    if Enum.random(1..100) <= 70 do
      :correo
    else
      :retiro
    end
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

  def comprar(pid \\ __MODULE__) do
    GenServer.call(pid, :comprar)
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
  def handle_call(:comprar, _from, state) do
    result = Libremarket.Compras.comprar
    {:reply, result, state}
  end
end
