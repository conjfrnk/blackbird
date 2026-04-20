# `.signing/` — local code-signing artifacts

This directory holds local-only files needed to sign Blackbird and wire up
the release pipeline. **Contents are gitignored; never commit anything here
except this README.**

Typical contents:

| File | What it is |
|---|---|
| `developerID_application.cer` | Apple-issued public cert downloaded from developer.apple.com. |
| `CertificateSigningRequest.certSigningRequest` | The CSR uploaded when requesting the cert. |
| `DevID.p12` | Cert + private key exported from Keychain. Password-protected. |
| `DevID.p12.base64` | Base64 of the `.p12`, ready to paste into the `DEVELOPER_ID_P12` GitHub secret. |
| `PWORD.txt` | The export password for the `.p12`. Paste into `DEVELOPER_ID_P12_PASSWORD`. |

## If this gets lost

- The `.cer` is re-downloadable from developer.apple.com.
- The CSR can be regenerated via Keychain Access → Certificate Assistant.
- The `.p12` requires the matching private key in the login keychain. If
  the keychain is gone too, revoke the cert on developer.apple.com and
  issue a new one.
- The Sparkle EdDSA private key lives in the login keychain under
  `ed25519 private key for signing Sparkle updates`. Exporting via
  Keychain Access → right-click → Export is the backup path. Losing it
  means generating a new key pair — which invalidates every already-signed
  appcast entry.

## Do not

- Commit any file from here.
- Email or Slack the `.p12` or `PWORD.txt`.
- Store them in iCloud Drive, Dropbox, etc. unencrypted.
