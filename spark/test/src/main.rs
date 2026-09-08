use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use breez_sdk_spark::*;
use reqwest::Client;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{future::Future, io::Read, time::Duration};
use tokio::time::{Instant, sleep, timeout};

const SSP: &str = "http://spark-ssp:5000";
const KEYS: [&str; 3] = [
    "0322ca18fc489ae25418a0e768273c2c61cabb823edfb14feb891e9bec62016510",
    "0341727a6c41b168f07eb50865ab8c397a53c7eef628ac1020956b705e43b6cb27",
    "0305ab8d485cc752394de4981f8a5ae004f2becfea6f432c9a59d5022d8764f0a6",
];

async fn poll<T, F, Fut>(label: &str, mut check: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T>>,
{
    let end = Instant::now() + Duration::from_secs(240);
    let mut last = String::new();
    while Instant::now() < end {
        match check().await {
            Ok(v) => return Ok(v),
            Err(e) => last = format!("{e:#}"),
        }
        sleep(Duration::from_secs(2)).await;
    }
    bail!("{label} timed out: {last}")
}
async fn btc(c: &Client, method: &str, params: Value) -> Result<Value> {
    let v: Value = c
        .post("http://bitcoind:18443/wallet/cashu")
        .basic_auth("cashu", Some("cashu"))
        .json(&json!({"jsonrpc":"1.0","id":1,"method":method,"params":params}))
        .send()
        .await?
        .json()
        .await?;
    ensure!(v["error"].is_null(), "Bitcoin {method}: {v}");
    Ok(v["result"].clone())
}
async fn mine(c: &Client, n: u64) -> Result<()> {
    let addr = btc(c, "getnewaddress", json!([])).await?;
    btc(c, "generatetoaddress", json!([n, addr])).await?;
    Ok(())
}
async fn ln(c: &Client, peer: &str, path: &str, body: Option<Value>) -> Result<Value> {
    let host = if peer == "lnd" {
        "https://lnd-1:8081"
    } else {
        "https://clightning-2:3010"
    };
    let url = format!("{host}{path}");
    let mut request = if let Some(body) = body {
        c.post(url).json(&body)
    } else {
        c.get(url)
    };
    request = if peer == "lnd" {
        request.header(
            "Grpc-Metadata-macaroon",
            hex::encode(std::fs::read(
                "/lnd/data/chain/bitcoin/regtest/admin.macaroon",
            )?),
        )
    } else {
        request.header("Rune", std::fs::read_to_string("/cln/rune")?.trim())
    };
    let response = request.send().await?;
    let status = response.status();
    let text = response.text().await?;
    ensure!(status.is_success(), "{peer} {path}: {text}");
    let v: Value = serde_json::from_str(text.trim())?;
    Ok(v.get("result").unwrap_or(&v).clone())
}
fn text(v: &Value) -> Result<String> {
    Ok(v.as_str().context("missing string")?.to_owned())
}
fn bytes_hex(v: &Value) -> Result<String> {
    let s = text(v)?;
    if s.len() == 64 && hex::decode(&s).is_ok() {
        Ok(s)
    } else {
        Ok(hex::encode(STANDARD.decode(s)?))
    }
}
async fn balance(sdk: &BreezSdk) -> Result<u64> {
    sdk.sync_wallet(SyncWalletRequest {}).await?;
    Ok(sdk
        .get_info(GetInfoRequest {
            ensure_synced: Some(true),
        })
        .await?
        .balance_sats)
}
async fn exact_balance(sdk: &BreezSdk, expected: u64) -> Result<()> {
    poll("wallet balance", || async {
        let actual = balance(sdk).await?;
        ensure!(actual == expected, "balance {actual}, expected {expected}");
        Ok(())
    })
    .await
}
async fn completed(sdk: &BreezSdk, id: &str) -> Result<Payment> {
    poll("Breez payment completion", || async {
        sdk.sync_wallet(SyncWalletRequest {}).await?;
        let p = sdk
            .get_payment(GetPaymentRequest {
                payment_id: id.to_owned(),
            })
            .await?
            .payment;
        ensure!(
            p.status == PaymentStatus::Completed,
            "payment status {}",
            p.status
        );
        Ok(p)
    })
    .await
}
fn proof(p: &Payment) -> Result<(String, String)> {
    let Some(PaymentDetails::Lightning { htlc_details, .. }) = &p.details else {
        bail!("missing Breez Lightning record")
    };
    let preimage = htlc_details.preimage.clone().context("missing preimage")?;
    ensure!(
        hex::encode(Sha256::digest(hex::decode(&preimage)?)) == htlc_details.payment_hash,
        "invalid preimage"
    );
    Ok((htlc_details.payment_hash.clone(), preimage))
}
async fn connect(c: &Client, storage: String, seed: Vec<u8>) -> Result<BreezSdk> {
    let identity: Value = c
        .get(format!("{SSP}/identity"))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let mut config = default_config(Network::Regtest);
    config.api_key = None;
    config.lnurl_domain = None;
    config.real_time_sync_server_url = None;
    config.use_default_external_input_parsers = false;
    config.prefer_spark_over_lightning = false;
    config.private_enabled_default = true;
    config.sync_interval_secs = 2;
    config.max_deposit_claim_fee = None;
    config.leaf_optimization_config.auto_enabled = false;
    config.token_optimization_config.auto_enabled = false;
    let spark = config
        .spark_config
        .as_mut()
        .context("missing regtest Spark config")?;
    spark.coordinator_identifier = format!("{:064x}", 1);
    spark.threshold = 2;
    spark.signing_operators = KEYS
        .iter()
        .enumerate()
        .map(|(id, key)| {
            Ok(SparkSigningOperator {
                id: id as u32,
                identifier: format!("{:064x}", id + 1),
                address: format!("https://spark-operator-{id}:8535"),
                identity_public_key: key.to_string(),
                ca_cert_pem: Some(std::fs::read_to_string(format!("/tls/server_{id}.crt"))?),
            })
        })
        .collect::<Result<Vec<_>>>()?;
    spark.ssp_config = SparkSspConfig {
        base_url: SSP.to_owned(),
        identity_public_key: text(&identity["identityPublicKey"])?,
        schema_endpoint: Some("graphql/spark/rc".to_owned()),
    };
    Ok(SdkBuilder::new(config, Seed::Entropy(seed))
        .with_default_storage(storage)
        .with_rest_chain_service(
            "http://spark-electrs:3002".to_owned(),
            ChainApiType::Esplora,
            None,
        )
        .build()
        .await?)
}
async fn run() -> Result<()> {
    let c = Client::builder()
        .timeout(Duration::from_secs(120))
        .build()?;
    // Only the fixture Lightning REST endpoints use self-signed certificates.
    // Breez operator TLS uses the explicit certificates above, never a bypass.
    let lightning = Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(Duration::from_secs(180))
        .build()?;
    let storage = tempfile::tempdir()?;
    let mut seed = vec![0; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut seed)?;
    let sdk = connect(
        &c,
        storage.path().to_string_lossy().into_owned(),
        seed.clone(),
    )
    .await?;
    exact_balance(&sdk, 0).await?;

    // Onchain receive: obtain the address and submit the confirmed claim only through Breez.
    let address = sdk
        .receive_payment(ReceivePaymentRequest {
            payment_method: ReceivePaymentMethod::BitcoinAddress {
                new_address: Some(false),
            },
        })
        .await?
        .payment_request;
    let txid = text(
        &btc(
            &c,
            "sendtoaddress",
            json!([
                address, 0.001, "", "", false, true, null, "unset", null, 100
            ]),
        )
        .await?,
    )?;
    mine(&c, 3).await?;
    let tx = btc(&c, "getrawtransaction", json!([txid, true])).await?;
    let output = tx["vout"]
        .as_array()
        .context("missing outputs")?
        .iter()
        .find(|v| v["scriptPubKey"]["address"] == address)
        .context("deposit output missing")?;
    let vout = output["n"].as_u64().context("missing vout")? as u32;
    let quote = poll("confirmed deposit quote", || async {
        let q = sdk
            .fetch_claim_deposit_quote(FetchClaimDepositQuoteRequest {
                txid: txid.clone(),
                vout,
            })
            .await?;
        ensure!(
            q.confirmations >= 3
                && q.confirmations >= q.mature.confirmations_required
                && !q.mature.is_estimate,
            "deposit is not confirmed and quoted"
        );
        ensure!(
            q.amount_sats == 100000
                && q.mature.fee_sats < 10000
                && q.mature.credit_amount_sats + q.mature.fee_sats == 100000,
            "invalid deposit quote"
        );
        Ok(q)
    })
    .await?;
    let claim = sdk
        .claim_deposit(ClaimDepositRequest {
            txid: txid.clone(),
            vout,
            max_fee: Some(MaxFee::Fixed {
                amount: quote.mature.fee_sats,
            }),
        })
        .await?;
    let deposit = completed(
        &sdk,
        &claim
            .payment
            .context("confirmed claim returned no payment")?
            .id,
    )
    .await?;
    ensure!(
        deposit.amount == quote.mature.credit_amount_sats as u128,
        "deposit credit mismatch"
    );
    ensure!(
        matches!(&deposit.details, Some(PaymentDetails::Deposit { tx_id, .. }) if tx_id == &txid),
        "deposit record transaction mismatch"
    );
    exact_balance(&sdk, quote.mature.credit_amount_sats).await?;
    ensure!(
        btc(&c, "gettxout", json!([txid, vout, true]))
            .await?
            .is_null(),
        "credited deposit was not recovered by SSP"
    );
    mine(&c, 1).await?;
    println!(
        "PASS: Breez onchain receive: 100000 sats deposited, {} sats credited, {} sats miner fee",
        quote.mature.credit_amount_sats, quote.mature.fee_sats
    );

    let mut settlements = Vec::new();
    for peer in ["lnd", "cln"] {
        let label = format!("breez-{peer}-{txid}");
        let before = balance(&sdk).await?;
        let inv = if peer == "lnd" {
            ln(
                &lightning,
                peer,
                "/v1/invoices",
                Some(json!({"value":"3000","memo":label})),
            )
            .await?
        } else {
            ln(
                &lightning,
                peer,
                "/v1/invoice",
                Some(json!({"amount_msat":3000000,"label":label,"description":label})),
            )
            .await?
        };
        let invoice = text(if peer == "lnd" {
            &inv["payment_request"]
        } else {
            &inv["bolt11"]
        })?;
        let expected_hash = if peer == "lnd" {
            bytes_hex(&inv["r_hash"])?
        } else {
            text(&inv["payment_hash"])?
        };
        let prepare = sdk
            .prepare_send_payment(PrepareSendPaymentRequest {
                payment_request: PaymentRequest::Input {
                    input: invoice.clone(),
                },
                amount: None,
                token_identifier: None,
                conversion_options: None,
                fee_policy: None,
            })
            .await?;
        let sent = sdk
            .send_payment(SendPaymentRequest {
                prepare_response: prepare,
                options: None,
                idempotency_key: None,
            })
            .await?;
        let p = completed(&sdk, &sent.payment.id).await?;
        ensure!(
            p.payment_type == PaymentType::Send && p.amount == 3000,
            "wrong send amount/type"
        );
        let (hash, preimage) = proof(&p)?;
        ensure!(hash == expected_hash, "invoice hash mismatch");
        let invoice_state = if peer == "lnd" {
            ln(&lightning, peer, &format!("/v1/invoice/{hash}"), None).await?
        } else {
            ln(
                &lightning,
                peer,
                "/v1/listinvoices",
                Some(json!({"label":label})),
            )
            .await?["invoices"][0]
                .clone()
        };
        if peer == "lnd" {
            ensure!(
                invoice_state["state"] == "SETTLED"
                    && invoice_state["amt_paid_sat"] == "3000"
                    && bytes_hex(&invoice_state["r_preimage"])? == preimage,
                "LND invoice mismatch"
            );
        } else {
            ensure!(
                invoice_state["status"] == "paid"
                    && invoice_state["amount_received_msat"] == 3000000
                    && invoice_state["payment_preimage"] == preimage,
                "CLN invoice mismatch"
            );
        }
        exact_balance(&sdk, before - 3000 - u64::try_from(p.fees)?).await?;
        settlements.push(
            json!({"peer":peer,"direction":"OUTBOUND","sats":3000,"hash":hash,"preimage":preimage}),
        );
        println!("PASS: Breez -> {peer}: 3000 sats, matching wallet/invoice hash and preimage");

        let before = balance(&sdk).await?;
        let invoice = sdk
            .receive_payment(ReceivePaymentRequest {
                payment_method: ReceivePaymentMethod::Bolt11Invoice {
                    description: label,
                    amount_sats: Some(5000),
                    expiry_secs: Some(300),
                    payment_hash: None,
                    receiver_identity_public_key: None,
                },
            })
            .await?
            .payment_request;
        let paid = if peer == "lnd" {
            ln(&lightning, peer, "/v2/router/send", Some(json!({"payment_request":invoice,"fee_limit_sat":"100","timeout_seconds":120,"no_inflight_updates":true}))).await?
        } else {
            ln(
                &lightning,
                peer,
                "/v1/pay",
                Some(json!({"bolt11":invoice,"retry_for":120})),
            )
            .await?
        };
        ensure!(
            if peer == "lnd" {
                paid["status"] == "SUCCEEDED"
            } else {
                paid["status"] == "complete"
            },
            "Lightning payer failed: {paid}"
        );
        let p = poll("Breez Lightning receive", || async {
            sdk.sync_wallet(SyncWalletRequest {}).await?;
            let payments = sdk.list_payments(ListPaymentsRequest::default()).await?.payments;
            let matches: Vec<_> = payments.into_iter().filter(|p| p.payment_type == PaymentType::Receive && matches!(&p.details, Some(PaymentDetails::Lightning { invoice: i, .. }) if i == &invoice)).collect();
            ensure!(matches.len() == 1 && matches[0].status == PaymentStatus::Completed, "receive not uniquely completed");
            Ok(matches[0].clone())
        }).await?;
        let (hash, preimage) = proof(&p)?;
        ensure!(
            p.amount == 5000
                && p.fees == 0
                && paid["payment_hash"] == hash
                && paid["payment_preimage"] == preimage,
            "receive settlement mismatch"
        );
        exact_balance(&sdk, before + 5000).await?;
        settlements.push(
            json!({"peer":peer,"direction":"INBOUND","sats":5000,"hash":hash,"preimage":preimage}),
        );
        println!("PASS: {peer} -> Breez: 5000 sats, matching wallet/payer hash and preimage");
    }

    // Withdraw the remaining Spark balance through Breez's standard cooperative-exit API.
    let before = balance(&sdk).await?;
    let destination = text(&btc(&c, "getnewaddress", json!(["breez-withdraw", "bech32m"])).await?)?;
    let prepare = sdk
        .prepare_send_payment(PrepareSendPaymentRequest {
            payment_request: PaymentRequest::Input {
                input: destination.clone(),
            },
            amount: Some(before.into()),
            token_identifier: None,
            conversion_options: None,
            fee_policy: Some(FeePolicy::FeesIncluded),
        })
        .await?;
    let SendPaymentMethod::BitcoinAddress { fee_quote, .. } = &prepare.payment_method else {
        bail!("not a Bitcoin withdrawal")
    };
    let fee = fee_quote.speed_fast.total_fee_sat();
    ensure!(fee > 0 && fee < before, "invalid withdrawal fee");
    let sent = sdk
        .send_payment(SendPaymentRequest {
            prepare_response: prepare,
            options: Some(SendPaymentOptions::BitcoinAddress {
                confirmation_speed: OnchainConfirmationSpeed::Fast,
            }),
            idempotency_key: None,
        })
        .await?;
    let withdrawal_txid = poll("withdrawal broadcast", || async {
        sdk.sync_wallet(SyncWalletRequest {}).await?;
        let p = sdk
            .get_payment(GetPaymentRequest {
                payment_id: sent.payment.id.clone(),
            })
            .await?
            .payment;
        let Some(PaymentDetails::Withdraw { tx_id }) = p.details else {
            bail!("withdrawal txid not yet available")
        };
        btc(&c, "getrawtransaction", json!([tx_id, true])).await?;
        Ok(tx_id)
    })
    .await?;
    mine(&c, 12).await?;
    let p = completed(&sdk, &sent.payment.id).await?;
    ensure!(
        p.payment_type == PaymentType::Send
            && p.amount + p.fees == before as u128
            && p.fees == fee as u128,
        "withdrawal SDK accounting mismatch"
    );
    let tx = btc(&c, "getrawtransaction", json!([withdrawal_txid, true])).await?;
    ensure!(
        tx["confirmations"].as_u64().unwrap_or(0) >= 3,
        "withdrawal unconfirmed"
    );
    let output = tx["vout"]
        .as_array()
        .context("no withdrawal outputs")?
        .iter()
        .find(|v| v["scriptPubKey"]["address"] == destination)
        .context("missing withdrawal output")?;
    let paid_sats =
        (output["value"].as_f64().context("invalid output value")? * 100000000.0).round() as u64;
    ensure!(
        paid_sats == before - fee,
        "withdrawal Bitcoin payout mismatch"
    );
    exact_balance(&sdk, 0).await?;
    let records = sdk
        .list_payments(ListPaymentsRequest::default())
        .await?
        .payments;
    ensure!(
        records.len() == 6 && records.iter().all(|p| p.status == PaymentStatus::Completed),
        "incomplete or duplicate wallet payments"
    );
    sdk.disconnect().await?;
    let reopened = connect(&c, storage.path().to_string_lossy().into_owned(), seed).await?;
    exact_balance(&reopened, 0).await?;
    ensure!(
        reopened
            .list_payments(ListPaymentsRequest::default())
            .await?
            .payments
            .len()
            == 6,
        "wallet history lost after reconnect"
    );
    reopened.disconnect().await?;
    println!(
        "PASS: Breez onchain send: {paid_sats} sats confirmed, {fee} sats fee; wallet history survives reconnect"
    );
    println!(
        "{}",
        json!({"status":"PASS","sdk":"breez/spark-sdk@a3fac0e8f1f38e7e3dca110a22f37dd3264e2bde","settlements":settlements,"depositTxid":txid,"withdrawalTxid":withdrawal_txid,"depositCreditSats":quote.mature.credit_amount_sats,"withdrawalSats":paid_sats,"finalBalanceSats":0})
    );
    Ok(())
}
#[tokio::main]
async fn main() -> Result<()> {
    timeout(Duration::from_secs(1200), run())
        .await
        .context("Breez acceptance exceeded 20 minutes")?
}
