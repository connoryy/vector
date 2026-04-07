use std::{collections::HashMap, future::ready, num::NonZeroUsize, pin::Pin};

use bytes::Bytes;
use futures::{Stream, StreamExt};
use lru::LruCache;
use vector_lib::lookup::lookup_v2::ConfigTargetPath;
use vrl::path::OwnedTargetPath;
use vrl::value::KeyString;

use super::common::FieldMatchConfig;
use crate::{
    event::{Event, Value},
    internal_events::DedupeEventsDropped,
    transforms::TaskTransform,
};

/// Cache for parsed field paths to avoid re-parsing on every event.
/// Maps field name → parsed ConfigTargetPath (None if parsing failed).
pub(crate) type PathCache = HashMap<KeyString, Option<ConfigTargetPath>>;

#[derive(Clone)]
pub struct Dedupe {
    fields: FieldMatchConfig,
    cache: LruCache<CacheEntry, bool>,
    path_cache: PathCache,
}

type TypeId = u8;

/// A CacheEntry comes in two forms, depending on the FieldMatchConfig in use.
///
/// When matching fields, a CacheEntry contains a vector of optional 2-tuples.
/// Each element in the vector represents one field in the corresponding
/// LogEvent. Elements in the vector will correspond 1:1 (and in order) to the
/// fields specified in "fields.match". The tuples each store the TypeId for
/// this field and the data as Bytes for the field. There is no need to store
/// the field name because the elements of the vector correspond 1:1 to
/// "fields.match", so there is never any ambiguity about what field is being
/// referred to. If a field from "fields.match" does not show up in an incoming
/// Event, the CacheEntry will have None in the correspond location in the
/// vector.
///
/// When ignoring fields, a CacheEntry contains a vector of 3-tuples. Each
/// element in the vector represents one field in the corresponding LogEvent.
/// The tuples will each contain the field name, TypeId, and data as Bytes for
/// the corresponding field (in that order). Since the set of fields that might
/// go into CacheEntries is not known at startup, we must store the field names
/// as part of CacheEntries. Since Event objects store their field in alphabetic
/// order (as they are backed by a BTreeMap), and we build CacheEntries by
/// iterating over the fields of the incoming Events, we know that the
/// CacheEntries for 2 equivalent events will always contain the fields in the
/// same order.
#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) enum CacheEntry {
    Match(Vec<Option<(TypeId, Bytes)>>),
    Ignore(Vec<(OwnedTargetPath, TypeId, Bytes)>),
}

/// Assigns a unique number to each of the types supported by Event::Value.
const fn type_id_for_value(val: &Value) -> TypeId {
    match val {
        Value::Bytes(_) => 0,
        Value::Timestamp(_) => 1,
        Value::Integer(_) => 2,
        Value::Float(_) => 3,
        Value::Boolean(_) => 4,
        Value::Object(_) => 5,
        Value::Array(_) => 6,
        Value::Null => 7,
        Value::Regex(_) => 8,
    }
}

impl Dedupe {
    pub fn new(num_entries: NonZeroUsize, fields: FieldMatchConfig) -> Self {
        Self {
            fields,
            cache: LruCache::new(num_entries),
            path_cache: PathCache::new(),
        }
    }

    pub fn transform_one(&mut self, event: Event) -> Option<Event> {
        let cache_entry = build_cache_entry(&event, &self.fields, &mut self.path_cache);
        if self.cache.put(cache_entry, true).is_some() {
            emit!(DedupeEventsDropped { count: 1 });
            None
        } else {
            Some(event)
        }
    }
}

/// Takes in an Event and returns a CacheEntry to place into the LRU cache
/// containing all relevant information for the fields that need matching
/// against according to the specified FieldMatchConfig.
///
/// The `path_cache` caches parsed `ConfigTargetPath` results for field names,
/// avoiding expensive VRL path re-parsing on every event in the IgnoreFields path.
pub(crate) fn build_cache_entry(
    event: &Event,
    fields: &FieldMatchConfig,
    path_cache: &mut PathCache,
) -> CacheEntry {
    match &fields {
        FieldMatchConfig::MatchFields(fields) => {
            let mut entry = Vec::with_capacity(fields.len());
            for field_name in fields.iter() {
                if let Some(value) = event.as_log().get(field_name) {
                    entry.push(Some((type_id_for_value(value), value.coerce_to_bytes())));
                } else {
                    entry.push(None);
                }
            }
            CacheEntry::Match(entry)
        }
        FieldMatchConfig::IgnoreFields(fields) => {
            let mut entry = Vec::new();

            if let Some(event_fields) = event.as_log().all_event_fields()
                && let Some(metadata_fields) = event.as_log().all_metadata_fields()
            {
                for (field_name, value) in event_fields.chain(metadata_fields) {
                    // Cache parsed ConfigTargetPath to avoid VRL path re-parsing on every event.
                    // On cache hit (common case after first event): single HashMap lookup.
                    // On cache miss (first event only): one clone + parse + insert.
                    let cached_path = match path_cache.get(field_name.as_str()) {
                        Some(v) => v.as_ref(),
                        None => {
                            let parsed = ConfigTargetPath::try_from(field_name.clone()).ok();
                            let key = field_name;
                            path_cache.entry(key).or_insert(parsed).as_ref()
                        }
                    };
                    if let Some(path) = cached_path
                        && !fields.contains(path)
                    {
                        entry.push((
                            path.0.clone(),
                            type_id_for_value(value),
                            value.coerce_to_bytes(),
                        ));
                    }
                }
            }

            CacheEntry::Ignore(entry)
        }
    }
}

impl TaskTransform<Event> for Dedupe {
    fn transform(
        self: Box<Self>,
        task: Pin<Box<dyn Stream<Item = Event> + Send>>,
    ) -> Pin<Box<dyn Stream<Item = Event> + Send>>
    where
        Self: 'static,
    {
        let mut inner = self;
        Box::pin(task.filter_map(move |v| ready(inner.transform_one(v))))
    }
}
