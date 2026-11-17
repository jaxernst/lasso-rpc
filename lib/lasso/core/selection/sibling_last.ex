defmodule Lasso.RPC.Selection.SiblingLast do
  @moduledoc false
  alias Lasso.Core.Support.ClaimAudit
  alias Lasso.RPC.AttemptTerminal

  @spec mark(map(), map(), map(), keyword()) :: map()
  def mark(
        ctx,
        %{fact: %AttemptTerminal.Response{kind: :application_error}} = outcome,
        channel,
        evidence
      ) do
    if capability_refusal?(outcome) or
         Keyword.get(evidence, :constraint_kind) in [:archival, :capability_refusal] do
      case ClaimAudit.vendor_group(channel) do
        nil -> ctx
        group -> %{ctx | refused_vendor_groups: Enum.uniq([group | ctx.refused_vendor_groups])}
      end
    else
      ctx
    end
  end

  def mark(ctx, _outcome, _channel, _evidence), do: ctx

  @doc "Promotes one recognised independent route, retaining unknown positions and sibling order."
  @spec order([term()], [atom()], (term() -> map()), (term() -> term())) :: [term()]
  def order(items, groups, channel, band) do
    recognised =
      Enum.filter(
        items,
        &(not is_nil(ClaimAudit.vendor_group(channel.(&1))) and band.(&1) == band.(hd(items)))
      )

    sibling = Enum.find_index(recognised, &(ClaimAudit.vendor_group(channel.(&1)) in groups))

    independent =
      Enum.find_index(recognised, &(ClaimAudit.vendor_group(channel.(&1)) not in groups))

    if sibling == 0 and is_integer(independent) and independent > 0 and
         ClaimAudit.vendor_group(channel.(hd(items))) in groups do
      {promoted, rest} = List.pop_at(recognised, independent)
      ordered = List.insert_at(rest, sibling, promoted)

      {result, []} =
        Enum.map_reduce(items, ordered, fn item, remaining ->
          if is_nil(ClaimAudit.vendor_group(channel.(item))) or band.(item) != band.(hd(items)) do
            {item, remaining}
          else
            [next | rest] = remaining
            {next, rest}
          end
        end)

      # Unknown positions cannot consume the slot reserved for the ordinary next route.
      if Enum.at(result, 1) == hd(items), do: result, else: items
    else
      items
    end
  end

  defp capability_refusal?(%{result: {:error, %{category: category}, _}})
       when category in [:method_not_found, :capability_violation],
       do: true

  defp capability_refusal?(_), do: false
end
