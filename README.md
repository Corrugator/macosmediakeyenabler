# MacOSMediaKeyEnabler

macOS Media Key Enabler for Music.app and Spotify.

Fork of [milgra/macmediakeyforwarder](https://github.com/milgra/macmediakeyforwarder), modernized for current macOS (Tahoe / macOS 26).

---

You can prioritize which app you would like to control or you can go with the default behaviour which controls the running app.
The app runs in the menu bar in the form of a subtle and beautiful black dot.

If you want even more control over what you want to control you should try [beardedspice](http://beardedspice.github.io)

Requirements: macOS 13 or newer. The app needs Accessibility permission (System Settings → Privacy & Security → Accessibility) to intercept the media keys — it asks on first launch and retries automatically once permission is granted.

---

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
