# Dashboard Refactor Plan

## 1. Overview and Goals

This document outlines a comprehensive plan to refactor the monolithic LiveView at `lib/livechain_web/dashboard/dashboard.ex`.

The primary goal is to **dramatically reduce the line count and complexity of the main `Dashboard` LiveView by decomposing it into smaller, single-purpose, and maintainable LiveComponents.**

### Addendum: Freedom to Innovate

Per our latest discussion, the requirement to **maintain the exact existing UI and functionality does NOT apply to the *Simulator* and *Chain Configuration* windows.** These features are considered incomplete. This refactor is an opportunity to overhaul and improve their UI, UX, and underlying logic. For all other components (the main topology view, details panel, etc.), the goal remains to preserve existing functionality precisely.

## 2. Guiding Principles for Junior Engineers

This refactor involves core Phoenix LiveView concepts. Understanding them is key to avoiding common mistakes.

### Example of a Stateless Component: `CoreComponents`

For a perfect example of simple, stateless, reusable components, look at **`lib/livechain_web/components/core_components.ex`**.

A function component like `status_badge/1` is the simplest form of reuse:

```elixir
# From: lib/livechain_web/components/core_components.ex

def status_badge(assigns) do
  ~H"""
  <span class={["inline-flex items-center rounded-full px-2 py-1 text-xs font-medium", status_color(@status)]}>
    {status_text(@status)}
  </span>
  """
end
```

This is a pure function. It takes assigns (`@status`), applies minimal logic, and renders HTML. It holds no state and handles no events, making it extremely easy to test and reason about. We will use this pattern to extract large blocks of HEEx into more manageable functions.

### Stateful vs. Stateless LiveComponents

A key decision is whether to make a component "stateful" or "stateless".

-   **Stateless (`<.live_component module={...} />`)**:
    -   Think of this as a managed function that renders HEEx. It receives all its data (`assigns`) from the parent LiveView.
    -   It does **not** have its own state.
    -   It does **not** have its own `handle_event/3` callbacks. All events are handled by the parent LiveView.
    -   Use this for simple, reusable UI elements.

-   **Stateful (`<.live_component module={...} id={...} />`)**:
    -   The `id` is the magic! Giving a component an `id` tells LiveView to spin up a separate, stateful process for it.
    -   It **manages its own state**. It has its own `mount/1` and `update/2` callbacks to initialize its `socket.assigns`.
    -   It **handles its own events**. A `phx-click` inside a stateful component will trigger `handle_event/3` *within that component's module*, not the parent.
    -   **This is the primary tool we will use for the refactor.**

### State Flow: Parent -> Child

A parent LiveView passes data to a child component via assigns.

```elixir
# Parent LiveView (dashboard.ex)
~H"""
<.live_component module={MyComponent} id="my-comp" my_data={@some_data_in_parent} />
"""
```

The child component receives this in `mount/1` (for the initial render) or `update/2` (for subsequent changes).

```elixir
# my_component.ex
def mount(socket) do
  # This won't have the assigns yet
  {:ok, socket}
end

def update(assigns, socket) do
  # `assigns.my_data` is available here!
  # This is where you should initialize state from the parent.
  socket = assign(socket, :my_data, assigns.my_data)
  {:ok, socket}
end
```

### Event Handling: `handle_info/2` and PubSub

This is the most important and tricky concept for this refactor.

-   **By default, only the top-level LiveView can receive `handle_info/2` messages.** This includes all `Phoenix.PubSub` messages.
-   For our new stateful components, the cleanest pattern is **Direct Subscription**:
    -   The stateful component (e.g., `ChainConfigurationWindow`) subscribes to the PubSub topics it cares about in its own `mount/1`.
    -   It can then implement its own `handle_info/2` callback to handle those messages directly, making it truly self-contained.

### Communication: Child -> Parent

If a child component needs to tell the parent something (e.g., "I've saved the data, please show a flash message"), it can send a message to its parent's process.

```elixir
# In the child component's handle_event/3
send(socket.parent_pid, {:child_updated, "some data"})

# In the parent LiveView (dashboard.ex)
@impl true
def handle_info({:child_updated, data}, socket) do
  # Do something with the data from the child
  {:noreply, put_flash(socket, :info, "Child component sent: #{data}")}
end
```

---
***Note on Line Numbers:*** *The line numbers referenced below are based on the version of `dashboard.ex` provided previously. They may be slightly different in the latest version of the file and should be used as a general guide.*
---

## 3. Phase 1: Low-Risk Code Organization

**Goal:** Move large blocks of rendering logic out of `dashboard.ex` without changing any functionality. This is a low-risk, high-impact first step.

### Step 1.1: Extract Rendering Logic to a Helper Module

-   **Action:** We will move large, render-only function components from `dashboard.ex` into a new dedicated helper file.
-   **Target File (New):** `lib/livechain_web/components/dashboard_components.ex`
-   **Source File:** `lib/livechain_web/dashboard/dashboard.ex`

**Functions to Move:**

1.  `floating_chain_config_window/1` (starts at line `~784`)
2.  `chain_config_form/1` (starts at line `~890`)
3.  `quick_add_provider_form/1` (starts at line `~1319`)
4.  `benchmarks_tab_content/1` (starts at line `~998`)
5.  `metrics_tab_content/1` (starts at line `~1008`)

**Implementation:**

