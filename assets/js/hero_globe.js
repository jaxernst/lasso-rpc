/**
 * HeroGlobe - 3D dotted globe with RPC request routing animations
 *
 * Pre-baked land dots from Natural Earth 50m data,
 * animated request routing arcs showing Lasso's aggregation flow:
 * Client → Hub → Fan-out to regional Providers
 * Hub nodes interconnected to show clustered network.
 * Pure Canvas 2D, no external dependencies.
 */

import LAND_DOTS from "./land_dots.json";

// ============================================================
// RPC INFRASTRUCTURE NODES
// ============================================================

const CLIENT_NODES = [
  { lat: 45.52, lng: -122.68, label: "Portland" },
  { lat: 39.74, lng: -104.99, label: "Denver" },
  { lat: 25.76, lng: -80.19, label: "Miami" },
  { lat: 43.65, lng: -79.38, label: "Toronto" },
  { lat: 40.42, lng: -3.7, label: "Madrid" },
  { lat: 52.23, lng: 21.01, label: "Warsaw" },
  { lat: 37.57, lng: 126.98, label: "Seoul" },
  { lat: 22.32, lng: 114.17, label: "Hong Kong" },
  { lat: 13.76, lng: 100.5, label: "Bangkok" },
  { lat: -1.29, lng: 36.82, label: "Nairobi" },
  { lat: 6.52, lng: 3.38, label: "Lagos" },
  { lat: 19.43, lng: -99.13, label: "Mexico City" },
  { lat: 34.05, lng: -118.24, label: "Los Angeles" },
  { lat: 41.88, lng: -87.63, label: "Chicago" },
  { lat: 47.61, lng: -122.33, label: "Seattle" },
  { lat: 33.45, lng: -112.07, label: "Phoenix" },
  { lat: 29.76, lng: -95.37, label: "Houston" },
  { lat: 55.75, lng: 37.62, label: "Moscow" },
  { lat: 59.33, lng: 18.07, label: "Stockholm" },
  { lat: 41.01, lng: 28.98, label: "Istanbul" },
  { lat: 30.04, lng: 31.24, label: "Cairo" },
  { lat: -34.6, lng: -58.38, label: "Buenos Aires" },
  { lat: 4.71, lng: -74.07, label: "Bogotá" },
  { lat: -12.05, lng: -77.04, label: "Lima" },
  { lat: 35.69, lng: 51.39, label: "Tehran" },
  { lat: 31.23, lng: 121.47, label: "Shanghai" },
  { lat: 14.6, lng: 120.98, label: "Manila" },
  { lat: -6.21, lng: 106.85, label: "Jakarta" },
  { lat: 3.14, lng: 101.69, label: "Kuala Lumpur" },
  { lat: -37.81, lng: 144.96, label: "Melbourne" },
  { lat: 64.13, lng: -21.9, label: "Reykjavik" },
  { lat: 48.21, lng: 16.37, label: "Vienna" },
  { lat: 42.36, lng: -71.06, label: "Boston" },
  { lat: 38.91, lng: -77.04, label: "Washington DC" },
  { lat: 33.75, lng: -84.39, label: "Atlanta" },
  { lat: 32.78, lng: -96.8, label: "Dallas" },
  { lat: 36.17, lng: -115.14, label: "Las Vegas" },
  { lat: 37.34, lng: -121.89, label: "San Jose" },
  { lat: 49.28, lng: -123.12, label: "Vancouver" },
  { lat: 51.05, lng: -114.07, label: "Calgary" },
  { lat: 53.55, lng: -113.49, label: "Edmonton" },
  { lat: 60.17, lng: 24.94, label: "Helsinki" },
  { lat: 50.45, lng: 30.52, label: "Kyiv" },
  { lat: 47.5, lng: 19.04, label: "Budapest" },
  { lat: 50.08, lng: 14.44, label: "Prague" },
  { lat: 41.39, lng: 2.17, label: "Barcelona" },
  { lat: 38.72, lng: -9.14, label: "Lisbon" },
  { lat: 55.68, lng: 12.57, label: "Copenhagen" },
  { lat: 53.35, lng: -6.26, label: "Dublin" },
  { lat: 35.17, lng: 136.91, label: "Nagoya" },
  { lat: 34.69, lng: 135.5, label: "Osaka" },
  { lat: -33.45, lng: -70.67, label: "Santiago" },
  { lat: 28.61, lng: 77.21, label: "New Delhi" },
  { lat: 12.97, lng: 77.59, label: "Bangalore" },
  { lat: -26.2, lng: 28.04, label: "Johannesburg" },
  { lat: 33.87, lng: 35.51, label: "Beirut" },
  { lat: 24.71, lng: 46.68, label: "Riyadh" },
  { lat: 1.29, lng: 36.82, label: "Kampala" },
  { lat: -4.32, lng: 15.31, label: "Kinshasa" },
];

