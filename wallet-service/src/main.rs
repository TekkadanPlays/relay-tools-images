use anyhow::Result;
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tracing::{info, error};
use tracing_subscriber;

mod database;
mod grpc_service;
mod http_service;
mod models;
mod bitcoin;

use database::Database;
use grpc_service::WalletService;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize tracing
    tracing_subscriber::fmt::init();

    // Initialize database
    let db = Database::new("wallet.db").await?;
    info!("Database initialized");

    // Start gRPC server
    let grpc_addr = SocketAddr::from(([127, 0, 0, 1], 50051));
    let grpc_service = WalletService::new(db.clone());
    let grpc_server = tonic::transport::Server::builder()
        .add_service(wallet_grpc::WalletServiceServer::new(grpc_service))
        .serve(grpc_addr);

    // Start HTTP server
    let http_addr = SocketAddr::from(([127, 0, 0, 1], 8080));
    let http_service = http_service::create_app(db);
    let http_server = axum::Server::bind(&http_addr).serve(http_service.into_make_service());

    info!("Starting gRPC server on {}", grpc_addr);
    info!("Starting HTTP server on {}", http_addr);

    // Run both servers
    tokio::try_join!(
        async {
            if let Err(e) = grpc_server.await {
                error!("gRPC server error: {}", e);
            }
            Ok::<_, anyhow::Error>(())
        },
        async {
            if let Err(e) = http_server.await {
                error!("HTTP server error: {}", e);
            }
            Ok::<_, anyhow::Error>(())
        }
    )?;

    Ok(())
}
