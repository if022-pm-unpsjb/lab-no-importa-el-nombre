defmodule Libremarket.Ui do

  def comprar(producto, forma_de_entrega, medio_de_pago) do
  {:ok, id_compra} = Libremarket.Compras.Server.seleccionar_producto(producto)
  Libremarket.Compras.Server.seleccionar_forma_de_entrega(id_compra, forma_de_entrega)
  Libremarket.Compras.Server.seleccionar_medio_de_pago(id_compra, medio_de_pago)
  Libremarket.Compras.Server.comprar(id_compra)
end

end
