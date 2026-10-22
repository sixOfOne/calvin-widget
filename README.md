# Calvin and Hobbes desktop widget

A small macOS app and WidgetKit widget that show the day's [Calvin and Hobbes](https://www.gocomics.com/calvinandhobbes) strip. GoComics has no API for this. The app reads the public daily page and downloads the comic image from it, then saves that image in a shared App Group folder. The widget reads the saved image. It does not download the comic itself.

It is meant for personal use. Build it once in Xcode with a free personal Apple ID. No paid developer account and no extra tools.

The project targets macOS 14 or later, which current Xcode on Apple silicon can build.

## Disclaimer

Calvin and Hobbes is © Bill Watterson / Andrews McMeel. This project is not affiliated with, endorsed by, or connected to Bill Watterson, Andrews McMeel, or GoComics.

Strips are loaded from GoComics when you run the app, for your own personal viewing. They are not included in this repository and are not redistributed by it. Do not commit comic images.

The source code is under the MIT license in `LICENSE`. That license covers this project's code only. It does not grant any rights to Calvin and Hobbes.

## Build

1. Install Xcode that can build for macOS 14 or later.
2. Copy the local signing file and set your team:
   ```
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```
   Open `Config/Local.xcconfig` and replace `YOUR_TEAM_ID` with your Apple Team ID. In Xcode: **Settings → Accounts → your Apple ID → Team ID**. A free personal team works. That file is gitignored. Do not commit it, and do not put the team id in `Config/Base.xcconfig` or `project.pbxproj`.
3. Open `CalvinWidget.xcodeproj`.
4. Signing & Capabilities should show your team from `Config/Local.xcconfig`, **App Sandbox** on both targets, and **Outgoing Connections (Client)** on the app only. Leave those as they are. The widget only reads the saved image, so it has no network entitlement.
5. If Xcode's signing UI writes `DEVELOPMENT_TEAM` into `project.pbxproj`, do not commit that change. Keep the team id in `Config/Local.xcconfig`.
6. Choose **Product > Run**. The first load can take about a minute. GoComics runs a browser check before it serves the page. The window then shows today's strip, or yesterday's if today's is not posted yet.
7. Right-click the desktop, choose **Edit Widgets**, and add **Calvin and Hobbes**. Strips are wide, so the widget is offered in medium, large, and extra large. Clicking it opens that day's page on GoComics.

`Config/Base.xcconfig` holds the shared defaults and includes `Local.xcconfig` when that file exists. The include is optional, so a build machine without your team id can still compile when code signing is turned off.

Do not add an App Groups capability, and if Xcode offers to "fix" App Groups, decline it unless a build actually fails with the profile error in the section below. Both targets already claim a macOS-style group, `$(TeamIdentifierPrefix)$(APP_GROUP_SUFFIX)`, in their entitlements files. With the default prefix that is `$(TeamIdentifierPrefix)com.example.CalvinWidget.shared`. A free personal team can use that form without registering a group on the Apple Developer site. Xcode fills in your Team ID when it signs the app.

The app writes the image into `Library/Application Support` inside the shared group container. That is the directory macOS lets the sandboxed app write. The newspaper icon in the menu bar is the app. Closing the window leaves it running so it can refresh the strip.

### Bundle identifier

The default ids are:

- App: `com.example.CalvinWidget`
- Widget: `com.example.CalvinWidget.widget`
- App Group suffix: `com.example.CalvinWidget.shared` (your Team ID is added in front when the app is signed)

If Xcode says the bundle id is unavailable, set your own prefix in `Config/Local.xcconfig`:

```
BUNDLE_ID_PREFIX = com.yourname
```

The app id, the widget id, and the App Group suffix all follow that prefix. The widget id stays the app id plus `.widget`, which is what the extension embed requires. You do not edit the entitlements or the Swift sources to change it.

### If you already have a local build

1. Pull this update.
2. Create `Config/Local.xcconfig` as above, with the same team you were using. Leave App Sandbox on. Outgoing Connections stays on the app only.
3. Choose **Product > Run**. Wait until the window shows a strip. The desktop widget updates from the image saved in the App Group container. If the old widget stays on "Couldn't load today's strip" or asks you to open the app, remove it and add **Calvin and Hobbes** again.

