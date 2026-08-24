# liquidsoap 2.4.5 win64 — unbounded private commit in 266,240-byte blocks

Status: **unresolved.** Fingerprint is precise. 24 hypotheses eliminated against controls. Root
cause not found.

Every number below was measured on this machine. Anything inferred rather than measured is marked
**[inference]**. Anything not independently verified is marked **[unverified]**. See §12 on why that
distinction is laboured.

---

## 1. Environment

```
host        Windows 11 Home, build 22631
            Intel i7-8750H, 16,243 MB RAM
            commit limit 32,486 MB (system-managed pagefile; was 39,739 MB when the
            process held 16 GB — the pagefile grows and shrinks with it)
liquidsoap  2.4.5 win64, prebuilt, single statically-linked binary
            113,412 KB, file date 2026-06-17
            ffmpeg is compiled in; the running process loads no non-system DLL
            (Process.Modules: 1 non-system module, the exe itself)
service     liquidsoap's own --run-service, running as a dedicated local account
```

Script: one file, **3,060 lines**. Exact counts, grepped from the source excluding comment lines:

```
harbor.http.register     23        all on port 8005
interactive.float        11        /control/knobs exposes 13 values, so 2 are not interactive.float
interactive.harbor        1        port 8005
input.harbor              1        port 8005, live source
output.harbor             1        port 8005, second mp3 mount
output.icecast            1        -> icecast 2.4.4 on 127.0.0.1:8000
thread.run                3        every 0.25 s, every 5.0 s, and one one-shot
```

```
playlist(mode="randomize", reload_mode="watch") over a 2,374-file directory
%ffmpeg(format="mp3", %audio(codec="libmp3lame", b="128k", ar=44100, ac=2))
settings.frame.duration = 0.02 (build default, not overridden)
telnet server on 127.0.0.1:1234
```

A reverse proxy sits in front. Only `/control/*`, `/likes/*`, `/earlier`, `/tug/*` are proxied to
the harbor; everything else caddy serves itself and never touches liquidsoap.

---

## 2. Symptom

Private bytes climb from process start and never fall. Only remedy found: restart.

Worst observed, before anything was touched:

```
uptime           75.1 h
private bytes    15,974 MB      machine has 16,243 MB RAM
working set         608 MB      <- almost all paged out, not resident
commit charge    35.3 GB of a 39.7 GB limit
```

The working set stays small throughout. This is committed, largely untouched memory: it costs
commit charge and pagefile, not RAM. The machine stays responsive until commit is exhausted.

### 2.1 Rates vary by an order of magnitude — read before comparing anything

```
quiet, no operator activity           3.31 MB/min     5-min window
                                      1.75 MB/min     6-min window, reverse proxy stopped
lifetime average @ 8.7 h uptime       4.73 MB/min
lifetime average @ 9.2 h uptime       4.63 MB/min
during active probing (repeated
restarts, HTTP bursts, telnet)       26 - 52 MB/min
```

Incoming request rate varies by ~20x on the same day:

```
measured 2026-08-23 afternoon          4.0 /min      8 requests in 120 s
measured 2026-08-24, same window        4.0 /min      8 requests in 120 s
inferred during retest arm A          ~86 /min      [inference] 650,843 log bytes / 1,255 B per line
```

The original observation (15,974 MB over 75.1 h = **3.55 MB/min**) agrees with the quiet regime.
A 26-52 MB/min figure is an artifact of measuring while probing the process.

---

## 3. Allocation fingerprint

`VirtualQueryEx` walk of the process address space. **Snapshot 1**, private = 1,710 MB:

```
committed, by type
  private   1,710 MB   in 12,818 regions     MEM_PRIVATE
  mapped        4 MB   in     22 regions
  image       163 MB   in    901 regions     the exe
  reserved  5,494 MB                          not committed

private commits, every bucket (2^k bytes), verbatim
       4 KB ..    8 KB     6,310 regions      24.6 MB
       8 KB ..   16 KB        73 regions       0.7 MB
      16 KB ..   32 KB         2 regions       0.0 MB
      32 KB ..   64 KB         4 regions       0.2 MB
      64 KB ..  128 KB        13 regions       1.0 MB
     128 KB ..  256 KB       102 regions      23.9 MB
     256 KB ..  512 KB     6,298 regions   1,600.6 MB    <- 93.6% of private commit
     512 KB ..    1 MB         7 regions       5.0 MB
       1 MB ..    2 MB         4 regions       5.2 MB
       2 MB ..    4 MB         2 regions       4.0 MB
       4 MB ..    8 MB         2 regions       9.4 MB
      32 MB ..   64 MB         1 region       35.6 MB

ten largest private regions:  35.58, 5.35, 4.00, 2.01, 2.00, 1.48, 1.41, 1.17, 1.10, 1.00 MB
```

