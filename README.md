# MacOSMediaKeyEnabler

macOS Media Key Enabler for Music.app and Spotify.

Fork of [milgra/macmediakeyforwarder](https://github.com/milgra/macmediakeyforwarder), modernized for current macOS (Tahoe / macOS 26).

---

You can prioritize which app you would like to control or you can go with the default behaviour which controls the running app.
The app runs in the menu bar in the form of a subtle and beautiful black dot.

If you want even more control over what you want to control you should try [beardedspice](http://beardedspice.github.io)

Requirements: macOS 13 or newer.

The app needs two permissions, both requested automatically on first launch:
- **Accessibility** (System Settings → Privacy & Security → Accessibility) — to intercept the media keys. The app retries automatically once granted, no relaunch needed.
- **Automation** (System Settings → Privacy & Security → Automation) — to control Music / Spotify. If it is missing or denied, the app no longer swallows the key: the press is passed through to macOS so default media handling keeps working, and you get a one-off notification pointing you to the setting.

---

## Installation

Download the latest `MacOSMediaKeyEnabler-x.y.zip` from the [Releases](https://github.com/Corrugator/macosmediakeyenabler/releases) page, unzip it, and move the app to `/Applications`.

The app is **not signed with an Apple Developer ID** (notarization requires a paid account), so on first launch Gatekeeper will warn that it is from an unidentified developer. To open it anyway:

- **Right-click** the app → **Open** → confirm **Open** in the dialog (only needed once), or
- clear the quarantine flag in Terminal:
  ```sh
  xattr -dr com.apple.quarantine /Applications/MacOSMediaKeyEnabler.app
  ```

To start it automatically at login, use the **Open at login** menu item (the keyboard-keys icon in the menu bar).

---

What's new in version 2.1 :
- fixed: media keys no longer go dead — added the required Apple Events usage description so macOS actually permits controlling Music / Spotify
- backup: if automation permission is missing or denied, the key is passed through to the system instead of being swallowed, so media control keeps working
- a throttled notification points you to the right setting when control is blocked
- new menu bar icon (keyboard-keys glyph) instead of the inconspicuous dot
- login item can also be toggled headlessly via `--register-login-item` / `--unregister-login-item`
- removed unused icon assets

What's new in version 2.0 :
- renamed to MacOSMediaKeyEnabler (was: HighSierraMediaKeyEnabler)
- controls Music.app instead of iTunes
- play key starts library playback when Music is stopped or not running (was a no-op before)
- "Pause if no player is running" option works again (events are passed to macOS so web players keep working)
- next/previous no longer launch the player accidentally when nothing is running
- event tap creation retries automatically until Accessibility permission is granted — no manual relaunch needed
- login item uses the modern SMAppService API
- Russian and Danish localizations are actually bundled now; Korean strings updated from iTunes to Music
- duplicate menu separator removed
- built as universal binary (Apple Silicon + Intel) with the macOS 26 SDK

---

Contributors : Michael Dorner (michaeldorner), Matt Chaput (mchaput), Ben Kropf (ben-kropf), Alejandro Iván (alejandroivan), Sungho Lee (sh1217sh), Björn Büschke (maciboy), Sergei Solovev (e1ectron)

Thank you!!!

Original author: Milan Toth ([milgra.com](http://milgra.com)) — see LICENSE.

---

What's new in version 1.9 :
- added open at login menu option
- German localization update
- Korean localization update

What's new in version 1.8 :
- added pause menu option
- added pause automatically menu option : if no music player is running macOS default behavior is used and keys are forwarded to currently active media player
- Russian localization
- German localization
- Spanish localization
- fixed headphone button issue
- added macOS Sierra compatibility if you want explicit music player control there

What's new in version 1.7 :
- fast forward/rewind is possible when iTunes is selected explicitly
- Korean localization
- rumors say that it works with TouchBar

What's new in version 1.6 :
- increased compatibility with external keyboards

What's new in version 1.5 :
- now you can explicitly prioritize iTunes or Spotify
- play button now starts up iTunes or Spotify if they are not running aaaand explicitly selected

What's new in version 1.4 :
- memory leak fixed

What's new in version 1.3 :
- previousTrack replaced with backTrack in case of iTunes for a better experience

What's new in version 1.2 :
- new icon
- source code is super tight now
- developer id signed, its a trusted app now
