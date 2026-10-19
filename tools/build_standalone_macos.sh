#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

# Separate derived data and product identity leave the original release intact.
standalone_root="$project_root/build/standalone-prompt-release"
standalone_app="$standalone_root/Build/Products/Release/JD Automation Standalone.app"
flutter build macos --release --config-only --no-pub \
  --dart-define=JD_STANDALONE=true \
  --dart-define="JD_APP_NAME=JD Automation Standalone" \
  --build-name=0.1.5 --build-number=14
xcodebuild -quiet -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$standalone_root" -disableAutomaticPackageResolution \
  PRODUCT_NAME="JD Automation Standalone" \
  PRODUCT_BUNDLE_IDENTIFIER=com.grozziie.jdAutomation.standalone \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
dart run tools/package_standalone_macos.dart "$standalone_app"
codesign --force --deep --sign - "$standalone_app"
codesign --verify --deep --strict "$standalone_app"
ditto -c -k --sequesterRsrc --keepParent "$standalone_app" \
  "$standalone_root/JD Automation Standalone.zip"
print "Standalone app: $standalone_app"
print "Shareable ZIP: $standalone_root/JD Automation Standalone.zip"
