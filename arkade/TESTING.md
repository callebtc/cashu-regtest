# Local acceptance evidence

Verified on 2026-09-05 using the revisions pinned in this directory.

| Command | Result |
| --- | --- |
| `bash tests/startup.sh` | Passed, including multi-wallet regression |
| Compose validation: core, Arkade, all profiles | Passed |
| `./start.sh` | Passed original topology and height 201 assertions |
| `./start.sh --arkade` | Passed from fresh volumes |
| `./start.sh --spark --bark --arkade` | All three payment suites passed; final height 255 |

The temporary Arkade wallet performed:

| Flow | Verified amount |
| --- | --- |
| Bitcoin receive and boarding | 1,000,000 sats confirmed; 990,000 spendable after fee |
| Arkade → LND-1 | 3,000-sat invoice settled; 3,001 sats debited |
| LND-1 → Arkade | 5,000-sat invoice settled; 4,980 sats credited |
| Arkade → CLN-2 | 3,000-sat invoice settled; 3,001 sats debited |
| CLN-2 → Arkade | 5,000-sat invoice settled; 4,980 sats credited |
| Cooperative Bitcoin exit | 20,000-sat output, three confirmations |

The test cross-checked payment hashes/preimages and wallet balance changes.
The combined run's Boltz database contained exactly two `transaction.claimed`
submarine swaps and two `invoice.settled` reverse swaps, with no other swap
statuses. All four wallet history entries were terminal; neither pending-swap
query returned an entry.

Reproduce with the commands above. Transaction IDs and preimages are printed
by the acceptance script; wallet private keys are not. CI configuration is
included, but a hosted CI run is not claimed by this local report.
