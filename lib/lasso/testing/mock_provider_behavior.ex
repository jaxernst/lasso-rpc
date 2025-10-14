defmodule Lasso.Testing.MockProviderBehavior do
  @moduledoc """
  Behavior-based mock provider with configurable failure scenarios.

  This module provides rich, realistic failure behaviors for integration tests,
  going beyond simple "always succeed" or "always fail" patterns.

  ## Response Format

  Mock responses return **unwrapped values** (what the application sees after
  JSON-RPC envelope removal):

      eth_blockNumber -> "0x7D40D" (hex string)
      eth_getBalance -> "0x1234..." (hex string)
      eth_getLogs -> [] (array)
      eth_call -> "0x00..." (hex string)
      eth_getBlockByNumber -> %{"number" => "0x...", ...} (map)

  The BehaviorHttpClient wraps these in `%{"jsonrpc" => "2.0", "result" => ...}`
  format before returning to the transport layer.

  ## Behaviors

  - `:healthy` - Normal operation, returns successful responses
  - `:always_fail` - All requests fail with generic error
  - `:always_timeout` - All requests timeout (long sleep)
  - `{:error, error}` - All requests fail with specific error
  - `{:conditional, fun}` - Dynamic behavior based on request
  - `{:sequence, responses}` - Return different responses in sequence
  - `degraded_performance/1` - Gradually increasing latency
  - `intermittent_failures/1` - Random failures at specified rate
  - `rate_limited_provider/1` - Rate limit after N requests

  ## Usage

      # Simple behaviors
      %{id: "provider", behavior: :healthy}
      %{id: "provider", behavior: :always_fail}
      %{id: "provider", behavior: {:error, :timeout}}

      # Complex behaviors
      %{id: "provider", behavior: MockProviderBehavior.degraded_performance(100)}
      %{id: "provider", behavior: MockProviderBehavior.intermittent_failures(0.3)}
      %{id: "provider", behavior: MockProviderBehavior.rate_limited_provider(10)}
  """

  alias Lasso.JSONRPC.Error, as: JError

  @type behavior ::
          :healthy
          | :always_fail
          | :always_timeout
          | {:error, term()}
          | {:conditional, (String.t(), list(), map() -> {:ok, any()} | {:error, any()})}
          | {:sequence, [any()]}

  @type request_state :: %{
          call_count: non_neg_integer(),
          start_time: integer()
        }

  @doc """
  Executes a behavior for a given request.

  Returns `{:ok, response}` or `{:error, error}` based on the behavior
  configuration and current state.
  """
  @spec execute_behavior(behavior(), String.t(), list(), request_state()) ::
          {:ok, any()} | {:error, any()}
  def execute_behavior(behavior, method, params, state)

  def execute_behavior(:healthy, method, params, _state) do
    {:ok, mock_response(method, params)}
  end

  def execute_behavior(:always_fail, _method, _params, _state) do
    {:error,
     %JError{
       code: -32_000,
       message: "Mock provider failure",
       category: :provider_error,
       retriable?: true
     }}
  end

  def execute_behavior(:always_timeout, _method, _params, _state) do
    # Simulate timeout by sleeping longer than typical timeout
    Process.sleep(35_000)
    {:ok, %{"result" => "0x1"}}
  end

  def execute_behavior({:error, error}, _method, _params, _state) do
    {:error, error}
  end

  def execute_behavior({:conditional, condition_fun}, method, params, state) do
    condition_fun.(method, params, state)
  end

  def execute_behavior({:sequence, responses}, _method, _params, state) do
    # Return different response based on call count
    index = min(state.call_count, length(responses) - 1)
    Enum.at(responses, index, {:error, :sequence_exhausted})
  end

  @doc """
  Creates a degraded performance behavior.

  Latency increases with each request, simulating a provider under load.

  ## Options

  - `base_latency` - Starting latency in milliseconds (default: 100)
  - `degradation_rate` - How much latency increases per request (default: 0.1 = 10%)

  ## Example

      behavior = degraded_performance(50)
      # First request: ~50ms
      # Second request: ~55ms
      # Third request: ~60.5ms
      # etc.
  """
  def degraded_performance(base_latency \\ 100, degradation_rate \\ 0.1) do
    {:conditional,
     fn method, params, state ->
       # Calculate latency based on call count
       latency = base_latency * (1 + state.call_count * degradation_rate)
       Process.sleep(trunc(latency))

       {:ok, mock_response(method, params)}
     end}
  end

  @doc """
  Creates an intermittent failure behavior.

  Randomly fails requests at the specified rate.

  ## Parameters

  - `success_rate` - Probability of success (0.0-1.0), default: 0.7

  ## Example

      behavior = intermittent_failures(0.8)
      # 80% success rate, 20% failure rate
  """
  def intermittent_failures(success_rate \\ 0.7) do
    {:conditional,
     fn method, params, _state ->
       if :rand.uniform() < success_rate do
         {:ok, mock_response(method, params)}
       else
         {:error,
          %JError{
            code: -32_603,
            message: "Intermittent provider failure",
            category: :provider_error,
            retriable?: true
          }}
       end
     end}
  end

  @doc """
  Creates a rate-limited provider behavior.

  Succeeds for first N requests, then returns rate limit errors.

  ## Parameters

  - `requests_before_limit` - Number of successful requests before rate limiting kicks in

  ## Example

      behavior = rate_limited_provider(10)
      # First 10 requests succeed, then rate limit errors
  """
  def rate_limited_provider(requests_before_limit \\ 10) do
    {:conditional,
     fn method, params, state ->
       if state.call_count < requests_before_limit do
         {:ok, mock_response(method, params)}
       else
         {:error,
          %JError{
            code: -32_005,
            message: "Rate limit exceeded",
            category: :rate_limit,
            retriable?: true,
            data: %{
              "retry_after_ms" => 1000
            }
          }}
       end
     end}
  end

  @doc """
  Creates a node out-of-sync behavior.

  Returns stale block numbers for a recovery period, then catches up.

  ## Parameters

  - `lag_blocks` - How many blocks behind to lag (default: 10)
  - `recovery_time_ms` - How long until node catches up (default: 30_000)

  ## Example

      behavior = node_out_of_sync(5, 10_000)
      # Returns blocks 5 behind current for 10 seconds, then catches up
  """
  def node_out_of_sync(lag_blocks \\ 10, recovery_time_ms \\ 30_000) do
    {:conditional,
     fn method, _params, state ->
       elapsed = System.monotonic_time(:millisecond) - state.start_time

       if method == "eth_blockNumber" do
         current_block = 1000 + div(elapsed, 1000)

         block_num =
           if elapsed < recovery_time_ms do
             # Still lagging
             current_block - lag_blocks
           else
             # Caught up
             current_block
           end

         {:ok, "0x#{Integer.to_string(block_num, 16)}"}
       else
         {:ok, mock_response(method, [])}
       end
     end}
  end

  @doc """
  Creates a cascading failure behavior.

  Provider starts healthy, degrades under load, fails, then recovers.

  ## Options

  - `:healthy_duration` - Initial healthy period (default: 5000ms)
  - `:degraded_duration` - Degraded performance period (default: 10_000ms)
  - `:failed_duration` - Complete failure period (default: 5000ms)
  - `:recovery_duration` - Recovery period (default: 5000ms)

  ## Phases

  1. Healthy: Normal operation
  2. Degraded: Slow responses, intermittent failures
  3. Failed: All requests fail
  4. Recovery: Gradual return to normal

  ## Example

      behavior = cascading_failure(
        healthy_duration: 10_000,
        degraded_duration: 20_000,
        failed_duration: 10_000
      )
  """
  def cascading_failure(opts \\ []) do
    healthy_duration = Keyword.get(opts, :healthy_duration, 5_000)
    degraded_duration = Keyword.get(opts, :degraded_duration, 10_000)
    failed_duration = Keyword.get(opts, :failed_duration, 5_000)
    recovery_duration = Keyword.get(opts, :recovery_duration, 5_000)

    {:conditional,
     fn method, params, state ->
       elapsed = System.monotonic_time(:millisecond) - state.start_time

       cond do
         # Phase 1: Healthy
         elapsed < healthy_duration ->
           {:ok, mock_response(method, params)}

         # Phase 2: Degraded (slow + intermittent failures)
         elapsed < healthy_duration + degraded_duration ->
           latency = 500 + :rand.uniform(1000)
           Process.sleep(latency)

           if :rand.uniform() < 0.7 do
             {:ok, mock_response(method, params)}
           else
             {:error,
              %JError{
                code: -32_603,
                message: "Service degraded",
                category: :provider_error,
                retriable?: true
              }}
           end

         # Phase 3: Complete failure
         elapsed < healthy_duration + degraded_duration + failed_duration ->
           {:error,
            %JError{
              code: -32_000,
              message: "Service unavailable",
              category: :provider_error,
              retriable?: false
            }}

         # Phase 4: Recovery
         elapsed < healthy_duration + degraded_duration + failed_duration + recovery_duration ->
           # Gradually improving success rate
           recovery_progress =
             (elapsed - (healthy_duration + degraded_duration + failed_duration)) /
               recovery_duration

           if :rand.uniform() < recovery_progress do
             {:ok, mock_response(method, params)}
           else
             {:error,
              %JError{
                code: -32_603,
                message: "Still recovering",
                category: :provider_error,
                retriable?: true
              }}
           end

         # Fully recovered
         true ->
           {:ok, mock_response(method, params)}
       end
     end}
  end

  @doc """
  Creates a method-specific behavior.

  Different methods can have different behaviors.

  ## Example

      behavior = method_specific(%{
        "eth_blockNumber" => :healthy,
        "eth_getBalance" => intermittent_failures(0.5),
        "eth_call" => :always_timeout
      })
  """
  def method_specific(method_behaviors) do
    default_behavior = Map.get(method_behaviors, :default, :healthy)

    {:conditional,
     fn method, params, state ->
       behavior = Map.get(method_behaviors, method, default_behavior)
       execute_behavior(behavior, method, params, state)
     end}
  end

  @doc """
  Creates a parameter-sensitive behavior.

  Behavior changes based on request parameters.

  ## Example

      behavior = parameter_sensitive(fn _method, params, _state ->
        case params do
          [%{"address" => addresses}] when length(addresses) > 100 ->
            {:error, %JError{code: -32_005, message: "Too many addresses"}}

          _ ->
            {:ok, mock_response("eth_getLogs", params)}
        end
      end)
  """
  def parameter_sensitive(sensitivity_fun) when is_function(sensitivity_fun, 3) do
    {:conditional, sensitivity_fun}
  end

  # Private helper: Generate mock responses

  defp mock_response("eth_blockNumber", _params) do
    block_num = :rand.uniform(1_000_000)
    "0x#{Integer.to_string(block_num, 16)}"
  end

  defp mock_response("eth_gasPrice", _params) do
    gas_price = :rand.uniform(100_000_000_000)
    "0x#{Integer.to_string(gas_price, 16)}"
  end

  defp mock_response("eth_getBalance", [_address, _block]) do
    balance = :rand.uniform(1_000_000_000_000_000_000)
    "0x#{Integer.to_string(balance, 16)}"
  end

  defp mock_response("eth_call", _params) do
    # Return mock call result (unwrapped)
    "0x0000000000000000000000000000000000000000000000000000000000000001"
  end

  defp mock_response("eth_getLogs", _params) do
    # Return empty logs array (unwrapped)
    []
  end

  defp mock_response("eth_getBlockByNumber", _params) do
    # Return unwrapped block object
    %{
      "number" => "0x#{Integer.to_string(:rand.uniform(1_000_000), 16)}",
      "hash" => "0x#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}",
      "timestamp" => "0x#{Integer.to_string(:os.system_time(:second), 16)}"
    }
  end

  defp mock_response(_method, _params) do
    # Generic successful response (unwrapped)
    "0x1"
  end
end
