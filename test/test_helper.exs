ExUnit.start()

Mox.defmock(Livechain.RPC.HttpClientMock, for: Livechain.RPC.HttpClient)

# Use the mock adapter for HTTP client in tests
Application.put_env(:livechain, :http_client, Livechain.RPC.HttpClientMock)
