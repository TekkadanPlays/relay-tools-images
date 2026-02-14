use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tower_http::cors::{CorsLayer, Any};

use crate::database::Database;
use crate::models::{User, Payment, Invoice};

#[derive(Deserialize)]
struct PaginationQuery {
    limit: Option<i32>,
    offset: Option<i32>,
}

#[derive(Deserialize)]
struct CreateUserRequest {
    username: String,
    pubkey: Option<String>,
}

#[derive(Deserialize)]
struct CreatePaymentRequest {
    user_id: String,
    amount: i64,
    payreq: Option<String>,
    memo: Option<String>,
    fee: Option<i64>,
}

#[derive(Deserialize)]
struct CreateInvoiceRequest {
    user_id: String,
    amount: i64,
    memo: Option<String>,
    r#type: Option<String>,
}

#[derive(Serialize)]
struct ApiResponse<T> {
    success: bool,
    data: Option<T>,
    error: Option<String>,
}

impl<T> ApiResponse<T> {
    fn success(data: T) -> Self {
        Self {
            success: true,
            data: Some(data),
            error: None,
        }
    }
    
    fn error(message: &str) -> Self {
        Self {
            success: false,
            data: None,
            error: Some(message.to_string()),
        }
    }
}

pub fn create_app(db: Arc<Database>) -> Router {
    let app = Router::new()
        // User endpoints
        .route("/users", post(create_user))
        .route("/users/:id", get(get_user))
        .route("/users/username/:username", get(get_user_by_username))
        
        // Payment endpoints
        .route("/payments", post(create_payment))
        .route("/payments", get(list_payments))
        .route("/payments/:id", get(get_payment))
        
        // Invoice endpoints
        .route("/invoices", post(create_invoice))
        .route("/invoices/:id", get(get_invoice))
        
        // Balance endpoint
        .route("/balance/:user_id", get(get_balance))
        
        // Health check
        .route("/health", get(health_check))
        
        .layer(CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any))
        .with_state(db);
    
    app
}

async fn health_check() -> Json<ApiResponse<HashMap<String, String>>> {
    let mut status = HashMap::new();
    status.insert("status".to_string(), "healthy".to_string());
    status.insert("service".to_string(), "wallet-service".to_string());
    Json(ApiResponse::success(status))
}

async fn create_user(
    State(db): State<Arc<Database>>,
    Json(req): Json<CreateUserRequest>,
) -> Result<Json<ApiResponse<User>>, StatusCode> {
    let user = User::new(req.username.clone(), req.pubkey.clone());
    
    match db.create_user(&user).await {
        Ok(_) => Ok(Json(ApiResponse::success(user))),
        Err(e) => {
            tracing::error!("Error creating user: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn get_user(
    State(db): State<Arc<Database>>,
    Path(id): Path<String>,
) -> Result<Json<ApiResponse<User>>, StatusCode> {
    match db.get_user_by_id(&id).await {
        Ok(Some(user)) => Ok(Json(ApiResponse::success(user))),
        Ok(None) => Err(StatusCode::NOT_FOUND),
        Err(e) => {
            tracing::error!("Error getting user: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn get_user_by_username(
    State(db): State<Arc<Database>>,
    Path(username): Path<String>,
) -> Result<Json<ApiResponse<User>>, StatusCode> {
    match db.get_user_by_username(&username).await {
        Ok(Some(user)) => Ok(Json(ApiResponse::success(user))),
        Ok(None) => Err(StatusCode::NOT_FOUND),
        Err(e) => {
            tracing::error!("Error getting user: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn create_payment(
    State(db): State<Arc<Database>>,
    Json(req): Json<CreatePaymentRequest>,
) -> Result<Json<ApiResponse<Payment>>, StatusCode> {
    // Verify user exists
    let user = match db.get_user_by_id(&req.user_id).await {
        Ok(Some(user)) => user,
        Ok(None) => return Err(StatusCode::NOT_FOUND),
        Err(e) => {
            tracing::error!("Error getting user: {}", e);
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    };
    
    // Check balance for outgoing payments
    if req.amount < 0 && user.balance < -req.amount {
        return Err(StatusCode::BAD_REQUEST);
    }
    
    // Create payment
    let mut payment = Payment::new(req.user_id.clone(), req.amount, "sent".to_string());
    payment.fee = req.fee;
    payment.memo = req.memo;
    payment.hash = req.payreq;
    
    if let Err(e) = db.create_payment(&payment).await {
        tracing::error!("Error creating payment: {}", e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    
    // Update user balance
    let new_balance = user.balance + payment.amount;
    if let Err(e) = db.update_user_balance(&req.user_id, new_balance).await {
        tracing::error!("Error updating balance: {}", e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    
    Ok(Json(ApiResponse::success(payment)))
}

async fn list_payments(
    State(db): State<Arc<Database>>,
    Query(query): Query<PaginationQuery>,
) -> Result<Json<ApiResponse<Vec<Payment>>>, StatusCode> {
    let limit = query.limit.unwrap_or(10);
    let offset = query.offset.unwrap_or(0);
    
    // For now, return empty list since we need user_id
    // In a real implementation, you'd get user_id from auth token
    Ok(Json(ApiResponse::success(vec![])))
}

async fn get_payment(
    State(_db): State<Arc<Database>>,
    Path(_id): Path<String>,
) -> Json<ApiResponse<String>> {
    Json(ApiResponse::error("Not implemented"))
}

async fn create_invoice(
    State(db): State<Arc<Database>>,
    Json(req): Json<CreateInvoiceRequest>,
) -> Result<Json<ApiResponse<Invoice>>, StatusCode> {
    // Verify user exists
    let _user = match db.get_user_by_id(&req.user_id).await {
        Ok(Some(user)) => user,
        Ok(None) => return Err(StatusCode::NOT_FOUND),
        Err(e) => {
            tracing::error!("Error getting user: {}", e);
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    };
    
    // Create invoice
    let mut invoice = Invoice::new(req.user_id.clone(), req.amount);
    invoice.memo = req.memo;
    
    if let Err(e) = db.create_invoice(&invoice).await {
        tracing::error!("Error creating invoice: {}", e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    
    Ok(Json(ApiResponse::success(invoice)))
}

async fn get_invoice(
    State(_db): State<Arc<Database>>,
    Path(_id): Path<String>,
) -> Json<ApiResponse<String>> {
    Json(ApiResponse::error("Not implemented"))
}

async fn get_balance(
    State(db): State<Arc<Database>>,
    Path(user_id): Path<String>,
) -> Result<Json<ApiResponse<i64>>, StatusCode> {
    match db.get_user_balance(&user_id).await {
        Ok(balance) => Ok(Json(ApiResponse::success(balance))),
        Err(e) => {
            tracing::error!("Error getting balance: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}
