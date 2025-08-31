// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// Enhanced Simulator module
import * as LassoSim from "./lasso_simulator";

// Collapsible Section Hook
const CollapsibleSection = {
  mounted() {
    this.isOpen = true; // Start open by default
    this.button = this.el.querySelector("button");
    this.contentContainer = this.el.children[1]; // The div after the button
    this.previewDiv = this.contentContainer.children[0]; // First child: preview
    this.fullContentDiv = this.contentContainer.children[1]; // Second child: full content
    this.arrow = this.button.querySelector("svg").parentElement;

    this.button.addEventListener("click", () => this.toggle());

    // Initialize in open state
    this.expand();
  },

  toggle() {
    this.isOpen = !this.isOpen;

    if (this.isOpen) {
      this.expand();
    } else {
      this.collapse();
    }
  },

  expand() {
    this.contentContainer.style.height = "auto";
    this.contentContainer.style.minHeight = "24rem"; // min-h-96
    this.previewDiv.style.display = "none";
    this.fullContentDiv.style.display = "block";
    this.arrow.style.transform = "rotate(180deg)";
  },

  collapse() {
    this.contentContainer.style.height = "3rem"; // h-12
    this.contentContainer.style.minHeight = "auto";
    this.previewDiv.style.display = "block";
    this.fullContentDiv.style.display = "none";
    this.arrow.style.transform = "rotate(0deg)";
  },
};

// Lightweight client-side event buffer
const EventsFeed = {
  mounted() {
    const sizeAttr = this.el.getAttribute("data-buffer-size");
    this.maxSize = (sizeAttr && parseInt(sizeAttr, 10)) || 500;
    this.buffer = [];

    // Allow other components to access the buffer via window
    window.__LivechainEventsFeed = {
      latest: (n = 50, predicate = null) => {
        const items = predicate ? this.buffer.filter(predicate) : this.buffer;
        return items.slice(-n);
      },
    };

    this.handleEvent("events_batch", ({ items }) => {
      if (Array.isArray(items)) {
        // Append and trim to ring buffer size
        this.buffer.push(...items);
        if (this.buffer.length > this.maxSize) {
          this.buffer.splice(0, this.buffer.length - this.maxSize);
        }
      }
    });
  },
};

// Auto-scroll hook for terminal-style feeds (with flex-col-reverse)
const TerminalFeed = {
  mounted() {
    // For reversed columns, bottom is scrollTop = 0
    this.scrollToBottom();
  },
  updated() {
    this.scrollToBottom();
  },
  scrollToBottom() {
    try {
      // Snap to bottom for reversed feeds
      this.el.scrollTop = 0;
    } catch (_) {}
  },
};

