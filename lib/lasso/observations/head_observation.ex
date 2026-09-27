defmodule Lasso.Observations.HeadObservation do
  @moduledoc """
  An immutable, attributed observation of one upstream's chain head.

  The observation records what an upstream instance reported and when Lasso
  received it. Fresh/stale, agreement, and lag verdicts are applied at read time.
  Collection metadata may retain a conservative lifetime cap on evidence reuse;
  it does not declare the observation fresh or the provider healthy.
  """

  alias Lasso.JSONRPC.Quantity
  alias Lasso.Observations.HeadReference

  @enforce_keys [:chain_id, :instance_id, :transport, :height, :observed_at_ms]
  defstruct @enforce_keys ++
              [
                :block_hash,
                :parent_hash,
                :block_timestamp,
                :latency_ms,
                :sample_interval_ms,
                :origin_member_id,
                poll_references: [],
                attributes: %{}
              ]

  @type transport :: :http | :ws

  @type t :: %__MODULE__{
          chain_id: pos_integer(),
          instance_id: String.t(),
          transport: transport(),
          height: non_neg_integer(),
          observed_at_ms: integer(),
          block_hash: String.t() | nil,
          parent_hash: String.t() | nil,
          block_timestamp: non_neg_integer() | nil,
          latency_ms: non_neg_integer() | nil,
          sample_interval_ms: pos_integer() | nil,
          poll_references: [HeadReference.t()],
          origin_member_id: String.t() | nil,
          attributes: map()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, chain_id} <- positive_integer(attrs, :chain_id),
         {:ok, instance_id} <- nonempty_binary(attrs, :instance_id),
         {:ok, transport} <- transport(attrs),
         {:ok, height} <- non_negative_integer(attrs, :height),
         {:ok, observed_at_ms} <- non_negative_integer(attrs, :observed_at_ms),
         :ok <- optional_non_negative_integer(attrs, :block_timestamp),
         :ok <- optional_non_negative_integer(attrs, :latency_ms),
         :ok <- optional_positive_integer(attrs, :sample_interval_ms),
         :ok <- optional_binary(attrs, :block_hash),
         :ok <- optional_binary(attrs, :parent_hash),
         :ok <- optional_binary(attrs, :origin_member_id),
         :ok <- valid_poll_references(attrs, transport, chain_id, observed_at_ms),
         :ok <- valid_attributes(attrs) do
      {:ok,
       struct!(__MODULE__,
         chain_id: chain_id,
         instance_id: instance_id,
         transport: transport,
         height: height,
         observed_at_ms: observed_at_ms,
         block_hash: Map.get(attrs, :block_hash),
         parent_hash: Map.get(attrs, :parent_hash),
         block_timestamp: Map.get(attrs, :block_timestamp),
         latency_ms: Map.get(attrs, :latency_ms),
         sample_interval_ms: Map.get(attrs, :sample_interval_ms),
         poll_references: Map.get(attrs, :poll_references, []),
         origin_member_id: Map.get(attrs, :origin_member_id),
         attributes: Map.get(attrs, :attributes, %{})
       )}
    end
  end

  @spec http(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def http(attrs) when is_list(attrs), do: attrs |> Map.new() |> http()
  def http(attrs) when is_map(attrs), do: attrs |> Map.put(:transport, :http) |> new()

  @spec new_head(
          pos_integer(),
          String.t(),
          map(),
          integer(),
          keyword()
        ) :: {:ok, t()} | {:error, term()}
  def new_head(chain_id, instance_id, payload, observed_at_ms, opts \\ [])
      when is_map(payload) and is_list(opts) do
    with {:ok, height} <- quantity(payload, "number"),
         {:ok, block_timestamp} <- optional_quantity(payload, "timestamp") do
      new(%{
        chain_id: chain_id,
        instance_id: instance_id,
        transport: :ws,
        height: height,
        observed_at_ms: observed_at_ms,
        block_hash: Map.get(payload, "hash"),
        parent_hash: Map.get(payload, "parentHash"),
        block_timestamp: block_timestamp,
        origin_member_id: Keyword.get(opts, :origin_member_id),
        attributes: Keyword.get(opts, :attributes, %{})
      })
    end
  end

  @spec with_origin(t(), String.t()) :: t()
  def with_origin(%__MODULE__{} = observation, origin_member_id)
      when is_binary(origin_member_id) and origin_member_id != "" do
    %{observation | origin_member_id: origin_member_id}
  end

  @spec with_attributes(t(), map()) :: t()
  def with_attributes(%__MODULE__{} = observation, attributes) when is_map(attributes) do
    %{observation | attributes: Map.merge(observation.attributes, attributes)}
  end

  @doc "Returns the request-start reference captured for one exact comparison scope."
  @spec poll_reference_for(t(), tuple() | nil) :: HeadReference.t() | nil
  def poll_reference_for(%__MODULE__{poll_references: references}, scope_id) do
    Enum.find(references, &(&1.scope_id == scope_id))
  end

  @doc "Whether assessment needs a reference captured before this upstream request."
  @spec request_observation?(t()) :: boolean()
  def request_observation?(%__MODULE__{transport: :http}), do: true
  def request_observation?(%__MODULE__{attributes: %{collection: :client}}), do: true
  def request_observation?(%__MODULE__{}), do: false

  defp quantity(payload, key) do
    value = Map.get(payload, key)

    case Quantity.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, :invalid_quantity} -> {:error, {:invalid_quantity, key, value}}
    end
  end

  defp optional_quantity(payload, key) do
    case Map.get(payload, key) do
      nil ->
        {:ok, nil}

      value ->
        case Quantity.decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, :invalid_quantity} -> {:error, {:invalid_quantity, key, value}}
        end
    end
  end

  defp positive_integer(attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp non_negative_integer(attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp nonempty_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp transport(attrs) do
    case Map.get(attrs, :transport) do
      value when value in [:http, :ws] -> {:ok, value}
      value -> {:error, {:invalid_field, :transport, value}}
    end
  end

  defp optional_non_negative_integer(attrs, key) do
    case Map.get(attrs, key) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp optional_positive_integer(attrs, key) do
    case Map.get(attrs, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp optional_binary(attrs, key) do
    case Map.get(attrs, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp valid_poll_references(attrs, transport, chain_id, observed_at_ms) do
    references = Map.get(attrs, :poll_references, [])

    valid? =
      (transport == :http or match?(%{collection: :client}, Map.get(attrs, :attributes))) and
        is_list(references) and
        Enum.all?(references, fn
          %HeadReference{} = reference ->
            HeadReference.valid_for_observation?(reference, chain_id, observed_at_ms)

          _invalid ->
            false
        end) and
        unique_reference_scopes?(references)

    cond do
      transport == :ws and references == [] -> :ok
      valid? -> :ok
      true -> {:error, {:invalid_field, :poll_references, references}}
    end
  end

  defp unique_reference_scopes?(references) do
    references
    |> Enum.map(& &1.scope_id)
    |> then(&(Enum.uniq(&1) == &1))
  end

  defp valid_attributes(attrs) do
    case Map.get(attrs, :attributes, %{}) do
      value when is_map(value) -> :ok
      value -> {:error, {:invalid_field, :attributes, value}}
    end
  end
end
