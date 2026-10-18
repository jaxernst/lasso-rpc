# Parse ExUnit declarations without loading Mix, compiling tests or evaluating tag expressions.
defmodule FeatureMapTags do
  def scan(ast, path) do
    Macro.prewalk(ast, fn
      {:@, meta, [{kind, _, [value]}]} = node
      when kind in [:tag, :moduletag, :describetag] ->
        tags(value, path, meta[:line])
        node

      node ->
        node
    end)

    scan_scope(ast, path)
  end

  defp scan_scope(ast, path) do
    state = %{
      module: scope_tags(ast, :moduletag, path),
      describe: %{},
      pending: %{},
      literal: true,
      described: false
    }

    walk(ast, state, path)
  end

  defp scope_tags(ast, kind, path) do
    nodes =
      case ast do
        {:__block__, _, nodes} -> nodes
        node -> [node]
      end

    Enum.reduce(nodes, %{}, fn
      {:@, meta, [{^kind, _, [value]}]}, acc -> Map.merge(acc, tags(value, path, meta[:line]))
      _, acc -> acc
    end)
  end

  defp walk({:__block__, _, nodes}, state, path), do: walk(nodes, state, path)

  defp walk(nodes, state, path) when is_list(nodes),
    do: Enum.reduce(nodes, state, &walk(&1, &2, path))

  defp walk({:->, _, [_patterns, body]}, state, path) do
    walk(body, state, path)
  end

  defp walk({:defmodule, _, [_name, [do: body]]}, state, path) do
    if state.literal, do: scan_scope(body, path), else: walk(body, state, path)
    state
  end

  defp walk({:@, meta, [{:tag, _, [value]}]}, state, path) do
    declared = tags(value, path, meta[:line])
    check_position(declared, state, path, meta[:line])
    Map.update!(state, :pending, &Map.merge(&1, declared))
  end

  defp walk({:@, meta, [{kind, _, [value]}]}, state, path)
       when kind in [:moduletag, :describetag] do
    # Scope inheritance is literal; generated declarations never establish guards.
    check_position(tags(value, path, meta[:line]), state, path, meta[:line])
    state
  end

  defp walk({:test, meta, args}, state, path) when is_list(args) do
    tags = state.module |> Map.merge(state.describe) |> Map.merge(state.pending)
    ids = Map.get(tags, :feature, [])

    harness =
      String.starts_with?(path, "harness/test/") or
        Enum.any?([state.module, state.describe, state.pending], &Map.get(&1, :harness, false))

    if not state.literal and (ids != [] or harness),
      do: literal_error(path, meta[:line])

    skipped = Enum.any?([state.module, state.describe, state.pending], &Map.has_key?(&1, :skip))

    if state.literal and not skipped,
      do: Enum.each(ids, &IO.puts("guard\t#{path}:#{meta[:line]}\t#{&1}"))

    if harness and ids == [],
      do: IO.puts("error\t#{path}:#{meta[:line]}\tharness-lane test has no feature tag")

    %{state | pending: %{}}
  end

  defp walk({:describe, _, [_name, [do: body]]}, state, path) do
    describe = Map.merge(state.describe, scope_tags(body, :describetag, path))

    inner = %{
      state
      | describe: describe,
        described: true,
        literal: state.literal and not state.described
    }

    result = walk(body, inner, path)
    %{state | pending: result.pending}
  end

  # Any other call creates a nonliteral scope. Traverse it only to reject declarations
  # and consume pending tags; never run or interpret the call's control flow.
  defp walk({_name, _, args}, state, path) when is_list(args) do
    result = walk(args, %{state | literal: false}, path)
    %{state | pending: result.pending}
  end

  defp walk({_key, body}, state, path), do: walk(body, state, path)
  defp walk(_, state, _path), do: state

  defp check_position(tags, state, path, line) do
    if Map.has_key?(tags, :feature) and not state.literal, do: literal_error(path, line)
  end

  defp literal_error(path, line),
    do:
      IO.puts(
        "error\t#{path}:#{line}\tput the test and its feature tag at a literal position: module level or directly inside a describe"
      )

  defp tags(value, path, line) do
    cond do
      value == :feature ->
        IO.puts("error\t#{path}:#{line}\tfeature tag must be a nonempty literal list of strings")
        %{}

      is_atom(value) ->
        %{value => true}

      is_list(value) and Keyword.keyword?(value) ->
        Enum.reduce(value, %{}, fn
          {:feature, ids}, acc ->
            if is_list(ids) and ids != [] and Enum.all?(ids, &is_binary/1) do
              Enum.each(ids, &IO.puts("tag\t#{path}:#{line}\t#{&1}"))
              Map.put(acc, :feature, ids)
            else
              IO.puts(
                "error\t#{path}:#{line}\tfeature tag must be a nonempty literal list of strings"
              )

              acc
            end

          {:skip, _}, acc ->
            Map.put(acc, :skip, true)

          {:harness, literal}, acc when is_boolean(literal) ->
            Map.put(acc, :harness, literal)

          {:harness, _}, acc ->
            IO.puts("error\t#{path}:#{line}\tharness tag must be literal")
            acc

          _, acc ->
            acc
        end)

      true ->
        IO.puts("error\t#{path}:#{line}\tcomputed tag declaration can hide feature IDs")
        %{}
    end
  end
end

:stdio
|> IO.read(:eof)
|> String.split(<<0>>)
|> Enum.chunk_every(2, 2, :discard)
|> Enum.each(fn [path, source] ->
  case Code.string_to_quoted(source, file: path, emit_warnings: false) do
    {:ok, ast} -> FeatureMapTags.scan(ast, path)
    {:error, error} -> IO.puts("error\t#{path}\tcannot parse Elixir: #{inspect(error)}")
  end
end)
