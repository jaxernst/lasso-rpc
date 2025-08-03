defmodule LivechainWeb.MinimalStateLive do
  use LivechainWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      count: 0,
      step: 1,
      auto_increment: false,
      history: [],
      last_updated: nil
    )}
  end

  def handle_event("increment", _params, socket) do
    new_count = socket.assigns.count + socket.assigns.step
    history = [{"increment", socket.assigns.count, new_count, socket.assigns.step} | socket.assigns.history] |> Enum.take(5)

    {:noreply, assign(socket,
      count: new_count,
      history: history,
      last_updated: DateTime.utc_now()
    )}
  end

  def handle_event("decrement", _params, socket) do
    new_count = socket.assigns.count - socket.assigns.step
    history = [{"decrement", socket.assigns.count, new_count, socket.assigns.step} | socket.assigns.history] |> Enum.take(5)

    {:noreply, assign(socket,
      count: new_count,
      history: history,
      last_updated: DateTime.utc_now()
    )}
  end

  def handle_event("reset", _params, socket) do
    history = [{"reset", socket.assigns.count, 0, 0} | socket.assigns.history] |> Enum.take(5)

    {:noreply, assign(socket,
      count: 0,
      history: history,
      last_updated: DateTime.utc_now()
    )}
  end

  def handle_event("step_change", params, socket) do
    step = case params do
      %{"step" => step} -> String.to_integer(step)
      _ -> socket.assigns.step
    end
    {:noreply, assign(socket, step: step)}
  end

  def handle_event("toggle_auto", _params, socket) do
    if socket.assigns.auto_increment do
      {:noreply, assign(socket, auto_increment: false)}
    else
      Process.send_after(self(), :auto_increment, 1000)
      {:noreply, assign(socket, auto_increment: true)}
    end
  end

  def handle_info(:auto_increment, socket) do
    if socket.assigns.auto_increment do
      new_count = socket.assigns.count + socket.assigns.step
      history = [{"auto", socket.assigns.count, new_count, socket.assigns.step} | socket.assigns.history] |> Enum.take(5)

      Process.send_after(self(), :auto_increment, 1000)

      {:noreply, assign(socket,
        count: new_count,
        history: history,
        last_updated: DateTime.utc_now()
      )}
    else
      {:noreply, socket}
    end
  end

  defp get_count_color(count) do
    cond do
      count > 0 -> "text-green-600"
      count < 0 -> "text-red-600"
      true -> "text-blue-600"
    end
  end

  defp get_bg_color(count) do
    cond do
      count > 10 -> "bg-green-50"
      count < -10 -> "bg-red-50"
      count > 0 -> "bg-blue-50"
      count < 0 -> "bg-orange-50"
      true -> "bg-white"
    end
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 flex items-center justify-center p-4">
      <div class={"max-w-md w-full p-8 rounded-lg shadow-md text-center transition-colors duration-300 #{get_bg_color(@count)}"}>
        <h1 class="text-3xl font-bold text-gray-800 mb-6">Hello World Counter</h1>

        <div class={"text-6xl font-bold mb-8 transition-colors duration-300 #{get_count_color(@count)}"}>
          <%= @count %>
        </div>

        <!-- Step Control -->
        <div class="mb-6">
          <label class="block text-sm font-medium text-gray-700 mb-2">Step Size</label>
          <form phx-change="step_change">
            <select name="step" class="w-full p-2 border border-gray-300 rounded-md">
              <option value="1" selected={@step == 1}>1</option>
              <option value="5" selected={@step == 5}>5</option>
              <option value="10" selected={@step == 10}>10</option>
              <option value="25" selected={@step == 25}>25</option>
            </select>
          </form>
        </div>

        <!-- Control Buttons -->
        <div class="space-x-2 mb-6">
          <button
            phx-click="decrement"
            class="bg-red-500 hover:bg-red-600 text-white font-bold py-2 px-4 rounded transition-colors">
            -<%= @step %>
          </button>

          <button
            phx-click="increment"
            class="bg-green-500 hover:bg-green-600 text-white font-bold py-2 px-4 rounded transition-colors">
            +<%= @step %>
          </button>
        </div>

        <!-- Reset and Auto Controls -->
        <div class="space-x-2 mb-6">
          <button
            phx-click="reset"
            class="bg-gray-500 hover:bg-gray-600 text-white font-bold py-2 px-4 rounded transition-colors">
            Reset
          </button>

          <button
            phx-click="toggle_auto"
            class={"font-bold py-2 px-4 rounded transition-colors #{if @auto_increment, do: 'bg-purple-600 hover:bg-purple-700 text-white', else: 'bg-purple-300 hover:bg-purple-400 text-purple-800'}"}>
            <%= if @auto_increment, do: "Stop Auto", else: "Start Auto" %>
          </button>
        </div>

        <!-- Status Indicators -->
        <div class="text-sm text-gray-600 mb-4">
          <div>Step: <%= @step %></div>
          <div>Auto: <%= if @auto_increment, do: "ON", else: "OFF" %></div>
          <%= if @last_updated do %>
            <div>Last updated: <%= format_time(@last_updated) %></div>
          <% end %>
        </div>

        <!-- History -->
        <%= if length(@history) > 0 do %>
          <div class="mt-6">
            <h3 class="text-lg font-semibold text-gray-700 mb-3">Recent Changes</h3>
            <div class="space-y-2">
              <%= for {action, old_val, new_val, step} <- @history do %>
                <div class="text-sm bg-gray-200 p-2 rounded">
                  <span class="font-medium"><%= String.upcase(action) %></span>
                  <span class="text-gray-600">
                    <%= old_val %> → <%= new_val %>
                    <%= if step > 0, do: "(±#{step})" %>
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
