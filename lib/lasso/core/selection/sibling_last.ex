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

  @spec sibling?(map(), [atom()]) :: boolean()
  def sibling?(channel, groups) do
    case ClaimAudit.vendor_group(channel) do
      nil -> false
      group -> group in groups
    end
  end

  defp capability_refusal?(%{result: {:error, %{category: category}, _}})
       when category in [:method_not_found, :capability_violation],
       do: true

  defp capability_refusal?(_), do: false
end
