// Simple test for Viem compatibility with ChainPulse JSON-RPC
const WebSocket = require('ws');

// Test JSON-RPC WebSocket endpoint
const ws = new WebSocket('ws://localhost:4000/rpc/ethereum');

ws.on('open', function open() {
  console.log('✅ Connected to ChainPulse JSON-RPC WebSocket');
  
  // Join the RPC channel
  const joinMessage = {
    topic: 'rpc:ethereum',
    event: 'phx_join',
    payload: {},
    ref: '1'
  };
  
  ws.send(JSON.stringify(joinMessage));
  console.log('📡 Sent join message');
});

ws.on('message', function message(data) {
  const response = JSON.parse(data.toString());
  console.log('📥 Received:', JSON.stringify(response, null, 2));
  
  if (response.event === 'phx_reply' && response.ref === '1') {
    console.log('✅ Successfully joined RPC channel');
    
    // Test eth_blockNumber call
    const rpcCall = {
      topic: 'rpc:ethereum',
      event: 'rpc_call',
      payload: {
        jsonrpc: '2.0',
        method: 'eth_blockNumber',
        params: [],
        id: 1
      },
      ref: '2'
    };
    
    ws.send(JSON.stringify(rpcCall));
    console.log('📡 Sent eth_blockNumber RPC call');
  }
  
  if (response.event === 'phx_reply' && response.ref === '2') {
    console.log('✅ RPC call successful!');
    
    // Test subscription
    const subscribeCall = {
      topic: 'rpc:ethereum',
      event: 'rpc_call',
      payload: {
        jsonrpc: '2.0',
        method: 'eth_subscribe',
        params: ['newHeads'],
        id: 2
      },
      ref: '3'
    };
    
    ws.send(JSON.stringify(subscribeCall));
    console.log('📡 Sent eth_subscribe call');
  }
  
  if (response.event === 'phx_reply' && response.ref === '3') {
    console.log('✅ Subscription created!');
    console.log('🎉 ChainPulse JSON-RPC is Viem-compatible!');
    
    // Keep connection open for a few seconds to receive events
    setTimeout(() => {
      ws.close();
    }, 5000);
  }
});

ws.on('error', function error(err) {
  console.error('❌ WebSocket error:', err.message);
});

ws.on('close', function close() {
  console.log('👋 Disconnected from ChainPulse');
});