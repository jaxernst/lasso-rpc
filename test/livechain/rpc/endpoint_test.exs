defmodule Livechain.RPC.EndpointTest do
  use ExUnit.Case, async: true

  alias Livechain.RPC.Endpoint

  describe "new/1" do
    test "creates a new endpoint with required fields" do
      endpoint =
        Endpoint.new(
          id: "ethereum_mainnet",
          name: "Ethereum Mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY",
          chain_id: 1
        )

      assert endpoint.id == "ethereum_mainnet"
      assert endpoint.name == "Ethereum Mainnet"
      assert endpoint.url == "https://mainnet.infura.io/v3/YOUR_KEY"
      assert endpoint.chain_id == 1
      assert endpoint.timeout == 30_000
      assert endpoint.max_retries == 3
      assert endpoint.enabled == true
    end

    test "allows overriding default values" do
      endpoint =
        Endpoint.new(
          id: "polygon",
          name: "Polygon",
          url: "https://polygon-rpc.com",
          chain_id: 137,
          timeout: 60_000,
          max_retries: 5,
          enabled: false
        )

      assert endpoint.timeout == 60_000
      assert endpoint.max_retries == 5
      assert endpoint.enabled == false
    end
  end

  describe "validate/1" do
    test "returns ok for valid endpoint" do
      endpoint =
        Endpoint.new(
          id: "ethereum_mainnet",
          name: "Ethereum Mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY",
          chain_id: 1
        )

      assert {:ok, ^endpoint} = Endpoint.validate(endpoint)
    end

    test "returns error for missing id" do
      endpoint =
        Endpoint.new(
          name: "Ethereum Mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY",
          chain_id: 1
        )

      assert {:error, "Endpoint ID is required"} = Endpoint.validate(endpoint)
    end

    test "returns error for empty id" do
      endpoint =
        Endpoint.new(
          id: "",
          name: "Ethereum Mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY",
          chain_id: 1
        )

      assert {:error, "Endpoint ID is required"} = Endpoint.validate(endpoint)
    end

    test "returns error for missing name" do
      endpoint =
        Endpoint.new(
          id: "ethereum_mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY",
          chain_id: 1
        )

      assert {:error, "Endpoint name is required"} = Endpoint.validate(endpoint)
    end

    test "returns error for missing url" do
      endpoint =
        Endpoint.new(
          id: "ethereum_mainnet",
          name: "Ethereum Mainnet",
          chain_id: 1
        )

      assert {:error, "Endpoint URL is required"} = Endpoint.validate(endpoint)
    end

    test "returns error for missing chain_id" do
      endpoint =
        Endpoint.new(
          id: "ethereum_mainnet",
          name: "Ethereum Mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY"
        )

      assert {:error, "Chain ID is required"} = Endpoint.validate(endpoint)
    end

    test "returns error for invalid timeout" do
      endpoint =
        Endpoint.new(
          id: "ethereum_mainnet",
          name: "Ethereum Mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY",
          chain_id: 1,
          timeout: 0
        )

      assert {:error, "Timeout must be greater than 0"} = Endpoint.validate(endpoint)
    end

    test "returns error for invalid max_retries" do
      endpoint =
        Endpoint.new(
          id: "ethereum_mainnet",
          name: "Ethereum Mainnet",
          url: "https://mainnet.infura.io/v3/YOUR_KEY",
          chain_id: 1,
          max_retries: -1
        )

      assert {:error, "Max retries must be non-negative"} = Endpoint.validate(endpoint)
    end
  end
end
