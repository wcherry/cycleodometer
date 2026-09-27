# Routes & Maps

**Status:** Proposed · **Date:** 2026-09-26 · **Applies to:** Cycle Odometer iOS app (**iOS 26+**)

> **Prerequisite:** raise the app's deployment target from iOS 17 to **iOS 26**
> (`options.deploymentTarget.iOS` in `project.yml`). Phones that can't run iOS 26
> won't be able to install new versions. In exchange, everything below can use
> iOS 26 APIs directly, with no `#available` checks or fallback code paths.

## Summary

Record the path of every ride, show it on a live map during the ride, and let a
past ride (or an imported GPX file) be saved as a **route**. A saved route can be
shared to other mapping apps, and followed on a later ride with the route drawn
under your track, progress along it, an alert when you stray off it, and turn cues
on both the map and the gauge screen. You can also navigate to a searched-for place
with Apple's cycling directions, and a Live Activity keeps speed and distance in
view on the Lock Screen and in the Dynamic Island, including while you navigate
in Google Maps or Apple Maps.

## Decisions so far

| Question | Decision |
|---|---|
| Where does a route come from? | Any ride in **Ride History** ("Save as Route"), or an **imported GPX file**. Not offered at the end of a ride. |
| When is a route chosen for following? | **Before starting** the ride, from the start screen. It can't be changed mid-ride. |
| How does the live map appear? | **Full-screen, toggled** from the ride screen, with a compact stats strip. The gauge screen also shows **turn cues** when following a route. |
| What guidance is given? | **Progress** (done / remaining / %), **off-route alerts**, and **turn cues**. |
| Can Google/Apple Maps do the routing, with their cues shown in our app and our speed/distance shown over their map? | **No**, neither half is possible on iOS (see [Handing navigation to Google or Apple Maps](#handing-navigation-to-google-or-apple-maps-evaluated)). **Both alternatives are adopted instead:** our own [Navigate to a place](#navigate-to-a-place), and a [Live Activity](#live-activity) that shows our numbers while you navigate in Google or Apple Maps. |

## Goals

- Record a GPS track for each ride, stored alongside the existing ride history.
- A full-screen live map of the current ride, reachable in one tap from the ride screen.
- Save any recorded ride as a named route; import routes from GPX files.
- Share a route to other apps, and open it in Google Maps or Apple Maps as far as those apps allow (see [Platform limits](#platform-limits-sharing-to-mapping-apps)).
- Follow a route: overlay, progress, off-route alerts, and turn cues.
- Navigate to a place: search for a destination, get Apple's cycling directions, and ride with our turn cues, map and speed/distance.
- A Live Activity (Dynamic Island and Lock Screen) showing speed, distance and time on every ride, including while navigating in Google Maps or Apple Maps.
- Everything except map tiles works offline, on the device.

## Non-goals (for now)

- Route *planning* (drawing a new route on a map). Plan in Komoot, Strava, Ride with GPS, etc. and import the GPX.
- General-purpose navigation to any destination, like Google or Apple Maps give. Apple's cycling directions are used only to *annotate* the route with street names, get you to its start, and get you back onto it (see [Turn cues](#turn-cues)). They never replace a saved route. [Navigate to a place](#navigate-to-a-place) covers the everyday "get me there" case; multi-stop trips, avoiding hills and similar routing options stay out of scope.
- Syncing routes between devices, or accounts.
- KML/FIT/TCX import. GPX only.
- Downloading map tiles for offline use (MapKit has no supported way to do this).

---

## Platform limits: sharing to mapping apps

This is the part of the request the platform constrains most, so it's worth being
explicit. **Neither Google Maps nor Apple Maps on iPhone can import a recorded
track.** What each one can do:

| Target | Can it show *your exact route*? | What we can do |
|---|---|---|
| **Apple Maps** | No. Apple Maps has no GPX or track import on any iOS version. | Open **cycling directions** to the route's start or its finish with a unified Maps URL, e.g. `https://maps.apple.com/directions?destination=LAT,LON&mode=cycling` (always available at iOS 26), or `MKMapItem.openMaps(with:launchOptions:)` with `MKLaunchOptionsDirectionsModeCycling`. Apple chooses its own path. The unified URL format lists a `waypoint` parameter; whether it accepts several stops needs verifying on a device before we rely on it. |
| **Google Maps app** | Not from the phone. Google's GPX/KML import is **Google My Maps**, which has no iPhone app. A map made there on a computer *does* then show in the Google Maps app (You → Maps). | Open **approximate** cycling directions through a sample of the route: `https://www.google.com/maps/dir/?api=1&origin=…&destination=…&waypoints=A\|B\|…&travelmode=bicycling`. Google allows **up to 9 waypoints** (only **3** if the link opens in a mobile browser), so a long route is reduced to its most important points and Google fills in the rest; it can take different roads. We can also export **KML** for someone who wants to import it into My Maps on a computer. |
| **Route apps** (Strava, Komoot, Ride with GPS, Gaia GPS, WorkOutDoors, …) | **Yes**, exactly. | Share a **GPX file** through the system share sheet. |
| **Files, AirDrop, Mail, Messages** | Yes, as a file. | The same GPX file via the share sheet. |

So the route's **Share** menu will offer:

1. **Share GPX File…**: the exact route, for route apps, Files, AirDrop and so on.
2. **Open in Google Maps**: labelled *approximate*. Up to 9 waypoints picked at the route's biggest turns, not evenly spaced (see [Waypoint sampling](#waypoint-sampling-for-google-maps)).
3. **Directions to Start in Apple Maps / Google Maps**: for riding to a route's start. The app can also do this itself (see [Start screen](#start-screen)); handing off is for people who prefer those apps' navigation.
4. **Export KML…**: for Google My Maps on a computer. Lower priority; could be cut.

### Waypoint sampling for Google Maps

Evenly spaced points miss the turns that matter. Instead: simplify the route with
Douglas–Peucker, increasing the tolerance until at most 9 interior points remain,
then use those as `waypoints`. This keeps the corners where Google would otherwise
choose a different road. Loops need care: origin and destination are the same
point, so the sampled waypoints are what stop Google from returning a zero-length
route.


## Handing navigation to Google or Apple Maps (evaluated)

**The idea:** send a start and an end point to Google Maps or Apple Maps, let them
work out the route, show their turn-by-turn cues on our gauge screen, and be able to
switch to their map with our speed and distance shown over it.

**Verdict: not possible as described.** Each half runs into an iOS or map-app limit:

| Part of the idea | Possible? | Why |
|---|---|---|
| Send start and end to Google/Apple Maps | **Yes** | The URLs in [Platform limits](#platform-limits-sharing-to-mapping-apps) do this. It's a one-way handoff: their app opens and takes over. |
| Get their turn-by-turn cues back into our app | **No** | Neither app has any API that shares its route or navigation steps with other apps. A link opens them and nothing comes back. Google's `comgooglemaps-x-callback://` scheme can call back into our app, but nothing in its documentation provides route or step data. Confirm on a device before ruling it out completely. iOS apps can't read another app's screen or notifications. |
| Show our speed/distance over their map | **No, not as an overlay** | iOS doesn't let an app draw on top of another app. The nearest legitimate equivalent is a Live Activity (below). |

### What we'll build instead

Options 1 and 2 are **adopted** (their user experience is under
[Navigate to a place](#navigate-to-a-place) and [Live Activity](#live-activity)).
Options 3 and 4 were considered and **rejected**.

**1. Our own "navigate to a place" (adopted).** Everything the idea wants, inside
our app:

- **Picking a destination:** search with MapKit's `MKLocalSearch`, or drop a pin.
- **Routing:** `MKDirections` with `transportType = .cycling` from where you are. This is **Apple's own cycling route**, the same routing engine as Apple Maps, so handing off to Apple Maps would add nothing.
- **During the ride:** the route's steps (`MKRoute.Step`, with street names) drive the turn cue card on the gauge screen, and the full-screen map shows the route with our speed/distance strip. It's the same screens as following a saved route, with the route coming from Apple instead of a GPX file.
- **Off route:** request a new route from your position. For a one-off destination, rerouting is the right behaviour (unlike a saved route, where we steer you back onto it).
- **Limits:** it needs network to plan and reroute, and depends on Apple's cycling coverage in your area. Once planned, cues keep working offline until you leave the route.
- **Saving:** the route can be saved to the Routes library like any other, so a good one can be ridden again.

**2. Live Activity while using Google or Apple Maps (adopted).** If you'd rather navigate in
Google Maps or Apple Maps, the app can still show its numbers alongside them:

- **Where it shows:** the **Dynamic Island**, with speed in the compact view and speed, distance and time when expanded, and the **Lock Screen**.
- **How:** a ride starts an ActivityKit Live Activity, and the app updates it from the background. It's already running there for GPS.
- **Limits:**
  - It isn't an overlay on their map; it sits in the Dynamic Island above it.
  - iOS decides how often it refreshes, so expect updates every few seconds, not every second.
  - If Google or Apple Maps is also showing a navigation Live Activity, the two share the Dynamic Island.
  - A Live Activity ends after about 8 hours.
- **Worth doing anyway:** it's useful even without a route, e.g. glancing at speed with the phone locked.

**3. Picture-in-picture window (rejected).** Rendering the gauge into a
floating video window (`AVPictureInPictureController` with a sample-buffer
source) would float our speed over any app. A few apps do this, but picture-in-picture
is meant for video and calls, so App Review may reject it. It also costs battery.

**4. Google's own directions inside our app (rejected).** Google's Routes API
could supply Google's cycling route and steps, but it needs an API key and paid
billing. Google's terms also require Google content to be shown on a **Google** map,
which means adding the Google Maps SDK alongside MapKit. The Google Navigation SDK
(full turn-by-turn) is aimed at business fleet use under a separate agreement.
That's a lot of cost and complexity to swap Apple's cycling route for Google's.

---

## User experience

### Start screen

```
┌──────────────────────────────┐
│                          ⚙︎   │
│                              │
│         ( START RIDE )       │
│                              │
│   [ Ride a Route ]           │
│   [ Navigate To… ]           │
│   [ Ride History ]           │
└──────────────────────────────┘
```

- **Ride a Route** opens the **Routes** library (below), in pick mode. Choosing a route starts the ride with that route loaded.
- **Far from the start:** if you're more than about 200 m away, the pick screen shows the distance and offers:
  - **Ride to Start**: the ride begins with an **approach leg**. Cycling directions from where you are to the route's start (`MKDirections`, `transportType = .cycling`) are drawn on the map as a dashed line, with their own turn cues. Following the route takes over when you reach its start.
  - **Open in Apple Maps / Google Maps**: hands off instead.
  - **Start Anyway**: no approach leg. Progress begins when you first reach the route.
- **Offline or no cycling coverage:** if the directions request fails, Ride to Start falls back to a straight-line bearing and distance to the start.

### Navigate to a place

- **Start screen → Navigate To…** opens a search sheet: a search field (`MKLocalSearch`, using `MKLocalSearchCompleter` for suggestions as you type), recent destinations, and **Drop a Pin** on a map.
- **Choosing a place** shows a preview: Apple's cycling route on a map, with distance and estimated time. If Apple returns alternative routes, you can pick one. **Go** starts the ride.
- **During the ride:** the same gauge screen, turn cue card and full-screen map as following a saved route. Cues come from the route's steps, with street names. Progress reads "2.1 of 5.4 mi · 12 min left".
- **Off route:** after the same 10-second test as a saved route, request a new route from your position to the destination. The map redraws it and the cues switch over. Without signal, you get the arrow back to the old route instead.
- **Arrival:** within 30 m of the destination, a success haptic and an "Arrived" banner. The ride keeps recording until you end it, so the ride home can be part of the same ride.
- **Afterwards:** the ride's recorded track can be saved as a route from Ride History, like any other ride.
- **Recent destinations:** the last 10 places are kept locally, for one-tap repeat trips.

### Live Activity

Shown for **every ride**, not only navigation, so speed and distance are visible
with the phone locked or while another app is on screen.

| Where | Shows |
|---|---|
| Dynamic Island, compact | Speed on the left; distance on the right. |
| Dynamic Island, expanded (long-press) | Speed, distance and time. When following a route or navigating: the next turn and progress. |
| Dynamic Island, minimal (when sharing with another activity, e.g. Google Maps navigation) | Speed only. |
| Lock Screen | Speed, distance, time, and a paused indicator. When following a route or navigating: the next turn and progress. |

- **Lifecycle:** it starts when the ride starts and ends when you slide to end, leaving a final summary on the Lock Screen for a few minutes.
- **Pausing:** a pause shows "Paused" and freezes the time.
- **Tapping it** opens the app on the gauge screen.
- **Refresh rate:** about every few seconds, or when the next turn changes. iOS limits how often it refreshes, so the Live Activity never shows the stopwatch's tenths of a second.
- **Turning it off:** users can do this in iOS Settings for the app. The ride works the same either way.

### Routes library

Reached from **Ride a Route**, and from a **Routes** link in Ride History.

- **Each row:** name, distance, where it came from (ride date, or "Imported"), and a small preview of its shape.
- **Toolbar:** **Import GPX…** (the system file picker).
- **Row actions:** Ride, Rename, Share (the menu above), Delete.
- **Detail view:** the route on a map with its start and finish marked, distance, and elevation gain if the data has it.
- **Limit:** none in v1. Routes are small once simplified (a 100 km route is about 2,000–4,000 points after simplification, well under 1 MB of GPX).

### Ride History

- **Tapping a ride** opens a detail view: its track on a map, plus the existing time, distance, top and average speed.
- **Save as Route** in that view asks for a name, defaulting to e.g. "Sat Sep 26, 11.5 mi". It copies the track into the route library, so the route survives when the ride later drops out of the 20-ride history.
- **Rides without a track:** rides recorded before this feature shipped have none. Their detail view says so, and Save as Route is disabled.

### Importing GPX

- **From other apps:** open a `.gpx` file with Cycle Odometer from Files, Safari, Mail, AirDrop or the share sheet.
- **From inside the app:** Import GPX… in the Routes library.
- The route is named from the GPX `<name>`, or the file name if there isn't one, and can be renamed.

### Ride screen (gauge) changes

```
┌──────────────────────────────┐
│ (NE)                   🗺  ⚙︎ │   ← map button beside the gear
│        ╭───────────╮          │
│       │  ↗ 3%      │          │
│       │   17.9     │          │
│       │   MPH      │          │
│        ╰─────   ───╯          │
│  [ DISTANCE ]  [ TIME ]       │
│ ┌───────────────────────────┐ │
│ │ ↱  Right in 400 ft        │ │   ← turn cue card (following a route)
│ │ 3.2 of 11.5 mi · 28%      │ │
│ └───────────────────────────┘ │
│ [   Pause Ride    ] [ Light ] │
└──────────────────────────────┘
```

- **Map button** (map icon) sits next to the gear and switches to the full-screen map.
- **Turn cue card:** when following a route, it takes the empty space between the stats tiles and the buttons. It shows the next turn and its distance on the first line, and progress on the second.
- **Off route:** the card turns orange and reads "Off route · 120 ft", with an arrow pointing back towards the route.
- **Not following a route:** the card is hidden and the screen looks as it does today.

### Full-screen map

```
┌──────────────────────────────┐
│ ‹ Gauge            N↑ / ⬆︎    │   ← back; north-up / heading-up toggle
│                              │
│      ····route (grey)····    │
│   ━━━done (blue)━━━●  you    │
│   ━━your track (green)━━     │
│                              │
│ ┌──────────────────────────┐ │
│ │ ↱ Right in 400 ft        │ │   ← turn cue (when following)
│ └──────────────────────────┘ │
│  17.9 mph   3.21 mi   24:10  │   ← compact stats strip
│  3.2 of 11.5 mi · 28%        │
└──────────────────────────────┘
```

- **Layers:** the route in grey, the part of it already done in blue, your actual track in green, and your position.
- **Camera:** follows you, heading-up by default (it matches the handlebar view), with a toggle to north-up. Panning stops the following; a **Recenter** button resumes it.
- **Stats strip:** speed, distance and time, always visible. The pause and end controls stay on the gauge screen, to keep the map simple and avoid accidental taps.
- **Warning flasher:** keeps running if it was on, but the map doesn't flash red; the flasher is a gauge-screen effect.

---

## Turn cues

The request asks for turn-by-turn directions. iOS 26 offers two sources for them,
each good at something different:

| | **A. From the route's shape** | **B. MapKit cycling directions** |
|---|---|---|
| How | Find the points where the route's bearing changes sharply. | `MKDirections.Request` with `transportType = .cycling` (new in iOS 26) between two points. |
| Follows *your* route exactly | **Yes** | No. Apple picks the roads between the two points, which can differ from the recorded track. |
| Street names | No ("Right in 400 ft") | Yes ("Right onto Main St") |
| Works offline / on trails / abroad | **Yes** | No. It needs network, road data and Apple's cycling coverage. |
| Cost | On-device, instant | Rate-limited network requests. |

**Recommendation: a hybrid.** A decides *where* the turns are; B only supplies the
*names*.

- **The route stays the authority.** Every cue comes from the route's own shape, so cues always match the path you chose, and they still work on trails, abroad or without signal.
- **Street names are added once, when a route is loaded for a ride.** For each leg between two consecutive turns, request cycling directions from one to the next. If Apple's route for that leg stays within about 25 m of ours throughout, take the name from the matching `MKRoute.Step` ("Right onto Main St").
- **Fallback:** if Apple's leg doesn't match, or the request fails, reverse-geocode the turn point with `MKReverseGeocodingRequest` (iOS 26's replacement for the deprecated `CLGeocoder`) for the street name there. If that fails too, the cue stays as "Right in 400 ft".
- **Caching:** names are saved in the route's index entry, so a route is only annotated once, and a ride never waits on the network.
- **Rate limits:** requests run one at a time in the background. An annotation left unfinished carries on the next time the route is loaded.

B is also what powers the approach leg to a route's start (see [Start screen](#start-screen)) and the **route back** when you're off route (see [Off-route alert](#off-route-alert)).

### How the shape-based cues work

1. Simplify the route (Douglas–Peucker, about 10 m) so GPS wiggle doesn't read as turns.
2. At each remaining vertex, compare the bearing in and out over about 30 m each side. Anything above 30° is a turn:
   - 30–60°: slight left or right.
   - 60–120°: left or right.
   - over 120°: sharp left or right.
   - near 180°: U-turn, e.g. the turnaround on an out-and-back.
3. Merge turns closer together than about 25 m (a road jog becomes one cue).
4. While riding, the next turn ahead of your matched position (below) is the cue. The distance to it counts down in your units (ft and mi, or m and km).
5. A light haptic tap at about 150 m before the turn and again at about 30 m, so you needn't look at the screen.

---

## Following a route: progress and off-route

### Map matching

Each accepted GPS fix (the same ≤25 m accuracy filter `RideTracker` uses) is
matched to the route:

- **Projection:** project the fix onto the route's segments and take the closest. The distance *along* the route at that point is your **progress**; the distance *to* it is the **cross-track error**.
- **Search window:** only search a window ahead of the last match (say the next 1 km, and a little behind). Without this, a route that crosses or retraces itself (figure-eights, out-and-backs, loops) would make progress jump to the wrong pass.
- **Recovery:** if nothing in the window is within the off-route threshold for 30 s, search the whole route. That handles a shortcut or a detour that rejoins further along.
- **Progress readout:** done = the matched distance along the route; remaining = the route length minus that; % = done ÷ length.

### Off-route alert

- **Threshold:** off route when the cross-track error is over **max(50 m, 2 × GPS accuracy)** for more than **10 s**. Back on route below **30 m**. The gap between the two stops it flickering in and out.
- **On leaving the route:** a warning haptic, the orange cue card and map banner, and an arrow towards the nearest point of the route.
- **Route back:** after 60 s off route, request cycling directions (`.cycling`) from your position to a rejoin point about 300 m further along the route, so you aren't sent backwards. It's drawn on the map as a dashed line, and its steps become the turn cues until you're back on the route. Offline, the arrow and distance are all you get.
- **On rejoining:** a success haptic and a brief "Back on route".
- **Phone locked:** haptics and banners only work while the app is on screen. The screen is normally kept on during a ride, but if it's locked an alert would need a **local notification** (a new permission). See [Open questions](#open-questions).

---

## Data model and storage

### Track recording (in `RideTracker`)

- **What's kept:** a point for each accepted fix, stored only when it has moved at least 5 m from the last stored point. That's about 20,000 points for 100 km, or fewer when riding straight.
- **Fields:** latitude, longitude, timestamp, GPS speed, and barometric relative altitude when available.
- **Pausing:** points are recorded only while the timer is running, matching how distance works today. Pausing starts a new **segment**, so a map never draws a straight line across a café stop. (GPX supports this: one `<trkseg>` per segment.)
- **Performance:** points are held in memory during the ride and written when the ride ends, with a checkpoint every few minutes so a crash loses little.

### Files

```
Application Support/
  rides.json                    existing history index (last 20 rides); gains a `hasTrack` flag
  tracks/<ride-id>.gpx          one per ride with a track; deleted when its ride drops off the 20
  routes/index.json             [{id, name, createdAt, source, distance, elevationGain}]
  routes/<route-id>.gpx         simplified geometry (Douglas–Peucker ~3 m)
```

- **Why GPX:** storing tracks and routes as GPX makes export a file copy and keeps them readable by other tools. They're parsed once into memory when a ride or route is opened.
- **Routes are copies:** a route owns its own copy of the geometry, so deleting or aging out the ride it came from doesn't affect it.
- **`RideRecord`** gains `hasTrack: Bool`, decoded as `false` when missing so existing `rides.json` files still load.

### GPX import details

- **Registering the file type:** declare a document type for `.gpx` in `Info.plist` (`CFBundleDocumentTypes`, plus an imported type declaration for `com.topografix.gpx`). Handle files opened from other apps with `onOpenURL`, and use `.fileImporter` inside the app.
- **Parsing:** use `XMLParser`. Accept track points (`<trk>/<trkseg>/<trkpt>`) and route points (`<rte>/<rtept>`). If a file has several tracks, join them in order. Ignore waypoints (`<wpt>`) in v1.
- **Validation:** at least 2 points. Simplify anything over 50,000 points. Refuse files over 20 MB with a clear message.
- **Errors:** show a plain message ("This file has no route in it"), never a silent failure.

---

## Map implementation

- **Framework:** SwiftUI `Map` (MapKit for SwiftUI), with `MapPolyline` for the route, done and track layers, `UserAnnotation` for your position, and a `MapCameraPosition` that follows the user with heading.
- **Keeping it smooth:** a long ride's track shouldn't rebuild a 20,000-point polyline every second. Draw a simplified copy, add new points to its end, and re-simplify every few hundred points.
- **No signal:** map tiles need network, and MapKit caches only what's been viewed. Out of signal, the lines and your position still draw on a blank background, and progress, off-route and turn cues keep working because they're computed on the device.
- **Overlays:** the turn cue card, stats strip and buttons over the map use iOS 26's Liquid Glass (`.glassEffect()`), so the map stays visible behind them. The gauge screen keeps its solid black tiles, which read better in sunlight and over the red warning flash.
- **Battery:** the map draws more than the gauge does. The gauge screen stays the default, and the map is one tap away.

---

## Permissions and configuration

- **Location:** no new permission. When-in-use plus background location is already declared.
- **Notifications:** only if off-route alerts must work with the phone locked. That's an open question.
- **`Info.plist`:** the GPX document type and imported type declaration.
- **Live Activity:** add `NSSupportsLiveActivities = YES` to the app's `Info.plist`, and a new **Widget Extension** target in `project.yml` for the Dynamic Island and Lock Screen layouts. The `ActivityAttributes` type is shared between the app and the extension. There are no push updates: the app updates the activity itself while it's running in the background for location.
- **Search:** `MKLocalSearch` needs no permission beyond location.
- **Deployment target:** iOS 26 (the prerequisite at the top). No availability checks are needed for `.cycling` directions, `MKReverseGeocodingRequest`, unified Maps URLs or `.glassEffect()`.

## Privacy

- **Home location:** a recorded track usually starts and ends at home, and sharing a GPX file shares that.
- **v1:** Share shows a one-line reminder the first time.
- **Later:** a **privacy zone** option that trims the first and last ~200 m from shared files, the way Strava does.
- **Timestamps:** leave them out of shared route files. Only the geometry is needed to follow a route.
- **Destinations:** searches and Navigate to a place send the search text and your position to Apple, the same as searching in Apple Maps. Recent destinations are stored only on the phone and can be cleared.
- **Apple's servers:** street names, Ride to Start and route back send turn points and your position to Apple (MapKit directions and geocoding). Tracks themselves are never uploaded. Say so in the app's privacy description, and consider a setting to turn street names off.

## Phasing

| Phase | Scope | Why this order |
|---|---|---|
| **0** | Raise the deployment target to iOS 26 and check the existing screens on it. | Everything below assumes it. |
| **1** | Track recording; full-screen live map (track only); map on the Ride History detail view. | Everything else depends on having tracks, and this is useful on its own. |
| **2** | Save as Route; Routes library; Share (GPX, Google Maps approximate, directions to start). | Delivers the "save and open in other apps" part of the request. |
| **3** | GPX import; Ride a Route; route overlay, progress and off-route alerts. | Following needs routes to exist, from rides or imports. |
| **4** | Turn cues on the map and the gauge screen (shape-based), with a haptic countdown; street names from cycling directions and reverse geocoding; Ride to Start; route back. | The most tuning-sensitive part; best built on a proven matcher. |
| **5** | Live Activity with speed, distance and time; next turn and progress once phase 4 exists. | Doesn't depend on routes, so it could be built earlier if wanted. |
| **6** | Navigate to a place: search, route preview, rerouting, arrival, recent destinations. | Reuses the cue card, map and matcher from phases 3–4. |
| Later | KML export; privacy zones; locked-screen alerts. | Nice to have. |

## Testing

- **Unit tests** (the project needs a test target; `scripts/deploy_testflight.sh` runs tests automatically once one exists):
  - GPX parse and write round-trip, including multi-segment tracks and route-point-only files.
  - Map matching on a straight route, a loop, an out-and-back, and a self-crossing figure-eight. Progress must not jump between passes.
  - Off-route hysteresis around the 30 m and 50 m thresholds.
  - Turn detection on a synthetic grid-street route, and ignoring GPS jitter on a straight road.
  - Google waypoint sampling: never more than 9, and turns are kept.
  - Street-name matching: an Apple leg that follows ours is used, one that detours is rejected, and a failed request leaves the plain cue. MapKit calls go through a small protocol so the tests use canned `MKRoute`-like results rather than the network.
- **Simulator:** `xcrun simctl location start` plays a list of waypoints. Extend `scripts/run_simulator.sh --ride` to take a GPX file (converted to waypoints) and add a scenario that leaves the route and rejoins it.
- **Field test checklist:**
  - A familiar loop.
  - An out-and-back.
  - A route with a deliberate wrong turn.
  - Riding out of signal (cues keep working without street names; Ride to Start falls back to bearing and distance).
  - Ride to Start from a few blocks away, and a route back after a wrong turn.
  - Navigate to a place a few miles away: a deliberate wrong turn (reroute), losing signal mid-way, and arrival.
  - Live Activity: Lock Screen and Dynamic Island during a ride; alongside Google Maps navigation (minimal view); pausing; ending the ride.
  - Pausing mid-route.
  - An imported Strava or Komoot GPX.
  - Opening the route in Google Maps and Apple Maps.

## Open questions

1. **Voice prompts:** should turn cues also be spoken (`AVSpeechSynthesizer`)? That's useful with the phone mounted. It would interact with other apps' audio in the same way as the parked music feature.
2. **Locked phone:** should off-route alerts reach you when the phone is locked? That needs notification permission.
3. **Map orientation:** heading-up or north-up by default?
4. **Map button placement:** next to the gear (as sketched), or somewhere else?
5. **Street names:** on by default, or opt-in, given they send turn points to Apple? (See [Privacy](#privacy).)
6. **Route library limit:** none, or a cap like the 20-ride history?
7. **Elevation:** show a route elevation profile (from GPX elevation or recorded barometer data) in the route detail view?
8. **Arrival:** when navigating to a place, should reaching it end the ride automatically (after a confirmation), or keep recording as proposed?
9. **Live Activity content:** is distance the right thing for the compact view's right side, or would time or grade be more useful?

## References

- Google Maps iOS URL scheme (`comgooglemaps://`, `comgooglemaps-x-callback://`): <https://developers.google.com/maps/documentation/urls/ios-urlscheme>
- ActivityKit / Live Activities: <https://developer.apple.com/documentation/activitykit>
- `MKLocalSearch`: <https://developer.apple.com/documentation/mapkit/mklocalsearch>
- Picture in Picture with custom content (`AVPictureInPictureController.ContentSource`): <https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource>
- Google Maps Platform terms (Google content on a Google map): <https://cloud.google.com/maps-platform/terms>

- Google Maps URLs: directions, `travelmode=bicycling`, waypoint limits (9, or 3 in mobile browsers): <https://developers.google.com/maps/documentation/urls/get-started>
- Apple unified Maps URLs (iOS 18.4+): <https://developer.apple.com/documentation/mapkit/unified-map-urls>
- Apple Maps URL parameter guide (`/directions`, `mode=cycling`, `waypoint`): <https://gotoapplemaps.com/guides/apple-maps-url-scheme-guide/>
- `MKLaunchOptionsDirectionsModeCycling`: <https://developer.apple.com/documentation/mapkit/mklaunchoptionsdirectionsmodecycling>
- `MKDirectionsTransportType.cycling`: <https://developer.apple.com/documentation/mapkit/mkdirectionstransporttype/cycling>
- `MKReverseGeocodingRequest` replacing the deprecated `CLGeocoder` in iOS 26: <https://developer.apple.com/forums/thread/795687>, <https://sasq.ca/blog/2026/7/19/is-mapkit-reverse-geocoding-ready>
- WWDC25, "Go further with MapKit" (cycling directions, geocoding in MapKit): <https://developer.apple.com/videos/play/wwdc2025/204/>
- Apple Maps has no GPX import: <https://nomadtracks.app/apple-maps-gpx/>, <https://discussions.apple.com/thread/251931517>
- Google My Maps import (no iPhone app; imported maps show in Google Maps under You → Maps): <https://support.google.com/mymaps/answer/3024836?hl=en&co=GENIE.Platform%3DiOS>, <https://support.google.com/maps/thread/44191167>
