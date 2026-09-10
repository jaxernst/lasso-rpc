defmodule Lasso.BlockPublication.Operator do
  @moduledoc """
  Release-console operations for publication membership. These functions are
  operator tools, never user-facing RPC methods or automatic failure detectors.
  """
  alias Lasso.BlockPublication.Postgres, as: Journal

  @doc "Reports durable fleet-wide scope, byte and background servicing reservations."
  @spec capacity() :: {:ok, map()} | {:error, atom()}
  def capacity, do: Journal.capacity()

  @spec status() :: {:ok, [{{String.t(), pos_integer()}, map()}]} | {:error, term()}
  def status do
    with {:ok, rows} <- Journal.list() do
      {:ok,
       Enum.map(rows, fn {key, state} ->
         {key,
          Map.take(state, [
            "phase",
            "epoch",
            "published_epoch",
            "minimum_height",
            "members",
            "active_members",
            "closed",
            "ready",
            "chain_change",
            "fences"
          ])
          |> Map.put("published_hash", state["published"] && state["published"]["hash"])}
       end)}
    end
  end

  @doc "Permanently closes this runtime's gates and records durable fences before replacement."
  @spec quiesce_local() :: :ok | {:error, term()}
  def quiesce_local, do: Lasso.BlockPublication.Runtime.quiesce()

  @doc "Records a fence only after the named boot has been externally stopped or excluded from ingress."
  @spec record_external_fence({String.t(), pos_integer()}, String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def record_external_fence(key, member, expected_boot, evidence)
      when is_binary(expected_boot) and is_binary(evidence),
      do: Journal.command(key, {:fence, member, expected_boot, evidence})

  @spec add_member({String.t(), pos_integer()}, String.t()) :: {:ok, map()} | {:error, term()}
  def add_member(key, member), do: Journal.command(key, {:add_member, member})

  @spec remove_fenced_member({String.t(), pos_integer()}, String.t()) ::
          {:ok, map()} | {:error, term()}
  def remove_fenced_member(key, member), do: Journal.command(key, {:remove_fenced_member, member})
  @spec disable({String.t(), pos_integer()}) :: {:ok, map()} | {:error, term()}
  def disable(key), do: Journal.command(key, :disable)
  @spec enable({String.t(), pos_integer()}) :: {:ok, map()} | {:error, term()}
  def enable(key), do: Journal.command(key, :enable)
end
