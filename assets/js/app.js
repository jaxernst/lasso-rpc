// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// Simulator module
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

const SimulatorControl = {
  mounted() {
    console.log("SimulatorControl hook mounted");
    this.httpTimer = null;
    this.wsHandles = [];

    this.handleEvent("sim_start_http", (opts) => {
      console.log("sim_start_http received with opts:", opts);
      LassoSim.startHttpLoad(opts);
    });

    this.handleEvent("sim_stop_http", () => {
      LassoSim.stopHttpLoad();
    });

    this.handleEvent("sim_start_ws", (opts) => {
      console.log("sim_start_ws received with opts:", opts);
      LassoSim.startWsLoad(opts);
    });

    this.handleEvent("sim_stop_ws", () => {
      LassoSim.stopWsLoad();
    });

    this.statsInterval = setInterval(() => {
      if (this.el.isConnected && this.pushEvent) {
        const stats = LassoSim.activeStats();
        this.pushEvent("sim_stats", stats);
      }
    }, 1000);
  },
  destroyed() {
    clearInterval(this.statsInterval);
    LassoSim.stopHttpLoad();
    LassoSim.stopWsLoad();
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
  },
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
