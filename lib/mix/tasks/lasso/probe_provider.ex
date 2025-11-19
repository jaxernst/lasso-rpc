defmodule Mix.Tasks.Lasso.ProbeProvider do
  use Mix.Task
  require Logger

  @shortdoc "Probe an RPC provider to discover supported methods"

  @moduledoc """
  Probes an Ethereum RPC provider to discover which methods are supported.

  This is a **development tool** for creating and maintaining adapter implementations.
  It is NOT used at runtime.

  ## Usage

      # Direct mode - probe any provider URL
      mix lasso.probe_provider <provider_url> [options]

      # Pipeline mode - test configured providers through Lasso's request pipeline
      mix lasso.probe_provider --pipeline <provider_id|chain_name> [options]

  ## Options

    * `--level <level>` - Probe level (default: standard)
      - critical: Core methods only (~10 methods)
      - standard: Common methods (~25 methods)
      - full: All standard methods (~70 methods)

    * `--timeout <ms>` - Request timeout in milliseconds (default: 3000)

    * `--output <format>` - Output format (default: table)
      - table: Human-readable table
      - json: JSON output
      - adapter: Generate adapter skeleton

    * `--chain <name>` - Chain name for context (default: ethereum)

    * `--concurrent <n>` - Concurrent requests (default: 5)

    * `--pipeline` - Use Lasso's request pipeline (tests adapters, error classification)
      - Requires provider_id (e.g., "alchemy_ethereum") or chain name (e.g., "ethereum")
      - Shows adapter validation, error classification, and mismatch detection
      - Only works for providers configured in chains.yml

  ## Examples

      # Direct mode - probe any provider URL
      mix lasso.probe_provider https://eth-mainnet.alchemyapi.io/v2/KEY

      # Direct mode - full probe with JSON output
      mix lasso.probe_provider https://ethereum.publicnode.com \\
        --level full \\
        --output json

      # Pipeline mode - test single configured provider
      mix lasso.probe_provider --pipeline alchemy_ethereum

      # Pipeline mode - test all providers for a chain
      mix lasso.probe_provider --pipeline ethereum --level full

      # Generate adapter skeleton from direct probe
      mix lasso.probe_provider https://api.mycustomprovider.io \\
        --level full \\
        --output adapter \\
        --chain ethereum

  ## Output

  ### Direct Mode
  The task will probe each method and report:
  - ✅ Supported: Method returned valid response
  - ❌ Unsupported: Method returned -32601 (method not found)
  - ⚠️  Unknown: Method returned other error or timed out

  ### Pipeline Mode
  Enhanced output includes:
  - Adapter name and validation results
  - Error classification details (category, retriable?, breaker_penalty?)
  - Adapter mismatches (adapter blocks but provider supports, or vice versa)
  - Real-world JError struct details
  - Recommendations for adapter tuning

  Results include:
  - Support status for each method
  - Response times
  - Error details
  - Recommended adapter configuration
  """

  @levels %{
    critical: [:core],
    standard: [:core, :state, :network, :eip1559, :mempool],
    full: [:core, :state, :network, :eip1559, :eip4844, :mempool,
           :filters, :subscriptions, :batch, :debug, :trace]
  }

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args,
      strict: [
        level: :string,
        timeout: :integer,
        output: :string,
        chain: :string,
        concurrent: :integer,
        pipeline: :boolean
      ],
      aliases: [l: :level, t: :timeout, o: :output, c: :chain]
    )

    pipeline_mode = Keyword.get(opts, :pipeline, false)

    cond do
      # Pipeline mode - probe configured providers
      pipeline_mode && length(args) > 0 ->
        probe_pipeline(List.first(args), opts)

      # Direct mode - probe any URL
      !pipeline_mode && length(args) > 0 ->
        probe_provider(List.first(args), opts)

      # No arguments
      true ->
        Mix.shell().error("Usage: mix lasso.probe_provider <provider_url|provider_id> [options]")
        Mix.shell().info("\nRun `mix help lasso.probe_provider` for details")
    end
  end

  defp probe_provider(url, opts) do
    # Start Lasso application (which starts Finch pool)
    Mix.Task.run("app.start")

    # Ensure required applications are started
    {:ok, _} = Application.ensure_all_started(:jason)

    level = Keyword.get(opts, :level, "standard") |> String.to_existing_atom()
    timeout = Keyword.get(opts, :timeout, 3000)
    output_format = Keyword.get(opts, :output, "table") |> String.to_existing_atom()
    chain = Keyword.get(opts, :chain, "ethereum")
    concurrent = Keyword.get(opts, :concurrent, 5)

    Mix.shell().info("🔍 Probing provider: #{url}")
    Mix.shell().info("📊 Level: #{level}")
    Mix.shell().info("⏱️  Timeout: #{timeout}ms")
    Mix.shell().info("")

    # Get methods to probe
    methods = get_probe_methods(level)

    Mix.shell().info("Testing #{length(methods)} methods...\n")

    # Probe concurrently
    results =
      methods
      |> Task.async_stream(
        fn method -> probe_method(url, method, timeout) end,
        max_concurrency: concurrent,
        timeout: timeout + 1000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> %{status: :timeout, duration: timeout, error: "Timeout"}
      end)
      |> Enum.zip(methods)
      |> Enum.map(fn {result, method} ->
        Map.put(result, :method, method)
      end)

    # Output results
    case output_format do
      :table -> output_table(results)
      :json -> output_json(results)
      :adapter -> output_adapter_skeleton(results, url, chain)
      _ -> Mix.shell().error("Unknown output format: #{output_format}")
    end
  end

  defp probe_pipeline(identifier, opts) do
    # Start Lasso application
    Mix.Task.run("app.start")

    {:ok, _} = Application.ensure_all_started(:jason)

    level = Keyword.get(opts, :level, "standard") |> String.to_existing_atom()
    timeout = Keyword.get(opts, :timeout, 3000)
    output_format = Keyword.get(opts, :output, "table") |> String.to_existing_atom()
    concurrent = Keyword.get(opts, :concurrent, 5)

    # Load chain configuration
    {:ok, config} = Lasso.Config.ChainConfig.load_config()

    # Determine if identifier is a chain name or provider ID
    providers = resolve_providers(config, identifier)

    if Enum.empty?(providers) do
      Mix.shell().error("No providers found for identifier: #{identifier}")
      Mix.shell().info("Available chains: #{Map.keys(config.chains) |> Enum.join(", ")}")
      :error
    else
      # Get methods to probe
      methods = get_probe_methods(level)

      # Probe each provider
      Enum.each(providers, fn {chain_name, provider} ->
        probe_provider_pipeline(provider, chain_name, methods, timeout, concurrent, output_format)
      end)
    end
  end

  defp resolve_providers(config, identifier) do
    # Try as chain name first
    case Map.get(config.chains, identifier) do
      nil ->
        # Try as provider ID - search all chains
        config.chains
        |> Enum.flat_map(fn {chain_name, chain_config} ->
          case Lasso.Config.ChainConfig.get_provider_by_id(chain_config, identifier) do
            {:ok, provider} -> [{chain_name, provider}]
            {:error, _} -> []
          end
        end)

      chain_config ->
        # Return all providers for this chain
        chain_config.providers
        |> Enum.map(fn provider -> {identifier, provider} end)
    end
  end

  defp probe_provider_pipeline(provider, chain_name, methods, timeout, concurrent, output_format) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("🔍 Pipeline Probe: #{provider.name}")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("Provider ID: #{provider.id}")
    Mix.shell().info("Chain: #{chain_name}")
    Mix.shell().info("URL: #{provider.url}")

    # Get adapter module
    adapter = Lasso.RPC.Providers.AdapterRegistry.adapter_for(provider.id)
    adapter_name = adapter |> Module.split() |> List.last()

    Mix.shell().info("Adapter: #{adapter_name}")
    Mix.shell().info("⏱️  Timeout: #{timeout}ms")
    Mix.shell().info("")
    Mix.shell().info("Testing #{length(methods)} methods...\n")

    # Build context for adapter validation
    ctx = %{
      provider_id: provider.id,
      chain: chain_name,
      adapter_config: provider.adapter_config || %{}
    }

    # Probe concurrently through pipeline
    results =
      methods
      |> Task.async_stream(
        fn method ->
          probe_method_pipeline(provider, adapter, method, timeout, ctx)
        end,
        max_concurrency: concurrent,
        timeout: timeout + 1000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> %{status: :timeout, duration: timeout, error: "Timeout"}
      end)
      |> Enum.zip(methods)
      |> Enum.map(fn {result, method} ->
        Map.put(result, :method, method)
      end)

    # Output results
    case output_format do
      :table -> output_pipeline_table(results, adapter_name)
      :json -> output_json(results)
      _ -> Mix.shell().error("Unknown output format: #{output_format}")
    end

    Mix.shell().info("")
  end

  defp probe_method_pipeline(provider, adapter, method, timeout, ctx) do
    start_time = System.monotonic_time(:millisecond)

    # Phase 1: Check if adapter supports method
    adapter_supports = adapter.supports_method?(method, :http, ctx)

    case adapter_supports do
      :ok ->
        # Phase 2: Validate params
        params = minimal_params_for(method)

        case adapter.validate_params(method, params, :http, ctx) do
          :ok ->
            # Phase 3: Make actual request
            result = Lasso.RPC.HttpClient.request(
              %{url: provider.url},
              method,
              params,
              timeout: timeout
            )

            duration = System.monotonic_time(:millisecond) - start_time

            # Phase 4: Normalize and classify response
            process_pipeline_result(result, adapter, method, duration, ctx)

          {:error, reason} ->
            duration = System.monotonic_time(:millisecond) - start_time

            %{
              status: :adapter_blocked,
              duration: duration,
              adapter_reason: reason,
              phase: :param_validation
            }
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time

        %{
          status: :adapter_blocked,
          duration: duration,
          adapter_reason: reason,
          phase: :method_support
        }
    end
  end

  defp process_pipeline_result(result, adapter, _method, duration, ctx) do
    case result do
      {:ok, %{"result" => _result}} ->
        %{status: :supported, duration: duration}

      {:ok, %{"error" => error_map}} when is_map(error_map) ->
        # Normalize error through adapter
        jerror = adapter.normalize_error(error_map, ctx)

        # Get provider-specific classification
        provider_classification = adapter.classify_error(jerror.code, jerror.message)

        # Determine actual category (provider classification or default)
        actual_category =
          case provider_classification do
            {:ok, cat} -> cat
            :default -> jerror.category
          end

        status =
          cond do
            jerror.code == -32601 -> :unsupported
            jerror.code == -32602 -> :supported
            true -> :error
          end

        %{
          status: status,
          duration: duration,
          error: jerror.message,
          error_code: jerror.code,
          category: actual_category,
          retriable: jerror.retriable?,
          breaker_penalty: jerror.breaker_penalty?,
          provider_classification: provider_classification
        }

      {:error, reason} ->
        %{status: :error, duration: duration, error: inspect(reason)}
    end
  end

  defp get_probe_methods(level) do
    categories = Map.get(@levels, level, @levels.standard)

    categories
    |> Enum.flat_map(&Lasso.RPC.MethodRegistry.category_methods/1)
  end

  defp probe_method(url, method, timeout) do
    params = minimal_params_for(method)
    provider_config = %{url: url}

    start_time = System.monotonic_time(:millisecond)

    result = Lasso.RPC.HttpClient.request(
      provider_config,
      method,
      params,
      timeout: timeout
    )

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{"error" => %{"code" => -32601}}} ->
        %{status: :unsupported, duration: duration, error: "Method not found"}

      {:ok, %{"error" => %{"code" => -32602}}} ->
        %{status: :supported, duration: duration, note: "Invalid params (method exists)"}

      {:ok, %{"result" => _}} ->
        %{status: :supported, duration: duration}

      {:ok, %{"error" => %{"code" => code, "message" => message}}} ->
        %{status: :unknown, duration: duration, error: message, error_code: code}

      {:ok, %{"error" => error}} when is_map(error) ->
        # Fallback for errors without standard structure
        message = Map.get(error, "message", inspect(error))
        code = Map.get(error, "code", :unknown)
        %{status: :unknown, duration: duration, error: message, error_code: code}

      {:error, {reason, _payload}} ->
        %{status: :unknown, duration: duration, error: "#{reason}"}

      {:error, reason} ->
        %{status: :unknown, duration: duration, error: inspect(reason)}
    end
  end

  defp minimal_params_for("eth_blockNumber"), do: []
  defp minimal_params_for("eth_chainId"), do: []
  defp minimal_params_for("eth_gasPrice"), do: []
  defp minimal_params_for("eth_call"), do: [
    %{to: "0x0000000000000000000000000000000000000000", data: "0x"},
    "latest"
  ]
  defp minimal_params_for("eth_estimateGas"), do: [
    %{to: "0x0000000000000000000000000000000000000000", data: "0x"}
  ]
  defp minimal_params_for("eth_getBalance"), do: [
    "0x0000000000000000000000000000000000000000",
    "latest"
  ]
  defp minimal_params_for("eth_getCode"), do: [
    "0x0000000000000000000000000000000000000000",
    "latest"
  ]
  defp minimal_params_for("eth_getTransactionCount"), do: [
    "0x0000000000000000000000000000000000000000",
    "latest"
  ]
  defp minimal_params_for("eth_getStorageAt"), do: [
    "0x0000000000000000000000000000000000000000",
    "0x0",
    "latest"
  ]
  defp minimal_params_for("eth_getTransactionByHash"), do: [
    "0x" <> String.duplicate("0", 64)
  ]
  defp minimal_params_for("eth_getTransactionReceipt"), do: [
    "0x" <> String.duplicate("0", 64)
  ]
  defp minimal_params_for("eth_getBlockByNumber"), do: ["latest", false]
  defp minimal_params_for("eth_getBlockByHash"), do: [
    "0x" <> String.duplicate("0", 64),
    false
  ]
  defp minimal_params_for("eth_getLogs"), do: [
    %{fromBlock: "latest", toBlock: "latest"}
  ]
  defp minimal_params_for("eth_newFilter"), do: [
    %{fromBlock: "latest", toBlock: "latest"}
  ]
  defp minimal_params_for("eth_getFilterChanges"), do: ["0x1"]
  defp minimal_params_for("eth_getFilterLogs"), do: ["0x1"]
  defp minimal_params_for("eth_uninstallFilter"), do: ["0x1"]
  defp minimal_params_for("eth_getBlockReceipts"), do: ["latest"]
  defp minimal_params_for("eth_feeHistory"), do: [4, "latest", []]
  defp minimal_params_for("debug_traceTransaction"), do: [
    "0x" <> String.duplicate("0", 64),
    %{}
  ]
  defp minimal_params_for("debug_traceBlockByNumber"), do: ["latest", %{}]
  defp minimal_params_for("trace_block"), do: ["latest"]
  defp minimal_params_for("trace_transaction"), do: [
    "0x" <> String.duplicate("0", 64)
  ]

  # State methods
  defp minimal_params_for("eth_getProof"), do: [
    "0x0000000000000000000000000000000000000000",  # address
    [],  # storage keys
    "latest"  # block
  ]

  # Network methods
  defp minimal_params_for("net_version"), do: []
  defp minimal_params_for("net_listening"), do: []
  defp minimal_params_for("net_peerCount"), do: []
  defp minimal_params_for("web3_clientVersion"), do: []
  defp minimal_params_for("web3_sha3"), do: ["0x68656c6c6f"]  # "hello" in hex
  defp minimal_params_for("eth_protocolVersion"), do: []
  defp minimal_params_for("eth_syncing"), do: []

  # Uncle methods (need valid hashes, but zeros will get -32602 which is fine)
  defp minimal_params_for("eth_getBlockTransactionCountByHash"), do: [
    "0x" <> String.duplicate("0", 64)
  ]
  defp minimal_params_for("eth_getBlockTransactionCountByNumber"), do: ["latest"]
  defp minimal_params_for("eth_getUncleCountByBlockHash"), do: [
    "0x" <> String.duplicate("0", 64)
  ]
  defp minimal_params_for("eth_getUncleCountByBlockNumber"), do: ["latest"]
  defp minimal_params_for("eth_getUncleByBlockHashAndIndex"), do: [
    "0x" <> String.duplicate("0", 64),
    "0x0"
  ]
  defp minimal_params_for("eth_getUncleByBlockNumberAndIndex"), do: [
    "latest",
    "0x0"
  ]
  defp minimal_params_for("eth_getTransactionByBlockHashAndIndex"), do: [
    "0x" <> String.duplicate("0", 64),
    "0x0"
  ]
  defp minimal_params_for("eth_getTransactionByBlockNumberAndIndex"), do: [
    "latest",
    "0x0"
  ]

  # EIP-1559
  defp minimal_params_for("eth_maxPriorityFeePerGas"), do: []

  # EIP-4844
  defp minimal_params_for("eth_getBlobBaseFee"), do: []

  # Mempool
  defp minimal_params_for("eth_sendRawTransaction"), do: [
    "0x"  # Invalid tx, but method exists check
  ]

  # Subscriptions
  defp minimal_params_for("eth_subscribe"), do: ["newHeads"]
  defp minimal_params_for("eth_unsubscribe"), do: ["0x1"]

  # Filters
  defp minimal_params_for("eth_newBlockFilter"), do: []
  defp minimal_params_for("eth_newPendingTransactionFilter"), do: []

  defp minimal_params_for(_), do: []

  defp output_table(results) do
    # Group by category
    by_category =
      results
      |> Enum.group_by(fn r ->
        Lasso.RPC.MethodRegistry.method_category(r.method)
      end)

    # Print summary
    supported = Enum.count(results, &(&1.status == :supported))
    unsupported = Enum.count(results, &(&1.status == :unsupported))
    unknown = Enum.count(results, &(&1.status == :unknown))

    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("SUMMARY")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("✅ Supported:   #{supported}")
    Mix.shell().info("❌ Unsupported: #{unsupported}")
    Mix.shell().info("⚠️  Unknown:     #{unknown}")
    Mix.shell().info("")

    # Print by category
    Enum.each(by_category, fn {category, methods} ->
      Mix.shell().info("#{category |> to_string() |> String.upcase()}")
      Mix.shell().info("-" |> String.duplicate(80))

      Enum.each(methods, fn result ->
        icon = case result.status do
          :supported -> "✅"
          :unsupported -> "❌"
          :unknown -> "⚠️"
          :timeout -> "⏱️"
        end

        duration_str = if result[:duration], do: " (#{result.duration}ms)", else: ""

        # Format error with code if available
        error_str = cond do
          result[:note] -> " - #{result.note}"
          result[:error] && result[:error_code] -> " - [#{result.error_code}] #{result.error}"
          result[:error] -> " - #{result.error}"
          true -> ""
        end

        Mix.shell().info(
          "  #{icon} #{String.pad_trailing(result.method, 40)} " <>
          "#{duration_str}#{error_str}"
        )
      end)

      Mix.shell().info("")
    end)

    # Recommendations
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("RECOMMENDATIONS")
    Mix.shell().info("=" |> String.duplicate(80))

    unsupported_methods =
      results
      |> Enum.filter(&(&1.status == :unsupported))
      |> Enum.map(&(&1.method))

    unsupported_categories =
      unsupported_methods
      |> Enum.map(&Lasso.RPC.MethodRegistry.method_category/1)
      |> Enum.uniq()
      |> Enum.filter(fn cat ->
        category_methods = Lasso.RPC.MethodRegistry.category_methods(cat)
        unsupported_in_cat = Enum.count(category_methods, &(&1 in unsupported_methods))
        # If >80% of category unsupported, recommend blocking whole category
        unsupported_in_cat / length(category_methods) > 0.8
      end)

    if length(unsupported_categories) > 0 do
      Mix.shell().info("Block entire categories:")
      Enum.each(unsupported_categories, fn cat ->
        Mix.shell().info("  - :#{cat}")
      end)
      Mix.shell().info("")
    end

    remaining_unsupported =
      unsupported_methods
      |> Enum.reject(fn method ->
        Lasso.RPC.MethodRegistry.method_category(method) in unsupported_categories
      end)

    if length(remaining_unsupported) > 0 do
      Mix.shell().info("Block specific methods:")
      Enum.each(remaining_unsupported, fn method ->
        Mix.shell().info("  - \"#{method}\"")
      end)
    end
  end

  defp output_pipeline_table(results, adapter_name) do
    # Group by category
    by_category =
      results
      |> Enum.group_by(fn r ->
        Lasso.RPC.MethodRegistry.method_category(r.method)
      end)

    # Print summary
    supported = Enum.count(results, &(&1.status == :supported))
    unsupported = Enum.count(results, &(&1.status == :unsupported))
    adapter_blocked = Enum.count(results, &(&1.status == :adapter_blocked))
    errors = Enum.count(results, &(&1.status == :error))
    unknown = Enum.count(results, &(&1.status == :unknown))

    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("SUMMARY")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("✅ Supported:       #{supported}")
    Mix.shell().info("❌ Unsupported:     #{unsupported}")
    Mix.shell().info("🚫 Adapter Blocked: #{adapter_blocked}")
    Mix.shell().info("⚠️  Errors:          #{errors}")

    if unknown > 0 do
      Mix.shell().info("❓ Unknown:         #{unknown}")
    end

    Mix.shell().info("")

    # Print by category
    Enum.each(by_category, fn {category, methods} ->
      Mix.shell().info("#{category |> to_string() |> String.upcase()}")
      Mix.shell().info("-" |> String.duplicate(80))

      Enum.each(methods, fn result ->
        icon =
          case result.status do
            :supported -> "✅"
            :unsupported -> "❌"
            :adapter_blocked -> "🚫"
            :error -> "⚠️"
            :timeout -> "⏱️"
            :unknown -> "❓"
          end

        duration_str = if result[:duration], do: " (#{result.duration}ms)", else: ""

        # Build detailed error/info string
        detail_str =
          cond do
            result[:status] == :adapter_blocked ->
              phase_name =
                case result[:phase] do
                  :method_support -> "method support"
                  :param_validation -> "param validation"
                  _ -> "unknown phase"
                end

              reason_str = format_adapter_reason(result[:adapter_reason])
              " - Blocked by #{adapter_name} (#{phase_name}): #{reason_str}"

            result[:status] == :supported && result[:error_code] == -32602 ->
              " - Invalid params (method exists)"

            result[:category] ->
              classification_str =
                case result[:provider_classification] do
                  {:ok, cat} -> " [Provider: #{cat}]"
                  :default -> ""
                end

              retriable_str = if result[:retriable], do: " | Retriable", else: ""

              breaker_str =
                if result[:breaker_penalty], do: " | Breaker Penalty", else: " | No Penalty"

              " - [#{result[:error_code]}] #{result[:error]}\n" <>
                "      Category: #{result[:category]}#{classification_str}#{retriable_str}#{breaker_str}"

            result[:error] ->
              " - #{result[:error]}"

            true ->
              ""
          end

        Mix.shell().info(
          "  #{icon} #{String.pad_trailing(result.method, 40)} " <>
            "#{duration_str}#{detail_str}"
        )
      end)

      Mix.shell().info("")
    end)

    # Adapter Mismatch Detection
    detect_adapter_mismatches(results, adapter_name)

    # Recommendations
    output_pipeline_recommendations(results)
  end

  defp format_adapter_reason(reason) when is_atom(reason) do
    reason |> to_string() |> String.replace("_", " ")
  end

  defp format_adapter_reason({:param_limit, message}) when is_binary(message) do
    "param limit - #{message}"
  end

  defp format_adapter_reason({:requires_archival, message}) when is_binary(message) do
    "requires archival - #{message}"
  end

  defp format_adapter_reason(reason), do: inspect(reason)

  defp detect_adapter_mismatches(results, adapter_name) do
    # Find methods where adapter blocks but provider supports
    false_negatives =
      results
      |> Enum.filter(fn r ->
        r.status == :adapter_blocked
      end)

    # Find methods where adapter allows but provider doesn't support
    false_positives =
      results
      |> Enum.filter(fn r ->
        r.status == :unsupported
      end)

    if length(false_negatives) > 0 or length(false_positives) > 0 do
      Mix.shell().info("=" |> String.duplicate(80))
      Mix.shell().info("ADAPTER MISMATCH DETECTION")
      Mix.shell().info("=" |> String.duplicate(80))

      if length(false_positives) > 0 do
        Mix.shell().info("⚠️  Adapter too permissive (allows methods that provider doesn't support):")

        Enum.each(false_positives, fn r ->
          Mix.shell().info("  - #{r.method}")
        end)

        Mix.shell().info(
          "\n  Recommendation: Add to #{adapter_name} unsupported_methods or unsupported_categories\n"
        )
      end

      if length(false_negatives) > 0 do
        Mix.shell().info("⚠️  Adapter too restrictive (blocks methods that provider supports):")

        Enum.each(false_negatives, fn r ->
          reason = format_adapter_reason(r[:adapter_reason])
          phase = if r[:phase] == :param_validation, do: " [param validation]", else: ""
          Mix.shell().info("  - #{r.method}#{phase} (#{reason})")
        end)

        Mix.shell().info(
          "\n  Recommendation: Review #{adapter_name} validation rules - provider may support these\n"
        )
      end
    end
  end

  defp output_pipeline_recommendations(results) do
    # Find capability violations that might need adapter tuning
    capability_violations =
      results
      |> Enum.filter(fn r ->
        r[:category] == :capability_violation
      end)

    if length(capability_violations) > 0 do
      Mix.shell().info("=" |> String.duplicate(80))
      Mix.shell().info("CAPABILITY VIOLATION RECOMMENDATIONS")
      Mix.shell().info("=" |> String.duplicate(80))

      Enum.each(capability_violations, fn r ->
        Mix.shell().info("Method: #{r.method}")
        Mix.shell().info("  Error: [#{r[:error_code]}] #{r[:error]}")

        provider_class =
          case r[:provider_classification] do
            {:ok, cat} -> "#{cat}"
            :default -> "generic capability_violation"
          end

        Mix.shell().info("  Classification: #{provider_class}")
        Mix.shell().info("")
      end)

      Mix.shell().info(
        "Consider adding adapter validation rules for these capability violations\n"
      )
    end
  end

  defp output_json(results) do
    json = Jason.encode!(results, pretty: true)
    Mix.shell().info(json)
  end

  defp output_adapter_skeleton(results, url, chain) do
    # Derive provider name from URL
    provider_name =
      URI.parse(url).host
      |> String.split(".")
      |> Enum.at(-2)
      |> Macro.camelize()

    unsupported_methods =
      results
      |> Enum.filter(&(&1.status == :unsupported))
      |> Enum.map(&(&1.method))

    unsupported_categories =
      unsupported_methods
      |> Enum.map(&Lasso.RPC.MethodRegistry.method_category/1)
      |> Enum.uniq()
      |> Enum.filter(fn cat ->
        category_methods = Lasso.RPC.MethodRegistry.category_methods(cat)
        unsupported_in_cat = Enum.count(category_methods, &(&1 in unsupported_methods))
        unsupported_in_cat / length(category_methods) > 0.8
      end)

    remaining_unsupported =
      unsupported_methods
      |> Enum.reject(fn method ->
        Lasso.RPC.MethodRegistry.method_category(method) in unsupported_categories
      end)

    skeleton = """
    defmodule Lasso.RPC.Providers.Adapters.#{provider_name} do
      @moduledoc \"\"\"
      Adapter for #{provider_name} RPC provider.

      Generated from probe results on #{Date.utc_today()}
      Chain: #{chain}
      URL: #{url}
      \"\"\"

      @behaviour Lasso.RPC.ProviderAdapter

      alias Lasso.RPC.{MethodRegistry, Providers.Generic}

      @impl true
      def supports_method?(method, _transport, _context) do
        category = MethodRegistry.method_category(method)

        cond do
          # Unsupported categories
          category in #{inspect(unsupported_categories)} ->
            {:error, :method_unsupported}

          # Unsupported methods
          method in #{inspect(remaining_unsupported)} ->
            {:error, :method_unsupported}

          # All other methods supported
          true ->
            :ok
        end
      end

      @impl true
      def validate_params(_method, _params, _transport, _context) do
        # TODO: Add parameter validation if needed
        # Example: eth_getLogs block range limits
        :ok
      end

      @impl true
      def classify_error(_code, _message) do
        # TODO: Add provider-specific error classification
        :default
      end

      @impl true
      defdelegate normalize_request(req, ctx), to: Generic

      @impl true
      defdelegate normalize_response(resp, ctx), to: Generic

      @impl true
      defdelegate normalize_error(err, ctx), to: Generic

      @impl true
      defdelegate headers(ctx), to: Generic

      @impl true
      def metadata do
        %{
          type: :unknown,  # TODO: Set to :paid | :public | :dedicated
          tier: :unknown,  # TODO: Set to :free | :paid | :enterprise
          known_limitations: [
            # TODO: Document known limitations from provider docs
          ],
          unsupported_categories: #{inspect(unsupported_categories)},
          unsupported_methods: #{inspect(remaining_unsupported)},
          conditional_support: %{
            # TODO: Add methods with parameter restrictions
            # "eth_getLogs" => "Max 2000 block range"
          },
          last_verified: ~D[#{Date.utc_today()}]
        }
      end
    end
    """

    Mix.shell().info(skeleton)

    # Write to file suggestion
    filename = "lib/lasso/rpc/providers/adapters/#{Macro.underscore(provider_name)}.ex"
    Mix.shell().info("\n💾 Save to: #{filename}")
  end
end
