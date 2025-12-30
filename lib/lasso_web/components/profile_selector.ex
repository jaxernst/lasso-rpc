defmodule LassoWeb.Components.ProfileSelector do
  use Phoenix.Component

  alias Lasso.Config.ConfigStore

  attr :profiles, :list, required: true
  attr :selected_profile, :string, required: true
  attr :class, :string, default: ""

  def profile_selector(assigns) do
    assigns = assign(assigns, :profile_data, get_profile_data(assigns.profiles))

    ~H"""
    <div class={["relative inline-block", @class]}>
      <div class="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-zinc-800 text-sm">
        <.profile_status_dot profile={@selected_profile} />
        <span class="font-medium"><%= @selected_profile %></span>
        <div class="text-xs text-zinc-400 ml-2">
          <%= case get_profile_stats(@selected_profile, @profile_data) do %>
            <% {chain_count, provider_count} -> %>
              <%= chain_count %> chains · <%= provider_count %> providers
            <% _ -> %>

          <% end %>
        </div>
      </div>
      <%= if length(@profiles) > 1 do %>
        <div class="mt-1 space-y-1">
          <%= for {profile, data} <- @profile_data do %>
            <%= if profile != @selected_profile do %>
              <button
                phx-click="select_profile"
                phx-value-profile={profile}
                class="w-full px-3 py-2 text-left hover:bg-zinc-800 transition rounded-lg border border-zinc-800"
              >
                <div class="flex items-center gap-2">
                  <.profile_status_dot profile={profile} />
                  <span class="font-medium"><%= profile %></span>
                </div>
                <div class="text-xs text-zinc-400 mt-0.5">
                  <%= data.chain_count %> chains · <%= data.provider_count %> providers
                </div>
              </button>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp profile_status_dot(assigns) do
    assigns = assign(assigns, :status, get_profile_status(assigns.profile))

    ~H"""
    <div class={[
      "w-2 h-2 rounded-full",
      case @status do
        :healthy -> "bg-emerald-500"
        :degraded -> "bg-yellow-500"
        :warning -> "bg-red-500"
        _ -> "bg-zinc-500"
      end
    ]} />
    """
  end

  defp get_profile_data(profiles) do
    Enum.map(profiles, fn profile ->
      chains = ConfigStore.list_chains_for_profile(profile)

      provider_count =
        Enum.reduce(chains, 0, fn chain, acc ->
          case ConfigStore.get_chain(chain) do
            {:ok, chain_config} -> acc + length(chain_config.providers || [])
            _ -> acc
          end
        end)

      {profile, %{chain_count: length(chains), provider_count: provider_count}}
    end)
  end

  defp get_profile_stats(profile, profile_data) do
    case Enum.find(profile_data, fn {p, _} -> p == profile end) do
      {_, data} -> {data.chain_count, data.provider_count}
      nil -> nil
    end
  end

  defp get_profile_status(profile) do
    chains = ConfigStore.list_chains_for_profile(profile)

    status_list =
      Enum.flat_map(chains, fn chain ->
        case Lasso.RPC.ProviderPool.get_status(profile, chain) do
          {:ok, status} ->
            status.providers
            |> Enum.map(fn provider_map ->
              Map.get(provider_map, :status, :unknown)
            end)

          _ ->
            []
        end
      end)

    cond do
      Enum.empty?(status_list) -> :unknown
      Enum.all?(status_list, &(&1 == :healthy)) -> :healthy
      Enum.any?(status_list, &(&1 == :healthy)) -> :degraded
      true -> :warning
    end
  end
end
