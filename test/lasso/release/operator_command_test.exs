defmodule Lasso.Release.OperatorCommandTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    lasso = Path.join(tmp_dir, "lasso")
    runtime = Path.join(tmp_dir, "lasso-runtime")
    File.cp!("rel/operator-lasso", lasso)

    File.write!(runtime, ~S"""
    #!/bin/sh
    printf '%s %s' "$*" "${RELEASE_COOKIE-unset}"
    """)

    File.chmod!(lasso, 0o755)
    File.chmod!(runtime, 0o755)
    %{lasso: lasso, stderr: Path.join(tmp_dir, "stderr")}
  end

  test "prefixes a cookie that erl would parse as a flag for every command", ctx do
    for cookie <- [
          "+n" <> String.duplicate("a1", 21) <> "=",
          "-name" <> String.duplicate("f", 32)
        ],
        {command, forwarded} <- [
          {["start"], "start"},
          {["remote"], "remote"},
          {["check-config"], "eval Lasso.Operator.Commands.check_config!()"},
          {["reload"], "rpc Lasso.Operator.Commands.reload!()"}
        ] do
      {stdout, warning} = run(ctx, command, cookie)
      assert stdout == "#{forwarded} lasso#{cookie}"
      assert warning =~ "RELEASE_COOKIE starts with '+' or '-'"
      refute warning =~ cookie
    end
  end

  test "leaves other cookies and the release default untouched", ctx do
    for cookie <- [String.duplicate("0f", 32), "abc+def", "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"] do
      assert {"start " <> ^cookie, ""} = run(ctx, ["start"], cookie)
    end

    assert {"start unset", ""} = run(ctx, ["start"], nil)
  end

  defp run(ctx, command, cookie) do
    {stdout, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          ~S(lasso="$1"; err="$2"; shift 2; "$lasso" "$@" 2>"$err"),
          "sh",
          ctx.lasso,
          ctx.stderr | command
        ],
        env: [{"RELEASE_COOKIE", cookie}]
      )

    {stdout, File.read!(ctx.stderr)}
  end
end
