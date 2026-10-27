use std::collections::VecDeque;
use std::fmt::Write;
use std::sync::Mutex;

use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::Layer;

use crate::frb_generated::StreamSink;

/// Lines kept for replay, so a late subscriber still sees startup logs.
const BACKLOG_LEN: usize = 200;

struct LogState {
    backlog: VecDeque<String>,
    sink: Option<StreamSink<String>>,
}

static LOGS: Mutex<LogState> = Mutex::new(LogState {
    backlog: VecDeque::new(),
    sink: None,
});

/// Installs the global tracing subscriber that forwards veilid logs to Dart.
pub fn init_log_forwarding() {
    let _ = tracing_subscriber::registry()
        .with(ForwardLayer.with_filter(LevelFilter::INFO))
        .try_init();
}

/// Registers the sink that receives new log lines, after replaying the backlog.
pub fn subscribe(sink: StreamSink<String>) {
    let mut logs = LOGS.lock().unwrap();
    for line in &logs.backlog {
        if sink.add(line.clone()).is_err() {
            return;
        }
    }
    logs.sink = Some(sink);
}

fn push_line(line: String) {
    let mut logs = LOGS.lock().unwrap();
    if logs.backlog.len() == BACKLOG_LEN {
        logs.backlog.pop_front();
    }
    logs.backlog.push_back(line.clone());
    // Drop the sink once Dart has stopped listening.
    if let Some(sink) = &logs.sink {
        if sink.add(line).is_err() {
            logs.sink = None;
        }
    }
}

struct ForwardLayer;

impl<S: Subscriber> Layer<S> for ForwardLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        let level = match *event.metadata().level() {
            Level::ERROR => "ERROR",
            Level::WARN => "WARN ",
            Level::INFO => "INFO ",
            Level::DEBUG => "DEBUG",
            Level::TRACE => "TRACE",
        };
        push_line(format!("{level} {}{}", visitor.message, visitor.fields));
    }
}

#[derive(Default)]
struct MessageVisitor {
    message: String,
    fields: String,
}

impl Visit for MessageVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let name = field.name();
        if name == "message" {
            let _ = write!(self.message, "{value:?}");
        } else if !name.starts_with("__") {
            // Skip veilid's internal "__VEILID_*" bookkeeping fields.
            let _ = write!(self.fields, " {name}={value:?}");
        }
    }
}
