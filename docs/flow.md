# Flash flow

This is the app and CLI contract. Core owns transitions and allowed recovery;
clients render them. Export ZIP uses the same inputs but never opens a phone.

## Independent state axes

- Connection: unavailable, waiting, opening, probing, ready, active,
  transitioning, needsAccess, lost, closing, stopped. A USB grant or arrival
  is not readiness. Ready requires the confirmed serial, consistent protocol
  answers, and the required mode. Arrival/removal cannot change write certainty.
- Run phase: setup → connecting → preparing → confirming → writing → done,
  or writing/preparing → recovering → writing/stopped. A terminal receipt may
  be restored for inspection, never turned into a live run after reload.
- Write certainty: notSubmitted, confirmed, refused, uncertain. Confirmed means
  protocol OKAY, not readback verification. A lost reply after submission is
  uncertain. Reconnection, a successful read, Stop, or reboot cannot erase it.

Only an explicit exact-serial confirmation starts writing. A failed run pauses
at its failed step. Recovery rechecks unchanged inputs, exact serial, mode and
`probeFastbootConsistency` before any write; inconsistent answers retire the
session and require physical power cycling. No automatic write retry exists.
A successful whole rewrite supersedes the failed attempt for that partition;
its original uncertain attempt remains in the receipt history. An unrelated
uncertain write remains uncertain.

## Recovery table

Every action is chosen explicitly. Stop is always available. Uncertainty is
shown before the error and no generic Retry is the default for an uncertain
write. The service, not a widget or CLI, decides which actions are offered.

| Action / service method | Preconditions | Commands sent | Resulting certainty |
|---|---|---|---|
| Retry read / `retryRead` | Failed read-only step; synchronized session; no uncertain write | Fresh exact-serial open, consistency reads, failed read and remaining plan | Previous uncertainty unchanged; subsequent writes need normal checks |
| Reconnect / `reconnectDevice` | Lost/disconnected/retired session; not an uncertain mutating step | Wait for same serial, consistency reads, resume refused/read-only step | Reconnect alone never settles a write |
| Reboot bootloader / `recoverBootloader` | Known mode mismatch or step requires bootloader | Consistency reads, `reboot-bootloader`, wait same serial, consistency reads; resume only if no uncertain mutation | An uncertain run remains paused for explicit rewrite |
| Reboot fastbootd / `recoverFastbootd` | Known mode mismatch or step requires fastbootd | Consistency reads, `reboot-fastboot`, wait same serial, consistency reads; resume only if no uncertain mutation | An uncertain run remains paused for explicit rewrite |
| Power cycled / `recoverPowerCycle` | Inconsistent answers or silent device; person has unplugged, held Power for 15 s, then entered bootloader with Volume-Down + Power | No reset command; wait same serial, consistency reads; uncertain mutation still needs explicit rewrite | Uncertainty remains until reconciled/replaced |
| Rewrite from byte zero / `rewriteStep` | Uncertain mutating step; explicit acknowledgement; consistent same-serial session in required mode | Full image from byte zero; logical create/delete first query `is-logical` and `partition-size`, reconcile observed state | Only completed replacement/reconciliation settles that operation; keep attempt history |
| Clear super / `wipeSuper` | Regional logical section blocked by capacity/preflight or logical create/resize FAIL `Not enough space`; explicit confirmation naming serial; fastbootd; snapshot status exactly `none`; known upstream size/names | Consistency reads, fresh snapshot check, sparse metadata-only image download, `flash:super`; restart logical section | OKAY confirms super metadata rewrite, not readback. Interrupted flash is uncertain. Phone cannot boot until run completes |
| Stop / `stopRun` | Active or paused run | No new commands after in-flight command completes; close session | Not rollback; uncertain attempts stay uncertain |

A device FAIL on a mutating step is not a read-only retry: rewriting a refused
image is a deliberate `rewriteStep` too. Invalid/changed input failures cannot
be repaired by reconnecting; prepare and confirm a new run instead. Recovery
preflight failure leaves the original paused run and uncertainty intact.

## Wipe-super preflight and recovery policy

Before the first logical mutation in fastbootd, Regional plans inventory all
logical allocations from `getvar all`, including both slots, unknown names and
`-cow`; query `is-logical` and `partition-size` to establish sizes. Missing or
malformed inventory is not proof of free space. Use upstream `SUPER_SIZE_TABLE`
for the selected device/region, reserve 4 MiB for LP metadata/alignment, and
simulate the remaining logical deletes, creates and image resizes in plan
order. Required space is the peak allocation, not the compressed download size
or merely the sum of new images. Existing partitions freed only later in the
plan still consume space at earlier steps. A peak above usable super capacity
pauses before the logical section with: “This phone's super still holds another
system (for example a custom ROM). Clear it?”

