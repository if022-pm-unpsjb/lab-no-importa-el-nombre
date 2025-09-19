defmodule Libremarket.Ui do
  @compras_node :"compras@compras"

  def comprar(producto, forma_de_entrega, medio_de_pago) do
    Node.connect(@compras_node)

    {:ok, id_compra} =
      :erpc.call(@compras_node, Libremarket.Compras.Server, :seleccionar_producto, [producto])

    :erpc.call(@compras_node, Libremarket.Compras.Server, :seleccionar_forma_de_entrega, [id_compra, forma_de_entrega])
    :erpc.call(@compras_node, Libremarket.Compras.Server, :seleccionar_medio_de_pago, [id_compra, medio_de_pago])

    :erpc.call(@compras_node, Libremarket.Compras.Server, :comprar, [id_compra])
  end
end
