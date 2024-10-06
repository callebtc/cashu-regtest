# docker-fulcrum
A Docker container for running a [Fulrum server](https://github.com/cculianu/Fulcrum).

## Install
These instructions assume you are using Docker installed on Ubuntu 18.04.

- Clone the repo: `git clone https://github.com/christroutner/docker-fulcrum && cd docker-fulcrum`
- Edit the mainnet.conf or testnet.conf file to reflect your settings.
- Edit the Dockerfile to reflect your settings.
- Edit the docker-compose.yml file to point to where the database should live.

### Create SSL certificate
Fulcrum requires an SSL certificate in order to operate. You can generate a self-signed
certificate or you get an SSL certificate from Let's Encrypt.

#### Generate a self-signed Certificate
Follow these instructions to generate your own self signed certificate. You'll
end up with two files: server.crt is the public key and certificate. server.key
is the private key.

- `sudo apt update`
- `sudo apt install openssl`
- `openssl genrsa -des3 -out server.pass.key 2048`
- `openssl rsa -in server.pass.key -out server.key`
- `rm server.pass.key`
- `openssl req -new -key server.key -out server.csr`
- `openssl x509 -req -sha256 -days 365 -in server.csr -signkey server.key -out server.crt`
- `rm server.csr`

#### Integrate a Let's Encrypt Certificate
TODO: add instructions here

After successfully registering with Let's Encrypt, you should end up with two
files: fullchain.pem (the public key and certificate) and privkey.pem (the
private key).

### Build the Docker Container
- Update the `docker-compose.yml` file with the path to where you want to store the blockchain data.
- `docker-compose build`
- `docker-compose up -d`

#### comments
Uno comment