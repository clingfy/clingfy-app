#!/bin/bash


BUNDLE_ID="com.clingfy.clingfy.dev"; 

echo "Bundle ID   : $APP_BUNDLE_ID"

echo "🧹 Cleaning Flutter build..."
flutter clean

echo "🔐 Resetting macOS Accessibility permissions..."
## Common service names include: Camera, Microphone, AddressBook, Photos, and ScreenCapture.
tccutil All Accessibility $BUNDLE_ID
tccutil reset All $BUNDLE_ID

echo "⚙️ Wiping Shared Preferences (NSUserDefaults)..."
defaults delete $BUNDLE_ID 2>/dev/null || true

echo "📂 Deleting App Sandbox Container..."
rm -rf ~/Library/Containers/$BUNDLE_ID

echo "🧹 Getting Flutter packages..."
flutter pub get


# echo "⚙️ Bootstrapping macOS environment..."
# cd macos
# echo "🧹 Wiping old CocoaPods cache..."
# pod deintegrate || true # Safely removes old Pods configurations
# pod install --repo-update
# cd ..

# flutter build macos --config-only

APP_ENV=dev; flutter run -d macos --release --flavor $APP_ENV --dart-define-from-file=.env.$APP_ENV

echo "🚀 Rebuilding and running..."
# flutter run -d macos --release --flavor $APP_ENV --dart-define-from-file=.env.$APP_ENV
flutter run -d macos --flavor $APP_ENV --dart-define-from-file=.env.$APP_ENV



