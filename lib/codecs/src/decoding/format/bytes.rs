use std::sync::LazyLock;

use bytes::Bytes;
use lookup::OwnedTargetPath;
use lookup::lookup_v2::OwnedSegment;
use serde::{Deserialize, Serialize};
use smallvec::{SmallVec, smallvec};
use vector_core::{
    config::{DataType, LogNamespace, log_schema},
    event::{Event, EventMetadata, KeyString, LogEvent, ObjectMap, Value},
    schema,
    schema::meaning,
};
use vrl::value::Kind;

use super::Deserializer;

/// Cached message key extracted from `log_schema()` for direct BTreeMap construction.
/// Avoids per-event path traversal and `Arc::make_mut` overhead in the Legacy namespace
/// deserialization path.
static LEGACY_MESSAGE_KEY: LazyLock<Option<KeyString>> = LazyLock::new(|| {
    log_schema()
        .message_key()
        .and_then(|path| match path.segments.first() {
            Some(OwnedSegment::Field(key)) => Some(key.clone()),
            _ => None,
        })
});

/// Config used to build a `BytesDeserializer`.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct BytesDeserializerConfig;

impl BytesDeserializerConfig {
    /// Creates a new `BytesDeserializerConfig`.
    pub const fn new() -> Self {
        Self
    }

    /// Build the `BytesDeserializer` from this configuration.
    pub fn build(&self) -> BytesDeserializer {
        BytesDeserializer
    }

    /// Return the type of event build by this deserializer.
    pub fn output_type(&self) -> DataType {
        DataType::Log
    }

    /// The schema produced by the deserializer.
    pub fn schema_definition(&self, log_namespace: LogNamespace) -> schema::Definition {
        match log_namespace {
            LogNamespace::Legacy => {
                let definition = schema::Definition::empty_legacy_namespace();
                if let Some(message_key) = log_schema().message_key() {
                    return definition.with_event_field(
                        message_key,
                        Kind::bytes(),
                        Some(meaning::MESSAGE),
                    );
                }
                definition
            }
            LogNamespace::Vector => {
                schema::Definition::new_with_default_metadata(Kind::bytes(), [log_namespace])
                    .with_meaning(OwnedTargetPath::event_root(), "message")
            }
        }
    }
}

/// Deserializer that converts bytes to an `Event`.
///
/// This deserializer can be considered as the no-op action for input where no
/// further decoding has been specified.
#[derive(Debug, Clone)]
pub struct BytesDeserializer;

impl BytesDeserializer {
    /// Deserializes the given bytes, which will always produce a single `LogEvent`.
    pub fn parse_single(&self, bytes: Bytes, log_namespace: LogNamespace) -> LogEvent {
        match log_namespace {
            LogNamespace::Vector => log_namespace.new_log_from_data(bytes),
            LogNamespace::Legacy => {
                // Construct the BTreeMap directly instead of going through
                // LogEvent::default() + value_mut() + insert(). This avoids:
                //   1. Arc::make_mut clone of the shared DEFAULT_INNER
                //   2. Path traversal overhead in Value::insert
                //   3. Size cache invalidation
                let mut map = ObjectMap::new();
                if let Some(key) = LEGACY_MESSAGE_KEY.as_ref() {
                    map.insert(key.clone(), Value::Bytes(bytes));
                }
                LogEvent::from_map(map, EventMetadata::default())
            }
        }
    }
}

impl Deserializer for BytesDeserializer {
    fn parse(
        &self,
        bytes: Bytes,
        log_namespace: LogNamespace,
    ) -> vector_common::Result<SmallVec<[Event; 1]>> {
        let log = self.parse_single(bytes, log_namespace);
        Ok(smallvec![log.into()])
    }
}

#[cfg(test)]
mod tests {
    use vrl::value::Value;

    use super::*;

    #[test]
    fn deserialize_bytes_legacy_namespace() {
        let input = Bytes::from("foo");
        let deserializer = BytesDeserializer;

        let events = deserializer.parse(input, LogNamespace::Legacy).unwrap();
        let mut events = events.into_iter();

        {
            let event = events.next().unwrap();
            let log = event.as_log();
            assert_eq!(*log.get_message().unwrap(), "foo".into());
        }

        assert_eq!(events.next(), None);
    }

    #[test]
    fn deserialize_bytes_vector_namespace() {
        let input = Bytes::from("foo");
        let deserializer = BytesDeserializer;

        let events = deserializer.parse(input, LogNamespace::Vector).unwrap();
        assert_eq!(events.len(), 1);

        assert_eq!(events[0].as_log().get(".").unwrap(), &Value::from("foo"));
    }
}
