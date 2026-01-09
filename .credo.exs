%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/"
        ],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/"
        ]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # Consistency Checks
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          # Design Checks
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 2]},
          {Credo.Check.Design.TagTODO, [priority: :low, exit_status: 0]},
          {Credo.Check.Design.TagFIXME, []},

          # Readability Checks
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, [priority: :low]},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, []},

          # Refactoring Opportunities
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 20]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 8]},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 4]},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},

          # Warnings
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.MixEnv, []},

          # Refactoring - additional
          {Credo.Check.Refactor.PipeChainStart, []},

          # Readability - typespecs (non-blocking, for documentation)
          # Only require specs for core modules; skip UI, helpers, and tooling
          {Credo.Check.Readability.Specs,
           [
             priority: :low,
             exit_status: 0,
             files: %{
               excluded: [
                 # UI & Dashboard
                 ~r"lib/lasso_web/dashboard/",
                 ~r"lib/lasso_web/components/",
                 ~r"lib/lasso_web/ui/",
                 # Web Infrastructure
                 ~r"lib/lasso_web/endpoint.ex",
                 ~r"lib/lasso_web/router.ex",
                 ~r"lib/lasso_web/plugs/",
                 ~r"lib/lasso_web/sockets/",
                 ~r"lib/lasso_web/rpc/helpers.ex",
                 ~r"lib/lasso_web/gettext.ex",
                 # Logging & Observability
                 ~r"lib/lasso/logger/",
                 ~r"lib/lasso/observability/",
                 # JSON-RPC Support
                 ~r"lib/lasso/jsonrpc/",
                 # Supporting Infrastructure
                 ~r"lib/lasso/core/chain_state.ex",
                 ~r"lib/lasso/core/block_cache.ex",
                 ~r"lib/lasso/core/events/",
                 ~r"lib/lasso/core/support/dedupe_cache.ex",
                 ~r"lib/lasso/core/support/filter_normalizer.ex",
                 ~r"lib/lasso/core/support/process_registry.ex",
                 ~r"lib/lasso/core/strategies/strategy_registry.ex",
                 ~r"lib/lasso/core/benchmarking/benchmark_store_adapter.ex",
                 ~r"lib/lasso/core/benchmarking/persistence.ex",
                 # Developer Tools
                 ~r"lib/mix/tasks/"
               ]
             }
           ]}
        ],
        disabled: [
          {Credo.Check.Readability.StrictModuleLayout, []},
          # Stylistic preference - existing codebase uses function-first pipes
          {Credo.Check.Refactor.PipeChainStart, []}
        ]
      }
    }
  ]
}