**Snapshot 2**, a few minutes later, private 1,771 -> 1,808 MB, restricted to the 256-512 KB band:

```
  t=0     6,381 regions in band
  t=90s   6,517 regions in band

  new regions   136 in 90 s   = 90.7 /min   = 24.32 MB/min  (active regime)
  per region    275 KB

  exact sizes within the band at t=90s
    266,240 bytes  x 6,487        PAGE_READWRITE, MEM_PRIVATE, MEM_COMMIT
    274,432 bytes  x 8
    286,720 bytes  x 3
    299,008 bytes  x 3
    282,624 bytes  x 2
    307,200 bytes  x 2
  page protection: PAGE_READWRITE on all 6,517
```

Other rate samples of the same band:

```
  148.0 new regions/min    38.80 MB/min    (active regime, 2.5-min window)
  105.7 new regions/min    27.70 MB/min    (active regime, 3-min window)
  ~104  new regions/min                    (steady, 16 x 15-s buckets: 22-31 per bucket,
                                            no bursts, no track changes in the window)
```

Two things this rules out directly:

- **Not thread stacks.** Reserved memory grew ~70 KB per new block; a 1 MB-reserved stack would
  show ~1,024 KB. `Threads.Count` measured 40-42 across all growth.
- **Not handles.** `HandleCount` measured 315-331 across the same growth.

---

## 4. Block contents

Three whole blocks read from the live process with `ReadProcessMemory` — earliest allocated,
middle, newest.

```
non-zero content
  first  block   28.16%    one contiguous run of 266,227 bytes
  middle block    1.22%    104 separate runs
  last   block    1.44%    104 separate runs

non-zero run offsets in the two sparse blocks
  middle:  8, 3144, 5168, 8280, 10304, 13416, ...   (104 runs, lengths 73-453)
  last:   24, 3160, 5184, 8296, 10320, 13432, ...   (104 runs)

  stride 5,120.   52 slots x 5,120 = 266,240 bytes exactly.
```

Slot 0 of the "last" block, verbatim:

```
  +  0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
  + 16  00 00 00 00 00 00 00 00  02 22 d0 db a3 61 f5 10
  + 32  b0 14 13 e4 ec 01 00 00  10 a0 43 e6 ec 01 00 00
  + 48  12 01 e0 0f c0 d0 e0 f0  be 4c 24 aa 00 00 00 00
  + 64  33 00 00 00 00 00 00 00  50 90 36 ff ec 01 00 00
```

Slot 0 of the "middle" block, same offsets:

```
  + 32  90 60 e7 fd ec 01 00 00  10 00 3e fe ec 01 00 00
  + 48  12 01 f0 0f c0 d0 e0 f0  8e bc cd f1 a3 61 4f 00
  + 64  33 00 00 00 00 00 00 00  40 60 df a4 ec 01 00 00
```

Observations, measured:

- The 8 bytes at +48 are `12 01 ?? 0f c0 d0 e0 f0` in every block sampled. **The third byte
  differs** (`e0` vs `f0`); the other seven are identical. Two further blocks sampled in an earlier
  pass also carried `12 01 f0 0f c0 d0 e0 f0`.