const SimulatorControl = {
  mounted() {
    this.httpTimer = null;
    this.wsHandles = [];
    this.recentCalls = [];
    this.maxRecentCalls = 50;

    // Parse available chains from data attribute
    try {
      const chainsData = this.el.getAttribute("data-available-chains");
      this.availableChains = chainsData ? JSON.parse(chainsData) : [];
      console.log("Available chains:", this.availableChains);

      // Make chains available to the simulator module
      LassoSim.setAvailableChains(this.availableChains);

      // Set callback for activity tracking
      LassoSim.setActivityCallback((activity) => {
        this.trackActivity(activity);
      });
    } catch (e) {
      console.error("Failed to parse available chains:", e);
      this.availableChains = [];
    }

    // Modern run-based event handlers
    this.handleEvent("start_simulator_run", (config) => {
      console.log("Starting simulator run with config:", config);
      this.startSimulatorRun(config);
    });

    this.handleEvent("stop_all_runs", () => {
      console.log("Stopping all simulator runs");
      LassoSim.stopAllRuns();
    });

    this.handleEvent("stop_run", ({ run_id }) => {
      console.log("Stopping simulator run:", run_id);
      LassoSim.stopRun(run_id);
    });

    // Legacy handlers for backward compatibility
    this.handleEvent("sim_start_http", (opts) => {
      console.log("sim_start_http (legacy) received with opts:", opts);
      LassoSim.startHttpLoad(opts);
    });

    this.handleEvent("sim_stop_http", () => {
      LassoSim.stopHttpLoad();
    });

    this.handleEvent("sim_start_ws", (opts) => {
      console.log("sim_start_ws (legacy) received with opts:", opts);
      LassoSim.startWsLoad(opts);
    });

    this.handleEvent("sim_stop_ws", () => {
      LassoSim.stopWsLoad();
    });

    this.handleEvent("sim_start_http_advanced", (opts) => {
      console.log("sim_start_http_advanced (legacy) received with opts:", opts);
      LassoSim.startHttpLoad(opts);
    });

    this.handleEvent("sim_start_ws_advanced", (opts) => {
      console.log("sim_start_ws_advanced (legacy) received with opts:", opts);
      LassoSim.startWsLoad(opts);
    });

    this.handleEvent("clear_sim_logs", () => {
      this.recentCalls = [];
      // No need to push event, component handles clearing internally
    });

    // Stats and activity update interval - only send updates when simulator is running
    // Completion events are now handled immediately via trackActivity
    this.statsInterval = setInterval(() => {
      if (
        this.el.isConnected &&
        window.liveSocket &&
        window.liveSocket.isConnected() &&
        LassoSim.isRunning() // Only update when simulator is actually running
      ) {
        const stats = LassoSim.activeStats();
        const activeRuns = LassoSim.getActiveRuns();

        // Send updates directly to the SimulatorControls component
        this.pushEvent("sim_stats", stats);
        this.pushEvent("active_runs_update", { runs: activeRuns });
        this.pushEvent("update_recent_calls", {
          calls: this.recentCalls.slice(-8),
        });
      }
    }, 500); // Reduce frequency from 200ms to 500ms
  },

  startSimulatorRun(config) {
    try {
      // Use the new run-based API
      const run = LassoSim.startRun(config);
      console.log("Started simulator run:", run.id, config);

      // Immediately update active runs
      const activeRuns = LassoSim.getActiveRuns();
      this.pushEvent("active_runs_update", { runs: activeRuns });
    } catch (error) {
      console.error("Failed to start simulator run:", error);
    }
  },

  trackActivity(activity) {
    // Add timestamp if not present
    if (!activity.timestamp) {
      activity.timestamp = Date.now();
    }

    // Add to recent calls buffer
    this.recentCalls.push(activity);

    // Keep buffer size manageable
    if (this.recentCalls.length > this.maxRecentCalls) {
      this.recentCalls.shift();
    }

    // Handle run completion notifications immediately
    if (activity.type === "run" && activity.status === "stopped") {
      // Send immediate notification when run completes
      if (
        this.el.isConnected &&
        this.pushEvent &&
        window.liveSocket &&
        window.liveSocket.isConnected()
      ) {
        console.log("Run completed, sending immediate update:", activity);

        // Update active runs and stats immediately
        const activeRuns = LassoSim.getActiveRuns();
        const stats = LassoSim.activeStats();

        this.pushEvent("active_runs_update", { runs: activeRuns });
        this.pushEvent("sim_stats", stats);

        // Update recent calls to show completion
        this.pushEvent("update_recent_calls", {
          calls: this.recentCalls.slice(-8),
        });
      }
    } else {
      // Normal immediate update for real-time feel (throttled by the interval above)
      if (
        this.el.isConnected &&
        this.pushEvent &&
        window.liveSocket &&
        window.liveSocket.isConnected() &&
        LassoSim.isRunning()
      ) {
        clearTimeout(this.immediateUpdate);
        this.immediateUpdate = setTimeout(() => {
          this.pushEvent("update_recent_calls", {
            calls: this.recentCalls.slice(-8),
          });
        }, 100);
      }
    }
  },

  destroyed() {
    clearInterval(this.statsInterval);
    clearTimeout(this.immediateUpdate);
    LassoSim.stopHttpLoad();
    LassoSim.stopWsLoad();
  },
};

