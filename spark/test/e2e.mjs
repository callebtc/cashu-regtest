import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import https from "node:https";

const sdkPath = process.env.SPARK_SDK_DIST;
if (!sdkPath) throw new Error("SPARK_SDK_DIST is required");
const { SparkWallet } = await import(sdkPath);

const sspBaseUrl = process.env.SSP_BASE_URL ?? "http://spark-ssp:5000";
const bitcoinRpcUrl = process.env.BITCOIN_RPC_URL ?? "http://bitcoind:18443";
const bitcoinRpcUser = process.env.BITCOIN_RPC_USER ?? "cashu";
const bitcoinRpcPassword = process.env.BITCOIN_RPC_PASSWORD ?? "cashu";
const bitcoinRpcWallet = process.env.BITCOIN_RPC_WALLET ?? "cashu";
const electrsUrl = process.env.ELECTRS_URL ?? "http://spark-electrs:3002";
const lndHost = process.env.LND_REST_HOST ?? "lnd-1";
const lndPort = Number(process.env.LND_REST_PORT ?? "8081");
const lndDataDir = process.env.LND_DATA_DIR ?? "/lnd";

let rpcId = 0;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    throw new Error(`${url} returned invalid JSON: ${text}`);
  }
  if (!response.ok) {
    throw new Error(`${url} returned HTTP ${response.status}: ${text}`);
  }
  return body;
}

async function bitcoinRpc(method, params = [], wallet = false) {
  const endpoint = wallet ? `${bitcoinRpcUrl}/wallet/${bitcoinRpcWallet}` : bitcoinRpcUrl;
  const response = await fetchJson(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(`${bitcoinRpcUser}:${bitcoinRpcPassword}`).toString("base64")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ jsonrpc: "1.0", id: ++rpcId, method, params }),
  });
  if (response.error) {
    throw new Error(`bitcoind ${method}: ${JSON.stringify(response.error)}`);
  }
  return response.result;
}

async function mine(blocks) {
  const address = await bitcoinRpc("getnewaddress", [], true);
  await bitcoinRpc("generatetoaddress", [blocks, address]);
  await new Promise((resolve) => setTimeout(resolve, 4_000));
}

async function lndRequest(path, { method = "GET", body } = {}) {
  const macaroon = await readFile(
    `${lndDataDir}/data/chain/bitcoin/regtest/admin.macaroon`,
  );
  const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
  return new Promise((resolve, reject) => {
    const request = https.request(
      {
        hostname: lndHost,
        port: lndPort,
        path,
        method,
        rejectUnauthorized: false,
        headers: {
          "Grpc-Metadata-macaroon": macaroon.toString("hex"),
          ...(payload
            ? {
                "Content-Type": "application/json",
                "Content-Length": payload.length,
              }
            : {}),
        },
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let value;
          try {
            value = text ? JSON.parse(text) : {};
          } catch {
            reject(new Error(`LND ${method} ${path} returned invalid JSON: ${text}`));
            return;
          }
          if ((response.statusCode ?? 500) >= 400) {
            reject(new Error(`LND ${method} ${path} returned ${response.statusCode}: ${text}`));
            return;
          }
          resolve(value);
        });
      },
    );
    request.setTimeout(120_000, () => request.destroy(new Error(`LND ${method} ${path} timed out`)));
    request.on("error", reject);
    if (payload) request.write(payload);
    request.end();
  });
}

async function poll(label, check, timeoutMs = 180_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await check();
      if (value) return value;
      lastError = undefined;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error(`${label} timed out${lastError ? `: ${lastError.message}` : ""}`);
}

function hashHex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function decodePreimage(value, label) {
  assert(typeof value === "string" && value.length > 0, `${label} is missing`);
  const normalized = value.startsWith("0x") ? value.slice(2) : value;
  const bytes = /^[0-9a-f]{64}$/i.test(normalized)
    ? Buffer.from(normalized, "hex")
    : Buffer.from(normalized, "base64");
  assert(bytes.length === 32, `${label} is not 32 bytes`);
  return bytes;
}

const identity = await fetchJson(`${sspBaseUrl}/identity`);
assert(/^[0-9a-f]{66}$/i.test(identity.identityPublicKey ?? ""), "SSP identity is invalid");

const signingOperators = Object.fromEntries(
  [
    "0322ca18fc489ae25418a0e768273c2c61cabb823edfb14feb891e9bec62016510",
    "0341727a6c41b168f07eb50865ab8c397a53c7eef628ac1020956b705e43b6cb27",
    "0305ab8d485cc752394de4981f8a5ae004f2becfea6f432c9a59d5022d8764f0a6",
  ].map((identityPublicKey, id) => {
    const identifier = (id + 1).toString(16).padStart(64, "0");
    return [
      identifier,
      {
        id,
        identifier,
        address: `https://spark-operator-${id}.minikube.local:8535`,
        identityPublicKey,
      },
    ];
  }),
);

const walletOptions = {
  network: "LOCAL",
  signingOperators,
  threshold: 2,
  electrsUrl,
  sspClientOptions: {
    baseUrl: sspBaseUrl,
    schemaEndpoint: "graphql/spark/rc",
    identityPublicKey: identity.identityPublicKey,
  },
  optimizationOptions: { auto: false, multiplicity: 0 },
  tokenOptimizationOptions: { enabled: false },
};

