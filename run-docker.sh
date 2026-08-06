#!/bin/bash

# Simple Docker runner for Lasso RPC
echo "🚀 Starting Lasso RPC with Docker..."

# Check if Docker is installed and running
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first:"
    echo "   https://docs.docker.com/get-docker/"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo "❌ Docker daemon is not running. Please start Docker and try again."
    exit 1
fi

echo "✅ Docker is available and running"

# Build and run the container
echo "🔨 Building Docker image..."
if docker build -t lasso-rpc .; then
    echo "✅ Image built successfully"
else
    echo "❌ Failed to build Docker image"
    exit 1
fi

echo "🚀 Starting Lasso RPC container..."
echo "📊 Live Dashboard: http://localhost:4000"
echo "🔌 RPC Endpoint: http://localhost:4000/rpc/fastest/ethereum"
echo ""
echo "Press Ctrl+C to stop the server"

# Generate SECRET_KEY_BASE if not set
if [ -z "$SECRET_KEY_BASE" ]; then
    echo "Generating SECRET_KEY_BASE..."
    SECRET_KEY_BASE=$(openssl rand -base64 48)
fi

# Production releases require a stable node identity. Keep local Docker usable
# without extra setup while allowing callers to supply their own value.
LASSO_NODE_ID="${LASSO_NODE_ID:-docker-local}"

# Run the container
docker run --rm \
    -p 4000:4000 \
    -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
    -e LASSO_NODE_ID="$LASSO_NODE_ID" \
    --name lasso-rpc \
    lasso-rpc
