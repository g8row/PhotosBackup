# Background photo backup: iOS 15 and later

Research date: 2026-09-10. Local code reviewed at `3625060`.
Status: strategy selected. The first increment adds a Shortcuts trigger on iOS 16+, storage visibility and safe orphan cleanup. Transport restructuring and optional arrival-home discovery remain follow-up work.

The priority is **new photos backing up unattended even when the app is rarely opened**. Keep iOS 15 support and, initially, the existing on-device Google Photos integration.

## Recommendation

Build one durable, staged upload engine with several legitimate opportunities to discover and prepare new photos. Use background URLSession for transfers, BGProcessingTask for catch-up, and offer an arrival-home trigger if the user accepts location access. Treat PhotoKit background resource uploads as a separate compatibility experiment for newer devices.

This can improve unattended backup substantially, but **guaranteed unattended discovery with a bounded delay is not available across iOS 15+**. Apple does not promise periodic background execution. A phone that stays stationary, with an app that is rarely used, remains the difficult case. A proxy server cannot make an older phone discover unqueued local photos. [Apple background execution limits](https://developer.apple.com/forums/thread/685525)

## What the research establishes

| Mechanism | Role in this app | Limit |
| --- | --- | --- |
| Background URLSession, iOS 15+ | Transfer prepared files through the system networking process | Does not discover or export new Photos assets |
| BGProcessingTask, iOS 15+ | Discover, prepare and reconcile in batches; overnight catch-up | Timing is controlled by iOS; work can expire |
| BGAppRefreshTask, iOS 15+ | Optional short reconciliation and status refresh | No regular wake-up guarantee; unsuitable for large exports |
| Core Location region monitoring | Optional user-configured “back up on arriving home” | Needs permission and a region transition; no stationary-device coverage |
| Shortcuts automation | Optional extra trigger at charging/time-of-day | Requires user setup and a working action on each supported OS/signing configuration |
| BGContinuedProcessingTask, iOS 26+ | Continue a user-started “Back Up Now” operation | Requires an explicit user action; does not discover future photos unattended |
| PhotoKit background resource upload, iOS 26.1+ | Purpose-built photo backup extension | Google protocol compatibility and extension signing need verification |
| Silent push | Possible server-event supplement if a backend is introduced | Delivery is not guaranteed; server does not observe local photo creation |

Background URLSession supports file-backed uploads while the app is suspended or system-terminated. Use a stable session identifier and delegate restoration. Apple recommends handing off multiple transfers rather than repeatedly waking for single transfers; background scheduling remains discretionary even if the configuration requests otherwise. [Apple background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

Force-quitting by swiping the app away cancels background URLSession transfers and prevents automatic relaunch until the user opens the app again. Distinguish this from normal suspension and system termination. [Apple session lifecycle](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))

Processing tasks may run for minutes, but are interruptible and run while the device is idle. The current `earliestBeginDate = now + 15 minutes` is an eligibility date, not a timer. [Apple BGProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask), [Apple scheduling limits](https://developer.apple.com/forums/thread/685525)

## What established apps add

**PhotoSync:** Offers location arrival and daily charging-based automatic transfer. Its support documentation explicitly says arrival does not trigger while remaining in the same location, and scheduled charging transfers can be delayed by system conditions. This is a useful product pattern, not proof of guaranteed delivery. Some older PhotoSync troubleshooting text states a fixed three-minute execution budget; do not use that as a current iOS contract. [Arrival behavior](https://www.photosync-app.com/support/basics/answers/how-does-the-autotransfer-feature-work-in-photosync), [Daily charging behavior](https://www.photosync-app.com/support/ios/answers/how-do-i-automatically-transfer-photos-once-a-day)

**Nextcloud:** Its location upload manager starts significant-location-change monitoring and invokes background auto-upload from the location callback. This verifies an actual implementation of another discovery trigger. We should implement our own narrow arrival feature rather than copy its code or its location logging. [Pinned Nextcloud source](https://github.com/nextcloud/ios/blob/aeb789c098b66578e13f0531f082390c2755c3d7/iOSClient/NCBackgroundLocationUploadManager.swift)

Core Location can wake the app for significant changes. Background App Refresh settings affect delivery, and location callbacks provide limited processing time. Location events are opportunities to do bounded work, not a persistent service or a promise to bypass force-quit. [Apple significant-change API](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()), [Apple location lifecycle](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/CoreLocation/CoreLocation.html)

**Immich:** Its FAQ acknowledges that iOS chooses background timing and duration, and suggests Background App Refresh, avoiding unnecessary Low Power Mode and more frequent app use. Its scheduler-based behavior does not solve the rarely-opened-app requirement by itself. [Immich FAQ](https://docs.immich.app/FAQ/)

**YAIIU:** Implements PhotoKit upload jobs with retries, acknowledgements and persistent tracking; its Immich integration requires a proxy converting raw resource uploads to multipart. This is a reference for job lifecycle, not evidence that direct Google Photos uploads will work. [YAIIU project](https://github.com/FawenYo/YAIIU), [Extension implementation](https://github.com/FawenYo/YAIIU/blob/main/YAIIU/BackgroundUploadExtension/BackgroundUploadExtension.swift)

## Findings in our current code

These are source-review findings, not results from a device experiment.

1. **The key primitives already exist.** `BackgroundUploadTransport.swift` uses a stable background session, file uploads and persisted results. `UploadQueuePersistence.swift` stores account-scoped JSON checkpoints and a completion ledger. Staging is in Application Support with protection permitting access after first unlock.
2. **Discovery count differs from system transfer count.** `AutomaticBackupCoordinator.swift` enqueues up to 250 sources in a background scan, but `UploadQueue.pump()` limits whole workers with `running.count < maxConcurrent`. `PhotosUploader.worker()` retains a slot through export, hash, preflight, transfer and commit. Raising the scan limit alone does not hand more prepared uploads to iOS.
3. **Completion wakes intentionally exclude fresh preparation.** `resumeBackgroundTransferCompletions()` drains prepared work. Once those transfers finish, unprepared photos need another foreground or processing opportunity.
4. **Cloud-only media is deliberately foreground-dependent.** The coordinator disables iCloud downloads in background windows. That conflicts with unattended backup when Optimize iPhone Storage has removed originals. Replace unconditional exclusion with a separately budgeted, cancellable preparation policy; success before expiration cannot be promised.
5. **Google finalization still needs app execution.** `GPMCClient.transfer()` reads a protobuf receipt from the PUT response body. `commit()` sends that receipt in a separate RPC. The receipt is checkpointed, but the completion handler currently tries to drain commits within a local 25-second deadline. That deadline is an implementation choice, not guaranteed runtime.
6. **There is a foreground-only recovery path.** Invalid receipts can set `continuesAfterProcessExit = false`. Such items cannot meet the desired background behavior until the underlying receipt failure is understood; count and expose this fallback.
7. **Persistence failures do not block handoff.** `persistNow()` catches save failures and sets a warning, while the worker can continue. For a stronger durability contract, a failed critical checkpoint must prevent transfer submission or destructive cleanup.
8. **A timer treats 15 minutes without byte progress as a stall.** OS-deferred or disconnected transfers can be legitimately quiet. Reconcile actual task state and distinguish connectivity/scheduling waits before canceling and retransmitting.

## Second pass: what shipping open-source apps do (GitHub, 2026-09-10)

| Project | Background mechanism | What we take from it |
| --- | --- | --- |
| Immich, `mobile/ios/Runner/Background/BackgroundWorkerApiImpl.swift` | Registers a `BGAppRefreshTask`, which the app caps at 20 s, and a network-requiring `BGProcessingTask`. Each handler resubmits its successor first. A semaphore makes a refresh window give its time back while a processing window runs. Expiration cancels the worker and completes the task two seconds later. | Our Shortcut now refuses to start a second run over a live window, and every window resubmits before working. A short `BGAppRefreshTask` path is the one pattern we still lack. |
| Nextcloud iOS, `iOSClient/Processor/AppDelegate+AppProcessing.swift` | `BGProcessingTask` resubmitted at start. The work is a Swift `Task` that the expiration handler cancels and each phase checks. Every phase logs a tagged start and stop. | Same structure as ours. It confirms that logging the start, stop, and expiry of each window is the practical way to answer "it never runs". |
| Umbrel, `clients/apple/ios/BackgroundUploadExtension/BackgroundUploadExtension.swift` | The iOS 26.1 `PHBackgroundResourceUploadExtension` is the only uploader. Each `process()` call advances a durable ledger: ingest library changes, reconcile PhotoKit's jobs, then refill the in-flight queue. Configuration and credentials are shared through the app group and Keychain. | Shows the extension route works in shipping code — for a server that accepts raw resource uploads. Our blocker is unchanged: Google's receipt arrives in the PUT response body. |
| YAIIU | The same PhotoKit extension, with a proxy converting to Immich's multipart format. | A reference for job lifecycle, not for Google. |

Apple constraints confirmed in this pass:

- An App Intent run from Siri or Shortcuts has about 30 seconds; past that the action fails. iOS 27 adds `LongRunningIntent`, which continues the work as a Live Activity, but that is outside our iOS 15–26 range. [Apple forum](https://developer.apple.com/forums/thread/720454), [FB12016280](https://github.com/feedback-assistant/reports/issues/386), [LongRunningIntent](https://matthewcassinelli.com/app-intents-thirty-second-limit-extend-execution-live-activity-longrunningintent/)
- MetricKit delivers crash reports and process-exit counts only for users who share analytics with developers, usually a day later. A memory-limit termination has no crash report; it shows up only in the exit counts. [MXCrashDiagnostic](https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic)

### Changes made from this pass (0.3.6)

- **Shortcut action.** One 22-second budget covers the whole action, scan included. With the app open, it queues and returns without pausing the foreground uploads; it used to suspend them until the next activation. It does not start while a background window is running. It no longer requires the Automatic Backup switch, so a schedule of the user's choosing can replace it.
- **Crash-loop guard (issue #13).** Rows that are exporting, hashing, or preflighting are marked in UserDefaults while the app is open or inside a granted window. At relaunch, a marked row goes to the back of the queue. A second death on the same row fails it as non-retryable. Nothing is marked while the app is suspended, so iOS's routine terminations do not count. The hashing loop also drains an autorelease pool per chunk.
- **Diagnostics.** The event timeline records each decision with its reason. That covers launch conditions, whether the previous session ended unexpectedly, scheduler requests and their errors, and when iOS started and ended each window relative to the request. It also covers run results with their conditions (battery, network, Low Power Mode, lock state), library scan mode, account restore, queue pauses and halts, per-stage failures, iCloud deferrals, and background-transfer delivery summaries. Identical consecutive entries fold together, and routine entries are dropped before warnings and errors. MetricKit crash and exit data, the last 40 runs, and a "What stands out" summary appear in the report.

### Next candidates

1. A `BGAppRefreshTask` (the Immich pattern): short windows that iOS grants more often than processing windows, used to scan and hand prepared uploads to the background session. It needs a second permitted identifier and `fetch` in `UIBackgroundModes`.
2. An opt-in "only while charging" setting (issue #14) that sets `requiresExternalPower` and gates the queue on battery state.
3. Progress for a user-started backup that survives leaving the app: `BGContinuedProcessingTask` on iOS 26, and a Live Activity (issue #2).

## Implementation order

### 1. Prove the current transport and receipt path

Before restructuring scheduling, validate background PUT response receipts and commit recovery on physical devices. Reproduce the invalid-receipt fallback with sanitized diagnostics. Resolve it or explicitly identify the affected conditions. A new trigger cannot fix an upload that silently requires the foreground.

Log wake reason, last scan, prepared count, system task count, receipt count, confirmed Google completions, stage failures and fallback count. Never log credentials or upload URLs containing sensitive identifiers.

### 2. Separate preparation, submission and finalization

Use a state machine such as:

```text
Discovered -> Preparing -> Prepared -> Submitted to iOS
                                      -> Receipt saved -> Commit pending -> Confirmed
```

Keep export/hash concurrency independent of outstanding system transfers. Prepare and submit a bounded batch during each useful execution window instead of waiting for one full worker to finish before preparing the next asset. Bound by bytes, free disk space, memory, task count and authorization/upload-URL lifetime; choose actual limits from device measurements.

Store each critical handoff successfully before submitting the task. On any relaunch, reconcile the durable records with `getAllTasks` and stored delegate results. Preserve files until their task ownership is resolved. Give commits priority over new exports; confirmed Google completion is the only state that counts as backed up.

First make commit retry durable and bounded. Evaluate a file-backed background POST for the commit RPC as a separate experiment if normal completion windows prove inadequate. Its authenticated request, response handling and duplicate behavior must be verified against Google's private protocol. Do not assume exactly-once commit: after an ambiguous result, reconcile remote existence before resending media.

Retain the existing persistence initially if it can enforce these invariants. SQLite transactions become attractive for large queues or multi-process extension sharing, but changing storage alone does not improve wake frequency.

### 3. Add unattended discovery opportunities

Keep BGProcessingTask catch-up and resubmit after each invocation. Offer a preferred overnight charging window, describing it as an earliest opportunity. Finish once bounded preparation, submission and reconciliation are done; leave transfers to iOS. Do not hold the task merely waiting for network bytes.

Add an optional user-configured arrival-home geofence if accepted. Use the event to perform a bounded scan and hand off prepared work. Store only the chosen region locally; do not keep a movement history. Respect account changes, Photos access, network policy and cancellation.

Use PhotoKit change observation while the process is executing. Retain persistent change-token scans on iOS 16+, with safe token-expiry recovery. On iOS 15, maintain resumable current-library reconciliation that does not miss backdated imports or edits. Do not advance a scan checkpoint ahead of successful queue persistence.

Consider a Shortcuts backup action as an additional option for stationary phones. Apple documents time-of-day and charger automations. iOS 15 needs a compatible legacy Intents path rather than an App Intents-only implementation. Locked-device execution, Photos/Keychain access and free-team signing require a prototype before calling this unattended support; an “Open App” action is insufficient. [Apple automation guidance](https://support.apple.com/en-gb/guide/shortcuts/apd602971e63/ios), [Apple Intents migration context](https://developer.apple.com/videos/play/tech-talks/110356/)

### 4. Investigate PhotoKit on iOS 26.1+

Apple confirms the older upload extension begins at iOS 26.1; current documentation also describes its iOS 27 successor. Full Photos access is required. iOS manages resource retrieval and upload, but still schedules work according to device conditions. The documented job results expose response headers and errors. [Apple PhotoKit upload guide](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background)

Our Google integration requires hashing before initialization and a receipt from the response **body** afterward. The documented PhotoKit result surface does not establish how to obtain that receipt. Therefore direct compatibility remains unproven. A proxy could capture the receipt and perform Google finalization, but adds hosting, media transit and credential-handling responsibilities. Do not introduce one without choosing that architecture explicitly.

Test activation, full versus limited access, shared state, current sideload signing, iCloud originals, Google initialization, response/commit handling, URL expiry and duplicate reconciliation. Make it the preferred newer-OS path only after these pass.

BGContinuedProcessingTask can separately improve a user-started initial backup on iOS 26+. It requires explicit user initiation and does not solve subsequent unattended discovery. [Apple WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/)

Automatic byte-offset upload resumption is also not universal: Apple's URLSession support starts at iOS 17 and requires the server's compatible resumable-upload protocol. Google support is unverified here; durable retry may restart a file. [Apple resumable uploads](https://developer.apple.com/documentation/foundation/pausing-and-resuming-uploads)

## Acceptance evidence

Use physical iOS 15 and newer phones without an attached debugger. Simulated task launches test handlers, not natural scheduling reliability.

Run a multi-day trial that takes new photos without opening the app. Include a stationary phone overnight, arrival-home events, lock/unlock, ordinary system termination, explicit force-quit followed by reopening, reboot/first unlock, Wi-Fi loss, cellular-policy changes, Low Power Mode and Background App Refresh off.

Exercise local photos, iCloud-only originals, large videos, low disk space, expired authorization/upload URLs, server errors, crash after PUT before commit and crash after server commit before local confirmation. Keep the current still-image-only Live Photo scope visible; resource-complete backup is separate work.

Measure discovery latency separately from preparation, transfer and finalization latency. Report actual Google confirmations, missed items, duplicated items and battery impact. Treat periods with no granted execution opportunity distinctly from engine failures. A useful target is recovery without missing or falsely completed items whenever execution becomes available; observed overnight completion is evidence, not an OS guarantee.

If the requirement remains “every new photo must reach Google within a fixed deadline while the app is never opened,” this iOS 15 app cannot honestly promise it. That requires changing the product requirement or moving discovery to another supported environment, such as an always-on computer with access to the photo library.
