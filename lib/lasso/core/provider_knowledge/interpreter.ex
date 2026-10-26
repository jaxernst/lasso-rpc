defmodule Lasso.RPC.ProviderKnowledge.Interpreter do
  @moduledoc "Off-path interpretation contract for masked application-error templates."

  @type packet :: %{
          required(:error_code) => integer(),
          required(:template) => binary(),
          required(:fingerprint) => binary(),
          optional(:method) => binary(),
          optional(:shape) => atom()
        }

  @callback interpret([packet()]) :: {:ok, [{packet(), map() | :unknown}]} | {:error, term()}

  @spec adapter() :: module()
  def adapter,
    do: Application.get_env(:lasso, :provider_knowledge_interpreter, __MODULE__.BuiltIn)
end

defmodule Lasso.RPC.ProviderKnowledge.Interpreter.BuiltIn do
  @moduledoc "Built-in error rules for offline interpretation."
  @behaviour Lasso.RPC.ProviderKnowledge.Interpreter

  alias Lasso.Core.Support.ErrorClassification

  @impl true
  def interpret(packets) when is_list(packets) do
    {:ok, Enum.map(packets, &{&1, interpret_one(&1)})}
  end

  defp interpret_one(%{error_code: code, template: template}) do
    case ErrorClassification.categorize_with_path(code, template) do
      {category, _path} when category in [:unclassified_server_error, :unknown_error] ->
        :unknown

      {category, _path} ->
        %{locus: locus(category), persistence: persistence(category), category: category}
        |> Map.put(:request_fault, locus(category) == :request)
        |> Map.put(:quantity_roles, [])
    end
  end

  defp locus(category)
       when category in [
              :invalid_request,
              :invalid_params,
              :parse_error,
              :user_error,
              :client_error,
              :execution_revert
            ],
       do: :request

  defp locus(category) when category in [:network_error, :timeout], do: :network
  defp locus(_category), do: :provider

  defp persistence(category)
       when category in [
              :rate_limit,
              :network_error,
              :server_error,
              :internal_error,
              :timeout,
              :provider_error,
              :block_not_available
            ],
       do: :transient

  defp persistence(_category), do: :persistent
end
