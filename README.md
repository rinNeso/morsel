# Morsel

A mindful-eating app for iOS. Primarily a bite timer that paces a meal so satiety
signals have time to arrive; secondarily a meal journal, calorie log, and
Happy Scale-style weight trend tracker.

Personal, single-user, local-first. Native SwiftUI, iOS 26+. See
[docs/SPEC.md](docs/SPEC.md) for the design and [docs/schema.sql](docs/schema.sql)
for the data model.

## Layout

| | |
|---|---|
| `MorselCore/Sources/MorselCore` | Pure logic: the meal-timer reducer, weight trend math. No dependencies. |
| `MorselCore/Sources/MorselData` | SQLite store via GRDB. |
| `App/` | SwiftUI app. |
| `project.yml` | XcodeGen spec. `Morsel.xcodeproj` is generated and gitignored. |

## Development

The logic is a plain SwiftPM package, so its tests run anywhere Swift does —
including Linux, with no Xcode:

```sh
cd MorselCore && swift test
```

Building and running the app itself needs Xcode, so macOS only:

```sh
xcodegen generate
xcodebuild -project Morsel.xcodeproj -scheme Morsel -configuration Debug \
  -destination "id=<device-udid>" -allowProvisioningUpdates build
```

Then install and launch on a connected device:

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device <udid> <path-to>/Morsel.app
xcrun devicectl device process launch --device <udid> com.rinneso.morsel
```

The phone must be unlocked to launch a development build.
