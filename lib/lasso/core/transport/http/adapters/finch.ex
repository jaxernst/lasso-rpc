defmodule Lasso.RPC.Transport.HTTP.Client.Finch do
  @moduledoc """
  HTTP client adapter using Finch.
  """

  @behaviour Lasso.RPC.Transport.HTTP.Client

  alias Lasso.Core.Transport.{AttemptProtocol, UpstreamAdmission}
  alias Lasso.Core.Transport.HTTP.DispatchTracker
  alias Lasso.Providers.ProviderHeaders
  alias Lasso.RPC.PreparedRequest

  @minimum_timeout_us 1_000

  @impl true
  def deferred_dispatch?, do: true

  @doc "Executes and consumes non-routing HTTP work while its response lease remains held."
  @spec bounded_request(Finch.Request.t(), keyword(), (term() -> term())) :: term()
  def bounded_request(%Finch.Request{} = request, opts, consumer)
      when is_list(opts) and is_function(consumer, 1) do
    timeout_ms = Keyword.get(opts, :timeout, Keyword.get(opts, :receive_timeout, 30_000))
    deadline_us = Keyword.get(opts, :deadline_us) || deadline_from_timeout(timeout_ms)
    finch_name = Keyword.get(opts, :finch_name, Lasso.Finch)
    request = %{request | headers: put_identity_encoding(request.headers)}

    with {:ok, request_options} <- request_options(deadline_us, nil, opts),
         {:ok, lease} <- acquire_admission(request, nil, opts) do
      try do
        request
        |> stream_request(finch_name, request_options, lease)
        |> consumer.()
      after
        UpstreamAdmission.release(lease, :bounded_request_finished)
      end
    end
  end

  @doc false
  @spec prepare_provider(map()) :: map()
  def prepare_provider(%{url: url} = provider) do
    template = Finch.build(:post, url, bounded_headers(provider), nil)
    Map.put(provider, :lasso_finch_template, template)
  rescue
    _error -> provider
  end

  @impl true
  def request(%{url: url} = provider, method, params, opts) do
    request_id = Keyword.get(opts, :request_id) || generate_id()
    timeout_ms = Keyword.get(opts, :timeout, 30_000)
    deadline_us = Keyword.get(opts, :deadline_us) || deadline_from_timeout(timeout_ms)
    finch_name = Keyword.get(opts, :finch_name, Lasso.Finch)
    context = Keyword.get(opts, :attempt_dispatch)

    body = %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => request_id}

    with {:ok, json} <- encode_body(body, context) do
      request_encoded(provider, url, json, context, deadline_us, finch_name, opts)
    end
  end

  @impl true
  def request_prepared(
        %{url: url} = provider,
        %PreparedRequest{encoded: encoded},
        opts
      ) do
    timeout_ms = Keyword.get(opts, :timeout, 30_000)
    deadline_us = Keyword.get(opts, :deadline_us) || deadline_from_timeout(timeout_ms)
    finch_name = Keyword.get(opts, :finch_name, Lasso.Finch)
    context = Keyword.get(opts, :attempt_dispatch)

    request_encoded(provider, url, encoded, context, deadline_us, finch_name, opts)
  end

  defp request_encoded(provider, url, encoded, context, deadline_us, finch_name, opts) do
    with {:ok, request} <-
           build_request(provider, url, encoded, context),
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

  defp build_request(%{lasso_finch_template: %Finch.Request{} = template}, _url, json, context) do
    request = %{
      template
      | body: json,
        private: Map.put(template.private, :lasso_attempt, context)
    }

    {:ok, request}
  end

  defp build_request(provider, url, json, context) do
    request =
      :post
      |> Finch.build(url, bounded_headers(provider), json)
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
    case acquire_admission(request, context, opts) do
      {:ok, lease} ->
        result =
          run_admitted_request(
            request,
            finch_name,
            deadline_us,
            context,
            tracker_token,
            opts,
            lease
          )

        case result do
          {:ok, {:raw, _body, ^lease}} = retained ->
            retained

          other ->
            UpstreamAdmission.release(lease, :request_finished)
            other
        end

      {:error, reason} ->
        AttemptProtocol.predispatch_failure(context, :local)
        {:error, {:local_capacity_rejection, reason}}
    end
  end

  defp run_admitted_request(request, finch_name, deadline_us, context, tracker_token, opts, lease) do
    DispatchTracker.begin_attempt(context, tracker_token)

    case request_options(deadline_us, context, opts) do
      {:ok, request_options} ->
        with :ok <- DispatchTracker.open_send(context, tracker_token),
             :ok <- final_deadline_gate(deadline_us, context, opts) do
          io_start_us = System.monotonic_time(:microsecond)

          outcome =
            try do
              {:returned, finch_request(request, finch_name, request_options, opts, lease)}
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
          io_duration_us = max(System.monotonic_time(:microsecond) - io_start_us, 0)

          handle_request_outcome(
            {outcome, dispatch_state, tracker_healthy?},
            context,
            lease,
            io_duration_us
          )
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

  defp finch_request(request, finch_name, request_options, opts, lease) do
    case Keyword.get(opts, :request_fun) do
      nil ->
        stream_request(request, finch_name, request_options, lease)

      request_fun when is_function(request_fun, 3) ->
        case request_fun.(request, finch_name, request_options) do
          {:ok, %Finch.Response{body: body} = response} when is_binary(body) ->
            case UpstreamAdmission.reserve_response(lease, byte_size(body), 2) do
              :ok -> {:ok, response}
              {:error, reason} -> {:error, {:response_limit, reason}}
            end

          other ->
            other
        end
    end
  end

  defp stream_request(request, finch_name, request_options, lease) do
    response_limit = UpstreamAdmission.response_limit(lease.admission)

    initial = %{
      body: [],
      error: nil,
      headers: [],
      status: nil,
      trailers: []
    }

    stream_fun = fn
      {:status, status}, acc ->
        {:cont, %{acc | status: status}}

      {:headers, headers}, acc ->
        case validate_response_headers(headers, response_limit) do
          :ok ->
            {:cont, %{acc | headers: acc.headers ++ headers}}

          {:error, reason} ->
            _ = UpstreamAdmission.reject_response(lease, reason)
            {:halt, %{acc | error: reason}}
        end

      {:data, data}, acc ->
        case UpstreamAdmission.reserve_response(lease, byte_size(data), 2) do
          :ok -> {:cont, %{acc | body: [data | acc.body]}}
          {:error, reason} -> {:halt, %{acc | error: reason}}
        end

      {:trailers, trailers}, acc ->
        {:cont, %{acc | trailers: acc.trailers ++ trailers}}
    end

    case Finch.stream_while(request, finch_name, initial, stream_fun, request_options) do
      {:ok, %{error: nil} = acc} ->
        {:ok,
         %Finch.Response{
           status: acc.status,
           headers: acc.headers,
           body: acc.body |> Enum.reverse() |> IO.iodata_to_binary(),
           trailers: acc.trailers
         }}

      {:ok, %{error: reason}} ->
        {:error, {:response_limit, reason}}

      {:error, error, %{error: nil}} ->
        {:error, error}

      {:error, _error, %{error: reason}} ->
        {:error, {:response_limit, reason}}
    end
  end

  defp acquire_admission(request, context, opts) do
    capacity_key = {request.scheme, String.downcase(request.host), request.port}

    upstream_instance_id =
      case Keyword.get(opts, :upstream_instance_id) do
        instance_id when is_binary(instance_id) -> instance_id
        _missing -> unscoped_instance_id(capacity_key)
      end

    metadata = %{
      method_class: Keyword.get(opts, :method_class, :system),
      transport: :http,
      tracked_attempt?: not is_nil(context)
    }

    UpstreamAdmission.acquire(capacity_key, upstream_instance_id,
      admission: Keyword.get(opts, :admission, UpstreamAdmission),
      metadata: metadata
    )
  end

  defp unscoped_instance_id(capacity_key) do
    suffix =
      capacity_key
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "unscoped-http:#{suffix}"
  end

  defp validate_response_headers(headers, response_limit) do
    content_encodings = header_values(headers, "content-encoding")

    content_lengths =
      headers |> header_values("content-length") |> split_header_tokens()

    transfer_encodings =
      headers |> header_values("transfer-encoding") |> split_header_tokens()

    cond do
      Enum.any?(content_encodings, &(String.downcase(String.trim(&1)) not in ["", "identity"])) ->
        {:error, :compressed_response}

      transfer_encodings not in [[], ["chunked"]] ->
        {:error, :compressed_response}

      transfer_encodings != [] and content_lengths != [] ->
        {:error, :ambiguous_framing}

      true ->
        validate_content_lengths(content_lengths, response_limit)
    end
  end

  defp validate_content_lengths(lengths, response_limit) do
    Enum.reduce_while(lengths, {:ok, nil}, fn value, {:ok, expected} ->
      case Integer.parse(value) do
        {length, ""} when length >= 0 and length <= response_limit ->
          if expected in [nil, length],
            do: {:cont, {:ok, length}},
            else: {:halt, {:error, :conflicting_content_length}}

        {length, ""} when length > response_limit ->
          {:halt, {:error, :response_too_large}}

        _malformed ->
          {:halt, {:error, :malformed_content_length}}
      end
    end)
    |> case do
      {:ok, _length} -> :ok
      error -> error
    end
  end

  defp split_header_tokens(values) do
    Enum.flat_map(values, fn value ->
      value
      |> :binary.split(",", [:global])
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    end)
  end

  defp header_values(headers, wanted_name) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == wanted_name, do: [value], else: []

      _invalid ->
        []
    end)
  end

  defp handle_request_outcome(
         {{:returned, {:ok, %Finch.Response{status: status, body: body}}}, _state, _healthy?},
         context,
         lease,
         _io_duration_us
       ) do
    case handle_response(status, body) do
      {:error, reason} = error ->
        AttemptProtocol.terminal(context, :transport_failure, %{
          reason: http_status_reason(reason),
          certainty: :dispatched
        })

        error

      {:ok, {:raw, raw_body}} ->
        if is_nil(context),
          do: {:ok, {:raw, raw_body}},
          else: {:ok, {:raw, raw_body, lease}}
    end
  end

  defp handle_request_outcome(
         {{:returned, {:error, {:response_limit, reason}}}, _state, _healthy?},
         context,
         _lease,
         io_duration_us
       ) do
    AttemptProtocol.terminal(context, :response, %{
      response_kind: :error,
      error_code: -32_005,
      error_category: :local_capacity_rejection,
      io_duration_us: io_duration_us
    })

    {:error, {:response_limit, reason}}
  end

  defp handle_request_outcome(
         {{:returned, {:error, reason}}, dispatch_state, tracker_healthy?},
         context,
         _lease,
         _io_duration_us
       ) do
    certainty = dispatch_certainty(dispatch_state, tracker_healthy?)
    emit_failure(context, reason, certainty)
    normalize_finch_error(reason)
  end

  defp handle_request_outcome(
         {{:raised, error}, dispatch_state, tracker_healthy?},
         context,
         _lease,
         _io_duration_us
       ) do
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
         context,
         _lease,
         _io_duration_us
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

  defp bounded_headers(provider) do
    provider
    |> ProviderHeaders.build()
    |> put_identity_encoding()
  end

  defp put_identity_encoding(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(to_string(name)) == "accept-encoding"
    end) ++ [{"accept-encoding", "identity"}]
  end

  defp deadline_from_timeout(timeout_ms),
    do: System.monotonic_time(:microsecond) + timeout_ms * 1_000

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
