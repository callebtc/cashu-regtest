#!/bin/sh
print_success() {
  printf "\033[;1;32mPASSED\033[;0m $1\n"
}

print_error() {
  printf "\033[;1;31mFAILED\033[;0m $1\n"
}

run(){
  label=$1
  value=$2
  cmd=$3
  if [[ "$cmd" == "$value" ]]; then
    print_success "$label is $cmd"
  else
    print_error "$label is $cmd, should be $value"
    failed="true"
  fi
}

bitcoin-cli-sim() {
  docker exec cashu-bitcoind-1 bitcoin-cli -rpcuser=cashu -rpcpassword=cashu -regtest "$@"
}

for i in 1; do
  wallet="wallet-$i"
  #bitcoin-cli-sim -named createwallet $wallet
  run "$wallet balance" "0.00000000" $(bitcoin-cli-sim -named -rpcwallet=$wallet getbalance)
  bitcoin-cli-sim -named -rpcwallet=$wallet generatetoaddress 1 $(bitcoin-cli-sim -named -rpcwallet=$wallet getnewaddress)
  run "$wallet balance after mining" "50.00000000" $(bitcoin-cli-sim -named -rpcwallet=$wallet getbalance)
done

# Minar para wallet-1 y verificar balance
bitcoin-cli-sim -named -rpcwallet=wallet-1 generatetoaddress 101 $(bitcoin-cli-sim -named -rpcwallet=wallet-1 getnewaddress)
run "wallet-1 balance after mining" "50.00000000" $(bitcoin-cli-sim -named -rpcwallet=wallet-1 getbalance)

# Generar direcciones de recepción para wallet-2 y wallet-3
address_wallet_2=$(bitcoin-cli-sim -named -rpcwallet=wallet-2 getnewaddress)
address_wallet_3=$(bitcoin-cli-sim -named -rpcwallet=wallet-3 getnewaddress)

# Enviar 10 BTC a wallet-2 y wallet-3 desde wallet-1
txid=$(bitcoin-cli-sim -named -rpcwallet=wallet-1 sendmany "" "{\"$address_wallet_2\":10,\"$address_wallet_3\":10}")

# Confirmar la transacción minando bloques adicionales
bitcoin-cli-sim -named generatetoaddress 1 $(bitcoin-cli-sim -named -rpcwallet=wallet-1 getnewaddress)

# Verificar los balances después de la transacción
run "wallet-1 balance after transaction" "29.99990000" $(bitcoin-cli-sim -named -rpcwallet=wallet-1 getbalance)
run "wallet-2 balance after transaction" "10.00000000" $(bitcoin-cli-sim -named -rpcwallet=wallet-2 getbalance)
run "wallet-3 balance after transaction" "10.00000000" $(bitcoin-cli-sim -named -rpcwallet=wallet-3 getbalance)
