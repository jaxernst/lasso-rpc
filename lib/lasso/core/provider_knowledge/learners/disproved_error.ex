defmodule Lasso.RPC.ProviderKnowledge.Learners.DisprovedError do
  @moduledoc """
  Provider errors a peer disproved, kept per credential, method and request shape.

  One disproval is enough to defer that credential behind its peers for matching
  requests, because deferral only reorders. Each shape expires on its own, and
  an accepted success of the same shape from the deferred credential retracts it.
  The read model admits a success only for a key this node already holds, local
  or imported, so ordinary traffic never creates rows here. A success on a shape
  only a peer's image holds is kept as a served-only entry, so the merged
  deferral retracts here and the recovery publishes back to that peer.
  """
  @behaviour Lasso.RPC.ProviderKnowledge.Learner

  alias Lasso.RPC.BoundedIdentifier
  alias Lasso.RPC.ProviderKnowledge.{Disproval, Evidence}

  @version 1
  @max_shapes 8
  @max_state_bytes 4_096
  @ttl_ms :timer.minutes(30)
  @probe_share 0.05

  @enforce_keys [:key, :epoch, :shapes]
  defstruct @enforce_keys ++ [:observed_at_ms]

  @type t :: %__MODULE__{}

  @doc "The share of matching requests that still try the deferred credential first."
  @spec probe_share() :: float()
  def probe_share, do: @probe_share

  @impl true
  def bounds, do: %{max_keys: 4_096, max_state_bytes: @max_state_bytes, version: @version}

  @impl true
  def key(%Disproval{} = record), do: {record.subject, record.partition, record.method}

  def key(%Evidence{outcome: :success, qualification: :accepted, method: method} = evidence)
      when is_binary(method),
      do: {evidence.subject, evidence.partition, method}

  def key(_), do: :skip

  @impl true
  def init(key), do: %__MODULE__{key: key, epoch: 0, shapes: %{}}

  @impl true
  def observe(%__MODULE__{} = state, %{epoch: epoch} = record) do
    cond do
      epoch < state.epoch -> state
      epoch > state.epoch -> observe(%{init(state.key) | epoch: epoch}, record)
      true -> observe_current(state, record)
    end
  end

  defp observe_current(state, %Disproval{} = record) do
    entry = %{
      disproved_at_ms: record.observed_at_ms,
      served_at_ms: nil,
      error_code: record.error_code,
      template: record.template,
      witness: record.witness
    }

    shapes =
      state.shapes
      |> Map.update(record.shape, entry, &later_disproval(&1, entry))
      |> retain()

    %{
      state
      | shapes: shapes,
        observed_at_ms: max_optional(state.observed_at_ms, record.observed_at_ms)
    }
  end

  defp observe_current(state, %Evidence{shape: shape, observed_at_ms: at_ms}) do
    served = %{
      disproved_at_ms: nil,
      served_at_ms: at_ms,
      error_code: nil,
      template: nil,
      witness: nil
    }

    shapes =
      state.shapes
      |> Map.update(shape, served, &%{&1 | served_at_ms: max_optional(&1.served_at_ms, at_ms)})
      |> retain()

    %{state | shapes: shapes}
  end

  @impl true
  def decay(%__MODULE__{} = state, now_ms) do
    shapes =
      Map.filter(state.shapes, fn {_shape, entry} -> latest_ms(entry) + @ttl_ms > now_ms end)

    if shapes == %{}, do: :expired, else: %{state | shapes: shapes}
  end

  @impl true
  def merge(%__MODULE__{epoch: left} = state, %__MODULE__{epoch: right}) when left > right,
    do: state

  def merge(%__MODULE__{epoch: left}, %__MODULE__{epoch: right} = state) when left < right,
    do: state

  def merge(%__MODULE__{key: key} = left, %__MODULE__{key: key} = right) do
    shapes =
      Map.merge(left.shapes, right.shapes, fn _shape, a, b -> later_disproval(a, b) end)
      |> retain()

    %{
      left
      | shapes: shapes,
        observed_at_ms: max_optional(left.observed_at_ms, right.observed_at_ms)
    }
  end

  @impl true
  def hints(%__MODULE__{key: {_, _, method}} = state, {:disproved_error, method}) do
    now_ms = System.system_time(:millisecond)

    active =
      for {shape, entry} <- state.shapes,
          deferring?(entry),
          entry.disproved_at_ms + @ttl_ms > now_ms,
          do: {shape, entry}

    case Enum.max_by(active, fn {_shape, entry} -> entry.disproved_at_ms end, fn -> nil end) do
      nil ->
        []

      {_shape, latest} ->
        expiries =
          Map.new(active, fn {shape, entry} -> {shape, entry.disproved_at_ms + @ttl_ms} end)

        [
          %{
            kind: :disproved_error,
            dimension: method,
            value: true,
            shapes: expiries,
            support: %{
              shapes: map_size(expiries),
              witness: latest.witness,
              error_code: latest.error_code,
              template: latest.template
            },
            learner: __MODULE__,
            version: @version,
            observed_at_ms: latest.disproved_at_ms,
            expires_at_ms: expiries |> Map.values() |> Enum.max()
          }
        ]
    end
  end

  def hints(_, _), do: []

  @impl true
  def publication(%__MODULE__{} = state) do
    fingerprint =
      Map.new(state.shapes, fn {shape, entry} ->
        {shape, {entry.disproved_at_ms, entry.served_at_ms}}
      end)

    {fingerprint, nil}
  end

  @impl true
  def encode(%__MODULE__{} = state) do
    payload = :erlang.term_to_binary({@version, state}, compressed: 6)
    if byte_size(payload) <= @max_state_bytes, do: {:ok, payload}, else: {:error, :too_large}
  end

  @impl true
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_state_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@version, %__MODULE__{} = state} ->
        if valid_state?(state), do: {:ok, state}, else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  defp valid_state?(%__MODULE__{key: {subject, partition, method}, epoch: epoch, shapes: shapes}) do
    is_binary(subject) and is_atom(partition) and BoundedIdentifier.valid?(method) and
      is_integer(epoch) and epoch >= 0 and is_map(shapes) and map_size(shapes) <= @max_shapes and
      Enum.all?(shapes, fn {shape, entry} ->
        Disproval.valid_shape?(shape) and valid_entry?(entry)
      end)
  end

  defp valid_state?(_), do: false

  defp valid_entry?(
         %{
           disproved_at_ms: disproved,
           served_at_ms: served,
           error_code: code,
           template: template,
           witness: witness
         } = entry
       ) do
    map_size(entry) == 5 and valid_times?(disproved, served) and
      (is_nil(code) or is_integer(code)) and
      (is_nil(template) or (is_binary(template) and byte_size(template) == 64)) and
      ((is_nil(disproved) and is_nil(witness)) or
         (is_binary(witness) and byte_size(witness) in 1..128))
  end

  defp valid_entry?(_), do: false

  defp valid_times?(nil, served), do: is_integer(served) and served >= 0

  defp valid_times?(disproved, served),
    do: is_integer(disproved) and disproved >= 0 and (is_nil(served) or valid_times?(nil, served))

  # A served answer at or after the disproval retracts it; a later disproval
  # reinstates the deferral with its own attribution.
  defp deferring?(%{disproved_at_ms: nil}), do: false

  defp deferring?(%{disproved_at_ms: disproved, served_at_ms: served}),
    do: is_nil(served) or served < disproved

  defp later_disproval(a, b) do
    latest = if (b.disproved_at_ms || -1) > (a.disproved_at_ms || -1), do: b, else: a
    %{latest | served_at_ms: max_optional(a.served_at_ms, b.served_at_ms)}
  end

  defp latest_ms(entry), do: max_optional(entry.disproved_at_ms, entry.served_at_ms)

  # Deferring shapes outlast served-only ones, so successes never evict a deferral.
  defp retain(shapes) when map_size(shapes) <= @max_shapes, do: shapes

  defp retain(shapes) do
    shapes
    |> Enum.sort_by(fn {_shape, entry} -> {deferring?(entry), latest_ms(entry)} end, :desc)
    |> Enum.take(@max_shapes)
    |> Map.new()
  end

  defp max_optional(nil, value), do: value
  defp max_optional(value, nil), do: value
  defp max_optional(left, right), do: max(left, right)
end
