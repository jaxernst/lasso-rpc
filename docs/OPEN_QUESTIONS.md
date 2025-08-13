- Can the ethereum JSON rpc protocol work entirely over websockets? If I'm building an app with ethers or viem, could I only provide a ws:// connection url for a blockchain node provider and still see the same functionality? Why wouldn't a developer use only ws connections if websockets are faster and less overhead?

- (Depending on the answer to the above question) Would it make sense to have this rpc orchestration service only talk to rpc providers with websocket connections? I've been assuming that we'll have many client connections for a single rpc provider ws connection, but I have not deeply considered how http plays into this and whether or not we would want to directly forward http requests to the providers as is (without going through websockets).

- Is the process registry + global naming system setup to follow best Elixir practices for a highly scalable and fault tolerant system like the one I'm building? I'm not sure what the relationship is between the ProcessRegistry, :global store, GenServers conventions, supervisors, etc. I found this from the genserver docs about naming and process management, but I'm not sure we're following these conventions? I also see the 'ProcessRegistry' does not seem to be used that much in the codebase so I'm not sure if its been fully migrated to:

```
(in genserver docs)

Name registration
Both start_link/3 and start/3 support the GenServer to register a name on start via the :name option. Registered names are also automatically cleaned up on termination. The supported values are:

an atom - the GenServer is registered locally (to the current node) with the given name using Process.register/2.

{:global, term} - the GenServer is registered globally with the given term using the functions in the :global module.

{:via, module, term} - the GenServer is registered with the given mechanism and name. The :via option expects a module that exports register_name/2, unregister_name/1, whereis_name/1 and send/2. One such example is the :global module which uses these functions for keeping the list of names of processes and their associated PIDs that are available globally for a network of Elixir nodes. Elixir also ships with a local, decentralized and scalable registry called Registry for locally storing names that are generated dynamically.

If there is an interest to register dynamic names locally, do not use atoms, as atoms are never garbage-collected and therefore dynamically generated atoms won't be garbage-collected. For such cases, you can set up your own local registry by using the Registry module.
```

- Are we configured to support all ethereum json rpc methods? I see that rpc_controller.ex has handlers setup for specific methods, which got me thinking: we are acting as middleware to rpc providers, so could we just forward the rpc requests to effectively 'support' all of them? (I intended this to use readonly rpc methods but maybe supporting blockchain write operations could be unlocked for 'free'?)
