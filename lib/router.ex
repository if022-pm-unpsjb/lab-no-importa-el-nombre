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

  put "/compras/:id" do

    id_compra = String.to_integer(id)
    body = conn.body_params

    if body["medio_de_pago"] do
      Libremarket.Compras.Server.seleccionar_medio_de_pago(id_compra, body["medio_de_pago"])
    end

    if body["forma_de_entrega"] do
      Libremarket.Compras.Server.seleccionar_forma_de_entrega(id_compra, body["forma_de_entrega"])
    end

    result = Libremarket.Compras.Server.buscar(id_compra)
    {status, compra} = result
    payload = %{status: status, compra: compra}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  post "/compras" do
    body = conn.body_params
    producto_id = body["producto_id"]
    forma = body["forma_de_entrega"]
    medio = body["medio_de_pago"]

    {:ok, id_compra} = Libremarket.Compras.Server.seleccionar_producto(producto_id)
    Libremarket.Compras.Server.seleccionar_forma_de_entrega(id_compra, forma)
    Libremarket.Compras.Server.seleccionar_medio_de_pago(id_compra, medio)

    result = Libremarket.Compras.Server.comprar(id_compra)

    {status, compra} = result
    payload = %{status: status, compra: compra}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end
end
