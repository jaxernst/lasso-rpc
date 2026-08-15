defmodule LassoWeb.Plugs.RequestTimingPlug do
  @moduledoc """
  Captures true end-to-end HTTP request timing at the plug boundary.

  This plug records the start time as early as possible in the plug chain
  and uses `register_before_send` to calculate total request duration just
  before the response is sent.

  ## Usage

  Place this plug early in the endpoint's plug chain (ideally right after
  Plug.RequestId):

      plug(Plug.RequestId)
      plug(LassoWeb.Plugs.RequestTimingPlug)

  ## Timing Data

  The plug stores timing data in `conn.private`:

  - `:lasso_request_start_time` - Monotonic time at plug entry (microseconds)

  After `register_before_send`, the following are computed:

  - `:lasso_e2e_latency_ms` - End-to-end latency from plug entry to response send

  ## Extracting Timing

  Use `get_start_time/1` to retrieve the start time for use in RequestContext:

      plug_start_time = LassoWeb.Plugs.RequestTimingPlug.get_start_time(conn)
  """

  import Plug.Conn

  @behaviour Plug

  @doc """
  Initialize plug options.

  No options are currently supported.
  """
  @impl true
  def init(opts), do: opts

  @doc """
  Captures start time and registers before_send callback.
  """
  @impl true
  def call(conn, _opts) do
    start_time = System.monotonic_time(:microsecond)

    conn
    |> put_private(:lasso_request_start_time, start_time)
    |> register_before_send(&finalize_timing(&1, start_time))
  end

  # Calculate timing just before response is sent.
  defp finalize_timing(conn, start_time) do
    end_time = System.monotonic_time(:microsecond)
    e2e_latency_ms = (end_time - start_time) / 1000.0

    put_private(conn, :lasso_e2e_latency_ms, e2e_latency_ms)
  end

  @doc """
  Retrieves the start time stored by this plug.

  Returns the monotonic time in microseconds, or nil if timing was not captured
  (e.g., for WebSocket upgrade requests).
  """
  @spec get_start_time(Plug.Conn.t()) :: integer() | nil
  def get_start_time(%Plug.Conn{private: private}) do
    Map.get(private, :lasso_request_start_time)
  end

  @doc """
  Retrieves the calculated e2e latency in milliseconds.

  This is only available after the response has been sent (in `before_send` callbacks
  that run after this plug's callback).
  """
  @spec get_e2e_latency_ms(Plug.Conn.t()) :: float() | nil
  def get_e2e_latency_ms(%Plug.Conn{private: private}) do
    Map.get(private, :lasso_e2e_latency_ms)
  end
end
