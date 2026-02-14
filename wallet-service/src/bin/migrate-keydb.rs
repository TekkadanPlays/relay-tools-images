use anyhow::Result;
use rusqlite::Connection;
use serde_json::Value;
use tracing::info;
use tracing_subscriber;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: migrate-keydb <input.json> <output.db>");
        std::process::exit(1);
    }
    
    let input_file = &args[1];
    let output_db = &args[2];
    
    info!("Starting migration from {} to {}", input_file, output_db);
    
    // Read KeyDB export
    let keydb_data = std::fs::read_to_string(input_file)?;
    let keydb_json: Value = serde_json::from_str(&keydb_data)?;
    
    // Initialize SQLite database
    let conn = Connection::open(output_db)?;
    setup_schema(&conn)?;
    
    // Migrate data
    migrate_users(&conn, &keydb_json)?;
    migrate_payments(&conn, &keydb_json)?;
    migrate_invoices(&conn, &keydb_json)?;
    
    info!("Migration completed successfully");
    Ok(())
}

fn setup_schema(conn: &Connection) -> Result<()> {
    info!("Setting up database schema");
    
    // Users table
    conn.execute(
        r#"
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            username TEXT UNIQUE NOT NULL,
            pubkey TEXT,
            npub TEXT,
            balance INTEGER NOT NULL DEFAULT 0,
            currency TEXT NOT NULL DEFAULT 'USD',
            display TEXT,
            picture TEXT,
            about TEXT,
            verified BOOLEAN NOT NULL DEFAULT FALSE,
            created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        "#,
        [],
    )?;
    
    // Payments table
    conn.execute(
        r#"
        CREATE TABLE IF NOT EXISTS payments (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            amount INTEGER NOT NULL,
            fee INTEGER,
            memo TEXT,
            hash TEXT,
            type TEXT NOT NULL,
            created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            confirmed BOOLEAN NOT NULL DEFAULT FALSE,
            with_user_id TEXT,
            FOREIGN KEY (user_id) REFERENCES users(id),
            FOREIGN KEY (with_user_id) REFERENCES users(id)
        )
        "#,
        [],
    )?;
    
    // Invoices table
    conn.execute(
        r#"
        CREATE TABLE IF NOT EXISTS invoices (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            hash TEXT UNIQUE NOT NULL,
            amount INTEGER NOT NULL,
            memo TEXT,
            bolt11 TEXT,
            created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            paid BOOLEAN NOT NULL DEFAULT FALSE,
            expires_at DATETIME,
            FOREIGN KEY (user_id) REFERENCES users(id)
        )
        "#,
        [],
    )?;
    
    // Accounts table
    conn.execute(
        r#"
        CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT,
            user_id TEXT NOT NULL,
            balance INTEGER NOT NULL DEFAULT 0,
            created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        )
        "#,
        [],
    )?;
    
    // Contacts table
    conn.execute(
        r#"
        CREATE TABLE IF NOT EXISTS contacts (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            contact_user_id TEXT NOT NULL,
            pinned BOOLEAN NOT NULL DEFAULT FALSE,
            trusted BOOLEAN NOT NULL DEFAULT FALSE,
            created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id),
            FOREIGN KEY (contact_user_id) REFERENCES users(id),
            UNIQUE(user_id, contact_user_id)
        )
        "#,
        [],
    )?;
    
    // Create indexes
    conn.execute("CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)", [])?;
    conn.execute("CREATE INDEX IF NOT EXISTS idx_users_pubkey ON users(pubkey)", [])?;
    conn.execute("CREATE INDEX IF NOT EXISTS idx_payments_user_id ON payments(user_id)", [])?;
    conn.execute("CREATE INDEX IF NOT EXISTS idx_payments_created ON payments(created)", [])?;
    conn.execute("CREATE INDEX IF NOT EXISTS idx_invoices_user_id ON invoices(user_id)", [])?;
    conn.execute("CREATE INDEX IF NOT EXISTS idx_accounts_user_id ON accounts(user_id)", [])?;
    
    Ok(())
}

