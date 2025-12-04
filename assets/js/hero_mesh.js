/**
 * HeroMesh - Dynamic mesh visualization with parallax and interactive effects
 *
 * This module handles:
 * - Real-time connection line recalculation during parallax
 * - Mouse-tracking organic mesh distortion
 * - Ambient breathing/pulsing animations
 * - Node hover interactions
 */

// Configuration for mesh behavior
const CONFIG = {
  // Parallax layer depths (how much each layer moves relative to scroll)
  parallax: {
    particles: { translateX: -15, translateY: 20 },
    edges: { translateX: -18, translateY: 38 },
    providers: { translateX: -8, translateY: 6 },
    chains: { translateX: 5, translateY: 20 },
    core: { translateX: -3, translateY: -20 },
  },

  // Ambient animation settings (applied as visual-only layer transforms)
  ambient: {
    breatheSpeed: 0.0005, // Speed of ambient breathing
    breatheAmount: 10, // Max pixel displacement from breathing (reduced for subtlety)
    driftSpeed: 0.0003, // Speed of ambient drift
    driftAmount: 10, // Max pixel displacement from drift
  },

  // Traffic particle settings
  traffic: {
    // Which connection types should have traffic particles
    enabledTypes: ["hub-chain", "chain-provider"],
    spawnInterval: 2000, // ms between spawns per connection
    spawnChance: 0.5, // 50% chance to spawn when interval passes
    speed: 0.0003, // Progress per ms (slower, more relaxed)
    speedVariance: 0.5, // Higher variance for more organic feel
    particleRadius: 1.7,
    particleColor: "#64748b", // Slate gray (matches line colors)
    particleOpacity: 0.5,
    maxParticles: 30,
  },
};

/**
 * MeshNode - Represents a single node in the mesh
 */
class MeshNode {
  constructor(element, layer, baseX, baseY, id) {
    this.element = element;
    this.layer = layer;
    this.id = id;

    // Base position (from SVG)
    this.baseX = baseX;
    this.baseY = baseY;

    // Current computed position (after all transforms)
    this.x = baseX;
    this.y = baseY;

    // Animation offsets
    this.parallaxOffset = { x: 0, y: 0 };
    this.ambientOffset = { x: 0, y: 0 };
  }

  updatePosition() {
    // Include both parallax and ambient offsets
    // This keeps connections aligned with visual node positions
    this.x = this.baseX + this.parallaxOffset.x + this.ambientOffset.x;
    this.y = this.baseY + this.parallaxOffset.y + this.ambientOffset.y;
  }
}

/**
 * MeshConnection - Represents a connection line between two nodes
 */
class MeshConnection {
  constructor(pathElement, fromNode, toNode, type) {
    this.element = pathElement;
    this.from = fromNode;
    this.to = toNode;
    this.type = type; // 'hub-chain', 'chain-provider', 'cross-chain', 'cross-provider', 'provider-edge'
    this.isCurved = type.startsWith("cross");
  }

  updatePath(cx, cy) {
    if (this.isCurved) {
      // Quadratic bezier through center point
      this.element.setAttribute(
        "d",
        `M ${this.from.x} ${this.from.y} Q ${cx} ${cy} ${this.to.x} ${this.to.y}`
      );
    } else {
      // Straight line
      this.element.setAttribute(
        "d",
        `M ${this.from.x} ${this.from.y} L ${this.to.x} ${this.to.y}`
      );
    }
  }

  /**
   * Get a point along this connection at parameter t (0-1)
   */
  getPointAt(t, cx, cy) {
    if (this.isCurved) {
      // Quadratic bezier: B(t) = (1-t)²P0 + 2(1-t)tP1 + t²P2
      const t1 = 1 - t;
      const t1sq = t1 * t1;
      const tsq = t * t;
      return {
        x: t1sq * this.from.x + 2 * t1 * t * cx + tsq * this.to.x,
        y: t1sq * this.from.y + 2 * t1 * t * cy + tsq * this.to.y,
      };
    } else {
      // Linear interpolation
      return {
        x: this.from.x + t * (this.to.x - this.from.x),
        y: this.from.y + t * (this.to.y - this.from.y),
      };
    }
  }
}

