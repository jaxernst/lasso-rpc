// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// Dashboard request tester
import * as LassoSim from "./lasso_simulator";

const copyTextToClipboard = async (text) => {
  if (!text) return false;

  if (navigator.clipboard && navigator.clipboard.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (_error) {
      // Fall back to execCommand below.
    }
  }

  try {
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    textarea.style.pointerEvents = "none";

    document.body.appendChild(textarea);
    textarea.focus();
    textarea.select();

    const copied = document.execCommand("copy");
    document.body.removeChild(textarea);

    return copied;
  } catch (_error) {
    return false;
  }
};

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
          `[data-event-id="${this.anchorElementId}"]`,
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
    this.profile = this.el.getAttribute("data-profile");
    this.httpTimer = null;
    this.wsHandles = [];
    this.recentCalls = [];
    this.maxRecentCalls = 50;

    // Parse available chains from data attribute
    try {
      const chainsData = this.el.getAttribute("data-available-chains");
      this.availableChains = chainsData ? JSON.parse(chainsData) : [];

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

    this.handleEvent("start_simulator_run", (config) => {
      this.startSimulatorRun(config);
    });

    this.handleEvent("stop_all_runs", () => {
      LassoSim.stopAllRuns();
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
        LassoSim.isRunning(this.profile) // Only update when simulator is actually running
      ) {
        const stats = LassoSim.activeStats(this.profile);
        // Send updates directly to the SimulatorControls component
        this.pushEvent("sim_stats", stats);
        this.pushEvent("update_recent_calls", {
          calls: this.recentCalls.slice(-8),
        });
      }
    }, 500); // Reduce frequency from 200ms to 500ms
  },

  updated() {
    const nextProfile = this.el.getAttribute("data-profile");
    if (nextProfile !== this.profile) {
      this.profile = nextProfile;
      this.recentCalls = [];
      clearTimeout(this.immediateUpdate);
      LassoSim.stopAllRuns();
      this.pushEvent("sim_running", { running: false });
      this.pushEvent("sim_stats", LassoSim.activeStats(this.profile));
      this.pushEvent("update_recent_calls", { calls: [] });
    }

    // Check if available chains changed (e.g., when profile switches)
    try {
      const chainsData = this.el.getAttribute("data-available-chains");
      const newAvailableChains = chainsData ? JSON.parse(chainsData) : [];

      // Compare with current chains (deep equality check)
      const chainsChanged =
        JSON.stringify(this.availableChains) !==
        JSON.stringify(newAvailableChains);

      if (chainsChanged) {
        this.availableChains = newAvailableChains;
        LassoSim.setAvailableChains(this.availableChains);

        // Stop all running simulations since chains changed
        if (LassoSim.isRunning(this.profile)) {
          LassoSim.stopAllRuns();
        }
      }
    } catch (e) {
      console.error("Failed to update available chains:", e);
    }
  },

  startSimulatorRun(config) {
    try {
      this.recentCalls = [];

      // Use the new run-based API
      LassoSim.startRun(config);

      this.pushEvent("sim_running", { running: true });
    } catch (error) {
      console.error("Failed to start simulator run:", error);
    }
  },

  trackActivity(activity) {
    if (activity.profile !== this.profile) return;
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
        // Update run state and stats immediately
        const stats = activity.stats || LassoSim.activeStats(this.profile);

        this.pushEvent("sim_running", { running: LassoSim.isRunning(this.profile) });
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
        LassoSim.isRunning(this.profile)
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
    LassoSim.stopAllRuns();
  },
};

