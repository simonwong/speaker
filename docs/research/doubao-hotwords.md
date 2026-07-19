# Doubao Direct Hotword Contract

Last reviewed: 2026-07-20

This note records the current first-party contract for request-scoped hotwords on Doubao's streaming ASR WebSocket. It focuses on Speaker's `bigmodel_async` endpoint and separates documented behavior from implementation recommendations.

## Conclusion

- The current WebSocket schema places the field at `request.corpus.context`.
- `context` is a JSON **string**. After parsing that string, the direct-hotword value has a `hotwords` array whose elements are objects with a `word` string.
- The current limit for bidirectional streaming is **100 tokens**, not 200 tokens. The same row gives a separate **5,000-word** limit for `bigmodel_nostream`.
- The official page does not define a tokenizer, token-counting API, or local counting algorithm.
- The official page does not say that an over-limit direct-hotword list is automatically truncated. Its automatic truncation statement applies to `dialog_ctx` conversational context, not to the `hotwords` form.

The authoritative source for these statements is the current [streaming ASR WebSocket contract](https://www.volcengine.com/docs/6561/1354869?lang=zh), last updated there on 2026-06-26.

## Request shape

The WebSocket field table declares:

| Field | Schema level | Type | Meaning |
| --- | ---: | --- | --- |
| `request` | 1 | object | Request configuration |
| `corpus` | 2 | object | Corpus/intervention configuration |
| `context` | 3 | string | Direct hotwords or conversational context |

Therefore the documented full-request nesting is:

```json
{
  "request": {
    "corpus": {
      "context": "{\"hotwords\":[{\"word\":\"Speaker\"},{\"word\":\"Swift\"}]}"
    }
  }
}
```

Parsing the `context` string yields:

```json
{
  "hotwords": [
    { "word": "Speaker" },
    { "word": "Swift" }
  ]
}
```

This follows the `request` / `corpus` / `context` levels and the direct-hotword example in the [full client request field table](https://www.volcengine.com/docs/6561/1354869?lang=zh). The separate [official streaming SDK page](https://www.volcengine.com/docs/6561/1395846?lang=zh) independently shows the same inner string shape with `hotwords` and `{ "word": "deepseek" }`.

### Documentation inconsistency

The WebSocket page also contains an illustrative `dialog_ctx` request block whose braces and value type are inconsistent with its own field table: the example visually places `context` beside `corpus` and renders it like an object, while the table declares `context` as a level-3 string after the level-2 `corpus` field. That block is not a direct-hotword example.

For direct hotwords, the schema table plus the adjacent hotword string example are the clearest contract. The SDK example confirms only the inner serialized value; it is a different SDK parameter surface and does not override the WebSocket field nesting.

## Capacity

The current WebSocket `context` row distinguishes the two streaming modes:

- bidirectional streaming: 100 tokens;
- `bigmodel_nostream`: 5,000 words.

The same page identifies `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` as the optimized bidirectional-streaming endpoint. Speaker therefore falls under the 100-token statement. A 200-token limit is not present in the current [WebSocket contract](https://www.volcengine.com/docs/6561/1354869?lang=zh).

The [official product update log](https://www.volcengine.com/docs/6561/162929?lang=zh) says that hotword input and context were expanded to 5,000 words in June 2025, but does not qualify that release-note sentence by endpoint. The newer endpoint-specific WebSocket table does qualify it: 100 tokens for bidirectional streaming and 5,000 words for `nostream`. The endpoint-specific table should govern this integration.

The separate [managed hotword-table guide](https://www.volcengine.com/docs/6561/155739?lang=zh) allows 5,000 entries per uploaded table and limits each managed-table entry to fewer than ten characters. Those are rules for an uploaded table referenced by `boosting_table_id` or `boosting_table_name`; the guide does not state that they are the capacity rules for request-scoped `context.hotwords`.

## Overflow and token counting

### Documented facts

The WebSocket page documents automatic truncation only for conversational `dialog_ctx`: it allows 800 tokens and 20 turns, and on overflow keeps newer conversation entries by truncating in time order. That statement is followed by ordering rules for `context_data`.

The direct-hotword paragraph gives the hotword capacity and example, but no overflow behavior. It does not promise that the server truncates excess hotwords, identify which hotwords would survive, or specify an error response for this case. Consequently, "hotwords above the limit are automatically truncated" is not an official contract supported by the reviewed sources.

The reviewed WebSocket contract, streaming SDK page, and hotword guide do not identify the ASR tokenizer, publish a compatible tokenizer, define how a term maps to tokens, or expose a token-count endpoint. Counting Swift `String` characters, Unicode scalars, bytes, or array entries is therefore not a documented substitute for the provider's token count.

### Safe client policy (recommendation, not provider fact)

1. Do not label a local character or entry count as an exact Doubao token count.
2. Preserve deterministic user priority/order and send no more than 100 non-empty, unique hotword entries. Record later entries as locally omitted. This is a conservative entry guard, not proof that the serialized list is at most 100 provider tokens: one hotword may tokenize to multiple tokens.
3. Do not rely on undocumented server truncation. Surface and classify a provider invalid-request response rather than claiming that all submitted words were accepted.
4. If strict token-limit compliance is required, obtain a provider-supplied tokenizer/counting rule or a written contract clarification. No such mechanism is documented in the reviewed public sources.

Using 5,000 as Speaker's `bigmodel_async` request capacity would apply the `nostream` or managed-table contract to the wrong surface. Using 200 would encode an outdated or unsupported premise. A 100-entry guard is the safest implementable bound available from the public contract, but its limitation should remain explicit in code and diagnostics.

## Repository gap at review time

At the time of this review:

- `DoubaoStreamingASRClient` encoded `context` directly under `request` and built a `dialog_ctx` / `context_data` value from dictionary hotwords;
- the official direct-hotword contract calls for a serialized `hotwords` array with `{ "word": ... }` entries at `request.corpus.context`;
- `DictionaryProviderCapacity.doubao` allowed 5,000 entries, matching the wrong mode/surface for Speaker's bidirectional endpoint.

These are implementation gaps, not evidence that the provider accepts the current form.

## Primary sources

- [Streaming ASR WebSocket contract](https://www.volcengine.com/docs/6561/1354869?lang=zh)
- [Streaming ASR SDK request-parameter example](https://www.volcengine.com/docs/6561/1395846?lang=zh)
- [Doubao Voice product update log](https://www.volcengine.com/docs/6561/162929?lang=zh)
- [Managed hotword-table guide](https://www.volcengine.com/docs/6561/155739?lang=zh)
