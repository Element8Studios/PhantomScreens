# Phantom Screens

An iPhone AR app that finds and measures a door, window or outdoor opening and shows
a Phantom retractable screen in it at true scale, in real time. Built with SwiftUI,
ARKit and RealityKit, with a Liquid Glass interface on iOS 26 (and a material fallback
on iOS 17–25).

**To put it on your phone, follow [INSTALL.md](INSTALL.md).**

## What it does

1. **Find the opening.** On LiDAR iPhones, depth is measured against ARKit's wall plane,
   so the room beyond and an open door leaf don't throw off the edges. Closed doors are
   found from ARKit's door and window labels, or as a rectangle in the camera image when
   the door blends into the wall. Tap an opening to point the search at it,
   or mark two corners by hand. Other iPhones look for the frame's outline.
2. **Place.** The app suggests the product from the size, the sill height and whether it's
   indoors or out: Single, Sliding, Double-French or Oversized Door Screen, Window Screen, or
   a Motorized Screen for porches and patios. It picks inside-jamb or surface mount from how
   deep the door sits behind the trim. It fades in once ARKit is tracking it and balances the
   frame's white once to the room's light (the brightest neutral surfaces in view, without
   assuming the trim is white).
3. **Open and close it.** Drag the pull handle (or the bottom bar of a motorized screen,
   which also has ▲ ■ ▼ controls). Touch a corner of the screen and drag it to fine-tune.
   Hold **compare** to hide it.
4. **Customize** covers the options on phantomscreens.com, with everything pre-chosen. The
   option bar above the toolbar shows each current choice; tapping one opens a short tabbed
   sheet on it, so the screen stays in view:
   - **Screen type**: Door Screen or Door Screen with Mesh Lock, and the retract side.
   - **Measurement**: the measured size and the matching height and width bands.
   - **Closure**: Latching Handle (preselected), Latching Handle with Latch Stop, Magnet Handle.
   - **Control** (motorized): remote, wall switch or smart home.
   - **Mesh**: Insect, or a custom mesh (pet, sun & heat, privacy).
   - **Color**: the ten standard colors, wood grain, a custom color (pick it, or tap the
     eyedropper to match any real color with the camera) or "decide later". The closest
     standard color to your trim is suggested.

   Options say **Included** or **Additional cost**; there are no prices, since they vary by
   region.
5. **Review** shows a snapshot of the screen in the opening and every selection (tap one to
   change it), then **Request a Quote** sends it with your photos to a local Phantom expert,
   found with Apple Maps. Sent designs are kept in **Saved designs**.

Everything for tuning and testing (detection, corners, placement nudges, lighting, white
balance, a debug overlay) is under **Settings → Advanced**.

## The catalog

Products, options, size bands and colors are in `Phantom/Model/Catalog.swift`. Size limits
come from Phantom's published specs. The on-screen colors are approximations; adjust
`FrameFinish.uiColor` to match real swatches.

## Building

Builds never run on push. Pick one:

| Where | How | Cost |
| --- | --- | --- |
| GitHub Actions | Actions → **Build** → Run workflow (tests are an opt-in checkbox) | Actions minutes |
| Codemagic | Add the repo at codemagic.io, start **Phantom Screens IPA** | Free monthly minutes |
| Your Mac | `./scripts/build-ipa.sh` (tests: `./scripts/test.sh`) | Free |

All three produce the same unsigned IPA for Sideloadly. To run from Xcode instead:

```sh
brew install xcodegen
xcodegen
open Phantom.xcodeproj
```

Pick your team under Signing & Capabilities and run on a device. AR doesn't run in the
Simulator.

## App icons

Four Home Screen icons, chosen in **Settings → App icon**: Classic (default), Pattern, Light and
Cyan. All are built from the vector mark in `Brand/vector/`; see `Brand/README.md`.

## Layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated)
codemagic.yaml              Codemagic workflows (manual start only)
scripts/                    build-ipa.sh and test.sh for a Mac
Brand/                      logo sources, vector mark and icon scripts
Phantom/
├── App/PhantomApp.swift
├── AR/
│   ├── PhantomSession.swift     AR session, detection, placement, touches, lighting
│   ├── DepthDetection.swift     LiDAR detection against the wall plane, door/window labels
│   ├── OpeningGeometry.swift    corners -> opening frame, edge finding (unit-tested)
│   ├── ScreenDoorEntity.swift   procedural door, window and motorized screens
│   ├── WhiteMatch.swift         matching the frame's white to the real trim
│   ├── ColorPicking.swift       centre-screen color picker
│   └── SunLight.swift           outdoor sun direction
├── Model/                  catalog, configuration, units, saved designs
└── Views/                  Options, Review, Settings, introduction and the AR overlays
PhantomTests/
```

## Limits

- LiDAR reaches about 5 m, so large outdoor openings may need the corners marked by hand.
- LiDAR can't see glass, so windows are measured from the frame around the glass.
- Closed doors are found once ARKit has recognized them, which takes a moment of scanning.
- Colors are approximations of Phantom's finishes, and the expert search only finds
  businesses Apple Maps lists under "Phantom Screens".
