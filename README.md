# immediate-tracking

Head and eye tracking from a webcam, sent to [opentrack](https://github.com/opentrack/opentrack) over UDP.

Linux only.

## Run

Install [uv](https://docs.astral.sh/uv/), then:

```
uv run immediate_tracking.py
```

The first run downloads the dependencies. Stop with Ctrl+C.

In opentrack, choose "UDP over network" as input, port 4242.

For more accurate gaze, calibrate first:

```
uv run immediate_tracking.py --calibrate
```

Look at the centre of your screen and press Enter when asked. To recalibrate later, look at the centre and blink three times quickly; without `--calibrate` this re-centres.

## Settings

Edit `settings.ini`. By default the first working camera is used; set `name` or `index` under `[Camera]` to pick another. Only one program can use a camera at a time.

## Tools

`tools/gaze-verify` shows the tracker's output in a browser, without opentrack.

## License

MIT. See `LICENSE`.