const PROVIDER_NODES = [
  { lat: 37.77, lng: -122.42, label: "US West" },
  { lat: 40.71, lng: -74.01, label: "US East" },
  { lat: 39.04, lng: -77.49, label: "US Central" },
  { lat: 51.51, lng: -0.13, label: "London" },
  { lat: 48.86, lng: 2.35, label: "Paris" },
  { lat: 52.52, lng: 13.41, label: "Berlin" },
  { lat: 35.68, lng: 139.65, label: "Tokyo" },
  { lat: 1.35, lng: 103.82, label: "Singapore" },
  { lat: -33.87, lng: 151.21, label: "Sydney" },
  { lat: 25.2, lng: 55.27, label: "Dubai" },
  { lat: -23.55, lng: -46.63, label: "São Paulo" },
  { lat: 19.08, lng: 72.88, label: "Mumbai" },
  { lat: 45.5, lng: -73.57, label: "Montreal" },
  { lat: 60.17, lng: 24.94, label: "Helsinki" },
  { lat: 22.32, lng: 114.17, label: "Hong Kong" },
  { lat: 37.57, lng: 126.98, label: "Seoul" },
  { lat: -1.29, lng: 36.82, label: "Nairobi" },
  { lat: 32.78, lng: -96.8, label: "Dallas" },
];

const HUB_NODES = [
  { lat: 39.04, lng: -77.49, label: "Lasso US East" },
  { lat: 37.77, lng: -122.42, label: "Lasso US West" },
  { lat: 50.11, lng: 8.68, label: "Lasso EU" },
  { lat: 1.35, lng: 103.82, label: "Lasso APAC" },
];

// ============================================================
// 3D MATH
// ============================================================

function latLngTo3D(lat, lng, r) {
  const phi = (90 - lat) * (Math.PI / 180);
  const theta = (lng + 180) * (Math.PI / 180);
  return {
    x: r * Math.sin(phi) * Math.cos(theta),
    y: r * Math.cos(phi),
    z: r * Math.sin(phi) * Math.sin(theta),
  };
}

function rotateY(p, a) {
  const c = Math.cos(a),
    s = Math.sin(a);
  return { x: p.x * c - p.z * s, y: p.y, z: p.x * s + p.z * c };
}

function rotateX(p, a) {
  const c = Math.cos(a),
    s = Math.sin(a);
  return { x: p.x, y: p.y * c - p.z * s, z: p.y * s + p.z * c };
}

function greatCircleDist(a, b) {
  const toRad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * toRad;
  const dLng = (b.lng - a.lng) * toRad;
  const sinLat = Math.sin(dLat / 2);
  const sinLng = Math.sin(dLng / 2);
  const h =
    sinLat * sinLat +
    Math.cos(a.lat * toRad) * Math.cos(b.lat * toRad) * sinLng * sinLng;
  return 2 * Math.asin(Math.sqrt(h));
}

