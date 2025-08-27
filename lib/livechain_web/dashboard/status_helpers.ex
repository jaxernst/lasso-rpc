defmodule LivechainWeb.Dashboard.StatusHelpers do
  @moduledoc """
  Status-related helper functions for providers and events.
  """

  @doc "Get provider status label"
  def provider_status_label(%{status: :connected}), do: "CONNECTED"
  def provider_status_label(%{status: :disconnected}), do: "DISCONNECTED"
  def provider_status_label(%{status: :rate_limited}), do: "RATE LIMITED"

  def provider_status_label(%{status: :connecting} = pc) do
    attempts = Map.get(pc, :reconnect_attempts, 0)
    last_seen = Map.get(pc, :last_seen)

    cond do
      attempts >= 5 and (is_nil(last_seen) or last_seen == 0) -> "UNREACHABLE"
      attempts >= 5 -> "UNSTABLE"
      true -> "CONNECTING"
    end
  end

  def provider_status_label(_), do: "UNKNOWN"

  @doc "Get provider status CSS text class"
  def provider_status_class_text(%{status: :connected}), do: "text-emerald-400"
  def provider_status_class_text(%{status: :disconnected}), do: "text-red-400"
  def provider_status_class_text(%{status: :rate_limited}), do: "text-purple-300"

  def provider_status_class_text(%{status: :connecting} = pc) do
    attempts = Map.get(pc, :reconnect_attempts, 0)
    last_seen = Map.get(pc, :last_seen)

    cond do
      attempts >= 5 and (is_nil(last_seen) or last_seen == 0) -> "text-red-400"
      attempts >= 5 -> "text-yellow-400"
      true -> "text-yellow-400"
    end
  end

  def provider_status_class_text(_), do: "text-gray-400"

  @doc "Get severity text CSS class"
  def severity_text_class(:debug), do: "text-gray-400"
  def severity_text_class(:info), do: "text-sky-300"
  def severity_text_class(:warn), do: "text-yellow-300"
  def severity_text_class(:error), do: "text-red-400"
  def severity_text_class(_), do: "text-gray-400"
end