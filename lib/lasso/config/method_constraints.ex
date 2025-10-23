defmodule Lasso.Config.MethodConstraints do
  @moduledoc """
  Public facade for method constraints (ws-only, disallowed, transports).

  Delegates to TransportPolicy for now to preserve backward compatibility,
  allowing future renaming without widespread churn.
  """

  alias Lasso.Config.TransportPolicy

  @type method :: String.t()

  @spec ws_only?(method) :: boolean()
  defdelegate ws_only?(method), to: TransportPolicy

  @spec disallowed?(method) :: boolean()
  defdelegate disallowed?(method), to: TransportPolicy

  @spec required_transport_for(method) :: :http | :ws | nil
  defdelegate required_transport_for(method), to: TransportPolicy

  @spec allowed_transports_for(method, :http | :ws | :both | nil) :: [:http | :ws]
  defdelegate allowed_transports_for(method, preference \\ :both), to: TransportPolicy
end
