defmodule Lasso.RPC.Transport.HTTP.Client.Finch do
  @moduledoc """
  HTTP client adapter using Finch.
  """

  @behaviour Lasso.RPC.Transport.HTTP.Client

  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.Core.Transport.HTTP.DispatchTracker
  alias Lasso.Providers.ProviderHeaders

  @minimum_timeout_us 1_000

  @impl true
  def deferred_dispatch?, do: true

  @impl true
  def request(%{url: url} = provider, method, params, opts) do
    request_id = Keyword.get(opts, :request_id) || generate_id()
    timeout_ms = Keyword.get(opts, :timeout, 30_000)
    deadline_us = Keyword.get(opts, :deadline_us) || deadline_from_timeout(timeout_ms)
    finch_name = Keyword.get(opts, :finch_name, Lasso.Finch)
    context = Keyword.get(opts, :attempt_dispatch)

    body = %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => request_id}

    with {:ok, json} <- encode_body(body, context),
         {:ok, request} <- build_request(url, ProviderHeaders.build(provider), json, context),
         {:ok, tracker_token} <- tracker_token(context) do
      run_request(request, finch_name, deadline_us, context, tracker_token, opts)
    end
  end

  defp encode_body(body, context) do
    case Jason.encode(body) do
      {:ok, json} ->
        {:ok, json}

      {:error, reason} ->
        AttemptProtocol.predispatch_failure(context, :encode_error)
        {:error, {:encode_error, Exception.message(reason)}}
    end
  end

  defp build_request(url, headers, json, context) do
    request =
      :post
      |> Finch.build(url, headers, json)
      |> Finch.Request.put_private(:lasso_attempt, context)

    {:ok, request}
  rescue
    error ->
      AttemptProtocol.predispatch_failure(context, :request_build_error)
      {:error, {:request_build_error, Exception.message(error)}}
  end

  defp tracker_token(nil), do: {:ok, nil}

  defp tracker_token(context) do
    case DispatchTracker.ready_token() do
      {:ok, token} ->
        {:ok, token}

      {:error, :unavailable} ->
        AttemptProtocol.predispatch_failure(context, :tracker_unavailable)
        {:error, {:local_capacity_rejection, :dispatch_tracker_unavailable}}
    end
  end

  defp request_options(deadline_us, context, opts) do
    monotonic_now =
      Keyword.get(opts, :monotonic_now_fun, fn -> System.monotonic_time(:microsecond) end)

    remaining_us = deadline_us - monotonic_now.()

    if remaining_us >= @minimum_timeout_us do
      remaining_ms = div(remaining_us, 1_000)

      {:ok,
       [
         pool_timeout: remaining_ms,
         receive_timeout: remaining_ms,
         request_timeout: remaining_ms
       ]}
    else
      AttemptProtocol.predispatch_failure(context, :deadline)
      {:error, {:local_capacity_rejection, :deadline}}
    end
  end

  defp run_request(request, finch_name, deadline_us, context, tracker_token, opts) do
    DispatchTracker.begin_attempt(context, tracker_token)

    case request_options(deadline_us, context, opts) do
      {:ok, request_options} ->
        with :ok <- DispatchTracker.open_send(context, tracker_token),
             :ok <- final_deadline_gate(deadline_us, context, opts) do
          outcome =
            try do
              {:returned, finch_request(request, finch_name, request_options, opts)}
            rescue
              error -> {:raised, error}
            catch
              kind, reason -> {:caught, kind, reason}
            end

          dispatch_state = DispatchTracker.attempt_state(context)

          tracker_healthy? =
            is_nil(context) or dispatch_state != :not_started or
              DispatchTracker.session_healthy?(tracker_token)

          DispatchTracker.clear_attempt(context)
          handle_request_outcome({outcome, dispatch_state, tracker_healthy?}, context)
        else
          {:error, reason} ->
            DispatchTracker.clear_attempt(context)
            send_start_error(reason, context)
        end

      {:error, _reason} = error ->
        DispatchTracker.clear_attempt(context)
        error
    end
  end

  defp final_deadline_gate(deadline_us, _context, opts) do
    monotonic_now =
      Keyword.get(opts, :monotonic_now_fun, fn -> System.monotonic_time(:microsecond) end)

    if monotonic_now.() < deadline_us, do: :ok, else: {:error, :deadline_expired}
  end

  defp send_start_error(:deadline_expired, context) do
    AttemptProtocol.predispatch_failure(context, :deadline)
    {:error, {:local_capacity_rejection, :deadline}}
  end

  defp send_start_error(:owner_down, context) do
    AttemptProtocol.predispatch_failure(context, :local)
    {:error, {:local_capacity_rejection, :dispatch_cancelled}}
  end

  defp finch_request(request, finch_name, request_options, opts) do
    case Keyword.get(opts, :request_fun) do
      nil ->
        Finch.request(request, finch_name, request_options)

      request_fun when is_function(request_fun, 3) ->
        request_fun.(request, finch_name, request_options)
    end
  end

  defp handle_request_outcome(
         {{:returned, {:ok, %Finch.Response{status: status, body: body}}}, _state, _healthy?},
         context
       ) do
    case handle_response(status, body) do
      {:error, reason} = error ->
        AttemptProtocol.terminal(context, :transport_failure, %{
          reason: http_status_reason(reason),
          certainty: :dispatched
        })

        error

      success ->
        success
    end
  end

  defp handle_request_outcome(
         {{:returned, {:error, reason}}, dispatch_state, tracker_healthy?},
         context
       ) do
    certainty = dispatch_certainty(dispatch_state, tracker_healthy?)
    emit_failure(context, reason, certainty)
    normalize_finch_error(reason)
  end

  defp handle_request_outcome({{:raised, error}, dispatch_state, tracker_healthy?}, context) do
    certainty = dispatch_certainty(dispatch_state, tracker_healthy?)
    emit_failure(context, error, certainty)

    if certainty == :not_dispatched do
      {:error, {:local_capacity_rejection, :pool_checkout_timeout}}
    else
      {:error, {:network_error, "Request failed"}}
    end
  end

  defp handle_request_outcome(
         {{:caught, _kind, reason}, dispatch_state, tracker_healthy?},
         context
       ) do
    certainty = dispatch_certainty(dispatch_state, tracker_healthy?)
    emit_failure(context, reason, certainty)

    if certainty == :not_dispatched do
      {:error, {:local_capacity_rejection, :pool_unavailable}}
    else
      {:error, {:network_error, "Request failed"}}
    end
  end

  defp dispatch_certainty(:confirmed, _tracker_healthy?), do: :dispatched
  defp dispatch_certainty(:started, _tracker_healthy?), do: :indeterminate
  defp dispatch_certainty(:not_started, true), do: :not_dispatched
  defp dispatch_certainty(:not_started, false), do: :indeterminate

  defp emit_failure(context, _reason, :not_dispatched) do
    AttemptProtocol.predispatch_failure(context, :pool_unavailable)
  end

  defp emit_failure(context, reason, certainty) do
    AttemptProtocol.terminal(context, :transport_failure, %{
      reason: transport_reason(reason),
      certainty: certainty
    })
  end

  defp normalize_finch_error(%Finch.TransportError{reason: :timeout}), do: {:error, :timeout}

  defp normalize_finch_error(%Finch.TransportError{reason: reason}),
    do: {:error, {:network_error, transport_message(reason)}}

  defp normalize_finch_error(%Finch.Error{reason: reason}),
    do: {:error, {:local_capacity_rejection, reason}}

  defp normalize_finch_error(%Finch.HTTPError{}),
    do: {:error, {:network_error, "HTTP protocol error"}}

  defp normalize_finch_error(reason), do: {:error, reason}

  defp transport_reason(%Finch.TransportError{reason: :timeout}), do: :timeout
  defp transport_reason(%Finch.TransportError{reason: :nxdomain}), do: :dns
  defp transport_reason(%Finch.TransportError{reason: :closed}), do: :closed
  defp transport_reason(%Finch.HTTPError{}), do: :protocol
  defp transport_reason(_reason), do: :connection

  defp transport_message(:closed), do: "Connection closed"
  defp transport_message(:econnrefused), do: "Connection refused"
  defp transport_message(:nxdomain), do: "DNS resolution failed"
  defp transport_message(reason) when is_atom(reason), do: "Connection error: #{reason}"
  defp transport_message(_reason), do: "Connection error"

  defp handle_response(status, body) when status in 200..299, do: {:ok, {:raw, body}}
  defp handle_response(429, body), do: {:error, {:rate_limit, %{status: 429, body: body}}}
  defp handle_response(408, body), do: {:error, {:server_error, %{status: 408, body: body}}}

  defp handle_response(status, body) when status >= 500,
    do: {:error, {:server_error, %{status: status, body: body}}}

  defp handle_response(status, body), do: {:error, {:client_error, %{status: status, body: body}}}

  defp http_status_reason({:rate_limit, _body}), do: :rate_limited
  defp http_status_reason({:server_error, _body}), do: :server_error
  defp http_status_reason({:client_error, _body}), do: :client_error

  defp deadline_from_timeout(timeout_ms),
    do: System.monotonic_time(:microsecond) + timeout_ms * 1_000

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
