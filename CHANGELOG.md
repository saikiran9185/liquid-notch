# Changelog

## Unreleased

- **Shuffle and repeat in the player.** The player card has shuffle on the left and repeat beside AirPlay; repeat cycles off → all → one. They follow the player's own state (from Now Playing, or Music and Spotify by AppleScript) and work through the adapter for other players.
- **Scroll on the island.** Hover shows the music; one scroll down (two fingers or the wheel) opens the main menu, the tools on their own in the player's place; scroll up closes. Scrolling on a ball opens its card. Lists inside (lyrics, Clipboard, Shelf) still scroll as before.
- **A Tools button on the player**, and Tools and Player & Lyrics in the right-click menu: the tools were only a double-click on the notch itself away while music played. The right-click menu is grouped into Island, Appearance and Liquid Notch.
- **Click Opens Lyrics** (right-click menu, off by default): a click on the music opens the big player straight away.
- **Today in the tools.** A Today tool (labelled with your next event's time) opens the day from every calendar: all-day events on top, then each event with what's on now highlighted and its time left.
- **Overlapping events.** The event card shows the one that started last or is about to start, so lunch at 12:30 shows even while a 9:30–13:30 class runs, with "+N more now" and the event's calendar.
- **Choose your calendars.** Right-click › Calendars lists every calendar by account with its colour; untick one and its events leave the card, the ball, Today and the start alerts (new calendars show by default; Show All resets).
- **Event Start Alerts** (right-click menu, off by default): a moment in the notch as each event starts.
- **Your day, large.** Click the event card and your day opens at the lyrics player's size: what's on now on the left (time left large, a line bar, what's next) and the day as a timeline on the right, scrolled to now. Back shrinks it to the tools.
- **Event ears like the brightness HUD.** The ring and the time left on the left, a line progress bar on the right; hovering the event's ball shows the same strip with its title.
- **A scoreboard for events.** The event card shows the time left as a big figure, the event's progress as a bar (like a match's), and its calendar or who's in it.
- **The event ball counts down.** Beside the music, an event's ball is a ring: orange toward the start, then the calendar's colour emptying as it runs, red in its last 5 minutes; the ear and card say the time left.
- **Calendar access that takes.** Setup's Allow asked through a separate EventKit store, so the event watcher (made before the grant) kept showing nothing until its next boundary. Setup now asks through the watcher's own store, which resets and reads on the answer and whenever the app becomes active; when access hasn't been decided, the watcher asks once at launch.
- **Fixes.** The lock-screen art test no longer depends on the Mac's own login-window setting (and a test covers the layout with the account photo showing); a debug-description warning in the lock-art log is gone.
- **Volume and AirPlay in the full player.** The lyrics view gets shuffle and repeat beside the controls and a volume slider with the AirPlay picker under them, like iPhone's Now Playing. Dragging the volume up from mute unmutes.

## 1.1.2

- **Music bars in a Jam.** The bars follow the music again after a Spotify Jam or a song playing on another device. Before, a moment of silence could switch the real bars off for every song after it.
- **Shuffle.** Both players have a shuffle button, on the left of the controls.
- **Your day.** Click an event's card to see your whole day: what's on now with its time left, what's next, and every event today.
- **Overlapping events.** When two events overlap, the island shows the one that started last, so lunch shows up even in the middle of a long class.
- **Choose your calendars.** Right-click › Calendars lets you hide calendars you don't want in the island.
- **A peek at the event.** Hovering an event's ball shows its title, the time left and how far along it is.
- **Fixes.** Allowing Calendar in Setup shows your events right away, and dragging the volume up from mute unmutes. Thanks to saikiran9185 for these and for the ideas behind shuffle and the calendar.

## 1.1.1

- **No more repeated permission prompts.** If the music bars can't hear system audio, Liquid Notch stops asking again with every song. You can still turn it on from Setup.
- **The tools open while music plays.** Clicking the notch opens the tools even when a song is playing in an app that's in front.

## 1.1

- **Works on Macs without a notch.** On a MacBook Air or any Mac without a notch, Liquid Notch now draws its own island at the top of the screen, sized to fit the menu bar.
- **Choose where the island appears.** Right-click the island and pick Show On › Built-in Display or Main Display. Notch › Always Virtual uses the drawn island even on a Mac with a notch.
- **Follows your displays.** Plugging in or unplugging a monitor, changing resolution or closing the lid moves the island to the right screen right away.
- **Fits any menu bar.** Album art, icons and indicators scale to fit a shorter menu bar, so nothing hangs over your windows.
- **Music shows up with multiple displays.** A song keeps showing in the island when its player is on another display or minimized.
- **Smarter about where you're looking.** Calls, downloads, Claude sessions and notifications only step aside when their app is open on the island's display, so you don't miss them while working on another screen.
- **Runs natively on Intel Macs.** The app is now a universal build for Apple silicon and Intel.
- **A proper Mac app.** The first time you open it, Liquid Notch moves itself into your Applications folder. To remove it, right-click the island and choose Uninstall Liquid Notch…, which also takes away everything it set up.
- **Updates itself.** Liquid Notch now checks for new versions once a day and installs them for you. To check right away, right-click the island and choose Check for Updates….

## 1.0

- First release.
