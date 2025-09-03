@echo off
REM Windows batch file for running Lasso RPC with Docker
echo 🚀 Starting Lasso RPC with Docker...

REM Check if Docker is installed
docker --version >nul 2>&1
if errorlevel 1 (
    echo ❌ Docker is not installed. Please install Docker first:
    echo    https://docs.docker.com/get-docker/
    pause
    exit /b 1
)

REM Check if Docker daemon is running
docker info >nul 2>&1
if errorlevel 1 (
    echo ❌ Docker daemon is not running. Please start Docker and try again.
    pause
    exit /b 1
)

echo ✅ Docker is available and running

REM Build and run the container
echo 🔨 Building Docker image...
docker build -t lasso-rpc .
if errorlevel 1 (
    echo ❌ Failed to build Docker image
    pause
    exit /b 1
)

echo ✅ Image built successfully
echo 🚀 Starting Lasso RPC container...
echo 📊 Live Dashboard: http://localhost:4000
echo 🔌 RPC Endpoint: http://localhost:4000/rpc/fastest/ethereum
echo.
echo Press Ctrl+C to stop the server

REM Run the container
docker run --rm -p 4000:4000 --name lasso-rpc lasso-rpc
