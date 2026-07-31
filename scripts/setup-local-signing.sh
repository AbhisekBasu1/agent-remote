#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
SIGNING_DIRECTORY="$PROJECT_ROOT/.local-signing"
SIGNING_KEYCHAIN="$SIGNING_DIRECTORY/DualSenseBridge.keychain-db"
SIGNING_KEYCHAIN_PASSWORD="DualSenseBridgeLocalKeychain2026"
SIGNING_IDENTITY_NAME="DualSense Bridge Local Code Signing"
USER_DEFAULT_KEYCHAIN=$(security default-keychain -d user \
  | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')

if [[ -z "$USER_DEFAULT_KEYCHAIN" ]]; then
  print -u2 -- "error: could not resolve the default user keychain"
  exit 1
fi

mkdir -p "$SIGNING_DIRECTORY"
chmod 700 "$SIGNING_DIRECTORY"

TEMPORARY_DIRECTORY=$(mktemp -d /private/tmp/DualSenseBridgeSigning.XXXXXX)
trap 'rm -rf -- "$TEMPORARY_DIRECTORY"' EXIT

if [[ -f "$SIGNING_KEYCHAIN" ]]; then
  security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
  if security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" \
      | grep -Fq "$SIGNING_IDENTITY_NAME"; then
    security export \
      -k "$SIGNING_KEYCHAIN" \
      -t certs \
      -f pemseq \
      -p \
      -o "$TEMPORARY_DIRECTORY/certificate.pem"

    if ! security verify-cert \
        -c "$TEMPORARY_DIRECTORY/certificate.pem" \
        -p codeSign \
        -L \
        -q; then
      security add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "$USER_DEFAULT_KEYCHAIN" \
        "$TEMPORARY_DIRECTORY/certificate.pem"
    fi

    security verify-cert \
      -c "$TEMPORARY_DIRECTORY/certificate.pem" \
      -p codeSign \
      -L \
      -q
    print -r -- "Stable local signing is already configured."
    exit 0
  fi

  # Resume a setup that imported the identity before user-level trust was
  # registered. Only the public certificate is exported.
  security export \
    -k "$SIGNING_KEYCHAIN" \
    -t certs \
    -f pemseq \
    -p \
    -o "$TEMPORARY_DIRECTORY/certificate.pem"

  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$USER_DEFAULT_KEYCHAIN" \
    "$TEMPORARY_DIRECTORY/certificate.pem"

  security verify-cert \
    -c "$TEMPORARY_DIRECTORY/certificate.pem" \
    -p codeSign \
    -L \
    -q

  security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" \
    | grep -F "$SIGNING_IDENTITY_NAME"
  chmod 600 "$SIGNING_KEYCHAIN"
  print -r -- "Stable local signing configured at $SIGNING_KEYCHAIN"
  exit 0
fi

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -keyout "$TEMPORARY_DIRECTORY/private-key.pem" \
  -out "$TEMPORARY_DIRECTORY/certificate.pem" \
  -days 3650 \
  -subj "/CN=$SIGNING_IDENTITY_NAME/O=DualSense Bridge Local Development" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

openssl pkcs12 \
  -export \
  -legacy \
  -out "$TEMPORARY_DIRECTORY/identity.p12" \
  -inkey "$TEMPORARY_DIRECTORY/private-key.pem" \
  -in "$TEMPORARY_DIRECTORY/certificate.pem" \
  -passout "pass:$SIGNING_KEYCHAIN_PASSWORD"

security create-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security import "$TEMPORARY_DIRECTORY/identity.p12" \
  -k "$SIGNING_KEYCHAIN" \
  -P "$SIGNING_KEYCHAIN_PASSWORD" \
  -x \
  -T /usr/bin/codesign
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$SIGNING_KEYCHAIN_PASSWORD" \
  "$SIGNING_KEYCHAIN" >/dev/null

# Register this self-signed certificate in the user's trust domain only for
# code-signing evaluation. The private key remains in the project keychain.
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$USER_DEFAULT_KEYCHAIN" \
  "$TEMPORARY_DIRECTORY/certificate.pem"

security verify-cert \
  -c "$TEMPORARY_DIRECTORY/certificate.pem" \
  -p codeSign \
  -L \
  -q

security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" \
  | grep -F "$SIGNING_IDENTITY_NAME"

chmod 600 "$SIGNING_KEYCHAIN"
print -r -- "Stable local signing configured at $SIGNING_KEYCHAIN"
