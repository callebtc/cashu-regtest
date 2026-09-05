import {createHash} from "node:crypto";
import {RestArkProvider, RestIndexerProvider} from "@arkade-os/sdk";
import {ArkadeSwaps, BoltzSwapProvider, InMemorySwapRepository} from "../dist/index.js";
import {assert, json, poll, btc, mine, wallet, board, Ramps, lightning, arkUrl} from "./common.mjs";
const hash = hex => createHash("sha256").update(Buffer.from(hex, "hex")).digest("hex");
const deadline = setTimeout(() => { console.error("Arkade payments exceeded 15 minutes"); process.exit(1); }, 900000);
let w, swaps;
try {
  await poll("Boltz ARK/BTC pairs", async () => {
    const pairs = await json("http://arkade-boltz/v2/swap/submarine");
    return pairs.ARK?.BTC;
  });
  w = await wallet();
  await board(w, 1000000);
  const provider = new BoltzSwapProvider({network:"regtest", apiUrl:"http://arkade-boltz"});
  swaps = new ArkadeSwaps({wallet:w, swapProvider:provider,
    arkProvider:new RestArkProvider(arkUrl), indexerProvider:new RestIndexerProvider(arkUrl),
    swapRepository:new InMemorySwapRepository(), swapManager:false});
  for (const peer of ["lnd", "cln"]) {
    const label = "arkade-" + peer + "-" + Date.now();
    const invoice = peer === "lnd"
      ? await lightning(peer, "/v1/invoices", {value:"3000", memo:label})
      : await lightning(peer, "/v1/invoice", {amount_msat:3000000, label, description:label});
    const paymentHash = peer === "lnd" ? Buffer.from(invoice.r_hash,"base64").toString("hex") : invoice.payment_hash;
    const before = (await w.getBalance()).available;
    const sent = await swaps.sendLightningPayment({invoice:invoice.payment_request ?? invoice.bolt11});
    assert.equal(hash(sent.preimage), paymentHash);
    assert(sent.amount >= 3000);
    await poll("wallet debit", async () => (await w.getBalance()).available === before - sent.amount);
    const settled = peer === "lnd"
      ? await lightning(peer, "/v1/invoice/" + paymentHash)
      : (await lightning(peer, "/v1/listinvoices", {label})).invoices[0];
    assert.equal(peer === "lnd" ? settled.state : settled.status, peer === "lnd" ? "SETTLED" : "paid");
    assert.equal(peer === "lnd" ? Buffer.from(settled.r_preimage,"base64").toString("hex") : settled.payment_preimage, sent.preimage);
    console.log(JSON.stringify({test:"Arkade -> " + peer,invoiceSats:3000,debitedSats:sent.amount,paymentHash,...sent}));

    const reverse = await swaps.createReverseSwap({amount:5000, description:label + "-receive"});
    const balance = (await w.getBalance()).available;
    const claim = swaps.waitAndClaim(reverse);
    const pay = peer === "lnd"
      ? lightning(peer, "/v2/router/send", {payment_request:reverse.response.invoice,
          fee_limit_sat:"100", timeout_seconds:120, no_inflight_updates:true})
      : lightning(peer, "/v1/pay", {bolt11:reverse.response.invoice});
    const [received, paid] = await Promise.all([claim, pay.then(response => {
      const p = response.result ?? response;
      if (peer === "lnd") assert.equal(p.status, "SUCCEEDED", p.failure_reason);
      else assert.equal(p.status, "complete");
      return p;
    })]);
    const preimage = paid.payment_preimage;
    assert.equal(preimage, reverse.preimage);
    assert.equal(hash(preimage), reverse.request.preimageHash);
    await poll("wallet credit", async () => (await w.getBalance()).available === balance + reverse.response.onchainAmount);
    await poll("Boltz reverse settlement", async () =>
      (await provider.getSwapStatus(reverse.id)).status === "invoice.settled");
    console.log(JSON.stringify({test:peer + " -> Arkade",invoiceSats:5000,creditedSats:reverse.response.onchainAmount,
      paymentHash:hash(preimage),preimage,txid:received.txid}));
  }
  const destination = await btc("getnewaddress", [], true);
  // Ramps deducts the configured 250-sat output fee from the requested amount.
  const txid = await new Ramps(w).offboard(destination, (await json(arkUrl + "/v1/info")).fees, 20250n);
  await mine();
  const tx = await btc("getrawtransaction", [txid, true]);
  assert(tx.confirmations >= 3);
  assert(tx.vout.some(v => v.scriptPubKey.address === destination && Math.round(v.value * 1e8) === 20000));
  console.log(JSON.stringify({test:"Arkade -> onchain",sats:20000,txid,confirmations:tx.confirmations}));
  const history = await swaps.getSwapHistory();
  assert.equal(history.length, 4);
  for (const s of history) assert(["transaction.claimed","invoice.settled"].includes(s.status), s.status);
  assert.equal((await swaps.getPendingSubmarineSwaps()).length, 0);
  assert.equal((await swaps.getPendingReverseSwaps()).length, 0);
  console.log("PASS: confirmed onchain receive/send and four settled Lightning payments; no pending swaps");
} finally {
  if (swaps) await swaps.dispose();
  if (w) await w.dispose();
  clearTimeout(deadline);
}
