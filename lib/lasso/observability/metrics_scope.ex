defmodule Lasso.Observability.MetricsScope do
  @moduledoc """
  Host hook that bounds Prometheus label values and selects the routes the exporter scans.

  `bound/1` receives an event's metadata before labels are built and returns it with
  `:profile`, `:chain_id`, `:provider_id` or `:instance_id` replaced as needed, for
  example folding tenant-defined profiles into one shared value. `export_route?/1`
  decides whether a profile's routes appear in the scrape-time route families (circuit
  state, head lag, provider info, readiness); bounded profiles usually should not, since
  several routes would collapse onto the same series.

  Configure a host implementation with `config :lasso, :metrics_scope, MyScope`. The
  default keeps every value and exports every route, which suits file-configured profiles.
  """

  @callback bound(map()) :: map()
  @callback export_route?(String.t()) :: boolean()

  @behaviour __MODULE__

  @impl true
  def bound(meta), do: meta

  @impl true
  def export_route?(_profile), do: true

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl, do: :persistent_term.get(__MODULE__, __MODULE__)

  @doc false
  @spec install() :: :ok
  def install do
    :persistent_term.put(__MODULE__, Application.get_env(:lasso, :metrics_scope, __MODULE__))
  end
end
