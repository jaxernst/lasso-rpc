// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// Enhanced Simulator module
import * as LassoSim from "./lasso_simulator";

// Dynamic mesh visualization for hero graphic
import { HeroMesh } from "./hero_mesh";

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

// Activity Feed Hook with scroll-to-pause auto-scroll
// Handles prepended content (newest events at top of list in DOM)
// Uses simple scroll compensation to preserve position during updates
const ActivityFeed = {
  mounted() {
    this.autoScroll = true;
    this.userHasScrolled = false;

    // Listen for scroll events to detect manual scrolling
    this.el.addEventListener("scroll", () => {
      // Check if user is near the top (within 10px) - newest events are at top!
      const isNearTop = this.el.scrollTop < 10;

      if (!isNearTop) {
        // User scrolled down (to see older events), pause auto-scroll
        this.autoScroll = false;
        this.userHasScrolled = true;
      } else if (isNearTop && this.userHasScrolled) {
        // User scrolled back to top, resume auto-scroll
        this.autoScroll = true;
      }
    });

    // Initial scroll to top (newest events are at top of DOM)
    this.scrollToTop();
  },

  updated() {
    if (this.autoScroll) {
      // User is at top - scroll to show newest content
      this.scrollToTop();
    } else {
      // User is scrolled down reading older events
      // Maintain scroll position by tracking a specific element

      if (this.anchorElementId !== undefined) {
        // We saved an anchor element from the previous render
        // Find it in the current DOM
        const anchorElement = this.el.querySelector(
          `[data-event-id="${this.anchorElementId}"]`
        );

        if (anchorElement && this.anchorOffsetTop !== undefined) {
          // Calculate how much the anchor element has moved
          const currentOffsetTop = anchorElement.offsetTop;
          const movement = currentOffsetTop - this.anchorOffsetTop;

          if (movement !== 0) {
            // Adjust scroll to keep the anchor element at the same viewport position
            this.el.scrollTop = this.savedScrollTop + movement;
          }
        }
      }

      // Save the current anchor element for the NEXT update
      // Find the first visible element in the viewport
      const children = Array.from(this.el.children);
      const containerRect = this.el.getBoundingClientRect();
      const anchorElement = children.find((child) => {
        const rect = child.getBoundingClientRect();
        // Element is visible if its top is at or below the container's top
        return (
          rect.top >= containerRect.top - 5 && rect.top <= containerRect.bottom
        );
      });

      if (anchorElement) {
        this.anchorElementId = anchorElement.getAttribute("data-event-id");
        this.anchorOffsetTop = anchorElement.offsetTop;
        this.savedScrollTop = this.el.scrollTop;
      }
    }
  },

  scrollToTop() {
    try {
      // Scroll to top (newest events are at top of DOM)
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

  updated() {
    // Check if available chains changed (e.g., when profile switches)
    try {
      const chainsData = this.el.getAttribute("data-available-chains");
      const newAvailableChains = chainsData ? JSON.parse(chainsData) : [];

      // Compare with current chains (deep equality check)
      const chainsChanged =
        JSON.stringify(this.availableChains) !==
        JSON.stringify(newAvailableChains);

      if (chainsChanged) {
        console.log(
          "Available chains changed from",
          this.availableChains,
          "to",
          newAvailableChains
        );
        this.availableChains = newAvailableChains;
        LassoSim.setAvailableChains(this.availableChains);

        // Stop all running simulations since chains changed
        if (LassoSim.isRunning()) {
          console.log("Stopping all runs due to chain change");
          LassoSim.stopAllRuns();
        }
      }
    } catch (e) {
      console.error("Failed to update available chains:", e);
    }
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
    this.hasDragged = false; // Track if user actually dragged (moved mouse significantly)
    this.dragThreshold = 5; // Pixels of movement to consider it a drag
    this.startX = 0;
    this.startY = 0;
    this.startClientX = 0; // Track initial mouse position
    this.startClientY = 0;
    this.translateX = 0;
    this.translateY = 0;
    this.scale = 1;
    this.animationId = null;

    // Store bound handler functions for proper event listener cleanup
    this.boundHandleCanvasClick = this.handleCanvasClick.bind(this);

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

    // Intercept click events on the canvas to prevent deselect when dragging
    if (this.canvasEl) {
      this.canvasEl.addEventListener(
        "click",
        this.boundHandleCanvasClick,
        true
      );
    }

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

    const newCanvasEl =
      this.networkContainer &&
      this.networkContainer.querySelector("[data-network-canvas]");

    // If canvas element changed, reattach click handler
    if (newCanvasEl && newCanvasEl !== this.canvasEl) {
      // Remove old listener if it exists
      if (this.canvasEl) {
        this.canvasEl.removeEventListener(
          "click",
          this.boundHandleCanvasClick,
          true
        );
      }
      // Attach to new element
      this.canvasEl = newCanvasEl;
      this.canvasEl.addEventListener(
        "click",
        this.boundHandleCanvasClick,
        true
      );
    } else if (!this.canvasEl && newCanvasEl) {
      this.canvasEl = newCanvasEl;
      this.canvasEl.addEventListener(
        "click",
        this.boundHandleCanvasClick,
        true
      );
    }

    this.updateTransform();
  },

  handleMouseDown(e) {
    // Only handle left mouse button
    if (e.button !== 0) return;

    this.isDragging = true;
    this.hasDragged = false; // Reset drag flag
    this.startX = e.clientX - this.translateX;
    this.startY = e.clientY - this.translateY;
    this.startClientX = e.clientX; // Store initial mouse position
    this.startClientY = e.clientY;
    this.el.style.cursor = "grabbing";
    e.preventDefault();
  },

  handleMouseMove(e) {
    if (!this.isDragging) return;

    this.translateX = e.clientX - this.startX;
    this.translateY = e.clientY - this.startY;

    // Check if we've moved beyond the drag threshold
    const deltaX = Math.abs(e.clientX - this.startClientX);
    const deltaY = Math.abs(e.clientY - this.startClientY);
    if (deltaX > this.dragThreshold || deltaY > this.dragThreshold) {
      this.hasDragged = true;
    }

    this.updateTransform();
    e.preventDefault();
  },

  handleMouseUp() {
    this.isDragging = false;
    this.el.style.cursor = "grab";
    // Note: hasDragged flag is intentionally NOT reset here
    // It's checked in handleCanvasClick and reset there
  },

  handleCanvasClick(e) {
    // If we dragged, prevent the click event from reaching LiveView
    // This prevents "deselect_all" from firing when panning the canvas
    if (this.hasDragged) {
      e.stopPropagation();
      e.preventDefault();
    }
    // Reset the flag for the next interaction
    this.hasDragged = false;
  },

  handleTouchStart(e) {
    if (e.touches.length === 1) {
      this.isDragging = true;
      this.hasDragged = false; // Reset drag flag
      const touch = e.touches[0];
      this.startX = touch.clientX - this.translateX;
      this.startY = touch.clientY - this.translateY;
      this.startClientX = touch.clientX; // Store initial touch position
      this.startClientY = touch.clientY;
      e.preventDefault();
    }
  },

  handleTouchMove(e) {
    if (!this.isDragging || e.touches.length !== 1) return;

    const touch = e.touches[0];
    this.translateX = touch.clientX - this.startX;
    this.translateY = touch.clientY - this.startY;

    // Check if we've moved beyond the drag threshold
    const deltaX = Math.abs(touch.clientX - this.startClientX);
    const deltaY = Math.abs(touch.clientY - this.startClientY);
    if (deltaX > this.dragThreshold || deltaY > this.dragThreshold) {
      this.hasDragged = true;
    }

    this.updateTransform();
    e.preventDefault();
  },

  handleTouchEnd() {
    this.isDragging = false;
    // Note: hasDragged flag will be checked and reset in handleCanvasClick
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
    // Clean up click event listener
    if (this.canvasEl && this.boundHandleCanvasClick) {
      this.canvasEl.removeEventListener(
        "click",
        this.boundHandleCanvasClick,
        true
      );
    }
  },
};

// Endpoint Selector Hook for Chain Details
const EndpointSelector = {
  mounted() {
    this.selectedStrategy = "fastest"; // default strategy
    this.selectedProvider = null; // no provider selected by default
    this.mode = "strategy"; // 'strategy' or 'provider'
    this.selectedProviderSupportsWs = false; // default to false

    // Read chain info from server-provided data attributes
    this.readChainFromDataset();

    // Detect any pre-selected buttons from the server state
    this.detectActiveSelection();

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
      const btn = e.target.closest("[data-copy-text]");
      if (btn && btn.dataset.copyText) {
        navigator.clipboard.writeText(btn.dataset.copyText).then(() => {
          const originalHTML = btn.innerHTML;
          btn.innerHTML = `<span class="text-xs">Copied!</span>`;
          btn.classList.add("text-emerald-400");
          setTimeout(() => {
            btn.innerHTML = originalHTML;
            btn.classList.remove("text-emerald-400");
          }, 1500);
        });
      }
    });

    this.updateUI();
  },

  updated() {
    // When LiveView updates the DOM, refresh chain context from data attributes
    this.readChainFromDataset();

    // Detect which button is currently active (if any) to sync state after LiveView updates
    this.detectActiveSelection();

    this.updateUI();
  },

  readChainFromDataset() {
    // Use chain name (string like "ethereum", "base") not chain_id (numeric)
    this.chain = this.el.getAttribute("data-chain") || this.chain || "ethereum";
    this.chainId = this.el.getAttribute("data-chain-id") || this.chainId || "1";
  },

  detectActiveSelection() {
    // Try to detect which button is currently selected based on CSS classes
    // This helps sync state after LiveView updates

    // Check for active strategy button
    const activeStrategy = this.el.querySelector(
      "[data-strategy].border-sky-500"
    );
    if (activeStrategy && activeStrategy.dataset.strategy) {
      this.selectedStrategy = activeStrategy.dataset.strategy;
      this.selectedProvider = null;
      this.mode = "strategy";
      this.selectedProviderSupportsWs = false;
      return;
    }

    // Check for active provider button
    const activeProvider = this.el.querySelector(
      "[data-provider].border-indigo-500"
    );
    if (activeProvider && activeProvider.dataset.provider) {
      const providerId = activeProvider.dataset.provider;
      this.selectedProvider = providerId;
      this.selectedStrategy = null;
      this.mode = "provider";

      // Read WebSocket support from the button
      const supportsWsAttr =
        activeProvider.dataset.providerSupportsWs ||
        activeProvider.getAttribute("data-provider-supports-ws");
      this.selectedProviderSupportsWs =
        supportsWsAttr === "true" || supportsWsAttr === true;
      return;
    }
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
    const providerButton = this.el.querySelector(
      `[data-provider="${provider}"]`
    );

    if (providerButton) {
      // Read the WebSocket support attribute - handle both dataset and getAttribute for robustness
      const supportsWsAttr =
        providerButton.dataset.providerSupportsWs ||
        providerButton.getAttribute("data-provider-supports-ws");
      // Convert to boolean - handle "true", "false", empty string, undefined, and actual booleans
      this.selectedProviderSupportsWs =
        supportsWsAttr === "true" || supportsWsAttr === true;
    } else {
      this.selectedProviderSupportsWs = false;
    }

    this.updateUI();
  },

  updateUI() {
    // If we're in provider mode, make sure we have the latest WebSocket support info
    if (this.mode === "provider" && this.selectedProvider) {
      const providerButton = this.el.querySelector(
        `[data-provider="${this.selectedProvider}"]`
      );
      if (providerButton) {
        const supportsWsAttr =
          providerButton.dataset.providerSupportsWs ||
          providerButton.getAttribute("data-provider-supports-ws");
        this.selectedProviderSupportsWs =
          supportsWsAttr === "true" || supportsWsAttr === true;
      }
    }

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
        // Active: sky blue for all strategies
        btn.className += " border-sky-500 bg-sky-500/20 text-sky-300";
      } else {
        // Inactive: gray with sky hover
        btn.className +=
          " border-gray-600 text-gray-300 hover:border-sky-400 hover:text-sky-300";
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
    const wsRow = this.el.querySelector("#ws-row");
    const httpCopyBtns = this.el.querySelectorAll("[data-copy-text]");

    if (httpUrl) {
      const baseUrl = window.location.origin;
      const wsProtocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      const wsHost = window.location.host;
      const chain = this.chain; // Use chain name, not chain_id

      let newHttpUrl, newWsUrl;
      let showWsRow = true;

      if (this.mode === "strategy" && this.selectedStrategy) {
        // Strategy mode: /rpc/{strategy}/{chain}
        newHttpUrl = `${baseUrl}/rpc/${this.selectedStrategy}/${chain}`;
        newWsUrl = `${wsProtocol}//${wsHost}/ws/rpc/${this.selectedStrategy}/${chain}`;
        showWsRow = true;
      } else if (this.mode === "provider" && this.selectedProvider) {
        // Provider mode: /rpc/provider/{provider_id}/{chain}
        newHttpUrl = `${baseUrl}/rpc/provider/${this.selectedProvider}/${chain}`;

        if (this.selectedProviderSupportsWs) {
          newWsUrl = `${wsProtocol}//${wsHost}/ws/rpc/provider/${this.selectedProvider}/${chain}`;
          showWsRow = true;
        } else {
          newWsUrl = "";
          showWsRow = false;
        }
      } else {
        // Default fallback
        newHttpUrl = `${baseUrl}/rpc/fastest/${chain}`;
        newWsUrl = `${wsProtocol}//${wsHost}/ws/rpc/fastest/${chain}`;
        showWsRow = true;
      }

      httpUrl.textContent = newHttpUrl;
      if (wsUrl) {
        wsUrl.textContent = newWsUrl;
      }

      // Show/hide WebSocket row based on provider support
      if (wsRow) {
        if (showWsRow) {
          wsRow.style.display = "";
          wsRow.classList.remove("hidden");
        } else {
          wsRow.style.display = "none";
          wsRow.classList.add("hidden");
        }
      }

      // Update copy button data attributes
      httpCopyBtns.forEach((btn) => {
        if (btn.dataset.copyText && btn.dataset.copyText.includes("http")) {
          btn.dataset.copyText = newHttpUrl;
        } else if (
          btn.dataset.copyText &&
          (btn.dataset.copyText.includes("ws://") ||
            btn.dataset.copyText.includes("wss://") ||
            btn.dataset.copyText === "")
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
        fastest:
          "Routes to the fastest provider based on real-time latency benchmarks (good for low-volume high-priority RPC calls)",
        "round-robin":
          "Distributes requests evenly across all available providers (good for general purpose RPC calls)",
        "latency-weighted":
          "Load balanced selection favoring faster providers, maximizing throughput (good for indexing + backfilling tasks)",
      };
      descriptionEl.textContent =
        descriptions[this.selectedStrategy] || "Strategy-based routing";
    } else if (this.mode === "provider" && this.selectedProvider) {
      descriptionEl.textContent = `Direct connection to ${this.selectedProvider} (bypasses routing strategies)`;
    } else {
      descriptionEl.textContent =
        "Routes to the fastest provider based on real-time latency benchmarks";
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

// Scroll Reveal Hook
const ScrollReveal = {
  mounted() {
    this.revealed = false;

    // Check if we should reveal immediately (if already visible or near top)
    // But usually we trust the observer.

    this.observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            this.reveal();
            this.observer.unobserve(this.el);
          }
        });
      },
      {
        root: null,
        threshold: 0.1,
        rootMargin: "0px 0px -50px 0px",
      }
    );
    this.observer.observe(this.el);
  },

  updated() {
    // LiveView might have reset the classes to the server-side state (hidden).
    // If we have already revealed this element, we must force it back to visible.
    if (this.revealed) {
      this.el.classList.remove("opacity-0", "translate-y-8");
      this.el.classList.add("opacity-100", "translate-y-0");
    }
  },

  reveal() {
    this.revealed = true;
    this.el.classList.remove("opacity-0", "translate-y-8");
    this.el.classList.add("opacity-100", "translate-y-0");
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

// Expandable Details Hook - preserves open state across LiveView updates
const ExpandableDetails = {
  mounted() {
    // Validate element has an ID for unique storage key
    if (!this.el.id) {
      console.warn(
        "ExpandableDetails: element must have an id attribute for state persistence"
      );
      return;
    }

    // Store a reference to this hook's element ID for storage key
    this.storageKey = `details-open-${this.el.id}`;

    // Restore state from sessionStorage (survives LiveView updates)
    const wasOpen = sessionStorage.getItem(this.storageKey) === "true";
    if (wasOpen) {
      this.el.open = true;
    }

    // Store handler reference for cleanup in destroyed()
    this.handleToggle = () => {
      sessionStorage.setItem(this.storageKey, this.el.open ? "true" : "false");
    };
    this.el.addEventListener("toggle", this.handleToggle);
  },

  updated() {
    // Skip if hook wasn't properly initialized (missing ID)
    if (!this.storageKey) return;

    // After LiveView update, restore the open state from sessionStorage
    const wasOpen = sessionStorage.getItem(this.storageKey) === "true";
    if (wasOpen && !this.el.open) {
      this.el.open = true;
    }
  },

  destroyed() {
    // Remove event listener to prevent memory leak
    if (this.handleToggle) {
      this.el.removeEventListener("toggle", this.handleToggle);
    }
    // Clean up sessionStorage when element is removed
    if (this.storageKey) {
      sessionStorage.removeItem(this.storageKey);
    }
  },
};

// Heatmap Animation Hook - adds dynamic cell highlighting effects
const HeatmapAnimation = {
  mounted() {
    this.cells = [];
    this.highlightInterval = null;

    // Start random highlight effect when live
    this.startHighlightEffect();
  },

  updated() {
    // Refresh cell references and restart effect
    this.startHighlightEffect();
  },

  startHighlightEffect() {
    // Clear existing interval
    if (this.highlightInterval) {
      clearInterval(this.highlightInterval);
    }

    // Get all heatmap cells
    this.cells = Array.from(this.el.querySelectorAll(".heatmap-cell"));

    if (this.cells.length === 0) return;

    // Random highlight every 800-1500ms
    this.highlightInterval = setInterval(() => {
      this.highlightRandomCell();
    }, 800 + Math.random() * 700);
  },

  highlightRandomCell() {
    if (this.cells.length === 0) return;

    const cell = this.cells[Math.floor(Math.random() * this.cells.length)];

    // Add a quick flash effect
    cell.style.transition = "filter 0.15s ease-out, transform 0.15s ease-out";
    cell.style.filter = "brightness(1.4)";
    cell.style.transform = "scale(1.05)";

    // Reset after flash
    setTimeout(() => {
      cell.style.filter = "";
      cell.style.transform = "";
    }, 150);
  },

  destroyed() {
    if (this.highlightInterval) {
      clearInterval(this.highlightInterval);
    }
  },
};

// Parallax Background Hook
const ParallaxBackground = {
  mounted() {
    this.ticking = false;

    this.handleScroll = () => {
      if (!this.ticking) {
        window.requestAnimationFrame(() => {
          const scrolled = this.el.scrollTop;
          const blobs = this.el.querySelectorAll("[data-parallax-speed]");

          blobs.forEach((blob) => {
            const speed = parseFloat(blob.dataset.parallaxSpeed);
            // Move UP as we scroll down to create depth (background moves slower than foreground)
            // Since foreground moves at 1px/px, background should move at (1-speed)px/px or similar.
            // But these are fixed elements. They don't move at all by default.
            // To make them look like they are "far away", they should move slightly opposite to scroll direction
            // or slightly WITH scroll direction?
            // If they are "background", they should move upwards but slower than the content.
            // Content moves up at speed equal to scroll.
            // If we want them to appear "behind", they should move up slower.
            // Since they are FIXED, they effectively move with the camera (0 movement relative to viewport).
            // To make them look like background, we need to push them UP as we scroll down.
            const yPos = -(scrolled * speed);
            blob.style.transform = `translate3d(0, ${yPos}px, 0)`;
          });

          this.ticking = false;
        });

        this.ticking = true;
      }
    };

    this.el.addEventListener("scroll", this.handleScroll);
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.handleScroll);
  },
};

// Hero Parallax Hook - Dynamic mesh visualization with parallax and interactive effects
// Uses HeroMesh module for real-time connection line recalculation during parallax
const HeroParallax = {
  mounted() {
    this.scrollContainer = document.getElementById("main-scroll-container");

    if (!this.scrollContainer) {
      console.warn("HeroParallax: Could not find main-scroll-container");
      return;
    }

    // Find the SVG element
    this.svg = this.el.querySelector("#hero-mesh-svg");
    if (!this.svg) {
      console.warn("HeroParallax: Could not find hero-mesh-svg");
      return;
    }

    // Initialize the dynamic mesh system
    this.mesh = new HeroMesh(this.el, this.svg, this.scrollContainer);

    // Container-level parallax (vertical stickiness)
    this.containerConfig = {
      verticalMultiplier: 0.17,
    };

    this.lastScrolled = 0;
    this.rafId = null;

    this.handleScroll = () => {
      const scrolled = this.scrollContainer.scrollTop;

      if (this.rafId) {
        cancelAnimationFrame(this.rafId);
      }

      this.rafId = requestAnimationFrame(() => {
        this.lastScrolled = scrolled;
        // Container-level vertical parallax (makes the whole graphic "sticky")
        const containerY = scrolled * this.containerConfig.verticalMultiplier;
        this.el.style.transform = `translateY(${containerY}px)`;
        this.rafId = null;
      });
    };

    this.scrollContainer.addEventListener("scroll", this.handleScroll, {
      passive: true,
    });

    // Initial call
    this.handleScroll();
  },

  updated() {
    // Re-apply container transform after LiveView patches
    if (this.scrollContainer && this.el) {
      const containerY =
        this.lastScrolled * this.containerConfig.verticalMultiplier;
      this.el.style.transform = `translateY(${containerY}px)`;
    }
  },

  destroyed() {
    if (this.scrollContainer) {
      this.scrollContainer.removeEventListener("scroll", this.handleScroll);
    }
    if (this.rafId) {
      cancelAnimationFrame(this.rafId);
    }
    if (this.mesh) {
      this.mesh.destroy();
    }
  },
};

// Profile Persistence Hook - saves selected profile to sessionStorage
const ProfilePersistence = {
  mounted() {
    this.handleEvent("persist_profile", ({ profile }) => {
      sessionStorage.setItem("lasso_selected_profile", profile);
    });

    const stored = sessionStorage.getItem("lasso_selected_profile");
    if (stored) {
      this.pushEvent("restore_profile", { profile: stored });
    }
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
    ActivityFeed,
    ProviderRequestAnimator,
    TabSwitcher: EndpointSelector,
    ScrollReveal,
    ParallaxBackground,
    HeroParallax,
    ExpandableDetails,
    HeatmapAnimation,
    ProfilePersistence,
  },
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
