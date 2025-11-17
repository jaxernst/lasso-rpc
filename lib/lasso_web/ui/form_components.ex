defmodule LassoWeb.UI.FormComponents do
  @moduledoc """
  Reusable form field components with consistent styling.
  Reduces duplication and ensures UI consistency.
  """

  use Phoenix.Component

  @doc """
  Reusable form field with label and input.

  ## Examples

      <.form_field
        label="Chain Name"
        name="chain[name]"
        value={@name}
      />

      <.form_field
        label="Chain ID"
        name="chain[chain_id]"
        type="number"
        value={@chain_id}
        placeholder="1"
      />
  """
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :type, :string, default: "text"
  attr :value, :any, default: ""
  attr :placeholder, :string, default: ""
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(phx-debounce phx-change disabled required)

  def form_field(assigns) do
    ~H"""
    <div>
      <label class="block text-[11px] mb-1 font-medium text-gray-400">
        <%= @label %>
      </label>
      <input
        type={@type}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class={[
          "bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500",
          @class
        ]}
        {@rest}
      />
    </div>
    """
  end

  @doc """
  Form field for URLs with monospace font.

  ## Examples

      <.url_field
        label="HTTP URL"
        name="provider[url]"
        value={@url}
        placeholder="https://eth-mainnet.example.com"
      />
  """
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :placeholder, :string, default: ""
  attr :rest, :global, include: ~w(phx-debounce phx-change disabled required)

  def url_field(assigns) do
    ~H"""
    <.form_field
      label={@label}
      name={@name}
      type="url"
      value={@value}
      placeholder={@placeholder}
      class="font-mono text-xs"
      {@rest}
    />
    """
  end

  @doc """
  Number field with numeric styling.

  ## Examples

      <.number_field
        label="Chain ID"
        name="chain[chain_id]"
        value={@chain_id}
        placeholder="1"
      />
  """
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: ""
  attr :placeholder, :string, default: ""
  attr :rest, :global, include: ~w(phx-debounce phx-change disabled required min max step)

  def number_field(assigns) do
    ~H"""
    <.form_field
      label={@label}
      name={@name}
      type="number"
      value={@value}
      placeholder={@placeholder}
      {@rest}
    />
    """
  end
end
