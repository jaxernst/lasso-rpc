defmodule LassoWeb.Components.ProfileSelector do
  @moduledoc """
  Profile selector dropdown component for switching between RPC profiles.

  Displays the current profile with a health status indicator and provides
  a dropdown menu for switching between available profiles.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Lasso.Config.ConfigStore

  attr(:profiles, :list, required: true)
  attr(:selected_profile, :string, required: true)
  attr(:class, :string, default: "")
  attr(:show_create_cta, :boolean, default: true)

  def profile_selector(assigns) do
    profile_data = get_profile_data(assigns.profiles)

    # Get display name for selected profile
    selected_display_name =
      case Enum.find(profile_data, fn {slug, _} -> slug == assigns.selected_profile end) do
        {_, data} -> data.name
        nil -> assigns.selected_profile
      end

    assigns =
      assigns
      |> assign(:profile_data, profile_data)
      |> assign(:selected_display_name, selected_display_name)

    ~H"""
    <div class={["relative", @class]} id="profile-selector">
      <!-- Trigger Button -->
      <button
        id="profile-selector-trigger"
        phx-click={toggle_dropdown()}
        aria-haspopup="listbox"
        aria-expanded="false"
        class="group bg-gray-900/60 flex items-center justify-between gap-3 rounded-lg border border-gray-700 px-3 py-2 text-left transition-all hover:bg-gray-900/50 hover:border-gray-600 focus:ring-purple-500/30 focus:outline-none focus:ring-1"
      >
        <div class="flex items-center gap-3">
          <!-- Label & Icon -->
          <div class="flex items-center gap-2 text-gray-400 transition-colors group-hover:text-gray-300">
            <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
              />
            </svg>
            <span class="text-xs font-medium uppercase tracking-wide text-gray-500 group-hover:text-gray-400">
              Profile
            </span>
          </div>
          
    <!-- Subtle Divider -->
          <div class="h-4 w-px bg-gray-800 transition-colors group-hover:bg-gray-700"></div>
          
    <!-- Selected Value -->
          <span class="text-sm font-semibold text-gray-200 transition-colors group-hover:text-white">
            {@selected_display_name}
          </span>
        </div>
        
    <!-- Chevron -->
        <svg
          class="h-4 w-4 text-gray-500 transition-colors group-hover:text-gray-400"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      
    <!-- Dropdown Panel -->
      <div
        id="profile-dropdown"
        phx-click-away={hide_dropdown()}
        class={["absolute top-full right-0 mt-2 w-72", "ring-black/50 rounded-lg border border-gray-700 bg-gray-900 shadow-xl ring-1", "z-50 overflow-hidden", "hidden"]}
      >
        <!-- Header -->
        <div class="bg-gray-900/50 border-b border-gray-800 px-3 py-2.5">
          <div class="text-sm font-medium text-gray-200">Switch Profile</div>
          <div class="mt-0.5 text-xs text-gray-500">Select a provider configuration</div>
        </div>
        
    <!-- Profile List -->
        <div class="py-1">
          <%= for {profile, data} <- @profile_data do %>
            <.profile_item
              profile={profile}
              data={data}
              selected={profile == @selected_profile}
            />
          <% end %>
        </div>
        
    <!-- Create Profile CTA -->
        <%= if @show_create_cta do %>
          <div class="border-t border-gray-800 p-2">
            <.create_profile_cta />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp toggle_dropdown do
    %JS{}
    |> JS.toggle(
      to: "#profile-dropdown",
      in:
        {"transition ease-out duration-200", "opacity-0 -translate-y-1",
         "opacity-100 translate-y-0"},
      out:
        {"transition ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-1"}
    )
    |> JS.toggle_attribute({"aria-expanded", "true", "false"},
      to: "#profile-selector-trigger"
    )
  end

  defp hide_dropdown(js \\ %JS{}) do
    js
    |> JS.hide(
      to: "#profile-dropdown",
      transition:
        {"transition ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-1"}
    )
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#profile-selector-trigger")
    |> JS.dispatch("blur", to: "#profile-selector-trigger")
  end

  defp profile_item(assigns) do
    ~H"""
    <button
      phx-click={JS.push("select_profile", value: %{profile: @profile}) |> hide_dropdown()}
      class={["flex w-full items-center gap-3 px-3 py-2.5 text-left", "transition-colors hover:bg-gray-800", @selected && "bg-purple-500/10"]}
    >
      <!-- Layers icon -->
      <svg
        class={["h-4 w-4 flex-none", if(@selected, do: "text-purple-400", else: "text-gray-600 group-hover:text-gray-500")]}
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
        />
      </svg>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <span class={["truncate text-sm font-medium", if(@selected, do: "text-white", else: "text-gray-300")]}>
            {@data.name}
          </span>
          <%= if @selected do %>
            <svg class="h-3.5 w-3.5 flex-none text-purple-400" fill="currentColor" viewBox="0 0 20 20">
              <path
                fill-rule="evenodd"
                d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                clip-rule="evenodd"
              />
            </svg>
          <% end %>
        </div>
        <div class="text-xs text-gray-500">
          {@data.chain_count} chains · {@data.provider_count} providers
        </div>
      </div>
    </button>
    """
  end

  defp create_profile_cta(assigns) do
    ~H"""
    <button
      phx-click={JS.push("navigate_create_profile") |> hide_dropdown()}
      class="flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm text-gray-400 transition-colors hover:bg-gray-800 hover:text-purple-300"
    >
      <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
      </svg>
      <span>Create profile</span>
    </button>
    """
  end

  defp get_profile_data(profiles) do
    Enum.map(profiles, fn profile_slug ->
      chains = ConfigStore.list_chains_for_profile(profile_slug)

      # Get display name from profile metadata
      display_name =
        case ConfigStore.get_profile(profile_slug) do
          {:ok, meta} -> meta.name || profile_slug
          _ -> profile_slug
        end

      provider_count =
        Enum.reduce(chains, 0, fn chain, count ->
          case ConfigStore.get_chain(chain) do
            {:ok, chain_config} ->
              providers = chain_config.providers || []
              count + length(providers)

            _ ->
              count
          end
        end)

      {profile_slug,
       %{
         name: display_name,
         chain_count: length(chains),
         provider_count: provider_count
       }}
    end)
  end
end