Older builds could also save a copy under `~/Library/Application Support/CalvinWidget`. The app no longer reads or writes that folder. Run the app once so the strip is saved in the App Group container.

### Open at login

The strip is fetched by the app, including a check shortly after midnight and retries later if today's page is not up yet. To keep that going after a restart:

1. In Xcode's project navigator, expand **Products**, right-click **CalvinWidget.app**, and choose **Show in Finder**.
2. Copy that app into `/Applications`.
3. Open the copy in `/Applications` (not the Xcode run).
4. In the window, turn on **Open at login**. The same switch is in the newspaper menu.
5. If the label says macOS is waiting for approval, allow **Calvin and Hobbes** in **System Settings → General → Login Items & Extensions**.

A copy that lives only in Xcode's build folder will not still be there after the next clean build, so the login item has to point at `/Applications`. At login the window stays closed. Open it from the newspaper icon.

There is no Login Items capability to turn on in Xcode. The switch uses the system login-item API, which does not need an extra entitlement.

### Only if signing fails

If Xcode says the provisioning profile does not support the App Groups entitlement:

1. Select the **CalvinWidget** target, then **Signing & Capabilities**.
2. Click **+ Capability** and add **App Groups**.
3. Add the group id your build actually signs: your Team ID, a dot, then the suffix (`com.example.CalvinWidget.shared` unless you changed `BUNDLE_ID_PREFIX`). Do not add an id that starts with `group.` — a free team often cannot register those. If Xcode adds one, delete it.
4. Repeat for the **CalvinWidgetExtension** target, with the same group id.
5. If Xcode rewrites the entitlements, put the variable form back: `$(TeamIdentifierPrefix)$(APP_GROUP_SUFFIX)`. A concrete team id in that file should not be committed.
6. Choose **Product > Run** again.

The group id has to match in both entitlements files and in the `CalvinGroupSuffix` value baked into each target at build time (from `APP_GROUP_SUFFIX` in the xcconfig). `Shared/StripStore.swift` reads that value. It does not have its own copy of the id.

## What to expect

After the window has today's strip, the app asks WidgetKit to reload. It also checks about ten minutes past local midnight, when the Mac wakes, and about every half hour while the app is running. If a check fails, or today's strip is not posted yet, it waits about three hours before trying the page again. **Refresh** in the window, or **Refresh Now** in the menu bar, tries immediately.

Sunday strips are taller than the weekday ones. The widget scales the whole image to fit, on a paper-colored background.

If the widget does not appear in Edit Widgets, run the app once from Xcode. If it is still missing, open the `CalvinWidget.app` you copied into `/Applications`.

## If the strip stops loading

The app loads the daily page in a web view at the top of the window, for example `https://www.gocomics.com/calvinandhobbes/2026/10/15`, so GoComics' browser check can run. That check does not run in a hidden window. A plain download is rejected with a short JavaScript challenge page. The image file itself is then downloaded from `featureassets.gocomics.com`, which does not use that check.

If the window still ends without a strip, the small text under the error says which step stopped. The same steps are in Console. The subsystem is the app's bundle id:

```
log show --predicate 'subsystem == "com.example.CalvinWidget"' --last 30m
```

If you set `BUNDLE_ID_PREFIX`, use that bundle id in the predicate instead of `com.example.CalvinWidget`.

Once the page is the real comic, the app looks for the image in this order:

1. `og:image`, then `twitter:image`, then `vf:image`, when the page's `og:url` is that calendar day
2. A JSON-LD `ImageObject` whose `contentUrl` is on `featureassets.gocomics.com` and whose `datePublished` matches the day
3. The first `featureassets.gocomics.com/assets/…` URL on a page that is clearly that day

Optimizer query strings (`?optimizer=image&width=…`) are removed so the original asset is downloaded. The image is then scaled down to a JPEG so it fits WidgetKit's timeline size limit.

This scrapes the page. If GoComics changes its HTML, the window will say it couldn't load today's strip and `Shared/StripHTML.swift` will need a matching update.

## Continuous integration

`.github/workflows/build.yml` compiles the `CalvinWidget` scheme on a GitHub-hosted Mac with code signing turned off (`CODE_SIGNING_ALLOWED=NO`). It does not run the app or contact GoComics, and it does not use your team id. A build on your Mac still needs `Config/Local.xcconfig`.
