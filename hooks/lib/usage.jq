# Aggregate per-message usage from a session transcript.
#
# Claude Code writes one transcript row per CONTENT BLOCK, and every row of a
# message repeats that message's usage. Summing rows naively overcounts by 3-6x.
#
# Within one message.id the input-side fields are identical, but output_tokens
# GROWS across blocks (observed: 3, 3, 342) - the last block carries the true
# total. So: take input-side from any row, and the MAX of output_tokens.
# Taking .[0] for output undercounts by ~60x.
#
# group_by sorts by message.id, which is random, so it does NOT preserve
# chronology. We carry the original row index through and re-sort by it:
# final_output_tokens must be the LAST message's output, and that is the
# summary the parent actually pays to ingest.
map(select(.message.usage != null))
| to_entries | map(.value + {_i: .key})
| group_by(.message.id)
| map({
    _last:          (map(._i) | max),
    model:          (.[0].message.model // null),
    input:          (.[0].message.usage.input_tokens // 0),
    cache_creation: (.[0].message.usage.cache_creation_input_tokens // 0),
    cache_read:     (.[0].message.usage.cache_read_input_tokens // 0),
    output:         (map(.message.usage.output_tokens // 0) | max)
  })
| sort_by(._last)
| { requests:       length,
    model:          (map(.model) | map(select(. != null)) | last),
    input_tokens:                (map(.input)          | add // 0),
    cache_creation_input_tokens: (map(.cache_creation) | add // 0),
    cache_read_input_tokens:     (map(.cache_read)     | add // 0),
    output_tokens:               (map(.output)         | add // 0),
    final_output_tokens:         (if length == 0 then 0 else .[-1].output end) }
