# gaze-verify

A tiny Node server that listens on the opentrack UDP port (4242) and draws the tracker's output on a web page.

## Run

```
npm install
node server.js
```

Then open http://localhost:9090 and start the tracker.

Do not run opentrack at the same time; both use port 4242.
