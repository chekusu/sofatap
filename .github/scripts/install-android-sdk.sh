#!/usr/bin/env bash
# Installs the Android SDK pieces the jobs check for (platform 36, build tools 35.0.0) into the runner's tool cache,
# nothing system-wide, and points ANDROID_HOME at it for the following steps. GitHub's Ubuntu images come with an
# SDK; the self-hosted Linux runners (Hayabuild) do not. Needs Java 17 (actions/setup-java) for sdkmanager.
set -euo pipefail
tools=15859902
tools_sha256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
root="${RUNNER_TOOL_CACHE:-$RUNNER_TEMP}/android-sdk"
manager="$root/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$manager" ]; then
  archive="$RUNNER_TEMP/android-commandlinetools.zip"
  curl -fsSL --retry 3 "https://dl.google.com/android/repository/commandlinetools-linux-${tools}_latest.zip" -o "$archive"
  echo "$tools_sha256  $archive" | sha256sum -c -
  rm -rf "$RUNNER_TEMP/android-commandlinetools"
  unzip -q -o "$archive" -d "$RUNNER_TEMP/android-commandlinetools"
  mkdir -p "$root/cmdline-tools"
  rm -rf "$root/cmdline-tools/latest"
  mv "$RUNNER_TEMP/android-commandlinetools/cmdline-tools" "$root/cmdline-tools/latest"
  rm -f "$archive"
fi
# yes dies of SIGPIPE when sdkmanager is done, which pipefail would read as a failure.
{ yes || true; } | "$manager" --sdk_root="$root" --licenses >/dev/null
"$manager" --sdk_root="$root" --install 'platforms;android-36' 'build-tools;35.0.0' >/dev/null
echo "ANDROID_HOME=$root" >> "$GITHUB_ENV"
echo "ANDROID_SDK_ROOT=$root" >> "$GITHUB_ENV"
