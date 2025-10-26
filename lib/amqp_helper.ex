defmodule Libremarket.AMQPHelper do
  require Logger
  alias AMQP.Basic

  # publica en una cola (directamente en el default exchange "")
  def publish_to_queue(queue, payload_map) when is_binary(queue) and is_map(payload_map) do
    Logger.info("AMQPHelper: publicando en #{queue} payload=#{inspect(payload_map)}")
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        AMQP.Queue.declare(chan, queue, durable: false)  # segun tu debugging config
        body = Jason.encode!(payload_map)
        Basic.publish(chan, "", queue, body, persistent: true)
        AMQP.Channel.close(chan)
        Logger.info("AMQPHelper: publicado OK en #{queue}")
        :ok
      {:error, reason} ->
        Logger.error("AMQPHelper: No AMQP channel to publish: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Publicar en exchange con routing_key
  def publish_exchange(exchange, routing_key, payload_map) do
    case Libremarket.AMQPConn.get_channel() do
      {:ok, chan} ->
        AMQP.Exchange.declare(chan, exchange, :direct, durable: false)
        body = Jason.encode!(payload_map)
        AMQP.Basic.publish(chan, exchange, routing_key, body, persistent: true)
        AMQP.Channel.close(chan)
        :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