Never clear automatically. `snapshot-update-status` must be exactly `none`;
missing, unsupported, snapshotted or merging status refuses the wipe. No
snapshot cancellation/merge command is sent. A user declining can Stop and keep
the receipt. On `Not enough space` during logical create/resize the same action
is offered with the same checks. After a successful wipe, restart the logical
section (not the physical bootloader section), since all logical data was
removed. Super/SuperHybrid already rewrite whole super and do not offer this
Regional repair.

The sparse image comes from `lp-super`: metadata size 65536, three slots,
virtual A/B, the two `qti_dynamic_partitions_a/_b` groups each sized super minus
4 MiB, and every upstream `SUPER_PARTS` name in both slots at size zero. The
wire operation is download + `flash:super`, **not** `update-super:super:wipe`.
AOSP `wipe_super` generates a sparse `WriteToImageFile(..., true)` image then
calls `do_flash`. Snapshot protections vary by device and operation; do not rely
on firmware rejecting an unsafe wipe. See [fastboot.cpp](https://android.googlesource.com/platform/system/core/+/refs/heads/main/fastboot/fastboot.cpp),
[commands.cpp](https://android.googlesource.com/platform/system/core/+/refs/heads/main/fastboot/device/commands.cpp),
[images.cpp](https://android.googlesource.com/platform/system/core/+/refs/heads/main/fs_mgr/liblp/images.cpp)
and [writer.cpp](https://android.googlesource.com/platform/system/core/+/refs/heads/main/fs_mgr/liblp/writer.cpp).
The host adds a stricter fail-closed snapshot-status gate.

## Lifecycle rules

One active command stream and one confirmed serial. Connect/disconnect events
update connection state, never trigger a write or a competing probe. Async
selection/probe results are generation-fenced. Re-enumeration waits have finite
time/attempt budgets. No reset, redundant alternate selection, clear-halt,
driver detach or killing another program is automatic recovery.

Screen wake lock and `beforeunload` guard exist only while writing (including
an in-flight command after Stop). Release them when paused, done or stopped;
visibility changes reacquire wake lock only for a still-writing run. Lack of
wake-lock support is reported, not a reason to write without confirmation.
Cancellation stops after the current command, never mid-download. A worker
failure ends the live UI run, preserves the latest receipt/uncertain operation
and exposes diagnostics; it never causes worker restart and write replay.
Persist receipt snapshots before commands and on events. Reload restores an
inspection-only receipt; a new preparation/confirmation is required to write.
A service-worker update is announced while busy but reload is offered only
when idle. No automatic reload during preparation, confirmation or writing.

## Guided screens

Each screen has one primary action; help, diagnostics, receipt and Stop are
secondary. Material 3 and `widgets/common.dart` remain the visual vocabulary;
use a single-column layout on narrow screens and bounded content on desktop.
Connection changes are announced accessibly; a spinner means actual work.

1. **Setup** — device, kind, region, bloat, OTA and required conversion/ABL
   choices. Primary **Continue** when valid. Secondary **Export ZIP** retains
   the existing streamed export path and does not require USB.
2. **Connect** — instructions for bootloader, chosen serial and one connection
   status. Primary **Choose phone** (gesture-bound chooser), or **Check phone**
   for an existing grant. “Not in the list?” gives mode/cable/port/OS help.
3. **Check / Prepare** — read-only input/device checks, progress and prompt
   answers. Primary **Review plan** once resolved; failures retain diagnostics.
4. **Confirm** — exact serial, OTA identity, ordered writes, destructive risks
   and readback limits. Primary **Flash serial …** only after acknowledgement.
5. **Flash** — current step, real byte progress, last reply and mode-change
   guidance. No second write action; primary **Stop further commands**.
6. **Recover** — uncertainty first, plain-language failure, raw evidence one tap
   away. Primary safest applicable action from the service table (never generic
   Retry for an uncertain write); remaining explicit alternatives secondary.
   Clear super has a separate serial-naming confirmation and unbootable warning.
7. **Done / Stopped** — distinguish OKAY from verified readback and retain any
   unresolved uncertainty. Primary **Save receipt**; diagnostics always available.

The CLI renders this same table with explicit choices and serial-naming wipe
confirmation, defaults to Stop, and never maps an unknown choice to writing.
