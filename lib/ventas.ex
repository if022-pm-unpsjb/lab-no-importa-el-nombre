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

  @global_name {:global, __MODULE__}

  # API
  def start_link(opts \\ %{}), do: GenServer.start_link(__MODULE__, opts, name: @global_name)

  def listar_stock(pid \\ __MODULE__), do: GenServer.call(@global_name, :listar)

  def reservar(pid \\ __MODULE__, producto_id, cantidad \\ 1),
    do: GenServer.call(@global_name, {:reservar, producto_id, cantidad})

  def liberar(pid \\ __MODULE__, producto_id, cantidad \\ 1),
    do: GenServer.call(@global_name, {:liberar, producto_id, cantidad})

  def listar(pid \\ __MODULE__),
    do: GenServer.call(@global_name, :listar)

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

defmodule Libremarket.Ventas.Consumer do
  use GenServer
  require Logger
  alias AMQP.{Queue, Basic}

  @in_queue "ventas_queue"
  @out_queue "compras_queue"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    role = System.get_env("ROLE") || "PRINCIPAL"
    if role == "PRINCIPAL" do
      send(self(), :setup)
      {:ok, Map.put(state, :role, role)}
    else
      Logger.info("Ventas.Consumer: modo REPLICA -> no me suscribo a AMQP.")
      {:ok, Map.put(state, :role, role)}
    end
  end

  def handle_info(:setup, state) do
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        Queue.declare(chan, @in_queue, durable: false)
        {:ok, _ct} = Basic.consume(chan, @in_queue, nil, no_ack: false)
        Logger.info("Ventas Consumer: escuchando #{@in_queue}")
        {:noreply, Map.put(state, :chan, chan)}
      {:error, _} ->
        Logger.error("Ventas Consumer: sin conexión AMQP, reintentando en 1s")
        Process.send_after(self(), :setup, 1_000)
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, payload, meta}, %{chan: chan} = state) do
    spawn(fn -> process_message(chan, payload, meta) end)
    {:noreply, state}
  end

  defp process_message(chan, payload, %{delivery_tag: tag}) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id, "producto_id" => producto_id} = _data} ->
        Logger.info("Ventas: petición reserva id=#{id} producto_id=#{producto_id}")

        case Libremarket.Ventas.Server.reservar(producto_id) do
          {:ok, producto_actualizado} ->
            result = %{
              "id" => id,
              "reservado" => true,
              "producto_id" => producto_id,
              "precio" => producto_actualizado.precio,
              "nombre" => producto_actualizado.name
            }

            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)

          {:error, :sin_stock} ->
            result = %{"id" => id, "reservado" => false, "reason" => "sin_stock"}
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)

          {:error, :producto_invalido} ->
            result = %{"id" => id, "reservado" => false, "reason" => "producto_invalido"}
            Libremarket.AMQPHelper.publish_to_queue(@out_queue, result)
            Basic.ack(chan, tag)
        end

      {:error, _} ->
        Logger.error("Ventas: payload inválido #{inspect(payload)}")
        Basic.reject(chan, tag, requeue: false)
    end
  end

  def handle_info({:basic_consume_ok, _}, state) do
    Logger.info("Suscripción AMQP confirmada correctamente.")
    {:noreply, state}
  end

  def handle_info({:basic_cancel, info}, state) do
    Logger.warning("Suscripción AMQP cancelada: #{inspect(info)}")
    {:stop, :normal, state}
  end

  def handle_info({:basic_cancel_ok, _}, state) do
    Logger.info("Cancelación AMQP confirmada.")
    {:noreply, state}
  end
end