1.  Create the new file `lib/livechain_web/components/dashboard_components.ex`.
2.  Define the module `LivechainWeb.Components.DashboardComponents` and `use Phoenix.Component`.
3.  Cut the 5 functions listed above from `dashboard.ex` and paste them into this new module.
4.  In `dashboard.ex`, add an alias at the top: `alias LivechainWeb.Components.DashboardComponents`.
5.  In the `render/1` function of `dashboard.ex`, update the calls.

**Example for `metrics_tab_content`:**

*   **Before (in `dashboard.ex` `render/1`):**
    ```elixir
    # line ~769
    <.metrics_tab_content
      connections={@connections}
      ...
    />
    ```
*   **After (in `dashboard.ex` `render/1`):**
    ```elixir
    # Alias DashboardComponents at the top of the file
    <DashboardComponents.metrics_tab_content
      connections={@connections}
      ...
    />
    ```

---

## 4. Phase 2: Extracting Stateful Components

**Goal:** Convert logically distinct UI sections into independent, stateful LiveComponents.

### Step 2.1: Refactor `SimulatorControls` into a Stateful Component

-   **Goal:** The simulator panel should manage its own state and events. This is an opportunity to improve its UI and logic.
-   **Source File:** `lib/livechain_web/dashboard/dashboard.ex`
-   **Target File (Existing):** `lib/livechain_web/components/simulator_controls.ex`

**Implementation:**

1.  **Move State from `Dashboard` to `SimulatorControls`:**
    -   In `dashboard.ex`, locate the following assigns in `mount/1` (lines `~70-80`):
        ```elixir
        :sim_collapsed, :selected_chains, :selected_strategy, :request_rate, :recent_calls
        ```
    -   Cut these lines from `dashboard.ex`.
    -   In `simulator_controls.ex`, modify the `update/2` function to receive and set these as initial state.

2.  **Move Event Handlers from `Dashboard` to `SimulatorControls`:**
    -   In `dashboard.ex`, locate the block of `handle_event/3` functions from line `~1058` to `~1150`.
    -   Cut this entire block of functions and paste it into `simulator_controls.ex`.
    -   In `simulator_controls.ex`, remove the generic `handle_event/3` that forwards events to the parent. The component will now handle these events itself.
    -   In the HEEx for `simulator_controls.ex`, ensure all `phx-target` attributes are set to `@myself`.

3.  **Clean up `Dashboard`:**
    -   The `handle_info({:simulator_event, ...})` function at line `~488` in `dashboard.ex` can now be deleted.
    -   The call to the component in `dashboard.ex` (line `~725`) will no longer pass down all the simulator-related assigns.

### Step 2.2: Create a Stateful `ChainConfigurationWindow` Component

-   **Goal:** Extract the entire chain configuration UI into its own component. This is a major opportunity for a UI/UX and logic overhaul.
-   **Source File:** `lib/livechain_web/dashboard/dashboard.ex`
-   **Target File (New):** `lib/livechain_web/components/chain_configuration_window.ex`

**Implementation:**

1.  **Create the Component File:**
    -   Create `lib/livechain_web/components/chain_configuration_window.ex`.
    -   Define the module `LivechainWeb.Components.ChainConfigurationWindow` and `use LivechainWeb, :live_component`.

2.  **Move State, Events, and PubSub Logic from `Dashboard`:**
    -   Move all assigns starting with `:chain_config_`, `:config_`, and `:quick_add_` from `dashboard.ex` `mount/1` (lines `~81-89`) into the new component's `mount/1`.
    -   Move the entire block of chain config `handle_event/3` functions (lines `~1153` to `~1415`) into the new component.
    -   Move the chain config `handle_info/2` clauses (lines `~500-608`) into the new component.
    -   In the new component's `mount/1`, add the necessary `Phoenix.PubSub.subscribe` calls.

3.  **Update `Dashboard` and Render the New Component:**
    -   In `dashboard.ex`, simplify `handle_event("toggle_chain_config", ...)` to only toggle a single assign, e.g., `@chain_config_open`.
    -   In `dashboard.ex`'s `dashboard_tab_content` function, replace the old call with the new stateful component:
        ```elixir
        <.live_component
          module={LivechainWeb.Components.ChainConfigurationWindow}
          id="chain-configuration-window"
          is_open={@chain_config_open}
        />
        ```

---

## 5. Phase 3: The Final "Container" LiveView

**Goal:** The `Dashboard` LiveView is now significantly smaller and has a much clearer responsibility.

### Final State of `dashboard.ex`:

-   **`mount/1`:** Will be much smaller. It will only subscribe to core data topics (`ws_connections`, `routing:decisions`, etc.) and initialize global state like `@connections`.
-   **`handle_info/2`:** Will only handle the core data events.
-   **`handle_event/3`:** Will only handle top-level events like `switch_tab` and `select_chain`.
-   **`render/1`:** Will act as a layout, rendering the major stateful components and passing down the global data they need.

## 6. Summary of Changes

| Component / Area | Action | Responsibility After Refactor |
| :--- | :--- | :--- |
| **`Dashboard` LiveView** | Becomes a "Container" | Manages layout, tabs, and global data (`@connections`, `@routing_events`). Passes data to children. |
| **`DashboardComponents`** | New helper module | Contains pure rendering logic for forms and static tabs. |
| **`SimulatorControls`** | Becomes fully stateful | Manages all simulator state and events. **Opportunity for UI/logic overhaul.** |
| **`ChainConfigurationWindow`** | New stateful component | Manages chain/provider CRUD. **Opportunity for UI/logic overhaul.** |
| **`FloatingDetailsWindow`** | (Already a component) | Continues to display details, receiving global data from the `Dashboard` parent. |