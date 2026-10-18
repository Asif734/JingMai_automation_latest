#!/bin/sh
set -eu
# Invoked by Xcode for every app variant. No Flutter dependency in the helper.
worker_root="${PROJECT_DIR}/.."
worker_destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
worker_arch="${CURRENT_ARCH:-arm64}"
case "$worker_arch" in arm64|x86_64) ;; *) worker_arch="${NATIVE_ARCH_ACTUAL:-arm64}" ;; esac
mkdir -p "$worker_destination"
xcrun swiftc -O -D JD_UI_WORKER -target "$worker_arch-apple-macos13.0" \
  "$worker_root/macos/UiWorkerMain.swift" \
  "$worker_root/macos/Runner/AccessibilityBridge.swift" \
  "$worker_root/macos/Runner/CustomerSafety.swift" \
  -o "$worker_destination/JDUiWorker" \
  -framework AppKit -framework ApplicationServices -framework Vision \
  -framework Speech -framework AVFoundation -framework ImageIO -framework CryptoKit
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --identifier "${PRODUCT_BUNDLE_IDENTIFIER}.ui-worker" "$worker_destination/JDUiWorker"
