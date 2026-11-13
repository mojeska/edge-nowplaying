# Edge Now Playing

Shows what Apple Music is playing on a **Corsair Xeneon Edge** touchscreen bar connected to a Mac. No iCUE needed.

![Edge Now Playing on a 2560×720 display, with sample artwork](docs/preview.png)

- Album artwork, title, artist and album, with a progress bar and the time left
- A spectrum visualizer behind the text: one line for the left channel, one for the right, tinted to match the artwork
- A clock and date, which fill the screen when nothing is playing
- Fills the Edge on its own and leaves your main display alone

Corsair's widgets for the Edge need iCUE, which doesn't work on macOS. To macOS the Edge is just a second display, so this app draws straight onto it.

This is an independent project, not affiliated with or endorsed by Corsair, Elgato or Apple.

## Requirements

- macOS 14.2 or later, on Apple Silicon or Intel
- A Xeneon Edge (or any display at least three times wider than tall) connected as a second display
- The Music app

## Install

1. Download `EdgeNowPlaying-<version>.zip` from [Releases](../../releases) and unzip it.
2. Drag **Edge Now Playing** into your **Applications** folder.
3. Open it. The app isn't notarized by Apple, so macOS blocks it the first time:
   - **macOS 15 or later:** open **System Settings → Privacy & Security**, scroll down to the message about Edge Now Playing, and click **Open Anyway**.
   - **macOS 14:** right-click the app and choose **Open**, then **Open** again.
4. Play something in Music. macOS asks two questions; allow both:
   - **Control "Music"**: to read the song and the artwork.
   - **Record audio from Music**: for the visualizer. It only measures how loud each frequency band is; nothing is recorded or saved.

Changed your mind? Both are under **System Settings → Privacy & Security** (Automation, and Screen & System Audio Recording).

## Using it

- **Quit:** right-click its Dock icon and choose Quit, or press ⌘Q while it's in front.
- **Settings:** click the Dock icon (or open the app again) for **Start at Login** and **Show in Dock**. There's also a menu bar icon with the same options.
- **Play, pause, skip:** use your keyboard's media keys, or a Stream Deck's Multimedia actions. The Edge's touchscreen isn't used (see below).
- The app never opens Music itself; it only reads Music while Music is running.

## Why the touchscreen isn't used

macOS treats the Edge's touch panel as an absolute mouse mapped to the **main** display, so a tap on the Edge moves the pointer and clicks on your main screen instead. An app can read the touches and block their clicks, but it can't stop the pointer from jumping. The panel also ignores the standard HID switch to touch mode. Paid touchscreen drivers can remap it; this app stays display-only.

Details, for anyone who wants to dig further: the controller reports as `TouchScreen`, vendor ID 10176 (0x27C0), product ID 2137, with a vendor interface (usage page 0xFF0A), an absolute mouse (X 0–16383, Y 0–9599) and a 15-contact digitizer. macOS drives the pointer from the mouse interface through its DriverKit HID driver; seizing the device doesn't stop that.

## Build from source

Needs Xcode or the Command Line Tools.

```sh
./make-cert.sh        # once per Mac: a local signing certificate, so rebuilds keep the permissions
./build.sh --install  # builds a universal app, installs it to /Applications and opens it
```

Without the certificate the build is ad-hoc signed, and macOS asks for the permissions again after every rebuild.

`./release.sh` builds and zips the app for a release. To check the layout without an Edge attached:

```sh
"$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/EdgeNowPlaying" --render out.png [artwork.jpg]
```

## How it works

- **Song info:** AppleScript to Music, every 2 seconds and whenever Music announces a track change.
- **Visualizer:** a Core Audio process tap on Music (macOS 14.2+), a 2048-point FFT with Accelerate, and 56 bands from 35 Hz to 16 kHz with automatic gain.
- **Display:** a borderless window on the Edge, found by name, that follows display changes.

## License

[MIT](LICENSE)
