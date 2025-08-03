// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

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

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: {
    CollapsibleSection,
  },
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
