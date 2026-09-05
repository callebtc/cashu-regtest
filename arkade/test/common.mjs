import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import https from "node:https";
import { Wallet, SingleKey, EsploraProvider, Ramps, InMemoryWalletRepository,
  InMemoryContractRepository } from "@arkade-os/sdk";

export { assert, Ramps };
export const arkUrl = "http://arkade-operator:7070";
export const esploraUrl = "http://spark-electrs:3002";
export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
export async function json(url, body) {
  const r = await fetch(url, {
    method: body === undefined ? "GET" : "POST",
    headers: {"Content-Type": "application/json"},
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(120000),
  });
  const value = await r.json();
  if (!r.ok) throw Error(url + ": " + JSON.stringify(value));
  return value;
}
export async function poll(label, check, timeout = 180000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try { const value = await check(); if (value) return value; }
    catch (e) { last = e.message; }
    await sleep(2000);
  }
  throw Error("Timed out waiting for " + label + (last ? ": " + last : ""));
}
export async function btc(method, params = [], wallet = false) {
  const r = await fetch("http://bitcoind:18443" + (wallet ? "/wallet/" + (wallet === true ? "cashu" : wallet) : ""), {
    method: "POST", headers: {Authorization: "Basic " + Buffer.from("cashu:cashu").toString("base64"),
      "Content-Type": "application/json"},
    body: JSON.stringify({jsonrpc:"1.0", id:1, method, params}),
    signal: AbortSignal.timeout(30000),
  });
  const v = await r.json();
  if (v.error) throw Error(method + ": " + JSON.stringify(v.error));
  return v.result;
}
export async function mine(n = 3) {
  await btc("generatetoaddress", [n, await btc("getnewaddress", [], true)]);
  const height = await btc("getblockcount");
  await poll("Esplora height " + height, async () =>
    Number(await (await fetch(esploraUrl + "/blocks/tip/height")).text()) === height);
}
export async function wallet() {
  return Wallet.create({
    identity: SingleKey.fromRandomBytes(), arkServerUrl: arkUrl,
    settlementConfig: false,
    storage: {walletRepository: new InMemoryWalletRepository(),
      contractRepository: new InMemoryContractRepository()},
    onchainProvider: new EsploraProvider(esploraUrl, {forcePolling:true, pollingInterval:2000}),
  });
}
export async function board(w, sats) {
  const address = await w.getBoardingAddress();
  const txid = await btc("sendtoaddress", [address, sats / 1e8, "", "", false, true, null, "unset", null, 100], true);
  await mine();
  const tx = await btc("getrawtransaction", [txid, true]);
  assert(tx.confirmations >= 3);
  assert(tx.vout.some(v => v.scriptPubKey.address === address && Math.round(v.value * 1e8) === sats));
  await poll("boarding UTXO", async () => (await w.getBoardingUtxos()).length > 0);
  const info = await json(arkUrl + "/v1/info");
  const settlement = await new Ramps(w).onboard(info.fees);
  await mine();
  await poll("spendable Arkade balance after 1% boarding fee",
    async () => (await w.getBalance()).available === sats - sats / 100);
  console.log(JSON.stringify({test:"onchain receive + board",sats,txid,settlement,balance:await w.getBalance()}));
}
export async function lightning(kind, path, body) {
  const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
  const headers = kind === "lnd"
    ? {"Grpc-Metadata-macaroon": (await readFile("/lnd/data/chain/bitcoin/regtest/admin.macaroon")).toString("hex")}
    : {Rune: (await readFile("/cln/rune", "utf8")).trim()};
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: kind === "lnd" ? "lnd-1" : "clightning-2", port:kind === "lnd" ? 8081 : 3010,
      path, method:payload ? "POST" : "GET", rejectUnauthorized:false,
      headers: {...headers, "Content-Type":"application/json", ...(payload ? {"Content-Length":payload.length} : {})},
    }, res => {
      const chunks = [];
      res.on("data", c => chunks.push(c));
      res.on("end", () => {
        try {
          const value = JSON.parse(Buffer.concat(chunks).toString());
          if (res.statusCode >= 400) throw Error(JSON.stringify(value));
          resolve(value);
        } catch (e) { reject(e); }
      });
    });
    req.setTimeout(180000, () => req.destroy(Error("Lightning request timeout")));
    req.on("error", reject);
    req.end(payload);
  });
}
