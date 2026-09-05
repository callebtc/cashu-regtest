![TESTS](https://github.com/lnbits/legend-regtest-enviroment/actions/workflows/ci.yml/badge.svg)

# Node versions

Pinned stable releases (checked 2026-09-05):

| Node | Release |
| --- | --- |
| Bitcoin Core | [31.1](https://github.com/bitcoin/bitcoin/releases/tag/v31.1) |
| LND (all three nodes) | [0.21.3-beta](https://github.com/lightningnetwork/lnd/releases/tag/v0.21.3-beta) |
| Core Lightning (core nodes and Bark) | [26.06.7](https://github.com/ElementsProject/lightning/releases/tag/v26.06.7) |

Images are pinned by multiarchitecture manifest digest for AMD64 and ARM64.
LND and CLN use official upstream images. CLN is pinned to the corrected
26.06.7 manifest documented in its release notes, not the earlier incorrect
image published under that tag. Bark retains its pinned hold-invoice plugin.

# nodes
* lnd-1: for testing your software
* lnd-2: used for boltz backend
* lnd-3: used for lnbits inside docker
* cln-1: for testing your software
* cln-2: used for clightning-REST

The optional Spark profile also runs three Spark Operators (a 2-of-3
threshold), an `open-ssp` provider, Electrs, and an `ldk-server` Lightning
node connected to `lnd-1`.

# Installing regtest 
get the regtest environment ready
```sh
# Install docker https://docs.docker.com/engine/install/
# Make sure your user has permission to use docker 'sudo usermod -aG docker ${USER}' then reboot
# Stop/start docker 'sudo systemctl stop docker' 'sudo systemctl start docker'

git clone https://github.com/callebtc/cashu-regtest.git
cd cashu-regtest
./start.sh  # start the regtest and also run tests
```

## Optional Arkade regtest

Run `./start.sh --arkade` to start Arkade with real Boltz/Fulmine Lightning
swaps and test a temporary wallet's onchain and Lightning send/receive flows.
It can be combined with `--spark --bark`. See [Arkade setup and tests](arkade/README.md)
for pinned versions, local endpoints, fee behavior, and test coverage.

## Optional Bark / Ark regtest

```sh
./start.sh --bark
# Or enable both optional L2 stacks:
./start.sh --spark --bark
```

The Bark profile adds Second's `captaind` Ark server, private PostgreSQL,
and a dedicated Core Lightning node with Boltz's hold-invoice plugin. It opens
a 24,000,000-sat channel from `lnd-1` with a 12,000,000-sat push and funds the
server's onchain wallet. Startup waits for channel gossip routes, and the
payment test waits for every Lightning node's exact Bitcoin block height to
avoid stale-height HTLC expiry failures. Core-only `./start.sh` is unchanged.

The Bark checks also require `jq`, `xxd`, and `openssl` on the host.
The first native ARM64/AMD64 source build can take tens of minutes. The wallet
and server use the same pinned Bark revision; no local upstream checkout is
needed:

* Bark / captaind (MIT): `ark-bitcoin/bark@e3d4174ca08a3c97bc23e1e73aa5332d725a7689`
* Hold plugin: `BoltzExchange/hold@af0055b132f3b9f24d0b1d478a15005fcf8f014f` (v0.3.3)
* Dedicated CLN: `elementsproject/lightningd:v26.06.7` (corrected digest pinned)

Startup creates a temporary Bark wallet, receives 1,000,000 confirmed Bitcoin
sats, sends an onchain payment, boards 250,000 sats into Ark, pays 3,000-sat
invoices on both LND and CLN, and receives 5,000-sat Lightning payments from
each. It checks settlement and payment hashes/preimages, credits after fees,
then confirms a 20,000-sat cooperative Ark-to-Bitcoin offboard. Normal Bark and
Lightning forwarding fees remain enabled. This tests cooperative operation,
not unilateral exits or server-failure recovery. A separate 90-minute CI job
runs the same acceptance script; the core job keeps its 10-minute limit.

Only the public Bark RPC is published, at `http://127.0.0.1:3535`.
PostgreSQL, CLN, hold gRPC, and the unauthenticated admin RPC remain private.
External Bark wallets should use the pinned version, `--regtest`, that Ark URL,
and a reachable regtest Bitcoin RPC or Esplora endpoint. The bundled wallet
already has access to Bitcoin Core inside Docker:

```sh
source ./docker-scripts.sh
bark-cli-sim balance
bark-cli-sim onchain address
bark-cli-sim lightning invoice '5000 sat'
# After a payer starts paying the hold invoice, claim it to settle:
bark-cli-sim lightning claim '<invoice>' --wait
captaind-cli-sim wallet
bark-lightning-cli-sim getinfo
```

All Bark state, including the temporary wallet mnemonic, lives in Docker
volumes and is deleted by the existing full-start / `down --volumes` lifecycle.
Every full start creates new identities. Credentials and disabled receive
anti-DoS requirements are for disposable regtest only; never use real funds.

## Optional Spark SO/SSP regtest

Start the core environment plus the Spark Operator and Service Provider stack:

```sh
./start.sh --spark
```

The Spark path builds its upstream components from pinned Git commits. The
first build can take 30-90 minutes; later runs reuse Docker's build cache. It
then creates balanced Lightning liquidity between `lnd-1` and `ldk-server`,
funds the SSP's Spark wallet, and tests both a Spark-to-Lightning payment and a
Lightning-to-Spark payment through the real SDK.

The pinned components are:

* Spark Operators: `buildonspark/spark@0b3a32a05c9ac06cc411683551dd1f1bde9d0caa`
* SSP: `benthecarman/open-ssp@04f8330b0bd76335c3b9798b73f2fc0a3622d7d5`
* Lightning backend: `lightningdevkit/ldk-server@6d6d810714706c225ce7effc2163eff6a1b54221`
* Esplora backend: `mempool/electrs@5b8819039dc1ad1dddf2c3c293ec8825975680f8`
* Test SDK: `benthecarman/spark@06614d2e3535385f15aef3749b2c8a780f679ebc`

The pinned official Operator contains the open-source counter-swap consensus
implementation, but its public protobuf does not expose the RPC used by this
`open-ssp` revision. The Operator image applies the small compatibility patch
in `spark/operator-build/open-ssp-rpc.patch` to expose that existing handler;
the swap implementation itself remains the pinned upstream code.

The public `open-ssp` repository did not contain an explicit software license
at the pinned revision. This project consumes that revision as a remote local
build and does not vendor its source. Confirm the upstream license before
redistributing the resulting image.

### Connecting a Spark wallet

Use the local network and read the SSP identity generated for the current run:

```sh
curl http://localhost:5000/identity
```

Configure the SDK with:

```json
{
  "network": "LOCAL",
  "threshold": 2,
  "electrsUrl": "http://localhost:30000",
  "signingOperators": {
    "0000000000000000000000000000000000000000000000000000000000000001": {
      "id": 0,
      "identifier": "0000000000000000000000000000000000000000000000000000000000000001",
      "address": "https://localhost:8535",
      "identityPublicKey": "0322ca18fc489ae25418a0e768273c2c61cabb823edfb14feb891e9bec62016510"
    },
    "0000000000000000000000000000000000000000000000000000000000000002": {
      "id": 1,
      "identifier": "0000000000000000000000000000000000000000000000000000000000000002",
      "address": "https://localhost:8536",
      "identityPublicKey": "0341727a6c41b168f07eb50865ab8c397a53c7eef628ac1020956b705e43b6cb27"
    },
    "0000000000000000000000000000000000000000000000000000000000000003": {
      "id": 2,
      "identifier": "0000000000000000000000000000000000000000000000000000000000000003",
      "address": "https://localhost:8537",
      "identityPublicKey": "0305ab8d485cc752394de4981f8a5ae004f2becfea6f432c9a59d5022d8764f0a6"
    }
  },
  "sspClientOptions": {
    "baseUrl": "http://localhost:5000",
    "schemaEndpoint": "graphql/spark/rc",
    "identityPublicKey": "<identityPublicKey from /identity>"
  }
}
```

The GraphQL URL is `/graphql/spark/rc`. The Operator certificates are
self-signed regtest certificates, so a Node client must set
`SPARK_DANGEROUSLY_DISABLE_TLS_VERIFICATION=1`; never use that setting outside
this local profile.

The profile uses public regtest-only operator fixture keys and the admin token
`regtest-spark-admin-token`. Never reuse either outside a disposable regtest.

# Running Nutshell on regtest
add this ENV variables to your `.env` file (assuming that the `cashu-regtest` directory is in `../` from the `nutshell` directory)
```sh
# LND
MINT_BACKEND_BOLT11_SAT=LndRestWallet
MINT_LND_REST_ENDPOINT=https://localhost:8081
MINT_LND_REST_CERT="../cashu-regtest/data/lnd-3/tls.cert"
MINT_LND_REST_MACAROON="../cashu-regtest/data/lnd-3/data/chain/bitcoin/regtest/admin.macaroon"

# CLN
MINT_BACKEND_BOLT11_SAT=CoreLightningRestWallet
MINT_CORELIGHTNING_REST_URL=https://localhost:3001
MINT_CORELIGHTNING_REST_MACAROON=../cashu-regtest-enviroment/data/clightning-2-rest/access.macaroon
MINT_CORELIGHTNING_REST_CERT=../cashu-regtest-enviroment/data/clightning-2-rest/certificate.pem
```

# Regtest nodes

You can interact with the software running in the container using the `bitcoin-cli-sim`, `lightning-cli-sim` and `lncli-sim` aliases. You can bind these aliases by sourcing the `docker-scripts.sh` file:
```sh
source docker-scripts.sh

# LND
lncli-sim 1 addinvoice <amount> # create an invoice
lncli-sim 1 payinvoice -f <invoice> # pay an invoice

# use bitcoin core, mine a block
bitcoin-cli-sim -generate 1

# use c-lightning nodes
lightning-cli-sim 1 newaddr | jq -r '.bech32' # use node 1
lightning-cli-sim 2 getinfo # use node 2
lightning-cli-sim 3 getinfo # use node 3

# use lnd nodes
lncli-sim 1 newaddr p2wsh
lncli-sim 2 listpeers

# use the optional Spark ldk-server
ldk-cli-sim get-node-info
ldk-cli-sim list-channels
```

# urls
* mempool: http://localhost:8080/
* boltz api: http://localhost:9001/
* lnd-1 rest: http://localhost:8081/
* lnbits: http://localhost:5001/
* Spark SSP: http://localhost:5000/ (with `--spark`)
* Spark Operators: https://localhost:8535-8537/ (with `--spark`)
* Spark Esplora: http://localhost:30000/ (with `--spark`)
* Spark ldk-server gRPC: https://localhost:3536/ (with `--spark`)

# debugging docker logs
```sh
docker logs cashu-lnbits-1 -f
docker logs cashu-boltz-1 -f
docker logs cashu-clightning-1-1 -f
docker logs cashu-lnd-2-1 -f
docker logs cashu-spark-ssp-1 -f
docker logs cashu-spark-ldk-1 -f
```
