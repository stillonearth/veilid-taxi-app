use std::path::PathBuf;

use anyhow::Result;
use tracing::{error, info};
use veilid_taxi::{
    app::P2PApp,
    driver::DriverRideRequest,
    pedestrian::{
        publish_request, respond_to_driver_ride_request, PedestianRideRequest, PedestrianDecision,
    },
    veilid::app_config,
};

use crate::frb_generated::StreamSink;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    crate::logs::init_log_forwarding();
}

/// Details of a published ride request, as plain data for the Dart side.
pub struct RideRequestInfo {
    pub request_key: String,
    pub route_id: String,
    pub board_key: String,
    pub slot: u16,
    pub lat: f64,
    pub lon: f64,
}

/// The pedestrian request a driver is answering, as plain data for the Dart side.
pub struct PedestrianRideRequestInfo {
    pub request_key: String,
    pub route_blob: Vec<u8>,
    pub cell: u64,
    pub expires_at: u64,
    pub max_price_cents: u32,
}

/// A driver's offer to take a published ride request.
pub struct DriverRideRequestInfo {
    pub pedestrian_ride_request: PedestrianRideRequestInfo,
    pub message: String,
    pub driver_route: Vec<u8>,
}

impl From<DriverRideRequest> for DriverRideRequestInfo {
    fn from(req: DriverRideRequest) -> Self {
        let ped = req.pedestrian_ride_request;
        Self {
            pedestrian_ride_request: PedestrianRideRequestInfo {
                request_key: ped.request_key,
                route_blob: ped.route_blob,
                cell: ped.cell,
                expires_at: ped.expires_at,
                max_price_cents: ped.max_price_cents,
            },
            message: req.message,
            driver_route: req.driver_route,
        }
    }
}

pub struct VP2PApp {
    p2p_app: P2PApp,
    subscribed: bool,
}

impl VP2PApp {
    pub async fn new() -> Result<Self> {
        let config = app_config("veilid-taxi-gui", Some(PathBuf::from("/home/cwiz")));
        let app = Self {
            p2p_app: P2PApp::new(config).await?,
            subscribed: false,
        };

        Ok(app)
    }

    /// Streams driver offers for our ride requests to Dart.
    ///
    /// Starts the veilid network loop (which decodes incoming app messages)
    /// and returns immediately, so the app stays usable for other calls.
    /// Only the first call has an effect.
    pub async fn subscribe_to_p2p_events(&mut self, sink: StreamSink<DriverRideRequestInfo>) {
        if self.subscribed {
            return;
        }
        self.subscribed = true;

        let mut app = self.p2p_app.clone();
        flutter_rust_bridge::spawn(async move {
            if let Err(e) = app.network_loop().await {
                error!("veilid network loop stopped: {e:?}");
            }
        });

        let on_driver_ride_request = self.p2p_app.app_state.on_driver_ride_request.clone();
        flutter_rust_bridge::spawn(async move {
            while let Ok(ride_request) = on_driver_ride_request.recv_async().await {
                println!("here 1");
                info!("driver offer received: {}", ride_request.message);

                let res = sink.add(ride_request.into());

                if res.is_err() {
                    println!("err: {:?}", res.err().unwrap());
                    break;
                }

                println!("here 2");
            }
        });
    }

    /// Sends the pedestrian's accept/decline decision back to the offering driver.
    pub async fn respond_to_driver_ride_request(
        &self,
        offer: DriverRideRequestInfo,
        accept: bool,
    ) -> Result<()> {
        let rc = self.p2p_app.veilid_api.routing_context()?;
        let request = offer.pedestrian_ride_request;
        let pedestrian_ride_request = PedestianRideRequest {
            request_key: request.request_key,
            route_blob: request.route_blob,
            cell: request.cell,
            expires_at: request.expires_at,
            max_price_cents: request.max_price_cents,
        };
        let decision = if accept {
            PedestrianDecision::Yes
        } else {
            PedestrianDecision::No
        };
        respond_to_driver_ride_request(&rc, offer.driver_route, pedestrian_ride_request, decision)
            .await?;
        Ok(())
    }

    pub async fn connect_to_network(&mut self) -> Result<()> {
        self.p2p_app.connect_to_network().await?;
        Ok(())
    }

    pub async fn request_ride(&mut self, lat: f64, lon: f64) -> Result<RideRequestInfo> {
        let rc = self.p2p_app.veilid_api.routing_context()?;
        let published = publish_request(&rc, lat, lon, 100).await?;
        Ok(RideRequestInfo {
            request_key: published.request_key.to_string(),
            route_id: published.route_id.to_string(),
            board_key: published.board_key.to_string(),
            slot: published.slot,
            lat,
            lon,
        })
    }
}

pub async fn initialize_app() -> Result<VP2PApp> {
    VP2PApp::new().await
}
