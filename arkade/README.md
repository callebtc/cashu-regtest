# Optional Arkade regtest

Run `./start.sh --arkade`. The flag can be combined with `--spark` and
`--bark`; plain `./start.sh` still runs only the original core environment.
The first run downloads several server images and builds the pinned SDK.
All state is disposable: a full start removes volumes and creates fresh wallets.
Never use real funds, production keys, or these credentials outside regtest.

Arkade uses arkd with its separate signer/onchain wallet, NBXplorer, and the
shared Esplora indexer (the service is named `spark-electrs` for compatibility).
Fulmine holds the swap provider's Arkade funds. Boltz handles real Lightning
swaps through existing LND-2, which already has balanced channels to LND-1
and CLN-2. No fake Lightning backend or additional channels are introduced.
Boltz starts after the core assertions. The Bitcoin helper explicitly selects
the original `cashu` wallet, since NBXplorer and Boltz can load additional Core wallets.
NBXplorer's automatic regtest mining is disabled. Boltz uses its own funded
`arkade-boltz` Core wallet.

Loopback endpoints:

| API | URL |
| --- | --- |
| Arkade operator | http://localhost:7070 |
| Boltz HTTP and WebSocket | http://localhost:9069 and ws://localhost:9004/v2/ws |
| Esplora | http://localhost:30000 |

Admin, signer, Fulmine, database, and NBXplorer ports are not published.
TLS/macaroons are disabled on these disposable internal Arkade services.
The local-only operator/Fulmine/Postgres password is `regtest-arkade`.
The operator uses Arkade's published regtest signer private key; it is not secret.
Boltz has a read-only mount of LND-2 credentials.

The temporary wallet uses `SingleKey.fromRandomBytes()`, in-memory repositories,
`arkServerUrl`, and an explicit regtest `EsploraProvider`. It uses manual
settlement and swap claiming; automatic renewal, recovery, and unilateral exit
are not covered by this acceptance test. Keys are never printed or persisted.
The test code is in `test/setup.mjs` and `test/e2e.mjs`.

## Acceptance flow

After the original core assertions pass, setup funds the operator with actual
Bitcoin transactions. A separate temporary wallet boards Bitcoin and transfers
15,000,000 Arkade sats to Fulmine. Operator input fees (1%), offboard output
fees (250 sats), and Boltz swap fees remain enabled throughout funding/testing.

The acceptance wallet then:

1. Receives 1,000,000 sats at a boarding address; checks the actual confirmed
   Core output and settles into spendable Arkade funds.
2. Pays a 3,000-sat invoice on LND-1 and another on CLN-2.
3. Receives a 5,000-sat Lightning invoice payment from each node.
4. Cooperatively exits 20,000 sats to Bitcoin; checks the actual output and
   at least three confirmations.
5. Verifies matching payment hashes/preimages, wallet debits/credits including
   fees, terminal swap records, and no remaining pending swaps.

Failures exit nonzero and print service diagnostics. The Arkade CI job has its
own 90-minute limit; the existing core job remains at 10 minutes.

## Revisions

Arkade, Fulmine, Boltz, and NBXplorer images use immutable multiarchitecture
manifest digests in Compose.

| Component | Version / source |
| --- | --- |
| arkd + arkd-wallet | v0.9.16, `e2d9ed443df7a0dfb3aa1e5c824de9541ff71047` |
| Fulmine | v0.3.25, `552f28546e288bffaf28e22cda493f2a1f241705` |
| Boltz | image manifest `sha256:8d495425bcf8083e842a54daa7d92328bccda8d0e6ec4742384428289bd40fb7` |
| NBXplorer | 2.6.7 |
| SDK + Boltz client | `arkade-os/ts-sdk@45a53690aa80dbc3fd058f3fa4c250c262cc566b`, packages 0.4.69 / 0.3.68 |

Configuration is adapted from the [official Arkade regtest](https://github.com/ArkLabsHQ/arkade-regtest).
The SDK is built from its pinned remote source with its upstream license retained
in the image; upstream source trees are not vendored in this repository.
