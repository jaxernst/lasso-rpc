defmodule Mix.Tasks.Lasso.Probe do
  use Mix.Task
  require Logger

  @shortdoc "Probe an RPC provider to discover capabilities, limits, and WebSocket support"

  @moduledoc """
  Unified tool to probe RPC providers for supported methods, limits, and WebSocket capabilities.

  ## Usage

      mix lasso.probe <provider_url> [options]

  ## Options

    * `--probes <list>` - Comma-separated list of probes to run (default: all)
      - methods: HTTP method support detection
      - limits: Provider limits (block range, batch size, etc.)
      - websocket: WebSocket connection and subscription support

    * `--level <level>` - Method probe level (default: standard)
      - critical: Core methods only (~10 methods)
      - standard: Common methods (~25 methods)
      - full: All standard methods (~70 methods)

    * `--timeout <ms>` - Request timeout in milliseconds (default: 10000)

    * `--output <format>` - Output format (default: table)
      - table: Human-readable table
      - json: JSON output for programmatic use

    * `--chain <name>` - Chain name for context (default: ethereum)

    * `--concurrent <n>` - Max concurrent requests (default: 5)

    * `--subscription-wait <ms>` - Time to wait for WebSocket events (default: 15000)

  ## Examples

      # Full probe (all probes)
      mix lasso.probe https://eth-mainnet.alchemyapi.io/v2/KEY

      # Methods and limits only
      mix lasso.probe https://eth-mainnet.alchemyapi.io/v2/KEY --probes methods,limits

      # WebSocket probe only
      mix lasso.probe wss://eth-mainnet.alchemyapi.io/v2/KEY --probes websocket

      # Full probe with JSON output
      mix lasso.probe https://ethereum.publicnode.com --output json

  ## Output

  The task will probe each capability and report:
  - Method support with status icons
  - Limit discovery with recommendations
  - WebSocket connection and subscription support

  Results include adapter configuration recommendations.
  """

  @valid_probes [:methods, :limits, :websocket]
  @valid_levels [:critical, :standard, :full]
  @valid_outputs [:table, :json]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        strict: [
          probes: :string,
          level: :string,
          timeout: :integer,
          output: :string,
          chain: :string,
          concurrent: :integer,
          subscription_wait: :integer
        ],
        aliases: [
          p: :probes,
          l: :level,
          t: :timeout,
          o: :output,
          c: :chain
        ]
      )

    if length(args) == 0 do
      Mix.shell().error("Usage: mix lasso.probe <provider_url> [options]")
      Mix.shell().info("\nRun `mix help lasso.probe` for details")
      System.halt(1)
    end

    # Start only minimal dependencies (not full web server)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:finch)

    # Start Finch pool for HTTP requests (same name as main app uses)
    case Finch.start_link(name: Lasso.Finch) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    url = List.first(args)
    probes = parse_probes(Keyword.get(opts, :probes, "methods,limits,websocket"))
    level = parse_level(Keyword.get(opts, :level, "standard"))
    timeout = Keyword.get(opts, :timeout, 10_000)
    output = parse_output(Keyword.get(opts, :output, "table"))
    chain = Keyword.get(opts, :chain, "ethereum")
    concurrent = Keyword.get(opts, :concurrent, 5)
    subscription_wait = Keyword.get(opts, :subscription_wait, 15_000)

    # Print header
    print_header(url, probes, level, timeout)

    # Run discovery
    results =
      Lasso.Discovery.probe(url,
        probes: probes,
        method_level: level,
        timeout: timeout,
        chain: chain,
        concurrent: concurrent,
        subscription_wait: subscription_wait
      )

    # Format and output results
    output_str =
      Lasso.Discovery.Formatter.format(results,
        format: output,
        chain: chain
      )

    Mix.shell().info(output_str)
  end

  defp parse_probes(probes_str) do
    probes_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
    |> Enum.filter(&(&1 in @valid_probes))
    |> case do
      [] ->
        Mix.shell().info("No valid probes specified, using all probes")
        @valid_probes

      probes ->
        probes
    end
  end

  defp parse_level(level_str) do
    level = String.to_atom(level_str)

    if level in @valid_levels do
      level
    else
      Mix.shell().info("Invalid level '#{level_str}', using :standard")
      :standard
    end
  end

  defp parse_output(output_str) do
    output = String.to_atom(output_str)

    if output in @valid_outputs do
      output
    else
      Mix.shell().info("Invalid output '#{output_str}', using :table")
      :table
    end
  end

  defp print_header(url, probes, level, timeout) do
    probes_str = Enum.map(probes, &Atom.to_string/1) |> Enum.join(", ")

    Mix.shell().info("Probing provider: #{url}")
    Mix.shell().info("Probes: #{probes_str}")
    Mix.shell().info("Method level: #{level}")
    Mix.shell().info("Timeout: #{timeout}ms")
    Mix.shell().info("")
  end
end
