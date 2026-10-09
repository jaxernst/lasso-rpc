defmodule LassoWeb.StrategyAliasContractTest do
  @moduledoc """
  `latency-weighted` is a permanent alias of `balanced-fast`: everything that reads a
  strategy name from a caller accepts it, and a new reader cannot forget it.
  """
  use ExUnit.Case, async: true

  alias Lasso.RPC.RequestOptions.Builder
  alias LassoWeb.RPC.Helpers

  # Files that name balanced-fast only to emit or display it, never to read a caller's choice.
  @emit_only %{
    "assets/js/app.js" => "dashboard description keyed by the selected canonical strategy",
    "lib/lasso_web/components/simulator_controls.ex" => "dashboard buttons send canonical names",
    "lib/lasso_web/dashboard/endpoint_helpers.ex" => "dashboard labels"
  }

  test "HTTP routes and socket paths accept the alias wherever they accept balanced-fast" do
    for prefix <- ["/rpc", "/rpc/profile/public"],
        slug <- ["balanced-fast", "latency-weighted"] do
      assert %{plug_opts: :rpc_balanced_fast} =
               Phoenix.Router.route_info(LassoWeb.Router, "POST", "#{prefix}/#{slug}/base", "")
    end

    paths = Enum.map(LassoWeb.Endpoint.__sockets__(), &elem(&1, 0))
    canonical = Enum.filter(paths, &String.contains?(&1, "/balanced-fast/"))
    assert canonical != []

    for path <- canonical do
      assert String.replace(path, "/balanced-fast/", "/latency-weighted/") in paths, path
    end
  end

  test "strategy tokens resolve the alias" do
    for token <- ["latency-weighted", "latency_weighted"] do
      assert Helpers.normalize_strategy_token(token) == :balanced_fast
    end

    assert %{strategy: :balanced_fast} =
             Builder.from_map(%{"strategy" => "latency_weighted"}, "eth_call")
  end

  test "every source that names balanced-fast also accepts latency-weighted" do
    {listing, 0} = System.cmd("git", ["ls-files", "lib", "scripts", "bench", "assets/js"])

    naming =
      listing
      |> String.split("\n", trim: true)
      |> Enum.filter(&File.regular?/1)
      |> Map.new(&{&1, File.read!(&1)})
      |> Map.filter(fn {_path, source} -> source =~ ~r/balanced-fast|"balanced_fast"/ end)

    missing =
      for {path, source} <- naming,
          not (source =~ ~r/latency-weighted|latency_weighted/),
          not Map.has_key?(@emit_only, path),
          do: path

    assert missing == [],
           "these sources read a strategy name without the latency-weighted alias: " <>
             Enum.join(missing, ", ")

    stale = for {path, _why} <- @emit_only, not Map.has_key?(naming, path), do: path
    assert stale == [], "no longer name balanced-fast; drop them: " <> Enum.join(stale, ", ")
  end
end
