defmodule Lasso.Test.AnvilCase do
  @moduledoc """
  Test helpers for opt-in local Anvil integration tests.

  The case starts one Anvil node per test module on a dynamic localhost port and
  temporarily switches Lasso's test transports from deterministic mocks to the
  real Finch/Mint clients for each test.
  """

  use ExUnit.CaseTemplate

  alias Lasso.Config.ChainConfig.Provider

  @default_chain_id 31_337
  @wait_attempts 60
  @wait_interval_ms 100
  @start_attempts 3

  using opts do
    quote do
      import Lasso.Test.AnvilCase

      @moduletag :integration
      @moduletag :anvil
      if is_nil(System.find_executable("anvil")),
        do: @moduletag(skip: "anvil executable not found")

      @anvil_chain_id 31_337

      setup_all do
        anvil =
          Lasso.Test.AnvilCase.start_anvil_node!(
            name: :primary,
            chain_id: @anvil_chain_id,
            prune_history: unquote(Keyword.get(opts, :prune_history, true))
          )

        {:ok, anvil_node: anvil, anvil_port: anvil.port_number, anvil_chain_id: anvil.chain_id}
      end

      setup do
        prior_http_client = Lasso.Test.AnvilCase.capture_app_env(:lasso, :http_client)
        prior_ws_client = Lasso.Test.AnvilCase.capture_app_env(:lasso, :ws_client_module)

        prior_origin_resolver =
          Lasso.Test.AnvilCase.capture_app_env(:lasso, :custom_origin_resolver)

        Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

        Application.put_env(
          :lasso,
          :ws_client_module,
          Lasso.RPC.Transport.WebSocket.Client
        )

        Application.put_env(:lasso, :custom_origin_resolver, fn _host ->
          {:ok, [{127, 0, 0, 1}]}
        end)

        on_exit(fn ->
          Lasso.Test.AnvilCase.restore_app_env(:lasso, :http_client, prior_http_client)
          Lasso.Test.AnvilCase.restore_app_env(:lasso, :ws_client_module, prior_ws_client)

          Lasso.Test.AnvilCase.restore_app_env(
            :lasso,
            :custom_origin_resolver,
            prior_origin_resolver
          )
        end)

        :ok
      end
    end
  end

  def capture_app_env(app, key), do: Application.get_env(app, key, :__missing__)

  def restore_app_env(app, key, :__missing__), do: Application.delete_env(app, key)
  def restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  def free_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_addr, port_number}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port_number
  end

  def start_anvil!(anvil_port, chain_id) do
    start_anvil_node!(port: anvil_port, chain_id: chain_id).port
  end

  def stop_anvil(port_or_node), do: stop_anvil_node(port_or_node)

  def start_anvil_node!(opts \\ []) do
    executable = System.find_executable("anvil")

    if is_nil(executable) do
      ExUnit.Assertions.flunk("anvil executable not found")
    end

    # `free_port!` releases the port before anvil binds it, so a racing process
    # can steal it and anvil exits on bind failure. When the port was chosen for
    # us, retry on a fresh port; an explicitly requested port cannot be retried.
    explicit_port? = Keyword.has_key?(opts, :port)
    start_anvil_node!(executable, opts, explicit_port?, @start_attempts)
  end

  defp start_anvil_node!(executable, opts, explicit_port?, attempts_left) do
    chain_id = Keyword.get(opts, :chain_id, @default_chain_id)
    host = Keyword.get(opts, :host, "127.0.0.1")
    port_number = Keyword.get(opts, :port, free_port!())
    name = Keyword.get(opts, :name, "anvil-#{System.unique_integer([:positive])}")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args:
          [
            "--host",
            host,
            "--port",
            Integer.to_string(port_number),
            "--chain-id",
            Integer.to_string(chain_id),
            "--block-time",
            "1"
          ] ++ if(Keyword.get(opts, :prune_history, true), do: ["--prune-history"], else: [])
      ])

    node = %{
      name: name,
      host: host,
      port_number: port_number,
      chain_id: chain_id,
      port: port,
      os_pid: os_pid_from_port(port)
    }

    case wait_for_anvil(node) do
      :ok ->
        ExUnit.Callbacks.on_exit(fn -> stop_anvil_node(node) end)
        node

      {:error, reason} ->
        stop_anvil_node(node)

        if attempts_left > 1 and not explicit_port? do
          start_anvil_node!(executable, opts, explicit_port?, attempts_left - 1)
        else
          ExUnit.Assertions.flunk("Anvil failed to start: #{inspect(reason)}")
        end
    end
  end

  def stop_anvil_node(%{port: port} = node) do
    do_stop_anvil_node(port, os_pid_from_port(port) || Map.get(node, :os_pid))
  end

  def stop_anvil_node(port) when is_port(port) do
    do_stop_anvil_node(port, os_pid_from_port(port))
  end

  def stop_anvil_node(_), do: :ok

  # Closing the Erlang port does not terminate the anvil OS process (anvil does
  # not exit when its stdin/stdout pipes close), so without an explicit signal
  # every node leaks as an orphan that holds its port. Kill the OS process while
  # the port still owns it, then close the port.
  defp do_stop_anvil_node(port, os_pid) do
    kill_os_process(os_pid)

    if is_port(port) and Port.info(port) do
      Port.close(port)
      wait_for_port_close(port, 20)
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp os_pid_from_port(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  defp os_pid_from_port(_), do: nil

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  catch
    _, _ -> :ok
  end

  def restart_anvil_node!(node, opts \\ [])

  def restart_anvil_node!(%{port: port} = node, opts) do
    stop_anvil_node(port)

    new_port = Keyword.get(opts, :port, node.port_number)

    restarted =
      start_anvil_node!(
        name: node.name,
        host: node.host,
        port: new_port,
        chain_id: node.chain_id
      )

    %{node | port: restarted.port, port_number: restarted.port_number, os_pid: restarted.os_pid}
  end

  def rpc_call!(node_or_port, method, params \\ [], id \\ 1)

  def rpc_call!(%{} = node, method, params, id) do
    rpc_call!(node.host, node.port_number, method, params, id)
  end

  def rpc_call!(port_number, method, params, id) when is_integer(port_number) do
    rpc_call!("127.0.0.1", port_number, method, params, id)
  end

  def rpc_call!(host, port_number, method, params, id) do
    body = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params, id: id})

    response =
      Finch.build(
        :post,
        "http://#{host}:#{port_number}",
        [{"content-type", "application/json"}],
        body
      )
      |> Finch.request!(Lasso.Finch)

    if response.status != 200 do
      ExUnit.Assertions.flunk("Anvil RPC #{method} failed with HTTP #{response.status}")
    end

    Jason.decode!(response.body)
  end

  def anvil_provider(%{} = node, opts \\ []) do
    provider_id = Keyword.get(opts, :id, to_string(node.name))

    %Provider{
      id: provider_id,
      name: Keyword.get(opts, :name, "Anvil #{provider_id}"),
      priority: Keyword.get(opts, :priority, 1),
      url: Keyword.get(opts, :url, "http://#{node.host}:#{node.port_number}"),
      ws_url: Keyword.get(opts, :ws_url, "ws://#{node.host}:#{node.port_number}"),
      archival: Keyword.get(opts, :archival, true),
      subscribe_new_heads: Keyword.get(opts, :subscribe_new_heads, true)
    }
  end

  def anvil_providers(nodes, opts \\ []) when is_list(nodes) do
    id_prefix = Keyword.get(opts, :id_prefix, "anvil")

    nodes
    |> Enum.with_index(1)
    |> Enum.map(fn {node, idx} ->
      anvil_provider(node,
        id: "#{id_prefix}-#{idx}",
        name: "Anvil #{idx}",
        priority: idx
      )
    end)
  end

  defp wait_for_anvil(node), do: wait_for_anvil(node, @wait_attempts)

  defp wait_for_anvil(_node, 0), do: {:error, :not_ready}

  defp wait_for_anvil(
         %{host: host, port_number: port_number, chain_id: chain_id} = node,
         attempts
       ) do
    expected = "0x" <> String.downcase(Integer.to_string(chain_id, 16))

    case safe_chain_id(host, port_number) do
      {:ok, result} ->
        if String.downcase(result) == expected do
          :ok
        else
          retry_wait_for_anvil(node, attempts)
        end

      _ ->
        retry_wait_for_anvil(node, attempts)
    end
  end

  defp retry_wait_for_anvil(%{port: port} = node, attempts) do
    receive do
      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      @wait_interval_ms -> wait_for_anvil(node, attempts - 1)
    end
  end

  defp safe_chain_id(host, port_number) do
    body = Jason.encode!(%{jsonrpc: "2.0", method: "eth_chainId", params: [], id: 1})

    case Finch.build(
           :post,
           "http://#{host}:#{port_number}",
           [{"content-type", "application/json"}],
           body
         )
         |> Finch.request(Lasso.Finch) do
      {:ok, %Finch.Response{status: 200, body: response}} ->
        case Jason.decode(response) do
          {:ok, %{"result" => result}} when is_binary(result) -> {:ok, result}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp wait_for_port_close(_port, 0), do: :ok

  defp wait_for_port_close(port, attempts) do
    if Port.info(port) do
      Process.sleep(25)
      wait_for_port_close(port, attempts - 1)
    else
      :ok
    end
  end
end
