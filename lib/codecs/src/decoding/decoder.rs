use bytes::{Bytes, BytesMut};
use smallvec::SmallVec;
use vector_common::internal_event::emit;
use vector_core::{config::LogNamespace, event::Event};

use crate::{
    decoding::format::Deserializer as _,
    decoding::{
        BoxedFramingError, BytesDeserializer, Deserializer, Error, Framer, NewlineDelimitedDecoder,
    },
    internal_events::{DecoderDeserializeError, DecoderFramingError},
};

type DecodedFrame = (SmallVec<[Event; 1]>, usize);

/// A decoder that can decode structured events from a byte stream / byte
/// messages.
#[derive(Clone)]
pub struct Decoder {
    /// The framer being used.
    pub framer: Framer,
    /// The deserializer being used.
    pub deserializer: Deserializer,
    /// The `log_namespace` being used.
    pub log_namespace: LogNamespace,
}

impl Default for Decoder {
    fn default() -> Self {
        Self {
            framer: Framer::NewlineDelimited(NewlineDelimitedDecoder::new()),
            deserializer: Deserializer::Bytes(BytesDeserializer),
            log_namespace: LogNamespace::Legacy,
        }
    }
}

impl Decoder {
    /// Creates a new `Decoder` with the specified `Framer` to produce byte
    /// frames from the byte stream / byte messages and `Deserializer` to parse
    /// structured events from a byte frame.
    pub const fn new(framer: Framer, deserializer: Deserializer) -> Self {
        Self {
            framer,
            deserializer,
            log_namespace: LogNamespace::Legacy,
        }
    }

    /// Sets the log namespace that will be used when decoding.
    pub const fn with_log_namespace(mut self, log_namespace: LogNamespace) -> Self {
        self.log_namespace = log_namespace;
        self
    }

    /// Handles the framing result and parses it into a structured event, if
    /// possible.
    ///
    /// Emits logs if either framing or parsing failed.
    fn handle_framing_result(
        &mut self,
        frame: Result<Option<Bytes>, BoxedFramingError>,
    ) -> Result<Option<DecodedFrame>, Error> {
        let frame = frame.map_err(|error| {
            emit(DecoderFramingError { error: &error });
            Error::FramingError(error)
        })?;

        frame
            .map(|frame| self.deserializer_parse(frame))
            .transpose()
    }

    /// Parses a frame using the included deserializer, and handles any errors by logging.
    pub fn deserializer_parse(&self, frame: Bytes) -> Result<DecodedFrame, Error> {
        let byte_size = frame.len();

        // Parse structured events from the byte frame.
        self.deserializer
            .parse(frame, self.log_namespace)
            .map(|events| (events, byte_size))
            .map_err(|error| {
                emit(DecoderDeserializeError { error: &error });
                Error::ParsingError(error)
            })
    }

    /// Decode all frames from the buffer, calling `f` for each decoded frame.
    ///
    /// For supported framers (character-delimited, newline-delimited), this
    /// uses streaming decode with `memchr_iter` for better throughput. Frames
    /// are passed directly to the deserializer without intermediate collection,
    /// keeping memory usage O(1) instead of O(N) where N is the frame count.
    /// Falls back to the standard `decode_eof` loop for other framers.
    ///
    /// Processing events via callback (instead of collecting into a Vec)
    /// preserves the memory access pattern of the per-frame decode loop:
    /// each event is created, passed to `f`, and dropped before the next
    /// event is created, keeping the working set in L1/L2 cache.
    pub fn decode_all<F>(&mut self, buf: &mut BytesMut, mut f: F) -> Result<(), Error>
    where
        F: FnMut(DecodedFrame),
    {
        // Split borrows: framer needs &mut, deserializer_parse needs &self fields.
        // Extract references to avoid conflicting borrows.
        let deserializer = &self.deserializer;
        let log_namespace = self.log_namespace;
        let mut err: Option<Error> = None;

        let handled = self.framer.for_each_frame(buf, |frame| {
            if err.is_some() {
                return;
            }
            let byte_size = frame.len();
            match deserializer
                .parse(frame, log_namespace)
                .map(|events| (events, byte_size))
            {
                Ok(decoded) => f(decoded),
                Err(error) => {
                    emit(DecoderDeserializeError { error: &error });
                    err = Some(Error::ParsingError(error));
                }
            }
        });

        if let Some(e) = err {
            return Err(e);
        }

        if !handled {
            // Fallback: standard decode_eof loop
            while let Some(d) = <Self as tokio_util::codec::Decoder>::decode_eof(self, buf)? {
                f(d);
            }
        }
        Ok(())
    }
}

impl tokio_util::codec::Decoder for Decoder {
    type Item = DecodedFrame;
    type Error = Error;

    fn decode(&mut self, buf: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        let frame = self.framer.decode(buf);
        self.handle_framing_result(frame)
    }

    fn decode_eof(&mut self, buf: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        let frame = self.framer.decode_eof(buf);
        self.handle_framing_result(frame)
    }
}

#[cfg(test)]
mod tests {
    use bytes::Bytes;
    use futures::{StreamExt, stream};
    use tokio_util::io::StreamReader;
    use vrl::value::Value;

    use super::Decoder;
    use crate::{
        DecoderFramedRead, JsonDeserializer, NewlineDelimitedDecoder, StreamDecodingError,
        decoding::{Deserializer, Framer},
    };

    #[tokio::test]
    async fn framed_read_recover_from_error() {
        let iter = stream::iter(
            ["{ \"foo\": 1 }\n", "invalid\n", "{ \"bar\": 2 }\n"]
                .into_iter()
                .map(Bytes::from),
        );
        let stream = iter.map(Ok::<_, std::io::Error>);
        let reader = StreamReader::new(stream);
        let decoder = Decoder::new(
            Framer::NewlineDelimited(NewlineDelimitedDecoder::new()),
            Deserializer::Json(JsonDeserializer::default()),
        );
        let mut stream = DecoderFramedRead::new(reader, decoder);

        let next = stream.next().await.unwrap();
        let event = next.unwrap().0.pop().unwrap().into_log();
        assert_eq!(event.get("foo").unwrap(), &Value::from(1));

        let next = stream.next().await.unwrap();
        let error = next.unwrap_err();
        assert!(error.can_continue());

        let next = stream.next().await.unwrap();
        let event = next.unwrap().0.pop().unwrap().into_log();
        assert_eq!(event.get("bar").unwrap(), &Value::from(2));
    }
}
