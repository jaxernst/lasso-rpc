ExUnit.start(max_cases: 1, timeout: 30_000)
{:ok, _} = Application.ensure_all_started(:lasso)
