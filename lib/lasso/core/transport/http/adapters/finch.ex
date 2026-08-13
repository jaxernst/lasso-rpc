defmodule Lasso.RPC.Transport.HTTP.Client.Finch do
  @moduledoc """
  Finch-based implementation of `Lasso.RPC.Transport.HTTP.Client`.
  """

  @behaviour Lasso.RPC.Transport.HTTP.Client
  require Logger

  alias Finch.HTTP1.Conn
  alias Lasso.Core.Support.AttemptLifecycle
  alias Lasso.Providers.ProviderHeaders
  alias Lasso.URLMask

  @impl true
  def deferred_dispatch?, do: true

  @impl true
  def request(%{url: url} = provider, method, params, opts) do
    # Extract options with defaults
    request_id = Keyword.get(opts, :request_id) || generate_id()
    timeout_ms = Keyword.get(opts, :timeout, 30_000)
    finch_name = Keyword.get(opts, :finch_name, Lasso.Finch)

    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => request_id
    }

    dispatch_context = Keyword.get(opts, :attempt_dispatch)

    with {:ok, json} <- encode_body(body, dispatch_context),
         headers <- base_headers(provider),
         {:ok, req} <- build_request(url, headers, json, dispatch_context),
         {:ok, %Finch.Response{status: status, body: resp_body}} <-
           finch_request(
             req,
             timeout_ms,
             dispatch_context,
             finch_name
           ) do
      handle_response(status, resp_body)
    else
      {:error, {:encode_error, _reason} = encode_error} ->
        {:error, encode_error}

      {:error, {:request_build_error, _reason} = build_error} ->
        {:error, build_error}

      {:error, {:local_capacity_rejection, _reason} = local_rejection} ->
        {:error, local_rejection}

      {:error, %Finch.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      # Handle NimblePool checkout errors specifically
      {:error, {:exit, {{:shutdown, :idle_timeout}, {NimblePool, :checkout, _}}}} ->
        Logger.warning("Finch connection pool idle timeout",
          provider_url: URLMask.mask(url),
          request_id: request_id
        )

        # Emit telemetry for monitoring
        :telemetry.execute(
          [:lasso, :finch, :pool_idle_timeout],
          %{count: 1},
          %{provider_url: URLMask.mask(url), request_id: request_id}
        )

        {:error, {:local_capacity_rejection, :pool_idle_timeout}}

      # Handle other NimblePool errors
      {:error, {:exit, {{:shutdown, reason}, {NimblePool, :checkout, _}}}} ->
        Logger.warning("Finch connection pool checkout failed",
          provider_url: URLMask.mask(url),
          request_id: request_id,
          shutdown_reason: reason
        )

        # Emit telemetry for monitoring
        :telemetry.execute(
          [:lasso, :finch, :pool_checkout_failed],
          %{count: 1},
          %{provider_url: URLMask.mask(url), request_id: request_id, reason: reason}
        )

        {:error, {:local_capacity_rejection, {:pool_checkout_failed, reason}}}

      {:error, %Finch.TransportError{reason: reason}} ->
        Logger.debug("Finch request failed - Mint transport error",
          provider_url: URLMask.mask(url),
          request_id: request_id,
          reason: reason
        )

        message =
          case reason do
            :timeout -> "Connection timeout"
            :closed -> "Connection closed"
            :econnrefused -> "Connection refused"
            :nxdomain -> "DNS resolution failed"
            {:error, reason} when is_atom(reason) -> "Connection error: #{reason}"
            _ -> "Connection error"
          end

        {:error, {:network_error, message}}

      {:error, reason} ->
        Logger.debug("Finch request failed",
          provider_url: URLMask.mask(url),
          request_id: request_id,
          error: inspect(reason)
        )

        {:error, {:network_error, "Request failed: #{inspect(reason)}"}}
    end
  end

  defp base_headers(provider), do: ProviderHeaders.build(provider)

  defp encode_body(body, dispatch_context) do
    case Jason.encode(body) do
      {:ok, json} ->
        {:ok, json}

      {:error, reason} ->
        AttemptLifecycle.abort_dispatch(dispatch_context)
        {:error, {:encode_error, Exception.message(reason)}}
    end
  end

  defp build_request(url, headers, json, dispatch_context) do
    {:ok, Finch.build(:post, url, headers, json)}
  rescue
    error ->
      AttemptLifecycle.abort_dispatch(dispatch_context)
      {:error, {:request_build_error, Exception.message(error)}}
  end

  defp finch_request(request, timeout_ms, dispatch_context, finch_name) do
    pool = %Finch.Pool{
      scheme: request.scheme,
      host: request.host,
      port: request.port,
      tag: request.pool_tag
    }

    request_opts = [
      pool_timeout: timeout_ms,
      receive_timeout: timeout_ms,
      request_timeout: :infinity
    ]

    case Finch.Pool.Manager.get_pool(finch_name, pool, request_opts) do
      {pool_pid, Finch.HTTP1.Pool} ->
        http1_request(pool_pid, request, request_opts, dispatch_context, finch_name)

      {_pool_pid, _pool_module} ->
        {:error, {:local_capacity_rejection, :unsupported_http_protocol}}

      _unavailable ->
        {:error, {:local_capacity_rejection, :pool_not_available}}
    end
  rescue
    error in RuntimeError ->
      if String.contains?(Exception.message(error), "unable to provide a connection") do
        {:error, {:local_capacity_rejection, :pool_checkout_timeout}}
      else
        reraise(error, __STACKTRACE__)
      end
  catch
    :exit, {:timeout, {NimblePool, :checkout, _affected_pids}} ->
      {:error, {:local_capacity_rejection, :pool_checkout_timeout}}

    :exit, {{:shutdown, :idle_timeout}, {NimblePool, :checkout, _affected_pids}} ->
      {:error, {:local_capacity_rejection, :pool_idle_timeout}}
  end

  defp http1_request(pool, request, opts, dispatch_context, finch_name) do
    pool_timeout = Keyword.fetch!(opts, :pool_timeout)
    receive_timeout = Keyword.fetch!(opts, :receive_timeout)
    request_timeout = Keyword.fetch!(opts, :request_timeout)
    acc = {nil, [], [], []}

    response =
      NimblePool.checkout!(
        pool,
        :checkout,
        fn from, {checkout_state, conn, idle_time} ->
          case AttemptLifecycle.mark_dispatched(dispatch_context) do
            :ok ->
              execute_http1_request(
                conn,
                {checkout_state, idle_time, from},
                request,
                acc,
                {receive_timeout, request_timeout, finch_name}
              )

            {:error, :cancelled} ->
              result = {:error, {:local_capacity_rejection, :dispatch_cancelled}, acc}
              {result, transfer_if_open(conn, checkout_state, from)}
          end
        end,
        pool_timeout
      )

    case response do
      {:ok, {status, headers, body, trailers}} ->
        {:ok,
         %Finch.Response{
           status: status,
           headers: headers,
           body: IO.iodata_to_binary(body),
           trailers: trailers
         }}

      {:error, error, _acc} ->
        {:error, error}
    end
  end

  defp execute_http1_request(
         conn,
         {checkout_state, idle_time, from},
         request,
         acc,
         {receive_timeout, request_timeout, finch_name}
       ) do
    result =
      case Conn.connect(conn, finch_name) do
        {:ok, conn} ->
          Conn.request(
            conn,
            request,
            acc,
            &collect_response/2,
            finch_name,
            receive_timeout,
            request_timeout,
            idle_time
          )
          |> case do
            {:ok, conn, response_acc} -> {:ok, conn, response_acc}
            {:error, conn, error, response_acc} -> {:error, conn, error, response_acc}
          end

        {:error, conn, error} ->
          {:error, conn, error, acc}
      end

    case result do
      {:ok, conn, response_acc} ->
        {{:ok, response_acc}, transfer_if_open(conn, checkout_state, from)}

      {:error, conn, error, response_acc} ->
        {{:error, error, response_acc}, transfer_if_open(conn, checkout_state, from)}
    end
  end

  defp collect_response({:status, value}, {_, headers, body, trailers}),
    do: {:cont, {value, headers, body, trailers}}

  defp collect_response({:headers, value}, {status, headers, body, trailers}),
    do: {:cont, {status, headers ++ value, body, trailers}}

  defp collect_response({:data, value}, {status, headers, body, trailers}),
    do: {:cont, {status, headers, [body | value], trailers}}

  defp collect_response({:trailers, value}, {status, headers, body, trailers}),
    do: {:cont, {status, headers, body, trailers ++ value}}

  defp transfer_if_open(conn, checkout_state, {pid, _tag} = from) do
    if Conn.open?(conn) do
      if checkout_state == :fresh do
        NimblePool.update(from, conn)

        case Conn.transfer(conn, pid) do
          {:ok, conn} -> {:ok, conn}
          {:error, _conn, _reason} -> :closed
        end
      else
        {:ok, conn}
      end
    else
      :closed
    end
  end

  defp handle_response(status, body) when status in 200..299 do
    # Return raw bytes for passthrough optimization
    # The caller (HTTP transport) will parse using Response.from_bytes/1
    {:ok, {:raw, body}}
  end

  defp handle_response(429, body), do: {:error, {:rate_limit, %{status: 429, body: body}}}

  # Treat 408 Request Timeout as retriable infrastructure failure
  defp handle_response(408, body), do: {:error, {:server_error, %{status: 408, body: body}}}

  defp handle_response(status, body) when status >= 500,
    do: {:error, {:server_error, %{status: status, body: body}}}

  defp handle_response(status, body), do: {:error, {:client_error, %{status: status, body: body}}}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
