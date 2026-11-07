//! Exercise the real fastboot session over a length-framed TCP boundary.
//!
//! `serve 127.0.0.1:0 --serial smoke-1`  run a local responder and print its port
//! `client 127.0.0.1:PORT smoke-1 [--expect-product NAME]`  open the responder
//! `smoke`  bind an ephemeral port, run both sides, and verify the transcript
//!
//! This is a test seam only: `--features tcp-smoke` builds it, and the app never
//! exposes a network path.

use std::env;

use anyhow::{anyhow, Context, Result};
use fastboot_link::tcp::{client, Responder};
use tokio::net::{TcpListener, TcpStream};

fn usage() -> Result<()> {
    Err(anyhow!(
        "usage: tcp_smoke serve <addr> --serial <serial> | \
         tcp_smoke client <addr> <serial> [--expect-product <name>] | tcp_smoke smoke"
    ))
}

async fn serve(addr: &str, serial: &str) -> Result<()> {
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("bind {addr}"))?;
    println!("LISTEN {}", listener.local_addr()?);
    let (stream, peer) = listener.accept().await.context("accept")?;
    println!("ACCEPT {peer}");
    Responder {
        product: "synthetic-device".to_string(),
        serial: serial.to_string(),
        fail_download: false,
    }
    .serve(stream)
    .await
    .context("responder")
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => {
            let addr = args.get(1).context("missing listen address")?;
            let serial = args
                .iter()
                .position(|arg| arg == "--serial")
                .and_then(|index| args.get(index + 1))
                .context("missing --serial")?;
            serve(addr, serial).await
        }
        Some("client") => {
            let addr = args.get(1).context("missing server address")?;
            let serial = args.get(2).context("missing serial")?;
            let expect = args
                .iter()
                .position(|arg| arg == "--expect-product")
                .and_then(|index| args.get(index + 1))
                .map(String::as_str);
            let stream = TcpStream::connect(addr.as_str())
                .await
                .with_context(|| format!("connect {addr}"))?;
            println!(
                "{}",
                client(stream, serial, expect)
                    .await
                    .map_err(anyhow::Error::msg)?
            );
            Ok(())
        }
        Some("smoke") => {
            let listener = TcpListener::bind("127.0.0.1:0")
                .await
                .context("bind ephemeral port")?;
            let addr = listener.local_addr()?;
            println!("LISTEN {addr}");
            let server = tokio::spawn(async move {
                let (stream, peer) = listener.accept().await?;
                println!("ACCEPT {peer}");
                Responder {
                    product: "synthetic-device".to_string(),
                    serial: "smoke-1".to_string(),
                    fail_download: false,
                }
                .serve(stream)
                .await
            });
            let stream = TcpStream::connect(addr)
                .await
                .with_context(|| format!("connect {addr}"))?;
            let summary = client(stream, "smoke-1", Some("synthetic-device"))
                .await
                .map_err(anyhow::Error::msg)?;
            server.await.context("server task")??;
            println!("{summary}");
            println!("SMOKE-OK");
            Ok(())
        }
        _ => usage(),
    }
}
