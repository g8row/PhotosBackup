# Architecture

## Repo layout

```text
App/Sources/        SwiftUI app: onboarding, account, upload queue
App/Resources/      Info.plist, Assets.xcassets, .entitlements
Extension/Sources/  Native Safari extension handler (Swift)
Extension/WebResources/  manifest.json, *.js, popup, icons (lands at extension bundle root)
GPMC/Core/          Protocol client: GPMCClient.swift, Protobuf.swift
Tests/PhotosBackupTests/  Offline unit tests + gated live tests
Scripts/make-ipa.sh Unsigned IPA for SideStore/AltStore
project.yml         XcodeGen definition (source of truth for targets)
```

Generated `PhotosBackup.xcodeproj` is disposable — regenerate, don't hand-edit.

## Targets (project.yml)

- `PhotosBackup` (application): sources = `App/Sources` + `GPMC/Core`
- `PhotosBackupExtension` (app-extension): `Extension/Sources` + `Extension/WebResources` (resources phase)
- `PhotosBackupTests` (unit-test bundle): `Tests/PhotosBackupTests`, depends on `PhotosBackup`

## Key types (App/Sources)

| Type | File | Role |
| ---- | ---- | ---- |
| `PhotosBackupApp` | PhotosBackupApp.swift | Composition root: `ProbeLog`, `HandoffStore`, `AccountConnector`, `PhotosStack` (account+queue), `BackupPreferences`, `AutomaticBackupCoordinator`, `NetworkPolicyMonitor` |
| `AccountConnectView` | AccountConnectWebView.swift | In-app EmbeddedSetup WKWebView; polls the cookie store for `oauth_token`, hands it to the connector |
| `AccountConnector` | AccountConnector.swift | Owns single-use token, runs exchange (`ingestWebToken`), calls `stack.connect(result)` |
| `PhotosAccount` / `PhotosStack` | PhotosAccount.swift / PhotosStack.swift | Auth state + wiring downstream of token |
| `TokenExchange` | TokenExchange.swift | oauth_token → master token → Photos credential. Rejects `TokenEncrypted=1` (token binding not implemented) |
| `GPMCClient` | GPMC/Core/GPMCClient.swift | `photosdata-pa` RPCs, protobuf, access-token refresh (1 forced re-auth on 401/403), `GPMCError` with `isRetryable` |
| `UploadQueue` (`@MainActor`) | UploadQueue.swift | Bounded concurrency (default 2), 3 attempts w/ backoff, halt-on-credential-rejected, states: queued → exporting → hashing → checkingDuplicate → uploading → finalizing → done/alreadyBackedUp |
| `UploadQueuePersistence` | UploadQueuePersistence.swift | Durable per-account snapshot (version-checked, never reused across accounts) |
| `AutomaticBackupCoordinator` | AutomaticBackupCoordinator.swift | BGProcessingTask scheduling; batches: 25/background window, 250/foreground. On iOS 26 also holds a `BGContinuedProcessingTask` (`ContinuedBackup.swift`) whenever the open app has work, so the queue keeps running after the app is backgrounded (max 2 concurrent there); the other background paths skip their suspend while it is active |
| `NetworkPolicy` / monitor | NetworkPolicy.swift | Wi-Fi-only vs Wi-Fi+cellular, enforced at queue + request level |
| `CredentialStore` | CredentialStore.swift | Single Keychain item, `AfterFirstUnlockThisDeviceOnly` |
| `PickedFolderStore` / `FolderScanner` | FolderImport.swift | Folders picked from Files / iCloud Drive (Dashboard "Pick Folder"): bookmarks keyed by id, recursive media scan into `.folderFile(folderID:relativePath:)` sources; the exporter copies each file into staging under the folder's security-scoped access. Album filing uses the file's parent folder name |
| `GoogleAlbumRegistry` / `GoogleAlbumFiler` | GoogleAlbums.swift | "Add to Matching Albums": per-account JSON of album name → Google album key; files each upload into albums named after its iOS albums (or its folder) |
| `MediaExport` / `PhotosUploader` | MediaExport.swift / PhotosUploader.swift | PHAsset export → hash → duplicate-check → upload → finalize; Live Photos = still, then motion attached as a separate `livePhotoMotion` row; a photo edited in the Google Photos app (`com.google.photos.editing.filtering.nondestructive`) also gets an `editBase` row uploading `.adjustmentBasePhoto`, the version that app checks |

## Data flow

```text
In-app EmbeddedSetup WKWebView → AccountConnectView captures oauth_token
→ AccountConnector → TokenExchange → GPMCClient → UploadQueue → PhotosUploader
```