// Draggable Network Viewport Hook
const DraggableNetworkViewport = {
  mounted() {
    this.isDragging = false;
    this.startX = 0;
    this.startY = 0;
    this.translateX = 0;
    this.translateY = 0;
    this.scale = 1;
    this.animationId = null;

    // Find the network container (the draggable content)
    this.networkContainer = this.el.querySelector("[data-draggable-content]");
    if (!this.networkContainer) {
      console.warn(
        "DraggableNetworkViewport: No element with data-draggable-content found"
      );
      return;
    }

    // Find the actual canvas element (4000x3000) to transform; fallback to wrapper
    this.canvasEl =
      this.networkContainer.querySelector("[data-network-canvas]") ||
      this.networkContainer;

    // Compute initial transform to center the canvas in the viewport
    const viewportRect = this.el.getBoundingClientRect();
    const canvasWidth =
      this.canvasEl.scrollWidth || this.canvasEl.offsetWidth || 4000;
    const canvasHeight =
      this.canvasEl.scrollHeight || this.canvasEl.offsetHeight || 3000;

    this.translateX = viewportRect.width / 2 - canvasWidth / 2;
    this.translateY = viewportRect.height / 2 - canvasHeight / 2;
    this.updateTransform();

    // Mouse events
    this.el.addEventListener("mousedown", this.handleMouseDown.bind(this));
    this.el.addEventListener("mousemove", this.handleMouseMove.bind(this));
    this.el.addEventListener("mouseup", this.handleMouseUp.bind(this));
    this.el.addEventListener("mouseleave", this.handleMouseUp.bind(this));

    // Touch events for mobile
    this.el.addEventListener("touchstart", this.handleTouchStart.bind(this), {
      passive: false,
    });
    this.el.addEventListener("touchmove", this.handleTouchMove.bind(this), {
      passive: false,
    });
    this.el.addEventListener("touchend", this.handleTouchEnd.bind(this));

    // Zoom disabled - wheel events ignored (but we add programmatic zoom)

    // Prevent context menu on right click
    this.el.addEventListener("contextmenu", (e) => e.preventDefault());

    // Set cursor styles
    this.el.style.cursor = "grab";
    this.el.style.userSelect = "none";

    this.handleEvent("center_on_chain", ({ chain }) => {
      this.centerOnChain(chain, { zoom: 1.25 });
    });

    this.handleEvent("center_on_provider", ({ provider }) => {
      this.centerOnProvider(provider, { zoom: 1.4 });
    });

    this.handleEvent("zoom_out", () => {
      this.animateZoomTo(1);
    });
  },

  updated() {
    // Re-select canvas after LiveView patches and reapply current transform
    this.networkContainer =
      this.el.querySelector("[data-draggable-content]") ||
      this.networkContainer;
    this.canvasEl =
      (this.networkContainer &&
        this.networkContainer.querySelector("[data-network-canvas]")) ||
      this.canvasEl;
    this.updateTransform();
  },

  handleMouseDown(e) {
    // Only handle left mouse button
    if (e.button !== 0) return;

    this.isDragging = true;
    this.startX = e.clientX - this.translateX;
    this.startY = e.clientY - this.translateY;
    this.el.style.cursor = "grabbing";
    e.preventDefault();
  },

  handleMouseMove(e) {
    if (!this.isDragging) return;

    this.translateX = e.clientX - this.startX;
    this.translateY = e.clientY - this.startY;
    this.updateTransform();
    e.preventDefault();
  },

  handleMouseUp() {
    this.isDragging = false;
    this.el.style.cursor = "grab";
  },

  handleTouchStart(e) {
    if (e.touches.length === 1) {
      this.isDragging = true;
      const touch = e.touches[0];
      this.startX = touch.clientX - this.translateX;
      this.startY = touch.clientY - this.translateY;
      e.preventDefault();
    }
  },

  handleTouchMove(e) {
    if (!this.isDragging || e.touches.length !== 1) return;

    const touch = e.touches[0];
    this.translateX = touch.clientX - this.startX;
    this.translateY = touch.clientY - this.startY;
    this.updateTransform();
    e.preventDefault();
  },

  handleTouchEnd() {
    this.isDragging = false;
  },

  updateTransform() {
    const target = this.canvasEl || this.networkContainer;
    if (target) {
      target.style.transform = `translate(${this.translateX}px, ${this.translateY}px) scale(${this.scale})`;
      target.style.transformOrigin = "0 0";
    }
  },

  // Center the viewport on the first chain on initial load
  centerOnFirstChain() {
    setTimeout(() => {
      const firstChain = this.networkContainer?.querySelector(
        "[data-chain-center]"
      );
      if (firstChain) {
        const center = firstChain.getAttribute("data-chain-center");
        if (center) {
          const [x, y] = center.split(",").map(Number);
          this.animateTo(x, y);
        }
      }
    }, 100);
  },

  // Center viewport on a specific chain
  centerOnChain(chainName, opts = {}) {
    const chainElement = this.networkContainer?.querySelector(
      `[data-chain="${chainName}"]`
    );
    if (chainElement) {
      const center = chainElement.getAttribute("data-chain-center");
      if (center) {
        const [x, y] = center.split(",").map(Number);
        const zoom = opts.zoom || 1.25;
        this.animateTo(x, y, 800, zoom);
      }
    }
  },

  // Center viewport on a specific provider
  centerOnProvider(providerId, opts = {}) {
    const providerElement = this.networkContainer?.querySelector(
      `[data-provider="${providerId}"]`
    );
    if (providerElement) {
      const center = providerElement.getAttribute("data-provider-center");
      if (center) {
        const [x, y] = center.split(",").map(Number);
        const zoom = opts.zoom || 1.4;
        this.animateTo(x, y, 800, zoom);
      }
    }
  },

  // Smooth zoom animation to target scale while keeping the current center
  animateZoomTo(targetScale = 1, duration = 300) {
    if (this.animationId) cancelAnimationFrame(this.animationId);

    const startScale = this.scale;
    const startX = this.translateX;
    const startY = this.translateY;

    const viewportRect = this.el.getBoundingClientRect();
    const viewportCenterX = viewportRect.width / 2;
    const viewportCenterY = viewportRect.height / 2;

    const currentCanvasCenterX = (viewportCenterX - startX) / startScale;
    const currentCanvasCenterY = (viewportCenterY - startY) / startScale;

    const startTime = performance.now();

    const animate = (t) => {
      const progress = Math.min((t - startTime) / duration, 1);
      const ease = 1 - Math.pow(1 - progress, 3);
      this.scale = startScale + (targetScale - startScale) * ease;

      // Keep the same canvas point under the viewport center
      this.translateX = viewportCenterX - currentCanvasCenterX * this.scale;
      this.translateY = viewportCenterY - currentCanvasCenterY * this.scale;

      this.updateTransform();
      if (progress < 1) {
        this.animationId = requestAnimationFrame(animate);
      } else {
        this.animationId = null;
      }
    };

    this.animationId = requestAnimationFrame(animate);
  },

  // Smooth animation to center on specific coordinates, with optional zoom
  animateTo(targetX, targetY, duration = 800, targetScale = null) {
    if (this.animationId) {
      cancelAnimationFrame(this.animationId);
    }

    const viewportRect = this.el.getBoundingClientRect();
    const viewportCenterX = viewportRect.width / 2;
    const viewportCenterY = viewportRect.height / 2;

    const startTranslateX = this.translateX;
    const startTranslateY = this.translateY;
    const startScale = this.scale;

    // If targetScale provided, animate scale too, keeping target point centered
    const finalScale = targetScale == null ? this.scale : targetScale;

    // Compute the translation needed at the final scale
    const targetTranslateX_final = viewportCenterX - targetX * finalScale;
    const targetTranslateY_final = viewportCenterY - targetY * finalScale;

    const startTime = performance.now();

    const animate = (currentTime) => {
      const elapsed = currentTime - startTime;
      const progress = Math.min(elapsed / duration, 1);
      const easeProgress = 1 - Math.pow(1 - progress, 3);

      // Interpolate scale and translation
      this.scale = startScale + (finalScale - startScale) * easeProgress;
      this.translateX =
        startTranslateX +
        (targetTranslateX_final - startTranslateX) * easeProgress;
      this.translateY =
        startTranslateY +
        (targetTranslateY_final - startTranslateY) * easeProgress;

      this.updateTransform();

      if (progress < 1) {
        this.animationId = requestAnimationFrame(animate);
      } else {
        this.animationId = null;
      }
    };

    this.animationId = requestAnimationFrame(animate);
  },

  destroyed() {
    if (this.animationId) {
      cancelAnimationFrame(this.animationId);
    }
  },
};

