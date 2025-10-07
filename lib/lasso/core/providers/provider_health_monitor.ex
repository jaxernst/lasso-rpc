defmodule Lasso.RPC.ProviderHealthMonitor do
  @moduledoc "Per-chain health monitor; performs periodic health checks and emits typed events."

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.{HttpClient, CircuitBreaker, ProviderPool}

  @default_interval 30_000
  @default_timeout 5_000

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:provider_health_monitor, chain}}}

  @impl true
  def init(chain) do
    # Delay first tick to allow provider supervisors to start breakers
    Process.send_after(self(), :tick, @default_interval)
    {:ok, %{chain: chain, last: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    case ConfigStore.get_chain(state.chain) do
      {:ok, cfg} ->
        Enum.each(cfg.providers, fn p ->
          check_provider(state.chain, p)
        end)

      _ ->
        :ok
    end

    schedule()
    {:noreply, state}
  end

  defp check_provider(chain, provider) do
    # Only perform HTTP health check against HTTP-capable providers
    http_url = provider.url
    _ts = System.system_time(:millisecond)

    # Call circuit breaker only if it's running to avoid :noproc exits on boot
    result =
      case GenServer.whereis(
             {:via, Registry, {Lasso.Registry, {:circuit_breaker, "#{provider.id}:http"}}}
           ) do
        nil ->
          # Fall back to direct request; breaker will be engaged on next tick once started
          HttpClient.request(
            %{url: http_url, api_key: Map.get(provider, :api_key)},
            "eth_chainId",
            [],
            timeout: @default_timeout
          )

        _pid ->
          CircuitBreaker.call({provider.id, :http}, fn ->
            HttpClient.request(
              %{url: http_url, api_key: Map.get(provider, :api_key)},
              "eth_chainId",
              [],
              timeout: @default_timeout
            )
          end)
      end

    case result do
      {:ok, %{"jsonrpc" => "2.0"} = response} ->
        case Lasso.RPC.Normalizer.run(provider.id, "eth_chainId", response) do
          {:ok, _} ->
            ProviderPool.report_success(chain, provider.id)

          {:error, %Lasso.JSONRPC.Error{} = jerr} ->
            ProviderPool.report_failure(chain, provider.id, {:health_check, jerr})
        end

      {:ok, other} ->
        # Non-JSON-RPC shape; treat as infra failure via JError
        jerr =
          Lasso.JSONRPC.Error.from({:response_decode_error, inspect(other)},
            provider_id: provider.id
          )

        ProviderPool.report_failure(chain, provider.id, {:health_check, jerr})

      {:error, reason} ->
        jerr = Lasso.JSONRPC.Error.from(reason, provider_id: provider.id)
        ProviderPool.report_failure(chain, provider.id, {:health_check, jerr})
    end
  end

  defp schedule(), do: Process.send_after(self(), :tick, @default_interval)
end
