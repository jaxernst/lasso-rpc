# Run with `mix run --no-start scripts/provider_learning/error_resolution_parity.exs BASE_SHA`.
# The baseline is compiled from the pinned repository source, not a rewritten oracle.
[baseline_sha] = System.argv()

if not Regex.match?(~r/^[0-9a-f]{40}$/, baseline_sha),
  do: raise("a full frozen baseline SHA is required")

{baseline_source, 0} =
  System.cmd("git", ["show", "#{baseline_sha}:lib/lasso/core/support/error_classifier.ex"])

{baseline_normalizer, 0} =
  System.cmd("git", ["show", "#{baseline_sha}:lib/lasso/core/support/error_normalizer.ex"])

{baseline_protocol, 0} =
  System.cmd("git", ["show", "#{baseline_sha}:lib/lasso/core/transport/attempt_protocol.ex"])

{baseline_classification, 0} =
  System.cmd("git", ["show", "#{baseline_sha}:lib/lasso/core/support/error_classification.ex"])

{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:crypto)
Logger.configure(level: :emergency)

baseline_classification
|> String.replace(
  "defmodule Lasso.Core.Support.ErrorClassification do",
  "defmodule ResolutionParity.BaselineClassification do"
)
|> Code.compile_string()

baseline_source
|> String.replace(
  "alias Lasso.Core.Support.ErrorClassification",
  "alias ResolutionParity.BaselineClassification, as: ErrorClassification"
)
|> String.replace(
  "defmodule Lasso.Core.Support.ErrorClassifier do",
  "defmodule ResolutionParity.BaselineClassifier do"
)
|> Code.compile_string()

baseline_normalizer
|> String.replace(
  "defmodule Lasso.Core.Support.ErrorNormalizer do",
  "defmodule ResolutionParity.BaselineNormalizer do"
)
|> String.replace(
  "alias Lasso.Core.Support.ErrorClassifier",
  "alias ResolutionParity.BaselineClassifier, as: ErrorClassifier"
)
|> Code.compile_string()

protocol_projection =
  baseline_protocol
  |> String.split("  defp canonical_application_error_category(:rate_limit)")
  |> Enum.at(1)
  |> String.split("  defp predispatch_reason")
  |> hd()

Code.compile_string(
  "defmodule ResolutionParity.BaselineProtocol do\n alias ResolutionParity.BaselineClassification, as: ErrorClassification\n def canonical_application_error_category(:rate_limit)" <>
    String.replace(
      protocol_projection,
      "defp canonical_application_error_category",
      "def canonical_application_error_category"
    ) <> "end"
)

alias Lasso.Core.Support.{ErrorClassifier, ErrorNormalizer, ErrorResolution}
alias Lasso.JSONRPC.Error, as: JError

codes = [
  -32_700,
  -32_600,
  -32_601,
  -32_602,
  -32_603,
  -32_000,
  -32_001,
  -32_002,
  -32_003,
  -32_004,
  -32_005,
  -32_099,
  3,
  35,
  400,
  402,
  403,
  429,
  500,
  4001,
  4100,
  4200,
  4900,
  4901
]

messages = [
  nil,
  "Invalid Request",
  "not available",
  "unknown method",
  "Vendor opaque denial",
  "execution reverted: access denied",
  "out of gas",
  "insufficient funds",
  "invalid argument 0: free tier",
  "Invalid parameter: fromBlock must be a hex quantity, got 'requires a paid plan'",
  "Invalid param: fromBlock must be a hex quantity, got 'requires a paid plan'",
  "Invalid params: fromBlock must be a hex quantity, got 'requires a paid plan'",
  "Invalid parameters: fromBlock must be a hex quantity, got 'free tier max block range is 10. Upgrade your plan.'",
  "cannot unmarshal string 'rate limit exceeded'",
  "Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. Upgrade to PAYG for expanded block range.",
  "query returned more than 10000 results",
  "eth_getLogs range is too large, max is 1k blocks",
  "monthly quota exceeded",
  "rate limit exceeded",
  "chain is not available on free plan",
  "API key is deactivated",
  "please retry",
  "header not found",
  "archive node required",
  "unfamiliar vendor error",
  String.duplicate("x", 4096) <> "free tier"
]