/**
 * TrafficParticle - A particle that animates along a connection
 */
class TrafficParticle {
  constructor(connection, element, speed, direction) {
    this.connection = connection;
    this.element = element;
    this.speed = speed; // 0-1 progress per second
    this.direction = direction; // 1 = from->to, -1 = to->from
    this.progress = direction === 1 ? 0 : 1;
    this.alive = true;
  }

  update(dt, cx, cy) {
    // Update progress
    this.progress += this.direction * this.speed * dt;

    // Check if particle has completed its journey
    if (this.progress > 1 || this.progress < 0) {
      this.alive = false;
      return;
    }

    // Get position along the path
    const pos = this.connection.getPointAt(this.progress, cx, cy);
    this.element.setAttribute("cx", pos.x);
    this.element.setAttribute("cy", pos.y);
  }
}

/**
 * HeroMesh - Main mesh controller
 */
export class HeroMesh {
  constructor(containerEl, svgEl, scrollContainer) {
    this.container = containerEl;
    this.svg = svgEl;
    this.scrollContainer = scrollContainer;

    // Mesh center (for curved connections)
    this.cx = 640;
    this.cy = 540;

    // Node and connection registries
    this.nodes = new Map(); // id -> MeshNode
    this.connections = []; // MeshConnection[]
    this.layers = {}; // layerName -> { element, nodes[] }

    // Animation state
    this.animationId = null;
    this.lastTime = 0;
    this.scrollProgress = 0;

    // Mouse tracking
    this.mouse = { x: 0, y: 0 };
    this.mouseInContainer = false;

    // Traffic particles
    this.trafficParticles = [];
    this.trafficGroup = null;
    this.lastSpawnTime = {};
    this.trafficConnections = []; // Connections eligible for traffic

    // Initialize
    this.parseStructure();
    this.createDynamicConnections();
    this.createTrafficLayer();
    this.setupEventListeners();
    this.startAnimation();
  }

  /**
   * Parse the SVG structure and build node registry
   */
  parseStructure() {
    // Get center coordinates from SVG data attributes
    const cxAttr = this.svg.getAttribute("data-mesh-cx");
    const cyAttr = this.svg.getAttribute("data-mesh-cy");
    if (cxAttr) this.cx = parseFloat(cxAttr);
    if (cyAttr) this.cy = parseFloat(cyAttr);

    // Find all layers
    const layerNames = ["particles", "edges", "providers", "chains", "core"];
    layerNames.forEach((name) => {
      const layerEl = this.svg.querySelector(`[data-parallax-layer="${name}"]`);
      if (layerEl) {
        this.layers[name] = {
          element: layerEl,
          nodes: [],
          config: CONFIG.parallax[name],
        };
      }
    });

    // Parse all nodes from data attributes
    this.svg.querySelectorAll("[data-mesh-node]").forEach((el) => {
      const id = el.getAttribute("data-mesh-node");
      const x = parseFloat(el.getAttribute("data-mesh-x"));
      const y = parseFloat(el.getAttribute("data-mesh-y"));
      const layer = el.getAttribute("data-mesh-layer");

      if (id && !isNaN(x) && !isNaN(y) && layer) {
        const node = new MeshNode(el, layer, x, y, id);
        this.nodes.set(id, node);

        if (this.layers[layer]) {
          this.layers[layer].nodes.push(node);
        }
      }
    });

    console.log(
      `HeroMesh: Parsed ${this.nodes.size} nodes across ${
        Object.keys(this.layers).length
      } layers`
    );

    // Debug: log layer details
    Object.entries(this.layers).forEach(([name, layer]) => {
      console.log(`  Layer "${name}": ${layer.nodes.length} nodes, element:`, layer.element);
    });
  }

