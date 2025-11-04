# Common Elixir Warning Patterns and Fixes

Quick reference for fixing common compilation warnings and Credo issues in Lasso RPC.

## Unused Alias

**Warning:**
```
warning: unused alias HTTP
  │
10 │   alias Lasso.RPC.Transports.{HTTP, WebSocket}
  │   ~
```

**Fix:** Remove the unused alias from multi-alias or entire line

```elixir
# Before
alias Lasso.RPC.Transports.{HTTP, WebSocket}

# After (if only WebSocket used)
alias Lasso.RPC.Transports.WebSocket

# Or (if neither used)
# Delete entire line
```

## Unused Variable

**Warning:**
```
warning: variable "from" is unused
  │
45 │   def handle_call({:get_provider}, from, state) do
```

**Fix:** Prefix with underscore

```elixir
# Before
def handle_call({:get_provider}, from, state) do

# After
def handle_call({:get_provider}, _from, state) do
```

## Unused Function

**Warning:**
```
warning: function generate_request_id/0 is unused
  │
169 │   defp generate_request_id do
```

**Fix:** Grep for usage first, then delete if truly unused

```bash
# Check for references
grep -r "generate_request_id" lib/ test/

# If no references found, delete the function
```

## Phoenix LiveView assign/3 Deprecation

**Warning:**
```
warning: Lasso.assign/3 is deprecated. Use assign/2 with keyword list instead
```

**Fix:** Update to current API

```elixir
# Before
socket
|> assign(:chain, "ethereum")
|> assign(:providers, providers)

# After
socket
|> assign(chain: "ethereum", providers: providers)

# Or
socket |> assign(chain: "ethereum") |> assign(providers: providers)
```

## Unused Module Attribute

**Warning:**
```
warning: module attribute @default_timeout was set but never used
```

**Fix:** Either use it or remove it

```elixir
# Before
@default_timeout 5000

# After (if used)
def make_request(opts) do
  timeout = Keyword.get(opts, :timeout, @default_timeout)
end

# Or delete if truly unused
```

## Pattern Match Warning

**Warning:**
```
warning: variable "error" is unused (if the variable is not meant to be used, prefix it with an underscore)
```

**Fix:** Prefix with underscore

```elixir
# Before
case make_request(provider) do
  {:ok, result} -> result
  {:error, error} -> nil
end

# After
case make_request(provider) do
  {:ok, result} -> result
  {:error, _error} -> nil
end
```

## Duplicate Key Warning

**Warning:**
```
warning: duplicate key :id in map
```

**Fix:** Remove duplicate

```elixir
# Before
%{
  id: "provider1",
  name: "Provider 1",
  id: "provider2"  # Duplicate!
}

# After
%{
  id: "provider2",  # Use the intended value
  name: "Provider 1"
}
```

## Import Conflicts

**Warning:**
```
warning: imported Enum.map/2 conflicts with local function
```

**Fix:** Use explicit module name or rename local function

```elixir
# Fix Option 1: Use module name
Enum.map(list, &process/1)

# Fix Option 2: Rename local function
defp map_providers(providers) do
  # ...
end
```

## Credo: Function Too Complex

**Credo:**
```
Function has complexity of 15 (max: 10)
```

**Fix:** Extract helper functions

```elixir
# Before: Complex function
def handle_request(request, state) do
  if condition1 do
    if condition2 do
      if condition3 do
        # nested logic
      end
    end
  end
end

# After: Extracted helpers
def handle_request(request, state) do
  request
  |> validate_request()
  |> process_valid_request(state)
  |> handle_result()
end

defp validate_request(request), do: ...
defp process_valid_request(request, state), do: ...
defp handle_result(result), do: ...
```

## Credo: Pipe Chain Starting with Single Value

**Credo:**
```
Pipe chain should start with a function call or a value
```

**Fix:** Rewrite to start with value or function

```elixir
# Before
def process(data) do
  data
  |> transform()
  |> validate()
end

# After (if data is a function argument, this is fine!)
# No change needed - Credo might be wrong here

# But if it's a literal:
# Before
def get_default_config do
  %{}
  |> Map.put(:timeout, 5000)
  |> Map.put(:retries, 3)
end

# After
def get_default_config do
  %{timeout: 5000, retries: 3}
end
```

## Credo: Unused Alias

Same as compiler warning - remove unused aliases.

## Dialyzer: No Local Return

**Dialyzer:**
```
Function has no local return
```

**Often means:** Function always raises or loops forever

**Fix:** Add return value or add typespec to document intentional behavior

```elixir
# If intentionally raises
@spec start_link!(keyword()) :: no_return()
def start_link!(opts) do
  case start_link(opts) do
    {:ok, pid} -> pid
    {:error, reason} -> raise "Failed to start: #{inspect(reason)}"
  end
end
```

## Dialyzer: Type Mismatch

**Dialyzer:**
```
The pattern can never match the type
```

**Often means:** Function spec doesn't match implementation

**Fix:** Update spec or implementation

```elixir
# Before: Spec says returns :ok, but returns {:ok, result}
@spec process(term()) :: :ok
def process(data) do
  result = transform(data)
  {:ok, result}  # Mismatch!
end

# After: Fix spec
@spec process(term()) :: {:ok, term()}
def process(data) do
  result = transform(data)
  {:ok, result}
end
```

## Common Safe Auto-Fixes Checklist

✅ Safe to auto-fix:
- Unused aliases (after grepping)
- Unused variables in function signatures (_prefix)
- Phoenix LiveView assign/3 → assign/2 with keyword
- Formatting with mix format
- Removing trailing whitespace

⚠️  Needs confirmation:
- Unused private functions (might be called dynamically)
- Complex deprecations
- Structural refactoring
- Dialyzer warnings

❌ Never auto-fix:
- Public API changes
- Test files (beyond formatting)
- Configuration files
- Production behavior changes