function buildArcPath(fromPos, toPos, steps, peakHeight) {
  const pts = [];
  const dot = fromPos.x * toPos.x + fromPos.y * toPos.y + fromPos.z * toPos.z;
  const omega = Math.acos(Math.max(-1, Math.min(1, dot)));
  const sinO = Math.sin(omega);

  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    let x, y, z;
    if (sinO > 0.001) {
      const a = Math.sin((1 - t) * omega) / sinO;
      const b = Math.sin(t * omega) / sinO;
      x = a * fromPos.x + b * toPos.x;
      y = a * fromPos.y + b * toPos.y;
      z = a * fromPos.z + b * toPos.z;
    } else {
      x = fromPos.x + t * (toPos.x - fromPos.x);
      y = fromPos.y + t * (toPos.y - fromPos.y);
      z = fromPos.z + t * (toPos.z - fromPos.z);
    }
    const len = Math.sqrt(x * x + y * y + z * z);
    const h = 1.0 + peakHeight * Math.sin(t * Math.PI);
    pts.push({ x: (x / len) * h, y: (y / len) * h, z: (z / len) * h });
  }
  return pts;
}

// ============================================================
// REQUEST LIFECYCLE (one-way: Client → Hub → Providers)
// ============================================================

class RequestLifecycle {
  constructor(client, hub, providers) {
    this.phase = "inbound";
    this.done = false;
    this.hubPulse = 0;

    this.client = client;
    this.hub = hub;
    this.providers = providers;

    const clientPos = latLngTo3D(client.lat, client.lng, 1.0);
    const hubPos = latLngTo3D(hub.lat, hub.lng, 1.0);

    this.inboundPath = buildArcPath(clientPos, hubPos, 60, 0.12);
    this.inboundProgress = 0;
    this.inboundSpeed = 0.45 + Math.random() * 0.15;

    this.fanoutArcs = providers.map((p) => ({
      path: buildArcPath(hubPos, latLngTo3D(p.lat, p.lng, 1.0), 25, 0.025),
      progress: 0,
      providerLabel: p.label,
      pingFlash: 0,
    }));
    this.fanoutSpeed = 1.6 + Math.random() * 0.4;

    this.fadeOut = 1.0;
  }

  update(dt) {
    const sec = dt / 1000;

    if (this.hubPulse > 0.01) {
      this.hubPulse *= 0.92;
      if (this.hubPulse < 0.01) this.hubPulse = 0;
    }

    for (const arc of this.fanoutArcs) {
      if (arc.pingFlash > 0.01) {
        arc.pingFlash *= 0.9;
        if (arc.pingFlash < 0.01) arc.pingFlash = 0;
      }
    }

    switch (this.phase) {
      case "inbound":
        this.inboundProgress += this.inboundSpeed * sec;
        if (this.inboundProgress >= 1.0) {
          this.inboundProgress = 1.0;
          this.hubPulse = 1.0;
          this.phase = "fanout";
        }
        break;

      case "fanout": {
        let allDone = true;
        for (const arc of this.fanoutArcs) {
          if (arc.progress < 1.0) {
            arc.progress += this.fanoutSpeed * sec;
            if (arc.progress >= 1.0) {
              arc.progress = 1.0;
              arc.pingFlash = 1.0;
            } else {
              allDone = false;
            }
          }
        }
        if (allDone) this.phase = "fading";
        break;
      }

      case "fading":
        this.fadeOut -= 1.2 * sec;
        if (this.fadeOut <= 0) {
          this.fadeOut = 0;
          this.done = true;
        }
        break;
    }
  }
}

// ============================================================
// GLOBE RENDERER
// ============================================================

