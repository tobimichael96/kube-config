# Dispatcharr

Dispatcharr's ffmpeg stream profiles live in its own database and are edited
through its web UI, not in this repository. The profile below is documented
here as a reference and a backup — it is not the source of truth, so update it
by hand when it changes in the UI.

The one part that _is_ source-controlled is the encoder-selection wrapper in
[`configmaps.yaml`](configmaps.yaml), mounted at `/scripts/ffmpeg-venc.sh`. The
profile invokes it instead of calling ffmpeg directly.

## Stream profile

Profile "ffmpeg alternative", the default for all channels
(`stream_settings.default_stream_profile`).

**Command** field:

```text
/bin/sh
```

**Parameters** field:

```text
/scripts/ffmpeg-venc.sh
-hide_banner -loglevel warning -stats -stats_period 10
-fflags +genpts+discardcorrupt
-reconnect 1 -reconnect_streamed 1
-reconnect_on_network_error 1 -reconnect_on_http_error 5xx,408
-reconnect_delay_max 30 -reconnect_max_retries 6 -rw_timeout 5000000
-i {streamUrl}
-map 0:v:0 -map 0:a:0 -sn -dn -ignore_unknown
@VENC@
-c:a aac -b:a 128k -ac 2 -ar 48000
-af aresample=async=1000:first_pts=0
-max_muxing_queue_size 2048
-f mpegts pipe:1
```

