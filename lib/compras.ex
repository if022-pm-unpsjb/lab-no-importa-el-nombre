defmodule Libremarket.Compras do

  def comprar(%{id: id_compra, producto_id: producto_id, medio_de_pago: medio, forma_de_entrega: envio} = compra) do
    if confirmar_compra?() do
      case erpc(:'ventas@ventas', Libremarket.Ventas.Server, :reservar, [producto_id]) do
        {:error, :producto_invalido} ->
          {:error, %{producto_id: producto_id, estado: :producto_invalido}}

        {:error, :sin_stock} ->
          {:error, %{producto_id: producto_id, estado: :sin_stock}}

        {:ok, producto_actualizado} ->
          # Detectar infracciones
          case erpc(:'infracciones@infracciones', Libremarket.Infracciones.Server, :detectar_infraccion, [id_compra]) do
            true ->
              erpc(:'ventas@ventas', Libremarket.Ventas.Server, :liberar, [producto_id])
              {:error, Map.put(compra, :estado, :infraccion_detectada)}

            false ->
              # Autorizar pago
              case erpc(:'pagos@pagos', Libremarket.Pagos.Server, :autorizar_pago, [id_compra]) do
                false ->
                  erpc(:'ventas@ventas', Libremarket.Ventas.Server, :liberar, [producto_id])
                  {:error, Map.put(compra, :estado, :pago_rechazado)}

                true ->
                  compra_actualizada =
                    compra
                    |> Map.put(:nombre, producto_actualizado.name)
                    |> Map.put(:precio, producto_actualizado.precio)
                    |> Map.put(:estado, :completada)

                  {:ok, compra_actualizada}
              end
          end
      end
    else
      erpc(:'ventas@ventas', Libremarket.Ventas.Server, :liberar, [producto_id])
      {:error, Map.put(compra, :estado, :cancelado)}
    end
  end

  defp confirmar_compra?(), do: Enum.random(1..100) <= 80

  # helper
  defp erpc(node, mod, fun, args) do
    Node.connect(node)
    :erpc.call(node, mod, fun, args)
  end
end

defmodule Libremarket.Compras.Server do
  use GenServer

  def start_link(opts \\ %{}), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def comprar(pid \\ __MODULE__, id_compra), do: GenServer.call(pid, {:comprar, id_compra})

  def seleccionar_producto(pid \\ __MODULE__, producto_id) do
    GenServer.call(pid, {:seleccionar_producto, producto_id})
  end

  def seleccionar_medio_de_pago(pid \\ __MODULE__, id_compra, medio) do
    GenServer.cast(pid, {:seleccionar_medio_de_pago, id_compra, medio})
  end

  def seleccionar_forma_de_entrega(pid \\ __MODULE__, id_compra, entrega) do
    GenServer.cast(pid, {:seleccionar_forma_de_entrega, id_compra, entrega})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  def handle_call({:comprar, id_compra}, _from, state) do
    case Map.fetch(state, id_compra) do
      :error ->
        {:reply, {:error, :compra_no_encontrada}, state}

      {:ok, compra} ->
        result = Libremarket.Compras.comprar(compra)
      {:reply, result, state}
    end
  end

  @impl true
  def handle_cast({:seleccionar_medio_de_pago, id_compra, medio}, state) do
    {:noreply, update_in(state, [id_compra], &Map.put(&1, :medio_de_pago, medio))}
  end

  @envios_node :"envios@envios"

  @impl true
  def handle_cast({:seleccionar_forma_de_entrega, id_compra, entrega}, state) do
    case Map.fetch(state, id_compra) do
      :error ->
        {:noreply, state}

      {:ok, compra} ->
        Node.connect(@envios_node)
        {:ok, envio_info} =
          :erpc.call(@envios_node, Libremarket.Envios.Server, :registrar, [id_compra, entrega])

        compra_actualizada =
          compra
          |> Map.put(:forma_de_entrega, envio_info.tipo_envio)
          |> Map.put(:costo_envio, envio_info.costo_envio)

        {:noreply, Map.put(state, id_compra, compra_actualizada)}
    end
  end

  @impl true
  def handle_call({:seleccionar_producto, producto_id}, _from, state) do
    id_compra = :erlang.unique_integer([:positive])
    compra = %{id: id_compra, producto_id: producto_id, medio_de_pago: nil, forma_de_entrega: nil}
    {:reply, {:ok, id_compra}, Map.put(state, id_compra, compra)}
  end
end
