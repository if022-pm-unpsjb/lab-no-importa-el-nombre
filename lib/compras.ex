defmodule Libremarket.Compras do

  #def comprar(producto_id) when is_integer(producto_id) do
  def comprar(%{id: id_compra, producto_id: producto_id, medio_de_pago: medio, forma_de_entrega: envio} = compra) do
        # Confirmación del cliente (80%)
        if confirmar_compra?() do
          case Libremarket.Ventas.Server.reservar(producto_id) do
            {:error, :producto_invalido} ->
              {:error, %{producto_id: producto_id, estado: :producto_invalido}}

            {:error, :sin_stock} ->
              {:error, %{producto_id: producto_id, estado: :sin_stock}}

            {:ok, producto_actualizado} ->
              #id_compra = :erlang.unique_integer([:positive])
              # Detectar infracciones (30%)
                    case Libremarket.Infracciones.Server.detectar_infraccion(id_compra) do
                      true ->
                            Libremarket.Ventas.Server.liberar(producto_id)
                            compra_actualizada =
                              compra
                              |> Map.put(:nombre, producto_actualizado.name)
                              |> Map.put(:precio, producto_actualizado.precio)
                              |> Map.put(:estado, :infraccion_detectada)

                            {:error, compra_actualizada}

                      false ->
                        # envio = elegir_envio()
                        #{:ok, envio_info} =
                        #  Libremarket.Envios.Server.registrar(id_compra, producto_id, envio, producto_actualizado.precio)
                        # Autorizar pago (70%)
                        case Libremarket.Pagos.Server.autorizar_pago(id_compra) do
                          false ->
                            # Si el pago se rechaza, se libera producto
                            Libremarket.Ventas.Server.liberar(producto_id)
                            compra_actualizada =
                              compra
                                |> Map.put(:nombre, producto_actualizado.name)
                                |> Map.put(:precio, producto_actualizado.precio)
                                |> Map.put(:estado, :pago_rechazado)

                            {:error, compra_actualizada}

                          true ->
                            #Libremarket.Ventas.Server.liberar(producto_id)
                            compra_actualizada =
                              compra
                                |> Map.put(:nombre, producto_actualizado.name)
                                |> Map.put(:precio, producto_actualizado.precio)
                                |> Map.put(:estado, :completada)

                            #total = compra.precio + compra.costo_envio
                            #compra_actualizada =
                              #compra
                                #|> Map.put(:total, total)
                                #|> Map.put(:estado, :completada)
                            {:ok, compra_actualizada}

                        end
                    end
          end
        else
          # Cliente canceló
          # Libremarket.Ventas.Server.liberar(producto_id)

           Libremarket.Ventas.Server.liberar(producto_id)
           compra_actualizada =
           compra
             |> Map.put(:estado, :cancelado)

           {:error, compra_actualizada}

        end

  end

  defp confirmar_compra?(), do: Enum.random(1..100) <= 80
  #defp elegir_envio(), do: if(Enum.random(1..100) <= 70, do: :correo, else: :retiro)
end

defmodule Libremarket.Compras.Server do
  use GenServer

  def start_link(opts \\ %{}), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  #def comprar(pid \\ __MODULE__, producto_id), do: GenServer.call(pid, {:comprar, producto_id})
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

  #@impl true
  #def handle_call({:comprar, producto_id}, _from, state) do
    #result = Libremarket.Compras.comprar(producto_id)
    #{:reply, result, state}
  #end

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

  @impl true
  def handle_cast({:seleccionar_forma_de_entrega, id_compra, entrega}, state) do
    case Map.fetch(state, id_compra) do
    :error ->
      {:noreply, state}

    {:ok, compra} ->
      {:ok, envio_info} =
        Libremarket.Envios.Server.registrar(
          id_compra,
          entrega
          )

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
