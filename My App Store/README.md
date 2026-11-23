# My App Store

A macOS app for organizing and installing Mac applications from a folder you control. The folder can be stored in iCloud Drive to share the catalog across your Macs.

## Features

- Import an `.app` or a ZIP containing one app, and organize apps into groups.
- Store app packages, icons, and a catalog in the selected repository folder.
- Install, reinstall, and update apps in a selected installation folder.
- Verify package hashes and installed app metadata.

## Requirements and setup

- macOS 14.6 or later.
- A recent Xcode version that supports this project format and the macOS SDK.
- Open `My App Store.xcodeproj`, select the **My App Store** scheme, and configure your own signing team and a unique bundle identifier in Signing & Capabilities before running.
- Choose a repository folder and click **Refresh**, then choose an installation folder. Use **Publish App** to import an app.

The repository folder contains your application packages and `catalog.json`. Keep it private unless you intend to share its contents. Folder permissions are saved locally as security-scoped bookmarks.

## Current limitations

- DMG and PKG imports are not supported. ZIP imports must contain exactly one app.
- Real iCloud synchronization and folder authorization flows need further interactive validation.
- Older catalog entries without icons display a placeholder.
- macOS signing, notarization, and Gatekeeper rules still apply to installed apps.

## License

No license has been specified. Contact the copyright holder before reusing or redistributing this project.
