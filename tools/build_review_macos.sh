#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

# Explicit defines avoid inheriting a previous standalone configuration. This
# review variant uses the project's existing data and read-only runtime assets.
review_root="$project_root/build/review-prompt-release"
review_app="$review_root/Build/Products/Release/JD Automation Review.app"
flutter build macos --release --config-only --no-pub \
  --dart-define=JD_STANDALONE=false \
  --dart-define="JD_APP_NAME=JD Automation Review" \
  --build-name=0.1.5 --build-number=12
xcodebuild -quiet -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$review_root" -disableAutomaticPackageResolution \
  PRODUCT_NAME="JD Automation Review" \
  PRODUCT_BUNDLE_IDENTIFIER=com.grozziie.jdAutomation.review \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
# Seal the complete bundle, not just the linker-signed executable. A stable
# certificate may be supplied explicitly; ad-hoc signing needs renewed consent
# after code changes. Never modify TCC or grant privacy permissions here.
review_identity="${JD_REVIEW_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$review_identity" \
  --identifier com.grozziie.jdAutomation.review "$review_app"
# --deep applies -i to nested executables too. Restore the helper's distinct
# identity, then reseal the app without re-signing its nested code again.
codesign --force --sign "$review_identity" \
  --identifier com.grozziie.jdAutomation.review.ui-worker \
  "$review_app/Contents/Helpers/JDUiWorker"
codesign --force --sign "$review_identity" \
  --identifier com.grozziie.jdAutomation.review "$review_app"
codesign --verify --deep --strict "$review_app"
print "Review app: $review_app"
print "Authorize this exact app in System Settings; automation stays stopped on launch."
