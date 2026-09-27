defmodule Lasso.Logger.URLRedactionTest do
  use ExUnit.Case, async: true

  test "console output projects message and metadata URLs to their origins" do
    url = "https://user:password@rpc.example/a.b?key=foo"

    output =
      Lasso.Logger.ChainFormatter.format(:error, "failed #{url}", nil, detail: url)
      |> IO.iodata_to_binary()

    assert output =~ "https://rpc.example"

    for secret <- ["password", "user:", "a.b", "foo"] do
      refute output =~ secret
    end
  end

  test "console output redacts key-shaped messages and sensitive metadata" do
    token = "lasso_ak_abcdefghijklmnopqrstuvwxyz123456"

    output =
      Lasso.Logger.ChainFormatter.format(:error, "upstream rejected #{token}", nil,
        authorization: "Bearer #{token}",
        account_id: "private-account"
      )
      |> IO.iodata_to_binary()

    assert output =~ "lasso_[FILTERED]"
    assert output =~ "authorization=[REDACTED]"
    assert output =~ "account_id=[REDACTED]"
    refute output =~ token
    refute output =~ "private-account"
  end
end
