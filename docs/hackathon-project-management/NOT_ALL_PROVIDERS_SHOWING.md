The architecture has a fundamental conceptual flaw: it conflates "connections" with "providers". The
network topology renders list_all_connections() which only returns providers with active WebSocket
processes, completely hiding HTTP-only providers.

Current Broken Flow

chains.yml (6 Base providers)
↓
ChainSupervisor (starts 2 WSConnections - only those with ws_url)
↓
list_all_connections() (returns 2 providers - only active WS)
↓
Network Topology (renders 2 nodes)

Proper Architecture Should Be

chains.yml (6 Base providers)
↓
list_all_providers() (returns ALL 6 with status)
↓
Network Topology (renders 6 nodes with different status indicators)

Detailed Implementation Plan

Phase 1: Create Unified Provider Status System

1.1 New Function: ChainRegistry.list_all_providers()
def list_all_providers do
all_chains = ConfigStore.get_all_chains()

    Enum.flat_map(all_chains, fn {chain_name, chain_config} ->
      Enum.map(chain_config.providers, fn provider ->
        %{
          id: provider.id,
          name: provider.name,
          chain: chain_name,
          type: determine_provider_type(provider), # "http", "websocket", "both"
          status: determine_provider_status(chain_name, provider),
          # ... other fields
        }
      end)
    end)

end

1.2 Enhanced Status Determination
defp determine_provider_status(chain_name, provider) do
case {has_websocket?(provider), has_circuit_breaker?(provider.id)} do
{true, true} -> # WebSocket provider - check WS connection + circuit breaker
merge_ws_and_circuit_status(chain_name, provider.id)

      {false, true} ->
        # HTTP-only provider - check circuit breaker + recent call history
        determine_http_provider_status(provider.id)

      {_, false} ->
        # No circuit breaker yet - provider is configured but not initialized
        :configured
    end

end

Phase 2: Backend Status Tracking Enhancement

2.1 HTTP Provider Status Tracking

- Extend CircuitBreaker to track HTTP-only provider health
- Add metrics for recent HTTP call success rates
- Status levels: :healthy, :degraded, :unhealthy, :circuit_open

  2.2 Unified Status Interface
  defmodule Livechain.RPC.ProviderStatus do
  def get_comprehensive_status(provider_id) do
  circuit_status = CircuitBreaker.get_status(provider_id)
  ws_status = WSConnection.get_status(provider_id) # nil if HTTP-only

      %{
        overall_status: determine_overall_status(circuit_status, ws_status),
        circuit_state: circuit_status.state,
        websocket_connected: ws_status && ws_status.connected,
        last_success: get_last_success_time(provider_id),
        # ...
      }

  end
  end

Phase 3: Dashboard Integration

3.1 Update Dashboard Data Fetching

# In dashboard.ex fetch_connections/1

defp fetch_connections(socket) do
providers = Livechain.RPC.ChainRegistry.list_all_providers() # NEW
latency_leaders = MetricsHelpers.get_latency_leaders_by_chain(providers)

    socket
    |> assign(:connections, providers) # Keep same variable name for UI compatibility
    |> assign(:latency_leaders, latency_leaders)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())

end

Phase 4: Network Topology Visual Enhancement

4.1 Provider Type Differentiation

# In network_topology.ex

defp provider_visual_class(provider) do
base_class = provider_status_class(provider)
type_modifier = case provider.type do
"websocket" -> "border-solid" # Solid border for WebSocket
"http" -> "border-dashed" # Dashed border for HTTP-only
"both" -> "border-double" # Double border for both
end

    "#{base_class} #{type_modifier}"

end

4.2 Status Icon System
defp provider*status_icon(provider) do
case {provider.type, provider.status} do
{"websocket", :connected} -> "🔗" # Connected WebSocket
{"http", :healthy} -> "🌐" # Healthy HTTP
{"http", :degraded} -> "⚠️" # Degraded HTTP
{*, :circuit_open} -> "🚫" # Circuit breaker open # ...
end
end

Phase 5: Event System Updates

5.1 HTTP Provider Event Broadcasting

- Extend circuit breaker events to include HTTP call results
- Broadcast HTTP provider status changes to dashboard
- Add synthetic events for HTTP-only providers

  5.2 Unified Event Stream

# HTTP provider events should trigger dashboard updates too

Phoenix.PubSub.broadcast(
Livechain.PubSub,
"provider_pool:events",
%{
ts: System.system_time(:millisecond),
chain: chain_name,
provider_id: provider_id,
event: :http_call_completed,
status: :success,
duration_ms: duration
}
)

Implementation Order & Risk Assessment

Low Risk (Start Here):

1. Create list_all_providers() function alongside existing list_all_connections()
2. Add provider type detection logic
3. Test with existing UI using new data source

Medium Risk:

1. Enhanced status determination for HTTP providers
2. Visual differentiation in network topology
3. Event system extensions

High Risk (Final Phase):

1. Replace list_all_connections() completely
2. Comprehensive event system overhaul
3. Performance optimization for larger provider sets

Key Benefits After Fix

1. Complete Visibility: All configured providers shown regardless of connection type
2. Proper Status Tracking: HTTP providers get appropriate health monitoring
3. Visual Clarity: Different provider types clearly distinguished
4. Better Debugging: Can see when HTTP providers are failing vs just not visible
5. Architectural Consistency: Providers and connections properly separated

This is a significant architectural improvement that properly separates configuration (providers) from
runtime state (connections).
