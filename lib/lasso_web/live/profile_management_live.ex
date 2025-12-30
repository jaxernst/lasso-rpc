defmodule LassoWeb.ProfileManagementLive do
  use LassoWeb, :live_view
  alias Lasso.Config.ConfigStore

  def mount(_params, _session, socket) do
    profiles = ConfigStore.list_profiles()
    socket = assign(socket, :profiles, profiles)
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="p-6">
      <h1 class="text-2xl font-bold mb-4">Profile Management</h1>
      <div class="text-gray-400 mb-4">
        Profiles are configured via YAML files in config/profiles/
      </div>
      <div class="space-y-2">
        <%= for profile <- @profiles do %>
          <div class="border border-gray-700 rounded p-4">
            <div class="font-semibold"><%= profile %></div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