- The 8 bytes at +64 are `33 00 00 00 00 00 00 00` = **51** in every block sampled.
- Values whose high dword is `0x000001EC` (the heap's address range this run) occur 58 times per
  block.
- Slots 1 and 2 are entirely zero except one small integer (`04`, `0a`) at a single offset.
- Bytes used per slot across 52 slots: min 849, median 3,821, max 5,115 (middle block);
  min 865, median 3,901, max 5,115 (last block).
- Slots byte-identical to slot 0 in their first 64 bytes: **0 of 51**.

No audio:

```
  mp3 frame syncs (FF Ex)   6 to 58 per 266,240 bytes
                            a real mp3 buffer of this size would hold hundreds
  printable text runs >= 5  none in middle; one 5-char run in an earlier sample
  PCM                       no dense or smoothly-varying regions
```

### 4.1 Reading — **[inference]**

52 fixed-size slots of 5,120 bytes, a near-constant encoded 8-byte field, and a block count of 51
match the Windows Low-Fragmentation Heap subsegment layout for a ~5 KB size class.

If that reading is right: **the 266,240-byte region is not the leaked object — it is a rack of 52
buckets for one.** The LFH holds an entire subsegment committed while any of its slots is busy, so
committed bytes would be amplified by up to 52x over the leaked payload. At the quiet 1.75 MB/min
baseline that would put actual leaked data somewhere around 0.03-1.75 MB/min.

This has **not** been confirmed — no symbols, no heap walker. It is a pattern match on the layout.

---

## 5. Not the OCaml heap — measured

liquidsoap's own `runtime.memory` over telnet, sampled while the process grew 5.6 MB:

```
                   managed      private(liq)    private(os)   live requests
  t = 0            56.7 MB        167.4 MB       221.2 MB          2
  t = 90s          56.7 MB        174.3 MB       227.7 MB          2
  t = 180s         56.7 MB        173.1 MB       235.3 MB          2

  managed grew   0.00 MB / 3 min
  private grew   5.62 MB / 3 min
```

Later, at 2,485 MB private and 8.7 h uptime:

```
  Physical memory     2.48 GB
  Private memory      1.98 GB
  Managed memory     43.14 MB
  Swapped memory      2.60 GB
  request.all         2 live requests (RIDs 221, 226)
```

`runtime.gc.full_major` + `runtime.gc.compact` returned 12.2 MB once (managed fell 56.7 -> 42.9 MB)
and did not change the trend.

**The allocation is C-side, outside the OCaml GC's accounting. No OCaml-level structure is
accumulating.**

---

## 6. Eliminated, with method

| # | Hypothesis | Method | Result | Regime | Verdict |
|---|---|---|---|---|---|
| 1 | OCaml heap growth | `runtime.memory` over 3 min | managed 0.00 MB / 3 min | active | out |
| 2 | Leaked requests | `request.all` | 2 live, flat | both | out |
| 3 | Thread stacks | thread count; reserved-per-block | 40-42 flat; +70 KB/block | active | out |
| 4 | Handle leak | `HandleCount` | 315-331 flat | both | out |
| 5 | Audio decoding | playlist -> `output.dummy`; CPU verified | 0.02 MB/min | isolated | out |
| 6 | ffmpeg/libmp3lame encode | `blank()` -> %ffmpeg mp3 -> file; 4.5 MB written | 0.19 MB/min | isolated | out |
| 7 | Decode + encode | playlist -> %ffmpeg -> file; 4.5 MB written | 0.03 MB/min | isolated | out |
| 8 | Network output | `output.file` / `.harbor` / `.icecast`; sink received 4.6 MB | 0.08 / 0.08 / 0.05 MB/min | isolated | out |
| 9 | `delay_line` | delay 0.0 and 1.75 s; `buffered()` polled | 0.00 / 0.02 MB/min; buffer plateaus at 1.76 s | isolated | out |
| 10 | `file.ls` 4x/sec (voice pickup) | isolated `thread.run(every=0.25)` on the real directory | −0.01 MB/min | isolated | out |
| 11 | Endpoint count | 1 / 21 / 61 registered endpoints | 2.4 / 3.5 / 4.3 KB per request | isolated | out |
| 12 | Handler body | none / `last_metadata` / `current_file` / all three | 3.6 / 4.7 / 4.0 / 5.4 KB per request | isolated | out |
| 13 | `interactive.harbor` + 13 knobs | added to bare probe | 2.3 KB per request | isolated | out |
| 14 | 1,202-record index in a ref | added to bare probe | 2.9 KB per request | isolated | out |
| 15 | `input.harbor` / `output.harbor` on same port | added to bare probe | 2.9 / 6.9 KB per request | isolated | out |
| 16 | Request headers | 1 header vs 17 browser headers, 150 requests each | 326 vs 313 KB per request | clone | out |
| 17 | Response size | 5 endpoints, replies 198 B - 7,078 B | identical cost | clone | out |
| 18 | Real icecast vs socket sink | the station itself repointed at a fake icecast | 26.86 -> 28.45 MB/min | **active** | out |
| 19 | 30 MB accumulated log file | moved aside, restarted on an empty log | 25.52 -> 42.10 MB/min | **active** | out |
| 20 | The station's own data files | 266 files (chat, posts, jsonl, config) copied into a clone | clone still 0.00 MB/min | quiet | out |
| 21 | `--run-service` mode | A/B/A on a clone: service / console / service | 0.01 / 0.03 / 0.00 MB/min | quiet | out |
| 22 | Non-audio files in the library | 55.1 KB per rejected file vs an all-audio control | real, ~0.03 MB/min at this library | isolated | **fixed** |
| 23 | Incoming HTTP traffic | reverse proxy stopped, 3 x 6-min windows | see §7 | **quiet** | **partial** |
| 24 | The service account | 2 attempts, both failed to execute | no data | — | **open** |

Rows 18 and 19 were measured in the active regime, where the background was ~10x the quiet rate.
They would not have resolved an effect smaller than a few MB/min. **They should be repeated.**

### 6.1 The one confirmed defect found — ours, and small

The library directory is 49.4% non-audio: **1,172 of 2,374 files** — 1,037 `.jpg` of album art, 42
`.db`, 41 `.ini`, plus `.xml`, `.js`, `.pdf`, and an unrelated software install directory.
`playlist` over a *directory* offers all of them as candidates. Each non-audio candidate that
reaches resolution is handed to ffmpeg, opened as an mjpeg video stream, found to carry no audio,
and torn down.

Controlled pair, 152 files each, one arm 150 of them album art, the other all audio:

```
  junk arm   194 files rejected, all opened as images    2.09 MB/min
  pure arm     0 rejected                                0.14 MB/min
                                                      -> 55.1 KB per rejection, never returned
```

Fixed with `check_next` (documented as being called *before* resolution), which took rejections
91 -> 0 on the same directory while the playlist still played 3 tracks. At the station's real
rejection rate — 33 rejections in 51 minutes, from its own log — this is worth **0.03 MB/min**.
Real, and not the leak.

---

## 7. Traffic: partially attributable, within noise

Three 6-minute windows at the quiet baseline, reverse proxy up / stopped / up:

```
  A  proxy up        2,503.5 -> 2,517.2 MB    2.28 MB/min    log +650,843 B
  B  proxy STOPPED   2,517.4 -> 2,527.9 MB    1.75 MB/min    nothing can reach the harbor
  C  proxy up        2,528.7 -> 2,546.6 MB    2.98 MB/min

  up mean 2.63  |  stopped 1.75  |  difference 0.88 MB/min
```

**Caveat, stated plainly: the two up-arms differ from each other by 0.70 MB/min, which is comparable
to the 0.88 MB/min effect being claimed. This is suggestive, not established.** One more repetition
with longer windows would settle it.

Arm A's request rate, **[inference]** from 650,843 log bytes at a measured 1,255 bytes per request
line: ~519 requests, ~86/min. If the whole 0.88 MB/min is traffic, that is **~10 KB per request** —
which agrees with the bare-liquidsoap figure (§6 rows 11-15, 2.3-6.9 KB) and **disagrees by ~27x
with the 268-326 KB per request measured on an aged clone** (§8). That disagreement is unexplained.

**~1.75 MB/min continues with nothing able to reach the harbor.** That is the part with no
candidate at all.

---

## 8. Per-request cost, measured on clones

```
bare liquidsoap, one trivial registered endpoint        2.4 - 4.0 KB per request
unregistered path (404), same process                   ~10x cheaper than a registered one

full script clone, freshly started                      ~83 KB per request   (0.32 blocks)
same clone after ~1,000 requests                   268 - 326 KB per request   (1.0-1.2 blocks)
```

Five endpoints on the aged clone, 100 requests each, fresh TCP connection per request:

```
  /control/now      103 blocks   268.6 KB/req      268 B reply
  /control/show     103 blocks   279.4 KB/req      198 B reply
  /likes/now         94 blocks   252.4 KB/req      405 B reply
  /earlier          103 blocks   276.7 KB/req    7,078 B reply   <- 26x the payload, same cost
  /control/knobs    111 blocks   298.2 KB/req      326 B reply
  /no/such/thing     10 blocks    26.8 KB/req      350 B reply   <- 10x cheaper, no handler matched
```

Flat in reply size. Flat in handler body. Ten times cheaper when no handler matches. Clean-room
control: **0 blocks across ten idle minutes, then 56 blocks from 200 requests.**

Note: liquidsoap's harbor **closed the connection after each response** — a keep-alive attempt got
one request through and then the connection was aborted — so on this build request count and
connection count are the same thing and could not be separated.

---

## 9. The unexplained gap

A clone of the station — same `radio.liq`, same music directory, the station's own data files
copied in, same `%ffmpeg`/libmp3lame settings, streaming to a socket sink, verified working each
time by the mp3 it wrote or the bytes its sink received — measures **0.00 MB/min**, as a console
process and as a Windows service.

```
same script, same library, same data, same 2-minute window

  STATION   pid 31540   1,005.7 -> 1,057.4 MB   = 25.84 MB/min    (active regime)
  CLONE     pid 17508     222.1 ->   222.1 MB   =  0.00 MB/min
```

The clone receives no HTTP traffic. But §7 shows the station still runs at **1.75 MB/min with no
traffic at all**, so traffic does not close this gap. The difference between a station at
1.75 MB/min and a clone at 0.00 MB/min with the same script, data and workload has no candidate.

Untested difference remaining: the service account. Two attempts to test it failed to execute
(§6 row 24).

---

## 10. What would settle it

An allocation stack for one 266,240-byte `VirtualAlloc`, or for the ~5 KB object inside it.

Attempted: `wpr -start VirtualAllocation` produced a 733 MB trace that **dropped 1,330,505 events**;
`tracerpt` flattened it to 1.2 GB of CSV in which the allocation provider appears only as an
unnamed GUID and no VirtualAlloc events for the target PID were extractable.

Available on the host: `wpr`, `tttracer`.
Not available: Windows Performance Analyzer, `xperf`, `gflags`, `umdh`, Debugging Tools for Windows.

---

## 11. Questions

1. **Is there a known unfreed allocation on the `harbor.http.register` response path in 2.4.x on
   Windows?** Profile: a few KB per request, independent of reply size and handler body, ~10x
   cheaper when no handler matches.

2. **Does this build use a private heap, and would disabling LFH on it
   (`HeapSetInformation`, `HeapCompatibilityInformation = 0`) collapse the amplification** if §4.1
   is right? If the leaked payload really is 52x smaller than the committed figure, that alone
   would make restarts unnecessary without finding the bug.

3. **Is 5,120 bytes a recognisable allocation size** anywhere in liquidsoap's or its vendored
   ffmpeg's Windows code path?

4. **What accounts for ~1.75 MB/min with no HTTP traffic, no live source, no track changes in the
   window, and a flat OCaml heap** — in a process whose clone, running the same script on the same
   data, is flat?

5. **Better way to get allocation stacks out of a running liquidsoap on Windows than ETW?**
   A debug-CRT build, an `OCAMLRUNPARAM` setting, an existing instrumentation hook, a build flag.

6. **Why would per-request cost measured on an aged clone (268-326 KB) exceed the station's
   derived cost (~10 KB) by 27x?** Both are on the same binary and script.

---

## 12. Method note — why the marking is laboured

Four probes in this investigation reported plausible numbers while not measuring what they claimed:

- A clone whose socket sink had died with its parent shell: the station "was flat" because it was
  never streaming.
- A service that never started: the arm reported `-1.0 MB` — a sentinel for *no process found* —
  and would have been read as 0.00.
- A PowerShell function whose `Write-Output` calls joined its return value, so every rate came back
  as `System.Object[]` and the script printed a conclusion drawn from garbage.
- A service-mode clone measured 2 minutes after launch, so its library scan and tag pass over 1,202
  files was counted as leak: 24.39 MB/min, reported as a reproduction, later contradicted by an
  A/B/A of 0.01 / 0.03 / 0.00.

Every figure in this document comes from a probe whose work was independently verified — CPU
burned, mp3 bytes written, sink bytes received, tracks played, or log lines counted. Two earlier
conclusions ("service mode reproduces it", "the leak is per-request in the harbor") did not survive
and are not asserted here.

---

## 13. Artifacts

- 3 raw block dumps, 266,240 bytes each (first / middle / last allocated).
- Measurement scripts: `VirtualQueryEx` walker and bucketer, `ReadProcessMemory` dumper, clean-room
  clone harness (ports remapped, socket sink), per-endpoint pricer, A/B/A runner.
- `radio.liq` in full (3,060 lines).
