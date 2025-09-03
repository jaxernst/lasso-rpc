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

# Run the container
docker run --rm -p 4000:4000 --name lasso-rpc lasso-rpc