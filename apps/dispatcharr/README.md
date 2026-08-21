# Dispatcharr

Dispatcharr's ffmpeg stream profiles live in its own database and are edited
through its web UI, not in this repo. The profile below is documented here as a
reference and a backup — it is not the source of truth, so update it by hand
when it changes in the UI.

## Stream profile

```
-hide_banner -loglevel warning -stats -stats_period 10
-fflags +genpts+discardcorrupt
-reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1
-reconnect_on_network_error 1 -reconnect_on_http_error 4xx,5xx
-reconnect_delay_max 30 -rw_timeout 5000000
-i {streamUrl}
-map 0:v:0 -map 0:a:0 -sn -dn -ignore_unknown
-c:v h264_nvenc -preset p4 -tune hq -rc vbr -cq 21 -b:v 4M -maxrate 8M -bufsize 16M
-g 50 -forced-idr 1
-c:a aac -b:a 128k -ac 2 -ar 48000
-af aresample=async=1000:first_pts=0
-max_muxing_queue_size 2048
-f mpegts pipe:1
```

Single line, for pasting into the UI:

```
-hide_banner -loglevel warning -stats -stats_period 10 -fflags +genpts+discardcorrupt -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_on_network_error 1 -reconnect_on_http_error 4xx,5xx -reconnect_delay_max 30 -rw_timeout 5000000 -i {streamUrl} -map 0:v:0 -map 0:a:0 -sn -dn -ignore_unknown -c:v h264_nvenc -preset p4 -tune hq -rc vbr -cq 21 -b:v 4M -maxrate 8M -bufsize 16M -g 50 -forced-idr 1 -c:a aac -b:a 128k -ac 2 -ar 48000 -af aresample=async=1000:first_pts=0 -max_muxing_queue_size 2048 -f mpegts pipe:1
```

## Why these flags

The guiding principle: an earlier version of this profile minimised latency at
every stage, which left nothing to absorb jitter from the upstream provider. Any
hiccup propagated straight through to the client as a visible gap. The current
profile trades roughly one second of latency — irrelevant for live TV — for
tolerance.

| Flag | Reason |
| --- | --- |
| `-rw_timeout 5000000` | Caps a stalled upstream read at 5s before the reconnect logic starts. At 15s the freeze was long enough to be obvious on screen. |
| `+genpts` | IPTV feeds routinely have gapped or missing PTS. Without it the mpegts muxer forwards the discontinuity and clients render it as a freeze. |
| `+discardcorrupt` | Drops packets flagged corrupt. Cuts both ways: a dropped reference frame freezes the picture until the next IDR, about 2s at `-g 50` on a 25fps source. Removing it gives brief macroblock artifacts instead. |
| `aresample=async=1000` | `async=1` only fills and trims at stream start. A number is the maximum samples the filter may stretch or squeeze, which stops A/V drift accumulating over a long session and forcing a client resync. |
| `-tune hq` (not `ll`) | `ll` disables NVENC lookahead. `hq` rides out rate spikes instead of passing them through. |
| no `-flags low_delay` | Decoder-side latency cut that also removes frame-reorder tolerance. |
| no `-muxdelay 0 -muxpreload 0` | Leaves the mpegts muxer its ~0.7s cushion. This is the jitter shock absorber; zeroing it makes every upstream hiccup immediately visible. |
| `-stats -stats_period 10` | Throughput line every 10s. At a freeze this shows whether ffmpeg's speed dropped (upstream or encoder) or held steady (client side or Dispatcharr buffering). |

`-mpegts_flags +resend_headers` is deliberately absent: the mpegts muxer's
`pat_period` already defaults to 0.1s, so PAT/PMT retransmission is frequent
enough. Verified against ffmpeg 8.1.2 in the running pod.
