defmodule Libremarket.Ui do

  def comprar(producto, _medio_de_pago, _forma_de_entrega) do
    Libremarket.Compras.Server.comprar(producto)
  end

end