// Draggable Network Viewport Hook
const DraggableNetworkViewport = {
  mounted() {
    this.isDragging = false;
    this.isPinching = false;
    this.hasDragged = false; // Track if user actually dragged (moved mouse significantly)
    this.dragThreshold = 5; // Pixels of movement to consider it a drag
    this.touchDragThreshold = 10; // Fingers wobble; a tap needs more slack
    this.pinchStartDistance = 0;
    this.pinchStartScale = 1;
    this.startX = 0;
    this.startY = 0;
    this.startClientX = 0; // Track initial mouse position
    this.startClientY = 0;
    this.translateX = 0;
    this.translateY = 0;
    this.scale = 1;
    // Zoom limits belong with the rest of the transform state: centerCanvas()
    // runs further down and clamps against minScale.
    this.minScale = 0.3;
    this.maxScale = 3.0;
    this.zoomSensitivity = 0.002; // scroll-to-zoom, towards the cursor
    this.animationId = null;
    this.canvasCenterX = null;
    this.canvasCenterY = null;

    // LiveView owns the canvas DOM and removes JS-authored inline styles while
    // applying the connected-mount patch. Keep the camera transform on the
    // document element so it survives connected-mount patches.
    this.frameTransformProperty = "--lasso-topology-transform";
    const restoredFrame = document.documentElement.style
      .getPropertyValue(this.frameTransformProperty)
      .trim();
    const restoredParts = restoredFrame.match(
      /^translate\(([-\d.]+)px,\s*([-\d.]+)px\) scale\(([\d.]+)\)$/,
    );
    if (restoredParts) {
      const [, x, y, scale] = restoredParts.map(Number);
      if (
        Number.isFinite(x) &&
        Number.isFinite(y) &&
        Number.isFinite(scale) &&
        scale > 0
      ) {
        this.translateX = x;
        this.translateY = y;
        this.scale = scale;
      }
    }

    // Store bound handler functions for proper event listener cleanup
    this.boundHandleCanvasClick = this.handleCanvasClick.bind(this);

    // Find the network container (the draggable content)
    this.networkContainer = this.el.querySelector("[data-draggable-content]");
    if (!this.networkContainer) {
      console.warn(
        "DraggableNetworkViewport: No element with data-draggable-content found",
      );
      return;
    }

    // Find the actual canvas element (4000x3000) to transform; fallback to wrapper
    this.canvasEl =
      this.networkContainer.querySelector("[data-network-canvas]") ||
      this.networkContainer;

    // Optional: preferred canvas center (in canvas coordinates) for consistent framing
    // Example: "1800,1500" (from TopologyConfig.canvas_center/0)
    const configuredCenter = this.el?.dataset?.canvasCenter;
    if (configuredCenter) {
      const [cx, cy] = configuredCenter.split(",").map(Number);
      if (Number.isFinite(cx) && Number.isFinite(cy)) {
        this.canvasCenterX = cx;
        this.canvasCenterY = cy;
      }
    }

    // Compute initial transform to center the topology in the viewport.
    // If the viewport is 0-sized at mount time (CSS layout race when the
    // dashboard panels are still settling) the centering math pushes the
    // canvas off-screen and the user sees a blank canvas until they
    // interact. Retry on the next animation frame in that case.
    // A canvas restored from browser history can reuse the last document-level
    // transform. Keep that frame visible while layout settles; a fresh document
    // stays hidden until centerCanvas() can measure it.
    const hasRestoredFrame =
      document.documentElement.classList.contains("topology-framed") &&
      Boolean(restoredFrame);

    if (!hasRestoredFrame) {
      document.documentElement.classList.remove("topology-framed");
    }

    if (!this.centerCanvas()) {
      requestAnimationFrame(() => {
        if (!this.centerCanvas())
          requestAnimationFrame(() => this.centerCanvas());
      });
    }

    // Those retries are bounded, so a viewport that is still collapsed on the
    // third frame (panels settling, a hidden tab, a slow font load) would leave
    // the canvas hidden for good. Watch for the element gaining a real size and
    // frame then; the observer stops itself once framing succeeds.
    if (typeof ResizeObserver !== "undefined") {
      this.sizeObserver = new ResizeObserver(() => {
        const { width, height } = this.el.getBoundingClientRect();
        if (width > 0 && height > 0 && this.centerCanvas()) {
          this.sizeObserver.disconnect();
          this.sizeObserver = null;
        }
      });
      this.sizeObserver.observe(this.el);
    }

    // Track whether the last render had topology nodes so updated() can
    // re-center when a late-arriving server diff hydrates them.
    this.hadNodes = this.countTopologyNodes() > 0;

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
        true,
      );
    }

    // Touch events for mobile. The viewport carries `touch-none` in its
    // server-rendered class so the browser's pan and pinch gestures belong to
    // this hook and a two-finger pinch zooms the canvas rather than the page.
    // It has to be a class: LiveView patching strips inline styles set here.
    this.el.addEventListener("touchstart", this.handleTouchStart.bind(this), {
      passive: false,
    });
    this.el.addEventListener("touchmove", this.handleTouchMove.bind(this), {
      passive: false,
    });
    this.el.addEventListener("touchend", this.handleTouchEnd.bind(this));
    this.el.addEventListener("touchcancel", this.handleTouchEnd.bind(this));

    // Safari on iOS still raises its own pinch gestures over an element that
    // opted out via touch-action, which would zoom the document.
    ["gesturestart", "gesturechange", "gestureend"].forEach((name) => {
      this.el.addEventListener(name, (e) => e.preventDefault(), {
        passive: false,
      });
    });

    // Provider name labels: shown when zoomed past `labelShowThreshold`,
    // hidden again once below `labelHideThreshold`. The hysteresis band
    // avoids flicker on micro-zoom around the boundary. The class is
    // toggled on the canvas root so CSS handles per-node visibility.
    this.labelShowThreshold = 1.45;
    this.labelHideThreshold = 1.2;
    this.labelsVisible = false;
    this.el.addEventListener("wheel", this.handleWheel.bind(this), {
      passive: false,
    });

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
      if (this.canvasEl) {
        this.canvasEl.removeEventListener(
          "click",
          this.boundHandleCanvasClick,
          true,
        );
      }
      this.canvasEl = newCanvasEl;
      this.canvasEl.addEventListener(
        "click",
        this.boundHandleCanvasClick,
        true,
      );
    } else if (!this.canvasEl && newCanvasEl) {
      this.canvasEl = newCanvasEl;
      this.canvasEl.addEventListener(
        "click",
        this.boundHandleCanvasClick,
        true,
      );
    }

    this.updateTransform();

    // Re-center when topology data arrives in a later server diff (e.g. a
    // profile data arriving after mount). Without this
    // the empty-at-mount viewport keeps its stale transform and the
    // now-present nodes render off-frame. Fire only on the no-nodes →
    // has-nodes transition — that is the initial hydration, before the
    // user has panned or zoomed. centerCanvas() resets both translate and
    // zoom, so firing it on a later update would override a manual view.
    const hasNodes = this.countTopologyNodes() > 0;
    if (hasNodes && !this.hadNodes) {
      this.centerCanvas();
    }
    this.hadNodes = hasNodes;
  },

  // Marks the topology as framed. Lives on the document element, outside the
  // LiveView container, so no patch can revert it and blank the canvas.
  revealCanvas() {
    document.documentElement.classList.add("topology-framed");
  },

  // Count chain bubbles inside the draggable topology container. The
  // `[data-chain]` selector is also used by the edit/detail panels, so the
  // `networkContainer` scope is load-bearing — it limits the count to the
  // topology canvas. Bubbles present = topology data has hydrated.
  countTopologyNodes() {
    if (!this.networkContainer) return 0;
    return this.networkContainer.querySelectorAll("[data-chain]").length;
  },

  // Compute the transform that frames the topology in the viewport.
  // Returns false when the viewport is still 0-sized (CSS layout race) so
  // callers can retry on a later frame.
  centerCanvas() {
    const viewportRect = this.el.getBoundingClientRect();

    if (viewportRect.width <= 0 || viewportRect.height <= 0) {
      return false;
    }

    const { canvasWidth, canvasHeight } = this.getCanvasDimensions();
    const centerX = this.canvasCenterX ?? canvasWidth / 2;
    const centerY = this.canvasCenterY ?? canvasHeight / 2;

    const box = this.visibleViewportBox(viewportRect);

    this.scale = this.initialScale(box);
    this.translateX = (box.left + box.right) / 2 - centerX * this.scale;
    this.translateY = (box.top + box.bottom) / 2 - centerY * this.scale;
    this.updateTransform();
    this.revealCanvas();

    return true;
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
    if (this.hasDragged) {
      e.stopPropagation();
      e.preventDefault();
    }
    this.hasDragged = false;
  },

  handleWheel(e) {
    e.preventDefault();

    const delta = -e.deltaY * this.zoomSensitivity;
    const newScale = Math.min(
      this.maxScale,
      Math.max(this.minScale, this.scale * (1 + delta)),
    );

    const rect = this.el.getBoundingClientRect();
    this.zoomAtPoint(newScale, e.clientX - rect.left, e.clientY - rect.top);
  },

  handleTouchStart(e) {
    if (e.touches.length === 2) {
      this.beginPinch(e.touches[0], e.touches[1]);
      e.preventDefault();
      return;
    }

    if (e.touches.length === 1) {
      this.isDragging = true;
      this.isPinching = false;
      this.hasDragged = false; // Reset drag flag
      const touch = e.touches[0];
      this.startX = touch.clientX - this.translateX;
      this.startY = touch.clientY - this.translateY;
      this.startClientX = touch.clientX; // Store initial touch position
      this.startClientY = touch.clientY;
      // Deliberately no preventDefault: suppressing the default on touchstart
      // also suppresses the synthesized click, and that click is how a tap
      // reaches `phx-click` to select a node or deselect the canvas. Panning
      // is kept off the page by `touch-action: none` plus the touchmove
      // preventDefault below.
    }
  },

  handleTouchMove(e) {
    if (this.isPinching && e.touches.length === 2) {
      this.updatePinch(e.touches[0], e.touches[1]);
      e.preventDefault();
      return;
    }

    if (!this.isDragging || e.touches.length !== 1) return;

    const touch = e.touches[0];
    this.translateX = touch.clientX - this.startX;
    this.translateY = touch.clientY - this.startY;

    // Check if we've moved beyond the drag threshold. Fingers wobble more
    // than a mouse, so a tap needs more slack before it counts as a drag.
    const deltaX = Math.abs(touch.clientX - this.startClientX);
    const deltaY = Math.abs(touch.clientY - this.startClientY);
    if (deltaX > this.touchDragThreshold || deltaY > this.touchDragThreshold) {
      this.hasDragged = true;
    }

    this.updateTransform();
    e.preventDefault();
  },

  handleTouchEnd(e) {
    const remaining = e && e.touches ? e.touches.length : 0;

    if (remaining === 0) {
      this.isDragging = false;
      this.isPinching = false;
      return;
    }

    // Lifting one finger out of a pinch hands the gesture back to panning,
    // re-anchored on the finger still down so the canvas does not jump.
    if (remaining === 1 && this.isPinching) {
      this.isPinching = false;
      const touch = e.touches[0];
      this.isDragging = true;
      this.startX = touch.clientX - this.translateX;
      this.startY = touch.clientY - this.translateY;
      this.startClientX = touch.clientX;
      this.startClientY = touch.clientY;
    }
    // Note: hasDragged flag will be checked and reset in handleCanvasClick
  },

  beginPinch(a, b) {
    this.isDragging = false;
    this.isPinching = true;
    // A pinch is never a tap; keep the trailing click from deselecting.
    this.hasDragged = true;
    this.pinchStartDistance = this.touchDistance(a, b);
    this.pinchStartScale = this.scale;
  },

  updatePinch(a, b) {
    if (!this.pinchStartDistance) return;

    const ratio = this.touchDistance(a, b) / this.pinchStartDistance;
    const newScale = Math.min(
      this.maxScale,
      Math.max(this.minScale, this.pinchStartScale * ratio),
    );

    const rect = this.el.getBoundingClientRect();
    this.zoomAtPoint(
      newScale,
      (a.clientX + b.clientX) / 2 - rect.left,
      (a.clientY + b.clientY) / 2 - rect.top,
    );
  },

  touchDistance(a, b) {
    return Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY);
  },

  // Scale about a viewport-relative point, keeping the canvas coordinate
  // under that point fixed. Shared by wheel zoom and pinch zoom.
  zoomAtPoint(newScale, x, y) {
    if (newScale === this.scale) return;

    const canvasX = (x - this.translateX) / this.scale;
    const canvasY = (y - this.translateY) / this.scale;

    this.scale = newScale;
    this.translateX = x - canvasX * this.scale;
    this.translateY = y - canvasY * this.scale;

    this.updateTransform();
  },

  updateTransform() {
    const transform = `translate(${this.translateX}px, ${this.translateY}px) scale(${this.scale})`;
    document.documentElement.style.setProperty(
      this.frameTransformProperty,
      transform,
    );

    // Remove transforms written by an older asset version after the equivalent
    // document-level value exists. The CSS variable then remains authoritative
    // when LiveView replaces or patches the canvas element.
    this.canvasEl?.style.removeProperty("transform");
    this.canvasEl?.style.removeProperty("transform-origin");
    this.updateLabelVisibility();
  },

  updateLabelVisibility() {
    if (!this.canvasEl) return;
    const next =
      this.scale >= this.labelShowThreshold
        ? true
        : this.scale < this.labelHideThreshold
          ? false
          : this.labelsVisible;
    this.labelsVisible = next;
    // Always sync the class — the canvas element can be replaced by
    // LiveView patches, in which case the new node won't carry it.
    if (this.canvasEl.classList.contains("labels-visible") !== next) {
      this.canvasEl.classList.toggle("labels-visible", next);
    }
  },

  // A phone viewport is narrower than the topology's natural spread, so 1:1
  // drops the user inside a single chain with no sense of the whole graph.
  // Fit the node bounds to the space the sheet leaves instead. Desktop is
  // already well framed at 1:1 and is left alone.
  initialScale(box) {
    const width = box.right - box.left;
    if (width >= 768) return 1;

    const bounds = this.topologyBounds();
    if (!bounds) return 0.7;

    const padding = 60;
    const fit = Math.min(
      width / (bounds.width + padding * 2),
      (box.bottom - box.top) / (bounds.height + padding * 2),
    );

    return Math.max(this.minScale, Math.min(1, fit * 1.2));
  },

  // Bounding box of every placed node, in canvas coordinates.
  topologyBounds() {
    const nodes = this.networkContainer?.querySelectorAll(
      "[data-chain-center], [data-provider-center]",
    );
    if (!nodes || !nodes.length) return null;

    const xs = [];
    const ys = [];
    nodes.forEach((el) => {
      const raw =
        el.getAttribute("data-chain-center") ||
        el.getAttribute("data-provider-center");
      const [x, y] = (raw || "").split(",").map(Number);
      if (Number.isFinite(x) && Number.isFinite(y)) {
        xs.push(x);
        ys.push(y);
      }
    });
    if (!xs.length) return null;

    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);
    return { width: maxX - minX, height: maxY - minY };
  },

  // Canvas dimensions used for viewport anchoring math.
  // Prefer measured DOM dimensions; fall back to configured topology canvas size.
  getCanvasDimensions() {
    const canvasWidth =
      this.canvasEl?.scrollWidth || this.canvasEl?.offsetWidth || 4000;
    const canvasHeight =
      this.canvasEl?.scrollHeight || this.canvasEl?.offsetHeight || 3000;
    return { canvasWidth, canvasHeight };
  },

  // The details window sits over the canvas, so the geometric centre of the
  // viewport is not the centre of what the user can actually see. Measure the
  // panel and pull the framing area back from whichever edge it occupies:
  // the right on desktop, the bottom for the mobile sheet. Everything that
  // frames a target routes through here, so centring a node lands it in open
  // space instead of behind the panel.
  visibleViewportBox(viewportRect) {
    const box = {
      left: 0,
      top: 0,
      right: viewportRect.width,
      bottom: viewportRect.height,
    };

    const panel = document.querySelector(
      '[data-floating-window="details-window"] > div',
    );
    if (!panel) return box;

    const p = panel.getBoundingClientRect();
    if (p.width < 1 || p.height < 1) return box;

    const left = p.left - viewportRect.left;
    const right = p.right - viewportRect.left;
    const top = p.top - viewportRect.top;
    const bottom = p.bottom - viewportRect.top;

    // Shrink along the axis the panel spans, away from the edge it sits
    // nearest. Comparing gaps rather than testing for a flush edge keeps this
    // correct for the desktop window, which is inset from the corner it hugs.
    if (p.width >= viewportRect.width * 0.9) {
      if (viewportRect.height - bottom <= top) {
        box.bottom = Math.max(box.top + 1, top);
      } else {
        box.top = Math.min(box.bottom - 1, bottom);
      }
    } else if (viewportRect.width - right <= left) {
      box.right = Math.max(box.left + 1, left);
    } else {
      box.left = Math.min(box.right - 1, right);
    }

    return box;
  },

  // Preferred "camera center" inside the viewport when centering on a target point.
  // If TopologyConfig.canvas_center is left-of-canvas-center, this keeps the view
  // framed slightly left even when focusing a chain/provider.
  getViewportAnchor(viewportRect, scale) {
    const { canvasWidth, canvasHeight } = this.getCanvasDimensions();
    const box = this.visibleViewportBox(viewportRect);
    const viewportCenterX = (box.left + box.right) / 2;
    const viewportCenterY = (box.top + box.bottom) / 2;

    const canvasCenterX =
      this.canvasCenterX == null ? canvasWidth / 2 : this.canvasCenterX;
    const canvasCenterY =
      this.canvasCenterY == null ? canvasHeight / 2 : this.canvasCenterY;

    const offsetX = canvasWidth / 2 - canvasCenterX;
    const offsetY = canvasHeight / 2 - canvasCenterY;

    return {
      x: viewportCenterX - offsetX * scale,
      y: viewportCenterY - offsetY * scale,
    };
  },

  // Center the viewport on the first chain on initial load
  centerOnFirstChain() {
    setTimeout(() => {
      const firstChain = this.networkContainer?.querySelector(
        "[data-chain-center]",
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

  // How far to zoom when framing a selected node. Mobile opens fitted to the
  // whole topology, so stepping straight to the desktop zoom is a three-fold
  // jump that throws away every surrounding node. Scale relative to that
  // fitted baseline instead, so selection tightens the view without
  // stranding the user inside a single cluster.
  focusScale(desktopZoom, mobileFactor) {
    const box = this.visibleViewportBox(this.el.getBoundingClientRect());
    if (box.right - box.left >= 768) return desktopZoom;

    return Math.min(desktopZoom, this.initialScale(box) * mobileFactor);
  },

  // Center viewport on a specific chain
  centerOnChain(chainName, opts = {}) {
    const chainElement = this.networkContainer?.querySelector(
      `[data-chain="${chainName}"]`,
    );
    if (chainElement) {
      const center = chainElement.getAttribute("data-chain-center");
      if (center) {
        const [x, y] = center.split(",").map(Number);
        this.animateTo(x, y, 800, this.focusScale(opts.zoom || 1.25, 2));
      }
    }
  },

  // Center viewport on a specific provider
  centerOnProvider(providerId, opts = {}) {
    const providerElement = this.networkContainer?.querySelector(
      `[data-provider="${providerId}"]`,
    );
    if (providerElement) {
      const center = providerElement.getAttribute("data-provider-center");
      if (center) {
        const [x, y] = center.split(",").map(Number);
        this.animateTo(x, y, 800, this.focusScale(opts.zoom || 1.4, 2.6));
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
    const anchorStart = this.getViewportAnchor(viewportRect, startScale);

    const currentCanvasAnchorX = (anchorStart.x - startX) / startScale;
    const currentCanvasAnchorY = (anchorStart.y - startY) / startScale;

    const startTime = performance.now();

    const animate = (t) => {
      const progress = Math.min((t - startTime) / duration, 1);
      const ease = 1 - Math.pow(1 - progress, 3);
      this.scale = startScale + (targetScale - startScale) * ease;

      // Keep the same canvas point under the preferred viewport anchor
      const anchor = this.getViewportAnchor(viewportRect, this.scale);
      this.translateX = anchor.x - currentCanvasAnchorX * this.scale;
      this.translateY = anchor.y - currentCanvasAnchorY * this.scale;

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

    const startTranslateX = this.translateX;
    const startTranslateY = this.translateY;
    const startScale = this.scale;

    // If targetScale provided, animate scale too, keeping target point centered
    const finalScale = targetScale == null ? this.scale : targetScale;

    const startTime = performance.now();

    const animate = (currentTime) => {
      const elapsed = currentTime - startTime;
      const progress = Math.min(elapsed / duration, 1);
      const easeProgress = 1 - Math.pow(1 - progress, 3);

      // Re-anchor every frame. Selecting a node resizes the details panel in
      // the same LiveView patch that starts this animation, so an anchor taken
      // up front would aim at the old panel geometry and leave the node partly
      // behind the new one. Recomputing converges on the final framing.
      const anchorFinal = this.getViewportAnchor(
        this.el.getBoundingClientRect(),
        finalScale,
      );
      const targetTranslateX_final = anchorFinal.x - targetX * finalScale;
      const targetTranslateY_final = anchorFinal.y - targetY * finalScale;

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
        true,
      );
    }
    this.sizeObserver?.disconnect();
    this.sizeObserver = null;
  },
};

// Endpoint Selector Hook for Chain Details
const EndpointSelector = {
  mounted() {
    this.selectedStrategy = "load-balanced"; // default strategy
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
    this.profile =
      this.el.getAttribute("data-profile") || this.profile || "default";
  },

  detectActiveSelection() {
    // Detect active selection via data-state attributes
    const activeStrategy = this.el.querySelector(
      '[data-strategy][data-state="active"]',
    );
    if (activeStrategy && activeStrategy.dataset.strategy) {
      this.selectedStrategy = activeStrategy.dataset.strategy;
      this.selectedProvider = null;
      this.mode = "strategy";
      this.selectedProviderSupportsWs = false;
      return;
    }

    const activeProvider = this.el.querySelector(
      '[data-provider][data-state="active"]',
    );
    if (activeProvider && activeProvider.dataset.provider) {
      this.selectedProvider = activeProvider.dataset.provider;
      this.selectedStrategy = null;
      this.mode = "provider";

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
      `[data-provider="${provider}"]`,
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
        `[data-provider="${this.selectedProvider}"]`,
      );
      if (providerButton) {
        const supportsWsAttr =
          providerButton.dataset.providerSupportsWs ||
          providerButton.getAttribute("data-provider-supports-ws");
        this.selectedProviderSupportsWs =
          supportsWsAttr === "true" || supportsWsAttr === true;
      }
    }

    // Update strategy button states via data attributes (CSS handles styling)
    this.el.querySelectorAll("[data-strategy]").forEach((btn) => {
      const strategy = btn.dataset.strategy;
      const isActive =
        strategy === this.selectedStrategy && this.mode === "strategy";
      btn.dataset.state = isActive ? "active" : "inactive";
    });

    // Update provider button states via data attributes
    this.el.querySelectorAll("[data-provider]").forEach((btn) => {
      const isActive =
        btn.dataset.provider === this.selectedProvider &&
        this.mode === "provider";
      btn.dataset.state = isActive ? "active" : "inactive";
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

      const profile = this.profile;

      if (this.mode === "strategy" && this.selectedStrategy) {
        newHttpUrl = `${baseUrl}/rpc/profile/${profile}/${this.selectedStrategy}/${chain}`;
        newWsUrl = `${wsProtocol}//${wsHost}/ws/rpc/profile/${profile}/${this.selectedStrategy}/${chain}`;
        showWsRow = true;
      } else if (this.mode === "provider" && this.selectedProvider) {
        newHttpUrl = `${baseUrl}/rpc/profile/${profile}/provider/${this.selectedProvider}/${chain}`;

        if (this.selectedProviderSupportsWs) {
          newWsUrl = `${wsProtocol}//${wsHost}/ws/rpc/profile/${profile}/provider/${this.selectedProvider}/${chain}`;
          showWsRow = true;
        } else {
          newWsUrl = "";
          showWsRow = false;
        }
      } else {
        newHttpUrl = `${baseUrl}/rpc/profile/${profile}/${chain}`;
        newWsUrl = `${wsProtocol}//${wsHost}/ws/rpc/profile/${profile}/${chain}`;
        showWsRow = true;
      }

      httpUrl.textContent = newHttpUrl;
      httpUrl.classList.remove("text-gray-500", "text-amber-400", "italic");
      httpUrl.classList.add("text-gray-300");
      if (wsUrl) {
        wsUrl.textContent = newWsUrl;
        wsUrl.classList.remove("text-gray-500", "text-amber-400", "italic");
        wsUrl.classList.add("text-gray-300");
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
        if (btn.dataset.copyText !== undefined) {
          if (btn.closest("#http-row")) {
            btn.dataset.copyText = newHttpUrl;
            btn.disabled = false;
            btn.classList.remove("opacity-50", "cursor-not-allowed");
          } else if (btn.closest("#ws-row")) {
            if (this.selectedProviderSupportsWs || this.mode === "strategy") {
              btn.dataset.copyText = newWsUrl;
              btn.disabled = false;
              btn.classList.remove("opacity-50", "cursor-not-allowed");
            } else {
              btn.disabled = true;
              btn.classList.add("opacity-50", "cursor-not-allowed");
            }
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
        "load-balanced":
          "Distributes requests evenly across all available providers — good for general purpose workloads",
        "latency-weighted":
          "Load balanced favoring faster providers — good for high-throughput workloads like indexing and backfilling",
        fastest:
          "Routes all requests to the single fastest provider — best suited for low-volume, latency-sensitive calls",
      };
      descriptionEl.textContent =
        descriptions[this.selectedStrategy] || "Strategy-based routing";
      descriptionEl.classList.remove("text-amber-400");
      descriptionEl.classList.add("text-gray-500");
    } else if (this.mode === "provider" && this.selectedProvider) {
      descriptionEl.textContent = `Direct connection to ${this.selectedProvider} (bypasses routing strategies)`;
      descriptionEl.classList.remove("text-amber-400");
      descriptionEl.classList.add("text-gray-500");
    } else {
      descriptionEl.textContent =
        "Distributes requests evenly across all available providers";
      descriptionEl.classList.remove("text-amber-400");
      descriptionEl.classList.add("text-gray-500");
    }
  },
};

// Scroll Reveal Hook

// Expandable Details Hook - preserves open state across LiveView updates
const ExpandableDetails = {
  mounted() {
    // Validate element has an ID for unique storage key
    if (!this.el.id) {
      console.warn(
        "ExpandableDetails: element must have an id attribute for state persistence",
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

// Parallax Background Hook

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

// Copy to clipboard hook with visual feedback
const CopyButton = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-copy-text]");
      if (btn && btn.dataset.copyText) {
        const originalHTML = btn.innerHTML;
        const originalClasses = btn.className;
        const successText = btn.dataset.copySuccess || "Copied!";

        btn.innerHTML = `<span class="text-white">${successText}</span>`;

        copyTextToClipboard(btn.dataset.copyText).catch(() => {});

        setTimeout(() => {
          btn.innerHTML = originalHTML;
          btn.className = originalClasses;
        }, 1500);
      }
    });
  },
};

// Network Topology Status Hook - applies provider status colors via push_event
// to avoid 28KB+ LiveView diffs from comprehension re-renders
const STATUS_COLORS = {
  healthy: "#34d399",
  lagging: "#38bdf8",
  recovering: "#f59e0b",
  testing_recovery: "#f59e0b",
  degraded: "#f97316",
  rate_limited: "#a78bfa",
  circuit_open: "#dc2626",
  unknown: "#9ca3af",
  failed: "#ef4444",
  probing: "#38bdf8",
};

const STATUS_COPY = {
  healthy: ["Healthy", "available evidence shows no current impairment in the selected scope"],
  lagging: ["Lagging", "fresh head evidence is behind the profile comparison reference"],
  recovering: ["Recovering", "a route is reconnecting or testing recovery"],
  testing_recovery: [
    "Recovering",
    "a circuit is testing whether the upstream has recovered",
  ],
  degraded: [
    "Degraded",
    "one or more regions or transports are impaired; other routes may remain available",
  ],
  rate_limited: ["Rate limited", "all supported routes in the selected scope are in quota cooldown"],
  circuit_open: ["Circuit open", "all supported routes in the selected scope have open circuits"],
  unknown: ["Awaiting evidence", "evidence is missing or stale; routing may still try this provider"],
  failed: ["Failed", "the provider is unavailable"],
  probing: ["Probing", "provider validation is in progress"],
};

const NetworkTopologyStatus = {
  mounted() {
    this.currentStatuses = {};
    this.currentStatusDetails = {};
    this.currentBlocks = {};
    this.blockPulses = new Map();
    this.pendingApply = false;

    this.statusStyleEl = document.createElement("style");
    this.statusStyleEl.dataset.topologyStatus = "";
    document.head.appendChild(this.statusStyleEl);

    this.hoverStyleEl = document.createElement("style");
    this.hoverStyleEl.dataset.topologyHover = "";
    document.head.appendChild(this.hoverStyleEl);

    this.handleEvent("chain-blocks", ({ blocks }) => {
      const advanced = {};
      for (const [chainId, height] of Object.entries(blocks)) {
        // A null height is a retraction: the chain's providers went stale, so
        // the readout is cleared rather than left showing a dead number.
        if (height === null) {
          delete this.currentBlocks[chainId];
        } else {
          if (this.currentBlocks[chainId] !== height) advanced[chainId] = true;
          this.currentBlocks[chainId] = height;
        }
      }
      this.applyChainBlocks(blocks, advanced);
    });
    this.handleEvent("provider-statuses", ({ statuses, snapshot, details = {} }) => {
      if (snapshot) {
        this.currentStatuses = statuses;
        this.currentStatusDetails = details;
      } else {
        for (const [id, status] of Object.entries(statuses)) {
          if (status === null) {
            delete this.currentStatuses[id];
            delete this.currentStatusDetails[id];
          } else {
            this.currentStatuses[id] = status;
            if (details[id]) this.currentStatusDetails[id] = details[id];
            else delete this.currentStatusDetails[id];
          }
        }
      }
      this.applyStatuses(this.currentStatuses);
    });
    this.pushEvent("request_provider_statuses", {});

    // Provider label hover bridge: labels live in a separate layer (above the
    // modules) and are not descendants of the pin, so CSS :hover cannot reveal
    // them. Track which provider the cursor is over and publish a rule for its
    // label. A class would not survive: the dashboard re-renders on every
    // coalesced batch tick, and morphdom strips JS-applied classes, which made
    // a hovered label appear and then vanish a moment later.
    this.lastHoveredProviderId = null;
    this.boundHandleProviderHover = this.handleProviderHover.bind(this);
    this.boundClearProviderHover = this.clearProviderHover.bind(this);
    this.el.addEventListener("mouseover", this.boundHandleProviderHover);
    this.el.addEventListener("mouseleave", this.boundClearProviderHover);
  },

  destroyed() {
    this.el.removeEventListener("mouseover", this.boundHandleProviderHover);
    this.el.removeEventListener("mouseleave", this.boundClearProviderHover);
    for (const timer of this.blockPulses.values()) clearTimeout(timer);
    this.blockPulses.clear();
    this.statusStyleEl?.remove();
    this.statusStyleEl = null;
    this.hoverStyleEl?.remove();
    this.hoverStyleEl = null;
  },

  handleProviderHover(e) {
    const provider = e.target.closest("[data-provider]");
    const id = provider ? provider.dataset.provider : null;
    if (id === this.lastHoveredProviderId) return;
    this.setHoveredLabel(id);
  },

  clearProviderHover() {
    this.setHoveredLabel(null);
  },

  setHoveredLabel(id) {
    this.lastHoveredProviderId = id;

    if (!this.hoverStyleEl) return;

    this.hoverStyleEl.textContent = id
      ? `[data-provider-label="${CSS.escape(id)}"]{opacity:1}`
      : "";
  },

  // A LiveView patch can replace canvas nodes, taking the JS-applied colours and
  // block heights with it, so both layers are re-applied after every patch.
  updated() {
    if (this.pendingApply) return;
    if (
      Object.keys(this.currentStatuses).length === 0 &&
      Object.keys(this.currentBlocks).length === 0
    ) {
      return;
    }
    this.pendingApply = true;
    requestAnimationFrame(() => {
      this.pendingApply = false;
      this.applyStatuses(this.currentStatuses);
      this.applyChainBlocks(this.currentBlocks);
    });
  },

  reconnected() {
    this.pushEvent("request_provider_statuses", {});
  },

  applyStatuses(statuses) {
    for (const status of Object.keys(statuses)) {
      const node = this.el.querySelector(
        `[data-provider="${CSS.escape(status)}"]`,
      );
      if (node) {
        this.toggleProbingAffordance(node, statuses[status]);
        this.applyStatusTitle(node, statuses[status]);
      }
    }

    this.writeStatusStyles();
  },

  // Status colour is published as a stylesheet in the document head rather than
  // an inline style on each pin. Anything JS writes into the LiveView-managed
  // DOM is stripped by the next patch that touches the canvas — selecting a
  // chain re-renders the whole comprehension — which repainted every pad to its
  // default grey for a frame before the next re-apply could restore it. A
  // stylesheet lives outside the patched tree, so the colours simply survive.
  writeStatusStyles() {
    if (!this.statusStyleEl) return;

    const rules = [];
    for (const [providerId, status] of Object.entries(this.currentStatuses)) {
      const color = STATUS_COLORS[status] || STATUS_COLORS.unknown;
      rules.push(
        `[data-provider="${CSS.escape(providerId)}"] .provider-pad{--pad-color:${color}}`,
      );
    }

    this.statusStyleEl.textContent = rules.join("\n");
  },

  applyStatusTitle(node, status) {
    const baseTitle = node.dataset.providerTitle || "Provider";
    const explanation = this.currentStatusDetails[node.dataset.provider];
    const [label, detail] = explanation?.description
      ? [explanation.label, explanation.description]
      : STATUS_COPY[status] || STATUS_COPY.unknown;
    node.title = `${baseTitle} · ${label}: ${detail}`;
  },

  // Chain head heights arrive as a delta of {chain_id => height}. Only a height
  // that actually moved pulses; `advanced` is decided against the hook's own
  // tracked state, so re-applying after a patch restores the number silently.
  applyChainBlocks(blocks, advanced = {}) {
    for (const [chainId, height] of Object.entries(blocks)) {
      const indicator = this.el.querySelector(
        `[data-chain-block="${chainId}"]`,
      );
      if (!indicator) continue;

      const value = indicator.querySelector("[data-block-height]");
      if (!value) continue;

      value.textContent =
        height === null ? "" : Number(height).toLocaleString("en-US");

      if (advanced[chainId]) this.pulseBlock(indicator);
    }
  },

  pulseBlock(indicator) {
    indicator.classList.add("is-advancing");
    clearTimeout(this.blockPulses.get(indicator));
    this.blockPulses.set(
      indicator,
      setTimeout(() => indicator.classList.remove("is-advancing"), 420),
    );
  },

  toggleProbingAffordance(node, status) {
    const existing = node.querySelector("[data-probing-ring]");

    if (status === "probing" && !existing) {
      const ring = document.createElement("div");
      ring.dataset.probingRing = "";
      node.appendChild(ring);
    } else if (status !== "probing" && existing) {
      existing.remove();
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
    TabSwitcher: EndpointSelector,
    ExpandableDetails,
    ProfilePersistence,
    CopyButton,
    NetworkTopologyStatus,
  },
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
