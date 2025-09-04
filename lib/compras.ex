defmodule Libremarket.Compras do

  def comprar(producto_id) when is_integer(producto_id) do
    case Libremarket.Ventas.Server.comprar(producto_id) do
      {:error, :producto_invalido} ->
        {:error, :producto_invalido}

      {:error, :sin_stock} ->
        {:error, :sin_stock}

      {:ok, producto_actualizado} ->
        # Confirmación del cliente (80%)
        if confirmar_compra?() do
          id_compra = :erlang.unique_integer([:positive])

          # Autorizar pago (70%)
          case Libremarket.Pagos.Server.autorizar_pago(id_compra) do
            false ->
              # Pago rechazado → liberar producto
              Libremarket.Ventas.Server.liberar(producto_id)
              {:error, :pago_rechazado}

            true ->
              # Detectar infracciones (30%)
              case Libremarket.Infracciones.Server.detectar_infraccion(id_compra) do
                true ->
                  Libremarket.Ventas.Server.liberar(producto_id)
                  {:error, :infraccion_detectada}

                false ->
                  envio = elegir_envio()
                  {:ok, envio_info} =
                    Libremarket.Envios.Server.registrar(id_compra, producto_id, envio, producto_actualizado.precio)

                  total = producto_actualizado.precio + envio_info.costo_envio

                  {:ok,
                   %{
                     id: id_compra,
                     producto_id: producto_id,
                     nombre: producto_actualizado.name,
                     precio: producto_actualizado.precio,
                     envio: envio,
                     costo_envio: envio_info.costo_envio,
                     total: total
                   }}
              end
          end
        else
          # Cliente canceló
          Libremarket.Ventas.Server.liberar(producto_id)
          {:cancelada, producto_id}
        end
    end
  end

  defp confirmar_compra?(), do: Enum.random(1..100) <= 80
  defp elegir_envio(), do: if(Enum.random(1..100) <= 70, do: :correo, else: :retiro)
end

defmodule Libremarket.Compras.Server do
  use GenServer

  def start_link(opts \\ %{}), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def comprar(pid \\ __MODULE__, producto_id), do: GenServer.call(pid, {:comprar, producto_id})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:comprar, producto_id}, _from, state) do
    result = Libremarket.Compras.comprar(producto_id)
    {:reply, result, state}
  end
end
