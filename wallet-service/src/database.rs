use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::Arc;
use tokio::task;
use tracing::info;

use crate::models::{User, Payment, Invoice};

#[derive(Clone)]
pub struct Database {
    path: Arc<str>,
}

impl Database {
    pub async fn new(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute("PRAGMA foreign_keys = ON", [])?;
        Self::init_schema(&conn)?;
        Ok(Self {
            path: Arc::from(path.to_string()),
        })
    }

    fn open_connection(path: &Arc<str>) -> Result<Connection> {
        let conn = Connection::open(path.as_ref())?;
        conn.execute("PRAGMA foreign_keys = ON", [])?;
        Ok(conn)
    }

    async fn with_conn<T, F>(&self, f: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(Connection) -> Result<T> + Send + 'static,
    {
        let path = self.path.clone();
        let result = task::spawn_blocking(move || -> Result<T> {
            let conn = Self::open_connection(&path)?;
            f(conn)
        })
        .await?;
        result
    }

    fn init_schema(conn: &Connection) -> Result<()> {
        info!("Initializing database schema");

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

        conn.execute("CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)", [])?;
        conn.execute("CREATE INDEX IF NOT EXISTS idx_users_pubkey ON users(pubkey)", [])?;
        conn.execute("CREATE INDEX IF NOT EXISTS idx_payments_user_id ON payments(user_id)", [])?;
        conn.execute("CREATE INDEX IF NOT EXISTS idx_payments_created ON payments(created)", [])?;
        conn.execute("CREATE INDEX IF NOT EXISTS idx_invoices_user_id ON invoices(user_id)", [])?;
        conn.execute("CREATE INDEX IF NOT EXISTS idx_accounts_user_id ON accounts(user_id)", [])?;

        info!("Database schema initialized");
        Ok(())
    }

    pub async fn create_user(&self, user: &User) -> Result<()> {
        let user = user.clone();
        self.with_conn(move |conn| {
            conn.execute(
                r#"
                INSERT INTO users (id, username, pubkey, npub, balance, currency, display, picture, about, verified, created)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                "#,
                params![
                    user.id,
                    user.username,
                    user.pubkey,
                    user.npub,
                    user.balance,
                    user.currency,
                    user.display,
                    user.picture,
                    user.about,
                    user.verified,
                    user.created
                ],
            )?;
            Ok(())
        }).await
    }

    pub async fn get_user_by_id(&self, id: &str) -> Result<Option<User>> {
        let id = id.to_string();
        self.with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT id, username, pubkey, npub, balance, currency, display, picture, about, verified, created FROM users WHERE id = ?1"
            )?;
            let user = stmt.query_row([id.as_str()], |row| {
                Ok(User {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    pubkey: row.get(2)?,
                    npub: row.get(3)?,
                    balance: row.get(4)?,
                    currency: row.get(5)?,
                    display: row.get(6)?,
                    picture: row.get(7)?,
                    about: row.get(8)?,
                    verified: row.get(9)?,
                    created: row.get(10)?,
                })
            }).optional()?;
            Ok(user)
        }).await
    }

    pub async fn get_user_by_username(&self, username: &str) -> Result<Option<User>> {
        let username = username.to_string();
        self.with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT id, username, pubkey, npub, balance, currency, display, picture, about, verified, created FROM users WHERE username = ?1"
            )?;
            let user = stmt.query_row([username.as_str()], |row| {
                Ok(User {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    pubkey: row.get(2)?,
                    npub: row.get(3)?,
                    balance: row.get(4)?,
                    currency: row.get(5)?,
                    display: row.get(6)?,
                    picture: row.get(7)?,
                    about: row.get(8)?,
                    verified: row.get(9)?,
                    created: row.get(10)?,
                })
            }).optional()?;
            Ok(user)
        }).await
    }

    pub async fn update_user_balance(&self, user_id: &str, new_balance: i64) -> Result<()> {
        let user_id = user_id.to_string();
        self.with_conn(move |conn| {
            conn.execute(
                "UPDATE users SET balance = ?1 WHERE id = ?2",
                params![new_balance, user_id],
            )?;
            Ok(())
        }).await
    }

    pub async fn create_payment(&self, payment: &Payment) -> Result<()> {
        let payment = payment.clone();
        self.with_conn(move |conn| {
            conn.execute(
                r#"
                INSERT INTO payments (id, user_id, amount, fee, memo, hash, type, created, confirmed, with_user_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                "#,
                params![
                    payment.id,
                    payment.user_id,
                    payment.amount,
                    payment.fee,
                    payment.memo,
                    payment.hash,
                    payment.r#type,
                    payment.created,
                    payment.confirmed,
                    payment.with_user_id
                ],
            )?;
            Ok(())
        }).await
    }

    pub async fn list_payments(&self, user_id: &str, limit: i32, offset: i32) -> Result<Vec<Payment>> {
        let user_id = user_id.to_string();
        self.with_conn(move |conn| {
            let mut stmt = conn.prepare(
                r#"
                SELECT id, user_id, amount, fee, memo, hash, type, created, confirmed, with_user_id
                FROM payments 
                WHERE user_id = ?1 
                ORDER BY created DESC 
                LIMIT ?2 OFFSET ?3
                "#
            )?;
            let payments = stmt.query_map(params![user_id, limit, offset], |row| {
                Ok(Payment {
                    id: row.get(0)?,
                    user_id: row.get(1)?,
                    amount: row.get(2)?,
                    fee: row.get(3)?,
                    memo: row.get(4)?,
                    hash: row.get(5)?,
                    r#type: row.get(6)?,
                    created: row.get(7)?,
                    confirmed: row.get(8)?,
                    with_user_id: row.get(9)?,
                })
            })?.collect::<Result<Vec<_>, _>>()?;
            Ok(payments)
        }).await
    }

    pub async fn create_invoice(&self, invoice: &Invoice) -> Result<()> {
        let invoice = invoice.clone();
        self.with_conn(move |conn| {
            conn.execute(
                r#"
                INSERT INTO invoices (id, user_id, hash, amount, memo, bolt11, created, paid, expires_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                "#,
                params![
                    invoice.id,
                    invoice.user_id,
                    invoice.hash,
                    invoice.amount,
                    invoice.memo,
                    invoice.bolt11,
                    invoice.created,
                    invoice.paid,
                    invoice.expires_at
                ],
            )?;
            Ok(())
        }).await
    }

    pub async fn get_user_balance(&self, user_id: &str) -> Result<i64> {
        let user_id = user_id.to_string();
        self.with_conn(move |conn| {
            let balance: i64 = conn.query_row(
                "SELECT balance FROM users WHERE id = ?1",
                [user_id.as_str()],
                |row| row.get(0)
            )?;
            Ok(balance)
        }).await
    }
}