// Endpoint Selector Hook for Chain Details
const EndpointSelector = {
  mounted() {
    this.selectedStrategy = "fastest"; // default strategy
    this.selectedProvider = null; // no provider selected by default
    this.mode = "strategy"; // 'strategy' or 'provider'

    // Read chain info from server-provided data attributes
    this.readChainFromDataset();

    // Set up click handlers
    this.el.addEventListener("click", (e) => {
      // Find the actual button element (might be a child element clicked)
      const button = e.target.closest("button");
      if (!button) return;

      if (button.dataset.strategy && !button.disabled) {
        this.selectStrategy(button.dataset.strategy);
      } else if (button.dataset.provider && !button.disabled) {
        this.selectProvider(button.dataset.provider);
      }
    });

    // Set up copy to clipboard handlers
    this.el.addEventListener("click", (e) => {
      if (e.target.dataset.copyText) {
        navigator.clipboard.writeText(e.target.dataset.copyText);
      }
    });

    this.updateUI();
  },

  updated() {
    // When LiveView updates the DOM, refresh chain context from data attributes
    this.readChainFromDataset();
    this.updateUI();
  },

  readChainFromDataset() {
    this.chain = this.el.getAttribute("data-chain") || this.chain || "ethereum";
    this.chainId = this.el.getAttribute("data-chain-id") || this.chainId || "1";
  },

  selectStrategy(strategy) {
    this.selectedStrategy = strategy;
    this.selectedProvider = null; // clear provider selection
    this.mode = "strategy";
    this.updateUI();
  },

  selectProvider(provider) {
    this.selectedProvider = provider;
    this.selectedStrategy = null; // clear strategy selection
    this.mode = "provider";
    
    // Get provider capabilities from the button data attributes
    const providerButton = this.el.querySelector(`[data-provider="${provider}"]`);
    this.selectedProviderSupportsWs = providerButton 
      ? providerButton.dataset.providerSupportsWs === 'true' 
      : false;
      
    this.updateUI();
  },

  updateUI() {
    // Update strategy pills with specific colors
    this.el.querySelectorAll("[data-strategy]").forEach((btn) => {
      const strategy = btn.dataset.strategy;
      const isActive =
        strategy === this.selectedStrategy && this.mode === "strategy";

      // Remove all possible color classes
      btn.className = btn.className.replace(
        /border-(sky|emerald|purple|orange)-[0-9]+|bg-(sky|emerald|purple|orange)-[0-9]+\/20|text-(sky|emerald|purple|orange)-[0-9]+|border-gray-[0-9]+|text-gray-[0-9]+|hover:border-(sky|emerald|purple|orange)-[0-9]+|hover:text-(sky|emerald|purple|orange)-[0-9]+/g,
        ""
      );

      if (isActive) {
        // Set active color based on strategy
        switch (strategy) {
          case "fastest":
            btn.className += " border-sky-500 bg-sky-500/20 text-sky-300";
            break;
          case "cheapest":
            btn.className +=
              " border-emerald-500 bg-emerald-500/20 text-emerald-300";
            break;
          case "priority":
            btn.className +=
              " border-purple-500 bg-purple-500/20 text-purple-300";
            break;
          case "round-robin":
            btn.className +=
              " border-orange-500 bg-orange-500/20 text-orange-300";
            break;
        }
      } else {
        // Inactive state with hover colors
        switch (strategy) {
          case "fastest":
            btn.className +=
              " border-gray-600 text-gray-300 hover:border-sky-400 hover:text-sky-300";
            break;
          case "cheapest":
            btn.className +=
              " border-gray-600 text-gray-300 hover:border-emerald-400 hover:text-emerald-300";
            break;
          case "priority":
            btn.className +=
              " border-gray-600 text-gray-300 hover:border-purple-400 hover:text-purple-300";
            break;
          case "round-robin":
            btn.className +=
              " border-gray-600 text-gray-300 hover:border-orange-400 hover:text-orange-300";
            break;
        }
      }
    });

    // Update provider buttons
    this.el.querySelectorAll("[data-provider]").forEach((btn) => {
      const isActive =
        btn.dataset.provider === this.selectedProvider &&
        this.mode === "provider";
      btn.className = btn.className.replace(
        /border-indigo-[0-9]+|bg-indigo-[0-9]+\/20|text-indigo-[0-9]+|border-gray-[0-9]+|text-gray-[0-9]+|hover:border-indigo-[0-9]+|hover:text-indigo-[0-9]+/g,
        ""
      );

      if (isActive) {
        btn.className += " border-indigo-500 bg-indigo-500/20 text-indigo-300";
      } else {
        btn.className +=
          " border-gray-600 text-gray-300 hover:border-indigo-400 hover:text-indigo-300";
      }
    });

    // Update URLs and description
    this.updateEndpointUrls();
    this.updateModeDescription();
  },

  updateEndpointUrls() {
    const httpUrl = this.el.querySelector("#endpoint-url");
    const wsUrl = this.el.querySelector("#ws-endpoint-url");
    const httpCopyBtns = this.el.querySelectorAll("[data-copy-text]");

    if (httpUrl && wsUrl) {
      const baseUrl = window.location.origin;
      const wsHost = window.location.host;
      const chain = this.chainId || this.chain || "1";

      let newHttpUrl, newWsUrl;

      if (this.mode === "strategy" && this.selectedStrategy) {
        newHttpUrl = `${baseUrl}/rpc/${this.selectedStrategy}/${chain}`;
        newWsUrl = `ws://${wsHost}/ws/rpc/${chain}`;
      } else if (this.mode === "provider" && this.selectedProvider) {
        // For provider overrides, use the provider ID directly
        newHttpUrl = `${baseUrl}/rpc/provider/${this.selectedProvider}/${chain}`;
        // Only show WebSocket URL if provider supports it
        if (this.selectedProviderSupportsWs) {
          newWsUrl = `ws://${wsHost}/ws/rpc/${chain}`;
        } else {
          newWsUrl = "WebSocket not supported by this provider";
        }
      } else {
        // Default fallback
        newHttpUrl = `${baseUrl}/rpc/fastest/${chain}`;
        newWsUrl = `ws://${wsHost}/ws/rpc/${chain}`;
      }

      httpUrl.textContent = newHttpUrl;
      wsUrl.textContent = newWsUrl;

      // Update copy button data attributes
      httpCopyBtns.forEach((btn) => {
        if (btn.dataset.copyText && btn.dataset.copyText.includes("http")) {
          btn.dataset.copyText = newHttpUrl;
        } else if (
          btn.dataset.copyText &&
          btn.dataset.copyText.includes("ws")
        ) {
          // Only allow copying if it's a valid WebSocket URL
          if (this.selectedProviderSupportsWs || this.mode === "strategy") {
            btn.dataset.copyText = newWsUrl;
            btn.disabled = false;
            btn.classList.remove("opacity-50", "cursor-not-allowed");
          } else {
            btn.disabled = true;
            btn.classList.add("opacity-50", "cursor-not-allowed");
          }
        }
      });
    }
  },

  updateModeDescription() {
    const descriptionEl = this.el.querySelector("#mode-description");
    if (!descriptionEl) return;

    if (this.mode === "strategy" && this.selectedStrategy) {
      const descriptions = {
        fastest: "Using fastest provider based on latency benchmarks",
        cheapest:
          "Using provider with lowest cost per request or free tier availability",
        priority: "Using providers in configured priority order with failover",
        "round-robin":
          "Distributing requests evenly across all available providers",
      };
      descriptionEl.textContent =
        descriptions[this.selectedStrategy] || "Strategy-based routing";
    } else if (this.mode === "provider" && this.selectedProvider) {
      descriptionEl.textContent = `Direct connection to ${this.selectedProvider} provider (bypasses routing)`;
    } else {
      descriptionEl.textContent =
        "Using fastest provider based on latency benchmarks";
    }
  },
};

// Provider Request Animator Hook (placeholder)
const ProviderRequestAnimator = {
  mounted() {
    // This hook can be used to animate provider requests in the future
    // For now it's just a placeholder to prevent the console error
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: {
    CollapsibleSection,
    SimulatorControl,
    DraggableNetworkViewport,
    EventsFeed,
    TerminalFeed,
    ProviderRequestAnimator,
    TabSwitcher: EndpointSelector,
  },
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
