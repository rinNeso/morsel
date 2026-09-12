# Morsel

A mindful-eating app for iOS. Primarily a bite timer that paces a meal so satiety
signals have time to arrive; secondarily a meal journal, calorie log, and
Happy Scale-style weight trend tracker.

Personal, single-user, local-first. See [docs/SPEC.md](docs/SPEC.md) for the design
and [docs/schema.sql](docs/schema.sql) for the data model.

## Development

Day-to-day work happens on Linux; macOS is only needed to sign builds.

```sh
npm install
npx expo start          # then scan the QR with the dev client on the iPhone
```

Run the trend-math tests (no toolchain beyond Node 22 required):

```sh
node --experimental-strip-types src/lib/trend.test.ts
```

### Signing (macOS only)

```sh
npx expo prebuild       # regenerates ios/ — it is gitignored on purpose
open ios/*.xcworkspace  # sign and install from Xcode
```

Only required for the first dev client and whenever the native module list changes.
Pure JavaScript and TypeScript changes reload on the device straight from Linux.
