# Editing by hand

The automatic draft gets you most of the way. This page covers the tools for the rest.

## Layout

- **Browser** (left; toggle it with the sidebar button in the toolbar). It has three tabs:
  - **Media**: your library clips.
  - **Music**: your music library.
  - **Titles**: text styles.
- **Viewer** (middle). The preview is rendered by the same compositor as the export.
- **Inspector** (right). Shows the selected item's properties, or the timeline's when nothing is selected.
- **Timeline** (bottom). Tracks from top to bottom: captions, titles, overlays, the main video, then audio and music.

## Adding things

| How | What happens |
|---|---|
| Drag from the browser onto a track | **Overwrites** what's there at that spot. A white ghost shows where it will land. |
| ⌥-drag onto a track | **Inserts**: everything after the drop point moves later, on every track, so captions and music stay in sync. |
| Drag below the tracks | **Connects** the item on a free track, adding one if needed. Nothing else moves. |
| Select in the browser, then press **Q / W / E / D** | Connect at the playhead / insert at the playhead / append to the end of the main track / overwrite at the playhead (as in Final Cut Pro). |
| **⌃T** or the toolbar's **Text** button | Adds a 3-second text at the playhead in the timeline's title style. Edit it in the inspector. |

Music added by hand gets its CC-BY credit added to the timeline, just as drafted music does.

## Cutting and trimming

- **B** or **⌘K** splits the selected clips at the playhead; with nothing selected, it splits every track. **⇧B** always splits every track.
- **⌫** deletes. It follows the toolbar's **Ripple** toggle: with ripple on, the gap closes.
- **⇧⌫** always ripples. **⌥⌫** always leaves a gap.
- Drag a clip's edge to trim it. Holding ⌥ inverts the ripple setting.
- **⌥[** and **⌥]** trim a clip's start or end to the playhead. They act on the selected clip, or on the clip under the playhead.
- **,** and **.** nudge the selection one frame. Held down, they repeat.

### In and Out

**I** and **O** mark a range, shown in yellow. **X** marks the clip under the playhead. With nothing selected, **⌫** removes the marked range from every unlocked track:

- With ripple on, it's an *extract*: everything after the range moves left.
- With ripple off, it's a *lift*: a gap is left.

**⌥X** clears the marks.

## Moving around

- **Space** plays or pauses.
- **J / K / L**: J plays backwards, K pauses, L plays forwards. Press J or L again to double the speed, up to 8×.
- **← / →** step one frame. **⇧← / ⇧→** step ten frames.
- **↑ / ↓** jump to the previous or next cut. Caption pages are skipped.
- **Home / End** go to the start or end of the timeline.

## Clipboard

**⌘C / ⌘X / ⌘V / ⌘D** copy, cut, paste and duplicate.

- Paste puts the copies at the playhead, keeping their spacing. Each copy goes on its original track if that spot is free, otherwise on a free track. **Paste never overwrites anything.**
- Duplicate places the copies right after the selection.
- The clipboard works across projects within a session.

## Speed

Right-click a clip and choose **Speed** for presets from 25% to 400%. The inspector's **Speed** slider works too, from 25% to 400% in steps of a whole percent.

- The clip gets shorter or longer from its start, and audio keeps its pitch.
- With ripple on, the clips after it on the same track move to make room. With ripple off, a slowed clip can't grow into the next clip; you'll get an error instead.

## Keyframes

Every slider in the inspector's **Transform** and **Audio** sections can be animated: scale, zoom, X/Y, rotation, opacity and gain.

1. Move the playhead over the clip.
2. Click **◆** next to a property to add a keyframe there. Click the filled ◆ to remove it.
3. Once a property has keyframes, dragging its slider sets the value at the playhead, adding a keyframe if there isn't one.
4. Use **‹ ›** to jump between that property's keyframes.

Keyframes appear as yellow diamonds along the bottom of the clip on the timeline. Punch-ins and reframes from the draft are keyframes too, so you can adjust them the same way.

## Re-draft

Click **Re-draft** in the toolbar to run the automatic draft again on the same clips. You can pick another template, another variation (which changes the music and other choices), a new title, or captions/music on or off.

- **Kept:** items you added, locked items, and everything on locked tracks. They stay where they were.
- **Replaced:** everything else.
- Track settings (mute, hide, lock, gain) are kept.
- Translated caption tracks are rebuilt from scratch, so translate again afterwards.
- It's a single undo step, so **⌘Z** goes back.

Lock an item with **⌘L** or the inspector's **Locked** switch.

## Shortcuts

Every action above can be rebound in **Settings ▸ Shortcuts**:

- Click **+** next to an action and press the keys.
- Click **×** on a shortcut to remove it.
- Click **Reset** to restore the factory shortcuts (per action, or all at once).
- Taking a key that another action uses moves it to the new action, and Clipper tells you which action lost it.

Notes:

- Single-key shortcuts (B, J, K, L, …) work anywhere in the editor window except while you type in a text field.
- Shortcuts using ⌘ or ⌃ also show in the **Playback** and **Timeline** menus.
- Only your changes are saved (in `settings.json`, under `keyBindings`), so new actions in future versions get their defaults automatically.

## For development: scripted smoke tests

Debug builds can drive the editor from a script, which is useful when you can't click (for example in CI or over SSH):

```sh
CLIPPER_LIBRARY=/tmp/Test.clipperlib CLIPPER_DEBUG_SCRIPT=script.txt \
  App/build/Build/Products/Debug/Clipper.app/Contents/MacOS/Clipper
```

The full command list is at the top of `App/Clipper/Models/DebugScript.swift`. It includes:

- `open`, `seek`, `key`, `action`
- `browse`, `drop`
- `select`, `keyframe`, `redraft`, `bind`
- `dump`, `settings`, `quit`

`key` posts a real key event, so shortcut routing gets exercised too. Use a scratch library made with `clipper import/draft --library …`. Never point the script runner at your real library.
