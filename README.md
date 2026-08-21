# Posture

Watches your posture through your webcam and tells you when you start slouching.
The bar widget turns red and a critical notification fires when you drift from a
baseline you calibrate yourself.

Runs entirely on your machine. No images are ever written to disk or sent
anywhere: frames live in memory for the fraction of a second they are analysed
and are then discarded. Only numbers are stored.

## Requirements

- Omarchy 4 (Quattro) with the Quickshell shell
- A webcam at `/dev/video0`
- `python-opencv`, which pulls in `python-numpy`

`jq`, `v4l2-ctl`, `fuser` and `loginctl` are also used and ship with Omarchy.

## Installation

```bash
# 1. the one dependency that is not already on an Omarchy system
omarchy pkg add python-opencv

# 2. add the plugin
omarchy plugin add https://github.com/CodeFoundryZA/omarchy-posture.git

# 3. install the background service
~/.config/omarchy/plugins/io.github.codefoundryza.posture/bin/posture-install

# 4. show the widget in the bar
omarchy plugin enable io.github.codefoundryza.posture right
```

Then calibrate. This is required, not optional: absolute thresholds cannot work
for an arbitrary camera height and desk, so the plugin does nothing until it
knows what good posture looks like for you.

```bash
~/.config/omarchy/plugins/io.github.codefoundryza.posture/bin/posture calibrate
```

Sit the way you want to be reminded to sit, and it records a baseline from about
ten samples. Recalibrate whenever you move the laptop or change desk setup, with
that same command or a middle click on the widget.

Add `bin/` to your `PATH` if you want to type `posture` instead of the full path.

## Removal

The plugin installs one file outside its own directory, a systemd user service.
Remove that first, otherwise it is left behind:

```bash
~/.config/omarchy/plugins/io.github.codefoundryza.posture/bin/posture-uninstall
omarchy plugin remove io.github.codefoundryza.posture
```

The uninstall script stops and deletes the service, then asks before touching
your calibration and history in `~/.local/state/omarchy/posture`. Answer no and a
later reinstall picks up your existing baseline.

## How it works

A systemd user service (`omarchy-posture.service`) samples the camera on an
adaptive cadence: it opens `/dev/video0`, grabs a few frames, releases the
device, and estimates head and shoulder geometry with BlazePose run through
OpenCV's DNN module. The device is held only for the length of a sample, so
video calls are never blocked.

A sample costs about 0.7s wall clock, nearly all of it the first read after
opening the device, so the interval is what governs how fast a slouch is
caught. Sampling therefore stays lazy while nothing is wrong and tightens the
moment one bad reading appears:

| Situation | Interval | Setting |
|---|---|---|
| posture is fine | 6s | `intervalSeconds` |
| a bad reading is pending confirmation | 2s | `fastIntervalSeconds` |
| nobody at the desk | 15s | `awayIntervalSeconds` |

Measured end to end that is about **7.6s from slouching to the bar going red**
and 2.5s back to green, at roughly 3.8% of one core and an 11% camera duty
cycle while posture is good.

The daemon owns the state machine and sends the notifications, and publishes
everything to `~/.local/state/omarchy/posture/state.json`. The Quickshell
plugin only reflects that file, so posture monitoring survives
`omarchy restart shell`.

## Commands

```bash
posture status        # current state
posture calibrate     # record your good-posture baseline
posture pause         # suspend sampling
posture resume
posture sensitivity 1.4
posture history       # today, last 12 hours, last 7 days
posture history --days 30
posture history --json
posture once          # single sample as JSON
posture probe         # camera health check
posture logs
```

`posture` lives at `bin/posture` inside this plugin directory.

## Bar widget

- left click: details panel
- right click: pause or resume
- middle click: recalibrate

Inside the panel: `C` recalibrate, `P` pause or resume, `H` open the full
history report in a terminal.

The icon carries the state as well as the colour, so the widget still reads
correctly without relying on red alone:

| State | Icon |
|---|---|
| good | `md-seat_recline_normal`, upright figure |
| bad | `md-seat_recline_extra`, reclined figure |
| away | `md-seat_outline`, empty chair |
| paused | `md-pause_circle_outline` |
| blocked | `md-webcam_off` |
| uncalibrated | `md-crosshairs_question` |
| daemon stopped | `md-help_circle_outline` |

The widget uses `WidgetButton.active`, which paints it with the theme's
`urgent` color, so red stays correct across theme switches.

## Metrics

All distances are divided by shoulder width, so they survive small changes in
how far you sit from the camera:

| Metric | Meaning |
|---|---|
| `neckRatio` | vertical room between shoulder line and nose; collapses when you slouch or crane |
| `earNeckRatio` | same, measured to the ears |
| `scale` | apparent shoulder width; grows as you lean toward the screen |
| `frameY` | height of the shoulder line in frame; grows as you sink down |
| `shoulderTiltDeg` | side lean |
| `headTiltDeg` | head tilt |

### Sensitivity

Calibration records what good posture looks like for you. Sensitivity decides
**how far you are allowed to drift from it before it complains.** It is one
number that divides every tolerance at once, so you tune nagging with a single
dial instead of five thresholds.

| Sensitivity | Head drop allowed | Side lean allowed | Feel |
|---|---|---|---|
| 0.5 | 28% | 18° | very forgiving, only bad slouches |
| 1.0 | 14% | 9° | default |
| 2.0 | 7% | 4.5° | strict, small movements trip it |

Higher is stricter, because the tolerance is divided by it. Accepted range is
0.5 to 2.5; the CLI rejects anything outside that.

The panel exposes this as four preset chips (Relaxed, Normal, Strict,
Strictest) rather than a slider. Sensitivity is a coarse preference, and a
slider knob had to be reconciled against a value the daemon only echoes back a
few seconds later, which made it spring back under the cursor. A chip cannot
disagree with itself that way. `-` and `+` in the panel still fine tune by 0.1
for values between the presets, and `0` resets to 1.0; a stored value that
matches no preset lights up the nearest one.

Per-metric tolerances live under `tolerance` in the config file if you want to
loosen one axis on its own without touching the others.

## States

| State | Meaning |
|---|---|
| `good` | inside tolerance |
| `bad` | out of tolerance for 3 consecutive samples, about 8 seconds |
| `away` | no person detected for 3 consecutive samples |
| `paused` | manually paused, session locked, or camera in use by another app |
| `blocked` | camera streams frames but the sensor sees nothing, so it is covered |
| `uncalibrated` | no baseline recorded yet |

Entering `bad` sends one critical notification and repeats every 5 minutes
while it holds. Recovery is silent.

## History

The daemon credits each cycle's elapsed wall time to whichever state was in
force, so totals stay honest despite the adaptive interval. Two files hold it:

- `summary.json`: hour and day buckets per state, plus the last 500 episodes.
  This is what the panel reads. Buckets are persisted directly, so nothing has
  to be replayed on restart.
- `history.jsonl`: raw metric rows written at most once a minute, for longer
  term trends or rebuilding.

Retention is 90 days of daily buckets, 72 hours of hourly buckets, and 20k raw
samples. The panel shows today's good-posture share, slouch count and longest
slouch, plus a 12 hour column chart where a hollow column means the monitor was
not watching that hour. `posture history` prints the same data plus a 7 day
trend and recent slouches.

Only `good` and `bad` time counts toward the percentage. `away` and `paused`
are tracked but excluded, so stepping out does not inflate your score.

## Implementation notes

Two things about this machine shaped the design and are worth knowing before
changing the inference path.

**The upstream person detector is unusable here.** BlazePose normally locates
its region of interest with a full-body person detector. That detector is
trained on images containing most of a body, and on a desk webcam showing only
head and shoulders it fired on 3 of 14 frames at confidences around 0.5. A desk
camera has fixed geometry, so the region of interest does not need detecting at
all: `PoseEngine._roi` synthesises one that models the sitter's hips below the
bottom of the frame. That measured 6 of 6 frames at confidence 1.00 with about
1 percent metric noise, and it dropped a 12MB model from the hot path. The
`roi` block in the config tunes it if the camera is mounted unusually.

**OpenCV 5.0 cannot run the pose model on its classic engine.** The classic
engine rejects the model's NHWC convolutions outright, so the pose model must
use the default new engine. This is why the harmless
`setPreferableTarget Targets are not supported by the new graph engine` warning
appears in the log on every start.

**Blank-frame detection uses standard deviation, not mean brightness.** The
webcam's `brightness` control adds a flat DC offset, so a covered sensor can
report a healthy-looking mean while every pixel is identical. `BLANK_STD`
guards against reading that as a real image.

## Privacy

No frame is ever written to disk, encoded, transmitted, or logged. Each sample
opens the camera, reads a few frames into memory, computes six numbers from the
landmark geometry, and releases the device. Only those numbers reach disk.

The camera is held for well under a second per sample and released between
samples, so video calls are never blocked. If another application is using the
camera the plugin skips that sample entirely rather than competing for it.

## License

MIT, see [LICENSE](LICENSE).

The bundled BlazePose model and its decoder are Apache-2.0 from
[opencv_zoo](https://github.com/opencv/opencv_zoo); see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