  /**
   * Create dynamic connection elements that will be updated each frame
   */
  createDynamicConnections() {
    // Find the connection definitions group (even though it has display:none, we can still query it)
    const defsGroup = this.svg.querySelector("[data-mesh-connection-defs]");

    // Find or create the visible connections group
    let connectionsGroup = this.svg.querySelector("[data-mesh-connections]");
    if (!connectionsGroup) {
      connectionsGroup = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "g"
      );
      connectionsGroup.setAttribute("data-mesh-connections", "true");
      // Insert after defs but before the glow circle - find the glow or first layer
      const glowCircle = this.svg.querySelector(
        'circle[fill="url(#glow-grad)"]'
      );
      const firstLayer = this.svg.querySelector("[data-parallax-layer]");
      const insertBefore = firstLayer || glowCircle;
      if (insertBefore) {
        insertBefore.parentNode.insertBefore(connectionsGroup, insertBefore);
      } else {
        this.svg.appendChild(connectionsGroup);
      }
    }

    // Store reference for later checks
    this.connectionsGroup = connectionsGroup;

    // Clear existing dynamic connections
    connectionsGroup.innerHTML = "";
    this.connections = [];

    // Store connection definitions for rebuilding if needed
    this.connectionDefs = [];

    // If we have definition templates, parse them
    if (defsGroup) {
      defsGroup.querySelectorAll("path[data-mesh-from]").forEach((el) => {
        const fromId = el.getAttribute("data-mesh-from");
        const toId = el.getAttribute("data-mesh-to");
        const type = el.getAttribute("data-mesh-connection-type") || "default";

        // Store definition for potential rebuild
        this.connectionDefs.push({
          fromId,
          toId,
          type,
          stroke: el.getAttribute("stroke") || "#334155",
          strokeWidth: el.getAttribute("stroke-width") || "0.6",
          opacity: el.getAttribute("opacity") || "0.2",
          dash: el.getAttribute("stroke-dasharray") || "",
        });

        const fromNode = this.nodes.get(fromId);
        const toNode = this.nodes.get(toId);

        if (fromNode && toNode) {
          // Create a new path element for dynamic updates
          const path = document.createElementNS(
            "http://www.w3.org/2000/svg",
            "path"
          );

          // Copy styling from template
          path.setAttribute("stroke", el.getAttribute("stroke") || "#334155");
          path.setAttribute(
            "stroke-width",
            el.getAttribute("stroke-width") || "0.6"
          );
          path.setAttribute("fill", "none");
          path.setAttribute("opacity", el.getAttribute("opacity") || "0.2");

          const dash = el.getAttribute("stroke-dasharray");
          if (dash && dash !== "") {
            path.setAttribute("stroke-dasharray", dash);
          }

          connectionsGroup.appendChild(path);

          const connection = new MeshConnection(path, fromNode, toNode, type);
          this.connections.push(connection);

          // Initial path update
          connection.updatePath(this.cx, this.cy);
        }
      });

      // Hide the defs group (should already be hidden but be sure)
      defsGroup.style.display = "none";
    }

