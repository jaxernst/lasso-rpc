defmodule Lasso.RPC.ProviderKnowledge.Inventory do
  @moduledoc "Local learning admission from published file-backed routing plans."
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.TransportRegistry

  @spec published() :: :ok
  def published do
    Phoenix.PubSub.local_broadcast(Lasso.PubSub, topic(), :learning_inventory_published)
  catch
    _kind, _reason -> :ok
  end

  @spec topic() :: binary()
  def topic, do: "provider_knowledge:inventory"

  @spec targets() :: [{binary(), pos_integer(), binary()}]
  def targets do
    case Catalog.snapshot() do
      %{table: table} ->
        for {{profile, chain}, plan} <- Catalog.routing_plans(table),
            provider <- plan.providers,
            transport <- provider.transports,
            subject when not is_nil(subject) <- [
              TransportRegistry.learning_subject_for(profile, chain, transport, provider.config)
            ],
            uniq: true,
            do: {profile, chain, subject.id}

      _ ->
        []
    end
  rescue
    ArgumentError -> []
  end
end
