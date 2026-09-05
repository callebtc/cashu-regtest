import {json, poll, btc, mine, wallet, board, assert, arkUrl} from "./common.mjs";
const admin = "http://arkade-operator:7071/v1/admin";
const fulmine = "http://arkade-fulmine:7001/api/v1";
const password = "regtest-arkade";
const deadline = setTimeout(() => { console.error("Arkade setup exceeded 15 minutes"); process.exit(1); }, 900000);
try {
  let status = await poll("operator admin", () => json(admin + "/wallet/status"));
  if (!status.initialized) {
    const {seed} = await json(admin + "/wallet/seed");
    assert(seed);
    await json(admin + "/wallet/create", {seed, password});
  }
  status = await json(admin + "/wallet/status");
  if (!status.unlocked) await json(admin + "/wallet/unlock", {password});
  await poll("operator wallet sync", async () => (await json(admin + "/wallet/status")).synced);
  const {address} = await json(admin + "/wallet/address");
  assert(address);
  for (let i = 0; i < 21; i++) {
    await btc("sendtoaddress", [address, 1, "", "", false, true, null, "unset", null, 100], true);
  }
  await mine();
  if (!(await btc("listwallets")).includes("arkade-boltz")) await btc("createwallet", ["arkade-boltz"]);
  const boltzAddress = await btc("getnewaddress", [], "arkade-boltz");
  await btc("sendtoaddress", [boltzAddress, 1, "", "", false, true, null, "unset", null, 100], true);
  await mine();
  await json(admin + "/intentFees", {fees:{
    offchainInputFee:"amount * 0.01", onchainInputFee:"amount * 0.01",
    offchainOutputFee:"0.0", onchainOutputFee:"250.0",
  }});
  await poll("operator public API", () => json(arkUrl + "/v1/info"));
  status = await poll("Fulmine API", () => json(fulmine + "/wallet/status"));
  if (!status.initialized) {
    const {nsec} = await json(fulmine + "/wallet/genseed");
    assert(nsec);
    await json(fulmine + "/wallet/create", {private_key:nsec, password, server_url:arkUrl});
  }
  status = await json(fulmine + "/wallet/status");
  if (!status.unlocked) await json(fulmine + "/wallet/unlock", {password});
  await poll("Fulmine ready", async () => {
    const s = await json(fulmine + "/wallet/status");
    return s.initialized && s.unlocked && s.synced;
  });
  const liquidity = await wallet();
  try {
    await board(liquidity, 20000000);
    const {address: destination} = await json(fulmine + "/address");
    const arkAddress = destination.startsWith("bitcoin:")
      ? new URL(destination).searchParams.get("ark") : destination;
    assert(arkAddress?.startsWith("tark1"));
    await liquidity.send({address:arkAddress, amount:15000000});
    await poll("Fulmine Arkade liquidity", async () =>
      Number((await json(fulmine + "/balance")).amount) >= 15000000);
    console.log("PASS: operator funded, fees enabled, Fulmine holds 15,000,000 real boarded sats");
  } finally { await liquidity.dispose(); }
} finally { clearTimeout(deadline); }
