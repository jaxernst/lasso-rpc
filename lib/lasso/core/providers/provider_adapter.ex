defmodule Lasso.RPC.ProviderAdapter do
  @moduledoc """
  Unified behaviour for provider-specific capabilities and normalization.

  ## Usage

  Most adapters only implement capability validation and delegate normalization
  to the Generic adapter using `defdelegate`:

      defmodule MyProvider do
        @behaviour Lasso.RPC.ProviderAdapter
        alias Lasso.RPC.Providers.Generic

        # Required: capability validation
        @impl true
        def supports_method?("unsupported_method", _transport, _ctx),
          do: {:error, :method_unsupported}
        def supports_method?(_method, _transport, _ctx),
          do: :skip_params

        @impl true
        def validate_params(_method, _params, _transport, _ctx),
          do: :ok

        # Optional: delegate normalization to Generic
        @impl true
        defdelegate normalize_request(req, ctx), to: Generic

        @impl true
        defdelegate normalize_response(resp, ctx), to: Generic

        @impl true
        defdelegate normalize_error(err, ctx), to: Generic

        @impl true
        defdelegate headers(ctx), to: Generic

        # Optional: provider metadata
        @impl true
        def metadata, do: %{type: :public, ...}
      end

  ## Design Principles

  - **Explicit validation:** Each provider's capabilities and limitations are encoded in reviewable code
  - **Two-phase validation:** Fast method-level checks run on all candidates; expensive parameter
    validation runs only on finalists
  - **Fail fast:** If a callback crashes, it's a bug that should be fixed (not hidden)
  - **Default implementations:** Adapters inherit Generic behavior for optional callbacks
  - **Override only what's needed:** Most adapters only need to implement capability validation

  ## Callback Groups

  ### Capability Validation (Required)
  - `supports_method?/3` - Fast method-level check (no parameter inspection)
  - `validate_params/4` - Parameter-level validation (only called on finalists)

  ### Normalization (Optional - defaults provided)
  - `normalize_request/2` - Transform request before sending to provider
  - `normalize_response/2` - Transform provider response to standard format
  - `normalize_error/2` - Transform provider errors to standard JSONRPC.Error
  - `headers/1` - Provider-specific HTTP headers

  ### Metadata (Optional)
  - `metadata/0` - Provider information for observability

  ## Two-Phase Validation Strategy

  Phase 1 runs on ALL candidates (fast):
  - Check if method is supported at all
  - No parameter parsing or inspection
  - Returns immediately for unsupported methods

  Phase 2 runs on FINALISTS only (slower, but fewer providers):
  - Parse and validate parameters
  - May involve hex decoding, list traversal, etc.
  - Only called after method-level filtering

  ## Examples

      # Phase 1: Method-level check (fast)
      def supports_method?("eth_getLogs", _transport, _ctx), do: {:error, :method_unsupported}
      def supports_method?("debug_" <> _, _transport, _ctx), do: {:error, :method_unsupported}
      def supports_method?(_method, _transport, _ctx), do: :ok

      # Phase 2: Parameter validation (only called if Phase 1 returns :ok)
      def validate_params("eth_getLogs", [%{"address" => addrs}], _transport, _ctx) when is_list(addrs) do
        if length(addrs) > 3 do
          {:error, {:param_limit, "max 3 addresses"}}
        else
          :ok
        end
      end

      def validate_params(_method, _params, _transport, _ctx), do: :ok
  """

  @type method :: String.t()
  @type params :: term()
  @type transport :: :http | :ws
  @type method_result :: :ok | {:error, :method_unsupported}
  @type validation_result :: :ok | {:error, error_reason()}

  @type error_reason ::
          :method_unsupported
          | :transport_unsupported
          | {:param_limit, String.t()}
          | {:requires_archival, String.t()}
          | {:requires_tier, String.t()}
          | atom()

  @type context :: %{
          optional(:provider_id) => String.t(),
          optional(:method) => String.t(),
          optional(:chain) => String.t()
        }

  # Capability Validation Callbacks (Required)

  @doc """
  Phase 1: Fast method-level check (no parameter inspection).

  Called for all provider candidates to quickly filter out providers
  that don't support the method.

  Returns:
  - `:ok` - Method supported
  - `{:error, :method_unsupported}` - Method not supported

  IMPORTANT: Do NOT inspect params in this callback for performance.
  """
  @callback supports_method?(method(), transport(), context()) :: method_result()

  @doc """
  Phase 2: Parameter-level validation (only called on finalists).

  This callback is only invoked after:
  1. supports_method?/3 returns :ok
  2. Provider is in the finalist set (after method filtering)

  May perform expensive operations:
  - Hex string parsing
  - List traversal
  - Block number calculations

  Returns:
  - `:ok` - Parameters are valid for this provider
  - `{:error, reason}` - Parameters violate provider limits
  """
  @callback validate_params(method(), params(), transport(), context()) :: validation_result()

  # Normalization Callbacks (Optional - defaults provided via __using__)

  @doc """
  Transforms a JSON-RPC request before sending to the provider.

  Override this if the provider requires non-standard request formatting.
  Default: pass-through via Generic adapter.
  """
  @callback normalize_request(map(), context()) :: map()

  @doc """
  Transforms a provider response to standard {:ok, result} | {:error, error} format.

  Override this if the provider returns non-standard response formats.
  Default: standard JSON-RPC 2.0 via Generic adapter.
  """
  @callback normalize_response(map(), context()) :: {:ok, any()} | {:error, any()}

  @doc """
  Transforms a provider error to standard JSONRPC.Error struct.

  Override this if the provider uses non-standard error codes or formats.
  Default: standard JSON-RPC 2.0 error via Generic adapter.
  """
  @callback normalize_error(any(), context()) :: Lasso.JSONRPC.Error.t()

  @doc """
  Returns provider-specific HTTP headers.

  Override this if the provider requires authentication headers or special headers.
  Default: empty list via Generic adapter.
  """
  @callback headers(context()) :: [{binary(), binary()}]

  @doc """
  Returns metadata about the adapter for observability.

  Should include:
  - type: :public | :commercial | :default
  - documentation: URL
  - known_limitations: list of strings
  - last_verified: Date
  """
  @callback metadata() :: map()

  # Note: normalize_* and headers callbacks are optional.
  # Most adapters delegate these to Generic using defdelegate.
  @optional_callbacks [
    normalize_request: 2,
    normalize_response: 2,
    normalize_error: 2,
    headers: 1,
    metadata: 0
  ]
end
