use anyhow::Result;
use std::sync::Arc;
use tonic::{Request, Response, Status};

use crate::database::Database;
use crate::models::{User, Payment, Invoice};
use crate::wallet_grpc::{
    wallet_service_server::WalletService,
    GetUserRequest, GetUserResponse,
    CreatePaymentRequest, CreatePaymentResponse,
    ListPaymentsRequest, ListPaymentsResponse,
    CreateInvoiceRequest, CreateInvoiceResponse,
    BalanceRequest, BalanceResponse,
};

pub struct WalletGrpcService {
    db: Arc<Database>,
}

impl WalletGrpcService {
    pub fn new(db: Arc<Database>) -> Self {
        Self { db }
    }
    
    fn map_user_to_proto(user: &User) -> wallet_grpc::User {
        wallet_grpc::User {
            id: user.id.clone(),
            username: user.username.clone(),
            pubkey: user.pubkey.clone().unwrap_or_default(),
            npub: user.npub.clone().unwrap_or_default(),
            balance: user.balance,
            currency: user.currency.clone(),
            display: user.display.clone().unwrap_or_default(),
            picture: user.picture.clone().unwrap_or_default(),
            about: user.about.clone().unwrap_or_default(),
            verified: user.verified,
            created: user.created.timestamp(),
        }
    }
    
    fn map_payment_to_proto(payment: &Payment) -> wallet_grpc::Payment {
        wallet_grpc::Payment {
            id: payment.id.clone(),
            amount: payment.amount,
            fee: payment.fee.unwrap_or(0),
            memo: payment.memo.clone().unwrap_or_default(),
            hash: payment.hash.clone().unwrap_or_default(),
            r#type: payment.r#type.clone(),
            created: payment.created.timestamp(),
            confirmed: payment.confirmed,
            user: None, // Will be populated if needed
        }
    }
    
    fn map_invoice_to_proto(invoice: &Invoice) -> wallet_grpc::Invoice {
        wallet_grpc::Invoice {
            id: invoice.id.clone(),
            hash: invoice.hash.clone(),
            amount: invoice.amount,
            memo: invoice.memo.clone().unwrap_or_default(),
            bolt11: invoice.bolt11.clone().unwrap_or_default(),
            created: invoice.created.timestamp(),
            paid: invoice.paid,
        }
    }
}

#[tonic::async_trait]
impl WalletService for WalletGrpcService {
    async fn get_user(&self, request: Request<GetUserRequest>) -> Result<Response<GetUserResponse>, Status> {
        let req = request.into_inner();
        
        let user = if !req.id.is_empty() {
            self.db.get_user_by_id(&req.id).await
        } else if !req.username.is_empty() {
            self.db.get_user_by_username(&req.username).await
        } else if !req.pubkey.is_empty() {
            // TODO: Implement get_user_by_pubkey
            Ok(None)
        } else {
            return Err(Status::invalid_argument("Must provide id, username, or pubkey"));
        };
        
        match user {
            Ok(Some(user)) => {
                let proto_user = Self::map_user_to_proto(&user);
                Ok(Response::new(GetUserResponse { user: Some(proto_user) }))
            }
            Ok(None) => Err(Status::not_found("User not found")),
            Err(e) => {
                tracing::error!("Error getting user: {}", e);
                Err(Status::internal("Database error"))
            }
        }
    }
    
    async fn create_payment(&self, request: Request<CreatePaymentRequest>) -> Result<Response<CreatePaymentResponse>, Status> {
        let req = request.into_inner();
        
        // Verify user exists
        let user = match self.db.get_user_by_id(&req.user_id).await {
            Ok(Some(user)) => user,
            Ok(None) => return Err(Status::not_found("User not found")),
            Err(e) => {
                tracing::error!("Error getting user: {}", e);
                return Err(Status::internal("Database error"));
            }
        };
        
        // Check balance for outgoing payments
        if req.amount < 0 && user.balance < -req.amount {
            return Err(Status::failed_precondition("Insufficient balance"));
        }
        
        // Create payment
        let mut payment = Payment::new(req.user_id.clone(), req.amount, "sent".to_string());
        payment.fee = Some(req.fee);
        payment.memo = if req.memo.is_empty() { None } else { Some(req.memo) };
        payment.hash = if req.payreq.is_empty() { None } else { Some(req.payreq) };
        
        if let Err(e) = self.db.create_payment(&payment).await {
            tracing::error!("Error creating payment: {}", e);
            return Err(Status::internal("Failed to create payment"));
        }
        
        // Update user balance
        let new_balance = user.balance + payment.amount;
        if let Err(e) = self.db.update_user_balance(&req.user_id, new_balance).await {
            tracing::error!("Error updating balance: {}", e);
            return Err(Status::internal("Failed to update balance"));
        }
        
        let proto_payment = Self::map_payment_to_proto(&payment);
        Ok(Response::new(CreatePaymentResponse { payment: Some(proto_payment) }))
    }
    
    async fn list_payments(&self, request: Request<ListPaymentsRequest>) -> Result<Response<ListPaymentsResponse>, Status> {
        let req = request.into_inner();
        
        let payments = match self.db.list_payments(&req.user_id, req.limit, req.offset).await {
            Ok(payments) => payments,
            Err(e) => {
                tracing::error!("Error listing payments: {}", e);
                return Err(Status::internal("Failed to list payments"));
            }
        };
        
        let proto_payments: Vec<_> = payments.iter()
            .map(Self::map_payment_to_proto)
            .collect();
        
        Ok(Response::new(ListPaymentsResponse {
            payments: proto_payments,
            total: proto_payments.len() as i32,
        }))
    }
    
    async fn create_invoice(&self, request: Request<CreateInvoiceRequest>) -> Result<Response<CreateInvoiceResponse>, Status> {
        let req = request.into_inner();
        
        // Verify user exists
        let _user = match self.db.get_user_by_id(&req.user_id).await {
            Ok(Some(user)) => user,
            Ok(None) => return Err(Status::not_found("User not found")),
            Err(e) => {
                tracing::error!("Error getting user: {}", e);
                return Err(Status::internal("Database error"));
            }
        };
        
        // Create invoice
        let mut invoice = Invoice::new(req.user_id.clone(), req.amount);
        invoice.memo = if req.memo.is_empty() { None } else { Some(req.memo) };
        
        if let Err(e) = self.db.create_invoice(&invoice).await {
            tracing::error!("Error creating invoice: {}", e);
            return Err(Status::internal("Failed to create invoice"));
        }
        
        let proto_invoice = Self::map_invoice_to_proto(&invoice);
        Ok(Response::new(CreateInvoiceResponse { invoice: Some(proto_invoice) }))
    }
    
    async fn get_balance(&self, request: Request<BalanceRequest>) -> Result<Response<BalanceResponse>, Status> {
        let req = request.into_inner();
        
        let balance = match self.db.get_user_balance(&req.user_id).await {
            Ok(balance) => balance,
            Err(e) => {
                tracing::error!("Error getting balance: {}", e);
                return Err(Status::internal("Failed to get balance"));
            }
        };
        
        Ok(Response::new(BalanceResponse { balance }))
    }
}
