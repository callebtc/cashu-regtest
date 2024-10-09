#!/bin/bash
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

run_comments(){
  comment=$1
  value=$2
  printf "\033[;1;33mADVICE\033[;0m $comment: $value\n"
}

bitcoin-cli-sim() {
  docker exec cashu-bitcoind-1 bitcoin-cli -rpcuser=cashu -rpcpassword=cashu -regtest "$@"
}

bitcoin-cli-sim loadwallet cashu > /dev/null
echo "mining 101 blocks..."
bitcoin-cli-sim -named -rpcwallet=cashu -generate 101 > /dev/null
#bitcoin-cli-sim -named -rpcwallet=$wallet generatetoaddress 5 $(bitcoin-cli-sim -named -rpcwallet=$wallet getnewaddress)
run_comments "cashu balance after mining" $(bitcoin-cli-sim -named -rpcwallet=cashu getbalance)


for i in 1 2 3; do
  wallet="wallet-$i"
  if ! bitcoin-cli-sim -named listwallets | grep -q "\"$wallet\""; then
    bitcoin-cli-sim -named createwallet $wallet
    run_comments "$wallet created with" "0.00000000"
  else
    run_comments "$wallet balance " $(bitcoin-cli-sim -named -rpcwallet=$wallet getbalance)
  fi
  #bitcoin-cli-sim loadwallet cashu > /dev/null
  #echo "mining 5 blocks..."
  #bitcoin-cli-sim -named -rpcwallet=cashu -generate 5 > /dev/null
  #bitcoin-cli-sim -named -rpcwallet=$wallet generatetoaddress 5 $(bitcoin-cli-sim -named -rpcwallet=$wallet getnewaddress)
  #run_comments "cashu balance after mining" $(bitcoin-cli-sim -named -rpcwallet=cashu getbalance)
  #run_comments "$wallet balance after mining" $(bitcoin-cli-sim -named -rpcwallet=$wallet getbalance)
done

for i in $(seq 1 350);do
  # Generar direcciones de recepción para wallet-2 y wallet-3
  address_wallet_1=$(bitcoin-cli-sim -named -rpcwallet=wallet-1 getnewaddress)
  address_wallet_2=$(bitcoin-cli-sim -named -rpcwallet=wallet-2 getnewaddress)
  address_wallet_3=$(bitcoin-cli-sim -named -rpcwallet=wallet-3 getnewaddress)

  # Enviar 10 BTC a wallet-2 y wallet-3 desde wallet-1
  txid=$(bitcoin-cli-sim -named -rpcwallet=cashu sendmany "" "{\"$address_wallet_2\":8,\"$address_wallet_3\":9}")
  txid=$(bitcoin-cli-sim -named -rpcwallet=cashu sendmany "" "{\"$address_wallet_1\":4,\"$address_wallet_3\":5}")
  txid=$(bitcoin-cli-sim -named -rpcwallet=cashu sendmany "" "{\"$address_wallet_2\":3,\"$address_wallet_1\":7}")
done

bitcoin-cli-sim -named generatetoaddress 1 $(bitcoin-cli-sim -named -rpcwallet=wallet-1 getnewaddress)
# Verificar los balances después de la transacción
#
run_comments "wallet-1 balance after transaction" $(bitcoin-cli-sim -named -rpcwallet=wallet-1 getbalance)
run_comments "wallet-2 balance after transaction" $(bitcoin-cli-sim -named -rpcwallet=wallet-2 getbalance)
run_comments "wallet-3 balance after transaction" $(bitcoin-cli-sim -named -rpcwallet=wallet-3 getbalance)
