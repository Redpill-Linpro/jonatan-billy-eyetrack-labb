const dgram = require('dgram');
const http = require('http');
const fs = require('fs');
const WebSocket = require('ws');
const udpServer = dgram.createSocket('udp4');
const httpServer = http.createServer((req, res) => {
    fs.readFile(__dirname + '/index.html', (err, data) => {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(data);
    });
});
const wss = new WebSocket.Server({ server: httpServer });

udpServer.on('message', (msg) => {
    // OpenTrack packets are 6 doubles (8 bytes each = 48 bytes)
    if (msg.length >= 48) {
        const data = {
            x: msg.readDoubleLE(0),
            y: msg.readDoubleLE(8),
            z: msg.readDoubleLE(16),
            yaw: msg.readDoubleLE(24),
            pitch: msg.readDoubleLE(32),
            roll: msg.readDoubleLE(40)
        };

        const payload = JSON.stringify(data);
        wss.clients.forEach(client => {
            if (client.readyState === WebSocket.OPEN) client.send(payload);
        });
    }
});

udpServer.bind(4242);
httpServer.listen(9090, () => console.log('gaze-verify running at http://localhost:9090'));
