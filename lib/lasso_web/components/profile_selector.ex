defmodule LassoWeb.Components.ProfileSelector do
  @moduledoc """
  Profile selector dropdown for switching between routing profiles.
  Built-in profiles render first, custom (BYOK) profiles below a divider.
  """
  use Phoenix.Component

  alias Lasso.Config.ConfigStore
  alias Phoenix.LiveView.JS

  attr(:profiles, :list, required: true)
  attr(:selected_profile, :string, required: true)
  attr(:profile_entitlements, :map, default: %{})
  attr(:class, :string, default: "")
  attr(:show_create_cta, :boolean, default: true)

  def profile_selector(assigns) do
    profile_data = get_profile_data(assigns.profiles, assigns.profile_entitlements)

    selected_data =
      case Enum.find(profile_data, fn {slug, _} -> slug == assigns.selected_profile end) do
        {_, data} -> data
        nil -> %{name: assigns.selected_profile, logo: nil}
      end

    {builtin_profiles, custom_profiles} =
      Enum.split_with(profile_data, fn {_slug, data} -> !data.byok end)

    assigns =
      assigns
      |> assign(:builtin_profiles, builtin_profiles)
      |> assign(:custom_profiles, custom_profiles)
      |> assign(:selected_display_name, selected_data.name)
      |> assign(:selected_logo, selected_data.logo)

    ~H"""
    <div class={["relative", @class]} id="profile-selector">
      <button
        id="profile-selector-trigger"
        phx-click={toggle_dropdown()}
        aria-haspopup="listbox"
        aria-expanded="false"
        class="group bg-[#121a28] flex items-center justify-between gap-3 rounded-lg border border-gray-600/40 px-3 py-2 text-left transition-all hover:border-gray-500/50 focus:ring-purple-500/30 focus:outline-none focus:ring-1"
      >
        <div class="flex items-center gap-3">
          <div class="flex items-center gap-2 text-gray-400 transition-colors group-hover:text-gray-300">
            <%= if @selected_logo do %>
              <img
                src={"/images/profiles/#{@selected_logo}"}
                class="h-4 w-4 object-contain"
                alt=""
              />
            <% else %>
              <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
                />
              </svg>
            <% end %>
            <span class="text-xs font-medium uppercase tracking-wide text-gray-500 group-hover:text-gray-400">
              Profile
            </span>
          </div>

          <div class="h-4 w-px bg-gray-800 transition-colors group-hover:bg-gray-700"></div>

          <span class="text-sm font-semibold text-gray-200 transition-colors group-hover:text-white">
            {@selected_display_name}
          </span>
        </div>

        <svg
          class="h-4 w-4 text-gray-500 transition-colors group-hover:text-gray-400"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <div
        id="profile-dropdown"
        phx-click-away={hide_dropdown()}
        class={[
          "absolute top-full right-0 mt-2 w-72",
          "ring-black/50 rounded-lg border border-gray-600/40 bg-[#121a28] shadow-xl ring-1",
          "z-50 overflow-hidden",
          "hidden"
        ]}
      >
        <div class="px-2 pt-1.5 pb-2">
          <span class="text-[10px] font-semibold tracking-wider text-gray-500 uppercase">
            Lasso Profiles
          </span>
        </div>

        <div class="px-2 space-y-1">
          <%= for {profile, data} <- @builtin_profiles do %>
            <.profile_card
              profile={profile}
              data={data}
              selected={profile == @selected_profile}
            />
          <% end %>
        </div>

        <%= if @show_create_cta or @custom_profiles != [] do %>
          <div class="mt-3 border-t border-gray-800/60"></div>

          <div class="flex items-center justify-between px-2 pt-3 pb-2">
            <span class="text-[10px] font-semibold tracking-wider text-gray-500 uppercase">
              Custom Profiles
            </span>
            <%= if @show_create_cta do %>
              <button
                type="button"
                phx-click={JS.push("show_upgrade_modal") |> hide_dropdown()}
                class="text-[11px] flex items-center gap-1 text-purple-400 transition-colors hover:text-purple-300"
              >
                <svg class="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 4v16m8-8H4"
                  />
                </svg>
                Create
              </button>
            <% end %>
          </div>

          <div class="px-2 pb-2 space-y-1">
            <%= for {profile, data} <- @custom_profiles do %>
              <.profile_card
                profile={profile}
                data={data}
                selected={profile == @selected_profile}
              />
            <% end %>
            <%= if @custom_profiles == [] do %>
              <p class="py-1 text-[11px] text-gray-600">
                Bring your own RPC providers with custom routing preferences.
              </p>
            <% end %>
          </div>
        <% else %>
          <div class="pb-2"></div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:profile, :string, required: true)
  attr(:data, :map, required: true)
  attr(:selected, :boolean, default: false)

  defp profile_card(assigns) do
    ~H"""
    <button
      phx-click={JS.push("select_profile", value: %{profile: @profile}) |> hide_dropdown()}
      class={[
        "group flex w-full items-center gap-2.5 rounded px-2.5 py-2 text-left transition-colors",
        if(@selected,
          do: "bg-purple-500/10 hover:bg-purple-500/15",
          else: "bg-gray-800/40 hover:bg-gray-800/70"
        )
      ]}
    >
      <%= if @data.logo do %>
        <img
          src={"/images/profiles/#{@data.logo}"}
          class="h-5 w-5 flex-none object-contain"
          alt=""
        />
      <% else %>
        <svg
          class={[
            "h-5 w-5 flex-none",
            if(@selected, do: "text-purple-400", else: "text-gray-600")
          ]}
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
      <% end %>

      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-1.5">
          <span class={[
            "truncate text-sm font-medium",
            if(@selected, do: "text-white", else: "text-gray-200")
          ]}>
            {@data.name}
          </span>
          <%= if @selected do %>
            <svg
              class="h-3.5 w-3.5 flex-none text-purple-400"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path
                fill-rule="evenodd"
                d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                clip-rule="evenodd"
              />
            </svg>
          <% end %>
        </div>
        <div class="mt-0.5 text-[11px] text-gray-500">
          {@data.chain_count} {if @data.chain_count == 1, do: "chain", else: "chains"}
        </div>
      </div>
    </button>
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

  defp get_profile_data(profiles, _profile_entitlements) do
    Enum.map(profiles, fn profile_slug ->
      chains = ConfigStore.list_chains_for_profile(profile_slug)

      {display_name, logo, unlisted} =
        case ConfigStore.get_profile(profile_slug) do
          {:ok, meta} -> {meta.name, meta.logo, meta.unlisted}
          _ -> {profile_slug, nil, false}
        end

      {profile_slug,
       %{
         name: display_name,
         logo: logo,
         byok: unlisted,
         chain_count: length(chains)
       }}
    end)
  end
end
