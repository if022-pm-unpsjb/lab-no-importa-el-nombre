defmodule Libremarket.Router do
  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  @idCompra "id"

  get "/ping" do
    send_resp(conn, 200, Jason.encode!(%{pong: true}))
  end

  get "/compras/:id" do
    id = String.to_integer(id)

    result = Libremarket.Compras.Server.buscar(id)

    {status, compra} = result
    payload = %{status: status, compra: compra}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  #Esto confirma la compra
  get "/compras/confirmarCompra/:id" do
    id = String.to_integer(id)
    result = Libremarket.Compras.Server.comprar(id)
    {status, compra} = result
    payload = %{status: status, compra: compra}
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  #Esto es para actualizar la compra con su medio de Entrega
  put "/compras/medioEntrega/:id" do
    id_compra = String.to_integer(id)
    body = conn.body_params
    Libremarket.Compras.Server.seleccionar_forma_de_entrega(id_compra, body["forma_de_entrega"])
    {status, compra} = Libremarket.Compras.Server.buscar(id_compra)
    payload = %{status: status, compra: compra}
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  #Esto es para actualizar la compra con su medio de Pago
  put "/compras/medioPago/:id" do
    id_compra = String.to_integer(id)
    body = conn.body_params
    Libremarket.Compras.Server.seleccionar_medio_de_pago(id_compra, body["medio_de_pago"])
    {status, compra} = Libremarket.Compras.Server.buscar(id_compra)
    payload = %{status: status, compra: compra}
    conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(payload))
  end

  #Esto es para crear una compra nueva y agregarle un producto
  post "/compras" do
    body = conn.body_params
    producto_id = body["producto_id"]
    {status, id_compra} = Libremarket.Compras.Server.seleccionar_producto(producto_id)
    {status, compra} = Libremarket.Compras.Server.buscar(id_compra)
    payload = %{status: status, compra: compra}
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end
end