let wallet;
try {
  ({ wallet } = await SparkWallet.initialize({ options: walletOptions }));

  const depositAddress = await wallet.getSingleUseDepositAddress();
  const depositTxid = await bitcoinRpc("sendtoaddress", [depositAddress, 0.0001], true);
  await mine(3);
  await wallet.claimDeposit(depositTxid);
  await poll("Spark wallet funding", async () => {
    await wallet.experimental_syncWallet();
    return (await wallet.getBalance()).balance === 10_000n;
  });

  const lndInvoice = await lndRequest("/v1/invoices", {
    method: "POST",
    body: { value: "3000", memo: "spark-regtest-send" },
  });
  assert(lndInvoice.payment_request, "LND did not return a BOLT11 invoice");
  assert(lndInvoice.r_hash, "LND did not return an invoice hash");

  const sendRequest = await wallet.payLightningInvoice({
    invoice: lndInvoice.payment_request,
    maxFeeSats: 0,
  });
  const paidSend = await poll("Spark-to-LND payment", async () => {
    const current = await wallet.getLightningSendRequest(sendRequest.id);
    if (current?.status === "LIGHTNING_PAYMENT_FAILED") {
      throw new Error(`Spark send failed: ${JSON.stringify(current)}`);
    }
    return ["LIGHTNING_PAYMENT_SUCCEEDED", "PREIMAGE_PROVIDED", "TRANSFER_COMPLETED"].includes(
      current?.status,
    )
      ? current
      : undefined;
  });
  assert(paidSend.id === sendRequest.id, "Spark send request ID changed");
  assert(
    paidSend.encodedInvoice === lndInvoice.payment_request,
    "Spark send record does not contain the paid LND invoice",
  );

  const lndHashHex = Buffer.from(lndInvoice.r_hash, "base64").toString("hex");
  const settledInvoice = await poll("LND invoice settlement", async () => {
    const invoice = await lndRequest(`/v1/invoice/${lndHashHex}`);
    return invoice.settled ? invoice : undefined;
  });
  const lndPreimage = decodePreimage(settledInvoice.r_preimage, "LND invoice preimage");
  assert(hashHex(lndPreimage) === lndHashHex, "LND invoice preimage does not match its hash");
  await poll("Spark send balance", async () => {
    await wallet.experimental_syncWallet();
    return (await wallet.getBalance()).balance === 7_000n;
  });

  const receiveRequest = await wallet.createLightningInvoice({
    amountSats: 5_000,
    memo: "spark-regtest-receive",
    expirySeconds: 300,
  });
  assert(receiveRequest.status === "INVOICE_CREATED", "Spark receive invoice was not created");
  assert(receiveRequest.invoice?.encodedInvoice, "Spark receive request has no BOLT11 invoice");

  const lndPaymentStream = await lndRequest("/v2/router/send", {
    method: "POST",
    body: {
      payment_request: receiveRequest.invoice.encodedInvoice,
      fee_limit_sat: "0",
      timeout_seconds: 120,
      no_inflight_updates: true,
    },
  });
  const lndPayment = lndPaymentStream.result ?? lndPaymentStream;
  assert(
    lndPayment.status === "SUCCEEDED",
    `LND payment failed (${lndPayment.failure_reason ?? lndPayment.status}): ${JSON.stringify(lndPayment)}`,
  );
  const receivePreimage = decodePreimage(lndPayment.payment_preimage, "LND payment preimage");
  assert(
    hashHex(receivePreimage) === receiveRequest.invoice.paymentHash.toLowerCase(),
    "Spark receive preimage does not match its payment hash",
  );

  const completedReceive = await poll("LND-to-Spark payment", async () => {
    const current = await wallet.getLightningReceiveRequest(receiveRequest.id);
    if (current?.status === "HTLC_FAILED" || current?.status === "TRANSFER_FAILED") {
      throw new Error(`Spark receive failed: ${JSON.stringify(current)}`);
    }
    return current?.status === "TRANSFER_COMPLETED" ? current : undefined;
  });
  assert(completedReceive.transfer?.sparkId, "Completed Spark receive has no transfer ID");
  const walletReceivePreimage = decodePreimage(
    completedReceive.paymentPreimage,
    "Spark receive record preimage",
  );
  assert(
    walletReceivePreimage.equals(receivePreimage),
    "Spark receive and LND payment records have different preimages",
  );

  await poll("Spark receive balance", async () => {
    await wallet.experimental_syncWallet();
    return (await wallet.getBalance()).balance === 12_000n;
  });

  console.log(
    JSON.stringify({
      status: "PASS",
      sparkToLightningSats: 3_000,
      lightningToSparkSats: 5_000,
      finalSparkBalanceSats: 12_000,
      sendPaymentHash: lndHashHex,
      sendPaymentPreimage: lndPreimage.toString("hex"),
      receivePaymentHash: receiveRequest.invoice.paymentHash.toLowerCase(),
      receivePaymentPreimage: receivePreimage.toString("hex"),
    }),
  );
} finally {
  if (wallet) await wallet.cleanupConnections();
}