class GlobeRenderer {
  constructor(canvas, options = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    if (!this.ctx) return;

    this.destroyed = false;
    this.time = 0;
    this.rotation = options.initialRotation ?? 3.7;
    this.tilt = options.initialTilt ?? -0.15;
    this.autoRotateSpeed = options.autoRotateSpeed ?? 0.00015;
    this.xOffset = options.xOffset ?? 0.5;
    this.yOffset = options.yOffset ?? 0.5;
    this.radiusScale = options.radiusScale ?? 0.42;
    this.scrollRotationOffset = 0;
    this.scrollTiltOffset = 0;

    this.mouseX = 0;
    this.targetRotOffset = 0;
    this.currentRotOffset = 0;

    this.lifecycles = [];
    this.lastSpawn = 0;
    this.providerPingFlashes = {};

    const landSet = new Set(LAND_DOTS.map(([lat, lng]) => lat + "," + lng));

    this.globeDots = [];
    for (let lat = -84.5; lat <= 85; lat += 1.5) {
      const cosLat = Math.cos((lat * Math.PI) / 180);
      const rawStep = Math.min(1.5 / Math.max(cosLat, 0.01), 5.0);
      const nLng = Math.max(20, Math.round(360 / rawStep));
      const lngStep = 360 / nLng;
      for (let i = 0; i < nLng; i++) {
        const rawLng = Math.round((-180 + i * rawStep) * 100) / 100;
        this.globeDots.push({
          pos: latLngTo3D(lat, -180 + i * lngStep, 1.0),
          land: landSet.has(lat + "," + rawLng),
        });
      }
    }

    this.providers = PROVIDER_NODES.map((n) => ({
      ...n,
      pos: latLngTo3D(n.lat, n.lng, 1.0),
      type: "provider",
    }));
    this.hubs = HUB_NODES.map((n) => ({
      ...n,
      pos: latLngTo3D(n.lat, n.lng, 1.0),
      type: "hub",
    }));

    this.hubLinks = [];
    for (let i = 0; i < HUB_NODES.length; i++) {
      for (let j = i + 1; j < HUB_NODES.length; j++) {
        this.hubLinks.push(
          buildArcPath(
            latLngTo3D(HUB_NODES[i].lat, HUB_NODES[i].lng, 1.0),
            latLngTo3D(HUB_NODES[j].lat, HUB_NODES[j].lng, 1.0),
            50,
            0.04,
          ),
        );
      }
    }

    this.resize();
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(canvas.parentElement);

    canvas.parentElement.addEventListener("mousemove", (e) => {
      const rect = canvas.parentElement.getBoundingClientRect();
      this.mouseX = (e.clientX - rect.left) / rect.width - 0.5;
      this.targetRotOffset = this.mouseX * 0.15;
    });
    canvas.parentElement.addEventListener("mouseleave", () => {
      this.targetRotOffset = 0;
    });

    for (let i = 0; i < 5; i++) this.spawnLifecycle();
    this.startAnimation();
  }

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const container = this.canvas.parentElement;
    const w = container.clientWidth;
    const h = container.clientHeight;
    this.canvas.width = w * dpr;
    this.canvas.height = h * dpr;
    this.canvas.style.width = w + "px";
    this.canvas.style.height = h + "px";
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = w;
    this.h = h;
    this.radius = Math.min(w, h) * this.radiusScale;
    this.cx = w * this.xOffset;
    this.cy = h * this.yOffset;
    this.perspective = 3.0;
  }

  project(p) {
    const angle =
      this.rotation + this.currentRotOffset + this.scrollRotationOffset;
    let pt = rotateY(p, angle);
    pt = rotateX(pt, this.tilt + this.scrollTiltOffset);
    const scale = this.perspective / (this.perspective + pt.z);
    return {
      x: pt.x * scale * this.radius + this.cx,
      y: -pt.y * scale * this.radius + this.cy,
      scale,
      z: pt.z,
      visible: pt.z < 0.35,
    };
  }

  spawnLifecycle() {
    if (this.lifecycles.length >= 12) return;

    const client =
      CLIENT_NODES[Math.floor(Math.random() * CLIENT_NODES.length)];

    let nearest = HUB_NODES[0];
    let bestDist = Infinity;
    for (const hub of HUB_NODES) {
      const d = greatCircleDist(client, hub);
      if (d < bestDist) {
        bestDist = d;
        nearest = hub;
      }
    }

    const sorted = [...PROVIDER_NODES].sort(
      (a, b) => greatCircleDist(nearest, a) - greatCircleDist(nearest, b),
    );
    const regional = sorted.slice(0, 6);
    const shuffled = regional.sort(() => Math.random() - 0.5);
    const providerCount = 2 + Math.floor(Math.random() * 2);
    const providers = shuffled.slice(0, providerCount);

    this.lifecycles.push(new RequestLifecycle(client, nearest, providers));
  }

  startAnimation() {
    let lastTime = 0;
    const animate = (time) => {
      if (this.destroyed) return;
      const dt = lastTime > 0 ? Math.min(time - lastTime, 100) : 16;
      lastTime = time;
      this.time = time * 0.001;
      this.rotation -= this.autoRotateSpeed * dt;

      this.currentRotOffset +=
        (this.targetRotOffset - this.currentRotOffset) * 0.04;

      if (time - this.lastSpawn > 700) {
        this.spawnLifecycle();
        this.lastSpawn = time;
      }

      this.providerPingFlashes = {};
      for (const lc of this.lifecycles) {
        lc.update(dt);
        for (const arc of lc.fanoutArcs) {
          if (arc.pingFlash > 0) {
            const key = arc.providerLabel;
            this.providerPingFlashes[key] = Math.max(
              this.providerPingFlashes[key] || 0,
              arc.pingFlash,
            );
          }
        }
      }
      this.lifecycles = this.lifecycles.filter((lc) => !lc.done);

      this.draw();
      this.animationId = requestAnimationFrame(animate);
    };
    this.animationId = requestAnimationFrame(animate);
  }

  draw() {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.w, this.h);

    this.drawAtmosphere(ctx);
    this.drawGlobeBase(ctx);
    this.drawGlobeDots(ctx);
    this.drawHubLink(ctx);
    this.drawArcs(ctx);
    this.drawNodes(ctx);
    this.drawHubPulses(ctx);
    this.drawRim(ctx);
  }

  drawAtmosphere(ctx) {
    const g = ctx.createRadialGradient(
      this.cx,
      this.cy,
      this.radius * 0.8,
      this.cx,
      this.cy,
      this.radius * 1.6,
    );
    g.addColorStop(0, "rgba(60, 80, 140, 0.08)");
    g.addColorStop(0.5, "rgba(40, 60, 120, 0.03)");
    g.addColorStop(1, "rgba(0, 0, 0, 0)");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, this.w, this.h);
  }

  drawGlobeBase(ctx) {
    const P = this.perspective;
    const silhouetteRadius = (this.radius * P) / Math.sqrt(P * P - 1);
    ctx.beginPath();
    ctx.arc(this.cx, this.cy, silhouetteRadius, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(10, 12, 20, 0.5)";
    ctx.fill();
    ctx.strokeStyle = "rgba(60, 80, 140, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();
  }

  drawGlobeDots(ctx) {
    const baseR = this.radius / 500;

    for (const dot of this.globeDots) {
      const proj = this.project(dot.pos);
      if (!proj.visible) continue;

      const depth = Math.max(0, 1 - proj.z / 0.35);

      if (dot.land) {
        const alpha = 0.2 + 0.7 * depth * depth;
        const size = Math.max(0.4, baseR * proj.scale);
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, size, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(160, 175, 210, ${alpha})`;
        ctx.fill();
      } else {
        const alpha = 0.06 * depth * depth;
        const size = Math.max(0.3, baseR * 0.6 * proj.scale);
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, size, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(55, 65, 100, ${alpha})`;
        ctx.fill();
      }
    }
  }

  drawHubLink(ctx) {
    const pulse = 0.5 + 0.5 * Math.sin(this.time * 1.5);
    const alpha = 0.06 + 0.04 * pulse;

    for (const link of this.hubLinks) {
      let prevProj = null;
      for (let i = 0; i < link.length; i++) {
        const proj = this.project(link[i]);
        if (!proj.visible) {
          prevProj = null;
          continue;
        }
        if (prevProj) {
          ctx.beginPath();
          ctx.moveTo(prevProj.x, prevProj.y);
          ctx.lineTo(proj.x, proj.y);
          ctx.strokeStyle = `rgba(139, 92, 246, ${alpha * proj.scale})`;
          ctx.lineWidth = 1.5;
          ctx.stroke();
        }
        prevProj = proj;
      }
    }
  }

  drawNodes(ctx) {
    const allNodes = [
      ...this.providers.map((n) => ({ ...n, proj: this.project(n.pos) })),
      ...this.hubs.map((n) => ({ ...n, proj: this.project(n.pos) })),
    ];
    allNodes.sort((a, b) => b.proj.z - a.proj.z);

    for (const node of allNodes) {
      const { proj, type, label } = node;
      if (!proj.visible) continue;

      if (type === "hub") {
        const baseSize = 7;
        const pulse = 0.85 + 0.15 * Math.sin(this.time * 2.5 + proj.x * 0.1);
        const s = baseSize * proj.scale * pulse;
        const glowR = s * 3.5;

        const g = ctx.createRadialGradient(
          proj.x,
          proj.y,
          0,
          proj.x,
          proj.y,
          glowR,
        );
        g.addColorStop(0, `rgba(139, 92, 246, ${0.55 * proj.scale})`);
        g.addColorStop(0.4, `rgba(139, 92, 246, ${0.15 * proj.scale})`);
        g.addColorStop(1, "rgba(139, 92, 246, 0)");
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, glowR, 0, Math.PI * 2);
        ctx.fillStyle = g;
        ctx.fill();
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, s, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(180, 160, 255, ${0.95 * proj.scale})`;
        ctx.fill();
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, s * 2, 0, Math.PI * 2);
        ctx.strokeStyle = `rgba(139, 92, 246, ${0.4 * proj.scale * pulse})`;
        ctx.lineWidth = 1.5;
        ctx.stroke();
      } else {
        const baseSize = 3;
        const pulse = 0.85 + 0.15 * Math.sin(this.time * 2.5 + proj.x * 0.1);
        const s = baseSize * proj.scale * pulse;
        const glowR = s * 3.5;

        const flash = this.providerPingFlashes[label] || 0;
        const greenAlpha = 0.45 + flash * 0.5;
        const coreAlpha = 0.9 + flash * 0.1;

        const g = ctx.createRadialGradient(
          proj.x,
          proj.y,
          0,
          proj.x,
          proj.y,
          glowR * 0.7,
        );
        g.addColorStop(0, `rgba(52, 211, 153, ${greenAlpha * proj.scale})`);
        g.addColorStop(
          0.5,
          `rgba(52, 211, 153, ${(0.12 + flash * 0.3) * proj.scale})`,
        );
        g.addColorStop(1, "rgba(52, 211, 153, 0)");
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, glowR * (0.7 + flash * 0.4), 0, Math.PI * 2);
        ctx.fillStyle = g;
        ctx.fill();
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, s * (1 + flash * 0.3), 0, Math.PI * 2);
        ctx.fillStyle = `rgba(74, 222, 170, ${Math.min(1, coreAlpha) * proj.scale})`;
        ctx.fill();
      }
    }
  }

  drawArcs(ctx) {
    for (const lc of this.lifecycles) {
      const fade = lc.fadeOut;

      if (
        lc.phase === "inbound" ||
        lc.phase === "fanout" ||
        lc.phase === "fading"
      ) {
        this.drawArcTrail(ctx, lc.inboundPath, lc.inboundProgress, fade);
      }

      if (lc.phase === "fanout" || lc.phase === "fading") {
        for (const arc of lc.fanoutArcs) {
          this.drawArcTrail(ctx, arc.path, arc.progress, fade);
        }
      }
    }
  }

  drawArcTrail(ctx, points, progress, fade) {
    let prevProj = null;
    for (let i = 0; i < points.length; i++) {
      const t = i / (points.length - 1);
      const proj = this.project(points[i]);
      if (!proj.visible) {
        prevProj = null;
        continue;
      }

      const headDist = Math.abs(t - progress);
      const trail = Math.max(0, 1 - headDist / 0.25);
      const laid = t <= progress ? 0.18 : 0;
      const alpha = Math.max(trail * 0.9, laid) * proj.scale * fade;

      if (alpha < 0.01) {
        prevProj = proj;
        continue;
      }

      if (prevProj) {
        ctx.beginPath();
        ctx.moveTo(prevProj.x, prevProj.y);
        ctx.lineTo(proj.x, proj.y);
        ctx.strokeStyle = `rgba(120, 140, 220, ${alpha})`;
        ctx.lineWidth = 1.5 + trail * 2;
        ctx.stroke();
      }

      if (trail > 0.7) {
        const dotR = 3 * proj.scale;
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, dotR, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(200, 215, 255, ${trail * 0.95 * proj.scale * fade})`;
        ctx.fill();
        const hg = ctx.createRadialGradient(
          proj.x,
          proj.y,
          0,
          proj.x,
          proj.y,
          10 * proj.scale,
        );
        hg.addColorStop(0, `rgba(100, 130, 220, ${0.5 * proj.scale * fade})`);
        hg.addColorStop(1, "rgba(80, 110, 200, 0)");
        ctx.beginPath();
        ctx.arc(proj.x, proj.y, 10 * proj.scale, 0, Math.PI * 2);
        ctx.fillStyle = hg;
        ctx.fill();
      }

      prevProj = proj;
    }
  }

  drawHubPulses(ctx) {
    for (const lc of this.lifecycles) {
      if (lc.hubPulse < 0.05) continue;
      const hubPos = latLngTo3D(lc.hub.lat, lc.hub.lng, 1.0);
      const proj = this.project(hubPos);
      if (!proj.visible) continue;

      const maxRadius = 20 * proj.scale;
      const pulseRadius = maxRadius * (1 - lc.hubPulse * 0.5);

      ctx.beginPath();
      ctx.arc(proj.x, proj.y, pulseRadius, 0, Math.PI * 2);
      ctx.strokeStyle = `rgba(139, 92, 246, ${lc.hubPulse * 0.6 * proj.scale})`;
      ctx.lineWidth = 2 * proj.scale;
      ctx.stroke();
    }
  }

  drawRim(ctx) {
    const g = ctx.createRadialGradient(
      this.cx,
      this.cy,
      this.radius * 0.92,
      this.cx,
      this.cy,
      this.radius * 1.1,
    );
    g.addColorStop(0, "rgba(70, 90, 160, 0)");
    g.addColorStop(0.35, "rgba(70, 90, 160, 0.12)");
    g.addColorStop(0.65, "rgba(50, 70, 140, 0.05)");
    g.addColorStop(1, "rgba(0, 0, 0, 0)");
    ctx.beginPath();
    ctx.arc(this.cx, this.cy, this.radius * 1.1, 0, Math.PI * 2);
    ctx.fillStyle = g;
    ctx.fill();
  }

  setScrollOffset(rotationOffset, tiltOffset) {
    this.scrollRotationOffset = rotationOffset;
    this.scrollTiltOffset = tiltOffset;
  }

  destroy() {
    this.destroyed = true;
    if (this.animationId) cancelAnimationFrame(this.animationId);
    if (this.resizeObserver) this.resizeObserver.disconnect();
  }
}

export { GlobeRenderer };
export default GlobeRenderer;
