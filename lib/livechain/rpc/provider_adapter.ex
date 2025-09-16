defmodule Livechain.RPC.ProviderAdapter do
  @moduledoc """
  Behaviour for provider-specific normalization hooks. The default Generic
  adapter performs pass-through behavior.
  """

  @type context :: %{
          optional(:provider_id) => String.t(),
          optional(:method) => String.t()
        }

  @callback normalize_request(map(), context()) :: map()
  @callback normalize_response(map(), context()) :: {:ok, any()} | {:error, any()}
  @callback normalize_error(any(), context()) :: Livechain.JSONRPC.Error.t()
  @callback headers(context()) :: [{binary(), binary()}]

  @optional_callbacks headers: 1
end
