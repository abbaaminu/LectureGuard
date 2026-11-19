# LectureGuard

## Keeping Student Pass Mode on screen

Pass Mode uses Android screen pinning while the lecturer session is locked. The
lecturer PIN is required to stop app-initiated pinning and leave Pass Mode.

On iPhone and iPad, apps cannot enable Guided Access programmatically. Before
using Pass Mode, enable **Settings → Accessibility → Guided Access**, open
LectureGuard, and start Guided Access with the configured side-button or Home
button shortcut. End Guided Access using the device passcode when the session
is complete.

For school-managed iOS devices, use the MDM provider's supervised **Single App
Mode** policy to keep LectureGuard in the foreground. Configure and test the
policy on the managed device; the lecturer PIN does not override an MDM
restriction.
