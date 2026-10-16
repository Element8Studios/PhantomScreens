# Installing Phantom Screens on your iPhone

Phantom Screens isn't on the App Store. You install it yourself with **Sideloadly**, a free tool that
signs the app with your Apple ID and copies it to your phone over a USB cable.
It takes about 15 minutes the first time.

## What you need

- An iPhone with **LiDAR** for the best results: iPhone 12 Pro or Pro Max or later Pro models.
  Other iPhones on iOS 17 or later still work, with less precise measuring.
- A **Windows PC or Mac**, used only for installing.
- A **USB cable** for your iPhone.
- An **Apple ID**. A free one works. A spare Apple ID is fine if you'd rather not use your main one.

## 1. Get the app file (.ipa)

Builds never run automatically. Start one when you want a new version, in any of these ways:

**GitHub Actions** (uses your Actions minutes; capped by your spending limit)
1. Open the repository on GitHub → **Actions** → **Build** → **Run workflow**.
   Leave **Also run unit tests** off unless you need them (they take about four times longer).
2. When the run has a green check, open it and download the artifact named like
   **PhantomScreens-v3.0-build01**. Unzip it to get the **.ipa**.

**Codemagic** (a hosted Mac with free monthly minutes; no Mac needed)
1. Sign in at codemagic.io with GitHub and add this repository. It reads `codemagic.yaml`.
2. **Start new build** → workflow **Phantom Screens IPA**. Download the .ipa from the build's Artifacts.

**Your own Mac** (free, about 2 minutes)
1. Install Xcode from the App Store and Homebrew from brew.sh.
2. In Terminal, in the project folder: `./scripts/build-ipa.sh`
3. The .ipa is in `build/ipa/`.

The build number shows in the app under **Settings → Version**.

## 2. Install Sideloadly on your computer

**Windows**
1. Install **iTunes** and **iCloud** from apple.com, *not* from the Microsoft Store.
   Sideloadly needs Apple's versions to talk to the phone. Restart the PC afterwards.
2. Download and install Sideloadly from **sideloadly.io**.

**Mac**
1. Download Sideloadly from **sideloadly.io** and drag it into Applications.
2. The first time you open it, macOS may ask you to allow it in
   **System Settings → Privacy & Security**. Click **Open Anyway**.

## 3. Connect your iPhone

1. Plug the iPhone into the computer and unlock it.
2. Tap **Trust** on the phone and enter your passcode.
3. Open Sideloadly. Your iPhone should appear in the device menu at the top.

## 4. Install Phantom

1. Drag the **.ipa** file onto the Sideloadly window (or click the IPA icon and pick it).
2. Type your **Apple ID email** into the Apple account box.
3. Click **Start**.
4. Enter your Apple ID password when asked, and the 6-digit code if you have two-factor sign-in.
   Sideloadly sends these only to Apple to create a free signing certificate.
5. Wait for **Done**. It takes a minute or two.

## 5. Allow it on your iPhone

1. **Turn on Developer Mode** (iOS 16 and later):
   **Settings → Privacy & Security → Developer Mode → On**. The phone restarts.
   After it restarts, tap **Turn On** and enter your passcode.
   If you don't see Developer Mode, do the install first and it will appear.
2. **Trust your Apple ID as a developer**:
   **Settings → General → VPN & Device Management**, tap your Apple ID under
   *Developer App*, then tap **Trust**.
3. Open **Phantom Screens** from the Home Screen. Allow **Camera** when asked.
   Allow **Photos** the first time you take a picture.

## Using Phantom Screens

1. Stand 2–3 m (6–10 ft) back from a door, window or outdoor opening and move the phone slowly.
2. When the outline turns solid amber and shows the size, tap **Place**.
   If it doesn't find the opening, tap it on screen, or tap **Corners** and mark two opposite corners.
3. The app picks the product from the size (single, double-French, oversized, window or motorized)
   and slides the screen partly open. **Drag the pull handle** (or use ▲ ■ ▼ on a motorized screen).
4. **Options** has every step already chosen for you: screen type, measurement, closure, mesh and color.
   Tap **Edit** on any step to change it.
5. Hold the **compare** button (top right) to see the opening without the screen.
6. **Photo** saves a picture. **Review** shows your order and sends it to a local Phantom expert,
   who quotes the price for your region.

## Every 7 days: reinstall

With a free Apple ID, Apple makes sideloaded apps stop opening after **7 days**.
Your saved designs stay on the phone. To keep using Phantom:

- Plug in, open Sideloadly and install the same **.ipa** or a newer build again (steps 3–4).
  No need to delete the app first.
- Or turn on Sideloadly's **auto-refresh** option. It reinstalls over Wi-Fi when your computer
  and phone are on the same network.

A paid Apple Developer account ($99/year) makes it last a year instead.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Sideloadly doesn't see the iPhone | Unlock the phone, tap Trust, try another cable or port. On Windows, reinstall iTunes from apple.com. |
| "Untrusted Developer" when opening | Do step 5.2 (VPN & Device Management → Trust). |
| App won't open or closes at once | Turn on Developer Mode (step 5.1). If it worked before, the 7 days have run out, so reinstall. |
| "Maximum number of apps" error | Free Apple IDs can have 3 sideloaded apps. Delete one you don't use. |
| Login fails in Sideloadly | Check your Apple ID password and use the newest Sideloadly. Wait a few minutes if you've tried many times. |
| Black camera screen | Settings → Phantom Screens → Camera → On. |
| Outline never appears | Step back so the whole opening and some wall around it are visible, turn on lights, tap the opening, or use Corners. |
| Measurement looks off | Drag a corner of the screen, or adjust it in Options → Measurement. Your Phantom expert measures on site before ordering anyway. |

## Getting a better fit

- If it keeps finding the wrong opening, tap inside the one you want. To search only after a tap,
  turn on **Settings → Advanced → Wait for a tap before finding**.
- **White balance:** the app matches the frame's white to your trim automatically when the screen
  appears, and keeps checking quietly as the light changes. To do it by hand:
  **Settings → Advanced → Pick the trim by hand**, aim the circle at your trim and tap **Match white**.
- **Color:** **Options → Color** suggests the standard color closest to your trim. **Custom Color**
  lets you pick any color or match your trim with the camera; it's noted in your order.
- **Outdoors:** turn on **Settings → Advanced → Outdoor sun shadows** (asks for your location) so shadows fall
  the same way as the real sun. Choose **In shade** if the opening is under a porch roof.

- After placing, touch a **corner of the screen** and drag it onto the real corner. Handles show
  while your finger is down. **••• → Edit corners** shows all four handles at once.
  Corners snap to nearby surfaces, so you can fix a screen that looks turned or tilted.
- Closed doors are found too: aim at (or tap) the door and move the phone slowly for a moment
  so ARKit can recognise it. With the door open, the open leaf no longer throws off the edges.
- **Settings → Advanced → Placement** has Re-fit to the wall, and Turn / Depth nudges in ½° and
  1 cm steps. Turn off **Keep plumb** for walls that lean, which adds Tilt and Twist.
