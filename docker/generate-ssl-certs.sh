#!/bin/bash

# Generate self-signed SSL certificates for local development
SSL_DIR="./docker/nginx/ssl"

# Create SSL directory if it doesn't exist
mkdir -p "$SSL_DIR"

# Generate private key
openssl genrsa -out "$SSL_DIR/key.pem" 2048

# Generate certificate
openssl req -new -x509 -key "$SSL_DIR/key.pem" -out "$SSL_DIR/cert.pem" -days 365 -subj "/C=US/ST=Local/L=Local/O=Lasso/OU=Dev/CN=localhost"

echo "SSL certificates generated in $SSL_DIR"
echo "You can now run: docker-compose up"