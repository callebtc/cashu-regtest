#!/bin/bash

# Path to the working directory
WORK_DIR="/home/safeuser"
LOG_FILE="$WORK_DIR/setup-openssl.log"

# Create a new log file
echo "Starting OpenSSL setup" > "$LOG_FILE"

# Change to the working directory
if [ ! -d "$WORK_DIR" ]; then
    echo "Working directory $WORK_DIR does not exist." >> "$LOG_FILE"
    exit 1
fi

cd "$WORK_DIR" || { echo "Could not change to directory $WORK_DIR" >> "$LOG_FILE"; exit 1; }

# Check the OpenSSL version
{
        echo "Checking OpenSSL version..."
        openssl version >> "$LOG_FILE" 2>&1
} || {
        echo "Error checking OpenSSL version." >> "$LOG_FILE"
        exit 1
}

# Generate a private key without a passphrase
{
        echo "Generating private key..."
        openssl genrsa -out server.key 2048 >> "$LOG_FILE" 2>&1
} || {
        echo "Error generating private key." >> "$LOG_FILE"
        exit 1
}

# Check if the private key has been created
if [ ! -f "server.key" ]; then
    echo "Could not generate private key." >> "$LOG_FILE"
    exit 1
fi

# Create a Certificate Signing Request (CSR)
{
        echo "Generating CSR..."
        openssl req -new -key server.key -out server.csr -config openssl.cnf -batch >> "$LOG_FILE" 2>&1
} || {
        echo "Error generating Certificate Signing Request (CSR)." >> "$LOG_FILE"
        exit 1
}

# Check if the CSR has been created
if [ ! -f "server.csr" ]; then
    echo "Could not generate Certificate Signing Request (CSR)." >> "$LOG_FILE"
    exit 1
fi

# Generate a self-signed certificate
{
        echo "Generating certificate..."
        openssl x509 -req -sha256 -days 365 -in server.csr -signkey server.key -out server.crt -extensions req_ext -extfile openssl.cnf >> "$LOG_FILE" 2>&1
} || {
        echo "Error generating certificate." >> "$LOG_FILE"
        exit 1
}

# Check if the certificate has been created
if [ ! -f "server.crt" ]; then
    echo "Could not generate certificate." >> "$LOG_FILE"
    exit 1
fi

# Delete temporary files if they exist
{
        echo "Deleting temporary files..."
        rm -f server.csr >> "$LOG_FILE" 2>&1
} || {
        echo "Error deleting temporary files." >> "$LOG_FILE"
}

echo "Process completed successfully." >> "$LOG_FILE"

