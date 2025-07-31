#!/usr/bin/env elixir

# Quick Start Demo Script
# Run with: mix run scripts/start_demo.exs

IO.puts """
🚀 Livechain Quick Start Demo
═══════════════════════════════════════════════════════════════

This demo will start:
✅ Mock blockchain providers (Ethereum, Polygon)
✅ Phoenix WebSocket server on port 4000
✅ HTTP API endpoints
✅ Real-time block generation and broadcasting

Ready to test with multiple WebSocket clients!
"""

# Run the demo
ChainPulseDemo.run_live_demo(120)  # Run for 2 minutes

IO.puts """

🎉 Demo completed!

To continue testing:
1. Install wscat: npm install -g wscat
2. Connect: wscat -c "ws://localhost:4000/socket/websocket"
3. Join channel: {"topic":"blockchain:ethereum","event":"phx_join","payload":{},"ref":"1"}
4. Subscribe: {"topic":"blockchain:ethereum","event":"subscribe","payload":{"type":"blocks"},"ref":"2"}

See docs/QUICK_START.md for complete instructions.
"""
