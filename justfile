derived_data := env("DERIVED_DATA_PATH", "build/DerivedData")
zip_dir := env("HOME") / "Downloads"
destination := "platform=macOS,arch=arm64"
# Brackets stop pkill/pgrep from matching the recipe's own shell.
dev_proc := "Debug/RAMnotes[.]app/Contents/MacOS/RAMnotes"

# List the available recipes.
default:
    @just --list

# Build build/DerivedData/Build/Products/Debug/RAMnotes.app, quit a running Debug instance, and open the new one.
run:
    xcodebuild -project RAMnotes.xcodeproj -scheme ramnotes -configuration Debug -derivedDataPath "{{derived_data}}" \
        -destination '{{destination}}' -skipPackageUpdates -disableAutomaticPackageResolution -quiet build
    @if pkill -f '{{dev_proc}}'; then while pgrep -f '{{dev_proc}}' >/dev/null; do sleep 0.1; done; fi
    open -n -a "{{justfile_directory()}}/{{derived_data}}/Build/Products/Debug/RAMnotes.app" "{{justfile_directory()}}"

# Build a ZIP in ~/Downloads: dev, release, or mas-release. Add --force for a clean build.
build target force='':
    @case {{quote(force)}} in ''|--force) ;; *) printf 'Unknown build option: %s\n' {{quote(force)}} >&2; exit 1 ;; esac
    @just {{quote('_build-' + target)}} {{quote(force)}}

# Build Debug and zip it as RAMnotes-dev.zip.
_build-dev force='':
    xcodebuild -project RAMnotes.xcodeproj -scheme ramnotes -configuration Debug -destination '{{destination}}' -derivedDataPath "{{derived_data}}" {{if force == '--force' { 'clean' } else { '' }}} build
    @just _zip Debug/RAMnotes.app RAMnotes-dev.zip

# Validate the update config, build Release, and zip it as RAMnotes-release.zip.
_build-release force='':
    xcodebuild -project RAMnotes.xcodeproj -scheme ramnotes -configuration Release -destination '{{destination}}' -derivedDataPath "{{derived_data}}" {{if force == '--force' { 'clean' } else { '' }}} build
    @just _zip Release/RAMnotes.app RAMnotes-release.zip

# Build the App Store configuration and zip it as RAMnotes-mas-release.zip.
_build-mas-release force='':
    xcodebuild -project RAMnotes.xcodeproj -scheme RAMnotesMAS -configuration AppStore -destination '{{destination}}' -derivedDataPath "{{derived_data}}" {{if force == '--force' { 'clean' } else { '' }}} build
    @just _zip AppStore/RAMnotes.app RAMnotes-mas-release.zip

_zip product name:
    ditto -c -k --sequesterRsrc --keepParent "{{derived_data}}/Build/Products/{{product}}" "{{zip_dir}}/{{name}}"
    @printf 'Created %s\n' "{{zip_dir}}/{{name}}"
