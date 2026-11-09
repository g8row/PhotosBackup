# What the Google Photos iOS app counts as backed up

Observed on 18–19 Sep 2026 on an iPhone 16 Pro Max (iOS 26.6.1) running
Google Photos 7.92.0, with a library of about 8,500 items uploaded by Photos
Backup under the Pixel XL profile. Evidence is the app's "not backed up" count,
its backup icons, Free up space and Delete from device, before and after each
upload. The research notes linked below explain why, from the app's code.

## Backed up

The account must hold a file byte for byte identical (SHA-1) to the one the
Google Photos app would upload itself for the item on the iPhone.

| Item on the iPhone | The file Google checks | Photos Backup uploads |
| --- | --- | --- |
| Unedited photo or video | The original (`.photo` / `.video`) | The same |
| Edited by the camera or in Apple Photos (styles, Portrait, crop, Auto) | The rendered edit (`.fullSizePhoto` / `.fullSizeVideo`) | The same |
| Edited video, including every Cinematic video | Counted once both the rendered edit and the original (`.video`) are in the account (iOS 27.2, Google Photos 7.98) | The rendered edit, then the original in its own row |
| Edited in the Google Photos app (`com.google.photos.editing.filtering.nondestructive`) | The version Google's edit was applied on (`.adjustmentBasePhoto`) | The finished edit, then the base in its own row |
| Saved to the iPhone from Google Photos | Never counted | Nothing helps. An edit in Apple Photos makes a new file that counts |

- **Edited items.** 8,145 items showed "not backed up" while only their
  originals were uploaded; 43 did after their rendered edits were.
- **Google Photos edits.** IMG_0102 did not count with both its original and
  its finished edit in the account, and counted once its adjustment base was
  uploaded.
- **Downloads from Google Photos.** A forced re-upload returned the library
  item that already held those bytes, and the app still did not count it.
  After a trivial edit in Apple Photos, the rendered file counted.
- **Cinematic videos.** On 31 Oct 2026, about 55 of 62 showed "not backed up"
  with only their rendered edits uploaded, and none did once their originals
  were added. All 62 originals went up together, so this does not show which
  videos needed one. The camera saves every Cinematic video as edited.
- **Archive.** Archiving the matching item un-counts the photo.
- **Editing again.** A photo edited again is not backed up until its new
  render is uploaded.

## Free up space

It offers a backed-up item only if it passes the checks in
[free-up-space-research.md](free-up-space-research.md). Two decided the outcome
on this account:

- **Edited items are skipped** while the server flag `Growth__fix_fus_promise`
  is on. It was on here: none of about 8,100 edited items were offered,
  including ones Google's own backup uploaded.
- **A Live Photo needs its motion attached** to the server item. Attaching it
  with commit field 9 (`reconcileInfo`) onto the existing still, or field 24
  (`livePhotoInfo`) in a paired commit
  ([live-photo-paired-upload.md](live-photo-paired-upload.md)), took Free up
  space from 2 items to 461.

The storage policy and the "Storage saver" label play no part.

## Delete from device

- **One photo:** offered only when it is backed up.
- **Several selected:** offered whenever the selection includes a photo on the
  iPhone. Photos that are not backed up are deleted too, after a "Some of these
  items aren't backed up" warning.
- **No edited or Live Photo checks,** so it removes the edited photos Free up
  space skips. See [delete-from-device-research.md](delete-from-device-research.md).

## Rate limit

photosdata-pa enforces "PhotosFeService RPC calls per minute per user"
(HTTP 429). Re-checking 8,535 items with 5 uploads at a time hit it within
about 7 minutes.
