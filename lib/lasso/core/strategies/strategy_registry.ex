defmodule Lasso.RPC.Strategies.Registry do
  @moduledoc """
  Strategy registry providing a DRY, pluggable mapping from strategy atoms to modules.

  This allows strategies to be extended or overridden via configuration without
  scattering case statements across the codebase.
  """

  @type strategy :: :fastest | :load_balanced | :latency_weighted

  @doc """
  Resolve a strategy atom to its implementation module.

  Returns the module implementing the Strategy behavior for the given strategy atom.
  Falls back to LoadBalanced strategy if unknown strategy is provided.

  The default registry can be overridden via:

      config :lasso, :strategy_registry, %{
        fastest: MyApp.Strategies.Fastest
      }

  ## Examples

      iex> StrategyRegistry.resolve(:fastest)
      Lasso.RPC.Strategies.Fastest

      iex> StrategyRegistry.resolve(:unknown)
      Lasso.RPC.Strategies.LoadBalanced

  """
  @spec resolve(strategy) :: module()
  def resolve(strategy) when is_atom(strategy) do
    registry = Application.get_env(:lasso, :strategy_registry, default_registry())
    Map.get(registry, strategy, Lasso.RPC.Strategies.LoadBalanced)
  end

  @spec strategy_atoms() :: [atom()]
  def strategy_atoms do
    Application.get_env(:lasso, :strategy_registry, default_registry())
    |> Map.keys()
  end

  @doc """
  Returns the URL-slug form of every registered strategy
  (`:load_balanced → "load-balanced"`, etc.) in stable order.

  Single source of truth for any UI / docs surface that lists
  exposed strategies. Adding a strategy in `default_registry/0`
  (or via the `:strategy_registry` config override) automatically
  shows up everywhere this function is consumed — no parallel
  hand-maintained list to drift against.
  """
  @spec strategy_slugs() :: [String.t()]
  def strategy_slugs do
    strategy_atoms()
    |> Enum.map(&strategy_atom_to_slug/1)
    |> Enum.sort()
  end

  @doc """
  Converts a strategy atom to its URL-slug form. Defined here so
  consumers don't reimplement the `_` → `-` convention.
  """
  @spec strategy_atom_to_slug(atom()) :: String.t()
  def strategy_atom_to_slug(atom) when is_atom(atom),
    do: atom |> Atom.to_string() |> String.replace("_", "-")

  @spec default_registry() :: %{strategy => module()}
  def default_registry do
    %{
      load_balanced: Lasso.RPC.Strategies.LoadBalanced,
      fastest: Lasso.RPC.Strategies.Fastest,
      latency_weighted: Lasso.RPC.Strategies.LatencyWeighted
    }
  end
end
