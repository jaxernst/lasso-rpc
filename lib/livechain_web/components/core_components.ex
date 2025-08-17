defmodule LivechainWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application's components. The components
  here are minimal and generic, allowing maximum flexibility and composition.

  The default components use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn
  how to customize them or feel free to swap in another framework altogether.

  Icons are provided by [Heroicons](https://heroicons.com). See `icon/1` for usage.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a status indicator badge.

  ## Examples

      <.status_badge status={:connected} />
      <.status_badge status={:disconnected} />
  """
  attr(:status, :atom, required: true)

  def status_badge(assigns) do
    ~H"""
    <span class={["inline-flex items-center rounded-full px-2 py-1 text-xs font-medium", status_color(@status)]}>
      {status_text(@status)}
    </span>
    """
  end

  @doc """
  Renders a simple table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
      </.table>
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "the function for generating the row id")
  attr(:row_click, :any, default: nil, doc: "the function for handling phx-click on each row")

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"
  )

  slot :col, required: true do
    attr(:label, :string)
  end

  slot(:action, doc: "the slot for showing user actions in the last table column")

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-y-auto px-4 sm:overflow-visible sm:px-0">
      <table class="w-[40rem] mt-11 sm:w-full">
        <thead class="text-left text-sm leading-6 text-zinc-500">
          <tr>
            <th :for={col <- @col} class="p-0 pr-6 pb-4 font-normal">{col[:label]}</th>
            <th :if={@action != []} class="relative p-0 pb-4">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class="relative divide-y divide-zinc-100 border-t border-zinc-200 text-sm leading-6 text-zinc-700"
        >
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="group hover:bg-zinc-50">
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              class={["relative p-0", @row_click && "hover:cursor-pointer"]}
            >
              <div class="block py-4 pr-6">
                <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-zinc-50 sm:rounded-l-xl" />
                <span class={["relative", i == 0 && "font-semibold text-zinc-900"]}>
                  {render_slot(col, @row_item.(row))}
                </span>
              </div>
            </td>
            <td :if={@action != []} class="relative w-14 p-0">
              <div class="relative whitespace-nowrap py-4 text-right text-sm font-medium">
                <span class="absolute -inset-y-px -right-4 left-0 group-hover:bg-zinc-50 sm:rounded-r-xl" />
                <span
                  :for={action <- @action}
                  class="relative ml-4 font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
                >
                  {render_slot(action, @row_item.(row))}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp status_color(:connected), do: "bg-green-100 text-green-800"
  defp status_color(:disconnected), do: "bg-red-100 text-red-800"
  defp status_color(:unknown), do: "bg-gray-100 text-gray-800"
  defp status_color(:dead), do: "bg-gray-100 text-gray-800"
  defp status_color(_), do: "bg-gray-100 text-gray-800"

  defp status_text(:connected), do: "Connected"
  defp status_text(:disconnected), do: "Disconnected"
  defp status_text(:unknown), do: "Unknown"
  defp status_text(:dead), do: "Dead"
  defp status_text(status), do: to_string(status)

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages")
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={["fixed top-2 right-2 z-50 mr-2 w-80 rounded-lg p-3 ring-1 sm:w-96", @kind == :info && "bg-emerald-50 fill-cyan-900 text-emerald-800 ring-emerald-500", @kind == :error && "bg-rose-50 fill-rose-900 text-rose-900 shadow-md ring-rose-500"]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6">
        <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4" />
        {@title}
      </p>
      <p class="mt-2 text-sm leading-5">{msg}</p>
      <button type="button" class="group absolute top-1 right-1 p-2" aria-label="close">
        <.icon name="hero-x-mark-solid" class="h-5 w-5 opacity-40 group-hover:opacity-70" />
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title="Success!" flash={@flash} />
      <.flash kind={:error} title="Error!" flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Hang in there while we get back on track
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr(:name, :string, required: true)
  attr(:class, :string, default: nil)

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(LivechainWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(LivechainWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  # Collapsible Section Component
  def collapsible_section(assigns) do
    # Determine colors based on section_id
    {header_gradient, content_bg, border_color} =
      case assigns.section_id do
        "live_stream" ->
          {"from-gray-900 to-black", "bg-gray-900", "border-gray-700"}

        "network_topology" ->
          {"from-purple-900 to-purple-800", "bg-purple-900", "border-purple-700"}

        _ ->
          {"from-gray-800 to-gray-900", "bg-gray-900", "border-gray-700"}
      end

    assigns = assign(assigns, :header_gradient, header_gradient)
    assigns = assign(assigns, :content_bg, content_bg)
    assigns = assign(assigns, :border_color, border_color)

    ~H"""
    <div
      class="group mb-4 transition-all duration-300 ease-out hover:scale-[1.02]"
      id={"collapsible-#{@section_id}"}
      phx-hook="CollapsibleSection"
    >
      <button
        type="button"
        class={"#{@header_gradient} flex w-full items-center justify-between rounded-t-lg bg-gradient-to-r p-4 text-left text-white shadow-lg transition-shadow duration-200 hover:shadow-xl"}
      >
        <div class="flex items-center space-x-3">
          <div class="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-lg bg-white bg-opacity-10">
            {render_slot(@icon)}
          </div>
          <div>
            <h3 class="text-lg font-semibold">{@title}</h3>
            <p class="text-sm text-gray-300">{@subtitle}</p>
          </div>
        </div>
        <div class="flex items-center space-x-2">
          <span class="text-sm text-gray-300">{@count}</span>
          <div class="h-5 w-5 flex-shrink-0 transform transition-transform duration-200 ease-out">
            <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 9l-7 7-7-7"
              />
            </svg>
          </div>
        </div>
      </button>

      <div class={"#{@content_bg} #{@border_color} h-12 overflow-hidden rounded-b-lg border-t transition-all duration-300 ease-out"}>
        <div class="grid-pattern p-3">
          <div class="flex h-full items-center justify-center">
            <div class="text-center">
              <div class="mb-1 text-lg opacity-50">
                {case @section_id do
                  "live_stream" -> "⚡"
                  "network_topology" -> "🌐"
                  _ -> "📁"
                end}
              </div>
              <p class="text-xs text-gray-400">Click to expand {@title}</p>
            </div>
          </div>
        </div>
        <div class="grid-pattern p-4" style="display: none;">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a modern tab switcher component with dark theme and purple accents.

  ## Examples

      <.tab_switcher
        id="main-tabs"
        tabs={[
          %{id: "live_feed", label: "Live Feed", icon: "M13 10V3L4 14h7v7l9-11h-7z"},
          %{id: "network", label: "Network", icon: "M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3"},
          %{id: "simulator", label: "Simulator", icon: "M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3"}
        ]}
        active_tab={@active_tab}
      />
  """
  attr(:id, :string, required: true, doc: "unique identifier for the tab switcher")
  attr(:tabs, :list, required: true, doc: "list of tab maps with id, label, and icon keys")
  attr(:active_tab, :string, required: true, doc: "currently active tab id")
  attr(:class, :string, default: "", doc: "additional CSS classes")

  def tab_switcher(assigns) do
    ~H"""
    <div class={["bg-gray-900/50 border-gray-700/50 flex items-center space-x-1 rounded-xl border p-1.5 backdrop-blur-sm", @class]}>
      <%= for tab <- @tabs do %>
        <button
          phx-click="switch_tab"
          phx-value-tab={tab.id}
          class={["relative flex items-center space-x-2 overflow-hidden rounded-lg px-4 py-2.5 text-sm font-medium transition-all duration-200", if(@active_tab == tab.id,
    do: "shadow-purple-500/25 bg-gradient-to-r from-purple-600 to-purple-500 text-white shadow-lg",
    else: "text-gray-300 hover:bg-gray-800/50 hover:text-white")]}
        >
          <%= if @active_tab == tab.id do %>
            <div class="from-purple-600/20 to-purple-500/20 absolute inset-0 rounded-lg bg-gradient-to-r">
            </div>
          <% end %>
          <svg
            class={["h-4 w-4", if(@active_tab == tab.id, do: "text-white", else: "text-gray-400")]}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d={tab.icon} />
          </svg>
          <span class="relative z-10">{tab.label}</span>
        </button>
      <% end %>
    </div>
    """
  end
end
