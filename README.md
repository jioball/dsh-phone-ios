# dsh-phone-ios

Native iOS wrapper for the dsh-phone PWA: a thin SwiftUI + WKWebView shell that
loads the phone client served by the DSH host plugin and keeps the full harness
brain (tools, sessions, voice, photos). All UI lives in the PWA; this project
only provides the installable, signed app around it.

- Host it loads: `https://babel.tail977397.ts.net:8443/`
- Minimum iOS: 16.0
- The pinned host's self-signed cert is trusted only for that hostname.

## Build (macOS or CI)

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project DSHPhone.xcodeproj -scheme DSHPhone \
  -configuration Release -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

Produces `build/Build/Products/Release-iphoneos/DSHPhone.app` (unsigned).

## Install on iPhone

- **Sideload**: AltStore / Sideloadly inject your free Apple ID certificate,
  or use Xcode with your own Team (macOS).
- **CI**: the included GitHub Actions workflow (`macos-14`) builds an unsigned
  `DSHPhone-unsigned.ipa` artifact on every push.

## Why not dsh-ios?

The community [dsh-ios](https://github.com/17521769724/dsh-ios) client is a
direct OpenAI-compatible API chat app — it cannot pair with the desktop DSH
host session, so it lacks tools, the agent loop, and your workspace. This
wrapper keeps the existing dsh-phone PWA (and its host pairing) intact.
