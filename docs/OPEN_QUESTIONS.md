1. Is the process registry + global naming system setup to follow best Elixir practices for a highly scalable and fault tolerant system like the one I'm building? I'm not sure what the relationship is between the ProcessRegistry, :global store, GenServers conventions, supervisors, etc. I found this from the genserver docs about naming and process management, but I'm not sure we're following these conventions? I also see the 'ProcessRegistry' does not seem to be used that much in the codebase so I'm not sure if its been fully migrated to:

```
(in genserver docs)

Name registration
Both start_link/3 and start/3 support the GenServer to register a name on start via the :name option. Registered names are also automatically cleaned up on termination. The supported values are:

an atom - the GenServer is registered locally (to the current node) with the given name using Process.register/2.

{:global, term} - the GenServer is registered globally with the given term using the functions in the :global module.

{:via, module, term} - the GenServer is registered with the given mechanism and name. The :via option expects a module that exports register_name/2, unregister_name/1, whereis_name/1 and send/2. One such example is the :global module which uses these functions for keeping the list of names of processes and their associated PIDs that are available globally for a network of Elixir nodes. Elixir also ships with a local, decentralized and scalable registry called Registry for locally storing names that are generated dynamically.

If there is an interest to register dynamic names locally, do not use atoms, as atoms are never garbage-collected and therefore dynamically generated atoms won't be garbage-collected. For such cases, you can set up your own local registry by using the Registry module.
```

2. How do we consider regionality across our system when it comes to latency measurements and benchmarking? We currently have 'region' config for providers, but this could be misguided and not very useful for big node rpc providers that are multi-region. It would be nice to support advanced regionality awareness in this system - somethings like 'discovering' the lowest latency json rpc method returns relative to the livechain node that is forward the request). So then if this platform was multiregion, they ar
