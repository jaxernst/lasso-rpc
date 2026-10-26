defmodule Lasso.RPC.ProviderKnowledge.Snapshot do
  @moduledoc "Versioned, bounded bundles of encoded learner states for one authority target."

  alias Lasso.RPC.ProviderKnowledge
  alias Lasso.RPC.ProviderKnowledge.{Evidence, Learner}
  alias Lasso.RPC.ProviderKnowledge.Stats.{Bracket, DecayedCounter, LatencyHistogram}

  @max_bytes 65_536
  @max_entries 128
  @max_expanded_bytes 2_500_000
  @max_state_expanded_bytes 262_144

  @type target :: {binary(), pos_integer(), binary()}
  @type row :: {module(), term(), term(), non_neg_integer()}

  @doc "V2 complete writer image. Checkpoints include node-local learners; peers never do."
  @spec encode(target(), map(), [row()], :peer | :checkpoint) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def encode({_, chain, subject}, image, rows, scope \\ :peer) do
    with true <- valid_image?(image),
         true <- scope in [:peer, :checkpoint] do
      now_ms = System.system_time(:millisecond)

      entries =
        rows
        |> Enum.flat_map(fn
          {learner, {^subject, _, _} = key, %{epoch: epoch, key: key} = state, at_ms}
          when epoch == image.epoch and is_integer(at_ms) and at_ms >= 0 ->
            if learner in ProviderKnowledge.learners() and permitted?(learner, scope) do
              with retained when retained != :expired <- learner.decay(state, now_ms),
                   {:ok, encoded} <- learner.encode(retained) do
                [{learner, key, encoded, at_ms}]
              else
                _ -> []
              end
            else
              []
            end

          _ ->
            []
        end)
        |> Enum.sort_by(&elem(&1, 3), :desc)
        |> Enum.take(@max_entries)

      pack({chain, subject}, image, entries, length(rows) - length(entries))
    else
      _ -> {:error, :invalid_snapshot}
    end
  rescue
    _ -> {:error, :invalid_snapshot}
  end

  @spec decode(binary(), target(), :peer | :checkpoint) ::
          {:ok | :incomplete, map()} | {:error, atom()}
  def decode(payload, target, scope \\ :peer)

  def decode(payload, {_, chain, subject}, scope)
      when is_binary(payload) and byte_size(payload) <= @max_bytes and
             scope in [:peer, :checkpoint] do
    :ok = :code.ensure_modules_loaded([Evidence, Bracket, DecayedCounter, LatencyHistogram])

    with true <- bounded_external?(payload, @max_expanded_bytes),
         {2, {^chain, ^subject}, epoch, writer, incarnation, revision, entries} <-
           :erlang.binary_to_term(payload, [:safe]),
         image = %{epoch: epoch, writer: writer, incarnation: incarnation, revision: revision},
         true <- valid_image?(image),
         true <- is_list(entries) and length(entries) <= @max_entries,
         {status, rows, omissions} when status in [:ok, :incomplete] <-
           decode_entries(entries, subject, epoch, scope) do
      {status, Map.merge(image, %{rows: rows, omissions: omissions})}
    else
      _ -> {:error, :invalid_snapshot}
    end
  rescue
    _ -> {:error, :invalid_snapshot}
  end

  def decode(_, _, _), do: {:error, :invalid_snapshot}

  defp valid_image?(%{epoch: epoch, writer: writer, incarnation: incarnation, revision: revision}),
    do:
      is_integer(epoch) and epoch >= 0 and is_binary(writer) and byte_size(writer) in 1..128 and
        is_binary(incarnation) and byte_size(incarnation) == 8 and is_integer(revision) and
        revision >= 0

  defp valid_image?(_), do: false

  defp permitted?(_learner, :checkpoint), do: true

  defp permitted?(learner, :peer), do: Learner.exchangeable?(learner)

  defp pack(target, image, entries, omitted) do
    payload =
      :erlang.term_to_binary(
        {2, target, image.epoch, image.writer, image.incarnation, image.revision, entries},
        compressed: 6
      )

    cond do
      byte_size(payload) <= @max_bytes -> {:ok, payload, omitted}
      entries == [] -> {:error, :summary_budget}
      true -> pack(target, image, List.delete_at(entries, -1), omitted + 1)
    end
  end

  defp decode_entries(entries, subject, epoch, scope) do
    allowed = ProviderKnowledge.learners()

    entries
    |> Enum.reduce_while({[], [], MapSet.new()}, fn entry, {rows, omissions, seen} ->
      with {learner, key, _payload, _at_ms} <- entry,
           false <- MapSet.member?(seen, {learner, key}) do
        seen = MapSet.put(seen, {learner, key})

        case decode_entry(entry, subject, epoch, allowed, scope) do
          {:row, row} -> {:cont, {[row | rows], omissions, seen}}
          {:omit, omission} -> {:cont, {rows, [omission | omissions], seen}}
          :invalid -> {:halt, :invalid}
        end
      else
        _ -> {:halt, :invalid}
      end
    end)
    |> case do
      {rows, omissions, _seen} ->
        status =
          if Enum.all?(omissions, &match?({:retired_version, _, _}, &1)),
            do: :ok,
            else: :incomplete

        {status, Enum.reverse(rows), Enum.reverse(omissions)}

      :invalid ->
        {:error, :invalid_snapshot}
    end
  end

  defp decode_entry(
         {learner, {subject, _, _} = key, payload, at_ms},
         subject,
         epoch,
         allowed,
         scope
       )
       when is_atom(learner) and is_binary(payload) and is_integer(at_ms) and at_ms >= 0 do
    cond do
      at_ms > System.system_time(:millisecond) ->
        :invalid

      not bounded_external?(payload, @max_state_expanded_bytes) ->
        :invalid

      learner not in allowed ->
        {:omit, {:unsupported_learner, learner, nil}}

      not permitted?(learner, scope) or
          byte_size(payload) > learner.bounds().max_state_bytes ->
        :invalid

      true ->
        decode_state(learner, key, payload, at_ms, epoch)
    end
  end

  defp decode_entry(_entry, _subject, _epoch, _allowed, _scope), do: :invalid

  defp decode_state(learner, key, payload, at_ms, epoch) do
    current = learner.bounds().version

    # Strict decoding accepts only current and recognized retired versions.
    # Only a payload it rejects pays for header classification, which reads a
    # newer version without decoding state this VM may not represent.
    case learner.decode(payload) do
      {:ok, %{key: ^key, epoch: ^epoch} = state} ->
        {:row, {learner, key, state, at_ms}}

      {:error, {:unsupported_version, version}}
      when is_integer(version) and version < current ->
        {:omit, {:retired_version, learner, version}}

      _rejected ->
        case Learner.envelope_version(payload) do
          {:ok, version} when version > current -> {:omit, {:future_version, learner, version}}
          _ -> :invalid
        end
    end
  end

  defp bounded_external?(<<131, 80, expanded::32, _::binary>>, limit),
    do: expanded <= limit

  defp bounded_external?(_, _limit), do: true
end
