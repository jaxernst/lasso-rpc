defmodule LassoWeb.Components.ClusterStatus do
  @moduledoc """
  Components for displaying cluster status and coverage indicators.
  """
  use Phoenix.Component

  @doc """
  Renders a coverage indicator showing how many nodes contributed to the data.

  ## Examples

      <.coverage_indicator responding={2} total={3} />
      <.coverage_indicator coverage={%{responding: 2, total: 3}} />
  """
  attr(:responding, :integer, default: nil)
  attr(:total, :integer, default: nil)
  attr(:coverage, :map, default: nil)
  attr(:class, :string, default: "")
  attr(:show_label, :boolean, default: true)

  def coverage_indicator(assigns) do
    {responding, total} =
      case assigns do
        %{coverage: %{responding: r, total: t}} -> {r, t}
        %{responding: r, total: t} when not is_nil(r) and not is_nil(t) -> {r, t}
        _ -> {1, 1}
      end

    assigns =
      assigns
      |> assign(:responding, responding)
      |> assign(:total, total)
      |> assign(:status, compute_status(responding, total))

    ~H"""
    <span class={["inline-flex items-center gap-1.5 text-xs", @class]}>
      <span class={[
        "h-2 w-2 rounded-full",
        status_color(@status)
      ]}>
      </span>
      <span class="text-gray-400">
        <%= if @show_label do %>
          <span class={status_text_color(@status)}><%= @responding %></span>/{@total} nodes
        <% else %>
          <span class={status_text_color(@status)}><%= @responding %></span>/{@total}
        <% end %>
      </span>
    </span>
    """
  end

  @doc """
  Renders cluster info in a compact badge format.
  """
  attr(:class, :string, default: "")

  def cluster_badge(assigns) do
    topology = get_topology_info()

    status =
      cond do
        not topology.enabled -> :disabled
        topology.coverage.connected == 1 -> :standalone
        topology.coverage.responding == topology.coverage.connected -> :healthy
        true -> :degraded
      end

    assigns =
      assigns
      |> assign(:topology, topology)
      |> assign(:status, status)

    ~H"""
    <div class={["inline-flex items-center gap-2 px-2 py-1 rounded bg-gray-800/50", @class]}>
      <span class={["h-2 w-2 rounded-full", cluster_status_color(@status)]}></span>
      <span class="text-xs text-gray-400">
        <%= case @status do %>
          <% :disabled -> %>
            Standalone
          <% :standalone -> %>
            1 node
          <% _ -> %>
            {@topology.coverage.connected} nodes
            <%= if length(@topology.regions) > 1 do %>
              · {length(@topology.regions)} regions
            <% end %>
        <% end %>
      </span>
    </div>
    """
  end

  defp get_topology_info do
    topology = Lasso.Cluster.Topology.get_topology()

    %{
      enabled: true,
      coverage: topology.coverage,
      regions: topology.regions
    }
  catch
    :exit, _ -> %{enabled: false, coverage: %{connected: 1, responding: 1}, regions: []}
  end

  @doc """
  Renders a stale data warning when cached data is being refreshed.
  """
  attr(:stale, :boolean, required: true)
  attr(:class, :string, default: "")

  def stale_indicator(assigns) do
    ~H"""
    <%= if @stale do %>
      <span class={["inline-flex items-center gap-1 text-xs text-yellow-500/70", @class]}>
        <svg class="h-3 w-3 animate-spin" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
          </circle>
          <path
            class="opacity-75"
            fill="currentColor"
            d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
          >
          </path>
        </svg>
        refreshing
      </span>
    <% end %>
    """
  end

  @doc """
  Renders a fixed-position cluster status indicator in bottom-left corner.
  Per spec Section 4.2: Global fixed indicator for cluster health awareness.
  """
  attr(:responding, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:stale, :boolean, default: false)

  def fixed_cluster_status(assigns) do
    assigns = assign(assigns, :status, compute_status(assigns.responding, assigns.total))

    ~H"""
    <div class="fixed bottom-2 left-2 z-40 flex items-center gap-2">
      <div class={[
        "flex items-center gap-2 px-3 py-2 rounded-lg text-sm",
        "transition-colors duration-200"
      ]}>
        <span class={["h-2 w-2 rounded-full", status_color(@status)]}></span>
        <span class="text-gray-300">
          <span class={status_text_color(@status)}><%= @responding %></span>/{@total} Lasso nodes reporting
        </span>
        <%= if @responding < @total do %>
          <span class="text-amber-400">⚠</span>
        <% end %>
      </div>

      <%= if @stale do %>
        <div class="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm">
          <svg class="h-3 w-3 animate-spin text-yellow-500/70" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
            </circle>
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            >
            </path>
          </svg>
          <span class="text-xs text-yellow-500/70">refreshing</span>
        </div>
      <% end %>
    </div>
    """
  end

  # Private helpers

  defp compute_status(responding, total) do
    cond do
      responding == total -> :healthy
      responding >= div(total, 2) + 1 -> :degraded
      responding > 0 -> :critical
      true -> :offline
    end
  end

  defp status_color(:healthy), do: "bg-emerald-500"
  defp status_color(:degraded), do: "bg-yellow-500"
  defp status_color(:critical), do: "bg-red-500"
  defp status_color(:offline), do: "bg-gray-500"

  defp status_text_color(:healthy), do: "text-emerald-400"
  defp status_text_color(:degraded), do: "text-yellow-400"
  defp status_text_color(:critical), do: "text-red-400"
  defp status_text_color(:offline), do: "text-gray-500"

  defp cluster_status_color(:disabled), do: "bg-gray-500"
  defp cluster_status_color(:standalone), do: "bg-blue-500"
  defp cluster_status_color(:healthy), do: "bg-emerald-500"
  defp cluster_status_color(:degraded), do: "bg-yellow-500"
end
