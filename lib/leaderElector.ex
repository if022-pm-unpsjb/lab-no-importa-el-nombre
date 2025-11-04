defmodule Libremarket.LeaderElection do
  @moduledoc """
  Election simple y determinista por prefijo de servicio.
  """

  use GenServer
  require Logger

  @default_check_ms 1_000

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts))
  end

  @impl true
  def init(opts) do
    service = Map.fetch!(opts, :service)
    consumer = Map.fetch!(opts, :consumer)
    check_ms = Map.get(opts, :check_ms, @default_check_ms)

    state = %{
      service: service,
      consumer: consumer,
      check_ms: check_ms,
      is_leader: false
    }

    Process.send_after(self(), :check, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, %{service: service, consumer: consumer, check_ms: ms, is_leader: was_leader} = state) do
    service_prefix =
      service
      |> Module.split()
      |> Enum.at(1)
      |> String.downcase()

    nodes = Enum.uniq([node() | Node.list()])

    candidates =
      nodes
      |> Enum.filter(fn n ->
        n_str = Atom.to_string(n)
        String.starts_with?(n_str, service_prefix)
      end)

    cond do
      candidates == [] ->
        Logger.debug("[leader_election #{inspect(service)}] no candidatos")
        Process.send_after(self(), :check, ms)
        {:noreply, state}

      true ->
        leader = Enum.min_by(candidates, &Atom.to_string/1)

        cond do
          leader == node() and not was_leader ->
            # Intentar registrarse globalmente con protección contra races
            pid = Process.whereis(service)

            case :global.whereis_name(service) do
              ^pid when is_pid(pid) ->
                # ya registrado a nuestro pid
                Logger.info("[leader_election #{inspect(service)}] ya registrado globalmente a este pid #{inspect(pid)}")
                notify_consumer(consumer, true)
                Process.send_after(self(), :check, ms)
                {:noreply, %{state | is_leader: true}}

              :undefined ->
                if is_pid(pid) do
                  case :global.register_name(service, pid) do
                    :yes ->
                      Logger.info("[leader_election] registrado globalmente #{inspect(service)} -> #{inspect(pid)}")
                      notify_consumer(consumer, true)
                      Process.send_after(self(), :check, ms)
                      {:noreply, %{state | is_leader: true}}

                    :no ->
                      # Otro nodo ganó la carrera: respetarlo y no marcar como leader
                      owner = :global.whereis_name(service)
                      Logger.warn("[leader_election] register_name returned :no, owner=#{inspect(owner)} — no seré líder.")
                      Process.send_after(self(), :check, ms + 200)
                      {:noreply, %{state | is_leader: false}}

                    other ->
                      Logger.warn("[leader_election] register_name returned #{inspect(other)}")
                      Process.send_after(self(), :check, ms)
                      {:noreply, state}
                  end
                else
                  Logger.warn("[leader_election] no hay pid local para #{inspect(service)} aún, reintentando")
                  Process.send_after(self(), :check, ms)
                  {:noreply, state}
                end

              owner_pid when is_pid(owner_pid) ->
                # Ya registrado en otro pid -> no podemos ser leader
                Logger.warn("[leader_election] nombre global ya registrado en #{inspect(owner_pid)}; no asumir liderazgo.")
                notify_consumer(consumer, false)
                Process.send_after(self(), :check, ms)
                {:noreply, %{state | is_leader: false}}
            end

          leader != node() and was_leader ->
            # Perdimos liderazgo — sólo desempregamos global si nosotros somos los dueños
            pid = Process.whereis(service)
            owner = :global.whereis_name(service)
            if owner == pid and is_pid(pid) do
              try do
                :global.unregister_name(service)
                Logger.info("[leader_election] desregistrado globalmente #{inspect(service)} (perdí liderazgo)")
              rescue
                _ -> Logger.warn("[leader_election] fallo al unregister_name #{inspect(service)}")
              end
            end

            notify_consumer(consumer, false)
            Process.send_after(self(), :check, ms)
            {:noreply, %{state | is_leader: false}}

          true ->
            # sin cambio
            Process.send_after(self(), :check, ms)
            {:noreply, state}
        end
    end
  end

  defp notify_consumer(consumer_mod, true) do
    case Process.whereis(consumer_mod) do
      nil ->
        Logger.warn("[leader_election] no encontre consumer #{inspect(consumer_mod)} para enviar :leader true")
      pid ->
        send(pid, {:leader, true})
    end
  end

  defp notify_consumer(consumer_mod, false) do
    case Process.whereis(consumer_mod) do
      nil ->
        Logger.warn("[leader_election] no encontre consumer #{inspect(consumer_mod)} para enviar :leader false")
      pid ->
        send(pid, {:leader, false})
    end
  end
end
