use anyhow::Result;
use veilid_taxi::{
    pedestrian::{publish_request, PublishedPedestrianRequest},
    veilid::app_config,
};

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

pub struct VP2PApp {
    pub p2p_app: veilid_taxi::app::P2PApp,
}

impl VP2PApp {
    pub async fn new() -> Result<Self> {
        let config = app_config("veilid-taxi-cli");
        let mut app = Self {
            p2p_app: veilid_taxi::app::P2PApp::new(config).await?,
        };

        app.p2p_app.connect_to_network().await?;

        println!("app initialized");

        Ok(app)
    }

    pub async fn request_ride(&mut self, lat: f64, lon: f64) -> Result<PublishedPedestrianRequest> {
        let rc = self.p2p_app.veilid_api.routing_context()?;
        publish_request(&rc, lat, lon, 100).await
    }
}

pub async fn initialize_app() -> Result<VP2PApp> {
    VP2PApp::new().await
}
