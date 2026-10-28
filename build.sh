#!/bin/bash
# Builds build/Oyl.app with the Xcode Command Line Tools (no Xcode project needed).
# Usage: ./build.sh            build
#        ./build.sh --run      build, then (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Oyl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos14.2" \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Oyl"

# Sign with a fixed local certificate rather than ad hoc. macOS ties permissions (capturing the
# player's audio, controlling Music/Spotify) to the signature; an ad-hoc one changes with every
# build, so each rebuild asked again. The certificate is made once and kept in its own keychain.
# (They keep the app's old name, nott: a new certificate would ask for every permission again.)
KEYCHAIN="$HOME/Library/Keychains/nott-signing.keychain-db"
KEYCHAIN_PASSWORD=nott
IDENTITY="nott local signing"
if [[ ! -f "$KEYCHAIN" ]]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cat > "$work/cert.cnf" <<CONFIG
[req]
distinguished_name = name
x509_extensions = extensions
prompt = no
[name]
CN = $IDENTITY
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONFIG
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$IDENTITY" \
        -passout pass:"$KEYCHAIN_PASSWORD" -out "$work/identity.p12"
    # create-keychain adds itself to the search list; put the list back as it was.
    searchList=$(security list-keychains -d user | xargs)
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    # shellcheck disable=SC2086
    security list-keychains -d user -s $searchList
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$work/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# codesign only finds identities in the search list, so add the keychain for this step only.
searchList=$(security list-keychains -d user | xargs)
# shellcheck disable=SC2086
security list-keychains -d user -s $searchList "$KEYCHAIN"
status=0
codesign --force --sign "$IDENTITY" "$APP" || status=$?
# shellcheck disable=SC2086
security list-keychains -d user -s $searchList
[[ $status -eq 0 ]] || exit "$status"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x Oyl || true
    # Opening while the old copy is still quitting fails, so wait for it to exit.
    while pgrep -x Oyl >/dev/null; do sleep 0.1; done
    open "$APP"
fi
