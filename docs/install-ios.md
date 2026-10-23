# Installing on an iPhone

Free provisioning, no paid Apple Developer account. The app will need reinstalling
every 7 days; your recorded sessions survive a reinstall.

## What you need

- Xcode installed (already done)
- An Apple ID — the free one is fine
- The iPhone and a USB cable
- The phone unlocked and trusted on this Mac

## One-time setup

1. Open the project:

   ```bash
   cd App
   xcodegen generate
   open OBDLogger.xcodeproj
   ```

2. Plug in the iPhone. If prompted on the phone, tap **Trust**.

3. In Xcode: **Window → Devices and Simulators** and confirm the phone appears.

4. Select the **OBDLogger-iOS** scheme at the top of the window, and choose your
   iPhone as the destination instead of a simulator.

5. Select the **OBDLogger** target → **Signing & Capabilities**:

   - Tick **Automatically manage signing**
   - **Team**: add your Apple ID if it is not listed (Add an Account…), then select
     it. It appears as *Your Name (Personal Team)*.
   - If Xcode complains the bundle identifier is not available, change it to
     something unique, e.g. `com.naleen.obdlogger1`. It only has to be unique to
     your account.

6. Press **Run** (⌘R).

## First launch on the phone

The app is unsigned by Apple, so iOS will refuse to open it until you approve it:

1. On the phone: **Settings → General → VPN & Device Management → Developer App**
2. Select your Apple ID and tap **Trust**
3. Launch **OBDLogger** from the home screen

Then allow Bluetooth when asked.

## Reinstalling every 7 days

The free provisioning profile expires after a week and the app stops launching.
Your data does not disappear.

- Reconnect the phone, open the project, press **Run**. This is an upgrade, not a
  fresh install — sessions in Application Support are preserved.
- Do **not** delete the app to "fix" it. Deleting removes its container, including
  every recorded session.
- Export important sessions to Files or iCloud before they matter. The app's
  Sessions view can share a ZIP at any time.

## Recording with the screen locked

The iOS target declares `bluetooth-central` background mode, so a recording
should continue while the phone is locked. This is **unverified** — the iOS build
has only been run in the simulator so far. Watch the session list after the first
locked-screen drive: if the session ends early, background mode is not holding and
that is a bug to report.

## If it fails to build

| Symptom | Cause |
|---|---|
| "Failed to register bundle identifier" | The ID is taken on your account. Change it in Signing & Capabilities. |
| "No signing certificate found" | No team selected, or the Apple ID is not signed in. |
| "Untrusted Developer" on launch | Approve it in Settings → General → VPN & Device Management. |
| App icon is missing on the home screen | Cosmetic; the asset catalogue builds for simulator but the device may cache. Reinstall once. |
