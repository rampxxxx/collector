use rumqttc::{AsyncClient, MqttOptions, QoS};
use serde_json::json;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Note: host should be just the IP, port is separate in MqttOptions
    let broker_url =
        std::env::var("MQTT_BROKER").unwrap_or_else(|_| "tcp://192.168.122.200:1883".to_string());

    // Parse URL to get host and port
    let url = url::Url::parse(&broker_url)?;
    let host = url.host_str().unwrap_or("192.168.122.200").to_string();
    let port = url.port().unwrap_or(1883);

    println!(
        "INFO: Attempting to connect to broker at: {}:{}",
        host, port
    );

    let mut mqttoptions = MqttOptions::new("rust-collector", host, port);
    mqttoptions.set_keep_alive(Duration::from_secs(20));

    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 10);

    // Run eventloop in background
    tokio::spawn(async move {
        loop {
            if let Err(e) = eventloop.poll().await {
                eprintln!("Error in eventloop: {:?}", e);
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    });

    loop {
        let msg = json!({
            "sensor": "temperature",
            "value": 25.5,
            "status": "ok"
        });

        let payload = msg.to_string();

        match client
            .publish("sensors/orchids", QoS::AtLeastOnce, false, payload.clone())
            .await
        {
            Ok(_) => println!("Published message: sensors/orchids {}", payload),
            Err(e) => eprintln!("❌ Failed to publish message: {:?}", e),
        }

        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}
