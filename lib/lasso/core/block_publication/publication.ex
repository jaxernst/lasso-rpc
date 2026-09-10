defmodule Lasso.BlockPublication.Publication do
  @moduledoc """
  Durable publication transitions. Every command is serialized by the journal.

  Readiness keeps the previous grant open. Closure acknowledgments revoke that
  grant before commit; readiness alone never authorizes publication. Epoch and
  boot checks make delayed commands harmless. Wall clocks do not fence members.
  """

  alias Lasso.BlockPublication.Block

  @type t :: map()
  @type command :: tuple() | :enable | :disable

  @spec new([String.t()], pos_integer()) :: t()
  def new(members, max_age_ms) when members != [] do
    %{
      "revision" => 0,
      "epoch" => 0,
      "published_epoch" => 0,
      "phase" => "joining",
      "members" => Map.new(members, &{&1, nil}),
      "active_members" => %{},
      "max_age_ms" => max_age_ms,
      "minimum_height" => 0,
      "published" => nil,
      "candidate" => nil,
      "ready" => %{},
      "closed" => %{},
      "evidence" => %{},
      "chain_change" => nil,
      "resume_after_close" => false,
      "fences" => [],
      "fenced_boots" => %{}
    }
  end

  @spec apply(t(), command()) :: {:ok, t()} | {:error, atom()}
  def apply(state, command) do
    case transition(state, command) do
      {:ok, next} ->
        next = complete_disable(next)
        {:ok, if(next == state, do: state, else: %{next | "revision" => state["revision"] + 1})}

      error ->
        error
    end
  end

  defp transition(s, {:join, member, boot, floor}) do
    cond do
      not Map.has_key?(s["members"], member) ->
        {:error, :unlisted_member}

      Map.has_key?(Map.get(s, "fenced_boots", %{}), boot) ->
        {:error, :boot_fenced}

      s["members"][member] not in [nil, boot] ->
        {:error, :previous_boot_requires_fence}

      true ->
        s = %{
          s
          | "members" => Map.put(s["members"], member, boot),
            "minimum_height" => max(s["minimum_height"], floor || 0)
        }

        phase = if s["phase"] == "joining" and joined?(s), do: "active", else: s["phase"]
        {:ok, %{s | "phase" => phase}}
    end
  end

  defp transition(%{"phase" => "active"} = s, {:propose, member, boot, block}) do
    with :ok <- member?(s, member, boot),
         true <- joined?(s),
         true <- block["height"] >= s["minimum_height"],
         true <-
           is_nil(s["published"]) or block["height"] > s["published"]["height"] or
             (Block.same?(block, s["published"]) and s["active_members"] != s["members"]) do
      candidate =
        if s["published"] && Block.same?(block, s["published"]),
          do: s["published"],
          else: block

      {:ok,
       %{
         s
         | "epoch" => s["epoch"] + 1,
           "phase" => "preparing",
           "candidate" => candidate,
           "ready" => %{},
           "closed" => %{}
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :ineligible_candidate}
    end
  end

  defp transition(%{"phase" => "preparing"} = s, {:ready, epoch, member, boot, evidence}) do
    with :ok <- epoch_member?(s, epoch, member, boot),
         true <- evidence["block_hash"] == s["candidate"]["hash"],
         true <- is_nil(s["published"]) or Block.valid_hash?(evidence["anchor_hash"]) do
      ready = Map.put(s["ready"], member, evidence)
      anchors = ready |> Map.values() |> Enum.map(& &1["anchor_hash"]) |> Enum.uniq()
      all_ready = map_size(ready) == map_size(s["members"]) and length(anchors) == 1
      minimum = max(s["minimum_height"], Map.get(evidence, "minimum_height", 0))

      if s["candidate"]["height"] < minimum do
        {:ok,
         %{
           s
           | "minimum_height" => minimum,
             "phase" => "active",
             "candidate" => nil,
             "ready" => %{}
         }}
      else
        {:ok,
         %{
           s
           | "minimum_height" => minimum,
             "ready" => ready,
             "phase" => if(all_ready, do: "closing", else: "preparing")
         }}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :conflicting_evidence}
    end
  end

  defp transition(%{"phase" => phase} = s, {:closed, epoch, member, boot})
       when phase in ["closing", "disabling"] do
    with :ok <- epoch_member?(s, epoch, member, boot) do
      closed = Map.put(s["closed"], member, boot)
      s = %{s | "closed" => closed}

      cond do
        phase == "disabling" ->
          {:ok, s}

        closed == s["members"] ->
          anchor = s["ready"] |> Map.values() |> hd() |> Map.get("anchor_hash")

          change =
            if s["published"] && anchor != s["published"]["hash"] do
              %{
                "kind" => "anchor_hash_changed",
                "epoch" => s["epoch"],
                "block_number" => s["published"]["header"]["number"],
                "previous_hash" => s["published"]["hash"],
                "observed_hash" => anchor
              }
            else
              s["chain_change"]
            end

          {:ok,
           %{
             s
             | "phase" => "active",
               "published" => s["candidate"],
               "published_epoch" => s["epoch"],
               "minimum_height" => s["candidate"]["height"],
               "candidate" => nil,
               "active_members" => s["members"],
               "evidence" => s["ready"],
               "chain_change" => change
           }}

        true ->
          {:ok, s}
      end
    end
  end

  defp transition(%{"phase" => "disabled"} = s, :enable),
    do: {:ok, %{s | "phase" => if(joined?(s), do: "active", else: "joining")}}

  defp transition(%{"phase" => "disabling"} = s, :enable),
    do: {:ok, Map.put(s, "resume_after_close", true)}

  defp transition(%{"phase" => phase} = s, :disable) when phase in ["disabled", "disabling"],
    do: {:ok, Map.put(s, "resume_after_close", false)}

  defp transition(s, :disable),
    do:
      {:ok,
       Map.put(
         %{
           s
           | "phase" => "disabling",
             "epoch" => s["epoch"] + 1,
             "closed" => %{},
             "candidate" => nil
         },
         "resume_after_close",
         false
       )}

  defp transition(state, {:max_age, max_age_ms})
       when is_integer(max_age_ms) and max_age_ms > 0,
       do: {:ok, %{state | "max_age_ms" => max_age_ms}}

  # Ordinary cancellation preserves the old grant only during preparation.
  # A closing epoch requires its barrier or an explicit membership transition.
  defp transition(%{"phase" => "preparing", "epoch" => epoch} = s, {:abort, epoch}) do
    {:ok, %{s | "phase" => "active", "candidate" => nil, "ready" => %{}}}
  end

  defp transition(s, {:fence, member, expected_boot, reason})
       when is_binary(expected_boot) and is_binary(reason) and byte_size(reason) >= 8 do
    if Map.has_key?(s["members"], member) and s["members"][member] == expected_boot do
      fence = %{
        "member" => member,
        "boot" => expected_boot,
        "reason" => reason,
        "epoch" => s["epoch"]
      }

      # A fenced runtime must no longer be able to serve. The replacement joins
      # cold, and every remaining runtime closes before any replacement grant.
      {:ok,
       %{
         s
         | "members" => Map.put(s["members"], member, nil),
           "phase" =>
             if(s["phase"] in ["disabling", "disabled"], do: s["phase"], else: "joining"),
           "candidate" => nil,
           "ready" => %{},
           "closed" => if(s["phase"] == "disabling", do: s["closed"], else: %{}),
           "fences" => Enum.take([fence | s["fences"]], 32),
           "fenced_boots" => Map.put(Map.get(s, "fenced_boots", %{}), expected_boot, member)
       }}
    else
      {:error, :boot_mismatch}
    end
  end

  defp transition(%{"phase" => phase} = s, {:add_member, member})
       when phase != "disabling" and is_binary(member) and byte_size(member) > 0 do
    if Map.has_key?(s["members"], member) do
      {:error, :member_exists}
    else
      {:ok,
       %{
         s
         | "members" => Map.put(s["members"], member, nil),
           "phase" => if(phase == "disabled", do: "disabled", else: "joining"),
           "ready" => %{},
           "closed" => %{},
           "candidate" => nil
       }}
    end
  end

  defp transition(%{"phase" => phase} = s, {:remove_fenced_member, member})
       when phase != "disabling" do
    if Map.has_key?(s["members"], member) and is_nil(s["members"][member]) and
         map_size(s["members"]) > 1 do
      s = %{
        s
        | "members" => Map.delete(s["members"], member),
          "ready" => %{},
          "closed" => %{},
          "candidate" => nil
      }

      {:ok, %{s | "phase" => roster_phase(s)}}
    else
      {:error, :member_requires_fence}
    end
  end

  defp transition(_, _), do: {:error, :stale_command}

  defp complete_disable(%{"phase" => "disabling"} = state) do
    closed? =
      Enum.all?(state["active_members"], fn {member, boot} ->
        state["closed"][member] == boot or
          Map.get(state["fenced_boots"], boot) == member
      end)

    if closed? do
      phase =
        if state["resume_after_close"],
          do: if(joined?(state), do: "active", else: "joining"),
          else: "disabled"

      %{state | "phase" => phase, "active_members" => %{}}
    else
      state
    end
  end

  defp complete_disable(state), do: state

  defp roster_phase(%{"phase" => "disabled"}), do: "disabled"
  defp roster_phase(s), do: if(joined?(s), do: "active", else: "joining")

  defp joined?(s), do: Enum.all?(s["members"], fn {_, boot} -> is_binary(boot) end)

  defp member?(s, member, boot) do
    if is_binary(boot) and Map.get(s["members"], member) == boot,
      do: :ok,
      else: {:error, :boot_mismatch}
  end

  defp epoch_member?(s, epoch, member, boot) do
    if s["epoch"] == epoch, do: member?(s, member, boot), else: {:error, :stale_epoch}
  end
end
