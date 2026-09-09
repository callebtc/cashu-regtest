![TESTS](https://github.com/lnbits/legend-regtest-enviroment/actions/workflows/ci.yml/badge.svg)

# Node versions

Pinned stable releases (checked 2026-09-05):

| Node | Release |
| --- | --- |
| Bitcoin Core | [31.1](https://github.com/bitcoin/bitcoin/releases/tag/v31.1) |
| LND (core nodes, fee hub, and fee leaf) | [0.21.3-beta](https://github.com/lightningnetwork/lnd/releases/tag/v0.21.3-beta) |
| Core Lightning (core nodes, fee leaf, and Bark) | [26.06.7](https://github.com/ElementsProject/lightning/releases/tag/v26.06.7) |

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
* cln-3: for testing your software
* ldk: LDK Node, running through the official `ldk-server` daemon
* fee-hub: dedicated LND router charging 1 sat + 1,000 ppm
* lnd-4, clightning-4, ldk-fee: fee-testing leaves with only one channel each, to fee-hub

The optional Spark profile also runs three Spark Operators (a 2-of-3
threshold), an `open-ssp` provider, and Electrs. Its Lightning backend shares
the default LDK node.

## Default LDK Node

Plain `./start.sh` runs Bitcoin Core, three LND nodes, three CLN nodes, and
one core [LDK Node](https://github.com/lightningdevkit/ldk-node), plus the fee
topology described below. LDK Node is a
library; the official [ldk-server](https://github.com/lightningdevkit/ldk-server)
provides its daemon and authenticated CLI. The source build pins server
`6d6d810714706c225ce7effc2163eff6a1b54221`, which pins LDK Node
`056447c28221be02c3d39f8c6ae430a67ebbd850` (MIT/Apache-2.0).

LDK opens six public 24,000,000-sat channels, one to each LND and CLN node,
pushing 12,000,000 sats to each peer. Startup funds six confirmed Bitcoin
UTXOs, confirms each channel funding transaction before opening the next,
then checks both channel readiness and exact chain height. Confirming each
spend avoids a same-second mempool sync race in the pinned LDK wallet. The
default baseline is height 224, with core LND channel counts 7/3/4 and three
channels per core CLN node.

Every start tests twelve real payments: LDK pays each peer 3,000 sats and
each peer pays LDK 5,000 sats. Both sides must report settlement with matching
payment hashes and preimages. These tests run after initial balance checks
and leave the resulting payment history available for inspection.

The first native ARM64/AMD64 Rust build can take tens of minutes; CI jobs
allow 90 minutes. Host test dependencies are `jq`, `xxd`, and `openssl`.
LDK's gRPC endpoint is published only on loopback port 3536; Lightning P2P
is available inside Docker at `ldk:9735`. `ldk-cli-sim` reads the generated
API key and TLS certificate automatically. Its wallet, channels, and credentials
live in the `ldk-data` Docker volume and are reset by a full start, like the
rest of this disposable environment. Do not use real funds.

## Fee-charging Lightning topology

Every `./start.sh` also starts this channel topology:

```text
existing network -- lnd-1 -- fee-hub -- lnd-4
                              |------ clightning-4
                              |------ ldk-fee
```

The hub opens four public 24,000,000-sat channels, pushing 12,000,000 sats
to each peer. Leaves never get direct channels to one another or the existing
network. Their payments must cross the hub. Existing channel policies stay
unchanged; a direct payment still has no forwarding fee.

The hub charges `1,000 msat + floor(amount_msat * 1,000 / 1,000,000)` on
each outgoing channel, with zero inbound discount. A 10,000-sat invoice costs
11 sats to route; a 100,000-sat invoice costs 101 sats. The receiver gets the
full invoice amount. Startup checks fee-policy propagation in all three leaf
routing graphs before testing payments. If gossip stalls, startup reconnects
the leaves once to restart synchronization, then rechecks policies and channel
readiness. Failed checks identify the peer and channel; failure diagnostics
include the leaf graphs as well as the hub graph.

Acceptance tests pay every ordered leaf pair at both amounts (12 payments),
then pay both ways between `lnd-1` and the CLN leaf (two more). They verify
matching hashes/preimages, exact sender fees, hub forwarding records, cleared
HTLCs, and a total hub balance gain of 694 sats. A 10-sat fee budget for an
11-sat route must fail without settling the invoice or crediting the hub.
Tests run after initial balance assertions and keep their history available.

```sh
source ./docker-scripts.sh
fee-hub-cli-sim listchannels
fee-hub-cli-sim fwdinghistory
lncli-sim 4 getinfo
lightning-cli-sim 4 getinfo
ldk-fee-cli-sim get-node-info
invoice=$(lightning-cli-sim 4 invoice 10000000 "manual-$(date +%s)" 'Fee test' | jq -r .bolt11)
lncli-sim 4 payinvoice --force --fee_limit 11 "$invoice"
```

The four new nodes reuse pinned images, publish no host ports, and keep
independent wallets and credentials in disposable named volumes. A full start
resets them. Fee topology initialization mines nine additional blocks; it
does not alter optional L2 fee behavior or add rebalancing/recovery tests.

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
avoid stale-height HTLC expiry failures. Bark remains opt-in.

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
runs the same acceptance script; all jobs allow the default LDK source build.

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

The Spark profile builds pinned source archives natively on ARM64 and AMD64.
The first build can take 30–90 minutes; later runs reuse Docker's cache.
It shares the default LDK node and uses a temporary **Breez SDK – Spark Rust**
wallet, not the former forked Spark JavaScript wallet.

Pinned revisions (checked 2026-09-08):

* Client: unmodified `breez/spark-sdk@a3fac0e8f1f38e7e3dca110a22f37dd3264e2bde` (official upstream main at verification time; MIT).
* SSP: `benthecarman/open-ssp@25eec4a8c492a16a4d1962b7115430181a8200ad` (now explicitly MIT-licensed).
* Provider-internal SDK: `benthecarman/spark-sdk@2472fdc0e136868eb10e5ad9f501a7e740080f04`, the SSP's pinned fork of that Breez revision.
* Operators: `benthecarman/spark@83cca565c3cce1a4692cedef601fef553ed0249b`, the SSP's compatible Spark fork (Apache-2.0).
* Lightning backend: `lightningdevkit/ldk-server@6d6d810714706c225ce7effc2163eff6a1b54221`.
* Esplora: `mempool/electrs@5b8819039dc1ad1dddf2c3c293ec8825975680f8`.

The SSP still needs provider-specific SDK and operator patches for counter
transfers, durable leaf splitting, and private operator APIs. These are server
dependencies, not client patches. The old local operator compatibility patch
is replaced by the upstream SSP's pinned operator implementation. Its private
SSP RPC port 8536 stays inside Docker; public host operator ports remain
8535–8537. Sources are consumed through pinned builds, not vendored.

### Breez acceptance flow

`./start.sh --spark` seeds the SSP with one coarse 500,000-sat Spark leaf,
deliberately exercising change selection and repeated splitting. A separate
Bitcoin Core wallet, `ssp-withdrawals`, supplies cooperative payout liquidity.

After initial node assertions, the temporary Breez wallet:

1. Receives 100,000 onchain sats at its SDK-generated static deposit address;
   waits for SDK-observed confirmations, accepts a bounded fee quote, and
   claims spendable Spark funds through Breez. Bitcoin must show the SSP
   spending the deposit output.
2. Pays 3,000-sat invoices on both LND and CLN.
3. Receives 5,000-sat Lightning payments from each node.
4. Cooperatively withdraws its remaining balance to Bitcoin, checks the exact
   quoted miner fee and confirmed payout, then reconnects using the same
   temporary seed/storage and verifies all six completed wallet records.

Lightning checks match SDK, peer, and LDK settlement records and verify
payment hashes/preimages. Operator databases must contain no incomplete
primary/counter swaps. The fixture never constructs wallet GraphQL calls or
signatures itself. SDK deposit/withdrawal fees are included in balance checks;
funding exact denominations is no longer required.

The Spark initialization adds three blocks (baseline 227 without Bark).
Its payment tests mine further blocks after baseline assertions. The normal
`./start.sh` topology and fee-hub tests are unchanged. Optional profiles can
still be combined with `--spark --bark --arkade`. This checks confirmed deposits
and cooperative exits, not instant deposits, unilateral recovery, or L2
routing through the fee hub.

### Connecting a Breez wallet

See [the acceptance client's connection setup](spark/test/src/main.rs) for
a complete Rust `SdkBuilder` example. Use the pinned official SDK revision,
`default_config(Network::Regtest)`, no Breez API key, local Esplora, threshold
2, and the three fixture signing operators. Discover the current SSP identity:

```sh
curl http://localhost:5000/identity
```

Set `SparkSspConfig` to the reachable SSP base URL, that
`identityPublicKey`, and `schema_endpoint: Some("graphql/spark/rc")`.
For host clients use Esplora at `http://localhost:30000` and operator URLs
`https://localhost:8535`, `:8536`, and `:8537`; inside Docker use the
service names shown in the client. Configure each operator's `ca_cert_pem`
with its generated certificate—do not disable operator TLS verification.

All operator keys and the admin token `regtest-spark-admin-token` are public
regtest fixtures. Full startup resets volumes and identities; never use real
funds. The temporary client seed is randomly generated and is not printed.

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

# use the default LDK Node daemon
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
* LDK Node gRPC: https://localhost:3536/ (always available; TLS and API key required)

# debugging docker logs
```sh
docker logs cashu-lnbits-1 -f
docker logs cashu-boltz-1 -f
docker logs cashu-clightning-1-1 -f
docker logs cashu-lnd-2-1 -f
docker logs cashu-spark-ssp-1 -f
docker logs cashu-ldk-1 -f
```
