# Used by "mix format"
[
  # TailwindFormatter temporarily disabled due to parsing bugs with comparison operators in HEEx
  # Re-enable periodically to sort Tailwind classes:
  plugins: [Phoenix.LiveView.HTMLFormatter],
  # plugins: [Phoenix.LiveView.HTMLFormatter, TailwindFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    "{config,lib,test}/**/*.{heex,ex,exs}"
  ]
]
