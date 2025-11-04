# Phoenix and LiveView API Updates

Migration guide for common Phoenix and Phoenix LiveView deprecations in Lasso RPC.

## Phoenix LiveView 1.0+ API Updates

### assign/3 → assign/2 (Keyword List)

**Deprecated:**
```elixir
socket
|> assign(:chain, "ethereum")
|> assign(:provider_count, 5)
```

**Current:**
```elixir
socket
|> assign(chain: "ethereum", provider_count: 5)

# Or chained
socket
|> assign(chain: "ethereum")
|> assign(provider_count: 5)
```

**Why:** Keyword list is more idiomatic Elixir and enables better pattern matching.

### push_redirect → push_navigate

**Deprecated:**
```elixir
socket
|> push_redirect(to: "/metrics/ethereum")
```

**Current:**
```elixir
socket
|> push_navigate(to: "/metrics/ethereum")
```

**Why:** More explicit naming and better handling of LiveView navigation.

### live_redirect → <.link navigate={...}>

**Deprecated (HEEx template):**
```heex
<%= live_redirect "View Metrics", to: "/metrics/ethereum" %>
```

**Current:**
```heex
<.link navigate="/metrics/ethereum">View Metrics</.link>
```

**Why:** Component-based approach with better accessibility and consistency.

### live_patch → <.link patch={...}>

**Deprecated:**
```heex
<%= live_patch "Switch Chain", to: "/metrics/base" %>
```

**Current:**
```heex
<.link patch="/metrics/base">Switch Chain</.link>
```

### handle_params Return Signature

**Old:**
```elixir
def handle_params(params, _uri, socket) do
  {:noreply, assign(socket, params: params)}
end
```

**Current (same, but ensure consistent):**
```elixir
def handle_params(params, _uri, socket) do
  {:noreply, assign(socket, params: params)}
end
```

This is already correct - just ensure all handle_params return `{:noreply, socket}`.

## Phoenix 1.7+ Updates

### Verified Routes ~p Sigil

**Old:**
```elixir
redirect(conn, to: "/metrics/ethereum")
```

**Current (optional but recommended):**
```elixir
redirect(conn, to: ~p"/metrics/ethereum")
```

**Why:** Compile-time verification that routes exist.

### Core Components

**Old (manual component definitions):**
```heex
<div class="modal">...</div>
```

**Current (use generated core components):**
```heex
<.modal id="provider-modal">
  ...
</.modal>
```

**Location:** `lib/lasso_web/components/core_components.ex`

## Phoenix PubSub (No Major Changes)

Phoenix PubSub API is stable. Current usage in Lasso:

```elixir
# Subscribe
Phoenix.PubSub.subscribe(Lasso.PubSub, "providers:#{chain}")

# Broadcast
Phoenix.PubSub.broadcast(
  Lasso.PubSub,
  "providers:#{chain}",
  {:provider_status, status}
)
```

This is current and correct.

## Telemetry (No Changes Needed)

Telemetry API is stable:

```elixir
:telemetry.execute(
  [:lasso, :rpc, :request, :completed],
  %{duration: duration},
  %{chain: chain, method: method}
)
```

## Ecto (Not Used in Lasso)

Lasso doesn't use Ecto, so no database-related migrations needed.

## Common Patterns in Lasso RPC

### LiveView Mount

**Current pattern (correct):**
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    # Subscribe to updates
    Phoenix.PubSub.subscribe(Lasso.PubSub, "metrics:#{chain}")
  end

  {:ok, assign(socket, chain: "ethereum", providers: [])}
end
```

### LiveView Event Handlers

**Current pattern (correct):**
```elixir
def handle_event("select_chain", %{"chain" => chain}, socket) do
  {:noreply, assign(socket, chain: chain)}
end
```

### LiveView Info Handlers (PubSub)

**Current pattern (correct):**
```elixir
def handle_info({:metrics_updated, metrics}, socket) do
  {:noreply, assign(socket, metrics: metrics)}
end
```

## Migration Checklist for Lasso RPC

When updating LiveView code:

- [ ] Replace `assign(socket, :key, value)` with `assign(socket, key: value)`
- [ ] Replace `live_redirect` with `<.link navigate=...>`
- [ ] Replace `live_patch` with `<.link patch=...>`
- [ ] Consider using `~p` sigil for route verification
- [ ] Use core components from `core_components.ex`
- [ ] Ensure handle_params returns `{:noreply, socket}`
- [ ] Run tests after changes
- [ ] Check for deprecation warnings: `mix compile`

## Finding Deprecations in Codebase

```bash
# Find old assign/3 usage
grep -r "assign(.*,.*,.*)" lib/lasso_web/

# Find live_redirect
grep -r "live_redirect" lib/lasso_web/

# Find live_patch
grep -r "live_patch" lib/lasso_web/

# Check for any deprecation warnings
mix compile 2>&1 | grep -i deprecat
```

## Testing After Updates

Always run LiveView tests after API updates:

```bash
# Run LiveView-specific tests
mix test test/lasso_web/live/

# Run full test suite
mix test --exclude battle --exclude slow
```

## Resources

- [Phoenix LiveView v1.0 Upgrade Guide](https://hexdocs.pm/phoenix_live_view/changelog.html)
- [Phoenix 1.7 Release Notes](https://hexdocs.pm/phoenix/changelog.html)
- Lasso LiveView files:
  - `lib/lasso_web/live/metrics_live.ex` (main dashboard)
  - `lib/lasso_web/live/simulator_live.ex` (system simulator)