    console.log(
      `HeroMesh: Created ${this.connections.length} dynamic connections`
    );
  }

  /**
   * Check if connections group still exists and has children, rebuild if needed
   */
  ensureConnections() {
    // Check if our connections group was removed or emptied
    if (
      !this.connectionsGroup ||
      !this.connectionsGroup.parentNode ||
      this.connectionsGroup.children.length === 0
    ) {
      console.log(
        "HeroMesh: Connections group missing or empty, rebuilding..."
      );

      // Re-find or create the connections group
      let connectionsGroup = this.svg.querySelector("[data-mesh-connections]");
      if (!connectionsGroup) {
        connectionsGroup = document.createElementNS(
          "http://www.w3.org/2000/svg",
          "g"
        );
        connectionsGroup.setAttribute("data-mesh-connections", "true");
        const firstLayer = this.svg.querySelector("[data-parallax-layer]");
        if (firstLayer) {
          firstLayer.parentNode.insertBefore(connectionsGroup, firstLayer);
        } else {
          this.svg.appendChild(connectionsGroup);
        }
      }

      this.connectionsGroup = connectionsGroup;
      this.connections = [];

      // Rebuild connections from stored definitions
      for (const def of this.connectionDefs) {
        const fromNode = this.nodes.get(def.fromId);
        const toNode = this.nodes.get(def.toId);

        if (fromNode && toNode) {
          const path = document.createElementNS(
            "http://www.w3.org/2000/svg",
            "path"
          );
          path.setAttribute("stroke", def.stroke);
          path.setAttribute("stroke-width", def.strokeWidth);
          path.setAttribute("fill", "none");
          path.setAttribute("opacity", def.opacity);

          if (def.dash) {
            path.setAttribute("stroke-dasharray", def.dash);
          }

          connectionsGroup.appendChild(path);

          const connection = new MeshConnection(
            path,
            fromNode,
            toNode,
            def.type
          );
          this.connections.push(connection);
          connection.updatePath(this.cx, this.cy);
        }
      }

      console.log(`HeroMesh: Rebuilt ${this.connections.length} connections`);
    }
  }

  /**
   * Create the traffic particle layer and identify eligible connections
   */
  createTrafficLayer() {
    // Create SVG group for traffic particles
    this.trafficGroup = document.createElementNS(
      "http://www.w3.org/2000/svg",
      "g"
    );
    this.trafficGroup.setAttribute("data-mesh-traffic", "true");

    // Insert after connections group but before layers
    const firstLayer = this.svg.querySelector("[data-parallax-layer]");
    if (firstLayer && this.connectionsGroup) {
      firstLayer.parentNode.insertBefore(this.trafficGroup, firstLayer);
    } else if (this.connectionsGroup) {
      this.connectionsGroup.parentNode.insertBefore(
        this.trafficGroup,
        this.connectionsGroup.nextSibling
      );
    } else {
      this.svg.appendChild(this.trafficGroup);
    }

    // Identify connections eligible for traffic particles
    const { enabledTypes } = CONFIG.traffic;
    this.trafficConnections = this.connections.filter((conn) =>
      enabledTypes.includes(conn.type)
    );

    // Initialize spawn timers for each traffic connection
    this.trafficConnections.forEach((_, i) => {
      // Stagger initial spawn times so particles don't all spawn at once
      this.lastSpawnTime[i] =
        -i * (CONFIG.traffic.spawnInterval / this.trafficConnections.length);
    });

    console.log(
      `HeroMesh: Traffic enabled on ${this.trafficConnections.length} connections`
    );
  }

  /**
   * Spawn a new traffic particle on a connection
   */
  spawnParticle(connection) {
    const {
      particleRadius,
      particleColor,
      particleOpacity,
      speed,
      speedVariance,
    } = CONFIG.traffic;

    // Create particle element (no expensive CSS filters)
    const circle = document.createElementNS(
      "http://www.w3.org/2000/svg",
      "circle"
    );
    circle.setAttribute("r", particleRadius);
    circle.setAttribute("fill", particleColor);
    circle.setAttribute("opacity", particleOpacity);

    this.trafficGroup.appendChild(circle);

    // Randomize speed with higher variance for organic feel
    const variance = 1 + (Math.random() * 2 - 1) * speedVariance;
    const particleSpeed = speed * variance;

    const particle = new TrafficParticle(
      connection,
      circle,
      particleSpeed,
      1 // direction: from -> to
    );

    // Set initial position
    const pos = connection.getPointAt(0, this.cx, this.cy);
    circle.setAttribute("cx", pos.x);
    circle.setAttribute("cy", pos.y);

    this.trafficParticles.push(particle);
  }

  /**
   * Update traffic particles - spawn new ones and update existing
   */
  updateTraffic(time, dt) {
    const { spawnInterval, spawnChance, maxParticles } = CONFIG.traffic;

    // Only check spawning occasionally, not every frame
    if (this.trafficParticles.length < maxParticles) {
      // Pick a random connection to potentially spawn on
      const i = Math.floor(Math.random() * this.trafficConnections.length);
      const conn = this.trafficConnections[i];
      const lastSpawn = this.lastSpawnTime[i] || 0;

      if (time - lastSpawn >= spawnInterval && Math.random() < spawnChance) {
        this.spawnParticle(conn);
        this.lastSpawnTime[i] = time;
      }
    }

    // Update existing particles and remove dead ones
    for (let i = this.trafficParticles.length - 1; i >= 0; i--) {
      const particle = this.trafficParticles[i];
      particle.update(dt, this.cx, this.cy);

      if (!particle.alive) {
        // Remove from DOM and array
        particle.element.remove();
        this.trafficParticles.splice(i, 1);
      }
    }
  }

  /**
   * Ensure traffic group exists (for LiveView DOM patching recovery)
   */
  ensureTrafficGroup() {
    if (!this.trafficGroup || !this.trafficGroup.parentNode) {
      this.createTrafficLayer();
      // Clear existing particles since their elements are gone
      this.trafficParticles = [];
    }
  }

  /**
   * Setup event listeners for scroll, mouse, and resize
   */
  setupEventListeners() {
    // Scroll handling
    if (this.scrollContainer) {
      this.handleScroll = () => {
        const maxScroll =
          this.scrollContainer.scrollHeight - this.scrollContainer.clientHeight;
        this.scrollProgress =
          maxScroll > 0
            ? Math.min(
                Math.max(this.scrollContainer.scrollTop / maxScroll, 0),
                1
              )
            : 0;
      };
      this.scrollContainer.addEventListener("scroll", this.handleScroll, {
        passive: true,
      });
      this.handleScroll(); // Initial call
    }

    // Mouse tracking on container
    this.handleMouseMove = (e) => {
      const rect = this.container.getBoundingClientRect();
      this.mouse.x = e.clientX - rect.left;
      this.mouse.y = e.clientY - rect.top;
      this.mouseInContainer = true;
    };

    this.handleMouseLeave = () => {
      this.mouseInContainer = false;
    };

    this.container.addEventListener("mousemove", this.handleMouseMove, {
      passive: true,
    });
    this.container.addEventListener("mouseleave", this.handleMouseLeave, {
      passive: true,
    });
  }

  /**
   * Start the animation loop
   */
  startAnimation() {
    let frameCount = 0;
    let lastFrameTime = 0;
    const targetFPS = 30; // Target 30fps for smoother performance
    const frameInterval = 1000 / targetFPS;
    let accumulator = 0;

    const animate = (time) => {
      const dt = lastFrameTime > 0 ? time - lastFrameTime : 16;
      lastFrameTime = time;
      this.lastTime = time;
      accumulator += dt;

      // Throttle to target FPS
      if (accumulator >= frameInterval) {
        accumulator = accumulator % frameInterval;

        // Check every ~2 seconds if connections/traffic need rebuilding
        frameCount++;
        if (frameCount % 60 === 0) {
          this.ensureConnections();
          this.ensureTrafficGroup();
        }

        this.updateParallax();
        this.updateNodePositions();
        this.updateConnections();
        this.updateLayerTransforms();
        this.updateTraffic(time, dt);
      }

      this.animationId = requestAnimationFrame(animate);
    };

    this.animationId = requestAnimationFrame(animate);
  }

  /**
   * Update parallax offsets based on scroll position
   */
  updateParallax() {
    const easeOutQuad = 1 - Math.pow(1 - this.scrollProgress, 2);
    const easeOutCubic = 1 - Math.pow(1 - this.scrollProgress, 3);

    Object.entries(this.layers).forEach(([layerName, layer]) => {
      const config = layer.config;
      if (!config) return;

      // Outer layers use cubic (more dramatic), inner use quad (smoother)
      const isOuter = ["particles", "edges"].includes(layerName);
      const ease = isOuter ? easeOutCubic : easeOutQuad;

      const offsetX = ease * config.translateX;
      const offsetY = ease * config.translateY;

      // Update all nodes in this layer with parallax offset
      // This is used for connection path calculations
      layer.nodes.forEach((node) => {
        node.parallaxOffset.x = offsetX;
        node.parallaxOffset.y = offsetY;
      });

      // Store parallax offset on layer for use in updateLayerTransforms
      layer.parallaxOffset = { x: offsetX, y: offsetY };
    });
  }

  /**
   * Apply combined transforms to layer elements (parallax + ambient)
   * Also updates node ambient offsets so connections stay aligned with visual nodes
   */
  updateLayerTransforms() {
    const { breatheSpeed, breatheAmount, driftSpeed, driftAmount } =
      CONFIG.ambient;
    const time = this.lastTime;

    Object.entries(this.layers).forEach(([layerName, layer]) => {
      const parallax = layer.parallaxOffset || { x: 0, y: 0 };

      // Calculate layer-wide ambient motion (use a consistent phase per layer)
      const layerPhase = layerName.length * 0.5; // Simple deterministic phase per layer
      const breathe =
        Math.sin(time * breatheSpeed + layerPhase) * breatheAmount;
      const driftX = Math.sin(time * driftSpeed + layerPhase) * driftAmount;
      const driftY =
        Math.cos(time * driftSpeed * 1.3 + layerPhase) * driftAmount * 0.7;

      // Layer-based intensity (outer = more movement)
      const intensity = ["particles", "edges"].includes(layerName)
        ? 1.0
        : ["providers"].includes(layerName)
        ? 0.6
        : ["chains"].includes(layerName)
        ? 0.3
        : 0.1;

      const ambientX = (driftX + breathe * 0.3) * intensity;
      const ambientY = (driftY + breathe * 0.5) * intensity;

      // Update each node's ambient offset so connections follow the breathing
      // This ensures connection endpoints match where the visual nodes appear
      layer.nodes.forEach((node) => {
        node.ambientOffset.x = ambientX;
        node.ambientOffset.y = ambientY;
      });

      // Apply combined transform to layer element (parallax + ambient)
      // This moves the visual nodes; the ambient offset on nodes keeps connections aligned
      const totalX = parallax.x + ambientX;
      const totalY = parallax.y + ambientY;

      layer.element.setAttribute(
        "transform",
        `translate(${totalX}, ${totalY})`
      );
    });
  }

  /**
   * Update all node final positions
   */
  updateNodePositions() {
    this.nodes.forEach((node) => {
      node.updatePosition();
    });
  }

  /**
   * Update all connection paths
   */
  updateConnections() {
    this.connections.forEach((conn) => {
      conn.updatePath(this.cx, this.cy);
    });
  }

  /**
   * Cleanup when destroyed
   */
  destroy() {
    if (this.animationId) {
      cancelAnimationFrame(this.animationId);
    }

    if (this.scrollContainer) {
      this.scrollContainer.removeEventListener("scroll", this.handleScroll);
    }

    this.container.removeEventListener("mousemove", this.handleMouseMove);
    this.container.removeEventListener("mouseleave", this.handleMouseLeave);

    // Clean up traffic particles
    this.trafficParticles.forEach((p) => p.element.remove());
    this.trafficParticles = [];
    if (this.trafficGroup) {
      this.trafficGroup.remove();
    }
  }
}

export default HeroMesh;
