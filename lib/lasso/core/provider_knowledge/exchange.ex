defmodule Lasso.RPC.ProviderKnowledge.Exchange do
  @moduledoc "Bounded PubSub complete-image exchange and per-writer digest repair, without persistence."
  use GenServer
  alias Lasso.RPC.ProviderKnowledge.{Learner, ReadModel, Snapshot, State}

  @topic "provider_knowledge:images:v2"
  @repair_ms :timer.minutes(15)
  @queue_limit 512
  @budget 65_536

  @spec topic() :: binary()
  def topic, do: @topic
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, Lasso.PubSub)
    Phoenix.PubSub.subscribe(pubsub, @topic)

    auto =
      Keyword.get(opts, :auto_refresh, true)

    state = %{
      pubsub: pubsub,
      auto: auto,
      fingerprints: %{},
      scan: [],
      queue: %{},
      sequence: 0,
      queue_limit: Keyword.get(opts, :queue_limit, @queue_limit),
      tokens: @budget,
      budget: Keyword.get(opts, :byte_budget, @budget),
      budget_at: System.monotonic_time(:millisecond),
      sent_at: %{},
      scan_ms: Keyword.get(opts, :scan_ms, 100)
    }

    if auto do
      send(self(), :scan)
      send(self(), :drain)
      Process.send_after(self(), :digest, @repair_ms)
    end

    {:ok, enqueue(state, :repair, {:learning_repair, State.identity()})}
  end

  @impl true
  def handle_info(:writer_changed, state) do
    state = %{state | fingerprints: %{}, sent_at: %{}, queue: %{}}
    {:noreply, enqueue(state, :repair, {:learning_repair, State.identity()})}
  end

  def handle_info({:subjects_admitted, targets}, state) do
    state =
      targets
      |> Enum.map(&key/1)
      |> Enum.uniq()
      |> Enum.chunk_every(128)
      |> Enum.reduce(state, fn keys, state ->
        enqueue(state, {:repair, keys}, {:learning_repair, State.identity(), keys})
      end)

    {:noreply, state}
  end

  def handle_info({:learning_repair, identity, keys}, state)
      when is_list(keys) and length(keys) <= 128 do
    wanted = MapSet.new(keys)

    state =
      if identity == State.identity() do
        state
      else
        Enum.reduce(State.targets(), state, fn target, state ->
          if MapSet.member?(wanted, key(target)), do: queue_image(state, target), else: state
        end)
      end

    {:noreply, state}
  end

  def handle_info(:scan, state) do
    targets = if state.scan == [], do: State.targets(), else: state.scan
    state = if state.scan == [], do: prune(state, targets), else: state

    state =
      case targets do
        [target | rest] -> check(%{state | scan: rest}, target)
        [] -> state
      end

    schedule(state, :scan, state.scan_ms)
    {:noreply, state}
  end

  def handle_info(:drain, state) do
    state = drain(state)
    schedule(state, :drain, 100)
    {:noreply, state}
  end

  def handle_info(:digest, state) do
    State.expire_imports()

    state =
      State.digest()
      |> Enum.chunk_every(128)
      |> Enum.with_index()
      |> Enum.reduce(state, fn {entries, index}, state ->
        enqueue(state, {:digest, index}, {:learning_digest, State.identity(), Map.new(entries)})
      end)

    # An empty digest must still ask active writers for their images.
    state =
      if map_size(State.digest()) == 0,
        do: enqueue(state, {:digest, 0}, {:learning_digest, State.identity(), %{}}),
        else: state

    schedule(state, :digest, @repair_ms)
    {:noreply, state}
  end

  def handle_info({:learning_repair, identity}, state) do
    state =
      if identity == State.identity(),
        do: state,
        else: Enum.reduce(State.targets(), state, &queue_image(&2, &1))

    {:noreply, state}
  end

  def handle_info({:learning_digest, identity, digest}, state)
      when is_map(digest) and map_size(digest) <= 128 do
    {writer, _incarnation} = State.identity()

    state =
      if identity == State.identity() do
        state
      else
        subjects = MapSet.new(digest, fn {{subject, _writer}, _image} -> subject end)
        own_digest = State.digest()

        Enum.reduce(State.targets(), state, fn target, state ->
          own = Map.get(own_digest, {key(target), writer})
          peer = Map.get(digest, {key(target), writer})

          if (map_size(digest) == 0 or MapSet.member?(subjects, key(target))) and
               behind?(peer, own),
             do: queue_image(state, target),
             else: state
        end)
      end

    {:noreply, state}
  end

  def handle_info({:learning_image, image_key, payload}, state) do
    target = Enum.find(State.targets(), &(key(&1) == image_key))

    if is_nil(target) do
      :telemetry.execute([:lasso, :provider_knowledge, :image, :not_admitted], %{count: 1}, %{
        node: node(),
        subject: image_key
      })
    end

    with target when not is_nil(target) <- target,
         {status, image} when status in [:ok, :incomplete] <- Snapshot.decode(payload, target),
         {writer, _incarnation} <- State.identity(),
         true <- writer != image.writer do
      State.import_image(target, image)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp check(state, target) do
    rows = ReadModel.snapshot_subject(elem(target, 2))
    {signature, refresh_ms} = signature(rows)
    key = key(target)
    now = System.monotonic_time(:millisecond)
    changed = Map.get(state.fingerprints, key) != {State.epoch(target), signature}

    refresh =
      is_integer(refresh_ms) and now - Map.get(state.sent_at, key, now - refresh_ms) >= refresh_ms

    if changed or refresh do
      queue_image(state, target, {State.epoch(target), signature})
    else
      state
    end
  end

  defp prune(state, targets) do
    wanted = MapSet.new(targets, &key/1)

    queue =
      Map.reject(state.queue, fn
        {{:image, key}, _item} -> not MapSet.member?(wanted, key)
        _ -> false
      end)

    %{
      state
      | queue: queue,
        fingerprints:
          Map.filter(state.fingerprints, fn {key, _} -> MapSet.member?(wanted, key) end),
        sent_at: Map.filter(state.sent_at, fn {key, _} -> MapSet.member?(wanted, key) end)
    }
  end

  defp signature(rows) do
    now = System.system_time(:millisecond)

    publications =
      for {learner, key, state, _at_ms} <- rows,
          Learner.exchangeable?(learner),
          fresh = learner.decay(state, now),
          fresh != :expired,
          {fingerprint, refresh_ms} = learner.publication(fresh),
          do: {{learner, key, fingerprint}, refresh_ms}

    {entries, refreshes} = Enum.unzip(publications)

    refresh =
      refreshes
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    {:crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(entries))), refresh}
  end

  defp queue_image(state, target, fingerprint \\ nil) do
    {writer, incarnation} = State.identity()

    with {:ok, image} <- State.snapshot(target, writer, incarnation),
         {:ok, payload, _omitted} <- Snapshot.encode(target, image, image.rows) do
      state =
        enqueue(
          state,
          {:image, key(target)},
          {:learning_image, key(target), payload},
          {target, image}
        )

      if fingerprint,
        do: %{state | fingerprints: Map.put(state.fingerprints, key(target), fingerprint)},
        else: state
    else
      _ -> state
    end
  end

  defp enqueue(state, key, message, image \\ nil) do
    item = %{
      message: message,
      image: image,
      bytes: :erlang.external_size(message),
      sequence: state.sequence
    }

    queue = Map.put(state.queue, key, item)

    {queue, fingerprints} =
      if map_size(queue) > state.queue_limit do
        {oldest, _} = Enum.min_by(queue, fn {_key, item} -> item.sequence end)

        fingerprints =
          case oldest do
            {:image, subject} -> Map.delete(state.fingerprints, subject)
            _ -> state.fingerprints
          end

        {Map.delete(queue, oldest), fingerprints}
      else
        {queue, state.fingerprints}
      end

    %{state | queue: queue, fingerprints: fingerprints, sequence: state.sequence + 1}
  end

  defp drain(state) do
    now = System.monotonic_time(:millisecond)

    tokens =
      min(state.budget * 2, state.tokens + div((now - state.budget_at) * state.budget, 1_000))

    state = %{state | tokens: tokens, budget_at: now}

    Enum.reduce_while(
      Enum.sort_by(state.queue, fn {_, item} -> item.sequence end),
      state,
      fn {key, item}, state ->
        cond do
          not publishable?(item.image) ->
            fingerprints =
              case item.image do
                {target, _image} -> Map.delete(state.fingerprints, key(target))
                nil -> state.fingerprints
              end

            {:cont, %{state | queue: Map.delete(state.queue, key), fingerprints: fingerprints}}

          item.bytes <= state.tokens ->
            Phoenix.PubSub.broadcast(state.pubsub, @topic, item.message)

            state = %{
              state
              | queue: Map.delete(state.queue, key),
                tokens: state.tokens - item.bytes
            }

            state =
              case item.image do
                {target, _image} ->
                  %{state | sent_at: Map.put(state.sent_at, key(target), now)}

                nil ->
                  state
              end

            {:cont, state}

          true ->
            {:halt, state}
        end
      end
    )
  end

  defp publishable?(nil), do: true
  defp publishable?({target, image}), do: State.publishable?(target, image)

  defp behind?(_peer, nil), do: false
  defp behind?(nil, _own), do: true
  defp behind?({incarnation, peer}, {incarnation, own}), do: peer < own
  defp behind?(_peer, _own), do: true
  defp schedule(%{auto: true}, message, delay), do: Process.send_after(self(), message, delay)
  defp schedule(_state, _message, _delay), do: :ok
  defp key({_profile, chain, subject}), do: {chain, subject}
end
