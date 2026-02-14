use anyhow::Result;
use bitcoin::{Address, Amount};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tracing::{info, error};

#[derive(Debug, Serialize, Deserialize)]
pub struct BitcoinRpcRequest {
    jsonrpc: String,
    id: String,
    method: String,
    params: serde_json::Value,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct BitcoinRpcResponse {
    result: Option<serde_json::Value>,
    error: Option<serde_json::Value>,
    id: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct BlockchainInfo {
    pub chain: String,
    pub blocks: i64,
    pub headers: i64,
    pub bestblockhash: String,
    pub difficulty: f64,
    pub mediantime: i64,
    pub verificationprogress: f64,
    pub chainwork: String,
    pub size_on_disk: u64,
    pub pruned: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WalletInfo {
    pub walletname: String,
    pub walletversion: i32,
    pub balance: f64,
    pub unconfirmed_balance: f64,
    pub immature_balance: f64,
    pub txcount: i32,
    pub keypoololdest: i32,
    pub keypoolsize: i32,
    pub keypoolsize_hd_internal: i32,
    pub paytxfee: f64,
    pub private_keys_enabled: bool,
    pub avoid_reuse: bool,
    pub scanning: ScanningInfo,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ScanningInfo {
    pub scanning: bool,
    pub amount: Option<f64>,
    pub progress: Option<f64>,
}

pub struct BitcoinClient {
    client: Client,
    rpc_url: String,
    rpc_user: String,
    rpc_password: String,
}

impl BitcoinClient {
    pub fn new(rpc_url: String, rpc_user: String, rpc_password: String) -> Self {
        Self {
            client: Client::new(),
            rpc_url,
            rpc_user,
            rpc_password,
        }
    }
    
    async fn make_request(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
        let request = BitcoinRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: "1".to_string(),
            method: method.to_string(),
            params,
        };
        
        let response = self.client
            .post(&self.rpc_url)
            .basic_auth(&self.rpc_user, Some(&self.rpc_password))
            .json(&request)
            .send()
            .await?;
        
        let rpc_response: BitcoinRpcResponse = response.json().await?;
        
        if let Some(error) = rpc_response.error {
            return Err(anyhow::anyhow!("Bitcoin RPC error: {:?}", error));
        }
        
        rpc_response.result.ok_or_else(|| anyhow::anyhow!("No result in RPC response"))
    }
    
    pub async fn get_blockchain_info(&self) -> Result<BlockchainInfo> {
        let result = self.make_request("getblockchaininfo", serde_json::Value::Null).await?;
        let info: BlockchainInfo = serde_json::from_value(result)?;
        Ok(info)
    }
    
    pub async fn get_wallet_info(&self) -> Result<WalletInfo> {
        let result = self.make_request("getwalletinfo", serde_json::Value::Null).await?;
        let info: WalletInfo = serde_json::from_value(result)?;
        Ok(info)
    }
    
    pub async fn get_balance(&self) -> Result<f64> {
        let result = self.make_request("getbalance", serde_json::json!([])).await?;
        let balance = result.as_f64().ok_or_else(|| anyhow::anyhow!("Invalid balance format"))?;
        Ok(balance)
    }
    
    pub async fn generate_address(&self) -> Result<String> {
        let result = self.make_request("getnewaddress", serde_json::json!([])).await?;
        let address = result.as_str().ok_or_else(|| anyhow::anyhow!("Invalid address format"))?;
        Ok(address.to_string())
    }
    
    pub async fn send_to_address(&self, address: &str, amount: f64) -> Result<String> {
        let result = self.make_request("sendtoaddress", serde_json::json!([address, amount])).await?;
        let txid = result.as_str().ok_or_else(|| anyhow::anyhow!("Invalid txid format"))?;
        Ok(txid.to_string())
    }
    
    pub async fn estimate_smart_fee(&self, conf_target: i32) -> Result<f64> {
        let result = self.make_request("estimatesmartfee", serde_json::json!([conf_target])).await?;
        let fee_info = result.as_object().ok_or_else(|| anyhow::anyhow!("Invalid fee estimate format"))?;
        let fee_rate = fee_info.get("feerate")
            .and_then(|v| v.as_f64())
            .ok_or_else(|| anyhow::anyhow!("No feerate in estimate"))?;
        Ok(fee_rate)
    }
    
    pub async fn get_transaction(&self, txid: &str) -> Result<serde_json::Value> {
        let result = self.make_request("gettransaction", serde_json::json!([txid])).await?;
        Ok(result)
    }
    
    pub async fn validate_address(&self, address: &str) -> Result<bool> {
        let result = self.make_request("validateaddress", serde_json::json!([address])).await?;
        let is_valid = result.get("isvalid")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        Ok(is_valid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[tokio::test]
    async fn test_bitcoin_client() {
        let client = BitcoinClient::new(
            "http://127.0.0.1:8332".to_string(),
            "test".to_string(),
            "test".to_string(),
        );
        
        // This would fail in tests without a real Bitcoin node
        // let info = client.get_blockchain_info().await;
        // assert!(info.is_ok());
    }
}
