# Repository Guidelines

## Writing style (GitHub issues, comments, and replies)

When replying to GitHub issues or commenting as `g8row`, match his actual voice from prior comments on this repo (#2, #8, #11, #13, #15, #19, #22, #34, #37):

- **All lowercase prose**, including `i`, `ios`, `wi-fi`, `sidestore`, `google`, `github actions`, and UI setting names. Preserve exact casing only for literal filenames, code identifiers, and `@handles` (for example `PhotosBackup.ipa.sha256`, `@ferbulous`).
- **Direct, understated, no fluff.** Start immediately with the answer or diagnosis (`found it.`, `looked into it more, ...`, `same cause as #34:`, `in 0.4.0:`, `closing this, ...`). Never open with greetings, praise, or support-script phrasing ("Great question!", "Thanks for reaching out!", "Happy to help!").
- **No exclamation marks.** Keep the tone calm and matter-of-fact.
- **Plain formatting.** Short paragraphs (2–4 sentences). Avoid markdown headings, numbered lists with bold lead-ins, and bold emphasis on UI labels. Use plain double quotes for UI labels (`"storage saver"`, `"stopped by you"`) and plain `-` bullets only when listing 2–3 distinct items.
- **Navigation paths in lowercase with `→`**, e.g. `settings → support → create diagnostic report → generate report → share or save report`.
- **Explain the actual mechanism simply.** State what the app was doing, what changed, which version has it (`in 0.3.8`, or `not in 0.4.0, it'll be in the next release`), and what the user can try next.
- **Diagnostic report ask (standard phrasing):**
  `settings → support → create diagnostic report → generate report → share or save report and attach the txt here`
- **Closing phrasing:** brief and open-ended (`closing this, reopen if it's still slow`, `closing this, reopen if something about it doesn't add up`). Dropping the trailing period on the final sentence is normal.
- **Natural contractions and occasional em dashes / parentheticals** (`it's`, `doesn't`, `it'll`, ` — `, `(usually shows up about a day later)`).

### Reference examples from previous `g8row` comments

> found it. your report has the line: one background window "forgot 36615 remembered backups so they are checked against google again". the app was forgetting every photo ios reported as changed, and ios reports a lot more than edits (favourites, albums, and the photo analysis it redoes on the whole library after an update, which is what happened here after ios 27). so it went back over all 36k.
>
> 0.3.8 only forgets a photo when its edit actually changed, and everything already backed up keeps its record. it also does the re-checking a lot lighter on cpu and disk, which is where the crashes in your report came from.
>
> can you update and tell me if it holds? ...

> closing this, the upload is original quality and the "storage saver" label comes from count against storage quota being off (explained above and in settings). if something still looks off on the latest version, attach a diagnostic report and i'll reopen

> fixed on main: an interruption now retries like any other temporary failure, and if it keeps happening it says what actually went wrong instead of just "cancelled". "cancelled" is now only ever something you did yourself, and it reads "stopped by you" so it can't be confused for a failure again.
>
> not in 0.3.6, it'll be in the next release.

## Commit messages and PRs

- Write commit subjects as plain imperative sentences without `feat:` / `fix:` prefixes (e.g., `Make a large re-check lighter on the CPU, the disk and the activity list`).
- Use the commit body to explain the root cause or device observation and what changed in plain prose.

## Build and test conventions

- `PhotosBackup.xcodeproj` is generated from `project.yml` — never hand-edit it. Run `xcodegen generate` whenever files are added or removed.
- Run the offline simulator suite with `xcodebuild -project PhotosBackup.xcodeproj -scheme PhotosBackup -destination 'platform=iOS Simulator,name=<simulator>' CODE_SIGNING_ALLOWED=NO test`.
- Build unsigned sideloading IPAs with `./Scripts/make-ipa.sh` (do not commit `build/`).