The copy-pasteable one-liner is in [Applying a profile
change](#applying-a-profile-change) below.

Dispatcharr builds the process as `[command] + shlex.split(parameters)` and
execs it without a shell (`core/models.py`, `StreamProfile.build_command`), so
`/bin/sh` is the command and the script path is simply the first argument. No
executable bit is needed on the mounted file, and `@VENC@` survives the split
as its own argument.

## Encoder selection

There are no `-c:v` flags in the profile. The wrapper substitutes the `@VENC@`
token with one of two encoder argument sets:

| Path | Arguments                                                                                                                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| GPU  | `-c:v h264_nvenc -preset p4 -tune hq -rc vbr -cq 21 -b:v 4M -maxrate 8M -bufsize 16M -g 50 -forced-idr 1 -profile:v high -pix_fmt yuv420p`       |
| CPU  | `-c:v libx264 -preset veryfast -crf 23 -maxrate 4M -bufsize 8M -g 50 -keyint_min 50 -sc_threshold 0 -profile:v high -pix_fmt yuv420p -threads 3` |

It picks between them by attempting a one-frame throwaway NVENC encode before
starting the real one. That probe costs about 0.5s on every channel start.

The reason is that the GPU is a single 6GB card shared with `immich-ml`,
`jellyfin` and `unmanic`, with no VRAM partitioning — whichever pod allocates
first wins. ffmpeg cannot fall back between encoders on its own, so without the
wrapper a full card meant `h264_nvenc` failed to open with
`CUDA_ERROR_OUT_OF_MEMORY` and Dispatcharr tore the channel down about three
seconds after the client connected, having exhausted its stream retries. A
software transcode at reduced bitrate is a much better outcome than a dead
channel.

The probe result is deliberately not cached. A cached "GPU is free" verdict that
had gone stale would reintroduce exactly the hard failure the wrapper exists to
prevent. Free VRAM as reported by `nvidia-smi` is not a usable substitute for
the probe either, since it does not account for the encoder context NVENC needs
on top of the frame buffers.

## Why these flags

The guiding principle: an earlier version of this profile minimised latency at
every stage, which left nothing to absorb jitter from the upstream provider. Any
hiccup propagated straight through to the client as a visible gap. The current
profile trades roughly one second of latency — irrelevant for live TV — for
tolerance.

| Flag                                               | Reason                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-profile:v high -pix_fmt yuv420p`                 | Without them the encoder inherits the input's format. A 4:4:4 or RGB upstream then yields `High 4:4:4 Predictive`, which no Android TV hardware decoder accepts — it fails as a black screen with working audio while desktop software players are fine, so it presents as a client bug rather than a profile one. Set on both encoder paths.                                                                                                                                                                                                                                                                                                                                                                                   |
| `-reconnect_on_http_error 5xx,408` (not `4xx,5xx`) | One of the upstream accounts permits only a single concurrent connection and answers a taken slot with HTTP 458. Retrying a connection-limit error cannot succeed while the retrying process is itself what holds the slot, so a blanket `4xx` deadlocked the channel: ffmpeg looped on 458 indefinitely, never failing, so Dispatcharr never marked the stream dead and never failed over. Only genuinely transient codes belong here.                                                                                                                                                                                                                                                                                         |
| `-rw_timeout 5000000`                              | Caps a stalled upstream read at 5s before the reconnect logic starts. At 15s the freeze was long enough to be obvious on screen.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| no `-reconnect_at_eof`                             | On EOF this flag reopens the URL instead of letting the input end. Providers rarely resume at the live edge: a rolling-buffer endpoint hands back the head of its buffer, so the channel replays 10-60s it has already shown, and a finite URL restarts from byte 0 and loops forever. `+genpts` then regenerates a continuous timestamp ramp over the seam, so the client gets no discontinuity to resync on and the repeat plays as smoothly as new material. A clean EOF on a live feed means that source is finished; letting ffmpeg exit is what lets Dispatcharr mark the stream dead and fail over. `-reconnect 1 -reconnect_streamed 1` still covers a dropped connection mid-stream, which is the case worth retrying. |
| `-reconnect_max_retries 6`                         | `-reconnect_delay_max` bounds the backoff but not the attempt count. An upstream that errors every few seconds would otherwise be retried indefinitely, so Dispatcharr never sees the stream die and never fails over -- the same deadlock as the HTTP 458 case above, reached through a different door.                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `+genpts`                                          | IPTV feeds routinely have gapped or missing PTS. Without it the mpegts muxer forwards the discontinuity and clients render it as a freeze.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `+discardcorrupt`                                  | Drops packets flagged corrupt. Cuts both ways: a dropped reference frame freezes the picture until the next IDR, about 2s at `-g 50` on a 25fps source. Removing it gives brief macroblock artifacts instead.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `aresample=async=1000`                             | `async=1` only fills and trims at stream start. A number is the maximum samples the filter may stretch or squeeze, which stops A/V drift accumulating over a long session and forcing a client resync.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `-tune hq` (not `ll`)                              | `ll` disables NVENC lookahead. `hq` rides out rate spikes instead of passing them through.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| no `-flags low_delay`                              | Decoder-side latency cut that also removes frame-reorder tolerance.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| no `-muxdelay 0 -muxpreload 0`                     | Leaves the mpegts muxer its ~0.7s cushion. This is the jitter shock absorber; zeroing it makes every upstream hiccup immediately visible.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `-stats -stats_period 10`                          | Throughput line every 10s. At a freeze this shows whether ffmpeg's speed dropped (upstream or encoder) or held steady (client-side or Dispatcharr buffering).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `-threads 3` (CPU path only)                       | Matches the container's 3000m CPU limit, so one software transcode cannot starve the Django workers sharing the container.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

`-mpegts_flags +resend_headers` is deliberately absent: the mpegts muxer's
`pat_period` already defaults to 0.1s, so PAT/PMT retransmission is frequent
enough. Verified against ffmpeg 8.1.2 in the running pod.

## Applying a profile change

The profile is stored in Dispatcharr's database, so editing this file changes
nothing by itself. To apply it:

1. Dispatcharr UI -> **Settings** -> **Stream Profiles** -> **ffmpeg
   alternative**.
2. Paste this into the **Parameters** field, replacing its entire contents:

   ```text
   /scripts/ffmpeg-venc.sh -hide_banner -loglevel warning -stats -stats_period 10 -fflags +genpts+discardcorrupt -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_on_http_error 5xx,408 -reconnect_delay_max 30 -reconnect_max_retries 6 -rw_timeout 5000000 -i {streamUrl} -map 0:v:0 -map 0:a:0 -sn -dn -ignore_unknown @VENC@ -c:a aac -b:a 128k -ac 2 -ar 48000 -af aresample=async=1000:first_pts=0 -max_muxing_queue_size 2048 -f mpegts pipe:1
   ```

   Leave **Command** as `/bin/sh`.

3. Save.

No pod restart is needed. `StreamProfile.build_command` runs when a channel
starts, so the new arguments apply to the next stream start; clients already
watching keep the ffmpeg process they were given until they reconnect.

To check what a running stream was actually launched with:

```sh
kubectl -n dispatcharr exec dispatcharr-0 -c app -- \
  bash -lc 'ps -eo args | grep -m1 "[f]fmpeg-venc"'
```

## Testing a profile change

`-reconnect*` are HTTP-protocol options and error out on a local file input, so
a realistic test needs an HTTP source. Serving a short clip over loopback inside
the pod exercises the full argument list without involving the provider:

```sh
kubectl -n dispatcharr exec dispatcharr-0 -c app -- bash -lc '
  cd /tmp
  ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=25 -f lavfi -i sine=frequency=440 \
    -pix_fmt yuv420p -t 4 -c:v libx264 -c:a aac -f mpegts -y in.ts
  python3 -m http.server 18099 --bind 127.0.0.1 & SRV=$!
  sleep 2
  /bin/sh /scripts/ffmpeg-venc.sh <parameters...> -i http://127.0.0.1:18099/in.ts \
    ... -t 4 -f mpegts pipe:1 > out.ts
  ffprobe -show_entries stream=codec_name,profile,pix_fmt -of default=noprint_wrappers=1 out.ts
  kill $SRV'
```

Bound the output with `-t`. Without `-reconnect_at_eof` the test clip's EOF
ends the run on its own, but `-t` keeps a run short if the loopback server
stalls rather than closing.
