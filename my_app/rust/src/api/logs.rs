use crate::frb_generated::StreamSink;

/// Streams veilid log lines to Dart, starting with the buffered backlog.
pub fn veilid_log_stream(sink: StreamSink<String>) {
    crate::logs::subscribe(sink);
}