fn migrate_users(conn: &Connection, keydb_json: &Value) -> Result<()> {
    info!("Migrating users");
    
    let mut user_count = 0;
    
    // KeyDB stores data as key-value pairs
    if let Some(obj) = keydb_json.as_object() {
        for (key, value) in obj {
            // Look for user data patterns
            if key.starts_with("user:") {
                if let Ok(user_data) = serde_json::from_value::<Value>(value.clone()) {
                    if let Some(user_obj) = user_data.as_object() {
                        let id_owned = user_obj.get("id")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                        let id = id_owned.as_str();
                        
                        let username = user_obj.get("username")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown");
                        
                        let balance = user_obj.get("balance")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        
                        let pubkey = user_obj.get("pubkey")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let npub = user_obj.get("npub")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let display = user_obj.get("display")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let picture = user_obj.get("picture")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let about = user_obj.get("about")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let verified = user_obj.get("verified")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        
                        conn.execute(
                            r#"
                            INSERT OR REPLACE INTO users (id, username, pubkey, npub, balance, currency, display, picture, about, verified)
                            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                            "#,
                            rusqlite::params![
                                id,
                                username,
                                pubkey,
                                npub,
                                balance,
                                "USD",
                                display,
                                picture,
                                about,
                                verified
                            ],
                        )?;
                        
                        user_count += 1;
                    }
                }
            }
        }
    }
    
    info!("Migrated {} users", user_count);
    Ok(())
}

fn migrate_payments(conn: &Connection, keydb_json: &Value) -> Result<()> {
    info!("Migrating payments");
    
    let mut payment_count = 0;
    
    if let Some(obj) = keydb_json.as_object() {
        for (key, value) in obj {
            if key.starts_with("payment:") {
                if let Ok(payment_data) = serde_json::from_value::<Value>(value.clone()) {
                    if let Some(payment_obj) = payment_data.as_object() {
                        let id_owned = payment_obj.get("id")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                        let id = id_owned.as_str();
                        
                        let user_id = payment_obj.get("user_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        
                        let amount = payment_obj.get("amount")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        
                        let fee = payment_obj.get("fee")
                            .and_then(|v| v.as_i64());
                        
                        let memo = payment_obj.get("memo")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let hash = payment_obj.get("hash")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let payment_type = payment_obj.get("type")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown");
                        
                        let confirmed = payment_obj.get("confirmed")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        
                        let with_user_id = payment_obj.get("with_user_id")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        conn.execute(
                            r#"
                            INSERT OR REPLACE INTO payments (id, user_id, amount, fee, memo, hash, type, confirmed, with_user_id)
                            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                            "#,
                            rusqlite::params![
                                id,
                                user_id,
                                amount,
                                fee,
                                memo,
                                hash,
                                payment_type,
                                confirmed,
                                with_user_id
                            ],
                        )?;
                        
                        payment_count += 1;
                    }
                }
            }
        }
    }
    
    info!("Migrated {} payments", payment_count);
    Ok(())
}

fn migrate_invoices(conn: &Connection, keydb_json: &Value) -> Result<()> {
    info!("Migrating invoices");
    
    let mut invoice_count = 0;
    
    if let Some(obj) = keydb_json.as_object() {
        for (key, value) in obj {
            if key.starts_with("invoice:") {
                if let Ok(invoice_data) = serde_json::from_value::<Value>(value.clone()) {
                    if let Some(invoice_obj) = invoice_data.as_object() {
                        let id_owned = invoice_obj.get("id")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                        let id = id_owned.as_str();
                        
                        let user_id = invoice_obj.get("user_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        
                        let hash_owned = invoice_obj.get("hash")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        let hash = hash_owned.as_deref().unwrap_or(id);
                        
                        let amount = invoice_obj.get("amount")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        
                        let memo = invoice_obj.get("memo")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        
                        let paid = invoice_obj.get("paid")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        
                        conn.execute(
                            r#"
                            INSERT OR REPLACE INTO invoices (id, user_id, hash, amount, memo, bolt11, paid)
                            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                            "#,
                            rusqlite::params![
                                id,
                                user_id,
                                hash,
                                amount,
                                memo,
                                bolt11,
                                paid
                            ],
                        )?;
                        
                        invoice_count += 1;
                    }
                }
            }
        }
    }
    
    info!("Migrated {} invoices", invoice_count);
    Ok(())
}
