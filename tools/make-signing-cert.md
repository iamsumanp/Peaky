# Local signing certificate

`build.sh` signs Peaky with a self-signed "Peaky Local Signing" certificate kept in its own keychain,
`~/Library/Keychains/peaky-signing.keychain-db` (password `peaky-local`, used only for this). Because the
signature identity stays the same across builds, macOS keeps Peaky's Calendar / Bluetooth / Accessibility
permissions after rebuilds. Nothing is added to the login keychain and no trust settings are changed.

Recreate it (if the keychain is deleted):

    openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
      -subj "/CN=Peaky Local Signing" -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false"
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "Peaky Local Signing" -out peaky.p12 -passout pass:peaky-local
    security create-keychain -p peaky-local ~/Library/Keychains/peaky-signing.keychain-db
    security set-keychain-settings ~/Library/Keychains/peaky-signing.keychain-db
    security unlock-keychain -p peaky-local ~/Library/Keychains/peaky-signing.keychain-db
    security import peaky.p12 -k ~/Library/Keychains/peaky-signing.keychain-db -P peaky-local -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k peaky-local ~/Library/Keychains/peaky-signing.keychain-db
    rm key.pem peaky.p12

To go back to ad-hoc signing, delete that keychain file.
