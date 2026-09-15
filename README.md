# MinusOne

MinusOne is a macOS menu bar app for practicing along with music.

It has two parts:

- **Live** removes the vocals from any audio playing on your Mac.
- **Practice** splits a song into vocals, drums, bass, and other, so you can mute, loop, and slow down each part.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Menu bar](#menu-bar)
- [Live](#live)
- [Practice](#practice)
- [Appearance](#appearance)
- [Build from source](#build-from-source)
- [Credits](#credits)

## Requirements

- macOS 14 or later.
- macOS 14.2 or later to record system audio or choose which apps Live affects.
- The Demucs model (about 200 MB), downloaded on first launch.
- [BlackHole 2ch](https://existential.audio/blackhole/), only on macOS versions before 14.2.

## Install

1. Download the latest `MinusOne-*-macos.dmg` from [Releases](https://github.com/cro64/MinusOne/releases).
2. Open the disk image and drag **MinusOne** into **Applications**.
3. Open MinusOne from Applications.
4. On the welcome screen, click **Download & Continue** to get the model.

You can skip the download and get it later from the Live tab. Live and Practice both need the model.

### If macOS blocks the app

MinusOne is not notarized, so macOS may say it is damaged or cannot be opened.

**Option A**

1. Try to open the app once.
2. Open **System Settings → Privacy & Security**.
3. Click **Open Anyway** next to the MinusOne message.

**Option B**

```bash
xattr -cr /Applications/MinusOne.app
open /Applications/MinusOne.app
```

## Menu bar

| Action | Result |
|---|---|
| Click the icon | Opens the menu |
| Right-click or Control-click the icon | Turns Live on or off |
| ⌘⌥M | Turns Live on or off |

The menu has four items:

| Item | What it does |
|---|---|
| **Live** | Turns vocal removal on or off |
| **Record** | Starts or stops recording system audio |
| **Open MinusOne…** | Opens the main window |
| **Quit** | Quits the app |

### Icon

| State | Meaning |
| --- | --- |
| **Off** | Live is off |
| **On** | Vocals are being removed |
| **Warming up** | The model is loading |
| **Permission needed** | Grant access in System Settings |
| **Error** | Something went wrong |

## Live

Live removes vocals from whatever is playing on your Mac. Nothing is recorded or saved.

Open the main window and choose the **Live** tab to change its settings.

| Setting | What it does |
|---|---|
| **Intensity** | How much of the vocals to remove, from 0 to 100% |
| **Gain** | Makes the result louder, from 0 to 12 dB (default 4.5 dB) |
| **Scope** | **All Apps**, or **Custom** for only the apps you pick |
| **Capture** | The list of apps to process when Scope is Custom |

Things to know:

- Audio plays about 10 seconds behind while Live is on.
- Live warms up again after a track changes.
- Custom scope needs macOS 14.2 or later.

### Permissions

| Setup | Permission to grant |
|---|---|
| macOS 14.2 or later | System Audio Recording |
| BlackHole | Microphone |

## Practice

Open the main window and choose the **Practice** tab.

The library of clips is on the left. The deck for the selected clip is on the right.

### Add a clip

| Way | How |
|---|---|
| Import | Click the import button above the search field |
| Drag and drop | Drop an audio file onto the library |
| Record | Click the record button above the search field |

MinusOne opens MP3, WAV, AIFF, and M4A files.

After you add a clip, MinusOne splits it into four stems in the background. You can play the clip while this runs.

### Record

| Setting | What it does |
|---|---|
| **Input source** | **System audio**, or any microphone or input device |
| **Auto-stop** | Stops recording after the minutes and seconds you set |

- You can also set the auto-stop time by dragging on the live waveform.
- Recording keeps going if you leave the Record page.
- While recording, a timer replaces the search field in the library. Click it to return to the Record page.
- The record button turns into a stop button while recording.
- Press Escape to leave the Record page.
- The finished recording appears in your library.

### Library

| Action | How |
|---|---|
| Find a clip | Type in the search field |
| Rename a clip | Double-click it, right-click and choose **Rename…**, or click its title in the deck |
| See what is playing | Look for the speaker icon next to the clip |
| Hide or show the library | Click the sidebar button in the title bar |

### Deck

| Control | What it does |
|---|---|
| Play / Pause | Starts or pauses the clip |
| Back / Forward | Jumps 5 seconds |
| Loop | Repeats the selected section |
| Tempo slider | Slows the clip down, from 50 to 100% |
| **BPM** | Shows the tempo, and you can type a new one |
| **Tap** | Sets the tempo from your taps |
| Waveform button | Shows or hides the overview waveform |

### Timeline

The timeline shows one lane per stem.

| Action | Result |
|---|---|
| Click | Jumps to that point |
| Drag | Selects a loop that snaps to the beat |
| ⌥ + drag | Selects a loop without snapping |
| Scroll sideways | Moves through the song |
| ⌘ + scroll, or pinch | Zooms in and out |
| Drag the downbeat marker on the ruler | Moves the beat grid |

### Overview waveform

The overview waveform shows the whole song above the timeline.

| Action | Result |
|---|---|
| Click | Jumps to that point |
| Drag | Selects a loop |
| Drag inside the zoom box | Moves the zoomed view |
| ⌘ + scroll, or pinch | Zooms the timeline |
| Drag the bottom edge | Changes its height |

### Stems

Each lane has its own controls.

| Control | What it does |
|---|---|
| Fader | Sets the stem's volume |
| Switch | Coral means the stem plays. Grey means it is muted. |
| ⌘ + click the switch | Plays only this stem |
| Export button | Saves the stem as WAV, AIFF, or M4A |

The export button turns on when the stem has finished processing.

## Appearance

Click the theme button in the title bar to switch between System, Light, and Dark.

## Build from source

```bash
Scripts/build-app.sh release     # builds build/MinusOne.app
Scripts/download-model.sh        # downloads the model without the welcome screen
```

Logs are saved to `~/Library/Logs/MinusOne/MinusOne.log`.

## Credits

- The model is [Demucs](https://github.com/facebookresearch/demucs) by Meta.
- MinusOne uses the CoreML build of Demucs by [dexxdean](https://huggingface.co/dexxdean/htdemucs-coreml).
- MinusOne is released under the [MIT License](LICENSE).