data_values = [
  nil,
  "0x08c379a0",
  "0x4e487b71",
  "0x1234",
  %{"data" => "0x08c379a0"},
  %{"detail" => "free tier"}
]

policies = [
  %{error_rules: []},
  %{error_rules: [%{code: 35, category: :capability_violation}]},
  %{
    error_rules: [
      %{code: -32_000, message_contains: "vendor opaque denial", category: :rate_limit}
    ]
  },
  %{error_rules: [%{code: -32_602, category: :server_error}, %{code: 3, category: :rate_limit}]}
]

cases =
  for code <- codes,
      message <- messages,
      data <- data_values,
      policy <- policies,
      shared? <- [false, true] do
    {code, message,
     [
       data: data,
       profile: "parity",
       chain_id: 42161,
       provider_id: "parity-provider",
       provider_capabilities: policy,
       shared_instance?: shared?
     ]}
  end

Enum.each(cases, fn {code, message, opts} ->
  expected = ResolutionParity.BaselineClassifier.classify(code, message, opts)
  resolution = ErrorClassifier.resolve(code, message, opts)
  actual = ErrorResolution.classification(resolution)

  if expected != actual,
    do: raise("classification mismatch: #{inspect({code, message, opts, expected, actual})}")

  if resolution.provider_health_failure? !=
       ResolutionParity.BaselineClassification.provider_health_failure?(expected.category),
     do: raise("health mismatch")

  if ErrorResolution.application_category(expected.control_category) !=
       ResolutionParity.BaselineProtocol.canonical_application_error_category(
         expected.control_category
       ),
     do: raise("execution projection mismatch")

  if is_binary(message) do
    envelope = %{"error" => %{"code" => code, "message" => message, "data" => opts[:data]}}
    expected_error = ResolutionParity.BaselineNormalizer.normalize(envelope, opts)
    actual_error = ErrorNormalizer.normalize(envelope, opts)

    if Jason.encode!(expected_error) != Jason.encode!(actual_error),
      do: raise("normalized serialization mismatch")

    if JError.to_map(expected_error) != JError.to_map(actual_error),
      do: raise("client response mismatch")
  end
end)

# Alternating independent rounds reduce ordering bias. This is a local classifier
# microbenchmark, not a claim about RPC throughput, correctness or fleet CPU.
fixture =
  {-32_602, "invalid argument 0: invalid hex",
   [provider_id: "parity-provider", provider_capabilities: hd(policies), shared_instance?: false]}

measure = fn module ->
  {code, message, opts} = fixture

  {us, _} =
    :timer.tc(fn ->
      Enum.each(1..10_000, fn _ -> apply(module, :classify, [code, message, opts]) end)
    end)

  us / 10_000
end

Enum.each(1..1_000, fn _ ->
  ErrorClassifier.classify(elem(fixture, 0), elem(fixture, 1), elem(fixture, 2))
end)

rounds =
  for round <- 1..6 do
    if rem(round, 2) == 0 do
      current = measure.(ErrorClassifier)
      %{baseline_us: measure.(ResolutionParity.BaselineClassifier), current_us: current}
    else
      baseline = measure.(ResolutionParity.BaselineClassifier)
      %{baseline_us: baseline, current_us: measure.(ErrorClassifier)}
    end
  end

sha256 = fn source -> :crypto.hash(:sha256, source) |> Base.encode16(case: :lower) end

IO.puts(
  Jason.encode!(%{
    baseline_sha: baseline_sha,
    baseline_classifier_sha256: sha256.(baseline_source),
    baseline_classification_sha256: sha256.(baseline_classification),
    comparisons: length(cases),
    mismatches: 0,
    checked: [
      "classification",
      "provider health",
      "canonical control projection",
      "JSON serialization",
      "client code/message/data"
    ],
    classifier_microbenchmark_us_per_call: rounds
  })
)
