# 🚀 Hackathon Judge Setup Guide

Welcome judges! This guide will get you up and running with Lasso RPC quickly.

## Prerequisites

- **Docker** (required) - [Download here](https://docs.docker.com/get-docker/)
- **Git** (to clone the repo)

## Quick Start (Recommended)

### Option 1: Unix-like Systems (Linux, macOS, Git Bash)

```bash
# 1. Clone the repository
git clone https://github.com/LazerTechnologies/lasso-rpc.git
cd livechain

# 3. Run with one command
./run-docker.sh
```

### Option 2: Windows Command Prompt

```cmd
# 1. Clone the repository
git clone <repository-url>
cd livechain

# 2. Run with one command
run-docker.bat
```

That's it! 🎉

## What You'll Get

- **Live Dashboard**: http://localhost:4000
- **RPC Endpoint**: http://localhost:4000/rpc/fastest/ethereum
- **Multiple Chains**: Ethereum, Polygon, Base, Arbitrum, Optimism, zkSync, and more
- **4 Routing Strategies**: Fastest, Cheapest, Priority, Round-Robin

## Test It Out

Once running, try these quick tests:

```bash
# Test Ethereum RPC
curl -X POST http://localhost:4000/rpc/fastest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Test Polygon RPC
curl -X POST http://localhost:4000/rpc/fastest/polygon \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Troubleshooting

**run-docker.sh script not executable?**

```bash
chmod +x run-docker.sh
```

**On Windows and script doesn't work?**

```cmd
run-docker.bat
```

**Docker not found?**

```bash
# Install Docker Desktop for your OS
# https://docs.docker.com/get-docker/
```

**Port 4000 already in use?**

```bash
# Stop any existing containers
docker stop lasso-rpc
# Or use a different port
docker run --rm -p 4001:4000 --name lasso-rpc lasso-rpc
```

**Build fails?**

```bash
# Clean Docker cache and retry
docker system prune -f
./run-docker.sh
```

## What Makes This Special

- **Multi-Provider Orchestration**: Routes requests across 6+ providers per chain
- **Intelligent Failover**: Automatically switches to working providers
- **Performance Optimization**: Routes to fastest provider based on real metrics
- **Zero Configuration**: Works out of the box with public RPC providers
- **Live Monitoring**: Real-time dashboard showing provider performance

## Architecture Highlights

- Built on **Elixir/OTP** for fault-tolerance and massive concurrency
- **Circuit breakers** prevent cascade failures
- **Passive benchmarking** measures real RPC performance
- **WebSocket support** for subscriptions
- **Distributed-ready** Low-complexity path to global deployment with local node latency optimization
