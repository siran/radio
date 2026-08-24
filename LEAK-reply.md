# Reply: the Windows Liquidsoap leak has been identified upstream

Date: 2026-08-24

## Bottom line

The principal leak described in `LEAK.md` is now identified with high
confidence. It is not an accumulating Liquidsoap request, an OCaml-heap object,
the station's handler code, ffmpeg, or the Windows service account. It is a
Windows-only interaction between Liquidsoap's scheduler and OCaml's
`Unix.select` implementation.

Liquidsoap upstream reproduced the same failure on Windows 11 with the 2.4.5
Windows build and merged a targeted fix:

- issue: <https://github.com/savonet/liquidsoap/issues/5245>
- diagnosis and fix: <https://github.com/savonet/liquidsoap/pull/5290>
- merged commit: <https://github.com/savonet/liquidsoap/commit/1b05d07>

Dolly is still running the affected `liquidsoap-2.4.5-win64` binary. A read-only
check on 2026-08-24 found the process at approximately 2.68 GiB private memory
with 315 handles.

## Root cause

On Windows, OCaml's `Unix.select` has two relevant paths:

1. If every descriptor is a socket, it uses the ordinary Winsock `select()`
   path.
2. If even one descriptor is not a socket, it uses a worker-thread and
   `WSAEventSelect` emulation path.

Liquidsoap permanently put two pipes into its scheduler's descriptor set:

- the harbor accept-loop control descriptor in `harbor.ml`;
- the `Duppy.Monad.Mutex.Factory` wake descriptor in `duppy.ml`.

Those pipes forced every scheduler call through the second path. That path
leaks native Windows memory per call, outside the OCaml garbage collector.
Leak rate therefore follows scheduler wake rate: quiet operation leaks slowly;
HTTP requests, active harbor clients, and other scheduler activity make it leak
much faster.

The Liquidsoap fix is deliberately small. It replaces both `Unix.pipe` pairs
with `Unix_utils.socketpair`, allowing the descriptor set to remain
socket-only and keeping Windows on the non-leaking Winsock fast path. The
upstream diff is ten added lines and two removed lines across `harbor.ml` and
`duppy.ml`; the functional change is one constructor replacement in each
file.

## Why it matches this station

The independently reported upstream fingerprint matches `LEAK.md` unusually
closely:

- Windows 11 and Liquidsoap 2.4.5;
- private memory grows while `process_managed_memory` remains flat;
- memory is not recovered by OCaml full-major collection or compaction;
- growth accelerates sharply with harbor activity;
- the problem does not reproduce on macOS or Linux, where Liquidsoap uses a
  different polling path.

This station also keeps the affected scheduler active through all of the
following:

- 23 `harbor.http.register` endpoints on port 8005;
- `input.harbor` for the live source;
- `output.harbor` for the host's low-latency monitor;
- periodic `thread.run` work, including the 250 ms voice-note pickup loop.

That accounts for both regimes in the report. A connected monitor or request
burst raises the scheduler wake rate and produces the 26–52 MB/min measurements.
Periodic work and ordinary requests can sustain the quieter background rate.
It also explains why response size, handler body, live request count, handle
count, and the OCaml heap did not correlate with the lost memory: none of them
is the allocation owner.

The 266,240-byte regions remain a useful measurement fingerprint, but they are
allocator-level evidence rather than the root object. The earlier LFH
subsegment interpretation is compatible with a small native allocation being
amplified into committed heap regions; disabling LFH is no longer a sensible
primary fix now that the offending scheduler path is known.

## Proposed production fix

Use a Windows Liquidsoap binary containing merged commit `1b05d07`.

The preferred deployment is a 2.4.5-compatible build with that commit
backported, or a later supported 2.4.x Windows release that explicitly contains
it. The commit was merged to Liquidsoap `main`, while the currently published
2.4.5 binary predates it. Moving the station directly to a development 2.5
build would mix this two-line behavioral repair with unrelated changes and is
therefore a larger migration than necessary.

Do not delete or recreate the `LiquidsoapRadio` service during deployment. Its
`svc-radio` password exists only as the service's stored LSA secret. Replace or
repoint the executable while preserving the service object, `ObjectName`, and
environment.

## Acceptance test

Test the candidate binary in a clone before replacing the service:

1. Run the full station script on spare harbor and output ports, with audio
   output verified by growing bytes rather than process existence alone.
2. Record process private bytes and count committed private 266,240-byte
   regions for at least ten quiet minutes.
3. Hold an `output.harbor` monitor client connected for at least ten minutes.
4. Send a large burst to a registered `harbor.http.register` endpoint, using a
   fresh TCP connection per request, and use an unregistered path as a control.
5. Repeat the private-byte and region counts.

Pass condition: neither the quiet arm nor the active monitor/request arm shows
unbounded growth. Short-lived allocator movement is acceptable; the count must
plateau or return instead of increasing linearly. The existing 2.4.5 binary can
be run as the positive control and should reproduce growth under the same
active workload.

After deployment, observe Dolly for several hours and then overnight. Confirm
the stream, live input, monitor, registered endpoints, telnet control, track
changes, and service restart behavior in addition to memory.

## Interim containment

Until a patched binary is deployed, restarting `LiquidsoapRadio` before commit
pressure becomes dangerous is the reliable containment. Removing only the host
monitor may lower the rate but does not remove the affected scheduler: the
HTTP and live-input harbor functions still require it. Moving Liquidsoap to a
Linux host would avoid this Windows path but is much more invasive than applying
the upstream patch.

The separate non-audio playlist defect found during investigation has already
been fixed in `radio.liq` with `check_next`. It was real but accounted for only
about 0.03 MB/min at the station's observed rejection rate, so it should not be
mistaken for resolution of this principal leak.

## Remaining caveat

The upstream Liquidsoap patch notes that `process_handler` pipes can still put a
non-socket descriptor into the scheduler temporarily while an external process
runs. This station's normal graph does not use `process.run`, and the identified
permanent harbor and Duppy pipes explain the measured continuous leak. If future
scripts add long-running external processes, that residual Windows path should
be tested separately.
