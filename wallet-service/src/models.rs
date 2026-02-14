use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: String,
    pub username: String,
    pub pubkey: Option<String>,
    pub npub: Option<String>,
    pub balance: i64,
    pub currency: String,
    pub display: Option<String>,
    pub picture: Option<String>,
    pub about: Option<String>,
    pub verified: bool,
    pub created: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Payment {
    pub id: String,
    pub user_id: String,
    pub amount: i64,
    pub fee: Option<i64>,
    pub memo: Option<String>,
    pub hash: Option<String>,
    pub r#type: String, // "sent" | "received" | "internal"
    pub created: DateTime<Utc>,
    pub confirmed: bool,
    pub with_user_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Invoice {
    pub id: String,
    pub user_id: String,
    pub hash: String,
    pub amount: i64,
    pub memo: Option<String>,
    pub bolt11: Option<String>,
    pub created: DateTime<Utc>,
    pub paid: bool,
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    pub name: String,
    pub r#type: Option<String>, // "personal" | "business" | "savings"
    pub user_id: String,
    pub balance: i64,
    pub created: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Contact {
    pub id: String,
    pub user_id: String,
    pub contact_user_id: String,
    pub pinned: bool,
    pub trusted: bool,
    pub created: DateTime<Utc>,
}

impl User {
    pub fn new(username: String, pubkey: Option<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            username,
            pubkey,
            npub: None,
            balance: 0,
            currency: "USD".to_string(),
            display: None,
            picture: None,
            about: None,
            verified: false,
            created: Utc::now(),
        }
    }
}

impl Payment {
    pub fn new(user_id: String, amount: i64, payment_type: String) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            user_id,
            amount,
            fee: None,
            memo: None,
            hash: None,
            r#type: payment_type,
            created: Utc::now(),
            confirmed: false,
            with_user_id: None,
        }
    }
}

impl Invoice {
    pub fn new(user_id: String, amount: i64) -> Self {
        let id = Uuid::new_v4().to_string();
        Self {
            id: id.clone(),
            user_id,
            hash: id, // Use ID as hash for now
            amount,
            memo: None,
            bolt11: None,
            created: Utc::now(),
            paid: false,
            expires_at: None,
        }
    }
}

impl Account {
    pub fn new(name: String, user_id: String) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name,
            r#type: Some("personal".to_string()),
            user_id,
            balance: 0,
            created: Utc::now(),
        }
    }
}
