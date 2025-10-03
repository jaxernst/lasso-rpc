defmodule LassoWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.
  """

  alias Lasso.JSONRPC.Error, as: JError

  # Handle parse errors with JSON-RPC format
  def render("400.json", _assigns) do
    error_response = JError.new(-32700, "Parse error: Invalid JSON")
    JError.to_response(error_response, nil)
  end

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
