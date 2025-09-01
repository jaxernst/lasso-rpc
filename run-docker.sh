#!/bin/bash

# Simple Docker runner for Lasso RPC
echo "🚀 Starting Lasso RPC with Docker..."

# Build and run the container
docker build -t lasso-rpc .
docker run --rm -p 4000:4000 --name lasso-rpc lasso-rpc

echo "🎯 Lasso RPC will be available at: http://localhost:4000"