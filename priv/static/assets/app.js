(() => {
  var __defProp = Object.defineProperty;
  var __defProps = Object.defineProperties;
  var __getOwnPropDescs = Object.getOwnPropertyDescriptors;
  var __getOwnPropSymbols = Object.getOwnPropertySymbols;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __propIsEnum = Object.prototype.propertyIsEnumerable;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __spreadValues = (a, b) => {
    for (var prop in b || (b = {}))
      if (__hasOwnProp.call(b, prop))
        __defNormalProp(a, prop, b[prop]);
    if (__getOwnPropSymbols)
      for (var prop of __getOwnPropSymbols(b)) {
        if (__propIsEnum.call(b, prop))
          __defNormalProp(a, prop, b[prop]);
      }
    return a;
  };
  var __spreadProps = (a, b) => __defProps(a, __getOwnPropDescs(b));

  // ../deps/phoenix_html/priv/static/phoenix_html.js
  (function() {
    var PolyfillEvent = eventConstructor();
    function eventConstructor() {
      if (typeof window.CustomEvent === "function")
        return window.CustomEvent;
      function CustomEvent2(event, params) {
        params = params || { bubbles: false, cancelable: false, detail: void 0 };
        var evt = document.createEvent("CustomEvent");
        evt.initCustomEvent(event, params.bubbles, params.cancelable, params.detail);
        return evt;
      }
      CustomEvent2.prototype = window.Event.prototype;
      return CustomEvent2;
    }
    function buildHiddenInput(name, value) {
      var input = document.createElement("input");
      input.type = "hidden";
      input.name = name;
      input.value = value;
      return input;
    }
    function handleClick(element, targetModifierKey) {
      var to = element.getAttribute("data-to"), method = buildHiddenInput("_method", element.getAttribute("data-method")), csrf = buildHiddenInput("_csrf_token", element.getAttribute("data-csrf")), form = document.createElement("form"), submit = document.createElement("input"), target = element.getAttribute("target");
      form.method = element.getAttribute("data-method") === "get" ? "get" : "post";
      form.action = to;
      form.style.display = "none";
      if (target)
        form.target = target;
      else if (targetModifierKey)
        form.target = "_blank";
      form.appendChild(csrf);
      form.appendChild(method);
      document.body.appendChild(form);
      submit.type = "submit";
      form.appendChild(submit);
      submit.click();
    }
    window.addEventListener("click", function(e) {
      var element = e.target;
      if (e.defaultPrevented)
        return;
      while (element && element.getAttribute) {
        var phoenixLinkEvent = new PolyfillEvent("phoenix.link.click", {
          "bubbles": true,
          "cancelable": true
        });
        if (!element.dispatchEvent(phoenixLinkEvent)) {
          e.preventDefault();
          e.stopImmediatePropagation();
          return false;
        }
        if (element.getAttribute("data-method") && element.getAttribute("data-to")) {
          handleClick(element, e.metaKey || e.shiftKey);
          e.preventDefault();
          return false;
        } else {
          element = element.parentNode;
        }
      }
    }, false);
    window.addEventListener("phoenix.link.click", function(e) {
      var message = e.target.getAttribute("data-confirm");
      if (message && !window.confirm(message)) {
        e.preventDefault();
      }
    }, false);
  })();

  // ../deps/phoenix/priv/static/phoenix.mjs
  var closure = (value) => {
    if (typeof value === "function") {
      return value;
    } else {
      let closure22 = function() {
        return value;
      };
      return closure22;
    }
  };
  var globalSelf = typeof self !== "undefined" ? self : null;
  var phxWindow = typeof window !== "undefined" ? window : null;
  var global = globalSelf || phxWindow || globalThis;
  var DEFAULT_VSN = "2.0.0";
  var SOCKET_STATES = { connecting: 0, open: 1, closing: 2, closed: 3 };
  var DEFAULT_TIMEOUT = 1e4;
  var WS_CLOSE_NORMAL = 1e3;
  var CHANNEL_STATES = {
    closed: "closed",
    errored: "errored",
    joined: "joined",
    joining: "joining",
    leaving: "leaving"
  };
  var CHANNEL_EVENTS = {
    close: "phx_close",
    error: "phx_error",
    join: "phx_join",
    reply: "phx_reply",
    leave: "phx_leave"
  };
  var TRANSPORTS = {
    longpoll: "longpoll",
    websocket: "websocket"
  };
  var XHR_STATES = {
    complete: 4
  };
  var AUTH_TOKEN_PREFIX = "base64url.bearer.phx.";
  var Push = class {
    constructor(channel, event, payload, timeout) {
      this.channel = channel;
      this.event = event;
      this.payload = payload || function() {
        return {};
      };
      this.receivedResp = null;
      this.timeout = timeout;
      this.timeoutTimer = null;
      this.recHooks = [];
      this.sent = false;
    }
    /**
     *
     * @param {number} timeout
     */
    resend(timeout) {
      this.timeout = timeout;
      this.reset();
      this.send();
    }
    /**
     *
     */
    send() {
      if (this.hasReceived("timeout")) {
        return;
      }
      this.startTimeout();
      this.sent = true;
      this.channel.socket.push({
        topic: this.channel.topic,
        event: this.event,
        payload: this.payload(),
        ref: this.ref,
        join_ref: this.channel.joinRef()
      });
    }
    /**
     *
     * @param {*} status
     * @param {*} callback
     */
    receive(status, callback) {
      if (this.hasReceived(status)) {
        callback(this.receivedResp.response);
      }
      this.recHooks.push({ status, callback });
      return this;
    }
    /**
     * @private
     */
    reset() {
      this.cancelRefEvent();
      this.ref = null;
      this.refEvent = null;
      this.receivedResp = null;
      this.sent = false;
    }
    /**
     * @private
     */
    matchReceive({ status, response, _ref }) {
      this.recHooks.filter((h) => h.status === status).forEach((h) => h.callback(response));
    }
    /**
     * @private
     */
    cancelRefEvent() {
      if (!this.refEvent) {
        return;
      }
      this.channel.off(this.refEvent);
    }
    /**
     * @private
     */
    cancelTimeout() {
      clearTimeout(this.timeoutTimer);
      this.timeoutTimer = null;
    }
    /**
     * @private
     */
    startTimeout() {
      if (this.timeoutTimer) {
        this.cancelTimeout();
      }
      this.ref = this.channel.socket.makeRef();
      this.refEvent = this.channel.replyEventName(this.ref);
      this.channel.on(this.refEvent, (payload) => {
        this.cancelRefEvent();
        this.cancelTimeout();
        this.receivedResp = payload;
        this.matchReceive(payload);
      });
      this.timeoutTimer = setTimeout(() => {
        this.trigger("timeout", {});
      }, this.timeout);
    }
    /**
     * @private
     */
    hasReceived(status) {
      return this.receivedResp && this.receivedResp.status === status;
    }
    /**
     * @private
     */
    trigger(status, response) {
      this.channel.trigger(this.refEvent, { status, response });
    }
  };
  var Timer = class {
    constructor(callback, timerCalc) {
      this.callback = callback;
      this.timerCalc = timerCalc;
      this.timer = null;
      this.tries = 0;
    }
    reset() {
      this.tries = 0;
      clearTimeout(this.timer);
    }
    /**
     * Cancels any previous scheduleTimeout and schedules callback
     */
    scheduleTimeout() {
      clearTimeout(this.timer);
      this.timer = setTimeout(() => {
        this.tries = this.tries + 1;
        this.callback();
      }, this.timerCalc(this.tries + 1));
    }
  };
  var Channel = class {
    constructor(topic, params, socket) {
      this.state = CHANNEL_STATES.closed;
      this.topic = topic;
      this.params = closure(params || {});
      this.socket = socket;
      this.bindings = [];
      this.bindingRef = 0;
      this.timeout = this.socket.timeout;
      this.joinedOnce = false;
      this.joinPush = new Push(this, CHANNEL_EVENTS.join, this.params, this.timeout);
      this.pushBuffer = [];
      this.stateChangeRefs = [];
      this.rejoinTimer = new Timer(() => {
        if (this.socket.isConnected()) {
          this.rejoin();
        }
      }, this.socket.rejoinAfterMs);
      this.stateChangeRefs.push(this.socket.onError(() => this.rejoinTimer.reset()));
      this.stateChangeRefs.push(
        this.socket.onOpen(() => {
          this.rejoinTimer.reset();
          if (this.isErrored()) {
            this.rejoin();
          }
        })
      );
      this.joinPush.receive("ok", () => {
        this.state = CHANNEL_STATES.joined;
        this.rejoinTimer.reset();
        this.pushBuffer.forEach((pushEvent) => pushEvent.send());
        this.pushBuffer = [];
      });
      this.joinPush.receive("error", () => {
        this.state = CHANNEL_STATES.errored;
        if (this.socket.isConnected()) {
          this.rejoinTimer.scheduleTimeout();
        }
      });
      this.onClose(() => {
        this.rejoinTimer.reset();
        if (this.socket.hasLogger())
          this.socket.log("channel", `close ${this.topic} ${this.joinRef()}`);
        this.state = CHANNEL_STATES.closed;
        this.socket.remove(this);
      });
      this.onError((reason) => {
        if (this.socket.hasLogger())
          this.socket.log("channel", `error ${this.topic}`, reason);
        if (this.isJoining()) {
          this.joinPush.reset();
        }
        this.state = CHANNEL_STATES.errored;
        if (this.socket.isConnected()) {
          this.rejoinTimer.scheduleTimeout();
        }
      });
      this.joinPush.receive("timeout", () => {
        if (this.socket.hasLogger())
          this.socket.log("channel", `timeout ${this.topic} (${this.joinRef()})`, this.joinPush.timeout);
        let leavePush = new Push(this, CHANNEL_EVENTS.leave, closure({}), this.timeout);
        leavePush.send();
        this.state = CHANNEL_STATES.errored;
        this.joinPush.reset();
        if (this.socket.isConnected()) {
          this.rejoinTimer.scheduleTimeout();
        }
      });
      this.on(CHANNEL_EVENTS.reply, (payload, ref) => {
        this.trigger(this.replyEventName(ref), payload);
      });
    }
    /**
     * Join the channel
     * @param {integer} timeout
     * @returns {Push}
     */
    join(timeout = this.timeout) {
      if (this.joinedOnce) {
        throw new Error("tried to join multiple times. 'join' can only be called a single time per channel instance");
      } else {
        this.timeout = timeout;
        this.joinedOnce = true;
        this.rejoin();
        return this.joinPush;
      }
    }
    /**
     * Hook into channel close
     * @param {Function} callback
     */
    onClose(callback) {
      this.on(CHANNEL_EVENTS.close, callback);
    }
    /**
     * Hook into channel errors
     * @param {Function} callback
     */
    onError(callback) {
      return this.on(CHANNEL_EVENTS.error, (reason) => callback(reason));
    }
    /**
     * Subscribes on channel events
     *
     * Subscription returns a ref counter, which can be used later to
     * unsubscribe the exact event listener
     *
     * @example
     * const ref1 = channel.on("event", do_stuff)
     * const ref2 = channel.on("event", do_other_stuff)
     * channel.off("event", ref1)
     * // Since unsubscription, do_stuff won't fire,
     * // while do_other_stuff will keep firing on the "event"
     *
     * @param {string} event
     * @param {Function} callback
     * @returns {integer} ref
     */
    on(event, callback) {
      let ref = this.bindingRef++;
      this.bindings.push({ event, ref, callback });
      return ref;
    }
    /**
     * Unsubscribes off of channel events
     *
     * Use the ref returned from a channel.on() to unsubscribe one
     * handler, or pass nothing for the ref to unsubscribe all
     * handlers for the given event.
     *
     * @example
     * // Unsubscribe the do_stuff handler
     * const ref1 = channel.on("event", do_stuff)
     * channel.off("event", ref1)
     *
     * // Unsubscribe all handlers from event
     * channel.off("event")
     *
     * @param {string} event
     * @param {integer} ref
     */
    off(event, ref) {
      this.bindings = this.bindings.filter((bind) => {
        return !(bind.event === event && (typeof ref === "undefined" || ref === bind.ref));
      });
    }
    /**
     * @private
     */
    canPush() {
      return this.socket.isConnected() && this.isJoined();
    }
    /**
     * Sends a message `event` to phoenix with the payload `payload`.
     * Phoenix receives this in the `handle_in(event, payload, socket)`
     * function. if phoenix replies or it times out (default 10000ms),
     * then optionally the reply can be received.
     *
     * @example
     * channel.push("event")
     *   .receive("ok", payload => console.log("phoenix replied:", payload))
     *   .receive("error", err => console.log("phoenix errored", err))
     *   .receive("timeout", () => console.log("timed out pushing"))
     * @param {string} event
     * @param {Object} payload
     * @param {number} [timeout]
     * @returns {Push}
     */
    push(event, payload, timeout = this.timeout) {
      payload = payload || {};
      if (!this.joinedOnce) {
        throw new Error(`tried to push '${event}' to '${this.topic}' before joining. Use channel.join() before pushing events`);
      }
      let pushEvent = new Push(this, event, function() {
        return payload;
      }, timeout);
      if (this.canPush()) {
        pushEvent.send();
      } else {
        pushEvent.startTimeout();
        this.pushBuffer.push(pushEvent);
      }
      return pushEvent;
    }
    /** Leaves the channel
     *
     * Unsubscribes from server events, and
     * instructs channel to terminate on server
     *
     * Triggers onClose() hooks
     *
     * To receive leave acknowledgements, use the `receive`
     * hook to bind to the server ack, ie:
     *
     * @example
     * channel.leave().receive("ok", () => alert("left!") )
     *
     * @param {integer} timeout
     * @returns {Push}
     */
    leave(timeout = this.timeout) {
      this.rejoinTimer.reset();
      this.joinPush.cancelTimeout();
      this.state = CHANNEL_STATES.leaving;
      let onClose = () => {
        if (this.socket.hasLogger())
          this.socket.log("channel", `leave ${this.topic}`);
        this.trigger(CHANNEL_EVENTS.close, "leave");
      };
      let leavePush = new Push(this, CHANNEL_EVENTS.leave, closure({}), timeout);
      leavePush.receive("ok", () => onClose()).receive("timeout", () => onClose());
      leavePush.send();
      if (!this.canPush()) {
        leavePush.trigger("ok", {});
      }
      return leavePush;
    }
    /**
     * Overridable message hook
     *
     * Receives all events for specialized message handling
     * before dispatching to the channel callbacks.
     *
     * Must return the payload, modified or unmodified
     * @param {string} event
     * @param {Object} payload
     * @param {integer} ref
     * @returns {Object}
     */
    onMessage(_event, payload, _ref) {
      return payload;
    }
    /**
     * @private
     */
    isMember(topic, event, payload, joinRef) {
      if (this.topic !== topic) {
        return false;
      }
      if (joinRef && joinRef !== this.joinRef()) {
        if (this.socket.hasLogger())
          this.socket.log("channel", "dropping outdated message", { topic, event, payload, joinRef });
        return false;
      } else {
        return true;
      }
    }
    /**
     * @private
     */
    joinRef() {
      return this.joinPush.ref;
    }
    /**
     * @private
     */
    rejoin(timeout = this.timeout) {
      if (this.isLeaving()) {
        return;
      }
      this.socket.leaveOpenTopic(this.topic);
      this.state = CHANNEL_STATES.joining;
      this.joinPush.resend(timeout);
    }
    /**
     * @private
     */
    trigger(event, payload, ref, joinRef) {
      let handledPayload = this.onMessage(event, payload, ref, joinRef);
      if (payload && !handledPayload) {
        throw new Error("channel onMessage callbacks must return the payload, modified or unmodified");
      }
      let eventBindings = this.bindings.filter((bind) => bind.event === event);
      for (let i = 0; i < eventBindings.length; i++) {
        let bind = eventBindings[i];
        bind.callback(handledPayload, ref, joinRef || this.joinRef());
      }
    }
    /**
     * @private
     */
    replyEventName(ref) {
      return `chan_reply_${ref}`;
    }
    /**
     * @private
     */
    isClosed() {
      return this.state === CHANNEL_STATES.closed;
    }
    /**
     * @private
     */
    isErrored() {
      return this.state === CHANNEL_STATES.errored;
    }
    /**
     * @private
     */
    isJoined() {
      return this.state === CHANNEL_STATES.joined;
    }
    /**
     * @private
     */
    isJoining() {
      return this.state === CHANNEL_STATES.joining;
    }
    /**
     * @private
     */
    isLeaving() {
      return this.state === CHANNEL_STATES.leaving;
    }
  };
  var Ajax = class {
    static request(method, endPoint, headers, body, timeout, ontimeout, callback) {
      if (global.XDomainRequest) {
        let req = new global.XDomainRequest();
        return this.xdomainRequest(req, method, endPoint, body, timeout, ontimeout, callback);
      } else if (global.XMLHttpRequest) {
        let req = new global.XMLHttpRequest();
        return this.xhrRequest(req, method, endPoint, headers, body, timeout, ontimeout, callback);
      } else if (global.fetch && global.AbortController) {
        return this.fetchRequest(method, endPoint, headers, body, timeout, ontimeout, callback);
      } else {
        throw new Error("No suitable XMLHttpRequest implementation found");
      }
    }
    static fetchRequest(method, endPoint, headers, body, timeout, ontimeout, callback) {
      let options = {
        method,
        headers,
        body
      };
      let controller = null;
      if (timeout) {
        controller = new AbortController();
        const _timeoutId = setTimeout(() => controller.abort(), timeout);
        options.signal = controller.signal;
      }
      global.fetch(endPoint, options).then((response) => response.text()).then((data) => this.parseJSON(data)).then((data) => callback && callback(data)).catch((err) => {
        if (err.name === "AbortError" && ontimeout) {
          ontimeout();
        } else {
          callback && callback(null);
        }
      });
      return controller;
    }
    static xdomainRequest(req, method, endPoint, body, timeout, ontimeout, callback) {
      req.timeout = timeout;
      req.open(method, endPoint);
      req.onload = () => {
        let response = this.parseJSON(req.responseText);
        callback && callback(response);
      };
      if (ontimeout) {
        req.ontimeout = ontimeout;
      }
      req.onprogress = () => {
      };
      req.send(body);
      return req;
    }
    static xhrRequest(req, method, endPoint, headers, body, timeout, ontimeout, callback) {
      req.open(method, endPoint, true);
      req.timeout = timeout;
      for (let [key, value] of Object.entries(headers)) {
        req.setRequestHeader(key, value);
      }
      req.onerror = () => callback && callback(null);
      req.onreadystatechange = () => {
        if (req.readyState === XHR_STATES.complete && callback) {
          let response = this.parseJSON(req.responseText);
          callback(response);
        }
      };
      if (ontimeout) {
        req.ontimeout = ontimeout;
      }
      req.send(body);
      return req;
    }
    static parseJSON(resp) {
      if (!resp || resp === "") {
        return null;
      }
      try {
        return JSON.parse(resp);
      } catch (e) {
        console && console.log("failed to parse JSON response", resp);
        return null;
      }
    }
    static serialize(obj, parentKey) {
      let queryStr = [];
      for (var key in obj) {
        if (!Object.prototype.hasOwnProperty.call(obj, key)) {
          continue;
        }
        let paramKey = parentKey ? `${parentKey}[${key}]` : key;
        let paramVal = obj[key];
        if (typeof paramVal === "object") {
          queryStr.push(this.serialize(paramVal, paramKey));
        } else {
          queryStr.push(encodeURIComponent(paramKey) + "=" + encodeURIComponent(paramVal));
        }
      }
      return queryStr.join("&");
    }
    static appendParams(url, params) {
      if (Object.keys(params).length === 0) {
        return url;
      }
      let prefix = url.match(/\?/) ? "&" : "?";
      return `${url}${prefix}${this.serialize(params)}`;
    }
  };
  var arrayBufferToBase64 = (buffer) => {
    let binary = "";
    let bytes = new Uint8Array(buffer);
    let len = bytes.byteLength;
    for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  };
  var LongPoll = class {
    constructor(endPoint, protocols) {
      if (protocols && protocols.length === 2 && protocols[1].startsWith(AUTH_TOKEN_PREFIX)) {
        this.authToken = atob(protocols[1].slice(AUTH_TOKEN_PREFIX.length));
      }
      this.endPoint = null;
      this.token = null;
      this.skipHeartbeat = true;
      this.reqs = /* @__PURE__ */ new Set();
      this.awaitingBatchAck = false;
      this.currentBatch = null;
      this.currentBatchTimer = null;
      this.batchBuffer = [];
      this.onopen = function() {
      };
      this.onerror = function() {
      };
      this.onmessage = function() {
      };
      this.onclose = function() {
      };
      this.pollEndpoint = this.normalizeEndpoint(endPoint);
      this.readyState = SOCKET_STATES.connecting;
      setTimeout(() => this.poll(), 0);
    }
    normalizeEndpoint(endPoint) {
      return endPoint.replace("ws://", "http://").replace("wss://", "https://").replace(new RegExp("(.*)/" + TRANSPORTS.websocket), "$1/" + TRANSPORTS.longpoll);
    }
    endpointURL() {
      return Ajax.appendParams(this.pollEndpoint, { token: this.token });
    }
    closeAndRetry(code, reason, wasClean) {
      this.close(code, reason, wasClean);
      this.readyState = SOCKET_STATES.connecting;
    }
    ontimeout() {
      this.onerror("timeout");
      this.closeAndRetry(1005, "timeout", false);
    }
    isActive() {
      return this.readyState === SOCKET_STATES.open || this.readyState === SOCKET_STATES.connecting;
    }
    poll() {
      const headers = { "Accept": "application/json" };
      if (this.authToken) {
        headers["X-Phoenix-AuthToken"] = this.authToken;
      }
      this.ajax("GET", headers, null, () => this.ontimeout(), (resp) => {
        if (resp) {
          var { status, token, messages } = resp;
          this.token = token;
        } else {
          status = 0;
        }
        switch (status) {
          case 200:
            messages.forEach((msg) => {
              setTimeout(() => this.onmessage({ data: msg }), 0);
            });
            this.poll();
            break;
          case 204:
            this.poll();
            break;
          case 410:
            this.readyState = SOCKET_STATES.open;
            this.onopen({});
            this.poll();
            break;
          case 403:
            this.onerror(403);
            this.close(1008, "forbidden", false);
            break;
          case 0:
          case 500:
            this.onerror(500);
            this.closeAndRetry(1011, "internal server error", 500);
            break;
          default:
            throw new Error(`unhandled poll status ${status}`);
        }
      });
    }
    // we collect all pushes within the current event loop by
    // setTimeout 0, which optimizes back-to-back procedural
    // pushes against an empty buffer
    send(body) {
      if (typeof body !== "string") {
        body = arrayBufferToBase64(body);
      }
      if (this.currentBatch) {
        this.currentBatch.push(body);
      } else if (this.awaitingBatchAck) {
        this.batchBuffer.push(body);
      } else {
        this.currentBatch = [body];
        this.currentBatchTimer = setTimeout(() => {
          this.batchSend(this.currentBatch);
          this.currentBatch = null;
        }, 0);
      }
    }
    batchSend(messages) {
      this.awaitingBatchAck = true;
      this.ajax("POST", { "Content-Type": "application/x-ndjson" }, messages.join("\n"), () => this.onerror("timeout"), (resp) => {
        this.awaitingBatchAck = false;
        if (!resp || resp.status !== 200) {
          this.onerror(resp && resp.status);
          this.closeAndRetry(1011, "internal server error", false);
        } else if (this.batchBuffer.length > 0) {
          this.batchSend(this.batchBuffer);
          this.batchBuffer = [];
        }
      });
    }
    close(code, reason, wasClean) {
      for (let req of this.reqs) {
        req.abort();
      }
      this.readyState = SOCKET_STATES.closed;
      let opts = Object.assign({ code: 1e3, reason: void 0, wasClean: true }, { code, reason, wasClean });
      this.batchBuffer = [];
      clearTimeout(this.currentBatchTimer);
      this.currentBatchTimer = null;
      if (typeof CloseEvent !== "undefined") {
        this.onclose(new CloseEvent("close", opts));
      } else {
        this.onclose(opts);
      }
    }
    ajax(method, headers, body, onCallerTimeout, callback) {
      let req;
      let ontimeout = () => {
        this.reqs.delete(req);
        onCallerTimeout();
      };
      req = Ajax.request(method, this.endpointURL(), headers, body, this.timeout, ontimeout, (resp) => {
        this.reqs.delete(req);
        if (this.isActive()) {
          callback(resp);
        }
      });
      this.reqs.add(req);
    }
  };
  var serializer_default = {
    HEADER_LENGTH: 1,
    META_LENGTH: 4,
    KINDS: { push: 0, reply: 1, broadcast: 2 },
    encode(msg, callback) {
      if (msg.payload.constructor === ArrayBuffer) {
        return callback(this.binaryEncode(msg));
      } else {
        let payload = [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload];
        return callback(JSON.stringify(payload));
      }
    },
    decode(rawPayload, callback) {
      if (rawPayload.constructor === ArrayBuffer) {
        return callback(this.binaryDecode(rawPayload));
      } else {
        let [join_ref, ref, topic, event, payload] = JSON.parse(rawPayload);
        return callback({ join_ref, ref, topic, event, payload });
      }
    },
    // private
    binaryEncode(message) {
      let { join_ref, ref, event, topic, payload } = message;
      let metaLength = this.META_LENGTH + join_ref.length + ref.length + topic.length + event.length;
      let header = new ArrayBuffer(this.HEADER_LENGTH + metaLength);
      let view = new DataView(header);
      let offset = 0;
      view.setUint8(offset++, this.KINDS.push);
      view.setUint8(offset++, join_ref.length);
      view.setUint8(offset++, ref.length);
      view.setUint8(offset++, topic.length);
      view.setUint8(offset++, event.length);
      Array.from(join_ref, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      Array.from(ref, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      Array.from(topic, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      Array.from(event, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      var combined = new Uint8Array(header.byteLength + payload.byteLength);
      combined.set(new Uint8Array(header), 0);
      combined.set(new Uint8Array(payload), header.byteLength);
      return combined.buffer;
    },
    binaryDecode(buffer) {
      let view = new DataView(buffer);
      let kind = view.getUint8(0);
      let decoder = new TextDecoder();
      switch (kind) {
        case this.KINDS.push:
          return this.decodePush(buffer, view, decoder);
        case this.KINDS.reply:
          return this.decodeReply(buffer, view, decoder);
        case this.KINDS.broadcast:
          return this.decodeBroadcast(buffer, view, decoder);
      }
    },
    decodePush(buffer, view, decoder) {
      let joinRefSize = view.getUint8(1);
      let topicSize = view.getUint8(2);
      let eventSize = view.getUint8(3);
      let offset = this.HEADER_LENGTH + this.META_LENGTH - 1;
      let joinRef = decoder.decode(buffer.slice(offset, offset + joinRefSize));
      offset = offset + joinRefSize;
      let topic = decoder.decode(buffer.slice(offset, offset + topicSize));
      offset = offset + topicSize;
      let event = decoder.decode(buffer.slice(offset, offset + eventSize));
      offset = offset + eventSize;
      let data = buffer.slice(offset, buffer.byteLength);
      return { join_ref: joinRef, ref: null, topic, event, payload: data };
    },
    decodeReply(buffer, view, decoder) {
      let joinRefSize = view.getUint8(1);
      let refSize = view.getUint8(2);
      let topicSize = view.getUint8(3);
      let eventSize = view.getUint8(4);
      let offset = this.HEADER_LENGTH + this.META_LENGTH;
      let joinRef = decoder.decode(buffer.slice(offset, offset + joinRefSize));
      offset = offset + joinRefSize;
      let ref = decoder.decode(buffer.slice(offset, offset + refSize));
      offset = offset + refSize;
      let topic = decoder.decode(buffer.slice(offset, offset + topicSize));
      offset = offset + topicSize;
      let event = decoder.decode(buffer.slice(offset, offset + eventSize));
      offset = offset + eventSize;
      let data = buffer.slice(offset, buffer.byteLength);
      let payload = { status: event, response: data };
      return { join_ref: joinRef, ref, topic, event: CHANNEL_EVENTS.reply, payload };
    },
    decodeBroadcast(buffer, view, decoder) {
      let topicSize = view.getUint8(1);
      let eventSize = view.getUint8(2);
      let offset = this.HEADER_LENGTH + 2;
      let topic = decoder.decode(buffer.slice(offset, offset + topicSize));
      offset = offset + topicSize;
      let event = decoder.decode(buffer.slice(offset, offset + eventSize));
      offset = offset + eventSize;
      let data = buffer.slice(offset, buffer.byteLength);
      return { join_ref: null, ref: null, topic, event, payload: data };
    }
  };
  var Socket = class {
    constructor(endPoint, opts = {}) {
      this.stateChangeCallbacks = { open: [], close: [], error: [], message: [] };
      this.channels = [];
      this.sendBuffer = [];
      this.ref = 0;
      this.timeout = opts.timeout || DEFAULT_TIMEOUT;
      this.transport = opts.transport || global.WebSocket || LongPoll;
      this.primaryPassedHealthCheck = false;
      this.longPollFallbackMs = opts.longPollFallbackMs;
      this.fallbackTimer = null;
      this.sessionStore = opts.sessionStorage || global && global.sessionStorage;
      this.establishedConnections = 0;
      this.defaultEncoder = serializer_default.encode.bind(serializer_default);
      this.defaultDecoder = serializer_default.decode.bind(serializer_default);
      this.closeWasClean = false;
      this.disconnecting = false;
      this.binaryType = opts.binaryType || "arraybuffer";
      this.connectClock = 1;
      if (this.transport !== LongPoll) {
        this.encode = opts.encode || this.defaultEncoder;
        this.decode = opts.decode || this.defaultDecoder;
      } else {
        this.encode = this.defaultEncoder;
        this.decode = this.defaultDecoder;
      }
      let awaitingConnectionOnPageShow = null;
      if (phxWindow && phxWindow.addEventListener) {
        phxWindow.addEventListener("pagehide", (_e) => {
          if (this.conn) {
            this.disconnect();
            awaitingConnectionOnPageShow = this.connectClock;
          }
        });
        phxWindow.addEventListener("pageshow", (_e) => {
          if (awaitingConnectionOnPageShow === this.connectClock) {
            awaitingConnectionOnPageShow = null;
            this.connect();
          }
        });
      }
      this.heartbeatIntervalMs = opts.heartbeatIntervalMs || 3e4;
      this.rejoinAfterMs = (tries) => {
        if (opts.rejoinAfterMs) {
          return opts.rejoinAfterMs(tries);
        } else {
          return [1e3, 2e3, 5e3][tries - 1] || 1e4;
        }
      };
      this.reconnectAfterMs = (tries) => {
        if (opts.reconnectAfterMs) {
          return opts.reconnectAfterMs(tries);
        } else {
          return [10, 50, 100, 150, 200, 250, 500, 1e3, 2e3][tries - 1] || 5e3;
        }
      };
      this.logger = opts.logger || null;
      if (!this.logger && opts.debug) {
        this.logger = (kind, msg, data) => {
          console.log(`${kind}: ${msg}`, data);
        };
      }
      this.longpollerTimeout = opts.longpollerTimeout || 2e4;
      this.params = closure(opts.params || {});
      this.endPoint = `${endPoint}/${TRANSPORTS.websocket}`;
      this.vsn = opts.vsn || DEFAULT_VSN;
      this.heartbeatTimeoutTimer = null;
      this.heartbeatTimer = null;
      this.pendingHeartbeatRef = null;
      this.reconnectTimer = new Timer(() => {
        this.teardown(() => this.connect());
      }, this.reconnectAfterMs);
      this.authToken = opts.authToken;
    }
    /**
     * Returns the LongPoll transport reference
     */
    getLongPollTransport() {
      return LongPoll;
    }
    /**
     * Disconnects and replaces the active transport
     *
     * @param {Function} newTransport - The new transport class to instantiate
     *
     */
    replaceTransport(newTransport) {
      this.connectClock++;
      this.closeWasClean = true;
      clearTimeout(this.fallbackTimer);
      this.reconnectTimer.reset();
      if (this.conn) {
        this.conn.close();
        this.conn = null;
      }
      this.transport = newTransport;
    }
    /**
     * Returns the socket protocol
     *
     * @returns {string}
     */
    protocol() {
      return location.protocol.match(/^https/) ? "wss" : "ws";
    }
    /**
     * The fully qualified socket url
     *
     * @returns {string}
     */
    endPointURL() {
      let uri = Ajax.appendParams(
        Ajax.appendParams(this.endPoint, this.params()),
        { vsn: this.vsn }
      );
      if (uri.charAt(0) !== "/") {
        return uri;
      }
      if (uri.charAt(1) === "/") {
        return `${this.protocol()}:${uri}`;
      }
      return `${this.protocol()}://${location.host}${uri}`;
    }
    /**
     * Disconnects the socket
     *
     * See https://developer.mozilla.org/en-US/docs/Web/API/CloseEvent#Status_codes for valid status codes.
     *
     * @param {Function} callback - Optional callback which is called after socket is disconnected.
     * @param {integer} code - A status code for disconnection (Optional).
     * @param {string} reason - A textual description of the reason to disconnect. (Optional)
     */
    disconnect(callback, code, reason) {
      this.connectClock++;
      this.disconnecting = true;
      this.closeWasClean = true;
      clearTimeout(this.fallbackTimer);
      this.reconnectTimer.reset();
      this.teardown(() => {
        this.disconnecting = false;
        callback && callback();
      }, code, reason);
    }
    /**
     *
     * @param {Object} params - The params to send when connecting, for example `{user_id: userToken}`
     *
     * Passing params to connect is deprecated; pass them in the Socket constructor instead:
     * `new Socket("/socket", {params: {user_id: userToken}})`.
     */
    connect(params) {
      if (params) {
        console && console.log("passing params to connect is deprecated. Instead pass :params to the Socket constructor");
        this.params = closure(params);
      }
      if (this.conn && !this.disconnecting) {
        return;
      }
      if (this.longPollFallbackMs && this.transport !== LongPoll) {
        this.connectWithFallback(LongPoll, this.longPollFallbackMs);
      } else {
        this.transportConnect();
      }
    }
    /**
     * Logs the message. Override `this.logger` for specialized logging. noops by default
     * @param {string} kind
     * @param {string} msg
     * @param {Object} data
     */
    log(kind, msg, data) {
      this.logger && this.logger(kind, msg, data);
    }
    /**
     * Returns true if a logger has been set on this socket.
     */
    hasLogger() {
      return this.logger !== null;
    }
    /**
     * Registers callbacks for connection open events
     *
     * @example socket.onOpen(function(){ console.info("the socket was opened") })
     *
     * @param {Function} callback
     */
    onOpen(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.open.push([ref, callback]);
      return ref;
    }
    /**
     * Registers callbacks for connection close events
     * @param {Function} callback
     */
    onClose(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.close.push([ref, callback]);
      return ref;
    }
    /**
     * Registers callbacks for connection error events
     *
     * @example socket.onError(function(error){ alert("An error occurred") })
     *
     * @param {Function} callback
     */
    onError(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.error.push([ref, callback]);
      return ref;
    }
    /**
     * Registers callbacks for connection message events
     * @param {Function} callback
     */
    onMessage(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.message.push([ref, callback]);
      return ref;
    }
    /**
     * Pings the server and invokes the callback with the RTT in milliseconds
     * @param {Function} callback
     *
     * Returns true if the ping was pushed or false if unable to be pushed.
     */
    ping(callback) {
      if (!this.isConnected()) {
        return false;
      }
      let ref = this.makeRef();
      let startTime = Date.now();
      this.push({ topic: "phoenix", event: "heartbeat", payload: {}, ref });
      let onMsgRef = this.onMessage((msg) => {
        if (msg.ref === ref) {
          this.off([onMsgRef]);
          callback(Date.now() - startTime);
        }
      });
      return true;
    }
    /**
     * @private
     */
    transportConnect() {
      this.connectClock++;
      this.closeWasClean = false;
      let protocols = void 0;
      if (this.authToken) {
        protocols = ["phoenix", `${AUTH_TOKEN_PREFIX}${btoa(this.authToken).replace(/=/g, "")}`];
      }
      this.conn = new this.transport(this.endPointURL(), protocols);
      this.conn.binaryType = this.binaryType;
      this.conn.timeout = this.longpollerTimeout;
      this.conn.onopen = () => this.onConnOpen();
      this.conn.onerror = (error) => this.onConnError(error);
      this.conn.onmessage = (event) => this.onConnMessage(event);
      this.conn.onclose = (event) => this.onConnClose(event);
    }
    getSession(key) {
      return this.sessionStore && this.sessionStore.getItem(key);
    }
    storeSession(key, val) {
      this.sessionStore && this.sessionStore.setItem(key, val);
    }
    connectWithFallback(fallbackTransport, fallbackThreshold = 2500) {
      clearTimeout(this.fallbackTimer);
      let established = false;
      let primaryTransport = true;
      let openRef, errorRef;
      let fallback = (reason) => {
        this.log("transport", `falling back to ${fallbackTransport.name}...`, reason);
        this.off([openRef, errorRef]);
        primaryTransport = false;
        this.replaceTransport(fallbackTransport);
        this.transportConnect();
      };
      if (this.getSession(`phx:fallback:${fallbackTransport.name}`)) {
        return fallback("memorized");
      }
      this.fallbackTimer = setTimeout(fallback, fallbackThreshold);
      errorRef = this.onError((reason) => {
        this.log("transport", "error", reason);
        if (primaryTransport && !established) {
          clearTimeout(this.fallbackTimer);
          fallback(reason);
        }
      });
      this.onOpen(() => {
        established = true;
        if (!primaryTransport) {
          if (!this.primaryPassedHealthCheck) {
            this.storeSession(`phx:fallback:${fallbackTransport.name}`, "true");
          }
          return this.log("transport", `established ${fallbackTransport.name} fallback`);
        }
        clearTimeout(this.fallbackTimer);
        this.fallbackTimer = setTimeout(fallback, fallbackThreshold);
        this.ping((rtt) => {
          this.log("transport", "connected to primary after", rtt);
          this.primaryPassedHealthCheck = true;
          clearTimeout(this.fallbackTimer);
        });
      });
      this.transportConnect();
    }
    clearHeartbeats() {
      clearTimeout(this.heartbeatTimer);
      clearTimeout(this.heartbeatTimeoutTimer);
    }
    onConnOpen() {
      if (this.hasLogger())
        this.log("transport", `${this.transport.name} connected to ${this.endPointURL()}`);
      this.closeWasClean = false;
      this.disconnecting = false;
      this.establishedConnections++;
      this.flushSendBuffer();
      this.reconnectTimer.reset();
      this.resetHeartbeat();
      this.stateChangeCallbacks.open.forEach(([, callback]) => callback());
    }
    /**
     * @private
     */
    heartbeatTimeout() {
      if (this.pendingHeartbeatRef) {
        this.pendingHeartbeatRef = null;
        if (this.hasLogger()) {
          this.log("transport", "heartbeat timeout. Attempting to re-establish connection");
        }
        this.triggerChanError();
        this.closeWasClean = false;
        this.teardown(() => this.reconnectTimer.scheduleTimeout(), WS_CLOSE_NORMAL, "heartbeat timeout");
      }
    }
    resetHeartbeat() {
      if (this.conn && this.conn.skipHeartbeat) {
        return;
      }
      this.pendingHeartbeatRef = null;
      this.clearHeartbeats();
      this.heartbeatTimer = setTimeout(() => this.sendHeartbeat(), this.heartbeatIntervalMs);
    }
    teardown(callback, code, reason) {
      if (!this.conn) {
        return callback && callback();
      }
      let connectClock = this.connectClock;
      this.waitForBufferDone(() => {
        if (connectClock !== this.connectClock) {
          return;
        }
        if (this.conn) {
          if (code) {
            this.conn.close(code, reason || "");
          } else {
            this.conn.close();
          }
        }
        this.waitForSocketClosed(() => {
          if (connectClock !== this.connectClock) {
            return;
          }
          if (this.conn) {
            this.conn.onopen = function() {
            };
            this.conn.onerror = function() {
            };
            this.conn.onmessage = function() {
            };
            this.conn.onclose = function() {
            };
            this.conn = null;
          }
          callback && callback();
        });
      });
    }
    waitForBufferDone(callback, tries = 1) {
      if (tries === 5 || !this.conn || !this.conn.bufferedAmount) {
        callback();
        return;
      }
      setTimeout(() => {
        this.waitForBufferDone(callback, tries + 1);
      }, 150 * tries);
    }
    waitForSocketClosed(callback, tries = 1) {
      if (tries === 5 || !this.conn || this.conn.readyState === SOCKET_STATES.closed) {
        callback();
        return;
      }
      setTimeout(() => {
        this.waitForSocketClosed(callback, tries + 1);
      }, 150 * tries);
    }
    onConnClose(event) {
      let closeCode = event && event.code;
      if (this.hasLogger())
        this.log("transport", "close", event);
      this.triggerChanError();
      this.clearHeartbeats();
      if (!this.closeWasClean && closeCode !== 1e3) {
        this.reconnectTimer.scheduleTimeout();
      }
      this.stateChangeCallbacks.close.forEach(([, callback]) => callback(event));
    }
    /**
     * @private
     */
    onConnError(error) {
      if (this.hasLogger())
        this.log("transport", error);
      let transportBefore = this.transport;
      let establishedBefore = this.establishedConnections;
      this.stateChangeCallbacks.error.forEach(([, callback]) => {
        callback(error, transportBefore, establishedBefore);
      });
      if (transportBefore === this.transport || establishedBefore > 0) {
        this.triggerChanError();
      }
    }
    /**
     * @private
     */
    triggerChanError() {
      this.channels.forEach((channel) => {
        if (!(channel.isErrored() || channel.isLeaving() || channel.isClosed())) {
          channel.trigger(CHANNEL_EVENTS.error);
        }
      });
    }
    /**
     * @returns {string}
     */
    connectionState() {
      switch (this.conn && this.conn.readyState) {
        case SOCKET_STATES.connecting:
          return "connecting";
        case SOCKET_STATES.open:
          return "open";
        case SOCKET_STATES.closing:
          return "closing";
        default:
          return "closed";
      }
    }
    /**
     * @returns {boolean}
     */
    isConnected() {
      return this.connectionState() === "open";
    }
    /**
     * @private
     *
     * @param {Channel}
     */
    remove(channel) {
      this.off(channel.stateChangeRefs);
      this.channels = this.channels.filter((c) => c !== channel);
    }
    /**
     * Removes `onOpen`, `onClose`, `onError,` and `onMessage` registrations.
     *
     * @param {refs} - list of refs returned by calls to
     *                 `onOpen`, `onClose`, `onError,` and `onMessage`
     */
    off(refs) {
      for (let key in this.stateChangeCallbacks) {
        this.stateChangeCallbacks[key] = this.stateChangeCallbacks[key].filter(([ref]) => {
          return refs.indexOf(ref) === -1;
        });
      }
    }
    /**
     * Initiates a new channel for the given topic
     *
     * @param {string} topic
     * @param {Object} chanParams - Parameters for the channel
     * @returns {Channel}
     */
    channel(topic, chanParams = {}) {
      let chan = new Channel(topic, chanParams, this);
      this.channels.push(chan);
      return chan;
    }
    /**
     * @param {Object} data
     */
    push(data) {
      if (this.hasLogger()) {
        let { topic, event, payload, ref, join_ref } = data;
        this.log("push", `${topic} ${event} (${join_ref}, ${ref})`, payload);
      }
      if (this.isConnected()) {
        this.encode(data, (result) => this.conn.send(result));
      } else {
        this.sendBuffer.push(() => this.encode(data, (result) => this.conn.send(result)));
      }
    }
    /**
     * Return the next message ref, accounting for overflows
     * @returns {string}
     */
    makeRef() {
      let newRef = this.ref + 1;
      if (newRef === this.ref) {
        this.ref = 0;
      } else {
        this.ref = newRef;
      }
      return this.ref.toString();
    }
    sendHeartbeat() {
      if (this.pendingHeartbeatRef && !this.isConnected()) {
        return;
      }
      this.pendingHeartbeatRef = this.makeRef();
      this.push({ topic: "phoenix", event: "heartbeat", payload: {}, ref: this.pendingHeartbeatRef });
      this.heartbeatTimeoutTimer = setTimeout(() => this.heartbeatTimeout(), this.heartbeatIntervalMs);
    }
    flushSendBuffer() {
      if (this.isConnected() && this.sendBuffer.length > 0) {
        this.sendBuffer.forEach((callback) => callback());
        this.sendBuffer = [];
      }
    }
    onConnMessage(rawMessage) {
      this.decode(rawMessage.data, (msg) => {
        let { topic, event, payload, ref, join_ref } = msg;
        if (ref && ref === this.pendingHeartbeatRef) {
          this.clearHeartbeats();
          this.pendingHeartbeatRef = null;
          this.heartbeatTimer = setTimeout(() => this.sendHeartbeat(), this.heartbeatIntervalMs);
        }
        if (this.hasLogger())
          this.log("receive", `${payload.status || ""} ${topic} ${event} ${ref && "(" + ref + ")" || ""}`, payload);
        for (let i = 0; i < this.channels.length; i++) {
          const channel = this.channels[i];
          if (!channel.isMember(topic, event, payload, join_ref)) {
            continue;
          }
          channel.trigger(event, payload, ref, join_ref);
        }
        for (let i = 0; i < this.stateChangeCallbacks.message.length; i++) {
          let [, callback] = this.stateChangeCallbacks.message[i];
          callback(msg);
        }
      });
    }
    leaveOpenTopic(topic) {
      let dupChannel = this.channels.find((c) => c.topic === topic && (c.isJoined() || c.isJoining()));
      if (dupChannel) {
        if (this.hasLogger())
          this.log("transport", `leaving duplicate topic "${topic}"`);
        dupChannel.leave();
      }
    }
  };

  // ../deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js
  var CONSECUTIVE_RELOADS = "consecutive-reloads";
  var MAX_RELOADS = 10;
  var RELOAD_JITTER_MIN = 5e3;
  var RELOAD_JITTER_MAX = 1e4;
  var FAILSAFE_JITTER = 3e4;
  var PHX_EVENT_CLASSES = [
    "phx-click-loading",
    "phx-change-loading",
    "phx-submit-loading",
    "phx-keydown-loading",
    "phx-keyup-loading",
    "phx-blur-loading",
    "phx-focus-loading",
    "phx-hook-loading"
  ];
  var PHX_COMPONENT = "data-phx-component";
  var PHX_VIEW_REF = "data-phx-view";
  var PHX_LIVE_LINK = "data-phx-link";
  var PHX_TRACK_STATIC = "track-static";
  var PHX_LINK_STATE = "data-phx-link-state";
  var PHX_REF_LOADING = "data-phx-ref-loading";
  var PHX_REF_SRC = "data-phx-ref-src";
  var PHX_REF_LOCK = "data-phx-ref-lock";
  var PHX_PENDING_REFS = "phx-pending-refs";
  var PHX_TRACK_UPLOADS = "track-uploads";
  var PHX_UPLOAD_REF = "data-phx-upload-ref";
  var PHX_PREFLIGHTED_REFS = "data-phx-preflighted-refs";
  var PHX_DONE_REFS = "data-phx-done-refs";
  var PHX_DROP_TARGET = "drop-target";
  var PHX_ACTIVE_ENTRY_REFS = "data-phx-active-refs";
  var PHX_LIVE_FILE_UPDATED = "phx:live-file:updated";
  var PHX_SKIP = "data-phx-skip";
  var PHX_MAGIC_ID = "data-phx-id";
  var PHX_PRUNE = "data-phx-prune";
  var PHX_CONNECTED_CLASS = "phx-connected";
  var PHX_LOADING_CLASS = "phx-loading";
  var PHX_ERROR_CLASS = "phx-error";
  var PHX_CLIENT_ERROR_CLASS = "phx-client-error";
  var PHX_SERVER_ERROR_CLASS = "phx-server-error";
  var PHX_PARENT_ID = "data-phx-parent-id";
  var PHX_MAIN = "data-phx-main";
  var PHX_ROOT_ID = "data-phx-root-id";
  var PHX_VIEWPORT_TOP = "viewport-top";
  var PHX_VIEWPORT_BOTTOM = "viewport-bottom";
  var PHX_TRIGGER_ACTION = "trigger-action";
  var PHX_HAS_FOCUSED = "phx-has-focused";
  var FOCUSABLE_INPUTS = [
    "text",
    "textarea",
    "number",
    "email",
    "password",
    "search",
    "tel",
    "url",
    "date",
    "time",
    "datetime-local",
    "color",
    "range"
  ];
  var CHECKABLE_INPUTS = ["checkbox", "radio"];
  var PHX_HAS_SUBMITTED = "phx-has-submitted";
  var PHX_SESSION = "data-phx-session";
  var PHX_VIEW_SELECTOR = `[${PHX_SESSION}]`;
  var PHX_STICKY = "data-phx-sticky";
  var PHX_STATIC = "data-phx-static";
  var PHX_READONLY = "data-phx-readonly";
  var PHX_DISABLED = "data-phx-disabled";
  var PHX_DISABLE_WITH = "disable-with";
  var PHX_DISABLE_WITH_RESTORE = "data-phx-disable-with-restore";
  var PHX_HOOK = "hook";
  var PHX_DEBOUNCE = "debounce";
  var PHX_THROTTLE = "throttle";
  var PHX_UPDATE = "update";
  var PHX_STREAM = "stream";
  var PHX_STREAM_REF = "data-phx-stream";
  var PHX_PORTAL = "data-phx-portal";
  var PHX_TELEPORTED_REF = "data-phx-teleported";
  var PHX_TELEPORTED_SRC = "data-phx-teleported-src";
  var PHX_RUNTIME_HOOK = "data-phx-runtime-hook";
  var PHX_LV_PID = "data-phx-pid";
  var PHX_KEY = "key";
  var PHX_PRIVATE = "phxPrivate";
  var PHX_AUTO_RECOVER = "auto-recover";
  var PHX_LV_DEBUG = "phx:live-socket:debug";
  var PHX_LV_PROFILE = "phx:live-socket:profiling";
  var PHX_LV_LATENCY_SIM = "phx:live-socket:latency-sim";
  var PHX_LV_HISTORY_POSITION = "phx:nav-history-position";
  var PHX_PROGRESS = "progress";
  var PHX_MOUNTED = "mounted";
  var PHX_RELOAD_STATUS = "__phoenix_reload_status__";
  var LOADER_TIMEOUT = 1;
  var MAX_CHILD_JOIN_ATTEMPTS = 3;
  var BEFORE_UNLOAD_LOADER_TIMEOUT = 200;
  var DISCONNECTED_TIMEOUT = 500;
  var BINDING_PREFIX = "phx-";
  var PUSH_TIMEOUT = 3e4;
  var DEBOUNCE_TRIGGER = "debounce-trigger";
  var THROTTLED = "throttled";
  var DEBOUNCE_PREV_KEY = "debounce-prev-key";
  var DEFAULTS = {
    debounce: 300,
    throttle: 300
  };
  var PHX_PENDING_ATTRS = [PHX_REF_LOADING, PHX_REF_SRC, PHX_REF_LOCK];
  var STATIC = "s";
  var ROOT = "r";
  var COMPONENTS = "c";
  var KEYED = "k";
  var KEYED_COUNT = "kc";
  var EVENTS = "e";
  var REPLY = "r";
  var TITLE = "t";
  var TEMPLATES = "p";
  var STREAM = "stream";
  var EntryUploader = class {
    constructor(entry, config, liveSocket2) {
      const { chunk_size, chunk_timeout } = config;
      this.liveSocket = liveSocket2;
      this.entry = entry;
      this.offset = 0;
      this.chunkSize = chunk_size;
      this.chunkTimeout = chunk_timeout;
      this.chunkTimer = null;
      this.errored = false;
      this.uploadChannel = liveSocket2.channel(`lvu:${entry.ref}`, {
        token: entry.metadata()
      });
    }
    error(reason) {
      if (this.errored) {
        return;
      }
      this.uploadChannel.leave();
      this.errored = true;
      clearTimeout(this.chunkTimer);
      this.entry.error(reason);
    }
    upload() {
      this.uploadChannel.onError((reason) => this.error(reason));
      this.uploadChannel.join().receive("ok", (_data) => this.readNextChunk()).receive("error", (reason) => this.error(reason));
    }
    isDone() {
      return this.offset >= this.entry.file.size;
    }
    readNextChunk() {
      const reader = new window.FileReader();
      const blob = this.entry.file.slice(
        this.offset,
        this.chunkSize + this.offset
      );
      reader.onload = (e) => {
        if (e.target.error === null) {
          this.offset += /** @type {ArrayBuffer} */
          e.target.result.byteLength;
          this.pushChunk(
            /** @type {ArrayBuffer} */
            e.target.result
          );
        } else {
          return logError("Read error: " + e.target.error);
        }
      };
      reader.readAsArrayBuffer(blob);
    }
    pushChunk(chunk) {
      if (!this.uploadChannel.isJoined()) {
        return;
      }
      this.uploadChannel.push("chunk", chunk, this.chunkTimeout).receive("ok", () => {
        this.entry.progress(this.offset / this.entry.file.size * 100);
        if (!this.isDone()) {
          this.chunkTimer = setTimeout(
            () => this.readNextChunk(),
            this.liveSocket.getLatencySim() || 0
          );
        }
      }).receive("error", ({ reason }) => this.error(reason));
    }
  };
  var logError = (msg, obj) => console.error && console.error(msg, obj);
  var isCid = (cid) => {
    const type = typeof cid;
    return type === "number" || type === "string" && /^(0|[1-9]\d*)$/.test(cid);
  };
  function detectDuplicateIds() {
    const ids = /* @__PURE__ */ new Set();
    const elems = document.querySelectorAll("*[id]");
    for (let i = 0, len = elems.length; i < len; i++) {
      if (ids.has(elems[i].id)) {
        console.error(
          `Multiple IDs detected: ${elems[i].id}. Ensure unique element ids.`
        );
      } else {
        ids.add(elems[i].id);
      }
    }
  }
  function detectInvalidStreamInserts(inserts) {
    const errors = /* @__PURE__ */ new Set();
    Object.keys(inserts).forEach((id) => {
      const streamEl = document.getElementById(id);
      if (streamEl && streamEl.parentElement && streamEl.parentElement.getAttribute("phx-update") !== "stream") {
        errors.add(
          `The stream container with id "${streamEl.parentElement.id}" is missing the phx-update="stream" attribute. Ensure it is set for streams to work properly.`
        );
      }
    });
    errors.forEach((error) => console.error(error));
  }
  var debug = (view, kind, msg, obj) => {
    if (view.liveSocket.isDebugEnabled()) {
      console.log(`${view.id} ${kind}: ${msg} - `, obj);
    }
  };
  var closure2 = (val) => typeof val === "function" ? val : function() {
    return val;
  };
  var clone = (obj) => {
    return JSON.parse(JSON.stringify(obj));
  };
  var closestPhxBinding = (el, binding, borderEl) => {
    do {
      if (el.matches(`[${binding}]`) && !el.disabled) {
        return el;
      }
      el = el.parentElement || el.parentNode;
    } while (el !== null && el.nodeType === 1 && !(borderEl && borderEl.isSameNode(el) || el.matches(PHX_VIEW_SELECTOR)));
    return null;
  };
  var isObject = (obj) => {
    return obj !== null && typeof obj === "object" && !(obj instanceof Array);
  };
  var isEqualObj = (obj1, obj2) => JSON.stringify(obj1) === JSON.stringify(obj2);
  var isEmpty = (obj) => {
    for (const x in obj) {
      return false;
    }
    return true;
  };
  var maybe = (el, callback) => el && callback(el);
  var channelUploader = function(entries, onError, resp, liveSocket2) {
    entries.forEach((entry) => {
      const entryUploader = new EntryUploader(entry, resp.config, liveSocket2);
      entryUploader.upload();
    });
  };
  var Browser = {
    canPushState() {
      return typeof history.pushState !== "undefined";
    },
    dropLocal(localStorage, namespace, subkey) {
      return localStorage.removeItem(this.localKey(namespace, subkey));
    },
    updateLocal(localStorage, namespace, subkey, initial, func) {
      const current = this.getLocal(localStorage, namespace, subkey);
      const key = this.localKey(namespace, subkey);
      const newVal = current === null ? initial : func(current);
      localStorage.setItem(key, JSON.stringify(newVal));
      return newVal;
    },
    getLocal(localStorage, namespace, subkey) {
      return JSON.parse(localStorage.getItem(this.localKey(namespace, subkey)));
    },
    updateCurrentState(callback) {
      if (!this.canPushState()) {
        return;
      }
      history.replaceState(
        callback(history.state || {}),
        "",
        window.location.href
      );
    },
    pushState(kind, meta, to) {
      if (this.canPushState()) {
        if (to !== window.location.href) {
          if (meta.type == "redirect" && meta.scroll) {
            const currentState = history.state || {};
            currentState.scroll = meta.scroll;
            history.replaceState(currentState, "", window.location.href);
          }
          delete meta.scroll;
          history[kind + "State"](meta, "", to || null);
          window.requestAnimationFrame(() => {
            const hashEl = this.getHashTargetEl(window.location.hash);
            if (hashEl) {
              hashEl.scrollIntoView();
            } else if (meta.type === "redirect") {
              window.scroll(0, 0);
            }
          });
        }
      } else {
        this.redirect(to);
      }
    },
    setCookie(name, value, maxAgeSeconds) {
      const expires = typeof maxAgeSeconds === "number" ? ` max-age=${maxAgeSeconds};` : "";
      document.cookie = `${name}=${value};${expires} path=/`;
    },
    getCookie(name) {
      return document.cookie.replace(
        new RegExp(`(?:(?:^|.*;s*)${name}s*=s*([^;]*).*$)|^.*$`),
        "$1"
      );
    },
    deleteCookie(name) {
      document.cookie = `${name}=; max-age=-1; path=/`;
    },
    redirect(toURL, flash, navigate = (url) => {
      window.location.href = url;
    }) {
      if (flash) {
        this.setCookie("__phoenix_flash__", flash, 60);
      }
      navigate(toURL);
    },
    localKey(namespace, subkey) {
      return `${namespace}-${subkey}`;
    },
    getHashTargetEl(maybeHash) {
      const hash = maybeHash.toString().substring(1);
      if (hash === "") {
        return;
      }
      return document.getElementById(hash) || document.querySelector(`a[name="${hash}"]`);
    }
  };
  var browser_default = Browser;
  var DOM = {
    byId(id) {
      return document.getElementById(id) || logError(`no id found for ${id}`);
    },
    removeClass(el, className) {
      el.classList.remove(className);
      if (el.classList.length === 0) {
        el.removeAttribute("class");
      }
    },
    all(node, query, callback) {
      if (!node) {
        return [];
      }
      const array = Array.from(node.querySelectorAll(query));
      if (callback) {
        array.forEach(callback);
      }
      return array;
    },
    childNodeLength(html) {
      const template = document.createElement("template");
      template.innerHTML = html;
      return template.content.childElementCount;
    },
    isUploadInput(el) {
      return el.type === "file" && el.getAttribute(PHX_UPLOAD_REF) !== null;
    },
    isAutoUpload(inputEl) {
      return inputEl.hasAttribute("data-phx-auto-upload");
    },
    findUploadInputs(node) {
      const formId = node.id;
      const inputsOutsideForm = this.all(
        document,
        `input[type="file"][${PHX_UPLOAD_REF}][form="${formId}"]`
      );
      return this.all(node, `input[type="file"][${PHX_UPLOAD_REF}]`).concat(
        inputsOutsideForm
      );
    },
    findComponentNodeList(viewId, cid, doc2 = document) {
      return this.all(
        doc2,
        `[${PHX_VIEW_REF}="${viewId}"][${PHX_COMPONENT}="${cid}"]`
      );
    },
    isPhxDestroyed(node) {
      return node.id && DOM.private(node, "destroyed") ? true : false;
    },
    wantsNewTab(e) {
      const wantsNewTab = e.ctrlKey || e.shiftKey || e.metaKey || e.button && e.button === 1;
      const isDownload = e.target instanceof HTMLAnchorElement && e.target.hasAttribute("download");
      const isTargetBlank = e.target.hasAttribute("target") && e.target.getAttribute("target").toLowerCase() === "_blank";
      const isTargetNamedTab = e.target.hasAttribute("target") && !e.target.getAttribute("target").startsWith("_");
      return wantsNewTab || isTargetBlank || isDownload || isTargetNamedTab;
    },
    isUnloadableFormSubmit(e) {
      const isDialogSubmit = e.target && e.target.getAttribute("method") === "dialog" || e.submitter && e.submitter.getAttribute("formmethod") === "dialog";
      if (isDialogSubmit) {
        return false;
      } else {
        return !e.defaultPrevented && !this.wantsNewTab(e);
      }
    },
    isNewPageClick(e, currentLocation) {
      const href = e.target instanceof HTMLAnchorElement ? e.target.getAttribute("href") : null;
      let url;
      if (e.defaultPrevented || href === null || this.wantsNewTab(e)) {
        return false;
      }
      if (href.startsWith("mailto:") || href.startsWith("tel:")) {
        return false;
      }
      if (e.target.isContentEditable) {
        return false;
      }
      try {
        url = new URL(href);
      } catch (e2) {
        try {
          url = new URL(href, currentLocation);
        } catch (e3) {
          return true;
        }
      }
      if (url.host === currentLocation.host && url.protocol === currentLocation.protocol) {
        if (url.pathname === currentLocation.pathname && url.search === currentLocation.search) {
          return url.hash === "" && !url.href.endsWith("#");
        }
      }
      return url.protocol.startsWith("http");
    },
    markPhxChildDestroyed(el) {
      if (this.isPhxChild(el)) {
        el.setAttribute(PHX_SESSION, "");
      }
      this.putPrivate(el, "destroyed", true);
    },
    findPhxChildrenInFragment(html, parentId) {
      const template = document.createElement("template");
      template.innerHTML = html;
      return this.findPhxChildren(template.content, parentId);
    },
    isIgnored(el, phxUpdate) {
      return (el.getAttribute(phxUpdate) || el.getAttribute("data-phx-update")) === "ignore";
    },
    isPhxUpdate(el, phxUpdate, updateTypes) {
      return el.getAttribute && updateTypes.indexOf(el.getAttribute(phxUpdate)) >= 0;
    },
    findPhxSticky(el) {
      return this.all(el, `[${PHX_STICKY}]`);
    },
    findPhxChildren(el, parentId) {
      return this.all(el, `${PHX_VIEW_SELECTOR}[${PHX_PARENT_ID}="${parentId}"]`);
    },
    findExistingParentCIDs(viewId, cids) {
      const parentCids = /* @__PURE__ */ new Set();
      const childrenCids = /* @__PURE__ */ new Set();
      cids.forEach((cid) => {
        this.all(
          document,
          `[${PHX_VIEW_REF}="${viewId}"][${PHX_COMPONENT}="${cid}"]`
        ).forEach((parent) => {
          parentCids.add(cid);
          this.all(parent, `[${PHX_VIEW_REF}="${viewId}"][${PHX_COMPONENT}]`).map((el) => parseInt(el.getAttribute(PHX_COMPONENT))).forEach((childCID) => childrenCids.add(childCID));
        });
      });
      childrenCids.forEach((childCid) => parentCids.delete(childCid));
      return parentCids;
    },
    private(el, key) {
      return el[PHX_PRIVATE] && el[PHX_PRIVATE][key];
    },
    deletePrivate(el, key) {
      el[PHX_PRIVATE] && delete el[PHX_PRIVATE][key];
    },
    putPrivate(el, key, value) {
      if (!el[PHX_PRIVATE]) {
        el[PHX_PRIVATE] = {};
      }
      el[PHX_PRIVATE][key] = value;
    },
    updatePrivate(el, key, defaultVal, updateFunc) {
      const existing = this.private(el, key);
      if (existing === void 0) {
        this.putPrivate(el, key, updateFunc(defaultVal));
      } else {
        this.putPrivate(el, key, updateFunc(existing));
      }
    },
    syncPendingAttrs(fromEl, toEl) {
      if (!fromEl.hasAttribute(PHX_REF_SRC)) {
        return;
      }
      PHX_EVENT_CLASSES.forEach((className) => {
        fromEl.classList.contains(className) && toEl.classList.add(className);
      });
      PHX_PENDING_ATTRS.filter((attr) => fromEl.hasAttribute(attr)).forEach(
        (attr) => {
          toEl.setAttribute(attr, fromEl.getAttribute(attr));
        }
      );
    },
    copyPrivates(target, source) {
      if (source[PHX_PRIVATE]) {
        target[PHX_PRIVATE] = source[PHX_PRIVATE];
      }
    },
    putTitle(str) {
      const titleEl = document.querySelector("title");
      if (titleEl) {
        const { prefix, suffix, default: defaultTitle } = titleEl.dataset;
        const isEmpty2 = typeof str !== "string" || str.trim() === "";
        if (isEmpty2 && typeof defaultTitle !== "string") {
          return;
        }
        const inner = isEmpty2 ? defaultTitle : str;
        document.title = `${prefix || ""}${inner || ""}${suffix || ""}`;
      } else {
        document.title = str;
      }
    },
    debounce(el, event, phxDebounce, defaultDebounce, phxThrottle, defaultThrottle, asyncFilter, callback) {
      let debounce = el.getAttribute(phxDebounce);
      let throttle = el.getAttribute(phxThrottle);
      if (debounce === "") {
        debounce = defaultDebounce;
      }
      if (throttle === "") {
        throttle = defaultThrottle;
      }
      const value = debounce || throttle;
      switch (value) {
        case null:
          return callback();
        case "blur":
          this.incCycle(el, "debounce-blur-cycle", () => {
            if (asyncFilter()) {
              callback();
            }
          });
          if (this.once(el, "debounce-blur")) {
            el.addEventListener(
              "blur",
              () => this.triggerCycle(el, "debounce-blur-cycle")
            );
          }
          return;
        default:
          const timeout = parseInt(value);
          const trigger = () => throttle ? this.deletePrivate(el, THROTTLED) : callback();
          const currentCycle = this.incCycle(el, DEBOUNCE_TRIGGER, trigger);
          if (isNaN(timeout)) {
            return logError(`invalid throttle/debounce value: ${value}`);
          }
          if (throttle) {
            let newKeyDown = false;
            if (event.type === "keydown") {
              const prevKey = this.private(el, DEBOUNCE_PREV_KEY);
              this.putPrivate(el, DEBOUNCE_PREV_KEY, event.key);
              newKeyDown = prevKey !== event.key;
            }
            if (!newKeyDown && this.private(el, THROTTLED)) {
              return false;
            } else {
              callback();
              const t = setTimeout(() => {
                if (asyncFilter()) {
                  this.triggerCycle(el, DEBOUNCE_TRIGGER);
                }
              }, timeout);
              this.putPrivate(el, THROTTLED, t);
            }
          } else {
            setTimeout(() => {
              if (asyncFilter()) {
                this.triggerCycle(el, DEBOUNCE_TRIGGER, currentCycle);
              }
            }, timeout);
          }
          const form = el.form;
          if (form && this.once(form, "bind-debounce")) {
            form.addEventListener("submit", () => {
              Array.from(new FormData(form).entries(), ([name]) => {
                const input = form.querySelector(`[name="${name}"]`);
                this.incCycle(input, DEBOUNCE_TRIGGER);
                this.deletePrivate(input, THROTTLED);
              });
            });
          }
          if (this.once(el, "bind-debounce")) {
            el.addEventListener("blur", () => {
              clearTimeout(this.private(el, THROTTLED));
              this.triggerCycle(el, DEBOUNCE_TRIGGER);
            });
          }
      }
    },
    triggerCycle(el, key, currentCycle) {
      const [cycle, trigger] = this.private(el, key);
      if (!currentCycle) {
        currentCycle = cycle;
      }
      if (currentCycle === cycle) {
        this.incCycle(el, key);
        trigger();
      }
    },
    once(el, key) {
      if (this.private(el, key) === true) {
        return false;
      }
      this.putPrivate(el, key, true);
      return true;
    },
    incCycle(el, key, trigger = function() {
    }) {
      let [currentCycle] = this.private(el, key) || [0, trigger];
      currentCycle++;
      this.putPrivate(el, key, [currentCycle, trigger]);
      return currentCycle;
    },
    // maintains or adds privately used hook information
    // fromEl and toEl can be the same element in the case of a newly added node
    // fromEl and toEl can be any HTML node type, so we need to check if it's an element node
    maintainPrivateHooks(fromEl, toEl, phxViewportTop, phxViewportBottom) {
      if (fromEl.hasAttribute && fromEl.hasAttribute("data-phx-hook") && !toEl.hasAttribute("data-phx-hook")) {
        toEl.setAttribute("data-phx-hook", fromEl.getAttribute("data-phx-hook"));
      }
      if (toEl.hasAttribute && (toEl.hasAttribute(phxViewportTop) || toEl.hasAttribute(phxViewportBottom))) {
        toEl.setAttribute("data-phx-hook", "Phoenix.InfiniteScroll");
      }
    },
    putCustomElHook(el, hook) {
      if (el.isConnected) {
        el.setAttribute("data-phx-hook", "");
      } else {
        console.error(`
        hook attached to non-connected DOM element
        ensure you are calling createHook within your connectedCallback. ${el.outerHTML}
      `);
      }
      this.putPrivate(el, "custom-el-hook", hook);
    },
    getCustomElHook(el) {
      return this.private(el, "custom-el-hook");
    },
    isUsedInput(el) {
      return el.nodeType === Node.ELEMENT_NODE && (this.private(el, PHX_HAS_FOCUSED) || this.private(el, PHX_HAS_SUBMITTED));
    },
    resetForm(form) {
      Array.from(form.elements).forEach((input) => {
        this.deletePrivate(input, PHX_HAS_FOCUSED);
        this.deletePrivate(input, PHX_HAS_SUBMITTED);
      });
    },
    isPhxChild(node) {
      return node.getAttribute && node.getAttribute(PHX_PARENT_ID);
    },
    isPhxSticky(node) {
      return node.getAttribute && node.getAttribute(PHX_STICKY) !== null;
    },
    isChildOfAny(el, parents) {
      return !!parents.find((parent) => parent.contains(el));
    },
    firstPhxChild(el) {
      return this.isPhxChild(el) ? el : this.all(el, `[${PHX_PARENT_ID}]`)[0];
    },
    isPortalTemplate(el) {
      return el.tagName === "TEMPLATE" && el.hasAttribute(PHX_PORTAL);
    },
    closestViewEl(el) {
      const portalOrViewEl = el.closest(
        `[${PHX_TELEPORTED_REF}],${PHX_VIEW_SELECTOR}`
      );
      if (!portalOrViewEl) {
        return null;
      }
      if (portalOrViewEl.hasAttribute(PHX_TELEPORTED_REF)) {
        return this.byId(portalOrViewEl.getAttribute(PHX_TELEPORTED_REF));
      } else if (portalOrViewEl.hasAttribute(PHX_SESSION)) {
        return portalOrViewEl;
      }
      return null;
    },
    dispatchEvent(target, name, opts = {}) {
      let defaultBubble = true;
      const isUploadTarget = target.nodeName === "INPUT" && target.type === "file";
      if (isUploadTarget && name === "click") {
        defaultBubble = false;
      }
      const bubbles = opts.bubbles === void 0 ? defaultBubble : !!opts.bubbles;
      const eventOpts = {
        bubbles,
        cancelable: true,
        detail: opts.detail || {}
      };
      const event = name === "click" ? new MouseEvent("click", eventOpts) : new CustomEvent(name, eventOpts);
      target.dispatchEvent(event);
    },
    cloneNode(node, html) {
      if (typeof html === "undefined") {
        return node.cloneNode(true);
      } else {
        const cloned = node.cloneNode(false);
        cloned.innerHTML = html;
        return cloned;
      }
    },
    // merge attributes from source to target
    // if an element is ignored, we only merge data attributes
    // including removing data attributes that are no longer in the source
    mergeAttrs(target, source, opts = {}) {
      const exclude = new Set(opts.exclude || []);
      const isIgnored = opts.isIgnored;
      const sourceAttrs = source.attributes;
      for (let i = sourceAttrs.length - 1; i >= 0; i--) {
        const name = sourceAttrs[i].name;
        if (!exclude.has(name)) {
          const sourceValue = source.getAttribute(name);
          if (target.getAttribute(name) !== sourceValue && (!isIgnored || isIgnored && name.startsWith("data-"))) {
            target.setAttribute(name, sourceValue);
          }
        } else {
          if (name === "value" && target.value === source.value) {
            target.setAttribute("value", source.getAttribute(name));
          }
        }
      }
      const targetAttrs = target.attributes;
      for (let i = targetAttrs.length - 1; i >= 0; i--) {
        const name = targetAttrs[i].name;
        if (isIgnored) {
          if (name.startsWith("data-") && !source.hasAttribute(name) && !PHX_PENDING_ATTRS.includes(name)) {
            target.removeAttribute(name);
          }
        } else {
          if (!source.hasAttribute(name)) {
            target.removeAttribute(name);
          }
        }
      }
    },
    mergeFocusedInput(target, source) {
      if (!(target instanceof HTMLSelectElement)) {
        DOM.mergeAttrs(target, source, { exclude: ["value"] });
      }
      if (source.readOnly) {
        target.setAttribute("readonly", true);
      } else {
        target.removeAttribute("readonly");
      }
    },
    hasSelectionRange(el) {
      return el.setSelectionRange && (el.type === "text" || el.type === "textarea");
    },
    restoreFocus(focused, selectionStart, selectionEnd) {
      if (focused instanceof HTMLSelectElement) {
        focused.focus();
      }
      if (!DOM.isTextualInput(focused)) {
        return;
      }
      const wasFocused = focused.matches(":focus");
      if (!wasFocused) {
        focused.focus();
      }
      if (this.hasSelectionRange(focused)) {
        focused.setSelectionRange(selectionStart, selectionEnd);
      }
    },
    isFormInput(el) {
      if (el.localName && customElements.get(el.localName)) {
        return customElements.get(el.localName)[`formAssociated`];
      }
      return /^(?:input|select|textarea)$/i.test(el.tagName) && el.type !== "button";
    },
    syncAttrsToProps(el) {
      if (el instanceof HTMLInputElement && CHECKABLE_INPUTS.indexOf(el.type.toLocaleLowerCase()) >= 0) {
        el.checked = el.getAttribute("checked") !== null;
      }
    },
    isTextualInput(el) {
      return FOCUSABLE_INPUTS.indexOf(el.type) >= 0;
    },
    isNowTriggerFormExternal(el, phxTriggerExternal) {
      return el.getAttribute && el.getAttribute(phxTriggerExternal) !== null && document.body.contains(el);
    },
    cleanChildNodes(container, phxUpdate) {
      if (DOM.isPhxUpdate(container, phxUpdate, ["append", "prepend", PHX_STREAM])) {
        const toRemove = [];
        container.childNodes.forEach((childNode) => {
          if (!childNode.id) {
            const isEmptyTextNode = childNode.nodeType === Node.TEXT_NODE && childNode.nodeValue.trim() === "";
            if (!isEmptyTextNode && childNode.nodeType !== Node.COMMENT_NODE) {
              logError(
                `only HTML element tags with an id are allowed inside containers with phx-update.

removing illegal node: "${(childNode.outerHTML || childNode.nodeValue).trim()}"

`
              );
            }
            toRemove.push(childNode);
          }
        });
        toRemove.forEach((childNode) => childNode.remove());
      }
    },
    replaceRootContainer(container, tagName, attrs) {
      const retainedAttrs = /* @__PURE__ */ new Set([
        "id",
        PHX_SESSION,
        PHX_STATIC,
        PHX_MAIN,
        PHX_ROOT_ID
      ]);
      if (container.tagName.toLowerCase() === tagName.toLowerCase()) {
        Array.from(container.attributes).filter((attr) => !retainedAttrs.has(attr.name.toLowerCase())).forEach((attr) => container.removeAttribute(attr.name));
        Object.keys(attrs).filter((name) => !retainedAttrs.has(name.toLowerCase())).forEach((attr) => container.setAttribute(attr, attrs[attr]));
        return container;
      } else {
        const newContainer = document.createElement(tagName);
        Object.keys(attrs).forEach(
          (attr) => newContainer.setAttribute(attr, attrs[attr])
        );
        retainedAttrs.forEach(
          (attr) => newContainer.setAttribute(attr, container.getAttribute(attr))
        );
        newContainer.innerHTML = container.innerHTML;
        container.replaceWith(newContainer);
        return newContainer;
      }
    },
    getSticky(el, name, defaultVal) {
      const op = (DOM.private(el, "sticky") || []).find(
        ([existingName]) => name === existingName
      );
      if (op) {
        const [_name, _op, stashedResult] = op;
        return stashedResult;
      } else {
        return typeof defaultVal === "function" ? defaultVal() : defaultVal;
      }
    },
    deleteSticky(el, name) {
      this.updatePrivate(el, "sticky", [], (ops) => {
        return ops.filter(([existingName, _]) => existingName !== name);
      });
    },
    putSticky(el, name, op) {
      const stashedResult = op(el);
      this.updatePrivate(el, "sticky", [], (ops) => {
        const existingIndex = ops.findIndex(
          ([existingName]) => name === existingName
        );
        if (existingIndex >= 0) {
          ops[existingIndex] = [name, op, stashedResult];
        } else {
          ops.push([name, op, stashedResult]);
        }
        return ops;
      });
    },
    applyStickyOperations(el) {
      const ops = DOM.private(el, "sticky");
      if (!ops) {
        return;
      }
      ops.forEach(([name, op, _stashed]) => this.putSticky(el, name, op));
    },
    isLocked(el) {
      return el.hasAttribute && el.hasAttribute(PHX_REF_LOCK);
    }
  };
  var dom_default = DOM;
  var UploadEntry = class {
    static isActive(fileEl, file) {
      const isNew = file._phxRef === void 0;
      const activeRefs = fileEl.getAttribute(PHX_ACTIVE_ENTRY_REFS).split(",");
      const isActive = activeRefs.indexOf(LiveUploader.genFileRef(file)) >= 0;
      return file.size > 0 && (isNew || isActive);
    }
    static isPreflighted(fileEl, file) {
      const preflightedRefs = fileEl.getAttribute(PHX_PREFLIGHTED_REFS).split(",");
      const isPreflighted = preflightedRefs.indexOf(LiveUploader.genFileRef(file)) >= 0;
      return isPreflighted && this.isActive(fileEl, file);
    }
    static isPreflightInProgress(file) {
      return file._preflightInProgress === true;
    }
    static markPreflightInProgress(file) {
      file._preflightInProgress = true;
    }
    constructor(fileEl, file, view, autoUpload) {
      this.ref = LiveUploader.genFileRef(file);
      this.fileEl = fileEl;
      this.file = file;
      this.view = view;
      this.meta = null;
      this._isCancelled = false;
      this._isDone = false;
      this._progress = 0;
      this._lastProgressSent = -1;
      this._onDone = function() {
      };
      this._onElUpdated = this.onElUpdated.bind(this);
      this.fileEl.addEventListener(PHX_LIVE_FILE_UPDATED, this._onElUpdated);
      this.autoUpload = autoUpload;
    }
    metadata() {
      return this.meta;
    }
    progress(progress) {
      this._progress = Math.floor(progress);
      if (this._progress > this._lastProgressSent) {
        if (this._progress >= 100) {
          this._progress = 100;
          this._lastProgressSent = 100;
          this._isDone = true;
          this.view.pushFileProgress(this.fileEl, this.ref, 100, () => {
            LiveUploader.untrackFile(this.fileEl, this.file);
            this._onDone();
          });
        } else {
          this._lastProgressSent = this._progress;
          this.view.pushFileProgress(this.fileEl, this.ref, this._progress);
        }
      }
    }
    isCancelled() {
      return this._isCancelled;
    }
    cancel() {
      this.file._preflightInProgress = false;
      this._isCancelled = true;
      this._isDone = true;
      this._onDone();
    }
    isDone() {
      return this._isDone;
    }
    error(reason = "failed") {
      this.fileEl.removeEventListener(PHX_LIVE_FILE_UPDATED, this._onElUpdated);
      this.view.pushFileProgress(this.fileEl, this.ref, { error: reason });
      if (!this.isAutoUpload()) {
        LiveUploader.clearFiles(this.fileEl);
      }
    }
    isAutoUpload() {
      return this.autoUpload;
    }
    //private
    onDone(callback) {
      this._onDone = () => {
        this.fileEl.removeEventListener(PHX_LIVE_FILE_UPDATED, this._onElUpdated);
        callback();
      };
    }
    onElUpdated() {
      const activeRefs = this.fileEl.getAttribute(PHX_ACTIVE_ENTRY_REFS).split(",");
      if (activeRefs.indexOf(this.ref) === -1) {
        LiveUploader.untrackFile(this.fileEl, this.file);
        this.cancel();
      }
    }
    toPreflightPayload() {
      return {
        last_modified: this.file.lastModified,
        name: this.file.name,
        relative_path: this.file.webkitRelativePath,
        size: this.file.size,
        type: this.file.type,
        ref: this.ref,
        meta: typeof this.file.meta === "function" ? this.file.meta() : void 0
      };
    }
    uploader(uploaders) {
      if (this.meta.uploader) {
        const callback = uploaders[this.meta.uploader] || logError(`no uploader configured for ${this.meta.uploader}`);
        return { name: this.meta.uploader, callback };
      } else {
        return { name: "channel", callback: channelUploader };
      }
    }
    zipPostFlight(resp) {
      this.meta = resp.entries[this.ref];
      if (!this.meta) {
        logError(`no preflight upload response returned with ref ${this.ref}`, {
          input: this.fileEl,
          response: resp
        });
      }
    }
  };
  var liveUploaderFileRef = 0;
  var LiveUploader = class _LiveUploader {
    static genFileRef(file) {
      const ref = file._phxRef;
      if (ref !== void 0) {
        return ref;
      } else {
        file._phxRef = (liveUploaderFileRef++).toString();
        return file._phxRef;
      }
    }
    static getEntryDataURL(inputEl, ref, callback) {
      const file = this.activeFiles(inputEl).find(
        (file2) => this.genFileRef(file2) === ref
      );
      callback(URL.createObjectURL(file));
    }
    static hasUploadsInProgress(formEl) {
      let active = 0;
      dom_default.findUploadInputs(formEl).forEach((input) => {
        if (input.getAttribute(PHX_PREFLIGHTED_REFS) !== input.getAttribute(PHX_DONE_REFS)) {
          active++;
        }
      });
      return active > 0;
    }
    static serializeUploads(inputEl) {
      const files = this.activeFiles(inputEl);
      const fileData = {};
      files.forEach((file) => {
        const entry = { path: inputEl.name };
        const uploadRef = inputEl.getAttribute(PHX_UPLOAD_REF);
        fileData[uploadRef] = fileData[uploadRef] || [];
        entry.ref = this.genFileRef(file);
        entry.last_modified = file.lastModified;
        entry.name = file.name || entry.ref;
        entry.relative_path = file.webkitRelativePath;
        entry.type = file.type;
        entry.size = file.size;
        if (typeof file.meta === "function") {
          entry.meta = file.meta();
        }
        fileData[uploadRef].push(entry);
      });
      return fileData;
    }
    static clearFiles(inputEl) {
      inputEl.value = null;
      inputEl.removeAttribute(PHX_UPLOAD_REF);
      dom_default.putPrivate(inputEl, "files", []);
    }
    static untrackFile(inputEl, file) {
      dom_default.putPrivate(
        inputEl,
        "files",
        dom_default.private(inputEl, "files").filter((f) => !Object.is(f, file))
      );
    }
    /**
     * @param {HTMLInputElement} inputEl
     * @param {Array<File|Blob>} files
     * @param {DataTransfer} [dataTransfer]
     */
    static trackFiles(inputEl, files, dataTransfer) {
      if (inputEl.getAttribute("multiple") !== null) {
        const newFiles = files.filter(
          (file) => !this.activeFiles(inputEl).find((f) => Object.is(f, file))
        );
        dom_default.updatePrivate(
          inputEl,
          "files",
          [],
          (existing) => existing.concat(newFiles)
        );
        inputEl.value = null;
      } else {
        if (dataTransfer && dataTransfer.files.length > 0) {
          inputEl.files = dataTransfer.files;
        }
        dom_default.putPrivate(inputEl, "files", files);
      }
    }
    static activeFileInputs(formEl) {
      const fileInputs = dom_default.findUploadInputs(formEl);
      return Array.from(fileInputs).filter(
        (el) => el.files && this.activeFiles(el).length > 0
      );
    }
    static activeFiles(input) {
      return (dom_default.private(input, "files") || []).filter(
        (f) => UploadEntry.isActive(input, f)
      );
    }
    static inputsAwaitingPreflight(formEl) {
      const fileInputs = dom_default.findUploadInputs(formEl);
      return Array.from(fileInputs).filter(
        (input) => this.filesAwaitingPreflight(input).length > 0
      );
    }
    static filesAwaitingPreflight(input) {
      return this.activeFiles(input).filter(
        (f) => !UploadEntry.isPreflighted(input, f) && !UploadEntry.isPreflightInProgress(f)
      );
    }
    static markPreflightInProgress(entries) {
      entries.forEach((entry) => UploadEntry.markPreflightInProgress(entry.file));
    }
    constructor(inputEl, view, onComplete) {
      this.autoUpload = dom_default.isAutoUpload(inputEl);
      this.view = view;
      this.onComplete = onComplete;
      this._entries = Array.from(
        _LiveUploader.filesAwaitingPreflight(inputEl) || []
      ).map((file) => new UploadEntry(inputEl, file, view, this.autoUpload));
      _LiveUploader.markPreflightInProgress(this._entries);
      this.numEntriesInProgress = this._entries.length;
    }
    isAutoUpload() {
      return this.autoUpload;
    }
    entries() {
      return this._entries;
    }
    initAdapterUpload(resp, onError, liveSocket2) {
      this._entries = this._entries.map((entry) => {
        if (entry.isCancelled()) {
          this.numEntriesInProgress--;
          if (this.numEntriesInProgress === 0) {
            this.onComplete();
          }
        } else {
          entry.zipPostFlight(resp);
          entry.onDone(() => {
            this.numEntriesInProgress--;
            if (this.numEntriesInProgress === 0) {
              this.onComplete();
            }
          });
        }
        return entry;
      });
      const groupedEntries = this._entries.reduce((acc, entry) => {
        if (!entry.meta) {
          return acc;
        }
        const { name, callback } = entry.uploader(liveSocket2.uploaders);
        acc[name] = acc[name] || { callback, entries: [] };
        acc[name].entries.push(entry);
        return acc;
      }, {});
      for (const name in groupedEntries) {
        const { callback, entries } = groupedEntries[name];
        callback(entries, onError, resp, liveSocket2);
      }
    }
  };
  var ARIA = {
    anyOf(instance, classes) {
      return classes.find((name) => instance instanceof name);
    },
    isFocusable(el, interactiveOnly) {
      return el instanceof HTMLAnchorElement && el.rel !== "ignore" || el instanceof HTMLAreaElement && el.href !== void 0 || !el.disabled && this.anyOf(el, [
        HTMLInputElement,
        HTMLSelectElement,
        HTMLTextAreaElement,
        HTMLButtonElement
      ]) || el instanceof HTMLIFrameElement || el.tabIndex >= 0 && el.getAttribute("aria-hidden") !== "true" || !interactiveOnly && el.getAttribute("tabindex") !== null && el.getAttribute("aria-hidden") !== "true";
    },
    attemptFocus(el, interactiveOnly) {
      if (this.isFocusable(el, interactiveOnly)) {
        try {
          el.focus();
        } catch (e) {
        }
      }
      return !!document.activeElement && document.activeElement.isSameNode(el);
    },
    focusFirstInteractive(el) {
      let child = el.firstElementChild;
      while (child) {
        if (this.attemptFocus(child, true) || this.focusFirstInteractive(child)) {
          return true;
        }
        child = child.nextElementSibling;
      }
    },
    focusFirst(el) {
      let child = el.firstElementChild;
      while (child) {
        if (this.attemptFocus(child) || this.focusFirst(child)) {
          return true;
        }
        child = child.nextElementSibling;
      }
    },
    focusLast(el) {
      let child = el.lastElementChild;
      while (child) {
        if (this.attemptFocus(child) || this.focusLast(child)) {
          return true;
        }
        child = child.previousElementSibling;
      }
    }
  };
  var aria_default = ARIA;
  var Hooks = {
    LiveFileUpload: {
      activeRefs() {
        return this.el.getAttribute(PHX_ACTIVE_ENTRY_REFS);
      },
      preflightedRefs() {
        return this.el.getAttribute(PHX_PREFLIGHTED_REFS);
      },
      mounted() {
        this.preflightedWas = this.preflightedRefs();
      },
      updated() {
        const newPreflights = this.preflightedRefs();
        if (this.preflightedWas !== newPreflights) {
          this.preflightedWas = newPreflights;
          if (newPreflights === "") {
            this.__view().cancelSubmit(this.el.form);
          }
        }
        if (this.activeRefs() === "") {
          this.el.value = null;
        }
        this.el.dispatchEvent(new CustomEvent(PHX_LIVE_FILE_UPDATED));
      }
    },
    LiveImgPreview: {
      mounted() {
        this.ref = this.el.getAttribute("data-phx-entry-ref");
        this.inputEl = document.getElementById(
          this.el.getAttribute(PHX_UPLOAD_REF)
        );
        LiveUploader.getEntryDataURL(this.inputEl, this.ref, (url) => {
          this.url = url;
          this.el.src = url;
        });
      },
      destroyed() {
        URL.revokeObjectURL(this.url);
      }
    },
    FocusWrap: {
      mounted() {
        this.focusStart = this.el.firstElementChild;
        this.focusEnd = this.el.lastElementChild;
        this.focusStart.addEventListener("focus", (e) => {
          if (!e.relatedTarget || !this.el.contains(e.relatedTarget)) {
            const nextFocus = e.target.nextElementSibling;
            aria_default.attemptFocus(nextFocus) || aria_default.focusFirst(nextFocus);
          } else {
            aria_default.focusLast(this.el);
          }
        });
        this.focusEnd.addEventListener("focus", (e) => {
          if (!e.relatedTarget || !this.el.contains(e.relatedTarget)) {
            const nextFocus = e.target.previousElementSibling;
            aria_default.attemptFocus(nextFocus) || aria_default.focusLast(nextFocus);
          } else {
            aria_default.focusFirst(this.el);
          }
        });
        if (!this.el.contains(document.activeElement)) {
          this.el.addEventListener("phx:show-end", () => this.el.focus());
          if (window.getComputedStyle(this.el).display !== "none") {
            aria_default.focusFirst(this.el);
          }
        }
      }
    }
  };
  var findScrollContainer = (el) => {
    if (["HTML", "BODY"].indexOf(el.nodeName.toUpperCase()) >= 0)
      return null;
    if (["scroll", "auto"].indexOf(getComputedStyle(el).overflowY) >= 0)
      return el;
    return findScrollContainer(el.parentElement);
  };
  var scrollTop = (scrollContainer) => {
    if (scrollContainer) {
      return scrollContainer.scrollTop;
    } else {
      return document.documentElement.scrollTop || document.body.scrollTop;
    }
  };
  var bottom = (scrollContainer) => {
    if (scrollContainer) {
      return scrollContainer.getBoundingClientRect().bottom;
    } else {
      return window.innerHeight || document.documentElement.clientHeight;
    }
  };
  var top = (scrollContainer) => {
    if (scrollContainer) {
      return scrollContainer.getBoundingClientRect().top;
    } else {
      return 0;
    }
  };
  var isAtViewportTop = (el, scrollContainer) => {
    const rect = el.getBoundingClientRect();
    return Math.ceil(rect.top) >= top(scrollContainer) && Math.ceil(rect.left) >= 0 && Math.floor(rect.top) <= bottom(scrollContainer);
  };
  var isAtViewportBottom = (el, scrollContainer) => {
    const rect = el.getBoundingClientRect();
    return Math.ceil(rect.bottom) >= top(scrollContainer) && Math.ceil(rect.left) >= 0 && Math.floor(rect.bottom) <= bottom(scrollContainer);
  };
  var isWithinViewport = (el, scrollContainer) => {
    const rect = el.getBoundingClientRect();
    return Math.ceil(rect.top) >= top(scrollContainer) && Math.ceil(rect.left) >= 0 && Math.floor(rect.top) <= bottom(scrollContainer);
  };
  Hooks.InfiniteScroll = {
    mounted() {
      this.scrollContainer = findScrollContainer(this.el);
      let scrollBefore = scrollTop(this.scrollContainer);
      let topOverran = false;
      const throttleInterval = 500;
      let pendingOp = null;
      const onTopOverrun = this.throttle(
        throttleInterval,
        (topEvent, firstChild) => {
          pendingOp = () => true;
          this.liveSocket.js().push(this.el, topEvent, {
            value: { id: firstChild.id, _overran: true },
            callback: () => {
              pendingOp = null;
            }
          });
        }
      );
      const onFirstChildAtTop = this.throttle(
        throttleInterval,
        (topEvent, firstChild) => {
          pendingOp = () => firstChild.scrollIntoView({ block: "start" });
          this.liveSocket.js().push(this.el, topEvent, {
            value: { id: firstChild.id },
            callback: () => {
              pendingOp = null;
              window.requestAnimationFrame(() => {
                if (!isWithinViewport(firstChild, this.scrollContainer)) {
                  firstChild.scrollIntoView({ block: "start" });
                }
              });
            }
          });
        }
      );
      const onLastChildAtBottom = this.throttle(
        throttleInterval,
        (bottomEvent, lastChild) => {
          pendingOp = () => lastChild.scrollIntoView({ block: "end" });
          this.liveSocket.js().push(this.el, bottomEvent, {
            value: { id: lastChild.id },
            callback: () => {
              pendingOp = null;
              window.requestAnimationFrame(() => {
                if (!isWithinViewport(lastChild, this.scrollContainer)) {
                  lastChild.scrollIntoView({ block: "end" });
                }
              });
            }
          });
        }
      );
      this.onScroll = (_e) => {
        const scrollNow = scrollTop(this.scrollContainer);
        if (pendingOp) {
          scrollBefore = scrollNow;
          return pendingOp();
        }
        const rect = this.el.getBoundingClientRect();
        const topEvent = this.el.getAttribute(
          this.liveSocket.binding("viewport-top")
        );
        const bottomEvent = this.el.getAttribute(
          this.liveSocket.binding("viewport-bottom")
        );
        const lastChild = this.el.lastElementChild;
        const firstChild = this.el.firstElementChild;
        const isScrollingUp = scrollNow < scrollBefore;
        const isScrollingDown = scrollNow > scrollBefore;
        if (isScrollingUp && topEvent && !topOverran && rect.top >= 0) {
          topOverran = true;
          onTopOverrun(topEvent, firstChild);
        } else if (isScrollingDown && topOverran && rect.top <= 0) {
          topOverran = false;
        }
        if (topEvent && isScrollingUp && isAtViewportTop(firstChild, this.scrollContainer)) {
          onFirstChildAtTop(topEvent, firstChild);
        } else if (bottomEvent && isScrollingDown && isAtViewportBottom(lastChild, this.scrollContainer)) {
          onLastChildAtBottom(bottomEvent, lastChild);
        }
        scrollBefore = scrollNow;
      };
      if (this.scrollContainer) {
        this.scrollContainer.addEventListener("scroll", this.onScroll);
      } else {
        window.addEventListener("scroll", this.onScroll);
      }
    },
    destroyed() {
      if (this.scrollContainer) {
        this.scrollContainer.removeEventListener("scroll", this.onScroll);
      } else {
        window.removeEventListener("scroll", this.onScroll);
      }
    },
    throttle(interval, callback) {
      let lastCallAt = 0;
      let timer;
      return (...args) => {
        const now = Date.now();
        const remainingTime = interval - (now - lastCallAt);
        if (remainingTime <= 0 || remainingTime > interval) {
          if (timer) {
            clearTimeout(timer);
            timer = null;
          }
          lastCallAt = now;
          callback(...args);
        } else if (!timer) {
          timer = setTimeout(() => {
            lastCallAt = Date.now();
            timer = null;
            callback(...args);
          }, remainingTime);
        }
      };
    }
  };
  var hooks_default = Hooks;
  var ElementRef = class {
    static onUnlock(el, callback) {
      if (!dom_default.isLocked(el) && !el.closest(`[${PHX_REF_LOCK}]`)) {
        return callback();
      }
      const closestLock = el.closest(`[${PHX_REF_LOCK}]`);
      const ref = closestLock.closest(`[${PHX_REF_LOCK}]`).getAttribute(PHX_REF_LOCK);
      closestLock.addEventListener(
        `phx:undo-lock:${ref}`,
        () => {
          callback();
        },
        { once: true }
      );
    }
    constructor(el) {
      this.el = el;
      this.loadingRef = el.hasAttribute(PHX_REF_LOADING) ? parseInt(el.getAttribute(PHX_REF_LOADING), 10) : null;
      this.lockRef = el.hasAttribute(PHX_REF_LOCK) ? parseInt(el.getAttribute(PHX_REF_LOCK), 10) : null;
    }
    // public
    maybeUndo(ref, phxEvent, eachCloneCallback) {
      if (!this.isWithin(ref)) {
        dom_default.updatePrivate(this.el, PHX_PENDING_REFS, [], (pendingRefs) => {
          pendingRefs.push(ref);
          return pendingRefs;
        });
        return;
      }
      this.undoLocks(ref, phxEvent, eachCloneCallback);
      this.undoLoading(ref, phxEvent);
      dom_default.updatePrivate(this.el, PHX_PENDING_REFS, [], (pendingRefs) => {
        return pendingRefs.filter((pendingRef) => {
          let opts = {
            detail: { ref: pendingRef, event: phxEvent },
            bubbles: true,
            cancelable: false
          };
          if (this.loadingRef && this.loadingRef > pendingRef) {
            this.el.dispatchEvent(
              new CustomEvent(`phx:undo-loading:${pendingRef}`, opts)
            );
          }
          if (this.lockRef && this.lockRef > pendingRef) {
            this.el.dispatchEvent(
              new CustomEvent(`phx:undo-lock:${pendingRef}`, opts)
            );
          }
          return pendingRef > ref;
        });
      });
      if (this.isFullyResolvedBy(ref)) {
        this.el.removeAttribute(PHX_REF_SRC);
      }
    }
    // private
    isWithin(ref) {
      return !(this.loadingRef !== null && this.loadingRef > ref && this.lockRef !== null && this.lockRef > ref);
    }
    // Check for cloned PHX_REF_LOCK element that has been morphed behind
    // the scenes while this element was locked in the DOM.
    // When we apply the cloned tree to the active DOM element, we must
    //
    //   1. execute pending mounted hooks for nodes now in the DOM
    //   2. undo any ref inside the cloned tree that has since been ack'd
    undoLocks(ref, phxEvent, eachCloneCallback) {
      if (!this.isLockUndoneBy(ref)) {
        return;
      }
      const clonedTree = dom_default.private(this.el, PHX_REF_LOCK);
      if (clonedTree) {
        eachCloneCallback(clonedTree);
        dom_default.deletePrivate(this.el, PHX_REF_LOCK);
      }
      this.el.removeAttribute(PHX_REF_LOCK);
      const opts = {
        detail: { ref, event: phxEvent },
        bubbles: true,
        cancelable: false
      };
      this.el.dispatchEvent(
        new CustomEvent(`phx:undo-lock:${this.lockRef}`, opts)
      );
    }
    undoLoading(ref, phxEvent) {
      if (!this.isLoadingUndoneBy(ref)) {
        if (this.canUndoLoading(ref) && this.el.classList.contains("phx-submit-loading")) {
          this.el.classList.remove("phx-change-loading");
        }
        return;
      }
      if (this.canUndoLoading(ref)) {
        this.el.removeAttribute(PHX_REF_LOADING);
        const disabledVal = this.el.getAttribute(PHX_DISABLED);
        const readOnlyVal = this.el.getAttribute(PHX_READONLY);
        if (readOnlyVal !== null) {
          this.el.readOnly = readOnlyVal === "true" ? true : false;
          this.el.removeAttribute(PHX_READONLY);
        }
        if (disabledVal !== null) {
          this.el.disabled = disabledVal === "true" ? true : false;
          this.el.removeAttribute(PHX_DISABLED);
        }
        const disableRestore = this.el.getAttribute(PHX_DISABLE_WITH_RESTORE);
        if (disableRestore !== null) {
          this.el.innerText = disableRestore;
          this.el.removeAttribute(PHX_DISABLE_WITH_RESTORE);
        }
        const opts = {
          detail: { ref, event: phxEvent },
          bubbles: true,
          cancelable: false
        };
        this.el.dispatchEvent(
          new CustomEvent(`phx:undo-loading:${this.loadingRef}`, opts)
        );
      }
      PHX_EVENT_CLASSES.forEach((name) => {
        if (name !== "phx-submit-loading" || this.canUndoLoading(ref)) {
          dom_default.removeClass(this.el, name);
        }
      });
    }
    isLoadingUndoneBy(ref) {
      return this.loadingRef === null ? false : this.loadingRef <= ref;
    }
    isLockUndoneBy(ref) {
      return this.lockRef === null ? false : this.lockRef <= ref;
    }
    isFullyResolvedBy(ref) {
      return (this.loadingRef === null || this.loadingRef <= ref) && (this.lockRef === null || this.lockRef <= ref);
    }
    // only remove the phx-submit-loading class if we are not locked
    canUndoLoading(ref) {
      return this.lockRef === null || this.lockRef <= ref;
    }
  };
  var DOMPostMorphRestorer = class {
    constructor(containerBefore, containerAfter, updateType) {
      const idsBefore = /* @__PURE__ */ new Set();
      const idsAfter = new Set(
        [...containerAfter.children].map((child) => child.id)
      );
      const elementsToModify = [];
      Array.from(containerBefore.children).forEach((child) => {
        if (child.id) {
          idsBefore.add(child.id);
          if (idsAfter.has(child.id)) {
            const previousElementId = child.previousElementSibling && child.previousElementSibling.id;
            elementsToModify.push({
              elementId: child.id,
              previousElementId
            });
          }
        }
      });
      this.containerId = containerAfter.id;
      this.updateType = updateType;
      this.elementsToModify = elementsToModify;
      this.elementIdsToAdd = [...idsAfter].filter((id) => !idsBefore.has(id));
    }
    // We do the following to optimize append/prepend operations:
    //   1) Track ids of modified elements & of new elements
    //   2) All the modified elements are put back in the correct position in the DOM tree
    //      by storing the id of their previous sibling
    //   3) New elements are going to be put in the right place by morphdom during append.
    //      For prepend, we move them to the first position in the container
    perform() {
      const container = dom_default.byId(this.containerId);
      if (!container) {
        return;
      }
      this.elementsToModify.forEach((elementToModify) => {
        if (elementToModify.previousElementId) {
          maybe(
            document.getElementById(elementToModify.previousElementId),
            (previousElem) => {
              maybe(
                document.getElementById(elementToModify.elementId),
                (elem) => {
                  const isInRightPlace = elem.previousElementSibling && elem.previousElementSibling.id == previousElem.id;
                  if (!isInRightPlace) {
                    previousElem.insertAdjacentElement("afterend", elem);
                  }
                }
              );
            }
          );
        } else {
          maybe(document.getElementById(elementToModify.elementId), (elem) => {
            const isInRightPlace = elem.previousElementSibling == null;
            if (!isInRightPlace) {
              container.insertAdjacentElement("afterbegin", elem);
            }
          });
        }
      });
      if (this.updateType == "prepend") {
        this.elementIdsToAdd.reverse().forEach((elemId) => {
          maybe(
            document.getElementById(elemId),
            (elem) => container.insertAdjacentElement("afterbegin", elem)
          );
        });
      }
    }
  };
  var DOCUMENT_FRAGMENT_NODE = 11;
  function morphAttrs(fromNode, toNode) {
    var toNodeAttrs = toNode.attributes;
    var attr;
    var attrName;
    var attrNamespaceURI;
    var attrValue;
    var fromValue;
    if (toNode.nodeType === DOCUMENT_FRAGMENT_NODE || fromNode.nodeType === DOCUMENT_FRAGMENT_NODE) {
      return;
    }
    for (var i = toNodeAttrs.length - 1; i >= 0; i--) {
      attr = toNodeAttrs[i];
      attrName = attr.name;
      attrNamespaceURI = attr.namespaceURI;
      attrValue = attr.value;
      if (attrNamespaceURI) {
        attrName = attr.localName || attrName;
        fromValue = fromNode.getAttributeNS(attrNamespaceURI, attrName);
        if (fromValue !== attrValue) {
          if (attr.prefix === "xmlns") {
            attrName = attr.name;
          }
          fromNode.setAttributeNS(attrNamespaceURI, attrName, attrValue);
        }
      } else {
        fromValue = fromNode.getAttribute(attrName);
        if (fromValue !== attrValue) {
          fromNode.setAttribute(attrName, attrValue);
        }
      }
    }
    var fromNodeAttrs = fromNode.attributes;
    for (var d = fromNodeAttrs.length - 1; d >= 0; d--) {
      attr = fromNodeAttrs[d];
      attrName = attr.name;
      attrNamespaceURI = attr.namespaceURI;
      if (attrNamespaceURI) {
        attrName = attr.localName || attrName;
        if (!toNode.hasAttributeNS(attrNamespaceURI, attrName)) {
          fromNode.removeAttributeNS(attrNamespaceURI, attrName);
        }
      } else {
        if (!toNode.hasAttribute(attrName)) {
          fromNode.removeAttribute(attrName);
        }
      }
    }
  }
  var range;
  var NS_XHTML = "http://www.w3.org/1999/xhtml";
  var doc = typeof document === "undefined" ? void 0 : document;
  var HAS_TEMPLATE_SUPPORT = !!doc && "content" in doc.createElement("template");
  var HAS_RANGE_SUPPORT = !!doc && doc.createRange && "createContextualFragment" in doc.createRange();
  function createFragmentFromTemplate(str) {
    var template = doc.createElement("template");
    template.innerHTML = str;
    return template.content.childNodes[0];
  }
  function createFragmentFromRange(str) {
    if (!range) {
      range = doc.createRange();
      range.selectNode(doc.body);
    }
    var fragment = range.createContextualFragment(str);
    return fragment.childNodes[0];
  }
  function createFragmentFromWrap(str) {
    var fragment = doc.createElement("body");
    fragment.innerHTML = str;
    return fragment.childNodes[0];
  }
  function toElement(str) {
    str = str.trim();
    if (HAS_TEMPLATE_SUPPORT) {
      return createFragmentFromTemplate(str);
    } else if (HAS_RANGE_SUPPORT) {
      return createFragmentFromRange(str);
    }
    return createFragmentFromWrap(str);
  }
  function compareNodeNames(fromEl, toEl) {
    var fromNodeName = fromEl.nodeName;
    var toNodeName = toEl.nodeName;
    var fromCodeStart, toCodeStart;
    if (fromNodeName === toNodeName) {
      return true;
    }
    fromCodeStart = fromNodeName.charCodeAt(0);
    toCodeStart = toNodeName.charCodeAt(0);
    if (fromCodeStart <= 90 && toCodeStart >= 97) {
      return fromNodeName === toNodeName.toUpperCase();
    } else if (toCodeStart <= 90 && fromCodeStart >= 97) {
      return toNodeName === fromNodeName.toUpperCase();
    } else {
      return false;
    }
  }
  function createElementNS(name, namespaceURI) {
    return !namespaceURI || namespaceURI === NS_XHTML ? doc.createElement(name) : doc.createElementNS(namespaceURI, name);
  }
  function moveChildren(fromEl, toEl) {
    var curChild = fromEl.firstChild;
    while (curChild) {
      var nextChild = curChild.nextSibling;
      toEl.appendChild(curChild);
      curChild = nextChild;
    }
    return toEl;
  }
  function syncBooleanAttrProp(fromEl, toEl, name) {
    if (fromEl[name] !== toEl[name]) {
      fromEl[name] = toEl[name];
      if (fromEl[name]) {
        fromEl.setAttribute(name, "");
      } else {
        fromEl.removeAttribute(name);
      }
    }
  }
  var specialElHandlers = {
    OPTION: function(fromEl, toEl) {
      var parentNode = fromEl.parentNode;
      if (parentNode) {
        var parentName = parentNode.nodeName.toUpperCase();
        if (parentName === "OPTGROUP") {
          parentNode = parentNode.parentNode;
          parentName = parentNode && parentNode.nodeName.toUpperCase();
        }
        if (parentName === "SELECT" && !parentNode.hasAttribute("multiple")) {
          if (fromEl.hasAttribute("selected") && !toEl.selected) {
            fromEl.setAttribute("selected", "selected");
            fromEl.removeAttribute("selected");
          }
          parentNode.selectedIndex = -1;
        }
      }
      syncBooleanAttrProp(fromEl, toEl, "selected");
    },
    /**
     * The "value" attribute is special for the <input> element since it sets
     * the initial value. Changing the "value" attribute without changing the
     * "value" property will have no effect since it is only used to the set the
     * initial value.  Similar for the "checked" attribute, and "disabled".
     */
    INPUT: function(fromEl, toEl) {
      syncBooleanAttrProp(fromEl, toEl, "checked");
      syncBooleanAttrProp(fromEl, toEl, "disabled");
      if (fromEl.value !== toEl.value) {
        fromEl.value = toEl.value;
      }
      if (!toEl.hasAttribute("value")) {
        fromEl.removeAttribute("value");
      }
    },
    TEXTAREA: function(fromEl, toEl) {
      var newValue = toEl.value;
      if (fromEl.value !== newValue) {
        fromEl.value = newValue;
      }
      var firstChild = fromEl.firstChild;
      if (firstChild) {
        var oldValue = firstChild.nodeValue;
        if (oldValue == newValue || !newValue && oldValue == fromEl.placeholder) {
          return;
        }
        firstChild.nodeValue = newValue;
      }
    },
    SELECT: function(fromEl, toEl) {
      if (!toEl.hasAttribute("multiple")) {
        var selectedIndex = -1;
        var i = 0;
        var curChild = fromEl.firstChild;
        var optgroup;
        var nodeName;
        while (curChild) {
          nodeName = curChild.nodeName && curChild.nodeName.toUpperCase();
          if (nodeName === "OPTGROUP") {
            optgroup = curChild;
            curChild = optgroup.firstChild;
            if (!curChild) {
              curChild = optgroup.nextSibling;
              optgroup = null;
            }
          } else {
            if (nodeName === "OPTION") {
              if (curChild.hasAttribute("selected")) {
                selectedIndex = i;
                break;
              }
              i++;
            }
            curChild = curChild.nextSibling;
            if (!curChild && optgroup) {
              curChild = optgroup.nextSibling;
              optgroup = null;
            }
          }
        }
        fromEl.selectedIndex = selectedIndex;
      }
    }
  };
  var ELEMENT_NODE = 1;
  var DOCUMENT_FRAGMENT_NODE$1 = 11;
  var TEXT_NODE = 3;
  var COMMENT_NODE = 8;
  function noop() {
  }
  function defaultGetNodeKey(node) {
    if (node) {
      return node.getAttribute && node.getAttribute("id") || node.id;
    }
  }
  function morphdomFactory(morphAttrs2) {
    return function morphdom2(fromNode, toNode, options) {
      if (!options) {
        options = {};
      }
      if (typeof toNode === "string") {
        if (fromNode.nodeName === "#document" || fromNode.nodeName === "HTML" || fromNode.nodeName === "BODY") {
          var toNodeHtml = toNode;
          toNode = doc.createElement("html");
          toNode.innerHTML = toNodeHtml;
        } else {
          toNode = toElement(toNode);
        }
      } else if (toNode.nodeType === DOCUMENT_FRAGMENT_NODE$1) {
        toNode = toNode.firstElementChild;
      }
      var getNodeKey = options.getNodeKey || defaultGetNodeKey;
      var onBeforeNodeAdded = options.onBeforeNodeAdded || noop;
      var onNodeAdded = options.onNodeAdded || noop;
      var onBeforeElUpdated = options.onBeforeElUpdated || noop;
      var onElUpdated = options.onElUpdated || noop;
      var onBeforeNodeDiscarded = options.onBeforeNodeDiscarded || noop;
      var onNodeDiscarded = options.onNodeDiscarded || noop;
      var onBeforeElChildrenUpdated = options.onBeforeElChildrenUpdated || noop;
      var skipFromChildren = options.skipFromChildren || noop;
      var addChild = options.addChild || function(parent, child) {
        return parent.appendChild(child);
      };
      var childrenOnly = options.childrenOnly === true;
      var fromNodesLookup = /* @__PURE__ */ Object.create(null);
      var keyedRemovalList = [];
      function addKeyedRemoval(key) {
        keyedRemovalList.push(key);
      }
      function walkDiscardedChildNodes(node, skipKeyedNodes) {
        if (node.nodeType === ELEMENT_NODE) {
          var curChild = node.firstChild;
          while (curChild) {
            var key = void 0;
            if (skipKeyedNodes && (key = getNodeKey(curChild))) {
              addKeyedRemoval(key);
            } else {
              onNodeDiscarded(curChild);
              if (curChild.firstChild) {
                walkDiscardedChildNodes(curChild, skipKeyedNodes);
              }
            }
            curChild = curChild.nextSibling;
          }
        }
      }
      function removeNode(node, parentNode, skipKeyedNodes) {
        if (onBeforeNodeDiscarded(node) === false) {
          return;
        }
        if (parentNode) {
          parentNode.removeChild(node);
        }
        onNodeDiscarded(node);
        walkDiscardedChildNodes(node, skipKeyedNodes);
      }
      function indexTree(node) {
        if (node.nodeType === ELEMENT_NODE || node.nodeType === DOCUMENT_FRAGMENT_NODE$1) {
          var curChild = node.firstChild;
          while (curChild) {
            var key = getNodeKey(curChild);
            if (key) {
              fromNodesLookup[key] = curChild;
            }
            indexTree(curChild);
            curChild = curChild.nextSibling;
          }
        }
      }
      indexTree(fromNode);
      function handleNodeAdded(el) {
        onNodeAdded(el);
        var curChild = el.firstChild;
        while (curChild) {
          var nextSibling = curChild.nextSibling;
          var key = getNodeKey(curChild);
          if (key) {
            var unmatchedFromEl = fromNodesLookup[key];
            if (unmatchedFromEl && compareNodeNames(curChild, unmatchedFromEl)) {
              curChild.parentNode.replaceChild(unmatchedFromEl, curChild);
              morphEl(unmatchedFromEl, curChild);
            } else {
              handleNodeAdded(curChild);
            }
          } else {
            handleNodeAdded(curChild);
          }
          curChild = nextSibling;
        }
      }
      function cleanupFromEl(fromEl, curFromNodeChild, curFromNodeKey) {
        while (curFromNodeChild) {
          var fromNextSibling = curFromNodeChild.nextSibling;
          if (curFromNodeKey = getNodeKey(curFromNodeChild)) {
            addKeyedRemoval(curFromNodeKey);
          } else {
            removeNode(
              curFromNodeChild,
              fromEl,
              true
              /* skip keyed nodes */
            );
          }
          curFromNodeChild = fromNextSibling;
        }
      }
      function morphEl(fromEl, toEl, childrenOnly2) {
        var toElKey = getNodeKey(toEl);
        if (toElKey) {
          delete fromNodesLookup[toElKey];
        }
        if (!childrenOnly2) {
          var beforeUpdateResult = onBeforeElUpdated(fromEl, toEl);
          if (beforeUpdateResult === false) {
            return;
          } else if (beforeUpdateResult instanceof HTMLElement) {
            fromEl = beforeUpdateResult;
            indexTree(fromEl);
          }
          morphAttrs2(fromEl, toEl);
          onElUpdated(fromEl);
          if (onBeforeElChildrenUpdated(fromEl, toEl) === false) {
            return;
          }
        }
        if (fromEl.nodeName !== "TEXTAREA") {
          morphChildren(fromEl, toEl);
        } else {
          specialElHandlers.TEXTAREA(fromEl, toEl);
        }
      }
      function morphChildren(fromEl, toEl) {
        var skipFrom = skipFromChildren(fromEl, toEl);
        var curToNodeChild = toEl.firstChild;
        var curFromNodeChild = fromEl.firstChild;
        var curToNodeKey;
        var curFromNodeKey;
        var fromNextSibling;
        var toNextSibling;
        var matchingFromEl;
        outer:
          while (curToNodeChild) {
            toNextSibling = curToNodeChild.nextSibling;
            curToNodeKey = getNodeKey(curToNodeChild);
            while (!skipFrom && curFromNodeChild) {
              fromNextSibling = curFromNodeChild.nextSibling;
              if (curToNodeChild.isSameNode && curToNodeChild.isSameNode(curFromNodeChild)) {
                curToNodeChild = toNextSibling;
                curFromNodeChild = fromNextSibling;
                continue outer;
              }
              curFromNodeKey = getNodeKey(curFromNodeChild);
              var curFromNodeType = curFromNodeChild.nodeType;
              var isCompatible = void 0;
              if (curFromNodeType === curToNodeChild.nodeType) {
                if (curFromNodeType === ELEMENT_NODE) {
                  if (curToNodeKey) {
                    if (curToNodeKey !== curFromNodeKey) {
                      if (matchingFromEl = fromNodesLookup[curToNodeKey]) {
                        if (fromNextSibling === matchingFromEl) {
                          isCompatible = false;
                        } else {
                          fromEl.insertBefore(matchingFromEl, curFromNodeChild);
                          if (curFromNodeKey) {
                            addKeyedRemoval(curFromNodeKey);
                          } else {
                            removeNode(
                              curFromNodeChild,
                              fromEl,
                              true
                              /* skip keyed nodes */
                            );
                          }
                          curFromNodeChild = matchingFromEl;
                          curFromNodeKey = getNodeKey(curFromNodeChild);
                        }
                      } else {
                        isCompatible = false;
                      }
                    }
                  } else if (curFromNodeKey) {
                    isCompatible = false;
                  }
                  isCompatible = isCompatible !== false && compareNodeNames(curFromNodeChild, curToNodeChild);
                  if (isCompatible) {
                    morphEl(curFromNodeChild, curToNodeChild);
                  }
                } else if (curFromNodeType === TEXT_NODE || curFromNodeType == COMMENT_NODE) {
                  isCompatible = true;
                  if (curFromNodeChild.nodeValue !== curToNodeChild.nodeValue) {
                    curFromNodeChild.nodeValue = curToNodeChild.nodeValue;
                  }
                }
              }
              if (isCompatible) {
                curToNodeChild = toNextSibling;
                curFromNodeChild = fromNextSibling;
                continue outer;
              }
              if (curFromNodeKey) {
                addKeyedRemoval(curFromNodeKey);
              } else {
                removeNode(
                  curFromNodeChild,
                  fromEl,
                  true
                  /* skip keyed nodes */
                );
              }
              curFromNodeChild = fromNextSibling;
            }
            if (curToNodeKey && (matchingFromEl = fromNodesLookup[curToNodeKey]) && compareNodeNames(matchingFromEl, curToNodeChild)) {
              if (!skipFrom) {
                addChild(fromEl, matchingFromEl);
              }
              morphEl(matchingFromEl, curToNodeChild);
            } else {
              var onBeforeNodeAddedResult = onBeforeNodeAdded(curToNodeChild);
              if (onBeforeNodeAddedResult !== false) {
                if (onBeforeNodeAddedResult) {
                  curToNodeChild = onBeforeNodeAddedResult;
                }
                if (curToNodeChild.actualize) {
                  curToNodeChild = curToNodeChild.actualize(fromEl.ownerDocument || doc);
                }
                addChild(fromEl, curToNodeChild);
                handleNodeAdded(curToNodeChild);
              }
            }
            curToNodeChild = toNextSibling;
            curFromNodeChild = fromNextSibling;
          }
        cleanupFromEl(fromEl, curFromNodeChild, curFromNodeKey);
        var specialElHandler = specialElHandlers[fromEl.nodeName];
        if (specialElHandler) {
          specialElHandler(fromEl, toEl);
        }
      }
      var morphedNode = fromNode;
      var morphedNodeType = morphedNode.nodeType;
      var toNodeType = toNode.nodeType;
      if (!childrenOnly) {
        if (morphedNodeType === ELEMENT_NODE) {
          if (toNodeType === ELEMENT_NODE) {
            if (!compareNodeNames(fromNode, toNode)) {
              onNodeDiscarded(fromNode);
              morphedNode = moveChildren(fromNode, createElementNS(toNode.nodeName, toNode.namespaceURI));
            }
          } else {
            morphedNode = toNode;
          }
        } else if (morphedNodeType === TEXT_NODE || morphedNodeType === COMMENT_NODE) {
          if (toNodeType === morphedNodeType) {
            if (morphedNode.nodeValue !== toNode.nodeValue) {
              morphedNode.nodeValue = toNode.nodeValue;
            }
            return morphedNode;
          } else {
            morphedNode = toNode;
          }
        }
      }
      if (morphedNode === toNode) {
        onNodeDiscarded(fromNode);
      } else {
        if (toNode.isSameNode && toNode.isSameNode(morphedNode)) {
          return;
        }
        morphEl(morphedNode, toNode, childrenOnly);
        if (keyedRemovalList) {
          for (var i = 0, len = keyedRemovalList.length; i < len; i++) {
            var elToRemove = fromNodesLookup[keyedRemovalList[i]];
            if (elToRemove) {
              removeNode(elToRemove, elToRemove.parentNode, false);
            }
          }
        }
      }
      if (!childrenOnly && morphedNode !== fromNode && fromNode.parentNode) {
        if (morphedNode.actualize) {
          morphedNode = morphedNode.actualize(fromNode.ownerDocument || doc);
        }
        fromNode.parentNode.replaceChild(morphedNode, fromNode);
      }
      return morphedNode;
    };
  }
  var morphdom = morphdomFactory(morphAttrs);
  var morphdom_esm_default = morphdom;
  var DOMPatch = class {
    constructor(view, container, id, html, streams, targetCID, opts = {}) {
      this.view = view;
      this.liveSocket = view.liveSocket;
      this.container = container;
      this.id = id;
      this.rootID = view.root.id;
      this.html = html;
      this.streams = streams;
      this.streamInserts = {};
      this.streamComponentRestore = {};
      this.targetCID = targetCID;
      this.cidPatch = isCid(this.targetCID);
      this.pendingRemoves = [];
      this.phxRemove = this.liveSocket.binding("remove");
      this.targetContainer = this.isCIDPatch() ? this.targetCIDContainer(html) : container;
      this.callbacks = {
        beforeadded: [],
        beforeupdated: [],
        beforephxChildAdded: [],
        afteradded: [],
        afterupdated: [],
        afterdiscarded: [],
        afterphxChildAdded: [],
        aftertransitionsDiscarded: []
      };
      this.withChildren = opts.withChildren || opts.undoRef || false;
      this.undoRef = opts.undoRef;
    }
    before(kind, callback) {
      this.callbacks[`before${kind}`].push(callback);
    }
    after(kind, callback) {
      this.callbacks[`after${kind}`].push(callback);
    }
    trackBefore(kind, ...args) {
      this.callbacks[`before${kind}`].forEach((callback) => callback(...args));
    }
    trackAfter(kind, ...args) {
      this.callbacks[`after${kind}`].forEach((callback) => callback(...args));
    }
    markPrunableContentForRemoval() {
      const phxUpdate = this.liveSocket.binding(PHX_UPDATE);
      dom_default.all(
        this.container,
        `[${phxUpdate}=append] > *, [${phxUpdate}=prepend] > *`,
        (el) => {
          el.setAttribute(PHX_PRUNE, "");
        }
      );
    }
    perform(isJoinPatch) {
      const { view, liveSocket: liveSocket2, html, container, targetContainer } = this;
      if (this.isCIDPatch() && !targetContainer) {
        return;
      }
      const focused = liveSocket2.getActiveElement();
      const { selectionStart, selectionEnd } = focused && dom_default.hasSelectionRange(focused) ? focused : {};
      const phxUpdate = liveSocket2.binding(PHX_UPDATE);
      const phxViewportTop = liveSocket2.binding(PHX_VIEWPORT_TOP);
      const phxViewportBottom = liveSocket2.binding(PHX_VIEWPORT_BOTTOM);
      const phxTriggerExternal = liveSocket2.binding(PHX_TRIGGER_ACTION);
      const added = [];
      const updates = [];
      const appendPrependUpdates = [];
      const portalCallbacks = [];
      let externalFormTriggered = null;
      const morph = (targetContainer2, source, withChildren = this.withChildren) => {
        const morphCallbacks = {
          // normally, we are running with childrenOnly, as the patch HTML for a LV
          // does not include the LV attrs (data-phx-session, etc.)
          // when we are patching a live component, we do want to patch the root element as well;
          // another case is the recursive patch of a stream item that was kept on reset (-> onBeforeNodeAdded)
          childrenOnly: targetContainer2.getAttribute(PHX_COMPONENT) === null && !withChildren,
          getNodeKey: (node) => {
            if (dom_default.isPhxDestroyed(node)) {
              return null;
            }
            if (isJoinPatch) {
              return node.id;
            }
            return node.id || node.getAttribute && node.getAttribute(PHX_MAGIC_ID);
          },
          // skip indexing from children when container is stream
          skipFromChildren: (from) => {
            return from.getAttribute(phxUpdate) === PHX_STREAM;
          },
          // tell morphdom how to add a child
          addChild: (parent, child) => {
            const { ref, streamAt } = this.getStreamInsert(child);
            if (ref === void 0) {
              return parent.appendChild(child);
            }
            this.setStreamRef(child, ref);
            if (streamAt === 0) {
              parent.insertAdjacentElement("afterbegin", child);
            } else if (streamAt === -1) {
              const lastChild = parent.lastElementChild;
              if (lastChild && !lastChild.hasAttribute(PHX_STREAM_REF)) {
                const nonStreamChild = Array.from(parent.children).find(
                  (c) => !c.hasAttribute(PHX_STREAM_REF)
                );
                parent.insertBefore(child, nonStreamChild);
              } else {
                parent.appendChild(child);
              }
            } else if (streamAt > 0) {
              const sibling = Array.from(parent.children)[streamAt];
              parent.insertBefore(child, sibling);
            }
          },
          onBeforeNodeAdded: (el) => {
            var _a;
            if (((_a = this.getStreamInsert(el)) == null ? void 0 : _a.updateOnly) && !this.streamComponentRestore[el.id]) {
              return false;
            }
            dom_default.maintainPrivateHooks(el, el, phxViewportTop, phxViewportBottom);
            this.trackBefore("added", el);
            let morphedEl = el;
            if (this.streamComponentRestore[el.id]) {
              morphedEl = this.streamComponentRestore[el.id];
              delete this.streamComponentRestore[el.id];
              morph(morphedEl, el, true);
            }
            return morphedEl;
          },
          onNodeAdded: (el) => {
            if (el.getAttribute) {
              this.maybeReOrderStream(el, true);
            }
            if (dom_default.isPortalTemplate(el)) {
              portalCallbacks.push(() => this.teleport(el, morph));
            }
            if (el instanceof HTMLImageElement && el.srcset) {
              el.srcset = el.srcset;
            } else if (el instanceof HTMLVideoElement && el.autoplay) {
              el.play();
            }
            if (dom_default.isNowTriggerFormExternal(el, phxTriggerExternal)) {
              externalFormTriggered = el;
            }
            if (dom_default.isPhxChild(el) && view.ownsElement(el) || dom_default.isPhxSticky(el) && view.ownsElement(el.parentNode)) {
              this.trackAfter("phxChildAdded", el);
            }
            if (el.nodeName === "SCRIPT" && el.hasAttribute(PHX_RUNTIME_HOOK)) {
              this.handleRuntimeHook(el, source);
            }
            added.push(el);
          },
          onNodeDiscarded: (el) => this.onNodeDiscarded(el),
          onBeforeNodeDiscarded: (el) => {
            if (el.getAttribute && el.getAttribute(PHX_PRUNE) !== null) {
              return true;
            }
            if (el.parentElement !== null && el.id && dom_default.isPhxUpdate(el.parentElement, phxUpdate, [
              PHX_STREAM,
              "append",
              "prepend"
            ])) {
              return false;
            }
            if (el.getAttribute && el.getAttribute(PHX_TELEPORTED_REF)) {
              return false;
            }
            if (this.maybePendingRemove(el)) {
              return false;
            }
            if (this.skipCIDSibling(el)) {
              return false;
            }
            if (dom_default.isPortalTemplate(el)) {
              const teleportedEl = document.getElementById(
                el.content.firstElementChild.id
              );
              if (teleportedEl) {
                teleportedEl.remove();
                morphCallbacks.onNodeDiscarded(teleportedEl);
                this.view.dropPortalElementId(teleportedEl.id);
              }
            }
            return true;
          },
          onElUpdated: (el) => {
            if (dom_default.isNowTriggerFormExternal(el, phxTriggerExternal)) {
              externalFormTriggered = el;
            }
            updates.push(el);
            this.maybeReOrderStream(el, false);
          },
          onBeforeElUpdated: (fromEl, toEl) => {
            if (fromEl.id && fromEl.isSameNode(targetContainer2) && fromEl.id !== toEl.id) {
              morphCallbacks.onNodeDiscarded(fromEl);
              fromEl.replaceWith(toEl);
              return morphCallbacks.onNodeAdded(toEl);
            }
            dom_default.syncPendingAttrs(fromEl, toEl);
            dom_default.maintainPrivateHooks(
              fromEl,
              toEl,
              phxViewportTop,
              phxViewportBottom
            );
            dom_default.cleanChildNodes(toEl, phxUpdate);
            if (this.skipCIDSibling(toEl)) {
              this.maybeReOrderStream(fromEl);
              return false;
            }
            if (dom_default.isPhxSticky(fromEl)) {
              [PHX_SESSION, PHX_STATIC, PHX_ROOT_ID].map((attr) => [
                attr,
                fromEl.getAttribute(attr),
                toEl.getAttribute(attr)
              ]).forEach(([attr, fromVal, toVal]) => {
                if (toVal && fromVal !== toVal) {
                  fromEl.setAttribute(attr, toVal);
                }
              });
              return false;
            }
            if (dom_default.isIgnored(fromEl, phxUpdate) || fromEl.form && fromEl.form.isSameNode(externalFormTriggered)) {
              this.trackBefore("updated", fromEl, toEl);
              dom_default.mergeAttrs(fromEl, toEl, {
                isIgnored: dom_default.isIgnored(fromEl, phxUpdate)
              });
              updates.push(fromEl);
              dom_default.applyStickyOperations(fromEl);
              return false;
            }
            if (fromEl.type === "number" && fromEl.validity && fromEl.validity.badInput) {
              return false;
            }
            const isFocusedFormEl = focused && fromEl.isSameNode(focused) && dom_default.isFormInput(fromEl);
            const focusedSelectChanged = isFocusedFormEl && this.isChangedSelect(fromEl, toEl);
            if (fromEl.hasAttribute(PHX_REF_SRC)) {
              const ref = new ElementRef(fromEl);
              if (ref.lockRef && (!this.undoRef || !ref.isLockUndoneBy(this.undoRef))) {
                if (dom_default.isUploadInput(fromEl)) {
                  dom_default.mergeAttrs(fromEl, toEl, { isIgnored: true });
                  this.trackBefore("updated", fromEl, toEl);
                  updates.push(fromEl);
                }
                dom_default.applyStickyOperations(fromEl);
                const isLocked = fromEl.hasAttribute(PHX_REF_LOCK);
                const clone2 = isLocked ? dom_default.private(fromEl, PHX_REF_LOCK) || fromEl.cloneNode(true) : null;
                if (clone2) {
                  dom_default.putPrivate(fromEl, PHX_REF_LOCK, clone2);
                  if (!isFocusedFormEl) {
                    fromEl = clone2;
                  }
                }
              }
            }
            if (dom_default.isPhxChild(toEl)) {
              const prevSession = fromEl.getAttribute(PHX_SESSION);
              dom_default.mergeAttrs(fromEl, toEl, { exclude: [PHX_STATIC] });
              if (prevSession !== "") {
                fromEl.setAttribute(PHX_SESSION, prevSession);
              }
              fromEl.setAttribute(PHX_ROOT_ID, this.rootID);
              dom_default.applyStickyOperations(fromEl);
              return false;
            }
            if (this.undoRef && dom_default.private(toEl, PHX_REF_LOCK)) {
              dom_default.putPrivate(
                fromEl,
                PHX_REF_LOCK,
                dom_default.private(toEl, PHX_REF_LOCK)
              );
            }
            dom_default.copyPrivates(toEl, fromEl);
            if (dom_default.isPortalTemplate(toEl)) {
              portalCallbacks.push(() => this.teleport(toEl, morph));
              return false;
            }
            if (isFocusedFormEl && fromEl.type !== "hidden" && !focusedSelectChanged) {
              this.trackBefore("updated", fromEl, toEl);
              dom_default.mergeFocusedInput(fromEl, toEl);
              dom_default.syncAttrsToProps(fromEl);
              updates.push(fromEl);
              dom_default.applyStickyOperations(fromEl);
              return false;
            } else {
              if (focusedSelectChanged) {
                fromEl.blur();
              }
              if (dom_default.isPhxUpdate(toEl, phxUpdate, ["append", "prepend"])) {
                appendPrependUpdates.push(
                  new DOMPostMorphRestorer(
                    fromEl,
                    toEl,
                    toEl.getAttribute(phxUpdate)
                  )
                );
              }
              dom_default.syncAttrsToProps(toEl);
              dom_default.applyStickyOperations(toEl);
              this.trackBefore("updated", fromEl, toEl);
              return fromEl;
            }
          }
        };
        morphdom_esm_default(targetContainer2, source, morphCallbacks);
      };
      this.trackBefore("added", container);
      this.trackBefore("updated", container, container);
      liveSocket2.time("morphdom", () => {
        this.streams.forEach(([ref, inserts, deleteIds, reset]) => {
          inserts.forEach(([key, streamAt, limit, updateOnly]) => {
            this.streamInserts[key] = { ref, streamAt, limit, reset, updateOnly };
          });
          if (reset !== void 0) {
            dom_default.all(container, `[${PHX_STREAM_REF}="${ref}"]`, (child) => {
              this.removeStreamChildElement(child);
            });
          }
          deleteIds.forEach((id) => {
            const child = container.querySelector(`[id="${id}"]`);
            if (child) {
              this.removeStreamChildElement(child);
            }
          });
        });
        if (isJoinPatch) {
          dom_default.all(this.container, `[${phxUpdate}=${PHX_STREAM}]`).filter((el) => this.view.ownsElement(el)).forEach((el) => {
            Array.from(el.children).forEach((child) => {
              this.removeStreamChildElement(child, true);
            });
          });
        }
        morph(targetContainer, html);
        portalCallbacks.forEach((callback) => callback());
        this.view.portalElementIds.forEach((id) => {
          const el = document.getElementById(id);
          if (el) {
            const source = document.getElementById(
              el.getAttribute(PHX_TELEPORTED_SRC)
            );
            if (!source) {
              el.remove();
              this.onNodeDiscarded(el);
              this.view.dropPortalElementId(id);
            }
          }
        });
      });
      if (liveSocket2.isDebugEnabled()) {
        detectDuplicateIds();
        detectInvalidStreamInserts(this.streamInserts);
        Array.from(document.querySelectorAll("input[name=id]")).forEach(
          (node) => {
            if (node instanceof HTMLInputElement && node.form) {
              console.error(
                'Detected an input with name="id" inside a form! This will cause problems when patching the DOM.\n',
                node
              );
            }
          }
        );
      }
      if (appendPrependUpdates.length > 0) {
        liveSocket2.time("post-morph append/prepend restoration", () => {
          appendPrependUpdates.forEach((update) => update.perform());
        });
      }
      liveSocket2.silenceEvents(
        () => dom_default.restoreFocus(focused, selectionStart, selectionEnd)
      );
      dom_default.dispatchEvent(document, "phx:update");
      added.forEach((el) => this.trackAfter("added", el));
      updates.forEach((el) => this.trackAfter("updated", el));
      this.transitionPendingRemoves();
      if (externalFormTriggered) {
        liveSocket2.unload();
        const submitter = dom_default.private(externalFormTriggered, "submitter");
        if (submitter && submitter.name && targetContainer.contains(submitter)) {
          const input = document.createElement("input");
          input.type = "hidden";
          const formId = submitter.getAttribute("form");
          if (formId) {
            input.setAttribute("form", formId);
          }
          input.name = submitter.name;
          input.value = submitter.value;
          submitter.parentElement.insertBefore(input, submitter);
        }
        Object.getPrototypeOf(externalFormTriggered).submit.call(
          externalFormTriggered
        );
      }
      return true;
    }
    onNodeDiscarded(el) {
      if (dom_default.isPhxChild(el) || dom_default.isPhxSticky(el)) {
        this.liveSocket.destroyViewByEl(el);
      }
      this.trackAfter("discarded", el);
    }
    maybePendingRemove(node) {
      if (node.getAttribute && node.getAttribute(this.phxRemove) !== null) {
        this.pendingRemoves.push(node);
        return true;
      } else {
        return false;
      }
    }
    removeStreamChildElement(child, force = false) {
      if (!force && !this.view.ownsElement(child)) {
        return;
      }
      if (this.streamInserts[child.id]) {
        this.streamComponentRestore[child.id] = child;
        child.remove();
      } else {
        if (!this.maybePendingRemove(child)) {
          child.remove();
          this.onNodeDiscarded(child);
        }
      }
    }
    getStreamInsert(el) {
      const insert = el.id ? this.streamInserts[el.id] : {};
      return insert || {};
    }
    setStreamRef(el, ref) {
      dom_default.putSticky(
        el,
        PHX_STREAM_REF,
        (el2) => el2.setAttribute(PHX_STREAM_REF, ref)
      );
    }
    maybeReOrderStream(el, isNew) {
      const { ref, streamAt, reset } = this.getStreamInsert(el);
      if (streamAt === void 0) {
        return;
      }
      this.setStreamRef(el, ref);
      if (!reset && !isNew) {
        return;
      }
      if (!el.parentElement) {
        return;
      }
      if (streamAt === 0) {
        el.parentElement.insertBefore(el, el.parentElement.firstElementChild);
      } else if (streamAt > 0) {
        const children = Array.from(el.parentElement.children);
        const oldIndex = children.indexOf(el);
        if (streamAt >= children.length - 1) {
          el.parentElement.appendChild(el);
        } else {
          const sibling = children[streamAt];
          if (oldIndex > streamAt) {
            el.parentElement.insertBefore(el, sibling);
          } else {
            el.parentElement.insertBefore(el, sibling.nextElementSibling);
          }
        }
      }
      this.maybeLimitStream(el);
    }
    maybeLimitStream(el) {
      const { limit } = this.getStreamInsert(el);
      const children = limit !== null && Array.from(el.parentElement.children);
      if (limit && limit < 0 && children.length > limit * -1) {
        children.slice(0, children.length + limit).forEach((child) => this.removeStreamChildElement(child));
      } else if (limit && limit >= 0 && children.length > limit) {
        children.slice(limit).forEach((child) => this.removeStreamChildElement(child));
      }
    }
    transitionPendingRemoves() {
      const { pendingRemoves, liveSocket: liveSocket2 } = this;
      if (pendingRemoves.length > 0) {
        liveSocket2.transitionRemoves(pendingRemoves, () => {
          pendingRemoves.forEach((el) => {
            const child = dom_default.firstPhxChild(el);
            if (child) {
              liveSocket2.destroyViewByEl(child);
            }
            el.remove();
          });
          this.trackAfter("transitionsDiscarded", pendingRemoves);
        });
      }
    }
    isChangedSelect(fromEl, toEl) {
      if (!(fromEl instanceof HTMLSelectElement) || fromEl.multiple) {
        return false;
      }
      if (fromEl.options.length !== toEl.options.length) {
        return true;
      }
      toEl.value = fromEl.value;
      return !fromEl.isEqualNode(toEl);
    }
    isCIDPatch() {
      return this.cidPatch;
    }
    skipCIDSibling(el) {
      return el.nodeType === Node.ELEMENT_NODE && el.hasAttribute(PHX_SKIP);
    }
    targetCIDContainer(html) {
      if (!this.isCIDPatch()) {
        return;
      }
      const [first, ...rest] = dom_default.findComponentNodeList(
        this.view.id,
        this.targetCID
      );
      if (rest.length === 0 && dom_default.childNodeLength(html) === 1) {
        return first;
      } else {
        return first && first.parentNode;
      }
    }
    indexOf(parent, child) {
      return Array.from(parent.children).indexOf(child);
    }
    teleport(el, morph) {
      const targetSelector = el.getAttribute(PHX_PORTAL);
      const portalContainer = document.querySelector(targetSelector);
      if (!portalContainer) {
        throw new Error(
          "portal target with selector " + targetSelector + " not found"
        );
      }
      const toTeleport = el.content.firstElementChild;
      if (this.skipCIDSibling(toTeleport)) {
        return;
      }
      if (!(toTeleport == null ? void 0 : toTeleport.id)) {
        throw new Error(
          "phx-portal template must have a single root element with ID!"
        );
      }
      const existing = document.getElementById(toTeleport.id);
      let portalTarget;
      if (existing) {
        if (!portalContainer.contains(existing)) {
          portalContainer.appendChild(existing);
        }
        portalTarget = existing;
      } else {
        portalTarget = document.createElement(toTeleport.tagName);
        portalContainer.appendChild(portalTarget);
      }
      toTeleport.setAttribute(PHX_TELEPORTED_REF, this.view.id);
      toTeleport.setAttribute(PHX_TELEPORTED_SRC, el.id);
      morph(portalTarget, toTeleport, true);
      toTeleport.removeAttribute(PHX_TELEPORTED_REF);
      toTeleport.removeAttribute(PHX_TELEPORTED_SRC);
      this.view.pushPortalElementId(toTeleport.id);
    }
    handleRuntimeHook(el, source) {
      const name = el.getAttribute(PHX_RUNTIME_HOOK);
      let nonce = el.hasAttribute("nonce") ? el.getAttribute("nonce") : null;
      if (el.hasAttribute("nonce")) {
        const template = document.createElement("template");
        template.innerHTML = source;
        nonce = template.content.querySelector(`script[${PHX_RUNTIME_HOOK}="${CSS.escape(name)}"]`).getAttribute("nonce");
      }
      const script = document.createElement("script");
      script.textContent = el.textContent;
      dom_default.mergeAttrs(script, el, { isIgnored: false });
      if (nonce) {
        script.nonce = nonce;
      }
      el.replaceWith(script);
      el = script;
    }
  };
  var VOID_TAGS = /* @__PURE__ */ new Set([
    "area",
    "base",
    "br",
    "col",
    "command",
    "embed",
    "hr",
    "img",
    "input",
    "keygen",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr"
  ]);
  var quoteChars = /* @__PURE__ */ new Set(["'", '"']);
  var modifyRoot = (html, attrs, clearInnerHTML) => {
    let i = 0;
    let insideComment = false;
    let beforeTag, afterTag, tag, tagNameEndsAt, id, newHTML;
    const lookahead = html.match(/^(\s*(?:<!--.*?-->\s*)*)<([^\s\/>]+)/);
    if (lookahead === null) {
      throw new Error(`malformed html ${html}`);
    }
    i = lookahead[0].length;
    beforeTag = lookahead[1];
    tag = lookahead[2];
    tagNameEndsAt = i;
    for (i; i < html.length; i++) {
      if (html.charAt(i) === ">") {
        break;
      }
      if (html.charAt(i) === "=") {
        const isId = html.slice(i - 3, i) === " id";
        i++;
        const char = html.charAt(i);
        if (quoteChars.has(char)) {
          const attrStartsAt = i;
          i++;
          for (i; i < html.length; i++) {
            if (html.charAt(i) === char) {
              break;
            }
          }
          if (isId) {
            id = html.slice(attrStartsAt + 1, i);
            break;
          }
        }
      }
    }
    let closeAt = html.length - 1;
    insideComment = false;
    while (closeAt >= beforeTag.length + tag.length) {
      const char = html.charAt(closeAt);
      if (insideComment) {
        if (char === "-" && html.slice(closeAt - 3, closeAt) === "<!-") {
          insideComment = false;
          closeAt -= 4;
        } else {
          closeAt -= 1;
        }
      } else if (char === ">" && html.slice(closeAt - 2, closeAt) === "--") {
        insideComment = true;
        closeAt -= 3;
      } else if (char === ">") {
        break;
      } else {
        closeAt -= 1;
      }
    }
    afterTag = html.slice(closeAt + 1, html.length);
    const attrsStr = Object.keys(attrs).map((attr) => attrs[attr] === true ? attr : `${attr}="${attrs[attr]}"`).join(" ");
    if (clearInnerHTML) {
      const idAttrStr = id ? ` id="${id}"` : "";
      if (VOID_TAGS.has(tag)) {
        newHTML = `<${tag}${idAttrStr}${attrsStr === "" ? "" : " "}${attrsStr}/>`;
      } else {
        newHTML = `<${tag}${idAttrStr}${attrsStr === "" ? "" : " "}${attrsStr}></${tag}>`;
      }
    } else {
      const rest = html.slice(tagNameEndsAt, closeAt + 1);
      newHTML = `<${tag}${attrsStr === "" ? "" : " "}${attrsStr}${rest}`;
    }
    return [newHTML, beforeTag, afterTag];
  };
  var Rendered = class {
    static extract(diff) {
      const { [REPLY]: reply, [EVENTS]: events, [TITLE]: title } = diff;
      delete diff[REPLY];
      delete diff[EVENTS];
      delete diff[TITLE];
      return { diff, title, reply: reply || null, events: events || [] };
    }
    constructor(viewId, rendered) {
      this.viewId = viewId;
      this.rendered = {};
      this.magicId = 0;
      this.mergeDiff(rendered);
    }
    parentViewId() {
      return this.viewId;
    }
    toString(onlyCids) {
      const { buffer: str, streams } = this.recursiveToString(
        this.rendered,
        this.rendered[COMPONENTS],
        onlyCids,
        true,
        {}
      );
      return { buffer: str, streams };
    }
    recursiveToString(rendered, components = rendered[COMPONENTS], onlyCids, changeTracking, rootAttrs) {
      onlyCids = onlyCids ? new Set(onlyCids) : null;
      const output = {
        buffer: "",
        components,
        onlyCids,
        streams: /* @__PURE__ */ new Set()
      };
      this.toOutputBuffer(rendered, null, output, changeTracking, rootAttrs);
      return { buffer: output.buffer, streams: output.streams };
    }
    componentCIDs(diff) {
      return Object.keys(diff[COMPONENTS] || {}).map((i) => parseInt(i));
    }
    isComponentOnlyDiff(diff) {
      if (!diff[COMPONENTS]) {
        return false;
      }
      return Object.keys(diff).length === 1;
    }
    getComponent(diff, cid) {
      return diff[COMPONENTS][cid];
    }
    resetRender(cid) {
      if (this.rendered[COMPONENTS][cid]) {
        this.rendered[COMPONENTS][cid].reset = true;
      }
    }
    mergeDiff(diff) {
      const newc = diff[COMPONENTS];
      const cache = {};
      delete diff[COMPONENTS];
      this.rendered = this.mutableMerge(this.rendered, diff);
      this.rendered[COMPONENTS] = this.rendered[COMPONENTS] || {};
      if (newc) {
        const oldc = this.rendered[COMPONENTS];
        for (const cid in newc) {
          newc[cid] = this.cachedFindComponent(cid, newc[cid], oldc, newc, cache);
        }
        for (const cid in newc) {
          oldc[cid] = newc[cid];
        }
        diff[COMPONENTS] = newc;
      }
    }
    cachedFindComponent(cid, cdiff, oldc, newc, cache) {
      if (cache[cid]) {
        return cache[cid];
      } else {
        let ndiff, stat, scid = cdiff[STATIC];
        if (isCid(scid)) {
          let tdiff;
          if (scid > 0) {
            tdiff = this.cachedFindComponent(scid, newc[scid], oldc, newc, cache);
          } else {
            tdiff = oldc[-scid];
          }
          stat = tdiff[STATIC];
          ndiff = this.cloneMerge(tdiff, cdiff, true);
          ndiff[STATIC] = stat;
        } else {
          ndiff = cdiff[STATIC] !== void 0 || oldc[cid] === void 0 ? cdiff : this.cloneMerge(oldc[cid], cdiff, false);
        }
        cache[cid] = ndiff;
        return ndiff;
      }
    }
    mutableMerge(target, source) {
      if (source[STATIC] !== void 0) {
        return source;
      } else {
        this.doMutableMerge(target, source);
        return target;
      }
    }
    doMutableMerge(target, source) {
      if (source[KEYED]) {
        this.mergeKeyed(target, source);
      } else {
        for (const key in source) {
          const val = source[key];
          const targetVal = target[key];
          const isObjVal = isObject(val);
          if (isObjVal && val[STATIC] === void 0 && isObject(targetVal)) {
            this.doMutableMerge(targetVal, val);
          } else {
            target[key] = val;
          }
        }
      }
      if (target[ROOT]) {
        target.newRender = true;
      }
    }
    clone(diff) {
      if ("structuredClone" in window) {
        return structuredClone(diff);
      } else {
        return JSON.parse(JSON.stringify(diff));
      }
    }
    // keyed comprehensions
    mergeKeyed(target, source) {
      const clonedTarget = this.clone(target);
      Object.entries(source[KEYED]).forEach(([i, entry]) => {
        if (i === KEYED_COUNT) {
          return;
        }
        if (Array.isArray(entry)) {
          const [old_idx, diff] = entry;
          target[KEYED][i] = clonedTarget[KEYED][old_idx];
          this.doMutableMerge(target[KEYED][i], diff);
        } else if (typeof entry === "number") {
          const old_idx = entry;
          target[KEYED][i] = clonedTarget[KEYED][old_idx];
        } else if (typeof entry === "object") {
          if (!target[KEYED][i]) {
            target[KEYED][i] = {};
          }
          this.doMutableMerge(target[KEYED][i], entry);
        }
      });
      if (source[KEYED][KEYED_COUNT] < target[KEYED][KEYED_COUNT]) {
        for (let i = source[KEYED][KEYED_COUNT]; i < target[KEYED][KEYED_COUNT]; i++) {
          delete target[KEYED][i];
        }
      }
      target[KEYED][KEYED_COUNT] = source[KEYED][KEYED_COUNT];
      if (source[STREAM]) {
        target[STREAM] = source[STREAM];
      }
      if (source[TEMPLATES]) {
        target[TEMPLATES] = source[TEMPLATES];
      }
    }
    // Merges cid trees together, copying statics from source tree.
    //
    // The `pruneMagicId` is passed to control pruning the magicId of the
    // target. We must always prune the magicId when we are sharing statics
    // from another component. If not pruning, we replicate the logic from
    // mutableMerge, where we set newRender to true if there is a root
    // (effectively forcing the new version to be rendered instead of skipped)
    //
    cloneMerge(target, source, pruneMagicId) {
      const merged = __spreadValues(__spreadValues({}, target), source);
      for (const key in merged) {
        const val = source[key];
        const targetVal = target[key];
        if (isObject(val) && val[STATIC] === void 0 && isObject(targetVal)) {
          merged[key] = this.cloneMerge(targetVal, val, pruneMagicId);
        } else if (val === void 0 && isObject(targetVal)) {
          merged[key] = this.cloneMerge(targetVal, {}, pruneMagicId);
        }
      }
      if (pruneMagicId) {
        delete merged.magicId;
        delete merged.newRender;
      } else if (target[ROOT]) {
        merged.newRender = true;
      }
      return merged;
    }
    componentToString(cid) {
      const { buffer: str, streams } = this.recursiveCIDToString(
        this.rendered[COMPONENTS],
        cid,
        null
      );
      const [strippedHTML, _before, _after] = modifyRoot(str, {});
      return { buffer: strippedHTML, streams };
    }
    pruneCIDs(cids) {
      cids.forEach((cid) => delete this.rendered[COMPONENTS][cid]);
    }
    // private
    get() {
      return this.rendered;
    }
    isNewFingerprint(diff = {}) {
      return !!diff[STATIC];
    }
    templateStatic(part, templates) {
      if (typeof part === "number") {
        return templates[part];
      } else {
        return part;
      }
    }
    nextMagicID() {
      this.magicId++;
      return `m${this.magicId}-${this.parentViewId()}`;
    }
    // Converts rendered tree to output buffer.
    //
    // changeTracking controls if we can apply the PHX_SKIP optimization.
    toOutputBuffer(rendered, templates, output, changeTracking, rootAttrs = {}) {
      if (rendered[KEYED]) {
        return this.comprehensionToBuffer(
          rendered,
          templates,
          output,
          changeTracking
        );
      }
      if (rendered[TEMPLATES]) {
        templates = rendered[TEMPLATES];
        delete rendered[TEMPLATES];
      }
      let { [STATIC]: statics } = rendered;
      statics = this.templateStatic(statics, templates);
      rendered[STATIC] = statics;
      const isRoot = rendered[ROOT];
      const prevBuffer = output.buffer;
      if (isRoot) {
        output.buffer = "";
      }
      if (changeTracking && isRoot && !rendered.magicId) {
        rendered.newRender = true;
        rendered.magicId = this.nextMagicID();
      }
      output.buffer += statics[0];
      for (let i = 1; i < statics.length; i++) {
        this.dynamicToBuffer(rendered[i - 1], templates, output, changeTracking);
        output.buffer += statics[i];
      }
      if (isRoot) {
        let skip = false;
        let attrs;
        if (changeTracking || rendered.magicId) {
          skip = changeTracking && !rendered.newRender;
          attrs = __spreadValues({ [PHX_MAGIC_ID]: rendered.magicId }, rootAttrs);
        } else {
          attrs = rootAttrs;
        }
        if (skip) {
          attrs[PHX_SKIP] = true;
        }
        const [newRoot, commentBefore, commentAfter] = modifyRoot(
          output.buffer,
          attrs,
          skip
        );
        rendered.newRender = false;
        output.buffer = prevBuffer + commentBefore + newRoot + commentAfter;
      }
    }
    comprehensionToBuffer(rendered, templates, output, changeTracking) {
      const keyedTemplates = templates || rendered[TEMPLATES];
      const statics = this.templateStatic(rendered[STATIC], templates);
      rendered[STATIC] = statics;
      delete rendered[TEMPLATES];
      for (let i = 0; i < rendered[KEYED][KEYED_COUNT]; i++) {
        output.buffer += statics[0];
        for (let j = 1; j < statics.length; j++) {
          this.dynamicToBuffer(
            rendered[KEYED][i][j - 1],
            keyedTemplates,
            output,
            changeTracking
          );
          output.buffer += statics[j];
        }
      }
      if (rendered[STREAM]) {
        const stream = rendered[STREAM];
        const [_ref, _inserts, deleteIds, reset] = stream || [null, {}, [], null];
        if (stream !== void 0 && (rendered[KEYED][KEYED_COUNT] > 0 || deleteIds.length > 0 || reset)) {
          delete rendered[STREAM];
          rendered[KEYED] = {
            [KEYED_COUNT]: 0
          };
          output.streams.add(stream);
        }
      }
    }
    dynamicToBuffer(rendered, templates, output, changeTracking) {
      if (typeof rendered === "number") {
        const { buffer: str, streams } = this.recursiveCIDToString(
          output.components,
          rendered,
          output.onlyCids
        );
        output.buffer += str;
        output.streams = /* @__PURE__ */ new Set([...output.streams, ...streams]);
      } else if (isObject(rendered)) {
        this.toOutputBuffer(rendered, templates, output, changeTracking, {});
      } else {
        output.buffer += rendered;
      }
    }
    recursiveCIDToString(components, cid, onlyCids) {
      const component = components[cid] || logError(`no component for CID ${cid}`, components);
      const attrs = { [PHX_COMPONENT]: cid, [PHX_VIEW_REF]: this.viewId };
      const skip = onlyCids && !onlyCids.has(cid);
      component.newRender = !skip;
      component.magicId = `c${cid}-${this.parentViewId()}`;
      const changeTracking = !component.reset;
      const { buffer: html, streams } = this.recursiveToString(
        component,
        components,
        onlyCids,
        changeTracking,
        attrs
      );
      delete component.reset;
      return { buffer: html, streams };
    }
  };
  var focusStack = [];
  var default_transition_time = 200;
  var JS = {
    // private
    exec(e, eventType, phxEvent, view, sourceEl, defaults) {
      const [defaultKind, defaultArgs] = defaults || [
        null,
        { callback: defaults && defaults.callback }
      ];
      const commands = phxEvent.charAt(0) === "[" ? JSON.parse(phxEvent) : [[defaultKind, defaultArgs]];
      commands.forEach(([kind, args]) => {
        if (kind === defaultKind) {
          args = __spreadValues(__spreadValues({}, defaultArgs), args);
          args.callback = args.callback || defaultArgs.callback;
        }
        this.filterToEls(view.liveSocket, sourceEl, args).forEach((el) => {
          this[`exec_${kind}`](e, eventType, phxEvent, view, sourceEl, el, args);
        });
      });
    },
    isVisible(el) {
      return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length > 0);
    },
    // returns true if any part of the element is inside the viewport
    isInViewport(el) {
      const rect = el.getBoundingClientRect();
      const windowHeight = window.innerHeight || document.documentElement.clientHeight;
      const windowWidth = window.innerWidth || document.documentElement.clientWidth;
      return rect.right > 0 && rect.bottom > 0 && rect.left < windowWidth && rect.top < windowHeight;
    },
    // private
    // commands
    exec_exec(e, eventType, phxEvent, view, sourceEl, el, { attr, to }) {
      const encodedJS = el.getAttribute(attr);
      if (!encodedJS) {
        throw new Error(`expected ${attr} to contain JS command on "${to}"`);
      }
      view.liveSocket.execJS(el, encodedJS, eventType);
    },
    exec_dispatch(e, eventType, phxEvent, view, sourceEl, el, { event, detail, bubbles, blocking }) {
      detail = detail || {};
      detail.dispatcher = sourceEl;
      if (blocking) {
        const promise = new Promise((resolve, _reject) => {
          detail.done = resolve;
        });
        view.liveSocket.asyncTransition(promise);
      }
      dom_default.dispatchEvent(el, event, { detail, bubbles });
    },
    exec_push(e, eventType, phxEvent, view, sourceEl, el, args) {
      const {
        event,
        data,
        target,
        page_loading,
        loading,
        value,
        dispatcher,
        callback
      } = args;
      const pushOpts = {
        loading,
        value,
        target,
        page_loading: !!page_loading,
        originalEvent: e
      };
      const targetSrc = eventType === "change" && dispatcher ? dispatcher : sourceEl;
      const phxTarget = target || targetSrc.getAttribute(view.binding("target")) || targetSrc;
      const handler = (targetView, targetCtx) => {
        if (!targetView.isConnected()) {
          return;
        }
        if (eventType === "change") {
          let { newCid, _target } = args;
          _target = _target || (dom_default.isFormInput(sourceEl) ? sourceEl.name : void 0);
          if (_target) {
            pushOpts._target = _target;
          }
          targetView.pushInput(
            sourceEl,
            targetCtx,
            newCid,
            event || phxEvent,
            pushOpts,
            callback
          );
        } else if (eventType === "submit") {
          const { submitter } = args;
          targetView.submitForm(
            sourceEl,
            targetCtx,
            event || phxEvent,
            submitter,
            pushOpts,
            callback
          );
        } else {
          targetView.pushEvent(
            eventType,
            sourceEl,
            targetCtx,
            event || phxEvent,
            data,
            pushOpts,
            callback
          );
        }
      };
      if (args.targetView && args.targetCtx) {
        handler(args.targetView, args.targetCtx);
      } else {
        view.withinTargets(phxTarget, handler);
      }
    },
    exec_navigate(e, eventType, phxEvent, view, sourceEl, el, { href, replace }) {
      view.liveSocket.historyRedirect(
        e,
        href,
        replace ? "replace" : "push",
        null,
        sourceEl
      );
    },
    exec_patch(e, eventType, phxEvent, view, sourceEl, el, { href, replace }) {
      view.liveSocket.pushHistoryPatch(
        e,
        href,
        replace ? "replace" : "push",
        sourceEl
      );
    },
    exec_focus(e, eventType, phxEvent, view, sourceEl, el) {
      aria_default.attemptFocus(el);
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => aria_default.attemptFocus(el));
      });
    },
    exec_focus_first(e, eventType, phxEvent, view, sourceEl, el) {
      aria_default.focusFirstInteractive(el) || aria_default.focusFirst(el);
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(
          () => aria_default.focusFirstInteractive(el) || aria_default.focusFirst(el)
        );
      });
    },
    exec_push_focus(e, eventType, phxEvent, view, sourceEl, el) {
      focusStack.push(el || sourceEl);
    },
    exec_pop_focus(_e, _eventType, _phxEvent, _view, _sourceEl, _el) {
      const el = focusStack.pop();
      if (el) {
        el.focus();
        window.requestAnimationFrame(() => {
          window.requestAnimationFrame(() => el.focus());
        });
      }
    },
    exec_add_class(e, eventType, phxEvent, view, sourceEl, el, { names, transition, time, blocking }) {
      this.addOrRemoveClasses(el, names, [], transition, time, view, blocking);
    },
    exec_remove_class(e, eventType, phxEvent, view, sourceEl, el, { names, transition, time, blocking }) {
      this.addOrRemoveClasses(el, [], names, transition, time, view, blocking);
    },
    exec_toggle_class(e, eventType, phxEvent, view, sourceEl, el, { names, transition, time, blocking }) {
      this.toggleClasses(el, names, transition, time, view, blocking);
    },
    exec_toggle_attr(e, eventType, phxEvent, view, sourceEl, el, { attr: [attr, val1, val2] }) {
      this.toggleAttr(el, attr, val1, val2);
    },
    exec_ignore_attrs(e, eventType, phxEvent, view, sourceEl, el, { attrs }) {
      this.ignoreAttrs(el, attrs);
    },
    exec_transition(e, eventType, phxEvent, view, sourceEl, el, { time, transition, blocking }) {
      this.addOrRemoveClasses(el, [], [], transition, time, view, blocking);
    },
    exec_toggle(e, eventType, phxEvent, view, sourceEl, el, { display, ins, outs, time, blocking }) {
      this.toggle(eventType, view, el, display, ins, outs, time, blocking);
    },
    exec_show(e, eventType, phxEvent, view, sourceEl, el, { display, transition, time, blocking }) {
      this.show(eventType, view, el, display, transition, time, blocking);
    },
    exec_hide(e, eventType, phxEvent, view, sourceEl, el, { display, transition, time, blocking }) {
      this.hide(eventType, view, el, display, transition, time, blocking);
    },
    exec_set_attr(e, eventType, phxEvent, view, sourceEl, el, { attr: [attr, val] }) {
      this.setOrRemoveAttrs(el, [[attr, val]], []);
    },
    exec_remove_attr(e, eventType, phxEvent, view, sourceEl, el, { attr }) {
      this.setOrRemoveAttrs(el, [], [attr]);
    },
    ignoreAttrs(el, attrs) {
      dom_default.putPrivate(el, "JS:ignore_attrs", {
        apply: (fromEl, toEl) => {
          Array.from(fromEl.attributes).forEach((attr) => {
            if (attrs.some(
              (toIgnore) => attr.name == toIgnore || toIgnore.includes("*") && attr.name.match(toIgnore) != null
            )) {
              toEl.setAttribute(attr.name, attr.value);
            }
          });
        }
      });
    },
    onBeforeElUpdated(fromEl, toEl) {
      const ignoreAttrs = dom_default.private(fromEl, "JS:ignore_attrs");
      if (ignoreAttrs) {
        ignoreAttrs.apply(fromEl, toEl);
      }
    },
    // utils for commands
    show(eventType, view, el, display, transition, time, blocking) {
      if (!this.isVisible(el)) {
        this.toggle(
          eventType,
          view,
          el,
          display,
          transition,
          null,
          time,
          blocking
        );
      }
    },
    hide(eventType, view, el, display, transition, time, blocking) {
      if (this.isVisible(el)) {
        this.toggle(
          eventType,
          view,
          el,
          display,
          null,
          transition,
          time,
          blocking
        );
      }
    },
    toggle(eventType, view, el, display, ins, outs, time, blocking) {
      time = time || default_transition_time;
      const [inClasses, inStartClasses, inEndClasses] = ins || [[], [], []];
      const [outClasses, outStartClasses, outEndClasses] = outs || [[], [], []];
      if (inClasses.length > 0 || outClasses.length > 0) {
        if (this.isVisible(el)) {
          const onStart = () => {
            this.addOrRemoveClasses(
              el,
              outStartClasses,
              inClasses.concat(inStartClasses).concat(inEndClasses)
            );
            window.requestAnimationFrame(() => {
              this.addOrRemoveClasses(el, outClasses, []);
              window.requestAnimationFrame(
                () => this.addOrRemoveClasses(el, outEndClasses, outStartClasses)
              );
            });
          };
          const onEnd = () => {
            this.addOrRemoveClasses(el, [], outClasses.concat(outEndClasses));
            dom_default.putSticky(
              el,
              "toggle",
              (currentEl) => currentEl.style.display = "none"
            );
            el.dispatchEvent(new Event("phx:hide-end"));
          };
          el.dispatchEvent(new Event("phx:hide-start"));
          if (blocking === false) {
            onStart();
            setTimeout(onEnd, time);
          } else {
            view.transition(time, onStart, onEnd);
          }
        } else {
          if (eventType === "remove") {
            return;
          }
          const onStart = () => {
            this.addOrRemoveClasses(
              el,
              inStartClasses,
              outClasses.concat(outStartClasses).concat(outEndClasses)
            );
            const stickyDisplay = display || this.defaultDisplay(el);
            window.requestAnimationFrame(() => {
              this.addOrRemoveClasses(el, inClasses, []);
              window.requestAnimationFrame(() => {
                dom_default.putSticky(
                  el,
                  "toggle",
                  (currentEl) => currentEl.style.display = stickyDisplay
                );
                this.addOrRemoveClasses(el, inEndClasses, inStartClasses);
              });
            });
          };
          const onEnd = () => {
            this.addOrRemoveClasses(el, [], inClasses.concat(inEndClasses));
            el.dispatchEvent(new Event("phx:show-end"));
          };
          el.dispatchEvent(new Event("phx:show-start"));
          if (blocking === false) {
            onStart();
            setTimeout(onEnd, time);
          } else {
            view.transition(time, onStart, onEnd);
          }
        }
      } else {
        if (this.isVisible(el)) {
          window.requestAnimationFrame(() => {
            el.dispatchEvent(new Event("phx:hide-start"));
            dom_default.putSticky(
              el,
              "toggle",
              (currentEl) => currentEl.style.display = "none"
            );
            el.dispatchEvent(new Event("phx:hide-end"));
          });
        } else {
          window.requestAnimationFrame(() => {
            el.dispatchEvent(new Event("phx:show-start"));
            const stickyDisplay = display || this.defaultDisplay(el);
            dom_default.putSticky(
              el,
              "toggle",
              (currentEl) => currentEl.style.display = stickyDisplay
            );
            el.dispatchEvent(new Event("phx:show-end"));
          });
        }
      }
    },
    toggleClasses(el, classes, transition, time, view, blocking) {
      window.requestAnimationFrame(() => {
        const [prevAdds, prevRemoves] = dom_default.getSticky(el, "classes", [[], []]);
        const newAdds = classes.filter(
          (name) => prevAdds.indexOf(name) < 0 && !el.classList.contains(name)
        );
        const newRemoves = classes.filter(
          (name) => prevRemoves.indexOf(name) < 0 && el.classList.contains(name)
        );
        this.addOrRemoveClasses(
          el,
          newAdds,
          newRemoves,
          transition,
          time,
          view,
          blocking
        );
      });
    },
    toggleAttr(el, attr, val1, val2) {
      if (el.hasAttribute(attr)) {
        if (val2 !== void 0) {
          if (el.getAttribute(attr) === val1) {
            this.setOrRemoveAttrs(el, [[attr, val2]], []);
          } else {
            this.setOrRemoveAttrs(el, [[attr, val1]], []);
          }
        } else {
          this.setOrRemoveAttrs(el, [], [attr]);
        }
      } else {
        this.setOrRemoveAttrs(el, [[attr, val1]], []);
      }
    },
    addOrRemoveClasses(el, adds, removes, transition, time, view, blocking) {
      time = time || default_transition_time;
      const [transitionRun, transitionStart, transitionEnd] = transition || [
        [],
        [],
        []
      ];
      if (transitionRun.length > 0) {
        const onStart = () => {
          this.addOrRemoveClasses(
            el,
            transitionStart,
            [].concat(transitionRun).concat(transitionEnd)
          );
          window.requestAnimationFrame(() => {
            this.addOrRemoveClasses(el, transitionRun, []);
            window.requestAnimationFrame(
              () => this.addOrRemoveClasses(el, transitionEnd, transitionStart)
            );
          });
        };
        const onDone = () => this.addOrRemoveClasses(
          el,
          adds.concat(transitionEnd),
          removes.concat(transitionRun).concat(transitionStart)
        );
        if (blocking === false) {
          onStart();
          setTimeout(onDone, time);
        } else {
          view.transition(time, onStart, onDone);
        }
        return;
      }
      window.requestAnimationFrame(() => {
        const [prevAdds, prevRemoves] = dom_default.getSticky(el, "classes", [[], []]);
        const keepAdds = adds.filter(
          (name) => prevAdds.indexOf(name) < 0 && !el.classList.contains(name)
        );
        const keepRemoves = removes.filter(
          (name) => prevRemoves.indexOf(name) < 0 && el.classList.contains(name)
        );
        const newAdds = prevAdds.filter((name) => removes.indexOf(name) < 0).concat(keepAdds);
        const newRemoves = prevRemoves.filter((name) => adds.indexOf(name) < 0).concat(keepRemoves);
        dom_default.putSticky(el, "classes", (currentEl) => {
          currentEl.classList.remove(...newRemoves);
          currentEl.classList.add(...newAdds);
          return [newAdds, newRemoves];
        });
      });
    },
    setOrRemoveAttrs(el, sets, removes) {
      const [prevSets, prevRemoves] = dom_default.getSticky(el, "attrs", [[], []]);
      const alteredAttrs = sets.map(([attr, _val]) => attr).concat(removes);
      const newSets = prevSets.filter(([attr, _val]) => !alteredAttrs.includes(attr)).concat(sets);
      const newRemoves = prevRemoves.filter((attr) => !alteredAttrs.includes(attr)).concat(removes);
      dom_default.putSticky(el, "attrs", (currentEl) => {
        newRemoves.forEach((attr) => currentEl.removeAttribute(attr));
        newSets.forEach(([attr, val]) => currentEl.setAttribute(attr, val));
        return [newSets, newRemoves];
      });
    },
    hasAllClasses(el, classes) {
      return classes.every((name) => el.classList.contains(name));
    },
    isToggledOut(el, outClasses) {
      return !this.isVisible(el) || this.hasAllClasses(el, outClasses);
    },
    filterToEls(liveSocket2, sourceEl, { to }) {
      const defaultQuery = () => {
        if (typeof to === "string") {
          return document.querySelectorAll(to);
        } else if (to.closest) {
          const toEl = sourceEl.closest(to.closest);
          return toEl ? [toEl] : [];
        } else if (to.inner) {
          return sourceEl.querySelectorAll(to.inner);
        }
      };
      return to ? liveSocket2.jsQuerySelectorAll(sourceEl, to, defaultQuery) : [sourceEl];
    },
    defaultDisplay(el) {
      return { tr: "table-row", td: "table-cell" }[el.tagName.toLowerCase()] || "block";
    },
    transitionClasses(val) {
      if (!val) {
        return null;
      }
      let [trans, tStart, tEnd] = Array.isArray(val) ? val : [val.split(" "), [], []];
      trans = Array.isArray(trans) ? trans : trans.split(" ");
      tStart = Array.isArray(tStart) ? tStart : tStart.split(" ");
      tEnd = Array.isArray(tEnd) ? tEnd : tEnd.split(" ");
      return [trans, tStart, tEnd];
    }
  };
  var js_default = JS;
  var js_commands_default = (liveSocket2, eventType) => {
    return {
      exec(el, encodedJS) {
        liveSocket2.execJS(el, encodedJS, eventType);
      },
      show(el, opts = {}) {
        const owner = liveSocket2.owner(el);
        js_default.show(
          eventType,
          owner,
          el,
          opts.display,
          js_default.transitionClasses(opts.transition),
          opts.time,
          opts.blocking
        );
      },
      hide(el, opts = {}) {
        const owner = liveSocket2.owner(el);
        js_default.hide(
          eventType,
          owner,
          el,
          null,
          js_default.transitionClasses(opts.transition),
          opts.time,
          opts.blocking
        );
      },
      toggle(el, opts = {}) {
        const owner = liveSocket2.owner(el);
        const inTransition = js_default.transitionClasses(opts.in);
        const outTransition = js_default.transitionClasses(opts.out);
        js_default.toggle(
          eventType,
          owner,
          el,
          opts.display,
          inTransition,
          outTransition,
          opts.time,
          opts.blocking
        );
      },
      addClass(el, names, opts = {}) {
        const classNames = Array.isArray(names) ? names : names.split(" ");
        const owner = liveSocket2.owner(el);
        js_default.addOrRemoveClasses(
          el,
          classNames,
          [],
          js_default.transitionClasses(opts.transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      removeClass(el, names, opts = {}) {
        const classNames = Array.isArray(names) ? names : names.split(" ");
        const owner = liveSocket2.owner(el);
        js_default.addOrRemoveClasses(
          el,
          [],
          classNames,
          js_default.transitionClasses(opts.transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      toggleClass(el, names, opts = {}) {
        const classNames = Array.isArray(names) ? names : names.split(" ");
        const owner = liveSocket2.owner(el);
        js_default.toggleClasses(
          el,
          classNames,
          js_default.transitionClasses(opts.transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      transition(el, transition, opts = {}) {
        const owner = liveSocket2.owner(el);
        js_default.addOrRemoveClasses(
          el,
          [],
          [],
          js_default.transitionClasses(transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      setAttribute(el, attr, val) {
        js_default.setOrRemoveAttrs(el, [[attr, val]], []);
      },
      removeAttribute(el, attr) {
        js_default.setOrRemoveAttrs(el, [], [attr]);
      },
      toggleAttribute(el, attr, val1, val2) {
        js_default.toggleAttr(el, attr, val1, val2);
      },
      push(el, type, opts = {}) {
        liveSocket2.withinOwners(el, (view) => {
          const data = opts.value || {};
          delete opts.value;
          let e = new CustomEvent("phx:exec", { detail: { sourceElement: el } });
          js_default.exec(e, eventType, type, view, el, ["push", __spreadValues({ data }, opts)]);
        });
      },
      navigate(href, opts = {}) {
        const customEvent = new CustomEvent("phx:exec");
        liveSocket2.historyRedirect(
          customEvent,
          href,
          opts.replace ? "replace" : "push",
          null,
          null
        );
      },
      patch(href, opts = {}) {
        const customEvent = new CustomEvent("phx:exec");
        liveSocket2.pushHistoryPatch(
          customEvent,
          href,
          opts.replace ? "replace" : "push",
          null
        );
      },
      ignoreAttributes(el, attrs) {
        js_default.ignoreAttrs(el, Array.isArray(attrs) ? attrs : [attrs]);
      }
    };
  };
  var HOOK_ID = "hookId";
  var viewHookID = 1;
  var ViewHook = class _ViewHook {
    static makeID() {
      return viewHookID++;
    }
    static elementID(el) {
      return dom_default.private(el, HOOK_ID);
    }
    constructor(view, el, callbacks) {
      this.el = el;
      this.__attachView(view);
      this.__listeners = /* @__PURE__ */ new Set();
      this.__isDisconnected = false;
      dom_default.putPrivate(this.el, HOOK_ID, _ViewHook.makeID());
      if (callbacks) {
        const protectedProps = /* @__PURE__ */ new Set([
          "el",
          "liveSocket",
          "__view",
          "__listeners",
          "__isDisconnected",
          "constructor",
          // Standard object properties
          // Core ViewHook API methods
          "js",
          "pushEvent",
          "pushEventTo",
          "handleEvent",
          "removeHandleEvent",
          "upload",
          "uploadTo",
          // Internal lifecycle callers
          "__mounted",
          "__updated",
          "__beforeUpdate",
          "__destroyed",
          "__reconnected",
          "__disconnected",
          "__cleanup__"
        ]);
        for (const key in callbacks) {
          if (Object.prototype.hasOwnProperty.call(callbacks, key)) {
            this[key] = callbacks[key];
            if (protectedProps.has(key)) {
              console.warn(
                `Hook object for element #${el.id} overwrites core property '${key}'!`
              );
            }
          }
        }
        const lifecycleMethods = [
          "mounted",
          "beforeUpdate",
          "updated",
          "destroyed",
          "disconnected",
          "reconnected"
        ];
        lifecycleMethods.forEach((methodName) => {
          if (callbacks[methodName] && typeof callbacks[methodName] === "function") {
            this[methodName] = callbacks[methodName];
          }
        });
      }
    }
    /** @internal */
    __attachView(view) {
      if (view) {
        this.__view = () => view;
        this.liveSocket = view.liveSocket;
      } else {
        this.__view = () => {
          throw new Error(
            `hook not yet attached to a live view: ${this.el.outerHTML}`
          );
        };
        this.liveSocket = null;
      }
    }
    // Default lifecycle methods
    mounted() {
    }
    beforeUpdate() {
    }
    updated() {
    }
    destroyed() {
    }
    disconnected() {
    }
    reconnected() {
    }
    // Internal lifecycle callers - called by the View
    /** @internal */
    __mounted() {
      this.mounted();
    }
    /** @internal */
    __updated() {
      this.updated();
    }
    /** @internal */
    __beforeUpdate() {
      this.beforeUpdate();
    }
    /** @internal */
    __destroyed() {
      this.destroyed();
      dom_default.deletePrivate(this.el, HOOK_ID);
    }
    /** @internal */
    __reconnected() {
      if (this.__isDisconnected) {
        this.__isDisconnected = false;
        this.reconnected();
      }
    }
    /** @internal */
    __disconnected() {
      this.__isDisconnected = true;
      this.disconnected();
    }
    js() {
      return __spreadProps(__spreadValues({}, js_commands_default(this.__view().liveSocket, "hook")), {
        exec: (encodedJS) => {
          this.__view().liveSocket.execJS(this.el, encodedJS, "hook");
        }
      });
    }
    pushEvent(event, payload, onReply) {
      const promise = this.__view().pushHookEvent(
        this.el,
        null,
        event,
        payload || {}
      );
      if (onReply === void 0) {
        return promise.then(({ reply }) => reply);
      }
      promise.then(({ reply, ref }) => onReply(reply, ref)).catch(() => {
      });
      return;
    }
    pushEventTo(selectorOrTarget, event, payload, onReply) {
      if (onReply === void 0) {
        const targetPair = [];
        this.__view().withinTargets(selectorOrTarget, (view, targetCtx) => {
          targetPair.push({ view, targetCtx });
        });
        const promises = targetPair.map(({ view, targetCtx }) => {
          return view.pushHookEvent(this.el, targetCtx, event, payload || {});
        });
        return Promise.allSettled(promises);
      }
      this.__view().withinTargets(selectorOrTarget, (view, targetCtx) => {
        view.pushHookEvent(this.el, targetCtx, event, payload || {}).then(({ reply, ref }) => onReply(reply, ref)).catch(() => {
        });
      });
      return;
    }
    handleEvent(event, callback) {
      const callbackRef = {
        event,
        callback: (customEvent) => callback(customEvent.detail)
      };
      window.addEventListener(
        `phx:${event}`,
        callbackRef.callback
      );
      this.__listeners.add(callbackRef);
      return callbackRef;
    }
    removeHandleEvent(ref) {
      window.removeEventListener(
        `phx:${ref.event}`,
        ref.callback
      );
      this.__listeners.delete(ref);
    }
    upload(name, files) {
      return this.__view().dispatchUploads(null, name, files);
    }
    uploadTo(selectorOrTarget, name, files) {
      return this.__view().withinTargets(selectorOrTarget, (view, targetCtx) => {
        view.dispatchUploads(targetCtx, name, files);
      });
    }
    /** @internal */
    __cleanup__() {
      this.__listeners.forEach(
        (callbackRef) => this.removeHandleEvent(callbackRef)
      );
    }
  };
  var prependFormDataKey = (key, prefix) => {
    const isArray = key.endsWith("[]");
    let baseKey = isArray ? key.slice(0, -2) : key;
    baseKey = baseKey.replace(/([^\[\]]+)(\]?$)/, `${prefix}$1$2`);
    if (isArray) {
      baseKey += "[]";
    }
    return baseKey;
  };
  var serializeForm = (form, opts, onlyNames = []) => {
    const { submitter } = opts;
    let injectedElement;
    if (submitter && submitter.name) {
      const input = document.createElement("input");
      input.type = "hidden";
      const formId = submitter.getAttribute("form");
      if (formId) {
        input.setAttribute("form", formId);
      }
      input.name = submitter.name;
      input.value = submitter.value;
      submitter.parentElement.insertBefore(input, submitter);
      injectedElement = input;
    }
    const formData = new FormData(form);
    const toRemove = [];
    formData.forEach((val, key, _index) => {
      if (val instanceof File) {
        toRemove.push(key);
      }
    });
    toRemove.forEach((key) => formData.delete(key));
    const params = new URLSearchParams();
    const { inputsUnused, onlyHiddenInputs } = Array.from(form.elements).reduce(
      (acc, input) => {
        const { inputsUnused: inputsUnused2, onlyHiddenInputs: onlyHiddenInputs2 } = acc;
        const key = input.name;
        if (!key) {
          return acc;
        }
        if (inputsUnused2[key] === void 0) {
          inputsUnused2[key] = true;
        }
        if (onlyHiddenInputs2[key] === void 0) {
          onlyHiddenInputs2[key] = true;
        }
        const isUsed = dom_default.private(input, PHX_HAS_FOCUSED) || dom_default.private(input, PHX_HAS_SUBMITTED);
        const isHidden = input.type === "hidden";
        inputsUnused2[key] = inputsUnused2[key] && !isUsed;
        onlyHiddenInputs2[key] = onlyHiddenInputs2[key] && isHidden;
        return acc;
      },
      { inputsUnused: {}, onlyHiddenInputs: {} }
    );
    for (const [key, val] of formData.entries()) {
      if (onlyNames.length === 0 || onlyNames.indexOf(key) >= 0) {
        const isUnused = inputsUnused[key];
        const hidden = onlyHiddenInputs[key];
        if (isUnused && !(submitter && submitter.name == key) && !hidden) {
          params.append(prependFormDataKey(key, "_unused_"), "");
        }
        if (typeof val === "string") {
          params.append(key, val);
        }
      }
    }
    if (submitter && injectedElement) {
      submitter.parentElement.removeChild(injectedElement);
    }
    return params.toString();
  };
  var View = class _View {
    static closestView(el) {
      const liveViewEl = el.closest(PHX_VIEW_SELECTOR);
      return liveViewEl ? dom_default.private(liveViewEl, "view") : null;
    }
    constructor(el, liveSocket2, parentView, flash, liveReferer) {
      this.isDead = false;
      this.liveSocket = liveSocket2;
      this.flash = flash;
      this.parent = parentView;
      this.root = parentView ? parentView.root : this;
      this.el = el;
      const boundView = dom_default.private(this.el, "view");
      if (boundView !== void 0 && boundView.isDead !== true) {
        logError(
          `The DOM element for this view has already been bound to a view.

        An element can only ever be associated with a single view!
        Please ensure that you are not trying to initialize multiple LiveSockets on the same page.
        This could happen if you're accidentally trying to render your root layout more than once.
        Ensure that the template set on the LiveView is different than the root layout.
      `,
          { view: boundView }
        );
        throw new Error("Cannot bind multiple views to the same DOM element.");
      }
      dom_default.putPrivate(this.el, "view", this);
      this.id = this.el.id;
      this.ref = 0;
      this.lastAckRef = null;
      this.childJoins = 0;
      this.loaderTimer = null;
      this.disconnectedTimer = null;
      this.pendingDiffs = [];
      this.pendingForms = /* @__PURE__ */ new Set();
      this.redirect = false;
      this.href = null;
      this.joinCount = this.parent ? this.parent.joinCount - 1 : 0;
      this.joinAttempts = 0;
      this.joinPending = true;
      this.destroyed = false;
      this.joinCallback = function(onDone) {
        onDone && onDone();
      };
      this.stopCallback = function() {
      };
      this.pendingJoinOps = this.parent ? null : [];
      this.viewHooks = {};
      this.formSubmits = [];
      this.children = this.parent ? null : {};
      this.root.children[this.id] = {};
      this.formsForRecovery = {};
      this.channel = this.liveSocket.channel(`lv:${this.id}`, () => {
        const url = this.href && this.expandURL(this.href);
        return {
          redirect: this.redirect ? url : void 0,
          url: this.redirect ? void 0 : url || void 0,
          params: this.connectParams(liveReferer),
          session: this.getSession(),
          static: this.getStatic(),
          flash: this.flash,
          sticky: this.el.hasAttribute(PHX_STICKY)
        };
      });
      this.portalElementIds = /* @__PURE__ */ new Set();
    }
    setHref(href) {
      this.href = href;
    }
    setRedirect(href) {
      this.redirect = true;
      this.href = href;
    }
    isMain() {
      return this.el.hasAttribute(PHX_MAIN);
    }
    connectParams(liveReferer) {
      const params = this.liveSocket.params(this.el);
      const manifest = dom_default.all(document, `[${this.binding(PHX_TRACK_STATIC)}]`).map((node) => node.src || node.href).filter((url) => typeof url === "string");
      if (manifest.length > 0) {
        params["_track_static"] = manifest;
      }
      params["_mounts"] = this.joinCount;
      params["_mount_attempts"] = this.joinAttempts;
      params["_live_referer"] = liveReferer;
      this.joinAttempts++;
      return params;
    }
    isConnected() {
      return this.channel.canPush();
    }
    getSession() {
      return this.el.getAttribute(PHX_SESSION);
    }
    getStatic() {
      const val = this.el.getAttribute(PHX_STATIC);
      return val === "" ? null : val;
    }
    destroy(callback = function() {
    }) {
      this.destroyAllChildren();
      this.destroyPortalElements();
      this.destroyed = true;
      dom_default.deletePrivate(this.el, "view");
      delete this.root.children[this.id];
      if (this.parent) {
        delete this.root.children[this.parent.id][this.id];
      }
      clearTimeout(this.loaderTimer);
      const onFinished = () => {
        callback();
        for (const id in this.viewHooks) {
          this.destroyHook(this.viewHooks[id]);
        }
      };
      dom_default.markPhxChildDestroyed(this.el);
      this.log("destroyed", () => ["the child has been removed from the parent"]);
      this.channel.leave().receive("ok", onFinished).receive("error", onFinished).receive("timeout", onFinished);
    }
    setContainerClasses(...classes) {
      this.el.classList.remove(
        PHX_CONNECTED_CLASS,
        PHX_LOADING_CLASS,
        PHX_ERROR_CLASS,
        PHX_CLIENT_ERROR_CLASS,
        PHX_SERVER_ERROR_CLASS
      );
      this.el.classList.add(...classes);
    }
    showLoader(timeout) {
      clearTimeout(this.loaderTimer);
      if (timeout) {
        this.loaderTimer = setTimeout(() => this.showLoader(), timeout);
      } else {
        for (const id in this.viewHooks) {
          this.viewHooks[id].__disconnected();
        }
        this.setContainerClasses(PHX_LOADING_CLASS);
      }
    }
    execAll(binding) {
      dom_default.all(
        this.el,
        `[${binding}]`,
        (el) => this.liveSocket.execJS(el, el.getAttribute(binding))
      );
    }
    hideLoader() {
      clearTimeout(this.loaderTimer);
      clearTimeout(this.disconnectedTimer);
      this.setContainerClasses(PHX_CONNECTED_CLASS);
      this.execAll(this.binding("connected"));
    }
    triggerReconnected() {
      for (const id in this.viewHooks) {
        this.viewHooks[id].__reconnected();
      }
    }
    log(kind, msgCallback) {
      this.liveSocket.log(this, kind, msgCallback);
    }
    transition(time, onStart, onDone = function() {
    }) {
      this.liveSocket.transition(time, onStart, onDone);
    }
    // calls the callback with the view and target element for the given phxTarget
    // targets can be:
    //  * an element itself, then it is simply passed to liveSocket.owner;
    //  * a CID (Component ID), then we first search the component's element in the DOM
    //  * a selector, then we search the selector in the DOM and call the callback
    //    for each element found with the corresponding owner view
    withinTargets(phxTarget, callback, dom = document) {
      if (phxTarget instanceof HTMLElement || phxTarget instanceof SVGElement) {
        return this.liveSocket.owner(
          phxTarget,
          (view) => callback(view, phxTarget)
        );
      }
      if (isCid(phxTarget)) {
        const targets = dom_default.findComponentNodeList(this.id, phxTarget, dom);
        if (targets.length === 0) {
          logError(`no component found matching phx-target of ${phxTarget}`);
        } else {
          callback(this, parseInt(phxTarget));
        }
      } else {
        const targets = Array.from(dom.querySelectorAll(phxTarget));
        if (targets.length === 0) {
          logError(
            `nothing found matching the phx-target selector "${phxTarget}"`
          );
        }
        targets.forEach(
          (target) => this.liveSocket.owner(target, (view) => callback(view, target))
        );
      }
    }
    applyDiff(type, rawDiff, callback) {
      this.log(type, () => ["", clone(rawDiff)]);
      const { diff, reply, events, title } = Rendered.extract(rawDiff);
      callback({ diff, reply, events });
      if (typeof title === "string" || type == "mount") {
        window.requestAnimationFrame(() => dom_default.putTitle(title));
      }
    }
    onJoin(resp) {
      const { rendered, container, liveview_version, pid } = resp;
      if (container) {
        const [tag, attrs] = container;
        this.el = dom_default.replaceRootContainer(this.el, tag, attrs);
      }
      this.childJoins = 0;
      this.joinPending = true;
      this.flash = null;
      if (this.root === this) {
        this.formsForRecovery = this.getFormsForRecovery();
      }
      if (this.isMain() && window.history.state === null) {
        browser_default.pushState("replace", {
          type: "patch",
          id: this.id,
          position: this.liveSocket.currentHistoryPosition
        });
      }
      if (liveview_version !== this.liveSocket.version()) {
        console.error(
          `LiveView asset version mismatch. JavaScript version ${this.liveSocket.version()} vs. server ${liveview_version}. To avoid issues, please ensure that your assets use the same version as the server.`
        );
      }
      if (pid) {
        this.el.setAttribute(PHX_LV_PID, pid);
      }
      browser_default.dropLocal(
        this.liveSocket.localStorage,
        window.location.pathname,
        CONSECUTIVE_RELOADS
      );
      this.applyDiff("mount", rendered, ({ diff, events }) => {
        this.rendered = new Rendered(this.id, diff);
        const [html, streams] = this.renderContainer(null, "join");
        this.dropPendingRefs();
        this.joinCount++;
        this.joinAttempts = 0;
        this.maybeRecoverForms(html, () => {
          this.onJoinComplete(resp, html, streams, events);
        });
      });
    }
    dropPendingRefs() {
      dom_default.all(document, `[${PHX_REF_SRC}="${this.refSrc()}"]`, (el) => {
        el.removeAttribute(PHX_REF_LOADING);
        el.removeAttribute(PHX_REF_SRC);
        el.removeAttribute(PHX_REF_LOCK);
      });
    }
    onJoinComplete({ live_patch }, html, streams, events) {
      if (this.joinCount > 1 || this.parent && !this.parent.isJoinPending()) {
        return this.applyJoinPatch(live_patch, html, streams, events);
      }
      const newChildren = dom_default.findPhxChildrenInFragment(html, this.id).filter(
        (toEl) => {
          const fromEl = toEl.id && this.el.querySelector(`[id="${toEl.id}"]`);
          const phxStatic = fromEl && fromEl.getAttribute(PHX_STATIC);
          if (phxStatic) {
            toEl.setAttribute(PHX_STATIC, phxStatic);
          }
          if (fromEl) {
            fromEl.setAttribute(PHX_ROOT_ID, this.root.id);
          }
          return this.joinChild(toEl);
        }
      );
      if (newChildren.length === 0) {
        if (this.parent) {
          this.root.pendingJoinOps.push([
            this,
            () => this.applyJoinPatch(live_patch, html, streams, events)
          ]);
          this.parent.ackJoin(this);
        } else {
          this.onAllChildJoinsComplete();
          this.applyJoinPatch(live_patch, html, streams, events);
        }
      } else {
        this.root.pendingJoinOps.push([
          this,
          () => this.applyJoinPatch(live_patch, html, streams, events)
        ]);
      }
    }
    attachTrueDocEl() {
      this.el = dom_default.byId(this.id);
      this.el.setAttribute(PHX_ROOT_ID, this.root.id);
    }
    // this is invoked for dead and live views, so we must filter by
    // by owner to ensure we aren't duplicating hooks across disconnect
    // and connected states. This also handles cases where hooks exist
    // in a root layout with a LV in the body
    execNewMounted(parent = document) {
      let phxViewportTop = this.binding(PHX_VIEWPORT_TOP);
      let phxViewportBottom = this.binding(PHX_VIEWPORT_BOTTOM);
      this.all(
        parent,
        `[${phxViewportTop}], [${phxViewportBottom}]`,
        (hookEl) => {
          dom_default.maintainPrivateHooks(
            hookEl,
            hookEl,
            phxViewportTop,
            phxViewportBottom
          );
          this.maybeAddNewHook(hookEl);
        }
      );
      this.all(
        parent,
        `[${this.binding(PHX_HOOK)}], [data-phx-${PHX_HOOK}]`,
        (hookEl) => {
          this.maybeAddNewHook(hookEl);
        }
      );
      this.all(parent, `[${this.binding(PHX_MOUNTED)}]`, (el) => {
        this.maybeMounted(el);
      });
    }
    all(parent, selector, callback) {
      dom_default.all(parent, selector, (el) => {
        if (this.ownsElement(el)) {
          callback(el);
        }
      });
    }
    applyJoinPatch(live_patch, html, streams, events) {
      this.attachTrueDocEl();
      const patch = new DOMPatch(this, this.el, this.id, html, streams, null);
      patch.markPrunableContentForRemoval();
      this.performPatch(patch, false, true);
      this.joinNewChildren();
      this.execNewMounted();
      this.joinPending = false;
      this.liveSocket.dispatchEvents(events);
      this.applyPendingUpdates();
      if (live_patch) {
        const { kind, to } = live_patch;
        this.liveSocket.historyPatch(to, kind);
      }
      this.hideLoader();
      if (this.joinCount > 1) {
        this.triggerReconnected();
      }
      this.stopCallback();
    }
    triggerBeforeUpdateHook(fromEl, toEl) {
      this.liveSocket.triggerDOM("onBeforeElUpdated", [fromEl, toEl]);
      const hook = this.getHook(fromEl);
      const isIgnored = hook && dom_default.isIgnored(fromEl, this.binding(PHX_UPDATE));
      if (hook && !fromEl.isEqualNode(toEl) && !(isIgnored && isEqualObj(fromEl.dataset, toEl.dataset))) {
        hook.__beforeUpdate();
        return hook;
      }
    }
    maybeMounted(el) {
      const phxMounted = el.getAttribute(this.binding(PHX_MOUNTED));
      const hasBeenInvoked = phxMounted && dom_default.private(el, "mounted");
      if (phxMounted && !hasBeenInvoked) {
        this.liveSocket.execJS(el, phxMounted);
        dom_default.putPrivate(el, "mounted", true);
      }
    }
    maybeAddNewHook(el) {
      const newHook = this.addHook(el);
      if (newHook) {
        newHook.__mounted();
      }
    }
    performPatch(patch, pruneCids, isJoinPatch = false) {
      const removedEls = [];
      let phxChildrenAdded = false;
      const updatedHookIds = /* @__PURE__ */ new Set();
      this.liveSocket.triggerDOM("onPatchStart", [patch.targetContainer]);
      patch.after("added", (el) => {
        this.liveSocket.triggerDOM("onNodeAdded", [el]);
        const phxViewportTop = this.binding(PHX_VIEWPORT_TOP);
        const phxViewportBottom = this.binding(PHX_VIEWPORT_BOTTOM);
        dom_default.maintainPrivateHooks(el, el, phxViewportTop, phxViewportBottom);
        this.maybeAddNewHook(el);
        if (el.getAttribute) {
          this.maybeMounted(el);
        }
      });
      patch.after("phxChildAdded", (el) => {
        if (dom_default.isPhxSticky(el)) {
          this.liveSocket.joinRootViews();
        } else {
          phxChildrenAdded = true;
        }
      });
      patch.before("updated", (fromEl, toEl) => {
        const hook = this.triggerBeforeUpdateHook(fromEl, toEl);
        if (hook) {
          updatedHookIds.add(fromEl.id);
        }
        js_default.onBeforeElUpdated(fromEl, toEl);
      });
      patch.after("updated", (el) => {
        if (updatedHookIds.has(el.id)) {
          this.getHook(el).__updated();
        }
      });
      patch.after("discarded", (el) => {
        if (el.nodeType === Node.ELEMENT_NODE) {
          removedEls.push(el);
        }
      });
      patch.after(
        "transitionsDiscarded",
        (els) => this.afterElementsRemoved(els, pruneCids)
      );
      patch.perform(isJoinPatch);
      this.afterElementsRemoved(removedEls, pruneCids);
      this.liveSocket.triggerDOM("onPatchEnd", [patch.targetContainer]);
      return phxChildrenAdded;
    }
    afterElementsRemoved(elements, pruneCids) {
      const destroyedCIDs = [];
      elements.forEach((parent) => {
        const components = dom_default.all(parent, `[${PHX_COMPONENT}]`);
        const hooks = dom_default.all(
          parent,
          `[${this.binding(PHX_HOOK)}], [data-phx-hook]`
        );
        components.concat(parent).forEach((el) => {
          const cid = this.componentID(el);
          if (isCid(cid) && destroyedCIDs.indexOf(cid) === -1) {
            destroyedCIDs.push(cid);
          }
        });
        hooks.concat(parent).forEach((hookEl) => {
          const hook = this.getHook(hookEl);
          hook && this.destroyHook(hook);
        });
      });
      if (pruneCids) {
        this.maybePushComponentsDestroyed(destroyedCIDs);
      }
    }
    joinNewChildren() {
      dom_default.findPhxChildren(document, this.id).forEach((el) => this.joinChild(el));
    }
    maybeRecoverForms(html, callback) {
      const phxChange = this.binding("change");
      const oldForms = this.root.formsForRecovery;
      const template = document.createElement("template");
      template.innerHTML = html;
      const rootEl = template.content.firstElementChild;
      rootEl.id = this.id;
      rootEl.setAttribute(PHX_ROOT_ID, this.root.id);
      rootEl.setAttribute(PHX_SESSION, this.getSession());
      rootEl.setAttribute(PHX_STATIC, this.getStatic());
      rootEl.setAttribute(PHX_PARENT_ID, this.parent ? this.parent.id : null);
      const formsToRecover = (
        // we go over all forms in the new DOM; because this is only the HTML for the current
        // view, we can be sure that all forms are owned by this view:
        dom_default.all(template.content, "form").filter((newForm) => newForm.id && oldForms[newForm.id]).filter((newForm) => !this.pendingForms.has(newForm.id)).filter(
          (newForm) => oldForms[newForm.id].getAttribute(phxChange) === newForm.getAttribute(phxChange)
        ).map((newForm) => {
          return [oldForms[newForm.id], newForm];
        })
      );
      if (formsToRecover.length === 0) {
        return callback();
      }
      formsToRecover.forEach(([oldForm, newForm], i) => {
        this.pendingForms.add(newForm.id);
        this.pushFormRecovery(
          oldForm,
          newForm,
          template.content.firstElementChild,
          () => {
            this.pendingForms.delete(newForm.id);
            if (i === formsToRecover.length - 1) {
              callback();
            }
          }
        );
      });
    }
    getChildById(id) {
      return this.root.children[this.id][id];
    }
    getDescendentByEl(el) {
      var _a;
      if (el.id === this.id) {
        return this;
      } else {
        return (_a = this.children[el.getAttribute(PHX_PARENT_ID)]) == null ? void 0 : _a[el.id];
      }
    }
    destroyDescendent(id) {
      for (const parentId in this.root.children) {
        for (const childId in this.root.children[parentId]) {
          if (childId === id) {
            return this.root.children[parentId][childId].destroy();
          }
        }
      }
    }
    joinChild(el) {
      const child = this.getChildById(el.id);
      if (!child) {
        const view = new _View(el, this.liveSocket, this);
        this.root.children[this.id][view.id] = view;
        view.join();
        this.childJoins++;
        return true;
      }
    }
    isJoinPending() {
      return this.joinPending;
    }
    ackJoin(_child) {
      this.childJoins--;
      if (this.childJoins === 0) {
        if (this.parent) {
          this.parent.ackJoin(this);
        } else {
          this.onAllChildJoinsComplete();
        }
      }
    }
    onAllChildJoinsComplete() {
      this.pendingForms.clear();
      this.formsForRecovery = {};
      this.joinCallback(() => {
        this.pendingJoinOps.forEach(([view, op]) => {
          if (!view.isDestroyed()) {
            op();
          }
        });
        this.pendingJoinOps = [];
      });
    }
    update(diff, events) {
      if (this.isJoinPending() || this.liveSocket.hasPendingLink() && this.root.isMain()) {
        return this.pendingDiffs.push({ diff, events });
      }
      this.rendered.mergeDiff(diff);
      let phxChildrenAdded = false;
      if (this.rendered.isComponentOnlyDiff(diff)) {
        this.liveSocket.time("component patch complete", () => {
          const parentCids = dom_default.findExistingParentCIDs(
            this.id,
            this.rendered.componentCIDs(diff)
          );
          parentCids.forEach((parentCID) => {
            if (this.componentPatch(
              this.rendered.getComponent(diff, parentCID),
              parentCID
            )) {
              phxChildrenAdded = true;
            }
          });
        });
      } else if (!isEmpty(diff)) {
        this.liveSocket.time("full patch complete", () => {
          const [html, streams] = this.renderContainer(diff, "update");
          const patch = new DOMPatch(this, this.el, this.id, html, streams, null);
          phxChildrenAdded = this.performPatch(patch, true);
        });
      }
      this.liveSocket.dispatchEvents(events);
      if (phxChildrenAdded) {
        this.joinNewChildren();
      }
    }
    renderContainer(diff, kind) {
      return this.liveSocket.time(`toString diff (${kind})`, () => {
        const tag = this.el.tagName;
        const cids = diff ? this.rendered.componentCIDs(diff) : null;
        const { buffer: html, streams } = this.rendered.toString(cids);
        return [`<${tag}>${html}</${tag}>`, streams];
      });
    }
    componentPatch(diff, cid) {
      if (isEmpty(diff))
        return false;
      const { buffer: html, streams } = this.rendered.componentToString(cid);
      const patch = new DOMPatch(this, this.el, this.id, html, streams, cid);
      const childrenAdded = this.performPatch(patch, true);
      return childrenAdded;
    }
    getHook(el) {
      return this.viewHooks[ViewHook.elementID(el)];
    }
    addHook(el) {
      const hookElId = ViewHook.elementID(el);
      if (el.getAttribute && !this.ownsElement(el)) {
        return;
      }
      if (hookElId && !this.viewHooks[hookElId]) {
        const hook = dom_default.getCustomElHook(el) || logError(`no hook found for custom element: ${el.id}`);
        this.viewHooks[hookElId] = hook;
        hook.__attachView(this);
        return hook;
      } else if (hookElId || !el.getAttribute) {
        return;
      } else {
        const hookName = el.getAttribute(`data-phx-${PHX_HOOK}`) || el.getAttribute(this.binding(PHX_HOOK));
        if (!hookName) {
          return;
        }
        const hookDefinition = this.liveSocket.getHookDefinition(hookName);
        if (hookDefinition) {
          if (!el.id) {
            logError(
              `no DOM ID for hook "${hookName}". Hooks require a unique ID on each element.`,
              el
            );
            return;
          }
          let hookInstance;
          try {
            if (typeof hookDefinition === "function" && hookDefinition.prototype instanceof ViewHook) {
              hookInstance = new hookDefinition(this, el);
            } else if (typeof hookDefinition === "object" && hookDefinition !== null) {
              hookInstance = new ViewHook(this, el, hookDefinition);
            } else {
              logError(
                `Invalid hook definition for "${hookName}". Expected a class extending ViewHook or an object definition.`,
                el
              );
              return;
            }
          } catch (e) {
            const errorMessage = e instanceof Error ? e.message : String(e);
            logError(`Failed to create hook "${hookName}": ${errorMessage}`, el);
            return;
          }
          this.viewHooks[ViewHook.elementID(hookInstance.el)] = hookInstance;
          return hookInstance;
        } else if (hookName !== null) {
          logError(`unknown hook found for "${hookName}"`, el);
        }
      }
    }
    destroyHook(hook) {
      const hookId = ViewHook.elementID(hook.el);
      hook.__destroyed();
      hook.__cleanup__();
      delete this.viewHooks[hookId];
    }
    applyPendingUpdates() {
      if (this.liveSocket.hasPendingLink() && this.root.isMain()) {
        return;
      }
      this.pendingDiffs.forEach(({ diff, events }) => this.update(diff, events));
      this.pendingDiffs = [];
      this.eachChild((child) => child.applyPendingUpdates());
    }
    eachChild(callback) {
      const children = this.root.children[this.id] || {};
      for (const id in children) {
        callback(this.getChildById(id));
      }
    }
    onChannel(event, cb) {
      this.liveSocket.onChannel(this.channel, event, (resp) => {
        if (this.isJoinPending()) {
          this.root.pendingJoinOps.push([this, () => cb(resp)]);
        } else {
          this.liveSocket.requestDOMUpdate(() => cb(resp));
        }
      });
    }
    bindChannel() {
      this.liveSocket.onChannel(this.channel, "diff", (rawDiff) => {
        this.liveSocket.requestDOMUpdate(() => {
          this.applyDiff(
            "update",
            rawDiff,
            ({ diff, events }) => this.update(diff, events)
          );
        });
      });
      this.onChannel(
        "redirect",
        ({ to, flash }) => this.onRedirect({ to, flash })
      );
      this.onChannel("live_patch", (redir) => this.onLivePatch(redir));
      this.onChannel("live_redirect", (redir) => this.onLiveRedirect(redir));
      this.channel.onError((reason) => this.onError(reason));
      this.channel.onClose((reason) => this.onClose(reason));
    }
    destroyAllChildren() {
      this.eachChild((child) => child.destroy());
    }
    onLiveRedirect(redir) {
      const { to, kind, flash } = redir;
      const url = this.expandURL(to);
      const e = new CustomEvent("phx:server-navigate", {
        detail: { to, kind, flash }
      });
      this.liveSocket.historyRedirect(e, url, kind, flash);
    }
    onLivePatch(redir) {
      const { to, kind } = redir;
      this.href = this.expandURL(to);
      this.liveSocket.historyPatch(to, kind);
    }
    expandURL(to) {
      return to.startsWith("/") ? `${window.location.protocol}//${window.location.host}${to}` : to;
    }
    /**
     * @param {{to: string, flash?: string, reloadToken?: string}} redirect
     */
    onRedirect({ to, flash, reloadToken }) {
      this.liveSocket.redirect(to, flash, reloadToken);
    }
    isDestroyed() {
      return this.destroyed;
    }
    joinDead() {
      this.isDead = true;
    }
    joinPush() {
      this.joinPush = this.joinPush || this.channel.join();
      return this.joinPush;
    }
    join(callback) {
      this.showLoader(this.liveSocket.loaderTimeout);
      this.bindChannel();
      if (this.isMain()) {
        this.stopCallback = this.liveSocket.withPageLoading({
          to: this.href,
          kind: "initial"
        });
      }
      this.joinCallback = (onDone) => {
        onDone = onDone || function() {
        };
        callback ? callback(this.joinCount, onDone) : onDone();
      };
      this.wrapPush(() => this.channel.join(), {
        ok: (resp) => this.liveSocket.requestDOMUpdate(() => this.onJoin(resp)),
        error: (error) => this.onJoinError(error),
        timeout: () => this.onJoinError({ reason: "timeout" })
      });
    }
    onJoinError(resp) {
      if (resp.reason === "reload") {
        this.log("error", () => [
          `failed mount with ${resp.status}. Falling back to page reload`,
          resp
        ]);
        this.onRedirect({ to: this.root.href, reloadToken: resp.token });
        return;
      } else if (resp.reason === "unauthorized" || resp.reason === "stale") {
        this.log("error", () => [
          "unauthorized live_redirect. Falling back to page request",
          resp
        ]);
        this.onRedirect({ to: this.root.href, flash: this.flash });
        return;
      }
      if (resp.redirect || resp.live_redirect) {
        this.joinPending = false;
        this.channel.leave();
      }
      if (resp.redirect) {
        return this.onRedirect(resp.redirect);
      }
      if (resp.live_redirect) {
        return this.onLiveRedirect(resp.live_redirect);
      }
      this.log("error", () => ["unable to join", resp]);
      if (this.isMain()) {
        this.displayError([
          PHX_LOADING_CLASS,
          PHX_ERROR_CLASS,
          PHX_SERVER_ERROR_CLASS
        ]);
        if (this.liveSocket.isConnected()) {
          this.liveSocket.reloadWithJitter(this);
        }
      } else {
        if (this.joinAttempts >= MAX_CHILD_JOIN_ATTEMPTS) {
          this.root.displayError([
            PHX_LOADING_CLASS,
            PHX_ERROR_CLASS,
            PHX_SERVER_ERROR_CLASS
          ]);
          this.log("error", () => [
            `giving up trying to mount after ${MAX_CHILD_JOIN_ATTEMPTS} tries`,
            resp
          ]);
          this.destroy();
        }
        const trueChildEl = dom_default.byId(this.el.id);
        if (trueChildEl) {
          dom_default.mergeAttrs(trueChildEl, this.el);
          this.displayError([
            PHX_LOADING_CLASS,
            PHX_ERROR_CLASS,
            PHX_SERVER_ERROR_CLASS
          ]);
          this.el = trueChildEl;
        } else {
          this.destroy();
        }
      }
    }
    onClose(reason) {
      if (this.isDestroyed()) {
        return;
      }
      if (this.isMain() && this.liveSocket.hasPendingLink() && reason !== "leave") {
        return this.liveSocket.reloadWithJitter(this);
      }
      this.destroyAllChildren();
      this.liveSocket.dropActiveElement(this);
      if (this.liveSocket.isUnloaded()) {
        this.showLoader(BEFORE_UNLOAD_LOADER_TIMEOUT);
      }
    }
    onError(reason) {
      this.onClose(reason);
      if (this.liveSocket.isConnected()) {
        this.log("error", () => ["view crashed", reason]);
      }
      if (!this.liveSocket.isUnloaded()) {
        if (this.liveSocket.isConnected()) {
          this.displayError([
            PHX_LOADING_CLASS,
            PHX_ERROR_CLASS,
            PHX_SERVER_ERROR_CLASS
          ]);
        } else {
          this.displayError([
            PHX_LOADING_CLASS,
            PHX_ERROR_CLASS,
            PHX_CLIENT_ERROR_CLASS
          ]);
        }
      }
    }
    displayError(classes) {
      if (this.isMain()) {
        dom_default.dispatchEvent(window, "phx:page-loading-start", {
          detail: { to: this.href, kind: "error" }
        });
      }
      this.showLoader();
      this.setContainerClasses(...classes);
      this.delayedDisconnected();
    }
    delayedDisconnected() {
      this.disconnectedTimer = setTimeout(() => {
        this.execAll(this.binding("disconnected"));
      }, this.liveSocket.disconnectedTimeout);
    }
    wrapPush(callerPush, receives) {
      const latency = this.liveSocket.getLatencySim();
      const withLatency = latency ? (cb) => setTimeout(() => !this.isDestroyed() && cb(), latency) : (cb) => !this.isDestroyed() && cb();
      withLatency(() => {
        callerPush().receive(
          "ok",
          (resp) => withLatency(() => receives.ok && receives.ok(resp))
        ).receive(
          "error",
          (reason) => withLatency(() => receives.error && receives.error(reason))
        ).receive(
          "timeout",
          () => withLatency(() => receives.timeout && receives.timeout())
        );
      });
    }
    pushWithReply(refGenerator, event, payload) {
      if (!this.isConnected()) {
        return Promise.reject(new Error("no connection"));
      }
      const [ref, [el], opts] = refGenerator ? refGenerator({ payload }) : [null, [], {}];
      const oldJoinCount = this.joinCount;
      let onLoadingDone = function() {
      };
      if (opts.page_loading) {
        onLoadingDone = this.liveSocket.withPageLoading({
          kind: "element",
          target: el
        });
      }
      if (typeof payload.cid !== "number") {
        delete payload.cid;
      }
      return new Promise((resolve, reject) => {
        this.wrapPush(() => this.channel.push(event, payload, PUSH_TIMEOUT), {
          ok: (resp) => {
            if (ref !== null) {
              this.lastAckRef = ref;
            }
            const finish = (hookReply) => {
              if (resp.redirect) {
                this.onRedirect(resp.redirect);
              }
              if (resp.live_patch) {
                this.onLivePatch(resp.live_patch);
              }
              if (resp.live_redirect) {
                this.onLiveRedirect(resp.live_redirect);
              }
              onLoadingDone();
              resolve({ resp, reply: hookReply, ref });
            };
            if (resp.diff) {
              this.liveSocket.requestDOMUpdate(() => {
                this.applyDiff("update", resp.diff, ({ diff, reply, events }) => {
                  if (ref !== null) {
                    this.undoRefs(ref, payload.event);
                  }
                  this.update(diff, events);
                  finish(reply);
                });
              });
            } else {
              if (ref !== null) {
                this.undoRefs(ref, payload.event);
              }
              finish(null);
            }
          },
          error: (reason) => reject(new Error(`failed with reason: ${reason}`)),
          timeout: () => {
            reject(new Error("timeout"));
            if (this.joinCount === oldJoinCount) {
              this.liveSocket.reloadWithJitter(this, () => {
                this.log("timeout", () => [
                  "received timeout while communicating with server. Falling back to hard refresh for recovery"
                ]);
              });
            }
          }
        });
      });
    }
    undoRefs(ref, phxEvent, onlyEls) {
      if (!this.isConnected()) {
        return;
      }
      const selector = `[${PHX_REF_SRC}="${this.refSrc()}"]`;
      if (onlyEls) {
        onlyEls = new Set(onlyEls);
        dom_default.all(document, selector, (parent) => {
          if (onlyEls && !onlyEls.has(parent)) {
            return;
          }
          dom_default.all(
            parent,
            selector,
            (child) => this.undoElRef(child, ref, phxEvent)
          );
          this.undoElRef(parent, ref, phxEvent);
        });
      } else {
        dom_default.all(document, selector, (el) => this.undoElRef(el, ref, phxEvent));
      }
    }
    undoElRef(el, ref, phxEvent) {
      const elRef = new ElementRef(el);
      elRef.maybeUndo(ref, phxEvent, (clonedTree) => {
        const patch = new DOMPatch(this, el, this.id, clonedTree, [], null, {
          undoRef: ref
        });
        const phxChildrenAdded = this.performPatch(patch, true);
        dom_default.all(
          el,
          `[${PHX_REF_SRC}="${this.refSrc()}"]`,
          (child) => this.undoElRef(child, ref, phxEvent)
        );
        if (phxChildrenAdded) {
          this.joinNewChildren();
        }
      });
    }
    refSrc() {
      return this.el.id;
    }
    putRef(elements, phxEvent, eventType, opts = {}) {
      const newRef = this.ref++;
      const disableWith = this.binding(PHX_DISABLE_WITH);
      if (opts.loading) {
        const loadingEls = dom_default.all(document, opts.loading).map((el) => {
          return { el, lock: true, loading: true };
        });
        elements = elements.concat(loadingEls);
      }
      for (const { el, lock, loading } of elements) {
        if (!lock && !loading) {
          throw new Error("putRef requires lock or loading");
        }
        el.setAttribute(PHX_REF_SRC, this.refSrc());
        if (loading) {
          el.setAttribute(PHX_REF_LOADING, newRef);
        }
        if (lock) {
          el.setAttribute(PHX_REF_LOCK, newRef);
        }
        if (!loading || opts.submitter && !(el === opts.submitter || el === opts.form)) {
          continue;
        }
        const lockCompletePromise = new Promise((resolve) => {
          el.addEventListener(`phx:undo-lock:${newRef}`, () => resolve(detail), {
            once: true
          });
        });
        const loadingCompletePromise = new Promise((resolve) => {
          el.addEventListener(
            `phx:undo-loading:${newRef}`,
            () => resolve(detail),
            { once: true }
          );
        });
        el.classList.add(`phx-${eventType}-loading`);
        const disableText = el.getAttribute(disableWith);
        if (disableText !== null) {
          if (!el.getAttribute(PHX_DISABLE_WITH_RESTORE)) {
            el.setAttribute(PHX_DISABLE_WITH_RESTORE, el.innerText);
          }
          if (disableText !== "") {
            el.innerText = disableText;
          }
          el.setAttribute(
            PHX_DISABLED,
            el.getAttribute(PHX_DISABLED) || el.disabled
          );
          el.setAttribute("disabled", "");
        }
        const detail = {
          event: phxEvent,
          eventType,
          ref: newRef,
          isLoading: loading,
          isLocked: lock,
          lockElements: elements.filter(({ lock: lock2 }) => lock2).map(({ el: el2 }) => el2),
          loadingElements: elements.filter(({ loading: loading2 }) => loading2).map(({ el: el2 }) => el2),
          unlock: (els) => {
            els = Array.isArray(els) ? els : [els];
            this.undoRefs(newRef, phxEvent, els);
          },
          lockComplete: lockCompletePromise,
          loadingComplete: loadingCompletePromise,
          lock: (lockEl) => {
            return new Promise((resolve) => {
              if (this.isAcked(newRef)) {
                return resolve(detail);
              }
              lockEl.setAttribute(PHX_REF_LOCK, newRef);
              lockEl.setAttribute(PHX_REF_SRC, this.refSrc());
              lockEl.addEventListener(
                `phx:lock-stop:${newRef}`,
                () => resolve(detail),
                { once: true }
              );
            });
          }
        };
        if (opts.payload) {
          detail["payload"] = opts.payload;
        }
        if (opts.target) {
          detail["target"] = opts.target;
        }
        if (opts.originalEvent) {
          detail["originalEvent"] = opts.originalEvent;
        }
        el.dispatchEvent(
          new CustomEvent("phx:push", {
            detail,
            bubbles: true,
            cancelable: false
          })
        );
        if (phxEvent) {
          el.dispatchEvent(
            new CustomEvent(`phx:push:${phxEvent}`, {
              detail,
              bubbles: true,
              cancelable: false
            })
          );
        }
      }
      return [newRef, elements.map(({ el }) => el), opts];
    }
    isAcked(ref) {
      return this.lastAckRef !== null && this.lastAckRef >= ref;
    }
    componentID(el) {
      const cid = el.getAttribute && el.getAttribute(PHX_COMPONENT);
      return cid ? parseInt(cid) : null;
    }
    targetComponentID(target, targetCtx, opts = {}) {
      if (isCid(targetCtx)) {
        return targetCtx;
      }
      const cidOrSelector = opts.target || target.getAttribute(this.binding("target"));
      if (isCid(cidOrSelector)) {
        return parseInt(cidOrSelector);
      } else if (targetCtx && (cidOrSelector !== null || opts.target)) {
        return this.closestComponentID(targetCtx);
      } else {
        return null;
      }
    }
    closestComponentID(targetCtx) {
      if (isCid(targetCtx)) {
        return targetCtx;
      } else if (targetCtx) {
        return maybe(
          targetCtx.closest(`[${PHX_COMPONENT}]`),
          (el) => this.ownsElement(el) && this.componentID(el)
        );
      } else {
        return null;
      }
    }
    pushHookEvent(el, targetCtx, event, payload) {
      if (!this.isConnected()) {
        this.log("hook", () => [
          "unable to push hook event. LiveView not connected",
          event,
          payload
        ]);
        return Promise.reject(
          new Error("unable to push hook event. LiveView not connected")
        );
      }
      const refGenerator = () => this.putRef([{ el, loading: true, lock: true }], event, "hook", {
        payload,
        target: targetCtx
      });
      return this.pushWithReply(refGenerator, "event", {
        type: "hook",
        event,
        value: payload,
        cid: this.closestComponentID(targetCtx)
      }).then(({ resp: _resp, reply, ref }) => ({ reply, ref }));
    }
    extractMeta(el, meta, value) {
      const prefix = this.binding("value-");
      for (let i = 0; i < el.attributes.length; i++) {
        if (!meta) {
          meta = {};
        }
        const name = el.attributes[i].name;
        if (name.startsWith(prefix)) {
          meta[name.replace(prefix, "")] = el.getAttribute(name);
        }
      }
      if (el.value !== void 0 && !(el instanceof HTMLFormElement)) {
        if (!meta) {
          meta = {};
        }
        meta.value = el.value;
        if (el.tagName === "INPUT" && CHECKABLE_INPUTS.indexOf(el.type) >= 0 && !el.checked) {
          delete meta.value;
        }
      }
      if (value) {
        if (!meta) {
          meta = {};
        }
        for (const key in value) {
          meta[key] = value[key];
        }
      }
      return meta;
    }
    pushEvent(type, el, targetCtx, phxEvent, meta, opts = {}, onReply) {
      this.pushWithReply(
        (maybePayload) => this.putRef([{ el, loading: true, lock: true }], phxEvent, type, __spreadProps(__spreadValues({}, opts), {
          payload: maybePayload == null ? void 0 : maybePayload.payload
        })),
        "event",
        {
          type,
          event: phxEvent,
          value: this.extractMeta(el, meta, opts.value),
          cid: this.targetComponentID(el, targetCtx, opts)
        }
      ).then(({ reply }) => onReply && onReply(reply)).catch((error) => logError("Failed to push event", error));
    }
    pushFileProgress(fileEl, entryRef, progress, onReply = function() {
    }) {
      this.liveSocket.withinOwners(fileEl.form, (view, targetCtx) => {
        view.pushWithReply(null, "progress", {
          event: fileEl.getAttribute(view.binding(PHX_PROGRESS)),
          ref: fileEl.getAttribute(PHX_UPLOAD_REF),
          entry_ref: entryRef,
          progress,
          cid: view.targetComponentID(fileEl.form, targetCtx)
        }).then(() => onReply()).catch((error) => logError("Failed to push file progress", error));
      });
    }
    pushInput(inputEl, targetCtx, forceCid, phxEvent, opts, callback) {
      if (!inputEl.form) {
        throw new Error("form events require the input to be inside a form");
      }
      let uploads;
      const cid = isCid(forceCid) ? forceCid : this.targetComponentID(inputEl.form, targetCtx, opts);
      const refGenerator = (maybePayload) => {
        return this.putRef(
          [
            { el: inputEl, loading: true, lock: true },
            { el: inputEl.form, loading: true, lock: true }
          ],
          phxEvent,
          "change",
          __spreadProps(__spreadValues({}, opts), { payload: maybePayload == null ? void 0 : maybePayload.payload })
        );
      };
      let formData;
      const meta = this.extractMeta(inputEl.form, {}, opts.value);
      const serializeOpts = {};
      if (inputEl instanceof HTMLButtonElement) {
        serializeOpts.submitter = inputEl;
      }
      if (inputEl.getAttribute(this.binding("change"))) {
        formData = serializeForm(inputEl.form, serializeOpts, [inputEl.name]);
      } else {
        formData = serializeForm(inputEl.form, serializeOpts);
      }
      if (dom_default.isUploadInput(inputEl) && inputEl.files && inputEl.files.length > 0) {
        LiveUploader.trackFiles(inputEl, Array.from(inputEl.files));
      }
      uploads = LiveUploader.serializeUploads(inputEl);
      const event = {
        type: "form",
        event: phxEvent,
        value: formData,
        meta: __spreadValues({
          // no target was implicitly sent as "undefined" in LV <= 1.0.5, therefore
          // we have to keep it. In 1.0.6 we switched from passing meta as URL encoded data
          // to passing it directly in the event, but the JSON encode would drop keys with
          // undefined values.
          _target: opts._target || "undefined"
        }, meta),
        uploads,
        cid
      };
      this.pushWithReply(refGenerator, "event", event).then(({ resp }) => {
        if (dom_default.isUploadInput(inputEl) && dom_default.isAutoUpload(inputEl)) {
          ElementRef.onUnlock(inputEl, () => {
            if (LiveUploader.filesAwaitingPreflight(inputEl).length > 0) {
              const [ref, _els] = refGenerator();
              this.undoRefs(ref, phxEvent, [inputEl.form]);
              this.uploadFiles(
                inputEl.form,
                phxEvent,
                targetCtx,
                ref,
                cid,
                (_uploads) => {
                  callback && callback(resp);
                  this.triggerAwaitingSubmit(inputEl.form, phxEvent);
                  this.undoRefs(ref, phxEvent);
                }
              );
            }
          });
        } else {
          callback && callback(resp);
        }
      }).catch((error) => logError("Failed to push input event", error));
    }
    triggerAwaitingSubmit(formEl, phxEvent) {
      const awaitingSubmit = this.getScheduledSubmit(formEl);
      if (awaitingSubmit) {
        const [_el, _ref, _opts, callback] = awaitingSubmit;
        this.cancelSubmit(formEl, phxEvent);
        callback();
      }
    }
    getScheduledSubmit(formEl) {
      return this.formSubmits.find(
        ([el, _ref, _opts, _callback]) => el.isSameNode(formEl)
      );
    }
    scheduleSubmit(formEl, ref, opts, callback) {
      if (this.getScheduledSubmit(formEl)) {
        return true;
      }
      this.formSubmits.push([formEl, ref, opts, callback]);
    }
    cancelSubmit(formEl, phxEvent) {
      this.formSubmits = this.formSubmits.filter(
        ([el, ref, _opts, _callback]) => {
          if (el.isSameNode(formEl)) {
            this.undoRefs(ref, phxEvent);
            return false;
          } else {
            return true;
          }
        }
      );
    }
    disableForm(formEl, phxEvent, opts = {}) {
      const filterIgnored = (el) => {
        const userIgnored = closestPhxBinding(
          el,
          `${this.binding(PHX_UPDATE)}=ignore`,
          el.form
        );
        return !(userIgnored || closestPhxBinding(el, "data-phx-update=ignore", el.form));
      };
      const filterDisables = (el) => {
        return el.hasAttribute(this.binding(PHX_DISABLE_WITH));
      };
      const filterButton = (el) => el.tagName == "BUTTON";
      const filterInput = (el) => ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName);
      const formElements = Array.from(formEl.elements);
      const disables = formElements.filter(filterDisables);
      const buttons = formElements.filter(filterButton).filter(filterIgnored);
      const inputs = formElements.filter(filterInput).filter(filterIgnored);
      buttons.forEach((button) => {
        button.setAttribute(PHX_DISABLED, button.disabled);
        button.disabled = true;
      });
      inputs.forEach((input) => {
        input.setAttribute(PHX_READONLY, input.readOnly);
        input.readOnly = true;
        if (input.files) {
          input.setAttribute(PHX_DISABLED, input.disabled);
          input.disabled = true;
        }
      });
      const formEls = disables.concat(buttons).concat(inputs).map((el) => {
        return { el, loading: true, lock: true };
      });
      const els = [{ el: formEl, loading: true, lock: false }].concat(formEls).reverse();
      return this.putRef(els, phxEvent, "submit", opts);
    }
    pushFormSubmit(formEl, targetCtx, phxEvent, submitter, opts, onReply) {
      const refGenerator = (maybePayload) => this.disableForm(formEl, phxEvent, __spreadProps(__spreadValues({}, opts), {
        form: formEl,
        payload: maybePayload == null ? void 0 : maybePayload.payload,
        submitter
      }));
      dom_default.putPrivate(formEl, "submitter", submitter);
      const cid = this.targetComponentID(formEl, targetCtx);
      if (LiveUploader.hasUploadsInProgress(formEl)) {
        const [ref, _els] = refGenerator();
        const push = () => this.pushFormSubmit(
          formEl,
          targetCtx,
          phxEvent,
          submitter,
          opts,
          onReply
        );
        return this.scheduleSubmit(formEl, ref, opts, push);
      } else if (LiveUploader.inputsAwaitingPreflight(formEl).length > 0) {
        const [ref, els] = refGenerator();
        const proxyRefGen = () => [ref, els, opts];
        this.uploadFiles(formEl, phxEvent, targetCtx, ref, cid, (_uploads) => {
          if (LiveUploader.inputsAwaitingPreflight(formEl).length > 0) {
            return this.undoRefs(ref, phxEvent);
          }
          const meta = this.extractMeta(formEl, {}, opts.value);
          const formData = serializeForm(formEl, { submitter });
          this.pushWithReply(proxyRefGen, "event", {
            type: "form",
            event: phxEvent,
            value: formData,
            meta,
            cid
          }).then(({ resp }) => onReply(resp)).catch((error) => logError("Failed to push form submit", error));
        });
      } else if (!(formEl.hasAttribute(PHX_REF_SRC) && formEl.classList.contains("phx-submit-loading"))) {
        const meta = this.extractMeta(formEl, {}, opts.value);
        const formData = serializeForm(formEl, { submitter });
        this.pushWithReply(refGenerator, "event", {
          type: "form",
          event: phxEvent,
          value: formData,
          meta,
          cid
        }).then(({ resp }) => onReply(resp)).catch((error) => logError("Failed to push form submit", error));
      }
    }
    uploadFiles(formEl, phxEvent, targetCtx, ref, cid, onComplete) {
      const joinCountAtUpload = this.joinCount;
      const inputEls = LiveUploader.activeFileInputs(formEl);
      let numFileInputsInProgress = inputEls.length;
      inputEls.forEach((inputEl) => {
        const uploader = new LiveUploader(inputEl, this, () => {
          numFileInputsInProgress--;
          if (numFileInputsInProgress === 0) {
            onComplete();
          }
        });
        const entries = uploader.entries().map((entry) => entry.toPreflightPayload());
        if (entries.length === 0) {
          numFileInputsInProgress--;
          return;
        }
        const payload = {
          ref: inputEl.getAttribute(PHX_UPLOAD_REF),
          entries,
          cid: this.targetComponentID(inputEl.form, targetCtx)
        };
        this.log("upload", () => ["sending preflight request", payload]);
        this.pushWithReply(null, "allow_upload", payload).then(({ resp }) => {
          this.log("upload", () => ["got preflight response", resp]);
          uploader.entries().forEach((entry) => {
            if (resp.entries && !resp.entries[entry.ref]) {
              this.handleFailedEntryPreflight(
                entry.ref,
                "failed preflight",
                uploader
              );
            }
          });
          if (resp.error || Object.keys(resp.entries).length === 0) {
            this.undoRefs(ref, phxEvent);
            const errors = resp.error || [];
            errors.map(([entry_ref, reason]) => {
              this.handleFailedEntryPreflight(entry_ref, reason, uploader);
            });
          } else {
            const onError = (callback) => {
              this.channel.onError(() => {
                if (this.joinCount === joinCountAtUpload) {
                  callback();
                }
              });
            };
            uploader.initAdapterUpload(resp, onError, this.liveSocket);
          }
        }).catch((error) => logError("Failed to push upload", error));
      });
    }
    handleFailedEntryPreflight(uploadRef, reason, uploader) {
      if (uploader.isAutoUpload()) {
        const entry = uploader.entries().find((entry2) => entry2.ref === uploadRef.toString());
        if (entry) {
          entry.cancel();
        }
      } else {
        uploader.entries().map((entry) => entry.cancel());
      }
      this.log("upload", () => [`error for entry ${uploadRef}`, reason]);
    }
    dispatchUploads(targetCtx, name, filesOrBlobs) {
      const targetElement = this.targetCtxElement(targetCtx) || this.el;
      const inputs = dom_default.findUploadInputs(targetElement).filter(
        (el) => el.name === name
      );
      if (inputs.length === 0) {
        logError(`no live file inputs found matching the name "${name}"`);
      } else if (inputs.length > 1) {
        logError(`duplicate live file inputs found matching the name "${name}"`);
      } else {
        dom_default.dispatchEvent(inputs[0], PHX_TRACK_UPLOADS, {
          detail: { files: filesOrBlobs }
        });
      }
    }
    targetCtxElement(targetCtx) {
      if (isCid(targetCtx)) {
        const [target] = dom_default.findComponentNodeList(this.id, targetCtx);
        return target;
      } else if (targetCtx) {
        return targetCtx;
      } else {
        return null;
      }
    }
    pushFormRecovery(oldForm, newForm, templateDom, callback) {
      const phxChange = this.binding("change");
      const phxTarget = newForm.getAttribute(this.binding("target")) || newForm;
      const phxEvent = newForm.getAttribute(this.binding(PHX_AUTO_RECOVER)) || newForm.getAttribute(this.binding("change"));
      const inputs = Array.from(oldForm.elements).filter(
        (el) => dom_default.isFormInput(el) && el.name && !el.hasAttribute(phxChange)
      );
      if (inputs.length === 0) {
        callback();
        return;
      }
      inputs.forEach(
        (input2) => input2.hasAttribute(PHX_UPLOAD_REF) && LiveUploader.clearFiles(input2)
      );
      const input = inputs.find((el) => el.type !== "hidden") || inputs[0];
      let pending = 0;
      this.withinTargets(
        phxTarget,
        (targetView, targetCtx) => {
          const cid = this.targetComponentID(newForm, targetCtx);
          pending++;
          let e = new CustomEvent("phx:form-recovery", {
            detail: { sourceElement: oldForm }
          });
          js_default.exec(e, "change", phxEvent, this, input, [
            "push",
            {
              _target: input.name,
              targetView,
              targetCtx,
              newCid: cid,
              callback: () => {
                pending--;
                if (pending === 0) {
                  callback();
                }
              }
            }
          ]);
        },
        templateDom
      );
    }
    pushLinkPatch(e, href, targetEl, callback) {
      const linkRef = this.liveSocket.setPendingLink(href);
      const loading = e.isTrusted && e.type !== "popstate";
      const refGen = targetEl ? () => this.putRef(
        [{ el: targetEl, loading, lock: true }],
        null,
        "click"
      ) : null;
      const fallback = () => this.liveSocket.redirect(window.location.href);
      const url = href.startsWith("/") ? `${location.protocol}//${location.host}${href}` : href;
      this.pushWithReply(refGen, "live_patch", { url }).then(
        ({ resp }) => {
          this.liveSocket.requestDOMUpdate(() => {
            if (resp.link_redirect) {
              this.liveSocket.replaceMain(href, null, callback, linkRef);
            } else {
              if (this.liveSocket.commitPendingLink(linkRef)) {
                this.href = href;
              }
              this.applyPendingUpdates();
              callback && callback(linkRef);
            }
          });
        },
        ({ error: _error, timeout: _timeout }) => fallback()
      );
    }
    getFormsForRecovery() {
      if (this.joinCount === 0) {
        return {};
      }
      const phxChange = this.binding("change");
      return dom_default.all(this.el, `form[${phxChange}]`).filter((form) => form.id).filter((form) => form.elements.length > 0).filter(
        (form) => form.getAttribute(this.binding(PHX_AUTO_RECOVER)) !== "ignore"
      ).map((form) => {
        const clonedForm = form.cloneNode(true);
        morphdom_esm_default(clonedForm, form, {
          onBeforeElUpdated: (fromEl, toEl) => {
            dom_default.copyPrivates(fromEl, toEl);
            return true;
          }
        });
        const externalElements = document.querySelectorAll(
          `[form="${form.id}"]`
        );
        Array.from(externalElements).forEach((el) => {
          if (form.contains(el)) {
            return;
          }
          const clonedEl = el.cloneNode(true);
          morphdom_esm_default(clonedEl, el);
          dom_default.copyPrivates(clonedEl, el);
          clonedForm.appendChild(clonedEl);
        });
        return clonedForm;
      }).reduce((acc, form) => {
        acc[form.id] = form;
        return acc;
      }, {});
    }
    maybePushComponentsDestroyed(destroyedCIDs) {
      let willDestroyCIDs = destroyedCIDs.filter((cid) => {
        return dom_default.findComponentNodeList(this.el, cid).length === 0;
      });
      const onError = (error) => {
        if (!this.isDestroyed()) {
          logError("Failed to push components destroyed", error);
        }
      };
      if (willDestroyCIDs.length > 0) {
        willDestroyCIDs.forEach((cid) => this.rendered.resetRender(cid));
        this.pushWithReply(null, "cids_will_destroy", { cids: willDestroyCIDs }).then(() => {
          this.liveSocket.requestDOMUpdate(() => {
            let completelyDestroyCIDs = willDestroyCIDs.filter((cid) => {
              return dom_default.findComponentNodeList(this.el, cid).length === 0;
            });
            if (completelyDestroyCIDs.length > 0) {
              this.pushWithReply(null, "cids_destroyed", {
                cids: completelyDestroyCIDs
              }).then(({ resp }) => {
                this.rendered.pruneCIDs(resp.cids);
              }).catch(onError);
            }
          });
        }).catch(onError);
      }
    }
    ownsElement(el) {
      let parentViewEl = el.closest(PHX_VIEW_SELECTOR);
      return el.getAttribute(PHX_PARENT_ID) === this.id || parentViewEl && parentViewEl.id === this.id || !parentViewEl && this.isDead;
    }
    submitForm(form, targetCtx, phxEvent, submitter, opts = {}) {
      dom_default.putPrivate(form, PHX_HAS_SUBMITTED, true);
      const inputs = Array.from(form.elements);
      inputs.forEach((input) => dom_default.putPrivate(input, PHX_HAS_SUBMITTED, true));
      this.liveSocket.blurActiveElement(this);
      this.pushFormSubmit(form, targetCtx, phxEvent, submitter, opts, () => {
        this.liveSocket.restorePreviouslyActiveFocus();
      });
    }
    binding(kind) {
      return this.liveSocket.binding(kind);
    }
    // phx-portal
    pushPortalElementId(id) {
      this.portalElementIds.add(id);
    }
    dropPortalElementId(id) {
      this.portalElementIds.delete(id);
    }
    destroyPortalElements() {
      this.portalElementIds.forEach((id) => {
        const el = document.getElementById(id);
        if (el) {
          el.remove();
        }
      });
    }
  };
  var LiveSocket = class {
    constructor(url, phxSocket, opts = {}) {
      this.unloaded = false;
      if (!phxSocket || phxSocket.constructor.name === "Object") {
        throw new Error(`
      a phoenix Socket must be provided as the second argument to the LiveSocket constructor. For example:

          import {Socket} from "phoenix"
          import {LiveSocket} from "phoenix_live_view"
          let liveSocket = new LiveSocket("/live", Socket, {...})
      `);
      }
      this.socket = new phxSocket(url, opts);
      this.bindingPrefix = opts.bindingPrefix || BINDING_PREFIX;
      this.opts = opts;
      this.params = closure2(opts.params || {});
      this.viewLogger = opts.viewLogger;
      this.metadataCallbacks = opts.metadata || {};
      this.defaults = Object.assign(clone(DEFAULTS), opts.defaults || {});
      this.prevActive = null;
      this.silenced = false;
      this.main = null;
      this.outgoingMainEl = null;
      this.clickStartedAtTarget = null;
      this.linkRef = 1;
      this.roots = {};
      this.href = window.location.href;
      this.pendingLink = null;
      this.currentLocation = clone(window.location);
      this.hooks = opts.hooks || {};
      this.uploaders = opts.uploaders || {};
      this.loaderTimeout = opts.loaderTimeout || LOADER_TIMEOUT;
      this.disconnectedTimeout = opts.disconnectedTimeout || DISCONNECTED_TIMEOUT;
      this.reloadWithJitterTimer = null;
      this.maxReloads = opts.maxReloads || MAX_RELOADS;
      this.reloadJitterMin = opts.reloadJitterMin || RELOAD_JITTER_MIN;
      this.reloadJitterMax = opts.reloadJitterMax || RELOAD_JITTER_MAX;
      this.failsafeJitter = opts.failsafeJitter || FAILSAFE_JITTER;
      this.localStorage = opts.localStorage || window.localStorage;
      this.sessionStorage = opts.sessionStorage || window.sessionStorage;
      this.boundTopLevelEvents = false;
      this.boundEventNames = /* @__PURE__ */ new Set();
      this.blockPhxChangeWhileComposing = opts.blockPhxChangeWhileComposing || false;
      this.serverCloseRef = null;
      this.domCallbacks = Object.assign(
        {
          jsQuerySelectorAll: null,
          onPatchStart: closure2(),
          onPatchEnd: closure2(),
          onNodeAdded: closure2(),
          onBeforeElUpdated: closure2()
        },
        opts.dom || {}
      );
      this.transitions = new TransitionSet();
      this.currentHistoryPosition = parseInt(this.sessionStorage.getItem(PHX_LV_HISTORY_POSITION)) || 0;
      window.addEventListener("pagehide", (_e) => {
        this.unloaded = true;
      });
      this.socket.onOpen(() => {
        if (this.isUnloaded()) {
          window.location.reload();
        }
      });
    }
    // public
    version() {
      return "1.1.3";
    }
    isProfileEnabled() {
      return this.sessionStorage.getItem(PHX_LV_PROFILE) === "true";
    }
    isDebugEnabled() {
      return this.sessionStorage.getItem(PHX_LV_DEBUG) === "true";
    }
    isDebugDisabled() {
      return this.sessionStorage.getItem(PHX_LV_DEBUG) === "false";
    }
    enableDebug() {
      this.sessionStorage.setItem(PHX_LV_DEBUG, "true");
    }
    enableProfiling() {
      this.sessionStorage.setItem(PHX_LV_PROFILE, "true");
    }
    disableDebug() {
      this.sessionStorage.setItem(PHX_LV_DEBUG, "false");
    }
    disableProfiling() {
      this.sessionStorage.removeItem(PHX_LV_PROFILE);
    }
    enableLatencySim(upperBoundMs) {
      this.enableDebug();
      console.log(
        "latency simulator enabled for the duration of this browser session. Call disableLatencySim() to disable"
      );
      this.sessionStorage.setItem(PHX_LV_LATENCY_SIM, upperBoundMs);
    }
    disableLatencySim() {
      this.sessionStorage.removeItem(PHX_LV_LATENCY_SIM);
    }
    getLatencySim() {
      const str = this.sessionStorage.getItem(PHX_LV_LATENCY_SIM);
      return str ? parseInt(str) : null;
    }
    getSocket() {
      return this.socket;
    }
    connect() {
      if (window.location.hostname === "localhost" && !this.isDebugDisabled()) {
        this.enableDebug();
      }
      const doConnect = () => {
        this.resetReloadStatus();
        if (this.joinRootViews()) {
          this.bindTopLevelEvents();
          this.socket.connect();
        } else if (this.main) {
          this.socket.connect();
        } else {
          this.bindTopLevelEvents({ dead: true });
        }
        this.joinDeadView();
      };
      if (["complete", "loaded", "interactive"].indexOf(document.readyState) >= 0) {
        doConnect();
      } else {
        document.addEventListener("DOMContentLoaded", () => doConnect());
      }
    }
    disconnect(callback) {
      clearTimeout(this.reloadWithJitterTimer);
      if (this.serverCloseRef) {
        this.socket.off(this.serverCloseRef);
        this.serverCloseRef = null;
      }
      this.socket.disconnect(callback);
    }
    replaceTransport(transport) {
      clearTimeout(this.reloadWithJitterTimer);
      this.socket.replaceTransport(transport);
      this.connect();
    }
    execJS(el, encodedJS, eventType = null) {
      const e = new CustomEvent("phx:exec", { detail: { sourceElement: el } });
      this.owner(el, (view) => js_default.exec(e, eventType, encodedJS, view, el));
    }
    /**
     * Returns an object with methods to manipluate the DOM and execute JavaScript.
     * The applied changes integrate with server DOM patching.
     *
     * @returns {import("./js_commands").LiveSocketJSCommands}
     */
    js() {
      return js_commands_default(this, "js");
    }
    // private
    unload() {
      if (this.unloaded) {
        return;
      }
      if (this.main && this.isConnected()) {
        this.log(this.main, "socket", () => ["disconnect for page nav"]);
      }
      this.unloaded = true;
      this.destroyAllViews();
      this.disconnect();
    }
    triggerDOM(kind, args) {
      this.domCallbacks[kind](...args);
    }
    time(name, func) {
      if (!this.isProfileEnabled() || !console.time) {
        return func();
      }
      console.time(name);
      const result = func();
      console.timeEnd(name);
      return result;
    }
    log(view, kind, msgCallback) {
      if (this.viewLogger) {
        const [msg, obj] = msgCallback();
        this.viewLogger(view, kind, msg, obj);
      } else if (this.isDebugEnabled()) {
        const [msg, obj] = msgCallback();
        debug(view, kind, msg, obj);
      }
    }
    requestDOMUpdate(callback) {
      this.transitions.after(callback);
    }
    asyncTransition(promise) {
      this.transitions.addAsyncTransition(promise);
    }
    transition(time, onStart, onDone = function() {
    }) {
      this.transitions.addTransition(time, onStart, onDone);
    }
    onChannel(channel, event, cb) {
      channel.on(event, (data) => {
        const latency = this.getLatencySim();
        if (!latency) {
          cb(data);
        } else {
          setTimeout(() => cb(data), latency);
        }
      });
    }
    reloadWithJitter(view, log) {
      clearTimeout(this.reloadWithJitterTimer);
      this.disconnect();
      const minMs = this.reloadJitterMin;
      const maxMs = this.reloadJitterMax;
      let afterMs = Math.floor(Math.random() * (maxMs - minMs + 1)) + minMs;
      const tries = browser_default.updateLocal(
        this.localStorage,
        window.location.pathname,
        CONSECUTIVE_RELOADS,
        0,
        (count) => count + 1
      );
      if (tries >= this.maxReloads) {
        afterMs = this.failsafeJitter;
      }
      this.reloadWithJitterTimer = setTimeout(() => {
        if (view.isDestroyed() || view.isConnected()) {
          return;
        }
        view.destroy();
        log ? log() : this.log(view, "join", () => [
          `encountered ${tries} consecutive reloads`
        ]);
        if (tries >= this.maxReloads) {
          this.log(view, "join", () => [
            `exceeded ${this.maxReloads} consecutive reloads. Entering failsafe mode`
          ]);
        }
        if (this.hasPendingLink()) {
          window.location = this.pendingLink;
        } else {
          window.location.reload();
        }
      }, afterMs);
    }
    getHookDefinition(name) {
      if (!name) {
        return;
      }
      return this.maybeInternalHook(name) || this.hooks[name] || this.maybeRuntimeHook(name);
    }
    maybeInternalHook(name) {
      return name && name.startsWith("Phoenix.") && hooks_default[name.split(".")[1]];
    }
    maybeRuntimeHook(name) {
      const runtimeHook = document.querySelector(
        `script[${PHX_RUNTIME_HOOK}="${CSS.escape(name)}"]`
      );
      if (!runtimeHook) {
        return;
      }
      let callbacks = window[`phx_hook_${name}`];
      if (!callbacks || typeof callbacks !== "function") {
        logError("a runtime hook must be a function", runtimeHook);
        return;
      }
      const hookDefiniton = callbacks();
      if (hookDefiniton && (typeof hookDefiniton === "object" || typeof hookDefiniton === "function")) {
        return hookDefiniton;
      }
      logError(
        "runtime hook must return an object with hook callbacks or an instance of ViewHook",
        runtimeHook
      );
    }
    isUnloaded() {
      return this.unloaded;
    }
    isConnected() {
      return this.socket.isConnected();
    }
    getBindingPrefix() {
      return this.bindingPrefix;
    }
    binding(kind) {
      return `${this.getBindingPrefix()}${kind}`;
    }
    channel(topic, params) {
      return this.socket.channel(topic, params);
    }
    joinDeadView() {
      const body = document.body;
      if (body && !this.isPhxView(body) && !this.isPhxView(document.firstElementChild)) {
        const view = this.newRootView(body);
        view.setHref(this.getHref());
        view.joinDead();
        if (!this.main) {
          this.main = view;
        }
        window.requestAnimationFrame(() => {
          var _a;
          view.execNewMounted();
          this.maybeScroll((_a = history.state) == null ? void 0 : _a.scroll);
        });
      }
    }
    joinRootViews() {
      let rootsFound = false;
      dom_default.all(
        document,
        `${PHX_VIEW_SELECTOR}:not([${PHX_PARENT_ID}])`,
        (rootEl) => {
          if (!this.getRootById(rootEl.id)) {
            const view = this.newRootView(rootEl);
            if (!dom_default.isPhxSticky(rootEl)) {
              view.setHref(this.getHref());
            }
            view.join();
            if (rootEl.hasAttribute(PHX_MAIN)) {
              this.main = view;
            }
          }
          rootsFound = true;
        }
      );
      return rootsFound;
    }
    redirect(to, flash, reloadToken) {
      if (reloadToken) {
        browser_default.setCookie(PHX_RELOAD_STATUS, reloadToken, 60);
      }
      this.unload();
      browser_default.redirect(to, flash);
    }
    replaceMain(href, flash, callback = null, linkRef = this.setPendingLink(href)) {
      const liveReferer = this.currentLocation.href;
      this.outgoingMainEl = this.outgoingMainEl || this.main.el;
      const stickies = dom_default.findPhxSticky(document) || [];
      const removeEls = dom_default.all(
        this.outgoingMainEl,
        `[${this.binding("remove")}]`
      ).filter((el) => !dom_default.isChildOfAny(el, stickies));
      const newMainEl = dom_default.cloneNode(this.outgoingMainEl, "");
      this.main.showLoader(this.loaderTimeout);
      this.main.destroy();
      this.main = this.newRootView(newMainEl, flash, liveReferer);
      this.main.setRedirect(href);
      this.transitionRemoves(removeEls);
      this.main.join((joinCount, onDone) => {
        if (joinCount === 1 && this.commitPendingLink(linkRef)) {
          this.requestDOMUpdate(() => {
            removeEls.forEach((el) => el.remove());
            stickies.forEach((el) => newMainEl.appendChild(el));
            this.outgoingMainEl.replaceWith(newMainEl);
            this.outgoingMainEl = null;
            callback && callback(linkRef);
            onDone();
          });
        }
      });
    }
    transitionRemoves(elements, callback) {
      const removeAttr = this.binding("remove");
      const silenceEvents = (e) => {
        e.preventDefault();
        e.stopImmediatePropagation();
      };
      elements.forEach((el) => {
        for (const event of this.boundEventNames) {
          el.addEventListener(event, silenceEvents, true);
        }
        this.execJS(el, el.getAttribute(removeAttr), "remove");
      });
      this.requestDOMUpdate(() => {
        elements.forEach((el) => {
          for (const event of this.boundEventNames) {
            el.removeEventListener(event, silenceEvents, true);
          }
        });
        callback && callback();
      });
    }
    isPhxView(el) {
      return el.getAttribute && el.getAttribute(PHX_SESSION) !== null;
    }
    newRootView(el, flash, liveReferer) {
      const view = new View(el, this, null, flash, liveReferer);
      this.roots[view.id] = view;
      return view;
    }
    owner(childEl, callback) {
      let view;
      const viewEl = dom_default.closestViewEl(childEl);
      if (viewEl) {
        view = this.getViewByEl(viewEl);
      } else {
        view = this.main;
      }
      return view && callback ? callback(view) : view;
    }
    withinOwners(childEl, callback) {
      this.owner(childEl, (view) => callback(view, childEl));
    }
    getViewByEl(el) {
      const rootId = el.getAttribute(PHX_ROOT_ID);
      return maybe(
        this.getRootById(rootId),
        (root) => root.getDescendentByEl(el)
      );
    }
    getRootById(id) {
      return this.roots[id];
    }
    destroyAllViews() {
      for (const id in this.roots) {
        this.roots[id].destroy();
        delete this.roots[id];
      }
      this.main = null;
    }
    destroyViewByEl(el) {
      const root = this.getRootById(el.getAttribute(PHX_ROOT_ID));
      if (root && root.id === el.id) {
        root.destroy();
        delete this.roots[root.id];
      } else if (root) {
        root.destroyDescendent(el.id);
      }
    }
    getActiveElement() {
      return document.activeElement;
    }
    dropActiveElement(view) {
      if (this.prevActive && view.ownsElement(this.prevActive)) {
        this.prevActive = null;
      }
    }
    restorePreviouslyActiveFocus() {
      if (this.prevActive && this.prevActive !== document.body && this.prevActive instanceof HTMLElement) {
        this.prevActive.focus();
      }
    }
    blurActiveElement() {
      this.prevActive = this.getActiveElement();
      if (this.prevActive !== document.body && this.prevActive instanceof HTMLElement) {
        this.prevActive.blur();
      }
    }
    /**
     * @param {{dead?: boolean}} [options={}]
     */
    bindTopLevelEvents({ dead } = {}) {
      if (this.boundTopLevelEvents) {
        return;
      }
      this.boundTopLevelEvents = true;
      this.serverCloseRef = this.socket.onClose((event) => {
        if (event && event.code === 1e3 && this.main) {
          return this.reloadWithJitter(this.main);
        }
      });
      document.body.addEventListener("click", function() {
      });
      window.addEventListener(
        "pageshow",
        (e) => {
          if (e.persisted) {
            this.getSocket().disconnect();
            this.withPageLoading({ to: window.location.href, kind: "redirect" });
            window.location.reload();
          }
        },
        true
      );
      if (!dead) {
        this.bindNav();
      }
      this.bindClicks();
      if (!dead) {
        this.bindForms();
      }
      this.bind(
        { keyup: "keyup", keydown: "keydown" },
        (e, type, view, targetEl, phxEvent, _phxTarget) => {
          const matchKey = targetEl.getAttribute(this.binding(PHX_KEY));
          const pressedKey = e.key && e.key.toLowerCase();
          if (matchKey && matchKey.toLowerCase() !== pressedKey) {
            return;
          }
          const data = __spreadValues({ key: e.key }, this.eventMeta(type, e, targetEl));
          js_default.exec(e, type, phxEvent, view, targetEl, ["push", { data }]);
        }
      );
      this.bind(
        { blur: "focusout", focus: "focusin" },
        (e, type, view, targetEl, phxEvent, phxTarget) => {
          if (!phxTarget) {
            const data = __spreadValues({ key: e.key }, this.eventMeta(type, e, targetEl));
            js_default.exec(e, type, phxEvent, view, targetEl, ["push", { data }]);
          }
        }
      );
      this.bind(
        { blur: "blur", focus: "focus" },
        (e, type, view, targetEl, phxEvent, phxTarget) => {
          if (phxTarget === "window") {
            const data = this.eventMeta(type, e, targetEl);
            js_default.exec(e, type, phxEvent, view, targetEl, ["push", { data }]);
          }
        }
      );
      this.on("dragover", (e) => e.preventDefault());
      this.on("drop", (e) => {
        e.preventDefault();
        const dropTargetId = maybe(
          closestPhxBinding(e.target, this.binding(PHX_DROP_TARGET)),
          (trueTarget) => {
            return trueTarget.getAttribute(this.binding(PHX_DROP_TARGET));
          }
        );
        const dropTarget = dropTargetId && document.getElementById(dropTargetId);
        const files = Array.from(e.dataTransfer.files || []);
        if (!dropTarget || !(dropTarget instanceof HTMLInputElement) || dropTarget.disabled || files.length === 0 || !(dropTarget.files instanceof FileList)) {
          return;
        }
        LiveUploader.trackFiles(dropTarget, files, e.dataTransfer);
        dropTarget.dispatchEvent(new Event("input", { bubbles: true }));
      });
      this.on(PHX_TRACK_UPLOADS, (e) => {
        const uploadTarget = e.target;
        if (!dom_default.isUploadInput(uploadTarget)) {
          return;
        }
        const files = Array.from(e.detail.files || []).filter(
          (f) => f instanceof File || f instanceof Blob
        );
        LiveUploader.trackFiles(uploadTarget, files);
        uploadTarget.dispatchEvent(new Event("input", { bubbles: true }));
      });
    }
    eventMeta(eventName, e, targetEl) {
      const callback = this.metadataCallbacks[eventName];
      return callback ? callback(e, targetEl) : {};
    }
    setPendingLink(href) {
      this.linkRef++;
      this.pendingLink = href;
      this.resetReloadStatus();
      return this.linkRef;
    }
    // anytime we are navigating or connecting, drop reload cookie in case
    // we issue the cookie but the next request was interrupted and the server never dropped it
    resetReloadStatus() {
      browser_default.deleteCookie(PHX_RELOAD_STATUS);
    }
    commitPendingLink(linkRef) {
      if (this.linkRef !== linkRef) {
        return false;
      } else {
        this.href = this.pendingLink;
        this.pendingLink = null;
        return true;
      }
    }
    getHref() {
      return this.href;
    }
    hasPendingLink() {
      return !!this.pendingLink;
    }
    bind(events, callback) {
      for (const event in events) {
        const browserEventName = events[event];
        this.on(browserEventName, (e) => {
          const binding = this.binding(event);
          const windowBinding = this.binding(`window-${event}`);
          const targetPhxEvent = e.target.getAttribute && e.target.getAttribute(binding);
          if (targetPhxEvent) {
            this.debounce(e.target, e, browserEventName, () => {
              this.withinOwners(e.target, (view) => {
                callback(e, event, view, e.target, targetPhxEvent, null);
              });
            });
          } else {
            dom_default.all(document, `[${windowBinding}]`, (el) => {
              const phxEvent = el.getAttribute(windowBinding);
              this.debounce(el, e, browserEventName, () => {
                this.withinOwners(el, (view) => {
                  callback(e, event, view, el, phxEvent, "window");
                });
              });
            });
          }
        });
      }
    }
    bindClicks() {
      this.on("mousedown", (e) => this.clickStartedAtTarget = e.target);
      this.bindClick("click", "click");
    }
    bindClick(eventName, bindingName) {
      const click = this.binding(bindingName);
      window.addEventListener(
        eventName,
        (e) => {
          let target = null;
          if (e.detail === 0)
            this.clickStartedAtTarget = e.target;
          const clickStartedAtTarget = this.clickStartedAtTarget || e.target;
          target = closestPhxBinding(e.target, click);
          this.dispatchClickAway(e, clickStartedAtTarget);
          this.clickStartedAtTarget = null;
          const phxEvent = target && target.getAttribute(click);
          if (!phxEvent) {
            if (dom_default.isNewPageClick(e, window.location)) {
              this.unload();
            }
            return;
          }
          if (target.getAttribute("href") === "#") {
            e.preventDefault();
          }
          if (target.hasAttribute(PHX_REF_SRC)) {
            return;
          }
          this.debounce(target, e, "click", () => {
            this.withinOwners(target, (view) => {
              js_default.exec(e, "click", phxEvent, view, target, [
                "push",
                { data: this.eventMeta("click", e, target) }
              ]);
            });
          });
        },
        false
      );
    }
    dispatchClickAway(e, clickStartedAt) {
      const phxClickAway = this.binding("click-away");
      dom_default.all(document, `[${phxClickAway}]`, (el) => {
        if (!(el.isSameNode(clickStartedAt) || el.contains(clickStartedAt))) {
          this.withinOwners(el, (view) => {
            const phxEvent = el.getAttribute(phxClickAway);
            if (js_default.isVisible(el) && js_default.isInViewport(el)) {
              js_default.exec(e, "click", phxEvent, view, el, [
                "push",
                { data: this.eventMeta("click", e, e.target) }
              ]);
            }
          });
        }
      });
    }
    bindNav() {
      if (!browser_default.canPushState()) {
        return;
      }
      if (history.scrollRestoration) {
        history.scrollRestoration = "manual";
      }
      let scrollTimer = null;
      window.addEventListener("scroll", (_e) => {
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(() => {
          browser_default.updateCurrentState(
            (state) => Object.assign(state, { scroll: window.scrollY })
          );
        }, 100);
      });
      window.addEventListener(
        "popstate",
        (event) => {
          if (!this.registerNewLocation(window.location)) {
            return;
          }
          const { type, backType, id, scroll, position } = event.state || {};
          const href = window.location.href;
          const isForward = position > this.currentHistoryPosition;
          const navType = isForward ? type : backType || type;
          this.currentHistoryPosition = position || 0;
          this.sessionStorage.setItem(
            PHX_LV_HISTORY_POSITION,
            this.currentHistoryPosition.toString()
          );
          dom_default.dispatchEvent(window, "phx:navigate", {
            detail: {
              href,
              patch: navType === "patch",
              pop: true,
              direction: isForward ? "forward" : "backward"
            }
          });
          this.requestDOMUpdate(() => {
            const callback = () => {
              this.maybeScroll(scroll);
            };
            if (this.main.isConnected() && navType === "patch" && id === this.main.id) {
              this.main.pushLinkPatch(event, href, null, callback);
            } else {
              this.replaceMain(href, null, callback);
            }
          });
        },
        false
      );
      window.addEventListener(
        "click",
        (e) => {
          const target = closestPhxBinding(e.target, PHX_LIVE_LINK);
          const type = target && target.getAttribute(PHX_LIVE_LINK);
          if (!type || !this.isConnected() || !this.main || dom_default.wantsNewTab(e)) {
            return;
          }
          const href = target.href instanceof SVGAnimatedString ? target.href.baseVal : target.href;
          const linkState = target.getAttribute(PHX_LINK_STATE);
          e.preventDefault();
          e.stopImmediatePropagation();
          if (this.pendingLink === href) {
            return;
          }
          this.requestDOMUpdate(() => {
            if (type === "patch") {
              this.pushHistoryPatch(e, href, linkState, target);
            } else if (type === "redirect") {
              this.historyRedirect(e, href, linkState, null, target);
            } else {
              throw new Error(
                `expected ${PHX_LIVE_LINK} to be "patch" or "redirect", got: ${type}`
              );
            }
            const phxClick = target.getAttribute(this.binding("click"));
            if (phxClick) {
              this.requestDOMUpdate(() => this.execJS(target, phxClick, "click"));
            }
          });
        },
        false
      );
    }
    maybeScroll(scroll) {
      if (typeof scroll === "number") {
        requestAnimationFrame(() => {
          window.scrollTo(0, scroll);
        });
      }
    }
    dispatchEvent(event, payload = {}) {
      dom_default.dispatchEvent(window, `phx:${event}`, { detail: payload });
    }
    dispatchEvents(events) {
      events.forEach(([event, payload]) => this.dispatchEvent(event, payload));
    }
    withPageLoading(info, callback) {
      dom_default.dispatchEvent(window, "phx:page-loading-start", { detail: info });
      const done = () => dom_default.dispatchEvent(window, "phx:page-loading-stop", { detail: info });
      return callback ? callback(done) : done;
    }
    pushHistoryPatch(e, href, linkState, targetEl) {
      if (!this.isConnected() || !this.main.isMain()) {
        return browser_default.redirect(href);
      }
      this.withPageLoading({ to: href, kind: "patch" }, (done) => {
        this.main.pushLinkPatch(e, href, targetEl, (linkRef) => {
          this.historyPatch(href, linkState, linkRef);
          done();
        });
      });
    }
    historyPatch(href, linkState, linkRef = this.setPendingLink(href)) {
      if (!this.commitPendingLink(linkRef)) {
        return;
      }
      this.currentHistoryPosition++;
      this.sessionStorage.setItem(
        PHX_LV_HISTORY_POSITION,
        this.currentHistoryPosition.toString()
      );
      browser_default.updateCurrentState((state) => __spreadProps(__spreadValues({}, state), { backType: "patch" }));
      browser_default.pushState(
        linkState,
        {
          type: "patch",
          id: this.main.id,
          position: this.currentHistoryPosition
        },
        href
      );
      dom_default.dispatchEvent(window, "phx:navigate", {
        detail: { patch: true, href, pop: false, direction: "forward" }
      });
      this.registerNewLocation(window.location);
    }
    historyRedirect(e, href, linkState, flash, targetEl) {
      const clickLoading = targetEl && e.isTrusted && e.type !== "popstate";
      if (clickLoading) {
        targetEl.classList.add("phx-click-loading");
      }
      if (!this.isConnected() || !this.main.isMain()) {
        return browser_default.redirect(href, flash);
      }
      if (/^\/$|^\/[^\/]+.*$/.test(href)) {
        const { protocol, host } = window.location;
        href = `${protocol}//${host}${href}`;
      }
      const scroll = window.scrollY;
      this.withPageLoading({ to: href, kind: "redirect" }, (done) => {
        this.replaceMain(href, flash, (linkRef) => {
          if (linkRef === this.linkRef) {
            this.currentHistoryPosition++;
            this.sessionStorage.setItem(
              PHX_LV_HISTORY_POSITION,
              this.currentHistoryPosition.toString()
            );
            browser_default.updateCurrentState((state) => __spreadProps(__spreadValues({}, state), {
              backType: "redirect"
            }));
            browser_default.pushState(
              linkState,
              {
                type: "redirect",
                id: this.main.id,
                scroll,
                position: this.currentHistoryPosition
              },
              href
            );
            dom_default.dispatchEvent(window, "phx:navigate", {
              detail: { href, patch: false, pop: false, direction: "forward" }
            });
            this.registerNewLocation(window.location);
          }
          if (clickLoading) {
            targetEl.classList.remove("phx-click-loading");
          }
          done();
        });
      });
    }
    registerNewLocation(newLocation) {
      const { pathname, search } = this.currentLocation;
      if (pathname + search === newLocation.pathname + newLocation.search) {
        return false;
      } else {
        this.currentLocation = clone(newLocation);
        return true;
      }
    }
    bindForms() {
      let iterations = 0;
      let externalFormSubmitted = false;
      this.on("submit", (e) => {
        const phxSubmit = e.target.getAttribute(this.binding("submit"));
        const phxChange = e.target.getAttribute(this.binding("change"));
        if (!externalFormSubmitted && phxChange && !phxSubmit) {
          externalFormSubmitted = true;
          e.preventDefault();
          this.withinOwners(e.target, (view) => {
            view.disableForm(e.target);
            window.requestAnimationFrame(() => {
              if (dom_default.isUnloadableFormSubmit(e)) {
                this.unload();
              }
              e.target.submit();
            });
          });
        }
      });
      this.on("submit", (e) => {
        const phxEvent = e.target.getAttribute(this.binding("submit"));
        if (!phxEvent) {
          if (dom_default.isUnloadableFormSubmit(e)) {
            this.unload();
          }
          return;
        }
        e.preventDefault();
        e.target.disabled = true;
        this.withinOwners(e.target, (view) => {
          js_default.exec(e, "submit", phxEvent, view, e.target, [
            "push",
            { submitter: e.submitter }
          ]);
        });
      });
      for (const type of ["change", "input"]) {
        this.on(type, (e) => {
          if (e instanceof CustomEvent && (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement || e.target instanceof HTMLTextAreaElement) && e.target.form === void 0) {
            if (e.detail && e.detail.dispatcher) {
              throw new Error(
                `dispatching a custom ${type} event is only supported on input elements inside a form`
              );
            }
            return;
          }
          const phxChange = this.binding("change");
          const input = e.target;
          if (this.blockPhxChangeWhileComposing && e.isComposing) {
            const key = `composition-listener-${type}`;
            if (!dom_default.private(input, key)) {
              dom_default.putPrivate(input, key, true);
              input.addEventListener(
                "compositionend",
                () => {
                  input.dispatchEvent(new Event(type, { bubbles: true }));
                  dom_default.deletePrivate(input, key);
                },
                { once: true }
              );
            }
            return;
          }
          const inputEvent = input.getAttribute(phxChange);
          const formEvent = input.form && input.form.getAttribute(phxChange);
          const phxEvent = inputEvent || formEvent;
          if (!phxEvent) {
            return;
          }
          if (input.type === "number" && input.validity && input.validity.badInput) {
            return;
          }
          const dispatcher = inputEvent ? input : input.form;
          const currentIterations = iterations;
          iterations++;
          const { at, type: lastType } = dom_default.private(input, "prev-iteration") || {};
          if (at === currentIterations - 1 && type === "change" && lastType === "input") {
            return;
          }
          dom_default.putPrivate(input, "prev-iteration", {
            at: currentIterations,
            type
          });
          this.debounce(input, e, type, () => {
            this.withinOwners(dispatcher, (view) => {
              dom_default.putPrivate(input, PHX_HAS_FOCUSED, true);
              js_default.exec(e, "change", phxEvent, view, input, [
                "push",
                { _target: e.target.name, dispatcher }
              ]);
            });
          });
        });
      }
      this.on("reset", (e) => {
        const form = e.target;
        dom_default.resetForm(form);
        const input = Array.from(form.elements).find((el) => el.type === "reset");
        if (input) {
          window.requestAnimationFrame(() => {
            input.dispatchEvent(
              new Event("input", { bubbles: true, cancelable: false })
            );
          });
        }
      });
    }
    debounce(el, event, eventType, callback) {
      if (eventType === "blur" || eventType === "focusout") {
        return callback();
      }
      const phxDebounce = this.binding(PHX_DEBOUNCE);
      const phxThrottle = this.binding(PHX_THROTTLE);
      const defaultDebounce = this.defaults.debounce.toString();
      const defaultThrottle = this.defaults.throttle.toString();
      this.withinOwners(el, (view) => {
        const asyncFilter = () => !view.isDestroyed() && document.body.contains(el);
        dom_default.debounce(
          el,
          event,
          phxDebounce,
          defaultDebounce,
          phxThrottle,
          defaultThrottle,
          asyncFilter,
          () => {
            callback();
          }
        );
      });
    }
    silenceEvents(callback) {
      this.silenced = true;
      callback();
      this.silenced = false;
    }
    on(event, callback) {
      this.boundEventNames.add(event);
      window.addEventListener(event, (e) => {
        if (!this.silenced) {
          callback(e);
        }
      });
    }
    jsQuerySelectorAll(sourceEl, query, defaultQuery) {
      const all = this.domCallbacks.jsQuerySelectorAll;
      return all ? all(sourceEl, query, defaultQuery) : defaultQuery();
    }
  };
  var TransitionSet = class {
    constructor() {
      this.transitions = /* @__PURE__ */ new Set();
      this.promises = /* @__PURE__ */ new Set();
      this.pendingOps = [];
    }
    reset() {
      this.transitions.forEach((timer) => {
        clearTimeout(timer);
        this.transitions.delete(timer);
      });
      this.promises.clear();
      this.flushPendingOps();
    }
    after(callback) {
      if (this.size() === 0) {
        callback();
      } else {
        this.pushPendingOp(callback);
      }
    }
    addTransition(time, onStart, onDone) {
      onStart();
      const timer = setTimeout(() => {
        this.transitions.delete(timer);
        onDone();
        this.flushPendingOps();
      }, time);
      this.transitions.add(timer);
    }
    addAsyncTransition(promise) {
      this.promises.add(promise);
      promise.then(() => {
        this.promises.delete(promise);
        this.flushPendingOps();
      });
    }
    pushPendingOp(op) {
      this.pendingOps.push(op);
    }
    size() {
      return this.transitions.size + this.promises.size;
    }
    flushPendingOps() {
      if (this.size() > 0) {
        return;
      }
      const op = this.pendingOps.shift();
      if (op) {
        op();
        this.flushPendingOps();
      }
    }
  };
  var LiveSocket2 = LiveSocket;

  // js/app.js
  var CollapsibleSection = {
    mounted() {
      this.isOpen = true;
      this.button = this.el.querySelector("button");
      this.contentContainer = this.el.children[1];
      this.previewDiv = this.contentContainer.children[0];
      this.fullContentDiv = this.contentContainer.children[1];
      this.arrow = this.button.querySelector("svg").parentElement;
      this.button.addEventListener("click", () => this.toggle());
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
      this.contentContainer.style.minHeight = "24rem";
      this.previewDiv.style.display = "none";
      this.fullContentDiv.style.display = "block";
      this.arrow.style.transform = "rotate(180deg)";
    },
    collapse() {
      this.contentContainer.style.height = "3rem";
      this.contentContainer.style.minHeight = "auto";
      this.previewDiv.style.display = "block";
      this.fullContentDiv.style.display = "none";
      this.arrow.style.transform = "rotate(0deg)";
    }
  };
  var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var liveSocket = new LiveSocket2("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken },
    hooks: {
      CollapsibleSection
    }
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vLi4vZGVwcy9waG9lbml4X2h0bWwvcHJpdi9zdGF0aWMvcGhvZW5peF9odG1sLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC91dGlscy5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvY29uc3RhbnRzLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC9wdXNoLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC90aW1lci5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvY2hhbm5lbC5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvYWpheC5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvbG9uZ3BvbGwuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4L2Fzc2V0cy9qcy9waG9lbml4L3ByZXNlbmNlLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC9zZXJpYWxpemVyLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC9zb2NrZXQuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvY29uc3RhbnRzLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2VudHJ5X3VwbG9hZGVyLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L3V0aWxzLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2Jyb3dzZXIuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvZG9tLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L3VwbG9hZF9lbnRyeS5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXhfbGl2ZV92aWV3L2Fzc2V0cy9qcy9waG9lbml4X2xpdmVfdmlldy9saXZlX3VwbG9hZGVyLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2FyaWEuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvaG9va3MuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvZWxlbWVudF9yZWYuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvZG9tX3Bvc3RfbW9ycGhfcmVzdG9yZXIuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9ub2RlX21vZHVsZXMvbW9ycGhkb20vZGlzdC9tb3JwaGRvbS1lc20uanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvZG9tX3BhdGNoLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L3JlbmRlcmVkLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2pzLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2pzX2NvbW1hbmRzLnRzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L3ZpZXdfaG9vay50cyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXhfbGl2ZV92aWV3L2Fzc2V0cy9qcy9waG9lbml4X2xpdmVfdmlldy92aWV3LmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2xpdmVfc29ja2V0LmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2luZGV4LnRzIiwgIi4uLy4uLy4uL2Fzc2V0cy9qcy9hcHAuanMiXSwKICAic291cmNlc0NvbnRlbnQiOiBbIlwidXNlIHN0cmljdFwiO1xuXG4oZnVuY3Rpb24oKSB7XG4gIHZhciBQb2x5ZmlsbEV2ZW50ID0gZXZlbnRDb25zdHJ1Y3RvcigpO1xuXG4gIGZ1bmN0aW9uIGV2ZW50Q29uc3RydWN0b3IoKSB7XG4gICAgaWYgKHR5cGVvZiB3aW5kb3cuQ3VzdG9tRXZlbnQgPT09IFwiZnVuY3Rpb25cIikgcmV0dXJuIHdpbmRvdy5DdXN0b21FdmVudDtcbiAgICAvLyBJRTw9OSBTdXBwb3J0XG4gICAgZnVuY3Rpb24gQ3VzdG9tRXZlbnQoZXZlbnQsIHBhcmFtcykge1xuICAgICAgcGFyYW1zID0gcGFyYW1zIHx8IHtidWJibGVzOiBmYWxzZSwgY2FuY2VsYWJsZTogZmFsc2UsIGRldGFpbDogdW5kZWZpbmVkfTtcbiAgICAgIHZhciBldnQgPSBkb2N1bWVudC5jcmVhdGVFdmVudCgnQ3VzdG9tRXZlbnQnKTtcbiAgICAgIGV2dC5pbml0Q3VzdG9tRXZlbnQoZXZlbnQsIHBhcmFtcy5idWJibGVzLCBwYXJhbXMuY2FuY2VsYWJsZSwgcGFyYW1zLmRldGFpbCk7XG4gICAgICByZXR1cm4gZXZ0O1xuICAgIH1cbiAgICBDdXN0b21FdmVudC5wcm90b3R5cGUgPSB3aW5kb3cuRXZlbnQucHJvdG90eXBlO1xuICAgIHJldHVybiBDdXN0b21FdmVudDtcbiAgfVxuXG4gIGZ1bmN0aW9uIGJ1aWxkSGlkZGVuSW5wdXQobmFtZSwgdmFsdWUpIHtcbiAgICB2YXIgaW5wdXQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwiaW5wdXRcIik7XG4gICAgaW5wdXQudHlwZSA9IFwiaGlkZGVuXCI7XG4gICAgaW5wdXQubmFtZSA9IG5hbWU7XG4gICAgaW5wdXQudmFsdWUgPSB2YWx1ZTtcbiAgICByZXR1cm4gaW5wdXQ7XG4gIH1cblxuICBmdW5jdGlvbiBoYW5kbGVDbGljayhlbGVtZW50LCB0YXJnZXRNb2RpZmllcktleSkge1xuICAgIHZhciB0byA9IGVsZW1lbnQuZ2V0QXR0cmlidXRlKFwiZGF0YS10b1wiKSxcbiAgICAgICAgbWV0aG9kID0gYnVpbGRIaWRkZW5JbnB1dChcIl9tZXRob2RcIiwgZWxlbWVudC5nZXRBdHRyaWJ1dGUoXCJkYXRhLW1ldGhvZFwiKSksXG4gICAgICAgIGNzcmYgPSBidWlsZEhpZGRlbklucHV0KFwiX2NzcmZfdG9rZW5cIiwgZWxlbWVudC5nZXRBdHRyaWJ1dGUoXCJkYXRhLWNzcmZcIikpLFxuICAgICAgICBmb3JtID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcImZvcm1cIiksXG4gICAgICAgIHN1Ym1pdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJpbnB1dFwiKSxcbiAgICAgICAgdGFyZ2V0ID0gZWxlbWVudC5nZXRBdHRyaWJ1dGUoXCJ0YXJnZXRcIik7XG5cbiAgICBmb3JtLm1ldGhvZCA9IChlbGVtZW50LmdldEF0dHJpYnV0ZShcImRhdGEtbWV0aG9kXCIpID09PSBcImdldFwiKSA/IFwiZ2V0XCIgOiBcInBvc3RcIjtcbiAgICBmb3JtLmFjdGlvbiA9IHRvO1xuICAgIGZvcm0uc3R5bGUuZGlzcGxheSA9IFwibm9uZVwiO1xuXG4gICAgaWYgKHRhcmdldCkgZm9ybS50YXJnZXQgPSB0YXJnZXQ7XG4gICAgZWxzZSBpZiAodGFyZ2V0TW9kaWZpZXJLZXkpIGZvcm0udGFyZ2V0ID0gXCJfYmxhbmtcIjtcblxuICAgIGZvcm0uYXBwZW5kQ2hpbGQoY3NyZik7XG4gICAgZm9ybS5hcHBlbmRDaGlsZChtZXRob2QpO1xuICAgIGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoZm9ybSk7XG5cbiAgICAvLyBJbnNlcnQgYSBidXR0b24gYW5kIGNsaWNrIGl0IGluc3RlYWQgb2YgdXNpbmcgYGZvcm0uc3VibWl0YFxuICAgIC8vIGJlY2F1c2UgdGhlIGBzdWJtaXRgIGZ1bmN0aW9uIGRvZXMgbm90IGVtaXQgYSBgc3VibWl0YCBldmVudC5cbiAgICBzdWJtaXQudHlwZSA9IFwic3VibWl0XCI7XG4gICAgZm9ybS5hcHBlbmRDaGlsZChzdWJtaXQpO1xuICAgIHN1Ym1pdC5jbGljaygpO1xuICB9XG5cbiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoXCJjbGlja1wiLCBmdW5jdGlvbihlKSB7XG4gICAgdmFyIGVsZW1lbnQgPSBlLnRhcmdldDtcbiAgICBpZiAoZS5kZWZhdWx0UHJldmVudGVkKSByZXR1cm47XG5cbiAgICB3aGlsZSAoZWxlbWVudCAmJiBlbGVtZW50LmdldEF0dHJpYnV0ZSkge1xuICAgICAgdmFyIHBob2VuaXhMaW5rRXZlbnQgPSBuZXcgUG9seWZpbGxFdmVudCgncGhvZW5peC5saW5rLmNsaWNrJywge1xuICAgICAgICBcImJ1YmJsZXNcIjogdHJ1ZSwgXCJjYW5jZWxhYmxlXCI6IHRydWVcbiAgICAgIH0pO1xuXG4gICAgICBpZiAoIWVsZW1lbnQuZGlzcGF0Y2hFdmVudChwaG9lbml4TGlua0V2ZW50KSkge1xuICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7XG4gICAgICAgIGUuc3RvcEltbWVkaWF0ZVByb3BhZ2F0aW9uKCk7XG4gICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgIH1cblxuICAgICAgaWYgKGVsZW1lbnQuZ2V0QXR0cmlidXRlKFwiZGF0YS1tZXRob2RcIikgJiYgZWxlbWVudC5nZXRBdHRyaWJ1dGUoXCJkYXRhLXRvXCIpKSB7XG4gICAgICAgIGhhbmRsZUNsaWNrKGVsZW1lbnQsIGUubWV0YUtleSB8fCBlLnNoaWZ0S2V5KTtcbiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpO1xuICAgICAgICByZXR1cm4gZmFsc2U7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICBlbGVtZW50ID0gZWxlbWVudC5wYXJlbnROb2RlO1xuICAgICAgfVxuICAgIH1cbiAgfSwgZmFsc2UpO1xuXG4gIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdwaG9lbml4LmxpbmsuY2xpY2snLCBmdW5jdGlvbiAoZSkge1xuICAgIHZhciBtZXNzYWdlID0gZS50YXJnZXQuZ2V0QXR0cmlidXRlKFwiZGF0YS1jb25maXJtXCIpO1xuICAgIGlmKG1lc3NhZ2UgJiYgIXdpbmRvdy5jb25maXJtKG1lc3NhZ2UpKSB7XG4gICAgICBlLnByZXZlbnREZWZhdWx0KCk7XG4gICAgfVxuICB9LCBmYWxzZSk7XG59KSgpO1xuIiwgIi8vIHdyYXBzIHZhbHVlIGluIGNsb3N1cmUgb3IgcmV0dXJucyBjbG9zdXJlXG5leHBvcnQgbGV0IGNsb3N1cmUgPSAodmFsdWUpID0+IHtcbiAgaWYodHlwZW9mIHZhbHVlID09PSBcImZ1bmN0aW9uXCIpe1xuICAgIHJldHVybiB2YWx1ZVxuICB9IGVsc2Uge1xuICAgIGxldCBjbG9zdXJlID0gZnVuY3Rpb24gKCl7IHJldHVybiB2YWx1ZSB9XG4gICAgcmV0dXJuIGNsb3N1cmVcbiAgfVxufVxuIiwgImV4cG9ydCBjb25zdCBnbG9iYWxTZWxmID0gdHlwZW9mIHNlbGYgIT09IFwidW5kZWZpbmVkXCIgPyBzZWxmIDogbnVsbFxuZXhwb3J0IGNvbnN0IHBoeFdpbmRvdyA9IHR5cGVvZiB3aW5kb3cgIT09IFwidW5kZWZpbmVkXCIgPyB3aW5kb3cgOiBudWxsXG5leHBvcnQgY29uc3QgZ2xvYmFsID0gZ2xvYmFsU2VsZiB8fCBwaHhXaW5kb3cgfHwgZ2xvYmFsVGhpc1xuZXhwb3J0IGNvbnN0IERFRkFVTFRfVlNOID0gXCIyLjAuMFwiXG5leHBvcnQgY29uc3QgU09DS0VUX1NUQVRFUyA9IHtjb25uZWN0aW5nOiAwLCBvcGVuOiAxLCBjbG9zaW5nOiAyLCBjbG9zZWQ6IDN9XG5leHBvcnQgY29uc3QgREVGQVVMVF9USU1FT1VUID0gMTAwMDBcbmV4cG9ydCBjb25zdCBXU19DTE9TRV9OT1JNQUwgPSAxMDAwXG5leHBvcnQgY29uc3QgQ0hBTk5FTF9TVEFURVMgPSB7XG4gIGNsb3NlZDogXCJjbG9zZWRcIixcbiAgZXJyb3JlZDogXCJlcnJvcmVkXCIsXG4gIGpvaW5lZDogXCJqb2luZWRcIixcbiAgam9pbmluZzogXCJqb2luaW5nXCIsXG4gIGxlYXZpbmc6IFwibGVhdmluZ1wiLFxufVxuZXhwb3J0IGNvbnN0IENIQU5ORUxfRVZFTlRTID0ge1xuICBjbG9zZTogXCJwaHhfY2xvc2VcIixcbiAgZXJyb3I6IFwicGh4X2Vycm9yXCIsXG4gIGpvaW46IFwicGh4X2pvaW5cIixcbiAgcmVwbHk6IFwicGh4X3JlcGx5XCIsXG4gIGxlYXZlOiBcInBoeF9sZWF2ZVwiXG59XG5cbmV4cG9ydCBjb25zdCBUUkFOU1BPUlRTID0ge1xuICBsb25ncG9sbDogXCJsb25ncG9sbFwiLFxuICB3ZWJzb2NrZXQ6IFwid2Vic29ja2V0XCJcbn1cbmV4cG9ydCBjb25zdCBYSFJfU1RBVEVTID0ge1xuICBjb21wbGV0ZTogNFxufVxuZXhwb3J0IGNvbnN0IEFVVEhfVE9LRU5fUFJFRklYID0gXCJiYXNlNjR1cmwuYmVhcmVyLnBoeC5cIlxuIiwgIi8qKlxuICogSW5pdGlhbGl6ZXMgdGhlIFB1c2hcbiAqIEBwYXJhbSB7Q2hhbm5lbH0gY2hhbm5lbCAtIFRoZSBDaGFubmVsXG4gKiBAcGFyYW0ge3N0cmluZ30gZXZlbnQgLSBUaGUgZXZlbnQsIGZvciBleGFtcGxlIGBcInBoeF9qb2luXCJgXG4gKiBAcGFyYW0ge09iamVjdH0gcGF5bG9hZCAtIFRoZSBwYXlsb2FkLCBmb3IgZXhhbXBsZSBge3VzZXJfaWQ6IDEyM31gXG4gKiBAcGFyYW0ge251bWJlcn0gdGltZW91dCAtIFRoZSBwdXNoIHRpbWVvdXQgaW4gbWlsbGlzZWNvbmRzXG4gKi9cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFB1c2gge1xuICBjb25zdHJ1Y3RvcihjaGFubmVsLCBldmVudCwgcGF5bG9hZCwgdGltZW91dCl7XG4gICAgdGhpcy5jaGFubmVsID0gY2hhbm5lbFxuICAgIHRoaXMuZXZlbnQgPSBldmVudFxuICAgIHRoaXMucGF5bG9hZCA9IHBheWxvYWQgfHwgZnVuY3Rpb24gKCl7IHJldHVybiB7fSB9XG4gICAgdGhpcy5yZWNlaXZlZFJlc3AgPSBudWxsXG4gICAgdGhpcy50aW1lb3V0ID0gdGltZW91dFxuICAgIHRoaXMudGltZW91dFRpbWVyID0gbnVsbFxuICAgIHRoaXMucmVjSG9va3MgPSBbXVxuICAgIHRoaXMuc2VudCA9IGZhbHNlXG4gIH1cblxuICAvKipcbiAgICpcbiAgICogQHBhcmFtIHtudW1iZXJ9IHRpbWVvdXRcbiAgICovXG4gIHJlc2VuZCh0aW1lb3V0KXtcbiAgICB0aGlzLnRpbWVvdXQgPSB0aW1lb3V0XG4gICAgdGhpcy5yZXNldCgpXG4gICAgdGhpcy5zZW5kKClcbiAgfVxuXG4gIC8qKlxuICAgKlxuICAgKi9cbiAgc2VuZCgpe1xuICAgIGlmKHRoaXMuaGFzUmVjZWl2ZWQoXCJ0aW1lb3V0XCIpKXsgcmV0dXJuIH1cbiAgICB0aGlzLnN0YXJ0VGltZW91dCgpXG4gICAgdGhpcy5zZW50ID0gdHJ1ZVxuICAgIHRoaXMuY2hhbm5lbC5zb2NrZXQucHVzaCh7XG4gICAgICB0b3BpYzogdGhpcy5jaGFubmVsLnRvcGljLFxuICAgICAgZXZlbnQ6IHRoaXMuZXZlbnQsXG4gICAgICBwYXlsb2FkOiB0aGlzLnBheWxvYWQoKSxcbiAgICAgIHJlZjogdGhpcy5yZWYsXG4gICAgICBqb2luX3JlZjogdGhpcy5jaGFubmVsLmpvaW5SZWYoKVxuICAgIH0pXG4gIH1cblxuICAvKipcbiAgICpcbiAgICogQHBhcmFtIHsqfSBzdGF0dXNcbiAgICogQHBhcmFtIHsqfSBjYWxsYmFja1xuICAgKi9cbiAgcmVjZWl2ZShzdGF0dXMsIGNhbGxiYWNrKXtcbiAgICBpZih0aGlzLmhhc1JlY2VpdmVkKHN0YXR1cykpe1xuICAgICAgY2FsbGJhY2sodGhpcy5yZWNlaXZlZFJlc3AucmVzcG9uc2UpXG4gICAgfVxuXG4gICAgdGhpcy5yZWNIb29rcy5wdXNoKHtzdGF0dXMsIGNhbGxiYWNrfSlcbiAgICByZXR1cm4gdGhpc1xuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICByZXNldCgpe1xuICAgIHRoaXMuY2FuY2VsUmVmRXZlbnQoKVxuICAgIHRoaXMucmVmID0gbnVsbFxuICAgIHRoaXMucmVmRXZlbnQgPSBudWxsXG4gICAgdGhpcy5yZWNlaXZlZFJlc3AgPSBudWxsXG4gICAgdGhpcy5zZW50ID0gZmFsc2VcbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgbWF0Y2hSZWNlaXZlKHtzdGF0dXMsIHJlc3BvbnNlLCBfcmVmfSl7XG4gICAgdGhpcy5yZWNIb29rcy5maWx0ZXIoaCA9PiBoLnN0YXR1cyA9PT0gc3RhdHVzKVxuICAgICAgLmZvckVhY2goaCA9PiBoLmNhbGxiYWNrKHJlc3BvbnNlKSlcbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgY2FuY2VsUmVmRXZlbnQoKXtcbiAgICBpZighdGhpcy5yZWZFdmVudCl7IHJldHVybiB9XG4gICAgdGhpcy5jaGFubmVsLm9mZih0aGlzLnJlZkV2ZW50KVxuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBjYW5jZWxUaW1lb3V0KCl7XG4gICAgY2xlYXJUaW1lb3V0KHRoaXMudGltZW91dFRpbWVyKVxuICAgIHRoaXMudGltZW91dFRpbWVyID0gbnVsbFxuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBzdGFydFRpbWVvdXQoKXtcbiAgICBpZih0aGlzLnRpbWVvdXRUaW1lcil7IHRoaXMuY2FuY2VsVGltZW91dCgpIH1cbiAgICB0aGlzLnJlZiA9IHRoaXMuY2hhbm5lbC5zb2NrZXQubWFrZVJlZigpXG4gICAgdGhpcy5yZWZFdmVudCA9IHRoaXMuY2hhbm5lbC5yZXBseUV2ZW50TmFtZSh0aGlzLnJlZilcblxuICAgIHRoaXMuY2hhbm5lbC5vbih0aGlzLnJlZkV2ZW50LCBwYXlsb2FkID0+IHtcbiAgICAgIHRoaXMuY2FuY2VsUmVmRXZlbnQoKVxuICAgICAgdGhpcy5jYW5jZWxUaW1lb3V0KClcbiAgICAgIHRoaXMucmVjZWl2ZWRSZXNwID0gcGF5bG9hZFxuICAgICAgdGhpcy5tYXRjaFJlY2VpdmUocGF5bG9hZClcbiAgICB9KVxuXG4gICAgdGhpcy50aW1lb3V0VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgIHRoaXMudHJpZ2dlcihcInRpbWVvdXRcIiwge30pXG4gICAgfSwgdGhpcy50aW1lb3V0KVxuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBoYXNSZWNlaXZlZChzdGF0dXMpe1xuICAgIHJldHVybiB0aGlzLnJlY2VpdmVkUmVzcCAmJiB0aGlzLnJlY2VpdmVkUmVzcC5zdGF0dXMgPT09IHN0YXR1c1xuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICB0cmlnZ2VyKHN0YXR1cywgcmVzcG9uc2Upe1xuICAgIHRoaXMuY2hhbm5lbC50cmlnZ2VyKHRoaXMucmVmRXZlbnQsIHtzdGF0dXMsIHJlc3BvbnNlfSlcbiAgfVxufVxuIiwgIi8qKlxuICpcbiAqIENyZWF0ZXMgYSB0aW1lciB0aGF0IGFjY2VwdHMgYSBgdGltZXJDYWxjYCBmdW5jdGlvbiB0byBwZXJmb3JtXG4gKiBjYWxjdWxhdGVkIHRpbWVvdXQgcmV0cmllcywgc3VjaCBhcyBleHBvbmVudGlhbCBiYWNrb2ZmLlxuICpcbiAqIEBleGFtcGxlXG4gKiBsZXQgcmVjb25uZWN0VGltZXIgPSBuZXcgVGltZXIoKCkgPT4gdGhpcy5jb25uZWN0KCksIGZ1bmN0aW9uKHRyaWVzKXtcbiAqICAgcmV0dXJuIFsxMDAwLCA1MDAwLCAxMDAwMF1bdHJpZXMgLSAxXSB8fCAxMDAwMFxuICogfSlcbiAqIHJlY29ubmVjdFRpbWVyLnNjaGVkdWxlVGltZW91dCgpIC8vIGZpcmVzIGFmdGVyIDEwMDBcbiAqIHJlY29ubmVjdFRpbWVyLnNjaGVkdWxlVGltZW91dCgpIC8vIGZpcmVzIGFmdGVyIDUwMDBcbiAqIHJlY29ubmVjdFRpbWVyLnJlc2V0KClcbiAqIHJlY29ubmVjdFRpbWVyLnNjaGVkdWxlVGltZW91dCgpIC8vIGZpcmVzIGFmdGVyIDEwMDBcbiAqXG4gKiBAcGFyYW0ge0Z1bmN0aW9ufSBjYWxsYmFja1xuICogQHBhcmFtIHtGdW5jdGlvbn0gdGltZXJDYWxjXG4gKi9cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFRpbWVyIHtcbiAgY29uc3RydWN0b3IoY2FsbGJhY2ssIHRpbWVyQ2FsYyl7XG4gICAgdGhpcy5jYWxsYmFjayA9IGNhbGxiYWNrXG4gICAgdGhpcy50aW1lckNhbGMgPSB0aW1lckNhbGNcbiAgICB0aGlzLnRpbWVyID0gbnVsbFxuICAgIHRoaXMudHJpZXMgPSAwXG4gIH1cblxuICByZXNldCgpe1xuICAgIHRoaXMudHJpZXMgPSAwXG4gICAgY2xlYXJUaW1lb3V0KHRoaXMudGltZXIpXG4gIH1cblxuICAvKipcbiAgICogQ2FuY2VscyBhbnkgcHJldmlvdXMgc2NoZWR1bGVUaW1lb3V0IGFuZCBzY2hlZHVsZXMgY2FsbGJhY2tcbiAgICovXG4gIHNjaGVkdWxlVGltZW91dCgpe1xuICAgIGNsZWFyVGltZW91dCh0aGlzLnRpbWVyKVxuXG4gICAgdGhpcy50aW1lciA9IHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgdGhpcy50cmllcyA9IHRoaXMudHJpZXMgKyAxXG4gICAgICB0aGlzLmNhbGxiYWNrKClcbiAgICB9LCB0aGlzLnRpbWVyQ2FsYyh0aGlzLnRyaWVzICsgMSkpXG4gIH1cbn1cbiIsICJpbXBvcnQge2Nsb3N1cmV9IGZyb20gXCIuL3V0aWxzXCJcbmltcG9ydCB7XG4gIENIQU5ORUxfRVZFTlRTLFxuICBDSEFOTkVMX1NUQVRFUyxcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCJcblxuaW1wb3J0IFB1c2ggZnJvbSBcIi4vcHVzaFwiXG5pbXBvcnQgVGltZXIgZnJvbSBcIi4vdGltZXJcIlxuXG4vKipcbiAqXG4gKiBAcGFyYW0ge3N0cmluZ30gdG9waWNcbiAqIEBwYXJhbSB7KE9iamVjdHxmdW5jdGlvbil9IHBhcmFtc1xuICogQHBhcmFtIHtTb2NrZXR9IHNvY2tldFxuICovXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBDaGFubmVsIHtcbiAgY29uc3RydWN0b3IodG9waWMsIHBhcmFtcywgc29ja2V0KXtcbiAgICB0aGlzLnN0YXRlID0gQ0hBTk5FTF9TVEFURVMuY2xvc2VkXG4gICAgdGhpcy50b3BpYyA9IHRvcGljXG4gICAgdGhpcy5wYXJhbXMgPSBjbG9zdXJlKHBhcmFtcyB8fCB7fSlcbiAgICB0aGlzLnNvY2tldCA9IHNvY2tldFxuICAgIHRoaXMuYmluZGluZ3MgPSBbXVxuICAgIHRoaXMuYmluZGluZ1JlZiA9IDBcbiAgICB0aGlzLnRpbWVvdXQgPSB0aGlzLnNvY2tldC50aW1lb3V0XG4gICAgdGhpcy5qb2luZWRPbmNlID0gZmFsc2VcbiAgICB0aGlzLmpvaW5QdXNoID0gbmV3IFB1c2godGhpcywgQ0hBTk5FTF9FVkVOVFMuam9pbiwgdGhpcy5wYXJhbXMsIHRoaXMudGltZW91dClcbiAgICB0aGlzLnB1c2hCdWZmZXIgPSBbXVxuICAgIHRoaXMuc3RhdGVDaGFuZ2VSZWZzID0gW11cblxuICAgIHRoaXMucmVqb2luVGltZXIgPSBuZXcgVGltZXIoKCkgPT4ge1xuICAgICAgaWYodGhpcy5zb2NrZXQuaXNDb25uZWN0ZWQoKSl7IHRoaXMucmVqb2luKCkgfVxuICAgIH0sIHRoaXMuc29ja2V0LnJlam9pbkFmdGVyTXMpXG4gICAgdGhpcy5zdGF0ZUNoYW5nZVJlZnMucHVzaCh0aGlzLnNvY2tldC5vbkVycm9yKCgpID0+IHRoaXMucmVqb2luVGltZXIucmVzZXQoKSkpXG4gICAgdGhpcy5zdGF0ZUNoYW5nZVJlZnMucHVzaCh0aGlzLnNvY2tldC5vbk9wZW4oKCkgPT4ge1xuICAgICAgdGhpcy5yZWpvaW5UaW1lci5yZXNldCgpXG4gICAgICBpZih0aGlzLmlzRXJyb3JlZCgpKXsgdGhpcy5yZWpvaW4oKSB9XG4gICAgfSlcbiAgICApXG4gICAgdGhpcy5qb2luUHVzaC5yZWNlaXZlKFwib2tcIiwgKCkgPT4ge1xuICAgICAgdGhpcy5zdGF0ZSA9IENIQU5ORUxfU1RBVEVTLmpvaW5lZFxuICAgICAgdGhpcy5yZWpvaW5UaW1lci5yZXNldCgpXG4gICAgICB0aGlzLnB1c2hCdWZmZXIuZm9yRWFjaChwdXNoRXZlbnQgPT4gcHVzaEV2ZW50LnNlbmQoKSlcbiAgICAgIHRoaXMucHVzaEJ1ZmZlciA9IFtdXG4gICAgfSlcbiAgICB0aGlzLmpvaW5QdXNoLnJlY2VpdmUoXCJlcnJvclwiLCAoKSA9PiB7XG4gICAgICB0aGlzLnN0YXRlID0gQ0hBTk5FTF9TVEFURVMuZXJyb3JlZFxuICAgICAgaWYodGhpcy5zb2NrZXQuaXNDb25uZWN0ZWQoKSl7IHRoaXMucmVqb2luVGltZXIuc2NoZWR1bGVUaW1lb3V0KCkgfVxuICAgIH0pXG4gICAgdGhpcy5vbkNsb3NlKCgpID0+IHtcbiAgICAgIHRoaXMucmVqb2luVGltZXIucmVzZXQoKVxuICAgICAgaWYodGhpcy5zb2NrZXQuaGFzTG9nZ2VyKCkpIHRoaXMuc29ja2V0LmxvZyhcImNoYW5uZWxcIiwgYGNsb3NlICR7dGhpcy50b3BpY30gJHt0aGlzLmpvaW5SZWYoKX1gKVxuICAgICAgdGhpcy5zdGF0ZSA9IENIQU5ORUxfU1RBVEVTLmNsb3NlZFxuICAgICAgdGhpcy5zb2NrZXQucmVtb3ZlKHRoaXMpXG4gICAgfSlcbiAgICB0aGlzLm9uRXJyb3IocmVhc29uID0+IHtcbiAgICAgIGlmKHRoaXMuc29ja2V0Lmhhc0xvZ2dlcigpKSB0aGlzLnNvY2tldC5sb2coXCJjaGFubmVsXCIsIGBlcnJvciAke3RoaXMudG9waWN9YCwgcmVhc29uKVxuICAgICAgaWYodGhpcy5pc0pvaW5pbmcoKSl7IHRoaXMuam9pblB1c2gucmVzZXQoKSB9XG4gICAgICB0aGlzLnN0YXRlID0gQ0hBTk5FTF9TVEFURVMuZXJyb3JlZFxuICAgICAgaWYodGhpcy5zb2NrZXQuaXNDb25uZWN0ZWQoKSl7IHRoaXMucmVqb2luVGltZXIuc2NoZWR1bGVUaW1lb3V0KCkgfVxuICAgIH0pXG4gICAgdGhpcy5qb2luUHVzaC5yZWNlaXZlKFwidGltZW91dFwiLCAoKSA9PiB7XG4gICAgICBpZih0aGlzLnNvY2tldC5oYXNMb2dnZXIoKSkgdGhpcy5zb2NrZXQubG9nKFwiY2hhbm5lbFwiLCBgdGltZW91dCAke3RoaXMudG9waWN9ICgke3RoaXMuam9pblJlZigpfSlgLCB0aGlzLmpvaW5QdXNoLnRpbWVvdXQpXG4gICAgICBsZXQgbGVhdmVQdXNoID0gbmV3IFB1c2godGhpcywgQ0hBTk5FTF9FVkVOVFMubGVhdmUsIGNsb3N1cmUoe30pLCB0aGlzLnRpbWVvdXQpXG4gICAgICBsZWF2ZVB1c2guc2VuZCgpXG4gICAgICB0aGlzLnN0YXRlID0gQ0hBTk5FTF9TVEFURVMuZXJyb3JlZFxuICAgICAgdGhpcy5qb2luUHVzaC5yZXNldCgpXG4gICAgICBpZih0aGlzLnNvY2tldC5pc0Nvbm5lY3RlZCgpKXsgdGhpcy5yZWpvaW5UaW1lci5zY2hlZHVsZVRpbWVvdXQoKSB9XG4gICAgfSlcbiAgICB0aGlzLm9uKENIQU5ORUxfRVZFTlRTLnJlcGx5LCAocGF5bG9hZCwgcmVmKSA9PiB7XG4gICAgICB0aGlzLnRyaWdnZXIodGhpcy5yZXBseUV2ZW50TmFtZShyZWYpLCBwYXlsb2FkKVxuICAgIH0pXG4gIH1cblxuICAvKipcbiAgICogSm9pbiB0aGUgY2hhbm5lbFxuICAgKiBAcGFyYW0ge2ludGVnZXJ9IHRpbWVvdXRcbiAgICogQHJldHVybnMge1B1c2h9XG4gICAqL1xuICBqb2luKHRpbWVvdXQgPSB0aGlzLnRpbWVvdXQpe1xuICAgIGlmKHRoaXMuam9pbmVkT25jZSl7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoXCJ0cmllZCB0byBqb2luIG11bHRpcGxlIHRpbWVzLiAnam9pbicgY2FuIG9ubHkgYmUgY2FsbGVkIGEgc2luZ2xlIHRpbWUgcGVyIGNoYW5uZWwgaW5zdGFuY2VcIilcbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy50aW1lb3V0ID0gdGltZW91dFxuICAgICAgdGhpcy5qb2luZWRPbmNlID0gdHJ1ZVxuICAgICAgdGhpcy5yZWpvaW4oKVxuICAgICAgcmV0dXJuIHRoaXMuam9pblB1c2hcbiAgICB9XG4gIH1cblxuICAvKipcbiAgICogSG9vayBpbnRvIGNoYW5uZWwgY2xvc2VcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2tcbiAgICovXG4gIG9uQ2xvc2UoY2FsbGJhY2spe1xuICAgIHRoaXMub24oQ0hBTk5FTF9FVkVOVFMuY2xvc2UsIGNhbGxiYWNrKVxuICB9XG5cbiAgLyoqXG4gICAqIEhvb2sgaW50byBjaGFubmVsIGVycm9yc1xuICAgKiBAcGFyYW0ge0Z1bmN0aW9ufSBjYWxsYmFja1xuICAgKi9cbiAgb25FcnJvcihjYWxsYmFjayl7XG4gICAgcmV0dXJuIHRoaXMub24oQ0hBTk5FTF9FVkVOVFMuZXJyb3IsIHJlYXNvbiA9PiBjYWxsYmFjayhyZWFzb24pKVxuICB9XG5cbiAgLyoqXG4gICAqIFN1YnNjcmliZXMgb24gY2hhbm5lbCBldmVudHNcbiAgICpcbiAgICogU3Vic2NyaXB0aW9uIHJldHVybnMgYSByZWYgY291bnRlciwgd2hpY2ggY2FuIGJlIHVzZWQgbGF0ZXIgdG9cbiAgICogdW5zdWJzY3JpYmUgdGhlIGV4YWN0IGV2ZW50IGxpc3RlbmVyXG4gICAqXG4gICAqIEBleGFtcGxlXG4gICAqIGNvbnN0IHJlZjEgPSBjaGFubmVsLm9uKFwiZXZlbnRcIiwgZG9fc3R1ZmYpXG4gICAqIGNvbnN0IHJlZjIgPSBjaGFubmVsLm9uKFwiZXZlbnRcIiwgZG9fb3RoZXJfc3R1ZmYpXG4gICAqIGNoYW5uZWwub2ZmKFwiZXZlbnRcIiwgcmVmMSlcbiAgICogLy8gU2luY2UgdW5zdWJzY3JpcHRpb24sIGRvX3N0dWZmIHdvbid0IGZpcmUsXG4gICAqIC8vIHdoaWxlIGRvX290aGVyX3N0dWZmIHdpbGwga2VlcCBmaXJpbmcgb24gdGhlIFwiZXZlbnRcIlxuICAgKlxuICAgKiBAcGFyYW0ge3N0cmluZ30gZXZlbnRcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2tcbiAgICogQHJldHVybnMge2ludGVnZXJ9IHJlZlxuICAgKi9cbiAgb24oZXZlbnQsIGNhbGxiYWNrKXtcbiAgICBsZXQgcmVmID0gdGhpcy5iaW5kaW5nUmVmKytcbiAgICB0aGlzLmJpbmRpbmdzLnB1c2goe2V2ZW50LCByZWYsIGNhbGxiYWNrfSlcbiAgICByZXR1cm4gcmVmXG4gIH1cblxuICAvKipcbiAgICogVW5zdWJzY3JpYmVzIG9mZiBvZiBjaGFubmVsIGV2ZW50c1xuICAgKlxuICAgKiBVc2UgdGhlIHJlZiByZXR1cm5lZCBmcm9tIGEgY2hhbm5lbC5vbigpIHRvIHVuc3Vic2NyaWJlIG9uZVxuICAgKiBoYW5kbGVyLCBvciBwYXNzIG5vdGhpbmcgZm9yIHRoZSByZWYgdG8gdW5zdWJzY3JpYmUgYWxsXG4gICAqIGhhbmRsZXJzIGZvciB0aGUgZ2l2ZW4gZXZlbnQuXG4gICAqXG4gICAqIEBleGFtcGxlXG4gICAqIC8vIFVuc3Vic2NyaWJlIHRoZSBkb19zdHVmZiBoYW5kbGVyXG4gICAqIGNvbnN0IHJlZjEgPSBjaGFubmVsLm9uKFwiZXZlbnRcIiwgZG9fc3R1ZmYpXG4gICAqIGNoYW5uZWwub2ZmKFwiZXZlbnRcIiwgcmVmMSlcbiAgICpcbiAgICogLy8gVW5zdWJzY3JpYmUgYWxsIGhhbmRsZXJzIGZyb20gZXZlbnRcbiAgICogY2hhbm5lbC5vZmYoXCJldmVudFwiKVxuICAgKlxuICAgKiBAcGFyYW0ge3N0cmluZ30gZXZlbnRcbiAgICogQHBhcmFtIHtpbnRlZ2VyfSByZWZcbiAgICovXG4gIG9mZihldmVudCwgcmVmKXtcbiAgICB0aGlzLmJpbmRpbmdzID0gdGhpcy5iaW5kaW5ncy5maWx0ZXIoKGJpbmQpID0+IHtcbiAgICAgIHJldHVybiAhKGJpbmQuZXZlbnQgPT09IGV2ZW50ICYmICh0eXBlb2YgcmVmID09PSBcInVuZGVmaW5lZFwiIHx8IHJlZiA9PT0gYmluZC5yZWYpKVxuICAgIH0pXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIGNhblB1c2goKXsgcmV0dXJuIHRoaXMuc29ja2V0LmlzQ29ubmVjdGVkKCkgJiYgdGhpcy5pc0pvaW5lZCgpIH1cblxuICAvKipcbiAgICogU2VuZHMgYSBtZXNzYWdlIGBldmVudGAgdG8gcGhvZW5peCB3aXRoIHRoZSBwYXlsb2FkIGBwYXlsb2FkYC5cbiAgICogUGhvZW5peCByZWNlaXZlcyB0aGlzIGluIHRoZSBgaGFuZGxlX2luKGV2ZW50LCBwYXlsb2FkLCBzb2NrZXQpYFxuICAgKiBmdW5jdGlvbi4gaWYgcGhvZW5peCByZXBsaWVzIG9yIGl0IHRpbWVzIG91dCAoZGVmYXVsdCAxMDAwMG1zKSxcbiAgICogdGhlbiBvcHRpb25hbGx5IHRoZSByZXBseSBjYW4gYmUgcmVjZWl2ZWQuXG4gICAqXG4gICAqIEBleGFtcGxlXG4gICAqIGNoYW5uZWwucHVzaChcImV2ZW50XCIpXG4gICAqICAgLnJlY2VpdmUoXCJva1wiLCBwYXlsb2FkID0+IGNvbnNvbGUubG9nKFwicGhvZW5peCByZXBsaWVkOlwiLCBwYXlsb2FkKSlcbiAgICogICAucmVjZWl2ZShcImVycm9yXCIsIGVyciA9PiBjb25zb2xlLmxvZyhcInBob2VuaXggZXJyb3JlZFwiLCBlcnIpKVxuICAgKiAgIC5yZWNlaXZlKFwidGltZW91dFwiLCAoKSA9PiBjb25zb2xlLmxvZyhcInRpbWVkIG91dCBwdXNoaW5nXCIpKVxuICAgKiBAcGFyYW0ge3N0cmluZ30gZXZlbnRcbiAgICogQHBhcmFtIHtPYmplY3R9IHBheWxvYWRcbiAgICogQHBhcmFtIHtudW1iZXJ9IFt0aW1lb3V0XVxuICAgKiBAcmV0dXJucyB7UHVzaH1cbiAgICovXG4gIHB1c2goZXZlbnQsIHBheWxvYWQsIHRpbWVvdXQgPSB0aGlzLnRpbWVvdXQpe1xuICAgIHBheWxvYWQgPSBwYXlsb2FkIHx8IHt9XG4gICAgaWYoIXRoaXMuam9pbmVkT25jZSl7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoYHRyaWVkIHRvIHB1c2ggJyR7ZXZlbnR9JyB0byAnJHt0aGlzLnRvcGljfScgYmVmb3JlIGpvaW5pbmcuIFVzZSBjaGFubmVsLmpvaW4oKSBiZWZvcmUgcHVzaGluZyBldmVudHNgKVxuICAgIH1cbiAgICBsZXQgcHVzaEV2ZW50ID0gbmV3IFB1c2godGhpcywgZXZlbnQsIGZ1bmN0aW9uICgpeyByZXR1cm4gcGF5bG9hZCB9LCB0aW1lb3V0KVxuICAgIGlmKHRoaXMuY2FuUHVzaCgpKXtcbiAgICAgIHB1c2hFdmVudC5zZW5kKClcbiAgICB9IGVsc2Uge1xuICAgICAgcHVzaEV2ZW50LnN0YXJ0VGltZW91dCgpXG4gICAgICB0aGlzLnB1c2hCdWZmZXIucHVzaChwdXNoRXZlbnQpXG4gICAgfVxuXG4gICAgcmV0dXJuIHB1c2hFdmVudFxuICB9XG5cbiAgLyoqIExlYXZlcyB0aGUgY2hhbm5lbFxuICAgKlxuICAgKiBVbnN1YnNjcmliZXMgZnJvbSBzZXJ2ZXIgZXZlbnRzLCBhbmRcbiAgICogaW5zdHJ1Y3RzIGNoYW5uZWwgdG8gdGVybWluYXRlIG9uIHNlcnZlclxuICAgKlxuICAgKiBUcmlnZ2VycyBvbkNsb3NlKCkgaG9va3NcbiAgICpcbiAgICogVG8gcmVjZWl2ZSBsZWF2ZSBhY2tub3dsZWRnZW1lbnRzLCB1c2UgdGhlIGByZWNlaXZlYFxuICAgKiBob29rIHRvIGJpbmQgdG8gdGhlIHNlcnZlciBhY2ssIGllOlxuICAgKlxuICAgKiBAZXhhbXBsZVxuICAgKiBjaGFubmVsLmxlYXZlKCkucmVjZWl2ZShcIm9rXCIsICgpID0+IGFsZXJ0KFwibGVmdCFcIikgKVxuICAgKlxuICAgKiBAcGFyYW0ge2ludGVnZXJ9IHRpbWVvdXRcbiAgICogQHJldHVybnMge1B1c2h9XG4gICAqL1xuICBsZWF2ZSh0aW1lb3V0ID0gdGhpcy50aW1lb3V0KXtcbiAgICB0aGlzLnJlam9pblRpbWVyLnJlc2V0KClcbiAgICB0aGlzLmpvaW5QdXNoLmNhbmNlbFRpbWVvdXQoKVxuXG4gICAgdGhpcy5zdGF0ZSA9IENIQU5ORUxfU1RBVEVTLmxlYXZpbmdcbiAgICBsZXQgb25DbG9zZSA9ICgpID0+IHtcbiAgICAgIGlmKHRoaXMuc29ja2V0Lmhhc0xvZ2dlcigpKSB0aGlzLnNvY2tldC5sb2coXCJjaGFubmVsXCIsIGBsZWF2ZSAke3RoaXMudG9waWN9YClcbiAgICAgIHRoaXMudHJpZ2dlcihDSEFOTkVMX0VWRU5UUy5jbG9zZSwgXCJsZWF2ZVwiKVxuICAgIH1cbiAgICBsZXQgbGVhdmVQdXNoID0gbmV3IFB1c2godGhpcywgQ0hBTk5FTF9FVkVOVFMubGVhdmUsIGNsb3N1cmUoe30pLCB0aW1lb3V0KVxuICAgIGxlYXZlUHVzaC5yZWNlaXZlKFwib2tcIiwgKCkgPT4gb25DbG9zZSgpKVxuICAgICAgLnJlY2VpdmUoXCJ0aW1lb3V0XCIsICgpID0+IG9uQ2xvc2UoKSlcbiAgICBsZWF2ZVB1c2guc2VuZCgpXG4gICAgaWYoIXRoaXMuY2FuUHVzaCgpKXsgbGVhdmVQdXNoLnRyaWdnZXIoXCJva1wiLCB7fSkgfVxuXG4gICAgcmV0dXJuIGxlYXZlUHVzaFxuICB9XG5cbiAgLyoqXG4gICAqIE92ZXJyaWRhYmxlIG1lc3NhZ2UgaG9va1xuICAgKlxuICAgKiBSZWNlaXZlcyBhbGwgZXZlbnRzIGZvciBzcGVjaWFsaXplZCBtZXNzYWdlIGhhbmRsaW5nXG4gICAqIGJlZm9yZSBkaXNwYXRjaGluZyB0byB0aGUgY2hhbm5lbCBjYWxsYmFja3MuXG4gICAqXG4gICAqIE11c3QgcmV0dXJuIHRoZSBwYXlsb2FkLCBtb2RpZmllZCBvciB1bm1vZGlmaWVkXG4gICAqIEBwYXJhbSB7c3RyaW5nfSBldmVudFxuICAgKiBAcGFyYW0ge09iamVjdH0gcGF5bG9hZFxuICAgKiBAcGFyYW0ge2ludGVnZXJ9IHJlZlxuICAgKiBAcmV0dXJucyB7T2JqZWN0fVxuICAgKi9cbiAgb25NZXNzYWdlKF9ldmVudCwgcGF5bG9hZCwgX3JlZil7IHJldHVybiBwYXlsb2FkIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIGlzTWVtYmVyKHRvcGljLCBldmVudCwgcGF5bG9hZCwgam9pblJlZil7XG4gICAgaWYodGhpcy50b3BpYyAhPT0gdG9waWMpeyByZXR1cm4gZmFsc2UgfVxuXG4gICAgaWYoam9pblJlZiAmJiBqb2luUmVmICE9PSB0aGlzLmpvaW5SZWYoKSl7XG4gICAgICBpZih0aGlzLnNvY2tldC5oYXNMb2dnZXIoKSkgdGhpcy5zb2NrZXQubG9nKFwiY2hhbm5lbFwiLCBcImRyb3BwaW5nIG91dGRhdGVkIG1lc3NhZ2VcIiwge3RvcGljLCBldmVudCwgcGF5bG9hZCwgam9pblJlZn0pXG4gICAgICByZXR1cm4gZmFsc2VcbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuIHRydWVcbiAgICB9XG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIGpvaW5SZWYoKXsgcmV0dXJuIHRoaXMuam9pblB1c2gucmVmIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIHJlam9pbih0aW1lb3V0ID0gdGhpcy50aW1lb3V0KXtcbiAgICBpZih0aGlzLmlzTGVhdmluZygpKXsgcmV0dXJuIH1cbiAgICB0aGlzLnNvY2tldC5sZWF2ZU9wZW5Ub3BpYyh0aGlzLnRvcGljKVxuICAgIHRoaXMuc3RhdGUgPSBDSEFOTkVMX1NUQVRFUy5qb2luaW5nXG4gICAgdGhpcy5qb2luUHVzaC5yZXNlbmQodGltZW91dClcbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgdHJpZ2dlcihldmVudCwgcGF5bG9hZCwgcmVmLCBqb2luUmVmKXtcbiAgICBsZXQgaGFuZGxlZFBheWxvYWQgPSB0aGlzLm9uTWVzc2FnZShldmVudCwgcGF5bG9hZCwgcmVmLCBqb2luUmVmKVxuICAgIGlmKHBheWxvYWQgJiYgIWhhbmRsZWRQYXlsb2FkKXsgdGhyb3cgbmV3IEVycm9yKFwiY2hhbm5lbCBvbk1lc3NhZ2UgY2FsbGJhY2tzIG11c3QgcmV0dXJuIHRoZSBwYXlsb2FkLCBtb2RpZmllZCBvciB1bm1vZGlmaWVkXCIpIH1cblxuICAgIGxldCBldmVudEJpbmRpbmdzID0gdGhpcy5iaW5kaW5ncy5maWx0ZXIoYmluZCA9PiBiaW5kLmV2ZW50ID09PSBldmVudClcblxuICAgIGZvcihsZXQgaSA9IDA7IGkgPCBldmVudEJpbmRpbmdzLmxlbmd0aDsgaSsrKXtcbiAgICAgIGxldCBiaW5kID0gZXZlbnRCaW5kaW5nc1tpXVxuICAgICAgYmluZC5jYWxsYmFjayhoYW5kbGVkUGF5bG9hZCwgcmVmLCBqb2luUmVmIHx8IHRoaXMuam9pblJlZigpKVxuICAgIH1cbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgcmVwbHlFdmVudE5hbWUocmVmKXsgcmV0dXJuIGBjaGFuX3JlcGx5XyR7cmVmfWAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgaXNDbG9zZWQoKXsgcmV0dXJuIHRoaXMuc3RhdGUgPT09IENIQU5ORUxfU1RBVEVTLmNsb3NlZCB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBpc0Vycm9yZWQoKXsgcmV0dXJuIHRoaXMuc3RhdGUgPT09IENIQU5ORUxfU1RBVEVTLmVycm9yZWQgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgaXNKb2luZWQoKXsgcmV0dXJuIHRoaXMuc3RhdGUgPT09IENIQU5ORUxfU1RBVEVTLmpvaW5lZCB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBpc0pvaW5pbmcoKXsgcmV0dXJuIHRoaXMuc3RhdGUgPT09IENIQU5ORUxfU1RBVEVTLmpvaW5pbmcgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgaXNMZWF2aW5nKCl7IHJldHVybiB0aGlzLnN0YXRlID09PSBDSEFOTkVMX1NUQVRFUy5sZWF2aW5nIH1cbn1cbiIsICJpbXBvcnQge1xuICBnbG9iYWwsXG4gIFhIUl9TVEFURVNcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCJcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgQWpheCB7XG5cbiAgc3RhdGljIHJlcXVlc3QobWV0aG9kLCBlbmRQb2ludCwgaGVhZGVycywgYm9keSwgdGltZW91dCwgb250aW1lb3V0LCBjYWxsYmFjayl7XG4gICAgaWYoZ2xvYmFsLlhEb21haW5SZXF1ZXN0KXtcbiAgICAgIGxldCByZXEgPSBuZXcgZ2xvYmFsLlhEb21haW5SZXF1ZXN0KCkgLy8gSUU4LCBJRTlcbiAgICAgIHJldHVybiB0aGlzLnhkb21haW5SZXF1ZXN0KHJlcSwgbWV0aG9kLCBlbmRQb2ludCwgYm9keSwgdGltZW91dCwgb250aW1lb3V0LCBjYWxsYmFjaylcbiAgICB9IGVsc2UgaWYoZ2xvYmFsLlhNTEh0dHBSZXF1ZXN0KXtcbiAgICAgIGxldCByZXEgPSBuZXcgZ2xvYmFsLlhNTEh0dHBSZXF1ZXN0KCkgLy8gSUU3KywgRmlyZWZveCwgQ2hyb21lLCBPcGVyYSwgU2FmYXJpXG4gICAgICByZXR1cm4gdGhpcy54aHJSZXF1ZXN0KHJlcSwgbWV0aG9kLCBlbmRQb2ludCwgaGVhZGVycywgYm9keSwgdGltZW91dCwgb250aW1lb3V0LCBjYWxsYmFjaylcbiAgICB9IGVsc2UgaWYoZ2xvYmFsLmZldGNoICYmIGdsb2JhbC5BYm9ydENvbnRyb2xsZXIpe1xuICAgICAgLy8gRmV0Y2ggd2l0aCBBYm9ydENvbnRyb2xsZXIgZm9yIG1vZGVybiBicm93c2Vyc1xuICAgICAgcmV0dXJuIHRoaXMuZmV0Y2hSZXF1ZXN0KG1ldGhvZCwgZW5kUG9pbnQsIGhlYWRlcnMsIGJvZHksIHRpbWVvdXQsIG9udGltZW91dCwgY2FsbGJhY2spXG4gICAgfSBlbHNlIHtcbiAgICAgIHRocm93IG5ldyBFcnJvcihcIk5vIHN1aXRhYmxlIFhNTEh0dHBSZXF1ZXN0IGltcGxlbWVudGF0aW9uIGZvdW5kXCIpXG4gICAgfVxuICB9XG5cbiAgc3RhdGljIGZldGNoUmVxdWVzdChtZXRob2QsIGVuZFBvaW50LCBoZWFkZXJzLCBib2R5LCB0aW1lb3V0LCBvbnRpbWVvdXQsIGNhbGxiYWNrKXtcbiAgICBsZXQgb3B0aW9ucyA9IHtcbiAgICAgIG1ldGhvZCxcbiAgICAgIGhlYWRlcnMsXG4gICAgICBib2R5LFxuICAgIH1cbiAgICBsZXQgY29udHJvbGxlciA9IG51bGxcbiAgICBpZih0aW1lb3V0KXtcbiAgICAgIGNvbnRyb2xsZXIgPSBuZXcgQWJvcnRDb250cm9sbGVyKClcbiAgICAgIGNvbnN0IF90aW1lb3V0SWQgPSBzZXRUaW1lb3V0KCgpID0+IGNvbnRyb2xsZXIuYWJvcnQoKSwgdGltZW91dClcbiAgICAgIG9wdGlvbnMuc2lnbmFsID0gY29udHJvbGxlci5zaWduYWxcbiAgICB9XG4gICAgZ2xvYmFsLmZldGNoKGVuZFBvaW50LCBvcHRpb25zKVxuICAgICAgLnRoZW4ocmVzcG9uc2UgPT4gcmVzcG9uc2UudGV4dCgpKVxuICAgICAgLnRoZW4oZGF0YSA9PiB0aGlzLnBhcnNlSlNPTihkYXRhKSlcbiAgICAgIC50aGVuKGRhdGEgPT4gY2FsbGJhY2sgJiYgY2FsbGJhY2soZGF0YSkpXG4gICAgICAuY2F0Y2goZXJyID0+IHtcbiAgICAgICAgaWYoZXJyLm5hbWUgPT09IFwiQWJvcnRFcnJvclwiICYmIG9udGltZW91dCl7XG4gICAgICAgICAgb250aW1lb3V0KClcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICBjYWxsYmFjayAmJiBjYWxsYmFjayhudWxsKVxuICAgICAgICB9XG4gICAgICB9KVxuICAgIHJldHVybiBjb250cm9sbGVyXG4gIH1cblxuICBzdGF0aWMgeGRvbWFpblJlcXVlc3QocmVxLCBtZXRob2QsIGVuZFBvaW50LCBib2R5LCB0aW1lb3V0LCBvbnRpbWVvdXQsIGNhbGxiYWNrKXtcbiAgICByZXEudGltZW91dCA9IHRpbWVvdXRcbiAgICByZXEub3BlbihtZXRob2QsIGVuZFBvaW50KVxuICAgIHJlcS5vbmxvYWQgPSAoKSA9PiB7XG4gICAgICBsZXQgcmVzcG9uc2UgPSB0aGlzLnBhcnNlSlNPTihyZXEucmVzcG9uc2VUZXh0KVxuICAgICAgY2FsbGJhY2sgJiYgY2FsbGJhY2socmVzcG9uc2UpXG4gICAgfVxuICAgIGlmKG9udGltZW91dCl7IHJlcS5vbnRpbWVvdXQgPSBvbnRpbWVvdXQgfVxuXG4gICAgLy8gV29yayBhcm91bmQgYnVnIGluIElFOSB0aGF0IHJlcXVpcmVzIGFuIGF0dGFjaGVkIG9ucHJvZ3Jlc3MgaGFuZGxlclxuICAgIHJlcS5vbnByb2dyZXNzID0gKCkgPT4geyB9XG5cbiAgICByZXEuc2VuZChib2R5KVxuICAgIHJldHVybiByZXFcbiAgfVxuXG4gIHN0YXRpYyB4aHJSZXF1ZXN0KHJlcSwgbWV0aG9kLCBlbmRQb2ludCwgaGVhZGVycywgYm9keSwgdGltZW91dCwgb250aW1lb3V0LCBjYWxsYmFjayl7XG4gICAgcmVxLm9wZW4obWV0aG9kLCBlbmRQb2ludCwgdHJ1ZSlcbiAgICByZXEudGltZW91dCA9IHRpbWVvdXRcbiAgICBmb3IobGV0IFtrZXksIHZhbHVlXSBvZiBPYmplY3QuZW50cmllcyhoZWFkZXJzKSl7XG4gICAgICByZXEuc2V0UmVxdWVzdEhlYWRlcihrZXksIHZhbHVlKVxuICAgIH1cbiAgICByZXEub25lcnJvciA9ICgpID0+IGNhbGxiYWNrICYmIGNhbGxiYWNrKG51bGwpXG4gICAgcmVxLm9ucmVhZHlzdGF0ZWNoYW5nZSA9ICgpID0+IHtcbiAgICAgIGlmKHJlcS5yZWFkeVN0YXRlID09PSBYSFJfU1RBVEVTLmNvbXBsZXRlICYmIGNhbGxiYWNrKXtcbiAgICAgICAgbGV0IHJlc3BvbnNlID0gdGhpcy5wYXJzZUpTT04ocmVxLnJlc3BvbnNlVGV4dClcbiAgICAgICAgY2FsbGJhY2socmVzcG9uc2UpXG4gICAgICB9XG4gICAgfVxuICAgIGlmKG9udGltZW91dCl7IHJlcS5vbnRpbWVvdXQgPSBvbnRpbWVvdXQgfVxuXG4gICAgcmVxLnNlbmQoYm9keSlcbiAgICByZXR1cm4gcmVxXG4gIH1cblxuICBzdGF0aWMgcGFyc2VKU09OKHJlc3Ape1xuICAgIGlmKCFyZXNwIHx8IHJlc3AgPT09IFwiXCIpeyByZXR1cm4gbnVsbCB9XG5cbiAgICB0cnkge1xuICAgICAgcmV0dXJuIEpTT04ucGFyc2UocmVzcClcbiAgICB9IGNhdGNoIHtcbiAgICAgIGNvbnNvbGUgJiYgY29uc29sZS5sb2coXCJmYWlsZWQgdG8gcGFyc2UgSlNPTiByZXNwb25zZVwiLCByZXNwKVxuICAgICAgcmV0dXJuIG51bGxcbiAgICB9XG4gIH1cblxuICBzdGF0aWMgc2VyaWFsaXplKG9iaiwgcGFyZW50S2V5KXtcbiAgICBsZXQgcXVlcnlTdHIgPSBbXVxuICAgIGZvcih2YXIga2V5IGluIG9iail7XG4gICAgICBpZighT2JqZWN0LnByb3RvdHlwZS5oYXNPd25Qcm9wZXJ0eS5jYWxsKG9iaiwga2V5KSl7IGNvbnRpbnVlIH1cbiAgICAgIGxldCBwYXJhbUtleSA9IHBhcmVudEtleSA/IGAke3BhcmVudEtleX1bJHtrZXl9XWAgOiBrZXlcbiAgICAgIGxldCBwYXJhbVZhbCA9IG9ialtrZXldXG4gICAgICBpZih0eXBlb2YgcGFyYW1WYWwgPT09IFwib2JqZWN0XCIpe1xuICAgICAgICBxdWVyeVN0ci5wdXNoKHRoaXMuc2VyaWFsaXplKHBhcmFtVmFsLCBwYXJhbUtleSkpXG4gICAgICB9IGVsc2Uge1xuICAgICAgICBxdWVyeVN0ci5wdXNoKGVuY29kZVVSSUNvbXBvbmVudChwYXJhbUtleSkgKyBcIj1cIiArIGVuY29kZVVSSUNvbXBvbmVudChwYXJhbVZhbCkpXG4gICAgICB9XG4gICAgfVxuICAgIHJldHVybiBxdWVyeVN0ci5qb2luKFwiJlwiKVxuICB9XG5cbiAgc3RhdGljIGFwcGVuZFBhcmFtcyh1cmwsIHBhcmFtcyl7XG4gICAgaWYoT2JqZWN0LmtleXMocGFyYW1zKS5sZW5ndGggPT09IDApeyByZXR1cm4gdXJsIH1cblxuICAgIGxldCBwcmVmaXggPSB1cmwubWF0Y2goL1xcPy8pID8gXCImXCIgOiBcIj9cIlxuICAgIHJldHVybiBgJHt1cmx9JHtwcmVmaXh9JHt0aGlzLnNlcmlhbGl6ZShwYXJhbXMpfWBcbiAgfVxufVxuIiwgImltcG9ydCB7XG4gIFNPQ0tFVF9TVEFURVMsXG4gIFRSQU5TUE9SVFMsXG4gIEFVVEhfVE9LRU5fUFJFRklYXG59IGZyb20gXCIuL2NvbnN0YW50c1wiXG5cbmltcG9ydCBBamF4IGZyb20gXCIuL2FqYXhcIlxuXG5sZXQgYXJyYXlCdWZmZXJUb0Jhc2U2NCA9IChidWZmZXIpID0+IHtcbiAgbGV0IGJpbmFyeSA9IFwiXCJcbiAgbGV0IGJ5dGVzID0gbmV3IFVpbnQ4QXJyYXkoYnVmZmVyKVxuICBsZXQgbGVuID0gYnl0ZXMuYnl0ZUxlbmd0aFxuICBmb3IobGV0IGkgPSAwOyBpIDwgbGVuOyBpKyspeyBiaW5hcnkgKz0gU3RyaW5nLmZyb21DaGFyQ29kZShieXRlc1tpXSkgfVxuICByZXR1cm4gYnRvYShiaW5hcnkpXG59XG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIExvbmdQb2xsIHtcblxuICBjb25zdHJ1Y3RvcihlbmRQb2ludCwgcHJvdG9jb2xzKXtcbiAgICAvLyB3ZSBvbmx5IHN1cHBvcnQgc3VicHJvdG9jb2xzIGZvciBhdXRoVG9rZW5cbiAgICAvLyBbXCJwaG9lbml4XCIsIFwiYmFzZTY0dXJsLmJlYXJlci5waHguQkFTRTY0X0VOQ09ERURfVE9LRU5cIl1cbiAgICBpZihwcm90b2NvbHMgJiYgcHJvdG9jb2xzLmxlbmd0aCA9PT0gMiAmJiBwcm90b2NvbHNbMV0uc3RhcnRzV2l0aChBVVRIX1RPS0VOX1BSRUZJWCkpe1xuICAgICAgdGhpcy5hdXRoVG9rZW4gPSBhdG9iKHByb3RvY29sc1sxXS5zbGljZShBVVRIX1RPS0VOX1BSRUZJWC5sZW5ndGgpKVxuICAgIH1cbiAgICB0aGlzLmVuZFBvaW50ID0gbnVsbFxuICAgIHRoaXMudG9rZW4gPSBudWxsXG4gICAgdGhpcy5za2lwSGVhcnRiZWF0ID0gdHJ1ZVxuICAgIHRoaXMucmVxcyA9IG5ldyBTZXQoKVxuICAgIHRoaXMuYXdhaXRpbmdCYXRjaEFjayA9IGZhbHNlXG4gICAgdGhpcy5jdXJyZW50QmF0Y2ggPSBudWxsXG4gICAgdGhpcy5jdXJyZW50QmF0Y2hUaW1lciA9IG51bGxcbiAgICB0aGlzLmJhdGNoQnVmZmVyID0gW11cbiAgICB0aGlzLm9ub3BlbiA9IGZ1bmN0aW9uICgpeyB9IC8vIG5vb3BcbiAgICB0aGlzLm9uZXJyb3IgPSBmdW5jdGlvbiAoKXsgfSAvLyBub29wXG4gICAgdGhpcy5vbm1lc3NhZ2UgPSBmdW5jdGlvbiAoKXsgfSAvLyBub29wXG4gICAgdGhpcy5vbmNsb3NlID0gZnVuY3Rpb24gKCl7IH0gLy8gbm9vcFxuICAgIHRoaXMucG9sbEVuZHBvaW50ID0gdGhpcy5ub3JtYWxpemVFbmRwb2ludChlbmRQb2ludClcbiAgICB0aGlzLnJlYWR5U3RhdGUgPSBTT0NLRVRfU1RBVEVTLmNvbm5lY3RpbmdcbiAgICAvLyB3ZSBtdXN0IHdhaXQgZm9yIHRoZSBjYWxsZXIgdG8gZmluaXNoIHNldHRpbmcgdXAgb3VyIGNhbGxiYWNrcyBhbmQgdGltZW91dCBwcm9wZXJ0aWVzXG4gICAgc2V0VGltZW91dCgoKSA9PiB0aGlzLnBvbGwoKSwgMClcbiAgfVxuXG4gIG5vcm1hbGl6ZUVuZHBvaW50KGVuZFBvaW50KXtcbiAgICByZXR1cm4gKGVuZFBvaW50XG4gICAgICAucmVwbGFjZShcIndzOi8vXCIsIFwiaHR0cDovL1wiKVxuICAgICAgLnJlcGxhY2UoXCJ3c3M6Ly9cIiwgXCJodHRwczovL1wiKVxuICAgICAgLnJlcGxhY2UobmV3IFJlZ0V4cChcIiguKilcXC9cIiArIFRSQU5TUE9SVFMud2Vic29ja2V0KSwgXCIkMS9cIiArIFRSQU5TUE9SVFMubG9uZ3BvbGwpKVxuICB9XG5cbiAgZW5kcG9pbnRVUkwoKXtcbiAgICByZXR1cm4gQWpheC5hcHBlbmRQYXJhbXModGhpcy5wb2xsRW5kcG9pbnQsIHt0b2tlbjogdGhpcy50b2tlbn0pXG4gIH1cblxuICBjbG9zZUFuZFJldHJ5KGNvZGUsIHJlYXNvbiwgd2FzQ2xlYW4pe1xuICAgIHRoaXMuY2xvc2UoY29kZSwgcmVhc29uLCB3YXNDbGVhbilcbiAgICB0aGlzLnJlYWR5U3RhdGUgPSBTT0NLRVRfU1RBVEVTLmNvbm5lY3RpbmdcbiAgfVxuXG4gIG9udGltZW91dCgpe1xuICAgIHRoaXMub25lcnJvcihcInRpbWVvdXRcIilcbiAgICB0aGlzLmNsb3NlQW5kUmV0cnkoMTAwNSwgXCJ0aW1lb3V0XCIsIGZhbHNlKVxuICB9XG5cbiAgaXNBY3RpdmUoKXsgcmV0dXJuIHRoaXMucmVhZHlTdGF0ZSA9PT0gU09DS0VUX1NUQVRFUy5vcGVuIHx8IHRoaXMucmVhZHlTdGF0ZSA9PT0gU09DS0VUX1NUQVRFUy5jb25uZWN0aW5nIH1cblxuICBwb2xsKCl7XG4gICAgY29uc3QgaGVhZGVycyA9IHtcIkFjY2VwdFwiOiBcImFwcGxpY2F0aW9uL2pzb25cIn1cbiAgICBpZih0aGlzLmF1dGhUb2tlbil7XG4gICAgICBoZWFkZXJzW1wiWC1QaG9lbml4LUF1dGhUb2tlblwiXSA9IHRoaXMuYXV0aFRva2VuXG4gICAgfVxuICAgIHRoaXMuYWpheChcIkdFVFwiLCBoZWFkZXJzLCBudWxsLCAoKSA9PiB0aGlzLm9udGltZW91dCgpLCByZXNwID0+IHtcbiAgICAgIGlmKHJlc3Ape1xuICAgICAgICB2YXIge3N0YXR1cywgdG9rZW4sIG1lc3NhZ2VzfSA9IHJlc3BcbiAgICAgICAgdGhpcy50b2tlbiA9IHRva2VuXG4gICAgICB9IGVsc2Uge1xuICAgICAgICBzdGF0dXMgPSAwXG4gICAgICB9XG5cbiAgICAgIHN3aXRjaChzdGF0dXMpe1xuICAgICAgICBjYXNlIDIwMDpcbiAgICAgICAgICBtZXNzYWdlcy5mb3JFYWNoKG1zZyA9PiB7XG4gICAgICAgICAgICAvLyBUYXNrcyBhcmUgd2hhdCB0aGluZ3MgbGlrZSBldmVudCBoYW5kbGVycywgc2V0VGltZW91dCBjYWxsYmFja3MsXG4gICAgICAgICAgICAvLyBwcm9taXNlIHJlc29sdmVzIGFuZCBtb3JlIGFyZSBydW4gd2l0aGluLlxuICAgICAgICAgICAgLy8gSW4gbW9kZXJuIGJyb3dzZXJzLCB0aGVyZSBhcmUgdHdvIGRpZmZlcmVudCBraW5kcyBvZiB0YXNrcyxcbiAgICAgICAgICAgIC8vIG1pY3JvdGFza3MgYW5kIG1hY3JvdGFza3MuXG4gICAgICAgICAgICAvLyBNaWNyb3Rhc2tzIGFyZSBtYWlubHkgdXNlZCBmb3IgUHJvbWlzZXMsIHdoaWxlIG1hY3JvdGFza3MgYXJlXG4gICAgICAgICAgICAvLyB1c2VkIGZvciBldmVyeXRoaW5nIGVsc2UuXG4gICAgICAgICAgICAvLyBNaWNyb3Rhc2tzIGFsd2F5cyBoYXZlIHByaW9yaXR5IG92ZXIgbWFjcm90YXNrcy4gSWYgdGhlIEpTIGVuZ2luZVxuICAgICAgICAgICAgLy8gaXMgbG9va2luZyBmb3IgYSB0YXNrIHRvIHJ1biwgaXQgd2lsbCBhbHdheXMgdHJ5IHRvIGVtcHR5IHRoZVxuICAgICAgICAgICAgLy8gbWljcm90YXNrIHF1ZXVlIGJlZm9yZSBhdHRlbXB0aW5nIHRvIHJ1biBhbnl0aGluZyBmcm9tIHRoZVxuICAgICAgICAgICAgLy8gbWFjcm90YXNrIHF1ZXVlLlxuICAgICAgICAgICAgLy9cbiAgICAgICAgICAgIC8vIEZvciB0aGUgV2ViU29ja2V0IHRyYW5zcG9ydCwgbWVzc2FnZXMgYWx3YXlzIGFycml2ZSBpbiB0aGVpciBvd25cbiAgICAgICAgICAgIC8vIGV2ZW50LiBUaGlzIG1lYW5zIHRoYXQgaWYgYW55IHByb21pc2VzIGFyZSByZXNvbHZlZCBmcm9tIHdpdGhpbixcbiAgICAgICAgICAgIC8vIHRoZWlyIGNhbGxiYWNrcyB3aWxsIGFsd2F5cyBmaW5pc2ggZXhlY3V0aW9uIGJ5IHRoZSB0aW1lIHRoZVxuICAgICAgICAgICAgLy8gbmV4dCBtZXNzYWdlIGV2ZW50IGhhbmRsZXIgaXMgcnVuLlxuICAgICAgICAgICAgLy9cbiAgICAgICAgICAgIC8vIEluIG9yZGVyIHRvIGVtdWxhdGUgdGhpcyBiZWhhdmlvdXIsIHdlIG5lZWQgdG8gbWFrZSBzdXJlIGVhY2hcbiAgICAgICAgICAgIC8vIG9ubWVzc2FnZSBoYW5kbGVyIGlzIHJ1biB3aXRoaW4gaXRzIG93biBtYWNyb3Rhc2suXG4gICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHRoaXMub25tZXNzYWdlKHtkYXRhOiBtc2d9KSwgMClcbiAgICAgICAgICB9KVxuICAgICAgICAgIHRoaXMucG9sbCgpXG4gICAgICAgICAgYnJlYWtcbiAgICAgICAgY2FzZSAyMDQ6XG4gICAgICAgICAgdGhpcy5wb2xsKClcbiAgICAgICAgICBicmVha1xuICAgICAgICBjYXNlIDQxMDpcbiAgICAgICAgICB0aGlzLnJlYWR5U3RhdGUgPSBTT0NLRVRfU1RBVEVTLm9wZW5cbiAgICAgICAgICB0aGlzLm9ub3Blbih7fSlcbiAgICAgICAgICB0aGlzLnBvbGwoKVxuICAgICAgICAgIGJyZWFrXG4gICAgICAgIGNhc2UgNDAzOlxuICAgICAgICAgIHRoaXMub25lcnJvcig0MDMpXG4gICAgICAgICAgdGhpcy5jbG9zZSgxMDA4LCBcImZvcmJpZGRlblwiLCBmYWxzZSlcbiAgICAgICAgICBicmVha1xuICAgICAgICBjYXNlIDA6XG4gICAgICAgIGNhc2UgNTAwOlxuICAgICAgICAgIHRoaXMub25lcnJvcig1MDApXG4gICAgICAgICAgdGhpcy5jbG9zZUFuZFJldHJ5KDEwMTEsIFwiaW50ZXJuYWwgc2VydmVyIGVycm9yXCIsIDUwMClcbiAgICAgICAgICBicmVha1xuICAgICAgICBkZWZhdWx0OiB0aHJvdyBuZXcgRXJyb3IoYHVuaGFuZGxlZCBwb2xsIHN0YXR1cyAke3N0YXR1c31gKVxuICAgICAgfVxuICAgIH0pXG4gIH1cblxuICAvLyB3ZSBjb2xsZWN0IGFsbCBwdXNoZXMgd2l0aGluIHRoZSBjdXJyZW50IGV2ZW50IGxvb3AgYnlcbiAgLy8gc2V0VGltZW91dCAwLCB3aGljaCBvcHRpbWl6ZXMgYmFjay10by1iYWNrIHByb2NlZHVyYWxcbiAgLy8gcHVzaGVzIGFnYWluc3QgYW4gZW1wdHkgYnVmZmVyXG5cbiAgc2VuZChib2R5KXtcbiAgICBpZih0eXBlb2YoYm9keSkgIT09IFwic3RyaW5nXCIpeyBib2R5ID0gYXJyYXlCdWZmZXJUb0Jhc2U2NChib2R5KSB9XG4gICAgaWYodGhpcy5jdXJyZW50QmF0Y2gpe1xuICAgICAgdGhpcy5jdXJyZW50QmF0Y2gucHVzaChib2R5KVxuICAgIH0gZWxzZSBpZih0aGlzLmF3YWl0aW5nQmF0Y2hBY2spe1xuICAgICAgdGhpcy5iYXRjaEJ1ZmZlci5wdXNoKGJvZHkpXG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMuY3VycmVudEJhdGNoID0gW2JvZHldXG4gICAgICB0aGlzLmN1cnJlbnRCYXRjaFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7XG4gICAgICAgIHRoaXMuYmF0Y2hTZW5kKHRoaXMuY3VycmVudEJhdGNoKVxuICAgICAgICB0aGlzLmN1cnJlbnRCYXRjaCA9IG51bGxcbiAgICAgIH0sIDApXG4gICAgfVxuICB9XG5cbiAgYmF0Y2hTZW5kKG1lc3NhZ2VzKXtcbiAgICB0aGlzLmF3YWl0aW5nQmF0Y2hBY2sgPSB0cnVlXG4gICAgdGhpcy5hamF4KFwiUE9TVFwiLCB7XCJDb250ZW50LVR5cGVcIjogXCJhcHBsaWNhdGlvbi94LW5kanNvblwifSwgbWVzc2FnZXMuam9pbihcIlxcblwiKSwgKCkgPT4gdGhpcy5vbmVycm9yKFwidGltZW91dFwiKSwgcmVzcCA9PiB7XG4gICAgICB0aGlzLmF3YWl0aW5nQmF0Y2hBY2sgPSBmYWxzZVxuICAgICAgaWYoIXJlc3AgfHwgcmVzcC5zdGF0dXMgIT09IDIwMCl7XG4gICAgICAgIHRoaXMub25lcnJvcihyZXNwICYmIHJlc3Auc3RhdHVzKVxuICAgICAgICB0aGlzLmNsb3NlQW5kUmV0cnkoMTAxMSwgXCJpbnRlcm5hbCBzZXJ2ZXIgZXJyb3JcIiwgZmFsc2UpXG4gICAgICB9IGVsc2UgaWYodGhpcy5iYXRjaEJ1ZmZlci5sZW5ndGggPiAwKXtcbiAgICAgICAgdGhpcy5iYXRjaFNlbmQodGhpcy5iYXRjaEJ1ZmZlcilcbiAgICAgICAgdGhpcy5iYXRjaEJ1ZmZlciA9IFtdXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIGNsb3NlKGNvZGUsIHJlYXNvbiwgd2FzQ2xlYW4pe1xuICAgIGZvcihsZXQgcmVxIG9mIHRoaXMucmVxcyl7IHJlcS5hYm9ydCgpIH1cbiAgICB0aGlzLnJlYWR5U3RhdGUgPSBTT0NLRVRfU1RBVEVTLmNsb3NlZFxuICAgIGxldCBvcHRzID0gT2JqZWN0LmFzc2lnbih7Y29kZTogMTAwMCwgcmVhc29uOiB1bmRlZmluZWQsIHdhc0NsZWFuOiB0cnVlfSwge2NvZGUsIHJlYXNvbiwgd2FzQ2xlYW59KVxuICAgIHRoaXMuYmF0Y2hCdWZmZXIgPSBbXVxuICAgIGNsZWFyVGltZW91dCh0aGlzLmN1cnJlbnRCYXRjaFRpbWVyKVxuICAgIHRoaXMuY3VycmVudEJhdGNoVGltZXIgPSBudWxsXG4gICAgaWYodHlwZW9mKENsb3NlRXZlbnQpICE9PSBcInVuZGVmaW5lZFwiKXtcbiAgICAgIHRoaXMub25jbG9zZShuZXcgQ2xvc2VFdmVudChcImNsb3NlXCIsIG9wdHMpKVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLm9uY2xvc2Uob3B0cylcbiAgICB9XG4gIH1cblxuICBhamF4KG1ldGhvZCwgaGVhZGVycywgYm9keSwgb25DYWxsZXJUaW1lb3V0LCBjYWxsYmFjayl7XG4gICAgbGV0IHJlcVxuICAgIGxldCBvbnRpbWVvdXQgPSAoKSA9PiB7XG4gICAgICB0aGlzLnJlcXMuZGVsZXRlKHJlcSlcbiAgICAgIG9uQ2FsbGVyVGltZW91dCgpXG4gICAgfVxuICAgIHJlcSA9IEFqYXgucmVxdWVzdChtZXRob2QsIHRoaXMuZW5kcG9pbnRVUkwoKSwgaGVhZGVycywgYm9keSwgdGhpcy50aW1lb3V0LCBvbnRpbWVvdXQsIHJlc3AgPT4ge1xuICAgICAgdGhpcy5yZXFzLmRlbGV0ZShyZXEpXG4gICAgICBpZih0aGlzLmlzQWN0aXZlKCkpeyBjYWxsYmFjayhyZXNwKSB9XG4gICAgfSlcbiAgICB0aGlzLnJlcXMuYWRkKHJlcSlcbiAgfVxufVxuIiwgIi8qKlxuICogSW5pdGlhbGl6ZXMgdGhlIFByZXNlbmNlXG4gKiBAcGFyYW0ge0NoYW5uZWx9IGNoYW5uZWwgLSBUaGUgQ2hhbm5lbFxuICogQHBhcmFtIHtPYmplY3R9IG9wdHMgLSBUaGUgb3B0aW9ucyxcbiAqICAgICAgICBmb3IgZXhhbXBsZSBge2V2ZW50czoge3N0YXRlOiBcInN0YXRlXCIsIGRpZmY6IFwiZGlmZlwifX1gXG4gKi9cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFByZXNlbmNlIHtcblxuICBjb25zdHJ1Y3RvcihjaGFubmVsLCBvcHRzID0ge30pe1xuICAgIGxldCBldmVudHMgPSBvcHRzLmV2ZW50cyB8fCB7c3RhdGU6IFwicHJlc2VuY2Vfc3RhdGVcIiwgZGlmZjogXCJwcmVzZW5jZV9kaWZmXCJ9XG4gICAgdGhpcy5zdGF0ZSA9IHt9XG4gICAgdGhpcy5wZW5kaW5nRGlmZnMgPSBbXVxuICAgIHRoaXMuY2hhbm5lbCA9IGNoYW5uZWxcbiAgICB0aGlzLmpvaW5SZWYgPSBudWxsXG4gICAgdGhpcy5jYWxsZXIgPSB7XG4gICAgICBvbkpvaW46IGZ1bmN0aW9uICgpeyB9LFxuICAgICAgb25MZWF2ZTogZnVuY3Rpb24gKCl7IH0sXG4gICAgICBvblN5bmM6IGZ1bmN0aW9uICgpeyB9XG4gICAgfVxuXG4gICAgdGhpcy5jaGFubmVsLm9uKGV2ZW50cy5zdGF0ZSwgbmV3U3RhdGUgPT4ge1xuICAgICAgbGV0IHtvbkpvaW4sIG9uTGVhdmUsIG9uU3luY30gPSB0aGlzLmNhbGxlclxuXG4gICAgICB0aGlzLmpvaW5SZWYgPSB0aGlzLmNoYW5uZWwuam9pblJlZigpXG4gICAgICB0aGlzLnN0YXRlID0gUHJlc2VuY2Uuc3luY1N0YXRlKHRoaXMuc3RhdGUsIG5ld1N0YXRlLCBvbkpvaW4sIG9uTGVhdmUpXG5cbiAgICAgIHRoaXMucGVuZGluZ0RpZmZzLmZvckVhY2goZGlmZiA9PiB7XG4gICAgICAgIHRoaXMuc3RhdGUgPSBQcmVzZW5jZS5zeW5jRGlmZih0aGlzLnN0YXRlLCBkaWZmLCBvbkpvaW4sIG9uTGVhdmUpXG4gICAgICB9KVxuICAgICAgdGhpcy5wZW5kaW5nRGlmZnMgPSBbXVxuICAgICAgb25TeW5jKClcbiAgICB9KVxuXG4gICAgdGhpcy5jaGFubmVsLm9uKGV2ZW50cy5kaWZmLCBkaWZmID0+IHtcbiAgICAgIGxldCB7b25Kb2luLCBvbkxlYXZlLCBvblN5bmN9ID0gdGhpcy5jYWxsZXJcblxuICAgICAgaWYodGhpcy5pblBlbmRpbmdTeW5jU3RhdGUoKSl7XG4gICAgICAgIHRoaXMucGVuZGluZ0RpZmZzLnB1c2goZGlmZilcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHRoaXMuc3RhdGUgPSBQcmVzZW5jZS5zeW5jRGlmZih0aGlzLnN0YXRlLCBkaWZmLCBvbkpvaW4sIG9uTGVhdmUpXG4gICAgICAgIG9uU3luYygpXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIG9uSm9pbihjYWxsYmFjayl7IHRoaXMuY2FsbGVyLm9uSm9pbiA9IGNhbGxiYWNrIH1cblxuICBvbkxlYXZlKGNhbGxiYWNrKXsgdGhpcy5jYWxsZXIub25MZWF2ZSA9IGNhbGxiYWNrIH1cblxuICBvblN5bmMoY2FsbGJhY2speyB0aGlzLmNhbGxlci5vblN5bmMgPSBjYWxsYmFjayB9XG5cbiAgbGlzdChieSl7IHJldHVybiBQcmVzZW5jZS5saXN0KHRoaXMuc3RhdGUsIGJ5KSB9XG5cbiAgaW5QZW5kaW5nU3luY1N0YXRlKCl7XG4gICAgcmV0dXJuICF0aGlzLmpvaW5SZWYgfHwgKHRoaXMuam9pblJlZiAhPT0gdGhpcy5jaGFubmVsLmpvaW5SZWYoKSlcbiAgfVxuXG4gIC8vIGxvd2VyLWxldmVsIHB1YmxpYyBzdGF0aWMgQVBJXG5cbiAgLyoqXG4gICAqIFVzZWQgdG8gc3luYyB0aGUgbGlzdCBvZiBwcmVzZW5jZXMgb24gdGhlIHNlcnZlclxuICAgKiB3aXRoIHRoZSBjbGllbnQncyBzdGF0ZS4gQW4gb3B0aW9uYWwgYG9uSm9pbmAgYW5kIGBvbkxlYXZlYCBjYWxsYmFjayBjYW5cbiAgICogYmUgcHJvdmlkZWQgdG8gcmVhY3QgdG8gY2hhbmdlcyBpbiB0aGUgY2xpZW50J3MgbG9jYWwgcHJlc2VuY2VzIGFjcm9zc1xuICAgKiBkaXNjb25uZWN0cyBhbmQgcmVjb25uZWN0cyB3aXRoIHRoZSBzZXJ2ZXIuXG4gICAqXG4gICAqIEByZXR1cm5zIHtQcmVzZW5jZX1cbiAgICovXG4gIHN0YXRpYyBzeW5jU3RhdGUoY3VycmVudFN0YXRlLCBuZXdTdGF0ZSwgb25Kb2luLCBvbkxlYXZlKXtcbiAgICBsZXQgc3RhdGUgPSB0aGlzLmNsb25lKGN1cnJlbnRTdGF0ZSlcbiAgICBsZXQgam9pbnMgPSB7fVxuICAgIGxldCBsZWF2ZXMgPSB7fVxuXG4gICAgdGhpcy5tYXAoc3RhdGUsIChrZXksIHByZXNlbmNlKSA9PiB7XG4gICAgICBpZighbmV3U3RhdGVba2V5XSl7XG4gICAgICAgIGxlYXZlc1trZXldID0gcHJlc2VuY2VcbiAgICAgIH1cbiAgICB9KVxuICAgIHRoaXMubWFwKG5ld1N0YXRlLCAoa2V5LCBuZXdQcmVzZW5jZSkgPT4ge1xuICAgICAgbGV0IGN1cnJlbnRQcmVzZW5jZSA9IHN0YXRlW2tleV1cbiAgICAgIGlmKGN1cnJlbnRQcmVzZW5jZSl7XG4gICAgICAgIGxldCBuZXdSZWZzID0gbmV3UHJlc2VuY2UubWV0YXMubWFwKG0gPT4gbS5waHhfcmVmKVxuICAgICAgICBsZXQgY3VyUmVmcyA9IGN1cnJlbnRQcmVzZW5jZS5tZXRhcy5tYXAobSA9PiBtLnBoeF9yZWYpXG4gICAgICAgIGxldCBqb2luZWRNZXRhcyA9IG5ld1ByZXNlbmNlLm1ldGFzLmZpbHRlcihtID0+IGN1clJlZnMuaW5kZXhPZihtLnBoeF9yZWYpIDwgMClcbiAgICAgICAgbGV0IGxlZnRNZXRhcyA9IGN1cnJlbnRQcmVzZW5jZS5tZXRhcy5maWx0ZXIobSA9PiBuZXdSZWZzLmluZGV4T2YobS5waHhfcmVmKSA8IDApXG4gICAgICAgIGlmKGpvaW5lZE1ldGFzLmxlbmd0aCA+IDApe1xuICAgICAgICAgIGpvaW5zW2tleV0gPSBuZXdQcmVzZW5jZVxuICAgICAgICAgIGpvaW5zW2tleV0ubWV0YXMgPSBqb2luZWRNZXRhc1xuICAgICAgICB9XG4gICAgICAgIGlmKGxlZnRNZXRhcy5sZW5ndGggPiAwKXtcbiAgICAgICAgICBsZWF2ZXNba2V5XSA9IHRoaXMuY2xvbmUoY3VycmVudFByZXNlbmNlKVxuICAgICAgICAgIGxlYXZlc1trZXldLm1ldGFzID0gbGVmdE1ldGFzXG4gICAgICAgIH1cbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIGpvaW5zW2tleV0gPSBuZXdQcmVzZW5jZVxuICAgICAgfVxuICAgIH0pXG4gICAgcmV0dXJuIHRoaXMuc3luY0RpZmYoc3RhdGUsIHtqb2luczogam9pbnMsIGxlYXZlczogbGVhdmVzfSwgb25Kb2luLCBvbkxlYXZlKVxuICB9XG5cbiAgLyoqXG4gICAqXG4gICAqIFVzZWQgdG8gc3luYyBhIGRpZmYgb2YgcHJlc2VuY2Ugam9pbiBhbmQgbGVhdmVcbiAgICogZXZlbnRzIGZyb20gdGhlIHNlcnZlciwgYXMgdGhleSBoYXBwZW4uIExpa2UgYHN5bmNTdGF0ZWAsIGBzeW5jRGlmZmBcbiAgICogYWNjZXB0cyBvcHRpb25hbCBgb25Kb2luYCBhbmQgYG9uTGVhdmVgIGNhbGxiYWNrcyB0byByZWFjdCB0byBhIHVzZXJcbiAgICogam9pbmluZyBvciBsZWF2aW5nIGZyb20gYSBkZXZpY2UuXG4gICAqXG4gICAqIEByZXR1cm5zIHtQcmVzZW5jZX1cbiAgICovXG4gIHN0YXRpYyBzeW5jRGlmZihzdGF0ZSwgZGlmZiwgb25Kb2luLCBvbkxlYXZlKXtcbiAgICBsZXQge2pvaW5zLCBsZWF2ZXN9ID0gdGhpcy5jbG9uZShkaWZmKVxuICAgIGlmKCFvbkpvaW4peyBvbkpvaW4gPSBmdW5jdGlvbiAoKXsgfSB9XG4gICAgaWYoIW9uTGVhdmUpeyBvbkxlYXZlID0gZnVuY3Rpb24gKCl7IH0gfVxuXG4gICAgdGhpcy5tYXAoam9pbnMsIChrZXksIG5ld1ByZXNlbmNlKSA9PiB7XG4gICAgICBsZXQgY3VycmVudFByZXNlbmNlID0gc3RhdGVba2V5XVxuICAgICAgc3RhdGVba2V5XSA9IHRoaXMuY2xvbmUobmV3UHJlc2VuY2UpXG4gICAgICBpZihjdXJyZW50UHJlc2VuY2Upe1xuICAgICAgICBsZXQgam9pbmVkUmVmcyA9IHN0YXRlW2tleV0ubWV0YXMubWFwKG0gPT4gbS5waHhfcmVmKVxuICAgICAgICBsZXQgY3VyTWV0YXMgPSBjdXJyZW50UHJlc2VuY2UubWV0YXMuZmlsdGVyKG0gPT4gam9pbmVkUmVmcy5pbmRleE9mKG0ucGh4X3JlZikgPCAwKVxuICAgICAgICBzdGF0ZVtrZXldLm1ldGFzLnVuc2hpZnQoLi4uY3VyTWV0YXMpXG4gICAgICB9XG4gICAgICBvbkpvaW4oa2V5LCBjdXJyZW50UHJlc2VuY2UsIG5ld1ByZXNlbmNlKVxuICAgIH0pXG4gICAgdGhpcy5tYXAobGVhdmVzLCAoa2V5LCBsZWZ0UHJlc2VuY2UpID0+IHtcbiAgICAgIGxldCBjdXJyZW50UHJlc2VuY2UgPSBzdGF0ZVtrZXldXG4gICAgICBpZighY3VycmVudFByZXNlbmNlKXsgcmV0dXJuIH1cbiAgICAgIGxldCByZWZzVG9SZW1vdmUgPSBsZWZ0UHJlc2VuY2UubWV0YXMubWFwKG0gPT4gbS5waHhfcmVmKVxuICAgICAgY3VycmVudFByZXNlbmNlLm1ldGFzID0gY3VycmVudFByZXNlbmNlLm1ldGFzLmZpbHRlcihwID0+IHtcbiAgICAgICAgcmV0dXJuIHJlZnNUb1JlbW92ZS5pbmRleE9mKHAucGh4X3JlZikgPCAwXG4gICAgICB9KVxuICAgICAgb25MZWF2ZShrZXksIGN1cnJlbnRQcmVzZW5jZSwgbGVmdFByZXNlbmNlKVxuICAgICAgaWYoY3VycmVudFByZXNlbmNlLm1ldGFzLmxlbmd0aCA9PT0gMCl7XG4gICAgICAgIGRlbGV0ZSBzdGF0ZVtrZXldXG4gICAgICB9XG4gICAgfSlcbiAgICByZXR1cm4gc3RhdGVcbiAgfVxuXG4gIC8qKlxuICAgKiBSZXR1cm5zIHRoZSBhcnJheSBvZiBwcmVzZW5jZXMsIHdpdGggc2VsZWN0ZWQgbWV0YWRhdGEuXG4gICAqXG4gICAqIEBwYXJhbSB7T2JqZWN0fSBwcmVzZW5jZXNcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2hvb3NlclxuICAgKlxuICAgKiBAcmV0dXJucyB7UHJlc2VuY2V9XG4gICAqL1xuICBzdGF0aWMgbGlzdChwcmVzZW5jZXMsIGNob29zZXIpe1xuICAgIGlmKCFjaG9vc2VyKXsgY2hvb3NlciA9IGZ1bmN0aW9uIChrZXksIHByZXMpeyByZXR1cm4gcHJlcyB9IH1cblxuICAgIHJldHVybiB0aGlzLm1hcChwcmVzZW5jZXMsIChrZXksIHByZXNlbmNlKSA9PiB7XG4gICAgICByZXR1cm4gY2hvb3NlcihrZXksIHByZXNlbmNlKVxuICAgIH0pXG4gIH1cblxuICAvLyBwcml2YXRlXG5cbiAgc3RhdGljIG1hcChvYmosIGZ1bmMpe1xuICAgIHJldHVybiBPYmplY3QuZ2V0T3duUHJvcGVydHlOYW1lcyhvYmopLm1hcChrZXkgPT4gZnVuYyhrZXksIG9ialtrZXldKSlcbiAgfVxuXG4gIHN0YXRpYyBjbG9uZShvYmopeyByZXR1cm4gSlNPTi5wYXJzZShKU09OLnN0cmluZ2lmeShvYmopKSB9XG59XG4iLCAiLyogVGhlIGRlZmF1bHQgc2VyaWFsaXplciBmb3IgZW5jb2RpbmcgYW5kIGRlY29kaW5nIG1lc3NhZ2VzICovXG5pbXBvcnQge1xuICBDSEFOTkVMX0VWRU5UU1xufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5leHBvcnQgZGVmYXVsdCB7XG4gIEhFQURFUl9MRU5HVEg6IDEsXG4gIE1FVEFfTEVOR1RIOiA0LFxuICBLSU5EUzoge3B1c2g6IDAsIHJlcGx5OiAxLCBicm9hZGNhc3Q6IDJ9LFxuXG4gIGVuY29kZShtc2csIGNhbGxiYWNrKXtcbiAgICBpZihtc2cucGF5bG9hZC5jb25zdHJ1Y3RvciA9PT0gQXJyYXlCdWZmZXIpe1xuICAgICAgcmV0dXJuIGNhbGxiYWNrKHRoaXMuYmluYXJ5RW5jb2RlKG1zZykpXG4gICAgfSBlbHNlIHtcbiAgICAgIGxldCBwYXlsb2FkID0gW21zZy5qb2luX3JlZiwgbXNnLnJlZiwgbXNnLnRvcGljLCBtc2cuZXZlbnQsIG1zZy5wYXlsb2FkXVxuICAgICAgcmV0dXJuIGNhbGxiYWNrKEpTT04uc3RyaW5naWZ5KHBheWxvYWQpKVxuICAgIH1cbiAgfSxcblxuICBkZWNvZGUocmF3UGF5bG9hZCwgY2FsbGJhY2spe1xuICAgIGlmKHJhd1BheWxvYWQuY29uc3RydWN0b3IgPT09IEFycmF5QnVmZmVyKXtcbiAgICAgIHJldHVybiBjYWxsYmFjayh0aGlzLmJpbmFyeURlY29kZShyYXdQYXlsb2FkKSlcbiAgICB9IGVsc2Uge1xuICAgICAgbGV0IFtqb2luX3JlZiwgcmVmLCB0b3BpYywgZXZlbnQsIHBheWxvYWRdID0gSlNPTi5wYXJzZShyYXdQYXlsb2FkKVxuICAgICAgcmV0dXJuIGNhbGxiYWNrKHtqb2luX3JlZiwgcmVmLCB0b3BpYywgZXZlbnQsIHBheWxvYWR9KVxuICAgIH1cbiAgfSxcblxuICAvLyBwcml2YXRlXG5cbiAgYmluYXJ5RW5jb2RlKG1lc3NhZ2Upe1xuICAgIGxldCB7am9pbl9yZWYsIHJlZiwgZXZlbnQsIHRvcGljLCBwYXlsb2FkfSA9IG1lc3NhZ2VcbiAgICBsZXQgbWV0YUxlbmd0aCA9IHRoaXMuTUVUQV9MRU5HVEggKyBqb2luX3JlZi5sZW5ndGggKyByZWYubGVuZ3RoICsgdG9waWMubGVuZ3RoICsgZXZlbnQubGVuZ3RoXG4gICAgbGV0IGhlYWRlciA9IG5ldyBBcnJheUJ1ZmZlcih0aGlzLkhFQURFUl9MRU5HVEggKyBtZXRhTGVuZ3RoKVxuICAgIGxldCB2aWV3ID0gbmV3IERhdGFWaWV3KGhlYWRlcilcbiAgICBsZXQgb2Zmc2V0ID0gMFxuXG4gICAgdmlldy5zZXRVaW50OChvZmZzZXQrKywgdGhpcy5LSU5EUy5wdXNoKSAvLyBraW5kXG4gICAgdmlldy5zZXRVaW50OChvZmZzZXQrKywgam9pbl9yZWYubGVuZ3RoKVxuICAgIHZpZXcuc2V0VWludDgob2Zmc2V0KyssIHJlZi5sZW5ndGgpXG4gICAgdmlldy5zZXRVaW50OChvZmZzZXQrKywgdG9waWMubGVuZ3RoKVxuICAgIHZpZXcuc2V0VWludDgob2Zmc2V0KyssIGV2ZW50Lmxlbmd0aClcbiAgICBBcnJheS5mcm9tKGpvaW5fcmVmLCBjaGFyID0+IHZpZXcuc2V0VWludDgob2Zmc2V0KyssIGNoYXIuY2hhckNvZGVBdCgwKSkpXG4gICAgQXJyYXkuZnJvbShyZWYsIGNoYXIgPT4gdmlldy5zZXRVaW50OChvZmZzZXQrKywgY2hhci5jaGFyQ29kZUF0KDApKSlcbiAgICBBcnJheS5mcm9tKHRvcGljLCBjaGFyID0+IHZpZXcuc2V0VWludDgob2Zmc2V0KyssIGNoYXIuY2hhckNvZGVBdCgwKSkpXG4gICAgQXJyYXkuZnJvbShldmVudCwgY2hhciA9PiB2aWV3LnNldFVpbnQ4KG9mZnNldCsrLCBjaGFyLmNoYXJDb2RlQXQoMCkpKVxuXG4gICAgdmFyIGNvbWJpbmVkID0gbmV3IFVpbnQ4QXJyYXkoaGVhZGVyLmJ5dGVMZW5ndGggKyBwYXlsb2FkLmJ5dGVMZW5ndGgpXG4gICAgY29tYmluZWQuc2V0KG5ldyBVaW50OEFycmF5KGhlYWRlciksIDApXG4gICAgY29tYmluZWQuc2V0KG5ldyBVaW50OEFycmF5KHBheWxvYWQpLCBoZWFkZXIuYnl0ZUxlbmd0aClcblxuICAgIHJldHVybiBjb21iaW5lZC5idWZmZXJcbiAgfSxcblxuICBiaW5hcnlEZWNvZGUoYnVmZmVyKXtcbiAgICBsZXQgdmlldyA9IG5ldyBEYXRhVmlldyhidWZmZXIpXG4gICAgbGV0IGtpbmQgPSB2aWV3LmdldFVpbnQ4KDApXG4gICAgbGV0IGRlY29kZXIgPSBuZXcgVGV4dERlY29kZXIoKVxuICAgIHN3aXRjaChraW5kKXtcbiAgICAgIGNhc2UgdGhpcy5LSU5EUy5wdXNoOiByZXR1cm4gdGhpcy5kZWNvZGVQdXNoKGJ1ZmZlciwgdmlldywgZGVjb2RlcilcbiAgICAgIGNhc2UgdGhpcy5LSU5EUy5yZXBseTogcmV0dXJuIHRoaXMuZGVjb2RlUmVwbHkoYnVmZmVyLCB2aWV3LCBkZWNvZGVyKVxuICAgICAgY2FzZSB0aGlzLktJTkRTLmJyb2FkY2FzdDogcmV0dXJuIHRoaXMuZGVjb2RlQnJvYWRjYXN0KGJ1ZmZlciwgdmlldywgZGVjb2RlcilcbiAgICB9XG4gIH0sXG5cbiAgZGVjb2RlUHVzaChidWZmZXIsIHZpZXcsIGRlY29kZXIpe1xuICAgIGxldCBqb2luUmVmU2l6ZSA9IHZpZXcuZ2V0VWludDgoMSlcbiAgICBsZXQgdG9waWNTaXplID0gdmlldy5nZXRVaW50OCgyKVxuICAgIGxldCBldmVudFNpemUgPSB2aWV3LmdldFVpbnQ4KDMpXG4gICAgbGV0IG9mZnNldCA9IHRoaXMuSEVBREVSX0xFTkdUSCArIHRoaXMuTUVUQV9MRU5HVEggLSAxIC8vIHB1c2hlcyBoYXZlIG5vIHJlZlxuICAgIGxldCBqb2luUmVmID0gZGVjb2Rlci5kZWNvZGUoYnVmZmVyLnNsaWNlKG9mZnNldCwgb2Zmc2V0ICsgam9pblJlZlNpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIGpvaW5SZWZTaXplXG4gICAgbGV0IHRvcGljID0gZGVjb2Rlci5kZWNvZGUoYnVmZmVyLnNsaWNlKG9mZnNldCwgb2Zmc2V0ICsgdG9waWNTaXplKSlcbiAgICBvZmZzZXQgPSBvZmZzZXQgKyB0b3BpY1NpemVcbiAgICBsZXQgZXZlbnQgPSBkZWNvZGVyLmRlY29kZShidWZmZXIuc2xpY2Uob2Zmc2V0LCBvZmZzZXQgKyBldmVudFNpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIGV2ZW50U2l6ZVxuICAgIGxldCBkYXRhID0gYnVmZmVyLnNsaWNlKG9mZnNldCwgYnVmZmVyLmJ5dGVMZW5ndGgpXG4gICAgcmV0dXJuIHtqb2luX3JlZjogam9pblJlZiwgcmVmOiBudWxsLCB0b3BpYzogdG9waWMsIGV2ZW50OiBldmVudCwgcGF5bG9hZDogZGF0YX1cbiAgfSxcblxuICBkZWNvZGVSZXBseShidWZmZXIsIHZpZXcsIGRlY29kZXIpe1xuICAgIGxldCBqb2luUmVmU2l6ZSA9IHZpZXcuZ2V0VWludDgoMSlcbiAgICBsZXQgcmVmU2l6ZSA9IHZpZXcuZ2V0VWludDgoMilcbiAgICBsZXQgdG9waWNTaXplID0gdmlldy5nZXRVaW50OCgzKVxuICAgIGxldCBldmVudFNpemUgPSB2aWV3LmdldFVpbnQ4KDQpXG4gICAgbGV0IG9mZnNldCA9IHRoaXMuSEVBREVSX0xFTkdUSCArIHRoaXMuTUVUQV9MRU5HVEhcbiAgICBsZXQgam9pblJlZiA9IGRlY29kZXIuZGVjb2RlKGJ1ZmZlci5zbGljZShvZmZzZXQsIG9mZnNldCArIGpvaW5SZWZTaXplKSlcbiAgICBvZmZzZXQgPSBvZmZzZXQgKyBqb2luUmVmU2l6ZVxuICAgIGxldCByZWYgPSBkZWNvZGVyLmRlY29kZShidWZmZXIuc2xpY2Uob2Zmc2V0LCBvZmZzZXQgKyByZWZTaXplKSlcbiAgICBvZmZzZXQgPSBvZmZzZXQgKyByZWZTaXplXG4gICAgbGV0IHRvcGljID0gZGVjb2Rlci5kZWNvZGUoYnVmZmVyLnNsaWNlKG9mZnNldCwgb2Zmc2V0ICsgdG9waWNTaXplKSlcbiAgICBvZmZzZXQgPSBvZmZzZXQgKyB0b3BpY1NpemVcbiAgICBsZXQgZXZlbnQgPSBkZWNvZGVyLmRlY29kZShidWZmZXIuc2xpY2Uob2Zmc2V0LCBvZmZzZXQgKyBldmVudFNpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIGV2ZW50U2l6ZVxuICAgIGxldCBkYXRhID0gYnVmZmVyLnNsaWNlKG9mZnNldCwgYnVmZmVyLmJ5dGVMZW5ndGgpXG4gICAgbGV0IHBheWxvYWQgPSB7c3RhdHVzOiBldmVudCwgcmVzcG9uc2U6IGRhdGF9XG4gICAgcmV0dXJuIHtqb2luX3JlZjogam9pblJlZiwgcmVmOiByZWYsIHRvcGljOiB0b3BpYywgZXZlbnQ6IENIQU5ORUxfRVZFTlRTLnJlcGx5LCBwYXlsb2FkOiBwYXlsb2FkfVxuICB9LFxuXG4gIGRlY29kZUJyb2FkY2FzdChidWZmZXIsIHZpZXcsIGRlY29kZXIpe1xuICAgIGxldCB0b3BpY1NpemUgPSB2aWV3LmdldFVpbnQ4KDEpXG4gICAgbGV0IGV2ZW50U2l6ZSA9IHZpZXcuZ2V0VWludDgoMilcbiAgICBsZXQgb2Zmc2V0ID0gdGhpcy5IRUFERVJfTEVOR1RIICsgMlxuICAgIGxldCB0b3BpYyA9IGRlY29kZXIuZGVjb2RlKGJ1ZmZlci5zbGljZShvZmZzZXQsIG9mZnNldCArIHRvcGljU2l6ZSkpXG4gICAgb2Zmc2V0ID0gb2Zmc2V0ICsgdG9waWNTaXplXG4gICAgbGV0IGV2ZW50ID0gZGVjb2Rlci5kZWNvZGUoYnVmZmVyLnNsaWNlKG9mZnNldCwgb2Zmc2V0ICsgZXZlbnRTaXplKSlcbiAgICBvZmZzZXQgPSBvZmZzZXQgKyBldmVudFNpemVcbiAgICBsZXQgZGF0YSA9IGJ1ZmZlci5zbGljZShvZmZzZXQsIGJ1ZmZlci5ieXRlTGVuZ3RoKVxuXG4gICAgcmV0dXJuIHtqb2luX3JlZjogbnVsbCwgcmVmOiBudWxsLCB0b3BpYzogdG9waWMsIGV2ZW50OiBldmVudCwgcGF5bG9hZDogZGF0YX1cbiAgfVxufVxuIiwgImltcG9ydCB7XG4gIGdsb2JhbCxcbiAgcGh4V2luZG93LFxuICBDSEFOTkVMX0VWRU5UUyxcbiAgREVGQVVMVF9USU1FT1VULFxuICBERUZBVUxUX1ZTTixcbiAgU09DS0VUX1NUQVRFUyxcbiAgVFJBTlNQT1JUUyxcbiAgV1NfQ0xPU0VfTk9STUFMLFxuICBBVVRIX1RPS0VOX1BSRUZJWFxufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5pbXBvcnQge1xuICBjbG9zdXJlXG59IGZyb20gXCIuL3V0aWxzXCJcblxuaW1wb3J0IEFqYXggZnJvbSBcIi4vYWpheFwiXG5pbXBvcnQgQ2hhbm5lbCBmcm9tIFwiLi9jaGFubmVsXCJcbmltcG9ydCBMb25nUG9sbCBmcm9tIFwiLi9sb25ncG9sbFwiXG5pbXBvcnQgU2VyaWFsaXplciBmcm9tIFwiLi9zZXJpYWxpemVyXCJcbmltcG9ydCBUaW1lciBmcm9tIFwiLi90aW1lclwiXG5cbi8qKiBJbml0aWFsaXplcyB0aGUgU29ja2V0ICpcbiAqXG4gKiBGb3IgSUU4IHN1cHBvcnQgdXNlIGFuIEVTNS1zaGltIChodHRwczovL2dpdGh1Yi5jb20vZXMtc2hpbXMvZXM1LXNoaW0pXG4gKlxuICogQHBhcmFtIHtzdHJpbmd9IGVuZFBvaW50IC0gVGhlIHN0cmluZyBXZWJTb2NrZXQgZW5kcG9pbnQsIGllLCBgXCJ3czovL2V4YW1wbGUuY29tL3NvY2tldFwiYCxcbiAqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBgXCJ3c3M6Ly9leGFtcGxlLmNvbVwiYFxuICogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGBcIi9zb2NrZXRcImAgKGluaGVyaXRlZCBob3N0ICYgcHJvdG9jb2wpXG4gKiBAcGFyYW0ge09iamVjdH0gW29wdHNdIC0gT3B0aW9uYWwgY29uZmlndXJhdGlvblxuICogQHBhcmFtIHtGdW5jdGlvbn0gW29wdHMudHJhbnNwb3J0XSAtIFRoZSBXZWJzb2NrZXQgVHJhbnNwb3J0LCBmb3IgZXhhbXBsZSBXZWJTb2NrZXQgb3IgUGhvZW5peC5Mb25nUG9sbC5cbiAqXG4gKiBEZWZhdWx0cyB0byBXZWJTb2NrZXQgd2l0aCBhdXRvbWF0aWMgTG9uZ1BvbGwgZmFsbGJhY2sgaWYgV2ViU29ja2V0IGlzIG5vdCBkZWZpbmVkLlxuICogVG8gZmFsbGJhY2sgdG8gTG9uZ1BvbGwgd2hlbiBXZWJTb2NrZXQgYXR0ZW1wdHMgZmFpbCwgdXNlIGBsb25nUG9sbEZhbGxiYWNrTXM6IDI1MDBgLlxuICpcbiAqIEBwYXJhbSB7bnVtYmVyfSBbb3B0cy5sb25nUG9sbEZhbGxiYWNrTXNdIC0gVGhlIG1pbGxpc2Vjb25kIHRpbWUgdG8gYXR0ZW1wdCB0aGUgcHJpbWFyeSB0cmFuc3BvcnRcbiAqIGJlZm9yZSBmYWxsaW5nIGJhY2sgdG8gdGhlIExvbmdQb2xsIHRyYW5zcG9ydC4gRGlzYWJsZWQgYnkgZGVmYXVsdC5cbiAqXG4gKiBAcGFyYW0ge2Jvb2xlYW59IFtvcHRzLmRlYnVnXSAtIFdoZW4gdHJ1ZSwgZW5hYmxlcyBkZWJ1ZyBsb2dnaW5nLiBEZWZhdWx0IGZhbHNlLlxuICpcbiAqIEBwYXJhbSB7RnVuY3Rpb259IFtvcHRzLmVuY29kZV0gLSBUaGUgZnVuY3Rpb24gdG8gZW5jb2RlIG91dGdvaW5nIG1lc3NhZ2VzLlxuICpcbiAqIERlZmF1bHRzIHRvIEpTT04gZW5jb2Rlci5cbiAqXG4gKiBAcGFyYW0ge0Z1bmN0aW9ufSBbb3B0cy5kZWNvZGVdIC0gVGhlIGZ1bmN0aW9uIHRvIGRlY29kZSBpbmNvbWluZyBtZXNzYWdlcy5cbiAqXG4gKiBEZWZhdWx0cyB0byBKU09OOlxuICpcbiAqIGBgYGphdmFzY3JpcHRcbiAqIChwYXlsb2FkLCBjYWxsYmFjaykgPT4gY2FsbGJhY2soSlNPTi5wYXJzZShwYXlsb2FkKSlcbiAqIGBgYFxuICpcbiAqIEBwYXJhbSB7bnVtYmVyfSBbb3B0cy50aW1lb3V0XSAtIFRoZSBkZWZhdWx0IHRpbWVvdXQgaW4gbWlsbGlzZWNvbmRzIHRvIHRyaWdnZXIgcHVzaCB0aW1lb3V0cy5cbiAqXG4gKiBEZWZhdWx0cyBgREVGQVVMVF9USU1FT1VUYFxuICogQHBhcmFtIHtudW1iZXJ9IFtvcHRzLmhlYXJ0YmVhdEludGVydmFsTXNdIC0gVGhlIG1pbGxpc2VjIGludGVydmFsIHRvIHNlbmQgYSBoZWFydGJlYXQgbWVzc2FnZVxuICogQHBhcmFtIHtGdW5jdGlvbn0gW29wdHMucmVjb25uZWN0QWZ0ZXJNc10gLSBUaGUgb3B0aW9uYWwgZnVuY3Rpb24gdGhhdCByZXR1cm5zIHRoZVxuICogc29ja2V0IHJlY29ubmVjdCBpbnRlcnZhbCwgaW4gbWlsbGlzZWNvbmRzLlxuICpcbiAqIERlZmF1bHRzIHRvIHN0ZXBwZWQgYmFja29mZiBvZjpcbiAqXG4gKiBgYGBqYXZhc2NyaXB0XG4gKiBmdW5jdGlvbih0cmllcyl7XG4gKiAgIHJldHVybiBbMTAsIDUwLCAxMDAsIDE1MCwgMjAwLCAyNTAsIDUwMCwgMTAwMCwgMjAwMF1bdHJpZXMgLSAxXSB8fCA1MDAwXG4gKiB9XG4gKiBgYGBgXG4gKlxuICogQHBhcmFtIHtGdW5jdGlvbn0gW29wdHMucmVqb2luQWZ0ZXJNc10gLSBUaGUgb3B0aW9uYWwgZnVuY3Rpb24gdGhhdCByZXR1cm5zIHRoZSBtaWxsaXNlY1xuICogcmVqb2luIGludGVydmFsIGZvciBpbmRpdmlkdWFsIGNoYW5uZWxzLlxuICpcbiAqIGBgYGphdmFzY3JpcHRcbiAqIGZ1bmN0aW9uKHRyaWVzKXtcbiAqICAgcmV0dXJuIFsxMDAwLCAyMDAwLCA1MDAwXVt0cmllcyAtIDFdIHx8IDEwMDAwXG4gKiB9XG4gKiBgYGBgXG4gKlxuICogQHBhcmFtIHtGdW5jdGlvbn0gW29wdHMubG9nZ2VyXSAtIFRoZSBvcHRpb25hbCBmdW5jdGlvbiBmb3Igc3BlY2lhbGl6ZWQgbG9nZ2luZywgaWU6XG4gKlxuICogYGBgamF2YXNjcmlwdFxuICogZnVuY3Rpb24oa2luZCwgbXNnLCBkYXRhKSB7XG4gKiAgIGNvbnNvbGUubG9nKGAke2tpbmR9OiAke21zZ31gLCBkYXRhKVxuICogfVxuICogYGBgXG4gKlxuICogQHBhcmFtIHtudW1iZXJ9IFtvcHRzLmxvbmdwb2xsZXJUaW1lb3V0XSAtIFRoZSBtYXhpbXVtIHRpbWVvdXQgb2YgYSBsb25nIHBvbGwgQUpBWCByZXF1ZXN0LlxuICpcbiAqIERlZmF1bHRzIHRvIDIwcyAoZG91YmxlIHRoZSBzZXJ2ZXIgbG9uZyBwb2xsIHRpbWVyKS5cbiAqXG4gKiBAcGFyYW0geyhPYmplY3R8ZnVuY3Rpb24pfSBbb3B0cy5wYXJhbXNdIC0gVGhlIG9wdGlvbmFsIHBhcmFtcyB0byBwYXNzIHdoZW4gY29ubmVjdGluZ1xuICogQHBhcmFtIHtzdHJpbmd9IFtvcHRzLmF1dGhUb2tlbl0gLSB0aGUgb3B0aW9uYWwgYXV0aGVudGljYXRpb24gdG9rZW4gdG8gYmUgZXhwb3NlZCBvbiB0aGUgc2VydmVyXG4gKiB1bmRlciB0aGUgYDphdXRoX3Rva2VuYCBjb25uZWN0X2luZm8ga2V5LlxuICogQHBhcmFtIHtzdHJpbmd9IFtvcHRzLmJpbmFyeVR5cGVdIC0gVGhlIGJpbmFyeSB0eXBlIHRvIHVzZSBmb3IgYmluYXJ5IFdlYlNvY2tldCBmcmFtZXMuXG4gKlxuICogRGVmYXVsdHMgdG8gXCJhcnJheWJ1ZmZlclwiXG4gKlxuICogQHBhcmFtIHt2c259IFtvcHRzLnZzbl0gLSBUaGUgc2VyaWFsaXplcidzIHByb3RvY29sIHZlcnNpb24gdG8gc2VuZCBvbiBjb25uZWN0LlxuICpcbiAqIERlZmF1bHRzIHRvIERFRkFVTFRfVlNOLlxuICpcbiAqIEBwYXJhbSB7T2JqZWN0fSBbb3B0cy5zZXNzaW9uU3RvcmFnZV0gLSBBbiBvcHRpb25hbCBTdG9yYWdlIGNvbXBhdGlibGUgb2JqZWN0XG4gKiBQaG9lbml4IHVzZXMgc2Vzc2lvblN0b3JhZ2UgZm9yIGxvbmdwb2xsIGZhbGxiYWNrIGhpc3RvcnkuIE92ZXJyaWRpbmcgdGhlIHN0b3JlIGlzXG4gKiB1c2VmdWwgd2hlbiBQaG9lbml4IHdvbid0IGhhdmUgYWNjZXNzIHRvIGBzZXNzaW9uU3RvcmFnZWAuIEZvciBleGFtcGxlLCBUaGlzIGNvdWxkXG4gKiBoYXBwZW4gaWYgYSBzaXRlIGxvYWRzIGEgY3Jvc3MtZG9tYWluIGNoYW5uZWwgaW4gYW4gaWZyYW1lLiBFeGFtcGxlIHVzYWdlOlxuICpcbiAqICAgICBjbGFzcyBJbk1lbW9yeVN0b3JhZ2Uge1xuICogICAgICAgY29uc3RydWN0b3IoKSB7IHRoaXMuc3RvcmFnZSA9IHt9IH1cbiAqICAgICAgIGdldEl0ZW0oa2V5TmFtZSkgeyByZXR1cm4gdGhpcy5zdG9yYWdlW2tleU5hbWVdIHx8IG51bGwgfVxuICogICAgICAgcmVtb3ZlSXRlbShrZXlOYW1lKSB7IGRlbGV0ZSB0aGlzLnN0b3JhZ2Vba2V5TmFtZV0gfVxuICogICAgICAgc2V0SXRlbShrZXlOYW1lLCBrZXlWYWx1ZSkgeyB0aGlzLnN0b3JhZ2Vba2V5TmFtZV0gPSBrZXlWYWx1ZSB9XG4gKiAgICAgfVxuICpcbiovXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBTb2NrZXQge1xuICBjb25zdHJ1Y3RvcihlbmRQb2ludCwgb3B0cyA9IHt9KXtcbiAgICB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzID0ge29wZW46IFtdLCBjbG9zZTogW10sIGVycm9yOiBbXSwgbWVzc2FnZTogW119XG4gICAgdGhpcy5jaGFubmVscyA9IFtdXG4gICAgdGhpcy5zZW5kQnVmZmVyID0gW11cbiAgICB0aGlzLnJlZiA9IDBcbiAgICB0aGlzLnRpbWVvdXQgPSBvcHRzLnRpbWVvdXQgfHwgREVGQVVMVF9USU1FT1VUXG4gICAgdGhpcy50cmFuc3BvcnQgPSBvcHRzLnRyYW5zcG9ydCB8fCBnbG9iYWwuV2ViU29ja2V0IHx8IExvbmdQb2xsXG4gICAgdGhpcy5wcmltYXJ5UGFzc2VkSGVhbHRoQ2hlY2sgPSBmYWxzZVxuICAgIHRoaXMubG9uZ1BvbGxGYWxsYmFja01zID0gb3B0cy5sb25nUG9sbEZhbGxiYWNrTXNcbiAgICB0aGlzLmZhbGxiYWNrVGltZXIgPSBudWxsXG4gICAgdGhpcy5zZXNzaW9uU3RvcmUgPSBvcHRzLnNlc3Npb25TdG9yYWdlIHx8IChnbG9iYWwgJiYgZ2xvYmFsLnNlc3Npb25TdG9yYWdlKVxuICAgIHRoaXMuZXN0YWJsaXNoZWRDb25uZWN0aW9ucyA9IDBcbiAgICB0aGlzLmRlZmF1bHRFbmNvZGVyID0gU2VyaWFsaXplci5lbmNvZGUuYmluZChTZXJpYWxpemVyKVxuICAgIHRoaXMuZGVmYXVsdERlY29kZXIgPSBTZXJpYWxpemVyLmRlY29kZS5iaW5kKFNlcmlhbGl6ZXIpXG4gICAgdGhpcy5jbG9zZVdhc0NsZWFuID0gZmFsc2VcbiAgICB0aGlzLmRpc2Nvbm5lY3RpbmcgPSBmYWxzZVxuICAgIHRoaXMuYmluYXJ5VHlwZSA9IG9wdHMuYmluYXJ5VHlwZSB8fCBcImFycmF5YnVmZmVyXCJcbiAgICB0aGlzLmNvbm5lY3RDbG9jayA9IDFcbiAgICBpZih0aGlzLnRyYW5zcG9ydCAhPT0gTG9uZ1BvbGwpe1xuICAgICAgdGhpcy5lbmNvZGUgPSBvcHRzLmVuY29kZSB8fCB0aGlzLmRlZmF1bHRFbmNvZGVyXG4gICAgICB0aGlzLmRlY29kZSA9IG9wdHMuZGVjb2RlIHx8IHRoaXMuZGVmYXVsdERlY29kZXJcbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy5lbmNvZGUgPSB0aGlzLmRlZmF1bHRFbmNvZGVyXG4gICAgICB0aGlzLmRlY29kZSA9IHRoaXMuZGVmYXVsdERlY29kZXJcbiAgICB9XG4gICAgbGV0IGF3YWl0aW5nQ29ubmVjdGlvbk9uUGFnZVNob3cgPSBudWxsXG4gICAgaWYocGh4V2luZG93ICYmIHBoeFdpbmRvdy5hZGRFdmVudExpc3RlbmVyKXtcbiAgICAgIHBoeFdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwicGFnZWhpZGVcIiwgX2UgPT4ge1xuICAgICAgICBpZih0aGlzLmNvbm4pe1xuICAgICAgICAgIHRoaXMuZGlzY29ubmVjdCgpXG4gICAgICAgICAgYXdhaXRpbmdDb25uZWN0aW9uT25QYWdlU2hvdyA9IHRoaXMuY29ubmVjdENsb2NrXG4gICAgICAgIH1cbiAgICAgIH0pXG4gICAgICBwaHhXaW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihcInBhZ2VzaG93XCIsIF9lID0+IHtcbiAgICAgICAgaWYoYXdhaXRpbmdDb25uZWN0aW9uT25QYWdlU2hvdyA9PT0gdGhpcy5jb25uZWN0Q2xvY2spe1xuICAgICAgICAgIGF3YWl0aW5nQ29ubmVjdGlvbk9uUGFnZVNob3cgPSBudWxsXG4gICAgICAgICAgdGhpcy5jb25uZWN0KClcbiAgICAgICAgfVxuICAgICAgfSlcbiAgICB9XG4gICAgdGhpcy5oZWFydGJlYXRJbnRlcnZhbE1zID0gb3B0cy5oZWFydGJlYXRJbnRlcnZhbE1zIHx8IDMwMDAwXG4gICAgdGhpcy5yZWpvaW5BZnRlck1zID0gKHRyaWVzKSA9PiB7XG4gICAgICBpZihvcHRzLnJlam9pbkFmdGVyTXMpe1xuICAgICAgICByZXR1cm4gb3B0cy5yZWpvaW5BZnRlck1zKHRyaWVzKVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgcmV0dXJuIFsxMDAwLCAyMDAwLCA1MDAwXVt0cmllcyAtIDFdIHx8IDEwMDAwXG4gICAgICB9XG4gICAgfVxuICAgIHRoaXMucmVjb25uZWN0QWZ0ZXJNcyA9ICh0cmllcykgPT4ge1xuICAgICAgaWYob3B0cy5yZWNvbm5lY3RBZnRlck1zKXtcbiAgICAgICAgcmV0dXJuIG9wdHMucmVjb25uZWN0QWZ0ZXJNcyh0cmllcylcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHJldHVybiBbMTAsIDUwLCAxMDAsIDE1MCwgMjAwLCAyNTAsIDUwMCwgMTAwMCwgMjAwMF1bdHJpZXMgLSAxXSB8fCA1MDAwXG4gICAgICB9XG4gICAgfVxuICAgIHRoaXMubG9nZ2VyID0gb3B0cy5sb2dnZXIgfHwgbnVsbFxuICAgIGlmKCF0aGlzLmxvZ2dlciAmJiBvcHRzLmRlYnVnKXtcbiAgICAgIHRoaXMubG9nZ2VyID0gKGtpbmQsIG1zZywgZGF0YSkgPT4geyBjb25zb2xlLmxvZyhgJHtraW5kfTogJHttc2d9YCwgZGF0YSkgfVxuICAgIH1cbiAgICB0aGlzLmxvbmdwb2xsZXJUaW1lb3V0ID0gb3B0cy5sb25ncG9sbGVyVGltZW91dCB8fCAyMDAwMFxuICAgIHRoaXMucGFyYW1zID0gY2xvc3VyZShvcHRzLnBhcmFtcyB8fCB7fSlcbiAgICB0aGlzLmVuZFBvaW50ID0gYCR7ZW5kUG9pbnR9LyR7VFJBTlNQT1JUUy53ZWJzb2NrZXR9YFxuICAgIHRoaXMudnNuID0gb3B0cy52c24gfHwgREVGQVVMVF9WU05cbiAgICB0aGlzLmhlYXJ0YmVhdFRpbWVvdXRUaW1lciA9IG51bGxcbiAgICB0aGlzLmhlYXJ0YmVhdFRpbWVyID0gbnVsbFxuICAgIHRoaXMucGVuZGluZ0hlYXJ0YmVhdFJlZiA9IG51bGxcbiAgICB0aGlzLnJlY29ubmVjdFRpbWVyID0gbmV3IFRpbWVyKCgpID0+IHtcbiAgICAgIHRoaXMudGVhcmRvd24oKCkgPT4gdGhpcy5jb25uZWN0KCkpXG4gICAgfSwgdGhpcy5yZWNvbm5lY3RBZnRlck1zKVxuICAgIHRoaXMuYXV0aFRva2VuID0gb3B0cy5hdXRoVG9rZW5cbiAgfVxuXG4gIC8qKlxuICAgKiBSZXR1cm5zIHRoZSBMb25nUG9sbCB0cmFuc3BvcnQgcmVmZXJlbmNlXG4gICAqL1xuICBnZXRMb25nUG9sbFRyYW5zcG9ydCgpeyByZXR1cm4gTG9uZ1BvbGwgfVxuXG4gIC8qKlxuICAgKiBEaXNjb25uZWN0cyBhbmQgcmVwbGFjZXMgdGhlIGFjdGl2ZSB0cmFuc3BvcnRcbiAgICpcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gbmV3VHJhbnNwb3J0IC0gVGhlIG5ldyB0cmFuc3BvcnQgY2xhc3MgdG8gaW5zdGFudGlhdGVcbiAgICpcbiAgICovXG4gIHJlcGxhY2VUcmFuc3BvcnQobmV3VHJhbnNwb3J0KXtcbiAgICB0aGlzLmNvbm5lY3RDbG9jaysrXG4gICAgdGhpcy5jbG9zZVdhc0NsZWFuID0gdHJ1ZVxuICAgIGNsZWFyVGltZW91dCh0aGlzLmZhbGxiYWNrVGltZXIpXG4gICAgdGhpcy5yZWNvbm5lY3RUaW1lci5yZXNldCgpXG4gICAgaWYodGhpcy5jb25uKXtcbiAgICAgIHRoaXMuY29ubi5jbG9zZSgpXG4gICAgICB0aGlzLmNvbm4gPSBudWxsXG4gICAgfVxuICAgIHRoaXMudHJhbnNwb3J0ID0gbmV3VHJhbnNwb3J0XG4gIH1cblxuICAvKipcbiAgICogUmV0dXJucyB0aGUgc29ja2V0IHByb3RvY29sXG4gICAqXG4gICAqIEByZXR1cm5zIHtzdHJpbmd9XG4gICAqL1xuICBwcm90b2NvbCgpeyByZXR1cm4gbG9jYXRpb24ucHJvdG9jb2wubWF0Y2goL15odHRwcy8pID8gXCJ3c3NcIiA6IFwid3NcIiB9XG5cbiAgLyoqXG4gICAqIFRoZSBmdWxseSBxdWFsaWZpZWQgc29ja2V0IHVybFxuICAgKlxuICAgKiBAcmV0dXJucyB7c3RyaW5nfVxuICAgKi9cbiAgZW5kUG9pbnRVUkwoKXtcbiAgICBsZXQgdXJpID0gQWpheC5hcHBlbmRQYXJhbXMoXG4gICAgICBBamF4LmFwcGVuZFBhcmFtcyh0aGlzLmVuZFBvaW50LCB0aGlzLnBhcmFtcygpKSwge3ZzbjogdGhpcy52c259KVxuICAgIGlmKHVyaS5jaGFyQXQoMCkgIT09IFwiL1wiKXsgcmV0dXJuIHVyaSB9XG4gICAgaWYodXJpLmNoYXJBdCgxKSA9PT0gXCIvXCIpeyByZXR1cm4gYCR7dGhpcy5wcm90b2NvbCgpfToke3VyaX1gIH1cblxuICAgIHJldHVybiBgJHt0aGlzLnByb3RvY29sKCl9Oi8vJHtsb2NhdGlvbi5ob3N0fSR7dXJpfWBcbiAgfVxuXG4gIC8qKlxuICAgKiBEaXNjb25uZWN0cyB0aGUgc29ja2V0XG4gICAqXG4gICAqIFNlZSBodHRwczovL2RldmVsb3Blci5tb3ppbGxhLm9yZy9lbi1VUy9kb2NzL1dlYi9BUEkvQ2xvc2VFdmVudCNTdGF0dXNfY29kZXMgZm9yIHZhbGlkIHN0YXR1cyBjb2Rlcy5cbiAgICpcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2sgLSBPcHRpb25hbCBjYWxsYmFjayB3aGljaCBpcyBjYWxsZWQgYWZ0ZXIgc29ja2V0IGlzIGRpc2Nvbm5lY3RlZC5cbiAgICogQHBhcmFtIHtpbnRlZ2VyfSBjb2RlIC0gQSBzdGF0dXMgY29kZSBmb3IgZGlzY29ubmVjdGlvbiAoT3B0aW9uYWwpLlxuICAgKiBAcGFyYW0ge3N0cmluZ30gcmVhc29uIC0gQSB0ZXh0dWFsIGRlc2NyaXB0aW9uIG9mIHRoZSByZWFzb24gdG8gZGlzY29ubmVjdC4gKE9wdGlvbmFsKVxuICAgKi9cbiAgZGlzY29ubmVjdChjYWxsYmFjaywgY29kZSwgcmVhc29uKXtcbiAgICB0aGlzLmNvbm5lY3RDbG9jaysrXG4gICAgdGhpcy5kaXNjb25uZWN0aW5nID0gdHJ1ZVxuICAgIHRoaXMuY2xvc2VXYXNDbGVhbiA9IHRydWVcbiAgICBjbGVhclRpbWVvdXQodGhpcy5mYWxsYmFja1RpbWVyKVxuICAgIHRoaXMucmVjb25uZWN0VGltZXIucmVzZXQoKVxuICAgIHRoaXMudGVhcmRvd24oKCkgPT4ge1xuICAgICAgdGhpcy5kaXNjb25uZWN0aW5nID0gZmFsc2VcbiAgICAgIGNhbGxiYWNrICYmIGNhbGxiYWNrKClcbiAgICB9LCBjb2RlLCByZWFzb24pXG4gIH1cblxuICAvKipcbiAgICpcbiAgICogQHBhcmFtIHtPYmplY3R9IHBhcmFtcyAtIFRoZSBwYXJhbXMgdG8gc2VuZCB3aGVuIGNvbm5lY3RpbmcsIGZvciBleGFtcGxlIGB7dXNlcl9pZDogdXNlclRva2VufWBcbiAgICpcbiAgICogUGFzc2luZyBwYXJhbXMgdG8gY29ubmVjdCBpcyBkZXByZWNhdGVkOyBwYXNzIHRoZW0gaW4gdGhlIFNvY2tldCBjb25zdHJ1Y3RvciBpbnN0ZWFkOlxuICAgKiBgbmV3IFNvY2tldChcIi9zb2NrZXRcIiwge3BhcmFtczoge3VzZXJfaWQ6IHVzZXJUb2tlbn19KWAuXG4gICAqL1xuICBjb25uZWN0KHBhcmFtcyl7XG4gICAgaWYocGFyYW1zKXtcbiAgICAgIGNvbnNvbGUgJiYgY29uc29sZS5sb2coXCJwYXNzaW5nIHBhcmFtcyB0byBjb25uZWN0IGlzIGRlcHJlY2F0ZWQuIEluc3RlYWQgcGFzcyA6cGFyYW1zIHRvIHRoZSBTb2NrZXQgY29uc3RydWN0b3JcIilcbiAgICAgIHRoaXMucGFyYW1zID0gY2xvc3VyZShwYXJhbXMpXG4gICAgfVxuICAgIGlmKHRoaXMuY29ubiAmJiAhdGhpcy5kaXNjb25uZWN0aW5nKXsgcmV0dXJuIH1cbiAgICBpZih0aGlzLmxvbmdQb2xsRmFsbGJhY2tNcyAmJiB0aGlzLnRyYW5zcG9ydCAhPT0gTG9uZ1BvbGwpe1xuICAgICAgdGhpcy5jb25uZWN0V2l0aEZhbGxiYWNrKExvbmdQb2xsLCB0aGlzLmxvbmdQb2xsRmFsbGJhY2tNcylcbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy50cmFuc3BvcnRDb25uZWN0KClcbiAgICB9XG4gIH1cblxuICAvKipcbiAgICogTG9ncyB0aGUgbWVzc2FnZS4gT3ZlcnJpZGUgYHRoaXMubG9nZ2VyYCBmb3Igc3BlY2lhbGl6ZWQgbG9nZ2luZy4gbm9vcHMgYnkgZGVmYXVsdFxuICAgKiBAcGFyYW0ge3N0cmluZ30ga2luZFxuICAgKiBAcGFyYW0ge3N0cmluZ30gbXNnXG4gICAqIEBwYXJhbSB7T2JqZWN0fSBkYXRhXG4gICAqL1xuICBsb2coa2luZCwgbXNnLCBkYXRhKXsgdGhpcy5sb2dnZXIgJiYgdGhpcy5sb2dnZXIoa2luZCwgbXNnLCBkYXRhKSB9XG5cbiAgLyoqXG4gICAqIFJldHVybnMgdHJ1ZSBpZiBhIGxvZ2dlciBoYXMgYmVlbiBzZXQgb24gdGhpcyBzb2NrZXQuXG4gICAqL1xuICBoYXNMb2dnZXIoKXsgcmV0dXJuIHRoaXMubG9nZ2VyICE9PSBudWxsIH1cblxuICAvKipcbiAgICogUmVnaXN0ZXJzIGNhbGxiYWNrcyBmb3IgY29ubmVjdGlvbiBvcGVuIGV2ZW50c1xuICAgKlxuICAgKiBAZXhhbXBsZSBzb2NrZXQub25PcGVuKGZ1bmN0aW9uKCl7IGNvbnNvbGUuaW5mbyhcInRoZSBzb2NrZXQgd2FzIG9wZW5lZFwiKSB9KVxuICAgKlxuICAgKiBAcGFyYW0ge0Z1bmN0aW9ufSBjYWxsYmFja1xuICAgKi9cbiAgb25PcGVuKGNhbGxiYWNrKXtcbiAgICBsZXQgcmVmID0gdGhpcy5tYWtlUmVmKClcbiAgICB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzLm9wZW4ucHVzaChbcmVmLCBjYWxsYmFja10pXG4gICAgcmV0dXJuIHJlZlxuICB9XG5cbiAgLyoqXG4gICAqIFJlZ2lzdGVycyBjYWxsYmFja3MgZm9yIGNvbm5lY3Rpb24gY2xvc2UgZXZlbnRzXG4gICAqIEBwYXJhbSB7RnVuY3Rpb259IGNhbGxiYWNrXG4gICAqL1xuICBvbkNsb3NlKGNhbGxiYWNrKXtcbiAgICBsZXQgcmVmID0gdGhpcy5tYWtlUmVmKClcbiAgICB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzLmNsb3NlLnB1c2goW3JlZiwgY2FsbGJhY2tdKVxuICAgIHJldHVybiByZWZcbiAgfVxuXG4gIC8qKlxuICAgKiBSZWdpc3RlcnMgY2FsbGJhY2tzIGZvciBjb25uZWN0aW9uIGVycm9yIGV2ZW50c1xuICAgKlxuICAgKiBAZXhhbXBsZSBzb2NrZXQub25FcnJvcihmdW5jdGlvbihlcnJvcil7IGFsZXJ0KFwiQW4gZXJyb3Igb2NjdXJyZWRcIikgfSlcbiAgICpcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2tcbiAgICovXG4gIG9uRXJyb3IoY2FsbGJhY2spe1xuICAgIGxldCByZWYgPSB0aGlzLm1ha2VSZWYoKVxuICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3MuZXJyb3IucHVzaChbcmVmLCBjYWxsYmFja10pXG4gICAgcmV0dXJuIHJlZlxuICB9XG5cbiAgLyoqXG4gICAqIFJlZ2lzdGVycyBjYWxsYmFja3MgZm9yIGNvbm5lY3Rpb24gbWVzc2FnZSBldmVudHNcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2tcbiAgICovXG4gIG9uTWVzc2FnZShjYWxsYmFjayl7XG4gICAgbGV0IHJlZiA9IHRoaXMubWFrZVJlZigpXG4gICAgdGhpcy5zdGF0ZUNoYW5nZUNhbGxiYWNrcy5tZXNzYWdlLnB1c2goW3JlZiwgY2FsbGJhY2tdKVxuICAgIHJldHVybiByZWZcbiAgfVxuXG4gIC8qKlxuICAgKiBQaW5ncyB0aGUgc2VydmVyIGFuZCBpbnZva2VzIHRoZSBjYWxsYmFjayB3aXRoIHRoZSBSVFQgaW4gbWlsbGlzZWNvbmRzXG4gICAqIEBwYXJhbSB7RnVuY3Rpb259IGNhbGxiYWNrXG4gICAqXG4gICAqIFJldHVybnMgdHJ1ZSBpZiB0aGUgcGluZyB3YXMgcHVzaGVkIG9yIGZhbHNlIGlmIHVuYWJsZSB0byBiZSBwdXNoZWQuXG4gICAqL1xuICBwaW5nKGNhbGxiYWNrKXtcbiAgICBpZighdGhpcy5pc0Nvbm5lY3RlZCgpKXsgcmV0dXJuIGZhbHNlIH1cbiAgICBsZXQgcmVmID0gdGhpcy5tYWtlUmVmKClcbiAgICBsZXQgc3RhcnRUaW1lID0gRGF0ZS5ub3coKVxuICAgIHRoaXMucHVzaCh7dG9waWM6IFwicGhvZW5peFwiLCBldmVudDogXCJoZWFydGJlYXRcIiwgcGF5bG9hZDoge30sIHJlZjogcmVmfSlcbiAgICBsZXQgb25Nc2dSZWYgPSB0aGlzLm9uTWVzc2FnZShtc2cgPT4ge1xuICAgICAgaWYobXNnLnJlZiA9PT0gcmVmKXtcbiAgICAgICAgdGhpcy5vZmYoW29uTXNnUmVmXSlcbiAgICAgICAgY2FsbGJhY2soRGF0ZS5ub3coKSAtIHN0YXJ0VGltZSlcbiAgICAgIH1cbiAgICB9KVxuICAgIHJldHVybiB0cnVlXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG5cbiAgdHJhbnNwb3J0Q29ubmVjdCgpe1xuICAgIHRoaXMuY29ubmVjdENsb2NrKytcbiAgICB0aGlzLmNsb3NlV2FzQ2xlYW4gPSBmYWxzZVxuICAgIGxldCBwcm90b2NvbHMgPSB1bmRlZmluZWRcbiAgICAvLyBTZWMtV2ViU29ja2V0LVByb3RvY29sIGJhc2VkIHRva2VuXG4gICAgLy8gKGxvbmdwb2xsIHVzZXMgQXV0aG9yaXphdGlvbiBoZWFkZXIgaW5zdGVhZClcbiAgICBpZih0aGlzLmF1dGhUb2tlbil7XG4gICAgICBwcm90b2NvbHMgPSBbXCJwaG9lbml4XCIsIGAke0FVVEhfVE9LRU5fUFJFRklYfSR7YnRvYSh0aGlzLmF1dGhUb2tlbikucmVwbGFjZSgvPS9nLCBcIlwiKX1gXVxuICAgIH1cbiAgICB0aGlzLmNvbm4gPSBuZXcgdGhpcy50cmFuc3BvcnQodGhpcy5lbmRQb2ludFVSTCgpLCBwcm90b2NvbHMpXG4gICAgdGhpcy5jb25uLmJpbmFyeVR5cGUgPSB0aGlzLmJpbmFyeVR5cGVcbiAgICB0aGlzLmNvbm4udGltZW91dCA9IHRoaXMubG9uZ3BvbGxlclRpbWVvdXRcbiAgICB0aGlzLmNvbm4ub25vcGVuID0gKCkgPT4gdGhpcy5vbkNvbm5PcGVuKClcbiAgICB0aGlzLmNvbm4ub25lcnJvciA9IGVycm9yID0+IHRoaXMub25Db25uRXJyb3IoZXJyb3IpXG4gICAgdGhpcy5jb25uLm9ubWVzc2FnZSA9IGV2ZW50ID0+IHRoaXMub25Db25uTWVzc2FnZShldmVudClcbiAgICB0aGlzLmNvbm4ub25jbG9zZSA9IGV2ZW50ID0+IHRoaXMub25Db25uQ2xvc2UoZXZlbnQpXG4gIH1cblxuICBnZXRTZXNzaW9uKGtleSl7IHJldHVybiB0aGlzLnNlc3Npb25TdG9yZSAmJiB0aGlzLnNlc3Npb25TdG9yZS5nZXRJdGVtKGtleSkgfVxuXG4gIHN0b3JlU2Vzc2lvbihrZXksIHZhbCl7IHRoaXMuc2Vzc2lvblN0b3JlICYmIHRoaXMuc2Vzc2lvblN0b3JlLnNldEl0ZW0oa2V5LCB2YWwpIH1cblxuICBjb25uZWN0V2l0aEZhbGxiYWNrKGZhbGxiYWNrVHJhbnNwb3J0LCBmYWxsYmFja1RocmVzaG9sZCA9IDI1MDApe1xuICAgIGNsZWFyVGltZW91dCh0aGlzLmZhbGxiYWNrVGltZXIpXG4gICAgbGV0IGVzdGFibGlzaGVkID0gZmFsc2VcbiAgICBsZXQgcHJpbWFyeVRyYW5zcG9ydCA9IHRydWVcbiAgICBsZXQgb3BlblJlZiwgZXJyb3JSZWZcbiAgICBsZXQgZmFsbGJhY2sgPSAocmVhc29uKSA9PiB7XG4gICAgICB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBgZmFsbGluZyBiYWNrIHRvICR7ZmFsbGJhY2tUcmFuc3BvcnQubmFtZX0uLi5gLCByZWFzb24pXG4gICAgICB0aGlzLm9mZihbb3BlblJlZiwgZXJyb3JSZWZdKVxuICAgICAgcHJpbWFyeVRyYW5zcG9ydCA9IGZhbHNlXG4gICAgICB0aGlzLnJlcGxhY2VUcmFuc3BvcnQoZmFsbGJhY2tUcmFuc3BvcnQpXG4gICAgICB0aGlzLnRyYW5zcG9ydENvbm5lY3QoKVxuICAgIH1cbiAgICBpZih0aGlzLmdldFNlc3Npb24oYHBoeDpmYWxsYmFjazoke2ZhbGxiYWNrVHJhbnNwb3J0Lm5hbWV9YCkpeyByZXR1cm4gZmFsbGJhY2soXCJtZW1vcml6ZWRcIikgfVxuXG4gICAgdGhpcy5mYWxsYmFja1RpbWVyID0gc2V0VGltZW91dChmYWxsYmFjaywgZmFsbGJhY2tUaHJlc2hvbGQpXG5cbiAgICBlcnJvclJlZiA9IHRoaXMub25FcnJvcihyZWFzb24gPT4ge1xuICAgICAgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJlcnJvclwiLCByZWFzb24pXG4gICAgICBpZihwcmltYXJ5VHJhbnNwb3J0ICYmICFlc3RhYmxpc2hlZCl7XG4gICAgICAgIGNsZWFyVGltZW91dCh0aGlzLmZhbGxiYWNrVGltZXIpXG4gICAgICAgIGZhbGxiYWNrKHJlYXNvbilcbiAgICAgIH1cbiAgICB9KVxuICAgIHRoaXMub25PcGVuKCgpID0+IHtcbiAgICAgIGVzdGFibGlzaGVkID0gdHJ1ZVxuICAgICAgaWYoIXByaW1hcnlUcmFuc3BvcnQpe1xuICAgICAgICAvLyBvbmx5IG1lbW9yaXplIExQIGlmIHdlIG5ldmVyIGNvbm5lY3RlZCB0byBwcmltYXJ5XG4gICAgICAgIGlmKCF0aGlzLnByaW1hcnlQYXNzZWRIZWFsdGhDaGVjayl7IHRoaXMuc3RvcmVTZXNzaW9uKGBwaHg6ZmFsbGJhY2s6JHtmYWxsYmFja1RyYW5zcG9ydC5uYW1lfWAsIFwidHJ1ZVwiKSB9XG4gICAgICAgIHJldHVybiB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBgZXN0YWJsaXNoZWQgJHtmYWxsYmFja1RyYW5zcG9ydC5uYW1lfSBmYWxsYmFja2ApXG4gICAgICB9XG4gICAgICAvLyBpZiB3ZSd2ZSBlc3RhYmxpc2hlZCBwcmltYXJ5LCBnaXZlIHRoZSBmYWxsYmFjayBhIG5ldyBwZXJpb2QgdG8gYXR0ZW1wdCBwaW5nXG4gICAgICBjbGVhclRpbWVvdXQodGhpcy5mYWxsYmFja1RpbWVyKVxuICAgICAgdGhpcy5mYWxsYmFja1RpbWVyID0gc2V0VGltZW91dChmYWxsYmFjaywgZmFsbGJhY2tUaHJlc2hvbGQpXG4gICAgICB0aGlzLnBpbmcocnR0ID0+IHtcbiAgICAgICAgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJjb25uZWN0ZWQgdG8gcHJpbWFyeSBhZnRlclwiLCBydHQpXG4gICAgICAgIHRoaXMucHJpbWFyeVBhc3NlZEhlYWx0aENoZWNrID0gdHJ1ZVxuICAgICAgICBjbGVhclRpbWVvdXQodGhpcy5mYWxsYmFja1RpbWVyKVxuICAgICAgfSlcbiAgICB9KVxuICAgIHRoaXMudHJhbnNwb3J0Q29ubmVjdCgpXG4gIH1cblxuICBjbGVhckhlYXJ0YmVhdHMoKXtcbiAgICBjbGVhclRpbWVvdXQodGhpcy5oZWFydGJlYXRUaW1lcilcbiAgICBjbGVhclRpbWVvdXQodGhpcy5oZWFydGJlYXRUaW1lb3V0VGltZXIpXG4gIH1cblxuICBvbkNvbm5PcGVuKCl7XG4gICAgaWYodGhpcy5oYXNMb2dnZXIoKSkgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgYCR7dGhpcy50cmFuc3BvcnQubmFtZX0gY29ubmVjdGVkIHRvICR7dGhpcy5lbmRQb2ludFVSTCgpfWApXG4gICAgdGhpcy5jbG9zZVdhc0NsZWFuID0gZmFsc2VcbiAgICB0aGlzLmRpc2Nvbm5lY3RpbmcgPSBmYWxzZVxuICAgIHRoaXMuZXN0YWJsaXNoZWRDb25uZWN0aW9ucysrXG4gICAgdGhpcy5mbHVzaFNlbmRCdWZmZXIoKVxuICAgIHRoaXMucmVjb25uZWN0VGltZXIucmVzZXQoKVxuICAgIHRoaXMucmVzZXRIZWFydGJlYXQoKVxuICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3Mub3Blbi5mb3JFYWNoKChbLCBjYWxsYmFja10pID0+IGNhbGxiYWNrKCkpXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG5cbiAgaGVhcnRiZWF0VGltZW91dCgpe1xuICAgIGlmKHRoaXMucGVuZGluZ0hlYXJ0YmVhdFJlZil7XG4gICAgICB0aGlzLnBlbmRpbmdIZWFydGJlYXRSZWYgPSBudWxsXG4gICAgICBpZih0aGlzLmhhc0xvZ2dlcigpKXsgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJoZWFydGJlYXQgdGltZW91dC4gQXR0ZW1wdGluZyB0byByZS1lc3RhYmxpc2ggY29ubmVjdGlvblwiKSB9XG4gICAgICB0aGlzLnRyaWdnZXJDaGFuRXJyb3IoKVxuICAgICAgdGhpcy5jbG9zZVdhc0NsZWFuID0gZmFsc2VcbiAgICAgIHRoaXMudGVhcmRvd24oKCkgPT4gdGhpcy5yZWNvbm5lY3RUaW1lci5zY2hlZHVsZVRpbWVvdXQoKSwgV1NfQ0xPU0VfTk9STUFMLCBcImhlYXJ0YmVhdCB0aW1lb3V0XCIpXG4gICAgfVxuICB9XG5cbiAgcmVzZXRIZWFydGJlYXQoKXtcbiAgICBpZih0aGlzLmNvbm4gJiYgdGhpcy5jb25uLnNraXBIZWFydGJlYXQpeyByZXR1cm4gfVxuICAgIHRoaXMucGVuZGluZ0hlYXJ0YmVhdFJlZiA9IG51bGxcbiAgICB0aGlzLmNsZWFySGVhcnRiZWF0cygpXG4gICAgdGhpcy5oZWFydGJlYXRUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gdGhpcy5zZW5kSGVhcnRiZWF0KCksIHRoaXMuaGVhcnRiZWF0SW50ZXJ2YWxNcylcbiAgfVxuXG4gIHRlYXJkb3duKGNhbGxiYWNrLCBjb2RlLCByZWFzb24pe1xuICAgIGlmKCF0aGlzLmNvbm4pe1xuICAgICAgcmV0dXJuIGNhbGxiYWNrICYmIGNhbGxiYWNrKClcbiAgICB9XG4gICAgbGV0IGNvbm5lY3RDbG9jayA9IHRoaXMuY29ubmVjdENsb2NrXG5cbiAgICB0aGlzLndhaXRGb3JCdWZmZXJEb25lKCgpID0+IHtcbiAgICAgIGlmKGNvbm5lY3RDbG9jayAhPT0gdGhpcy5jb25uZWN0Q2xvY2speyByZXR1cm4gfVxuICAgICAgaWYodGhpcy5jb25uKXtcbiAgICAgICAgaWYoY29kZSl7IHRoaXMuY29ubi5jbG9zZShjb2RlLCByZWFzb24gfHwgXCJcIikgfSBlbHNlIHsgdGhpcy5jb25uLmNsb3NlKCkgfVxuICAgICAgfVxuXG4gICAgICB0aGlzLndhaXRGb3JTb2NrZXRDbG9zZWQoKCkgPT4ge1xuICAgICAgICBpZihjb25uZWN0Q2xvY2sgIT09IHRoaXMuY29ubmVjdENsb2NrKXsgcmV0dXJuIH1cbiAgICAgICAgaWYodGhpcy5jb25uKXtcbiAgICAgICAgICB0aGlzLmNvbm4ub25vcGVuID0gZnVuY3Rpb24gKCl7IH0gLy8gbm9vcFxuICAgICAgICAgIHRoaXMuY29ubi5vbmVycm9yID0gZnVuY3Rpb24gKCl7IH0gLy8gbm9vcFxuICAgICAgICAgIHRoaXMuY29ubi5vbm1lc3NhZ2UgPSBmdW5jdGlvbiAoKXsgfSAvLyBub29wXG4gICAgICAgICAgdGhpcy5jb25uLm9uY2xvc2UgPSBmdW5jdGlvbiAoKXsgfSAvLyBub29wXG4gICAgICAgICAgdGhpcy5jb25uID0gbnVsbFxuICAgICAgICB9XG5cbiAgICAgICAgY2FsbGJhY2sgJiYgY2FsbGJhY2soKVxuICAgICAgfSlcbiAgICB9KVxuICB9XG5cbiAgd2FpdEZvckJ1ZmZlckRvbmUoY2FsbGJhY2ssIHRyaWVzID0gMSl7XG4gICAgaWYodHJpZXMgPT09IDUgfHwgIXRoaXMuY29ubiB8fCAhdGhpcy5jb25uLmJ1ZmZlcmVkQW1vdW50KXtcbiAgICAgIGNhbGxiYWNrKClcbiAgICAgIHJldHVyblxuICAgIH1cblxuICAgIHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgdGhpcy53YWl0Rm9yQnVmZmVyRG9uZShjYWxsYmFjaywgdHJpZXMgKyAxKVxuICAgIH0sIDE1MCAqIHRyaWVzKVxuICB9XG5cbiAgd2FpdEZvclNvY2tldENsb3NlZChjYWxsYmFjaywgdHJpZXMgPSAxKXtcbiAgICBpZih0cmllcyA9PT0gNSB8fCAhdGhpcy5jb25uIHx8IHRoaXMuY29ubi5yZWFkeVN0YXRlID09PSBTT0NLRVRfU1RBVEVTLmNsb3NlZCl7XG4gICAgICBjYWxsYmFjaygpXG4gICAgICByZXR1cm5cbiAgICB9XG5cbiAgICBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgIHRoaXMud2FpdEZvclNvY2tldENsb3NlZChjYWxsYmFjaywgdHJpZXMgKyAxKVxuICAgIH0sIDE1MCAqIHRyaWVzKVxuICB9XG5cbiAgb25Db25uQ2xvc2UoZXZlbnQpe1xuICAgIGxldCBjbG9zZUNvZGUgPSBldmVudCAmJiBldmVudC5jb2RlXG4gICAgaWYodGhpcy5oYXNMb2dnZXIoKSkgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJjbG9zZVwiLCBldmVudClcbiAgICB0aGlzLnRyaWdnZXJDaGFuRXJyb3IoKVxuICAgIHRoaXMuY2xlYXJIZWFydGJlYXRzKClcbiAgICBpZighdGhpcy5jbG9zZVdhc0NsZWFuICYmIGNsb3NlQ29kZSAhPT0gMTAwMCl7XG4gICAgICB0aGlzLnJlY29ubmVjdFRpbWVyLnNjaGVkdWxlVGltZW91dCgpXG4gICAgfVxuICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3MuY2xvc2UuZm9yRWFjaCgoWywgY2FsbGJhY2tdKSA9PiBjYWxsYmFjayhldmVudCkpXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIG9uQ29ubkVycm9yKGVycm9yKXtcbiAgICBpZih0aGlzLmhhc0xvZ2dlcigpKSB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBlcnJvcilcbiAgICBsZXQgdHJhbnNwb3J0QmVmb3JlID0gdGhpcy50cmFuc3BvcnRcbiAgICBsZXQgZXN0YWJsaXNoZWRCZWZvcmUgPSB0aGlzLmVzdGFibGlzaGVkQ29ubmVjdGlvbnNcbiAgICB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzLmVycm9yLmZvckVhY2goKFssIGNhbGxiYWNrXSkgPT4ge1xuICAgICAgY2FsbGJhY2soZXJyb3IsIHRyYW5zcG9ydEJlZm9yZSwgZXN0YWJsaXNoZWRCZWZvcmUpXG4gICAgfSlcbiAgICBpZih0cmFuc3BvcnRCZWZvcmUgPT09IHRoaXMudHJhbnNwb3J0IHx8IGVzdGFibGlzaGVkQmVmb3JlID4gMCl7XG4gICAgICB0aGlzLnRyaWdnZXJDaGFuRXJyb3IoKVxuICAgIH1cbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgdHJpZ2dlckNoYW5FcnJvcigpe1xuICAgIHRoaXMuY2hhbm5lbHMuZm9yRWFjaChjaGFubmVsID0+IHtcbiAgICAgIGlmKCEoY2hhbm5lbC5pc0Vycm9yZWQoKSB8fCBjaGFubmVsLmlzTGVhdmluZygpIHx8IGNoYW5uZWwuaXNDbG9zZWQoKSkpe1xuICAgICAgICBjaGFubmVsLnRyaWdnZXIoQ0hBTk5FTF9FVkVOVFMuZXJyb3IpXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIC8qKlxuICAgKiBAcmV0dXJucyB7c3RyaW5nfVxuICAgKi9cbiAgY29ubmVjdGlvblN0YXRlKCl7XG4gICAgc3dpdGNoKHRoaXMuY29ubiAmJiB0aGlzLmNvbm4ucmVhZHlTdGF0ZSl7XG4gICAgICBjYXNlIFNPQ0tFVF9TVEFURVMuY29ubmVjdGluZzogcmV0dXJuIFwiY29ubmVjdGluZ1wiXG4gICAgICBjYXNlIFNPQ0tFVF9TVEFURVMub3BlbjogcmV0dXJuIFwib3BlblwiXG4gICAgICBjYXNlIFNPQ0tFVF9TVEFURVMuY2xvc2luZzogcmV0dXJuIFwiY2xvc2luZ1wiXG4gICAgICBkZWZhdWx0OiByZXR1cm4gXCJjbG9zZWRcIlxuICAgIH1cbiAgfVxuXG4gIC8qKlxuICAgKiBAcmV0dXJucyB7Ym9vbGVhbn1cbiAgICovXG4gIGlzQ29ubmVjdGVkKCl7IHJldHVybiB0aGlzLmNvbm5lY3Rpb25TdGF0ZSgpID09PSBcIm9wZW5cIiB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqXG4gICAqIEBwYXJhbSB7Q2hhbm5lbH1cbiAgICovXG4gIHJlbW92ZShjaGFubmVsKXtcbiAgICB0aGlzLm9mZihjaGFubmVsLnN0YXRlQ2hhbmdlUmVmcylcbiAgICB0aGlzLmNoYW5uZWxzID0gdGhpcy5jaGFubmVscy5maWx0ZXIoYyA9PiBjICE9PSBjaGFubmVsKVxuICB9XG5cbiAgLyoqXG4gICAqIFJlbW92ZXMgYG9uT3BlbmAsIGBvbkNsb3NlYCwgYG9uRXJyb3IsYCBhbmQgYG9uTWVzc2FnZWAgcmVnaXN0cmF0aW9ucy5cbiAgICpcbiAgICogQHBhcmFtIHtyZWZzfSAtIGxpc3Qgb2YgcmVmcyByZXR1cm5lZCBieSBjYWxscyB0b1xuICAgKiAgICAgICAgICAgICAgICAgYG9uT3BlbmAsIGBvbkNsb3NlYCwgYG9uRXJyb3IsYCBhbmQgYG9uTWVzc2FnZWBcbiAgICovXG4gIG9mZihyZWZzKXtcbiAgICBmb3IobGV0IGtleSBpbiB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzKXtcbiAgICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3Nba2V5XSA9IHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3Nba2V5XS5maWx0ZXIoKFtyZWZdKSA9PiB7XG4gICAgICAgIHJldHVybiByZWZzLmluZGV4T2YocmVmKSA9PT0gLTFcbiAgICAgIH0pXG4gICAgfVxuICB9XG5cbiAgLyoqXG4gICAqIEluaXRpYXRlcyBhIG5ldyBjaGFubmVsIGZvciB0aGUgZ2l2ZW4gdG9waWNcbiAgICpcbiAgICogQHBhcmFtIHtzdHJpbmd9IHRvcGljXG4gICAqIEBwYXJhbSB7T2JqZWN0fSBjaGFuUGFyYW1zIC0gUGFyYW1ldGVycyBmb3IgdGhlIGNoYW5uZWxcbiAgICogQHJldHVybnMge0NoYW5uZWx9XG4gICAqL1xuICBjaGFubmVsKHRvcGljLCBjaGFuUGFyYW1zID0ge30pe1xuICAgIGxldCBjaGFuID0gbmV3IENoYW5uZWwodG9waWMsIGNoYW5QYXJhbXMsIHRoaXMpXG4gICAgdGhpcy5jaGFubmVscy5wdXNoKGNoYW4pXG4gICAgcmV0dXJuIGNoYW5cbiAgfVxuXG4gIC8qKlxuICAgKiBAcGFyYW0ge09iamVjdH0gZGF0YVxuICAgKi9cbiAgcHVzaChkYXRhKXtcbiAgICBpZih0aGlzLmhhc0xvZ2dlcigpKXtcbiAgICAgIGxldCB7dG9waWMsIGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5fcmVmfSA9IGRhdGFcbiAgICAgIHRoaXMubG9nKFwicHVzaFwiLCBgJHt0b3BpY30gJHtldmVudH0gKCR7am9pbl9yZWZ9LCAke3JlZn0pYCwgcGF5bG9hZClcbiAgICB9XG5cbiAgICBpZih0aGlzLmlzQ29ubmVjdGVkKCkpe1xuICAgICAgdGhpcy5lbmNvZGUoZGF0YSwgcmVzdWx0ID0+IHRoaXMuY29ubi5zZW5kKHJlc3VsdCkpXG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMuc2VuZEJ1ZmZlci5wdXNoKCgpID0+IHRoaXMuZW5jb2RlKGRhdGEsIHJlc3VsdCA9PiB0aGlzLmNvbm4uc2VuZChyZXN1bHQpKSlcbiAgICB9XG4gIH1cblxuICAvKipcbiAgICogUmV0dXJuIHRoZSBuZXh0IG1lc3NhZ2UgcmVmLCBhY2NvdW50aW5nIGZvciBvdmVyZmxvd3NcbiAgICogQHJldHVybnMge3N0cmluZ31cbiAgICovXG4gIG1ha2VSZWYoKXtcbiAgICBsZXQgbmV3UmVmID0gdGhpcy5yZWYgKyAxXG4gICAgaWYobmV3UmVmID09PSB0aGlzLnJlZil7IHRoaXMucmVmID0gMCB9IGVsc2UgeyB0aGlzLnJlZiA9IG5ld1JlZiB9XG5cbiAgICByZXR1cm4gdGhpcy5yZWYudG9TdHJpbmcoKVxuICB9XG5cbiAgc2VuZEhlYXJ0YmVhdCgpe1xuICAgIGlmKHRoaXMucGVuZGluZ0hlYXJ0YmVhdFJlZiAmJiAhdGhpcy5pc0Nvbm5lY3RlZCgpKXsgcmV0dXJuIH1cbiAgICB0aGlzLnBlbmRpbmdIZWFydGJlYXRSZWYgPSB0aGlzLm1ha2VSZWYoKVxuICAgIHRoaXMucHVzaCh7dG9waWM6IFwicGhvZW5peFwiLCBldmVudDogXCJoZWFydGJlYXRcIiwgcGF5bG9hZDoge30sIHJlZjogdGhpcy5wZW5kaW5nSGVhcnRiZWF0UmVmfSlcbiAgICB0aGlzLmhlYXJ0YmVhdFRpbWVvdXRUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gdGhpcy5oZWFydGJlYXRUaW1lb3V0KCksIHRoaXMuaGVhcnRiZWF0SW50ZXJ2YWxNcylcbiAgfVxuXG4gIGZsdXNoU2VuZEJ1ZmZlcigpe1xuICAgIGlmKHRoaXMuaXNDb25uZWN0ZWQoKSAmJiB0aGlzLnNlbmRCdWZmZXIubGVuZ3RoID4gMCl7XG4gICAgICB0aGlzLnNlbmRCdWZmZXIuZm9yRWFjaChjYWxsYmFjayA9PiBjYWxsYmFjaygpKVxuICAgICAgdGhpcy5zZW5kQnVmZmVyID0gW11cbiAgICB9XG4gIH1cblxuICBvbkNvbm5NZXNzYWdlKHJhd01lc3NhZ2Upe1xuICAgIHRoaXMuZGVjb2RlKHJhd01lc3NhZ2UuZGF0YSwgbXNnID0+IHtcbiAgICAgIGxldCB7dG9waWMsIGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5fcmVmfSA9IG1zZ1xuICAgICAgaWYocmVmICYmIHJlZiA9PT0gdGhpcy5wZW5kaW5nSGVhcnRiZWF0UmVmKXtcbiAgICAgICAgdGhpcy5jbGVhckhlYXJ0YmVhdHMoKVxuICAgICAgICB0aGlzLnBlbmRpbmdIZWFydGJlYXRSZWYgPSBudWxsXG4gICAgICAgIHRoaXMuaGVhcnRiZWF0VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHRoaXMuc2VuZEhlYXJ0YmVhdCgpLCB0aGlzLmhlYXJ0YmVhdEludGVydmFsTXMpXG4gICAgICB9XG5cbiAgICAgIGlmKHRoaXMuaGFzTG9nZ2VyKCkpIHRoaXMubG9nKFwicmVjZWl2ZVwiLCBgJHtwYXlsb2FkLnN0YXR1cyB8fCBcIlwifSAke3RvcGljfSAke2V2ZW50fSAke3JlZiAmJiBcIihcIiArIHJlZiArIFwiKVwiIHx8IFwiXCJ9YCwgcGF5bG9hZClcblxuICAgICAgZm9yKGxldCBpID0gMDsgaSA8IHRoaXMuY2hhbm5lbHMubGVuZ3RoOyBpKyspe1xuICAgICAgICBjb25zdCBjaGFubmVsID0gdGhpcy5jaGFubmVsc1tpXVxuICAgICAgICBpZighY2hhbm5lbC5pc01lbWJlcih0b3BpYywgZXZlbnQsIHBheWxvYWQsIGpvaW5fcmVmKSl7IGNvbnRpbnVlIH1cbiAgICAgICAgY2hhbm5lbC50cmlnZ2VyKGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5fcmVmKVxuICAgICAgfVxuXG4gICAgICBmb3IobGV0IGkgPSAwOyBpIDwgdGhpcy5zdGF0ZUNoYW5nZUNhbGxiYWNrcy5tZXNzYWdlLmxlbmd0aDsgaSsrKXtcbiAgICAgICAgbGV0IFssIGNhbGxiYWNrXSA9IHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3MubWVzc2FnZVtpXVxuICAgICAgICBjYWxsYmFjayhtc2cpXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIGxlYXZlT3BlblRvcGljKHRvcGljKXtcbiAgICBsZXQgZHVwQ2hhbm5lbCA9IHRoaXMuY2hhbm5lbHMuZmluZChjID0+IGMudG9waWMgPT09IHRvcGljICYmIChjLmlzSm9pbmVkKCkgfHwgYy5pc0pvaW5pbmcoKSkpXG4gICAgaWYoZHVwQ2hhbm5lbCl7XG4gICAgICBpZih0aGlzLmhhc0xvZ2dlcigpKSB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBgbGVhdmluZyBkdXBsaWNhdGUgdG9waWMgXCIke3RvcGljfVwiYClcbiAgICAgIGR1cENoYW5uZWwubGVhdmUoKVxuICAgIH1cbiAgfVxufVxuIiwgImV4cG9ydCBjb25zdCBDT05TRUNVVElWRV9SRUxPQURTID0gXCJjb25zZWN1dGl2ZS1yZWxvYWRzXCI7XG5leHBvcnQgY29uc3QgTUFYX1JFTE9BRFMgPSAxMDtcbmV4cG9ydCBjb25zdCBSRUxPQURfSklUVEVSX01JTiA9IDUwMDA7XG5leHBvcnQgY29uc3QgUkVMT0FEX0pJVFRFUl9NQVggPSAxMDAwMDtcbmV4cG9ydCBjb25zdCBGQUlMU0FGRV9KSVRURVIgPSAzMDAwMDtcbmV4cG9ydCBjb25zdCBQSFhfRVZFTlRfQ0xBU1NFUyA9IFtcbiAgXCJwaHgtY2xpY2stbG9hZGluZ1wiLFxuICBcInBoeC1jaGFuZ2UtbG9hZGluZ1wiLFxuICBcInBoeC1zdWJtaXQtbG9hZGluZ1wiLFxuICBcInBoeC1rZXlkb3duLWxvYWRpbmdcIixcbiAgXCJwaHgta2V5dXAtbG9hZGluZ1wiLFxuICBcInBoeC1ibHVyLWxvYWRpbmdcIixcbiAgXCJwaHgtZm9jdXMtbG9hZGluZ1wiLFxuICBcInBoeC1ob29rLWxvYWRpbmdcIixcbl07XG5leHBvcnQgY29uc3QgUEhYX0NPTVBPTkVOVCA9IFwiZGF0YS1waHgtY29tcG9uZW50XCI7XG5leHBvcnQgY29uc3QgUEhYX1ZJRVdfUkVGID0gXCJkYXRhLXBoeC12aWV3XCI7XG5leHBvcnQgY29uc3QgUEhYX0xJVkVfTElOSyA9IFwiZGF0YS1waHgtbGlua1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9UUkFDS19TVEFUSUMgPSBcInRyYWNrLXN0YXRpY1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9MSU5LX1NUQVRFID0gXCJkYXRhLXBoeC1saW5rLXN0YXRlXCI7XG5leHBvcnQgY29uc3QgUEhYX1JFRl9MT0FESU5HID0gXCJkYXRhLXBoeC1yZWYtbG9hZGluZ1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9SRUZfU1JDID0gXCJkYXRhLXBoeC1yZWYtc3JjXCI7XG5leHBvcnQgY29uc3QgUEhYX1JFRl9MT0NLID0gXCJkYXRhLXBoeC1yZWYtbG9ja1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9QRU5ESU5HX1JFRlMgPSBcInBoeC1wZW5kaW5nLXJlZnNcIjtcbmV4cG9ydCBjb25zdCBQSFhfVFJBQ0tfVVBMT0FEUyA9IFwidHJhY2stdXBsb2Fkc1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9VUExPQURfUkVGID0gXCJkYXRhLXBoeC11cGxvYWQtcmVmXCI7XG5leHBvcnQgY29uc3QgUEhYX1BSRUZMSUdIVEVEX1JFRlMgPSBcImRhdGEtcGh4LXByZWZsaWdodGVkLXJlZnNcIjtcbmV4cG9ydCBjb25zdCBQSFhfRE9ORV9SRUZTID0gXCJkYXRhLXBoeC1kb25lLXJlZnNcIjtcbmV4cG9ydCBjb25zdCBQSFhfRFJPUF9UQVJHRVQgPSBcImRyb3AtdGFyZ2V0XCI7XG5leHBvcnQgY29uc3QgUEhYX0FDVElWRV9FTlRSWV9SRUZTID0gXCJkYXRhLXBoeC1hY3RpdmUtcmVmc1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9MSVZFX0ZJTEVfVVBEQVRFRCA9IFwicGh4OmxpdmUtZmlsZTp1cGRhdGVkXCI7XG5leHBvcnQgY29uc3QgUEhYX1NLSVAgPSBcImRhdGEtcGh4LXNraXBcIjtcbmV4cG9ydCBjb25zdCBQSFhfTUFHSUNfSUQgPSBcImRhdGEtcGh4LWlkXCI7XG5leHBvcnQgY29uc3QgUEhYX1BSVU5FID0gXCJkYXRhLXBoeC1wcnVuZVwiO1xuZXhwb3J0IGNvbnN0IFBIWF9DT05ORUNURURfQ0xBU1MgPSBcInBoeC1jb25uZWN0ZWRcIjtcbmV4cG9ydCBjb25zdCBQSFhfTE9BRElOR19DTEFTUyA9IFwicGh4LWxvYWRpbmdcIjtcbmV4cG9ydCBjb25zdCBQSFhfRVJST1JfQ0xBU1MgPSBcInBoeC1lcnJvclwiO1xuZXhwb3J0IGNvbnN0IFBIWF9DTElFTlRfRVJST1JfQ0xBU1MgPSBcInBoeC1jbGllbnQtZXJyb3JcIjtcbmV4cG9ydCBjb25zdCBQSFhfU0VSVkVSX0VSUk9SX0NMQVNTID0gXCJwaHgtc2VydmVyLWVycm9yXCI7XG5leHBvcnQgY29uc3QgUEhYX1BBUkVOVF9JRCA9IFwiZGF0YS1waHgtcGFyZW50LWlkXCI7XG5leHBvcnQgY29uc3QgUEhYX01BSU4gPSBcImRhdGEtcGh4LW1haW5cIjtcbmV4cG9ydCBjb25zdCBQSFhfUk9PVF9JRCA9IFwiZGF0YS1waHgtcm9vdC1pZFwiO1xuZXhwb3J0IGNvbnN0IFBIWF9WSUVXUE9SVF9UT1AgPSBcInZpZXdwb3J0LXRvcFwiO1xuZXhwb3J0IGNvbnN0IFBIWF9WSUVXUE9SVF9CT1RUT00gPSBcInZpZXdwb3J0LWJvdHRvbVwiO1xuZXhwb3J0IGNvbnN0IFBIWF9UUklHR0VSX0FDVElPTiA9IFwidHJpZ2dlci1hY3Rpb25cIjtcbmV4cG9ydCBjb25zdCBQSFhfSEFTX0ZPQ1VTRUQgPSBcInBoeC1oYXMtZm9jdXNlZFwiO1xuZXhwb3J0IGNvbnN0IEZPQ1VTQUJMRV9JTlBVVFMgPSBbXG4gIFwidGV4dFwiLFxuICBcInRleHRhcmVhXCIsXG4gIFwibnVtYmVyXCIsXG4gIFwiZW1haWxcIixcbiAgXCJwYXNzd29yZFwiLFxuICBcInNlYXJjaFwiLFxuICBcInRlbFwiLFxuICBcInVybFwiLFxuICBcImRhdGVcIixcbiAgXCJ0aW1lXCIsXG4gIFwiZGF0ZXRpbWUtbG9jYWxcIixcbiAgXCJjb2xvclwiLFxuICBcInJhbmdlXCIsXG5dO1xuZXhwb3J0IGNvbnN0IENIRUNLQUJMRV9JTlBVVFMgPSBbXCJjaGVja2JveFwiLCBcInJhZGlvXCJdO1xuZXhwb3J0IGNvbnN0IFBIWF9IQVNfU1VCTUlUVEVEID0gXCJwaHgtaGFzLXN1Ym1pdHRlZFwiO1xuZXhwb3J0IGNvbnN0IFBIWF9TRVNTSU9OID0gXCJkYXRhLXBoeC1zZXNzaW9uXCI7XG5leHBvcnQgY29uc3QgUEhYX1ZJRVdfU0VMRUNUT1IgPSBgWyR7UEhYX1NFU1NJT059XWA7XG5leHBvcnQgY29uc3QgUEhYX1NUSUNLWSA9IFwiZGF0YS1waHgtc3RpY2t5XCI7XG5leHBvcnQgY29uc3QgUEhYX1NUQVRJQyA9IFwiZGF0YS1waHgtc3RhdGljXCI7XG5leHBvcnQgY29uc3QgUEhYX1JFQURPTkxZID0gXCJkYXRhLXBoeC1yZWFkb25seVwiO1xuZXhwb3J0IGNvbnN0IFBIWF9ESVNBQkxFRCA9IFwiZGF0YS1waHgtZGlzYWJsZWRcIjtcbmV4cG9ydCBjb25zdCBQSFhfRElTQUJMRV9XSVRIID0gXCJkaXNhYmxlLXdpdGhcIjtcbmV4cG9ydCBjb25zdCBQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUgPSBcImRhdGEtcGh4LWRpc2FibGUtd2l0aC1yZXN0b3JlXCI7XG5leHBvcnQgY29uc3QgUEhYX0hPT0sgPSBcImhvb2tcIjtcbmV4cG9ydCBjb25zdCBQSFhfREVCT1VOQ0UgPSBcImRlYm91bmNlXCI7XG5leHBvcnQgY29uc3QgUEhYX1RIUk9UVExFID0gXCJ0aHJvdHRsZVwiO1xuZXhwb3J0IGNvbnN0IFBIWF9VUERBVEUgPSBcInVwZGF0ZVwiO1xuZXhwb3J0IGNvbnN0IFBIWF9TVFJFQU0gPSBcInN0cmVhbVwiO1xuZXhwb3J0IGNvbnN0IFBIWF9TVFJFQU1fUkVGID0gXCJkYXRhLXBoeC1zdHJlYW1cIjtcbmV4cG9ydCBjb25zdCBQSFhfUE9SVEFMID0gXCJkYXRhLXBoeC1wb3J0YWxcIjtcbmV4cG9ydCBjb25zdCBQSFhfVEVMRVBPUlRFRF9SRUYgPSBcImRhdGEtcGh4LXRlbGVwb3J0ZWRcIjtcbmV4cG9ydCBjb25zdCBQSFhfVEVMRVBPUlRFRF9TUkMgPSBcImRhdGEtcGh4LXRlbGVwb3J0ZWQtc3JjXCI7XG5leHBvcnQgY29uc3QgUEhYX1JVTlRJTUVfSE9PSyA9IFwiZGF0YS1waHgtcnVudGltZS1ob29rXCI7XG5leHBvcnQgY29uc3QgUEhYX0xWX1BJRCA9IFwiZGF0YS1waHgtcGlkXCI7XG5leHBvcnQgY29uc3QgUEhYX0tFWSA9IFwia2V5XCI7XG5leHBvcnQgY29uc3QgUEhYX1BSSVZBVEUgPSBcInBoeFByaXZhdGVcIjtcbmV4cG9ydCBjb25zdCBQSFhfQVVUT19SRUNPVkVSID0gXCJhdXRvLXJlY292ZXJcIjtcbmV4cG9ydCBjb25zdCBQSFhfTFZfREVCVUcgPSBcInBoeDpsaXZlLXNvY2tldDpkZWJ1Z1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9MVl9QUk9GSUxFID0gXCJwaHg6bGl2ZS1zb2NrZXQ6cHJvZmlsaW5nXCI7XG5leHBvcnQgY29uc3QgUEhYX0xWX0xBVEVOQ1lfU0lNID0gXCJwaHg6bGl2ZS1zb2NrZXQ6bGF0ZW5jeS1zaW1cIjtcbmV4cG9ydCBjb25zdCBQSFhfTFZfSElTVE9SWV9QT1NJVElPTiA9IFwicGh4Om5hdi1oaXN0b3J5LXBvc2l0aW9uXCI7XG5leHBvcnQgY29uc3QgUEhYX1BST0dSRVNTID0gXCJwcm9ncmVzc1wiO1xuZXhwb3J0IGNvbnN0IFBIWF9NT1VOVEVEID0gXCJtb3VudGVkXCI7XG5leHBvcnQgY29uc3QgUEhYX1JFTE9BRF9TVEFUVVMgPSBcIl9fcGhvZW5peF9yZWxvYWRfc3RhdHVzX19cIjtcbmV4cG9ydCBjb25zdCBMT0FERVJfVElNRU9VVCA9IDE7XG5leHBvcnQgY29uc3QgTUFYX0NISUxEX0pPSU5fQVRURU1QVFMgPSAzO1xuZXhwb3J0IGNvbnN0IEJFRk9SRV9VTkxPQURfTE9BREVSX1RJTUVPVVQgPSAyMDA7XG5leHBvcnQgY29uc3QgRElTQ09OTkVDVEVEX1RJTUVPVVQgPSA1MDA7XG5leHBvcnQgY29uc3QgQklORElOR19QUkVGSVggPSBcInBoeC1cIjtcbmV4cG9ydCBjb25zdCBQVVNIX1RJTUVPVVQgPSAzMDAwMDtcbmV4cG9ydCBjb25zdCBMSU5LX0hFQURFUiA9IFwieC1yZXF1ZXN0ZWQtd2l0aFwiO1xuZXhwb3J0IGNvbnN0IFJFU1BPTlNFX1VSTF9IRUFERVIgPSBcIngtcmVzcG9uc2UtdXJsXCI7XG5leHBvcnQgY29uc3QgREVCT1VOQ0VfVFJJR0dFUiA9IFwiZGVib3VuY2UtdHJpZ2dlclwiO1xuZXhwb3J0IGNvbnN0IFRIUk9UVExFRCA9IFwidGhyb3R0bGVkXCI7XG5leHBvcnQgY29uc3QgREVCT1VOQ0VfUFJFVl9LRVkgPSBcImRlYm91bmNlLXByZXYta2V5XCI7XG5leHBvcnQgY29uc3QgREVGQVVMVFMgPSB7XG4gIGRlYm91bmNlOiAzMDAsXG4gIHRocm90dGxlOiAzMDAsXG59O1xuZXhwb3J0IGNvbnN0IFBIWF9QRU5ESU5HX0FUVFJTID0gW1BIWF9SRUZfTE9BRElORywgUEhYX1JFRl9TUkMsIFBIWF9SRUZfTE9DS107XG4vLyBSZW5kZXJlZFxuZXhwb3J0IGNvbnN0IFNUQVRJQyA9IFwic1wiO1xuZXhwb3J0IGNvbnN0IFJPT1QgPSBcInJcIjtcbmV4cG9ydCBjb25zdCBDT01QT05FTlRTID0gXCJjXCI7XG5leHBvcnQgY29uc3QgS0VZRUQgPSBcImtcIjtcbmV4cG9ydCBjb25zdCBLRVlFRF9DT1VOVCA9IFwia2NcIjtcbmV4cG9ydCBjb25zdCBFVkVOVFMgPSBcImVcIjtcbmV4cG9ydCBjb25zdCBSRVBMWSA9IFwiclwiO1xuZXhwb3J0IGNvbnN0IFRJVExFID0gXCJ0XCI7XG5leHBvcnQgY29uc3QgVEVNUExBVEVTID0gXCJwXCI7XG5leHBvcnQgY29uc3QgU1RSRUFNID0gXCJzdHJlYW1cIjtcbiIsICJpbXBvcnQgeyBsb2dFcnJvciB9IGZyb20gXCIuL3V0aWxzXCI7XG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIEVudHJ5VXBsb2FkZXIge1xuICBjb25zdHJ1Y3RvcihlbnRyeSwgY29uZmlnLCBsaXZlU29ja2V0KSB7XG4gICAgY29uc3QgeyBjaHVua19zaXplLCBjaHVua190aW1lb3V0IH0gPSBjb25maWc7XG4gICAgdGhpcy5saXZlU29ja2V0ID0gbGl2ZVNvY2tldDtcbiAgICB0aGlzLmVudHJ5ID0gZW50cnk7XG4gICAgdGhpcy5vZmZzZXQgPSAwO1xuICAgIHRoaXMuY2h1bmtTaXplID0gY2h1bmtfc2l6ZTtcbiAgICB0aGlzLmNodW5rVGltZW91dCA9IGNodW5rX3RpbWVvdXQ7XG4gICAgdGhpcy5jaHVua1RpbWVyID0gbnVsbDtcbiAgICB0aGlzLmVycm9yZWQgPSBmYWxzZTtcbiAgICB0aGlzLnVwbG9hZENoYW5uZWwgPSBsaXZlU29ja2V0LmNoYW5uZWwoYGx2dToke2VudHJ5LnJlZn1gLCB7XG4gICAgICB0b2tlbjogZW50cnkubWV0YWRhdGEoKSxcbiAgICB9KTtcbiAgfVxuXG4gIGVycm9yKHJlYXNvbikge1xuICAgIGlmICh0aGlzLmVycm9yZWQpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgdGhpcy51cGxvYWRDaGFubmVsLmxlYXZlKCk7XG4gICAgdGhpcy5lcnJvcmVkID0gdHJ1ZTtcbiAgICBjbGVhclRpbWVvdXQodGhpcy5jaHVua1RpbWVyKTtcbiAgICB0aGlzLmVudHJ5LmVycm9yKHJlYXNvbik7XG4gIH1cblxuICB1cGxvYWQoKSB7XG4gICAgdGhpcy51cGxvYWRDaGFubmVsLm9uRXJyb3IoKHJlYXNvbikgPT4gdGhpcy5lcnJvcihyZWFzb24pKTtcbiAgICB0aGlzLnVwbG9hZENoYW5uZWxcbiAgICAgIC5qb2luKClcbiAgICAgIC5yZWNlaXZlKFwib2tcIiwgKF9kYXRhKSA9PiB0aGlzLnJlYWROZXh0Q2h1bmsoKSlcbiAgICAgIC5yZWNlaXZlKFwiZXJyb3JcIiwgKHJlYXNvbikgPT4gdGhpcy5lcnJvcihyZWFzb24pKTtcbiAgfVxuXG4gIGlzRG9uZSgpIHtcbiAgICByZXR1cm4gdGhpcy5vZmZzZXQgPj0gdGhpcy5lbnRyeS5maWxlLnNpemU7XG4gIH1cblxuICByZWFkTmV4dENodW5rKCkge1xuICAgIGNvbnN0IHJlYWRlciA9IG5ldyB3aW5kb3cuRmlsZVJlYWRlcigpO1xuICAgIGNvbnN0IGJsb2IgPSB0aGlzLmVudHJ5LmZpbGUuc2xpY2UoXG4gICAgICB0aGlzLm9mZnNldCxcbiAgICAgIHRoaXMuY2h1bmtTaXplICsgdGhpcy5vZmZzZXQsXG4gICAgKTtcbiAgICByZWFkZXIub25sb2FkID0gKGUpID0+IHtcbiAgICAgIGlmIChlLnRhcmdldC5lcnJvciA9PT0gbnVsbCkge1xuICAgICAgICB0aGlzLm9mZnNldCArPSAvKiogQHR5cGUge0FycmF5QnVmZmVyfSAqLyAoZS50YXJnZXQucmVzdWx0KS5ieXRlTGVuZ3RoO1xuICAgICAgICB0aGlzLnB1c2hDaHVuaygvKiogQHR5cGUge0FycmF5QnVmZmVyfSAqLyAoZS50YXJnZXQucmVzdWx0KSk7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICByZXR1cm4gbG9nRXJyb3IoXCJSZWFkIGVycm9yOiBcIiArIGUudGFyZ2V0LmVycm9yKTtcbiAgICAgIH1cbiAgICB9O1xuICAgIHJlYWRlci5yZWFkQXNBcnJheUJ1ZmZlcihibG9iKTtcbiAgfVxuXG4gIHB1c2hDaHVuayhjaHVuaykge1xuICAgIGlmICghdGhpcy51cGxvYWRDaGFubmVsLmlzSm9pbmVkKCkpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgdGhpcy51cGxvYWRDaGFubmVsXG4gICAgICAucHVzaChcImNodW5rXCIsIGNodW5rLCB0aGlzLmNodW5rVGltZW91dClcbiAgICAgIC5yZWNlaXZlKFwib2tcIiwgKCkgPT4ge1xuICAgICAgICB0aGlzLmVudHJ5LnByb2dyZXNzKCh0aGlzLm9mZnNldCAvIHRoaXMuZW50cnkuZmlsZS5zaXplKSAqIDEwMCk7XG4gICAgICAgIGlmICghdGhpcy5pc0RvbmUoKSkge1xuICAgICAgICAgIHRoaXMuY2h1bmtUaW1lciA9IHNldFRpbWVvdXQoXG4gICAgICAgICAgICAoKSA9PiB0aGlzLnJlYWROZXh0Q2h1bmsoKSxcbiAgICAgICAgICAgIHRoaXMubGl2ZVNvY2tldC5nZXRMYXRlbmN5U2ltKCkgfHwgMCxcbiAgICAgICAgICApO1xuICAgICAgICB9XG4gICAgICB9KVxuICAgICAgLnJlY2VpdmUoXCJlcnJvclwiLCAoeyByZWFzb24gfSkgPT4gdGhpcy5lcnJvcihyZWFzb24pKTtcbiAgfVxufVxuIiwgImltcG9ydCB7IFBIWF9WSUVXX1NFTEVDVE9SIH0gZnJvbSBcIi4vY29uc3RhbnRzXCI7XG5cbmltcG9ydCBFbnRyeVVwbG9hZGVyIGZyb20gXCIuL2VudHJ5X3VwbG9hZGVyXCI7XG5cbmV4cG9ydCBjb25zdCBsb2dFcnJvciA9IChtc2csIG9iaikgPT4gY29uc29sZS5lcnJvciAmJiBjb25zb2xlLmVycm9yKG1zZywgb2JqKTtcblxuZXhwb3J0IGNvbnN0IGlzQ2lkID0gKGNpZCkgPT4ge1xuICBjb25zdCB0eXBlID0gdHlwZW9mIGNpZDtcbiAgcmV0dXJuIHR5cGUgPT09IFwibnVtYmVyXCIgfHwgKHR5cGUgPT09IFwic3RyaW5nXCIgJiYgL14oMHxbMS05XVxcZCopJC8udGVzdChjaWQpKTtcbn07XG5cbmV4cG9ydCBmdW5jdGlvbiBkZXRlY3REdXBsaWNhdGVJZHMoKSB7XG4gIGNvbnN0IGlkcyA9IG5ldyBTZXQoKTtcbiAgY29uc3QgZWxlbXMgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKFwiKltpZF1cIik7XG4gIGZvciAobGV0IGkgPSAwLCBsZW4gPSBlbGVtcy5sZW5ndGg7IGkgPCBsZW47IGkrKykge1xuICAgIGlmIChpZHMuaGFzKGVsZW1zW2ldLmlkKSkge1xuICAgICAgY29uc29sZS5lcnJvcihcbiAgICAgICAgYE11bHRpcGxlIElEcyBkZXRlY3RlZDogJHtlbGVtc1tpXS5pZH0uIEVuc3VyZSB1bmlxdWUgZWxlbWVudCBpZHMuYCxcbiAgICAgICk7XG4gICAgfSBlbHNlIHtcbiAgICAgIGlkcy5hZGQoZWxlbXNbaV0uaWQpO1xuICAgIH1cbiAgfVxufVxuXG5leHBvcnQgZnVuY3Rpb24gZGV0ZWN0SW52YWxpZFN0cmVhbUluc2VydHMoaW5zZXJ0cykge1xuICBjb25zdCBlcnJvcnMgPSBuZXcgU2V0KCk7XG4gIE9iamVjdC5rZXlzKGluc2VydHMpLmZvckVhY2goKGlkKSA9PiB7XG4gICAgY29uc3Qgc3RyZWFtRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7XG4gICAgaWYgKFxuICAgICAgc3RyZWFtRWwgJiZcbiAgICAgIHN0cmVhbUVsLnBhcmVudEVsZW1lbnQgJiZcbiAgICAgIHN0cmVhbUVsLnBhcmVudEVsZW1lbnQuZ2V0QXR0cmlidXRlKFwicGh4LXVwZGF0ZVwiKSAhPT0gXCJzdHJlYW1cIlxuICAgICkge1xuICAgICAgZXJyb3JzLmFkZChcbiAgICAgICAgYFRoZSBzdHJlYW0gY29udGFpbmVyIHdpdGggaWQgXCIke3N0cmVhbUVsLnBhcmVudEVsZW1lbnQuaWR9XCIgaXMgbWlzc2luZyB0aGUgcGh4LXVwZGF0ZT1cInN0cmVhbVwiIGF0dHJpYnV0ZS4gRW5zdXJlIGl0IGlzIHNldCBmb3Igc3RyZWFtcyB0byB3b3JrIHByb3Blcmx5LmAsXG4gICAgICApO1xuICAgIH1cbiAgfSk7XG4gIGVycm9ycy5mb3JFYWNoKChlcnJvcikgPT4gY29uc29sZS5lcnJvcihlcnJvcikpO1xufVxuXG5leHBvcnQgY29uc3QgZGVidWcgPSAodmlldywga2luZCwgbXNnLCBvYmopID0+IHtcbiAgaWYgKHZpZXcubGl2ZVNvY2tldC5pc0RlYnVnRW5hYmxlZCgpKSB7XG4gICAgY29uc29sZS5sb2coYCR7dmlldy5pZH0gJHtraW5kfTogJHttc2d9IC0gYCwgb2JqKTtcbiAgfVxufTtcblxuLy8gd3JhcHMgdmFsdWUgaW4gY2xvc3VyZSBvciByZXR1cm5zIGNsb3N1cmVcbmV4cG9ydCBjb25zdCBjbG9zdXJlID0gKHZhbCkgPT5cbiAgdHlwZW9mIHZhbCA9PT0gXCJmdW5jdGlvblwiXG4gICAgPyB2YWxcbiAgICA6IGZ1bmN0aW9uICgpIHtcbiAgICAgICAgcmV0dXJuIHZhbDtcbiAgICAgIH07XG5cbmV4cG9ydCBjb25zdCBjbG9uZSA9IChvYmopID0+IHtcbiAgcmV0dXJuIEpTT04ucGFyc2UoSlNPTi5zdHJpbmdpZnkob2JqKSk7XG59O1xuXG5leHBvcnQgY29uc3QgY2xvc2VzdFBoeEJpbmRpbmcgPSAoZWwsIGJpbmRpbmcsIGJvcmRlckVsKSA9PiB7XG4gIGRvIHtcbiAgICBpZiAoZWwubWF0Y2hlcyhgWyR7YmluZGluZ31dYCkgJiYgIWVsLmRpc2FibGVkKSB7XG4gICAgICByZXR1cm4gZWw7XG4gICAgfVxuICAgIGVsID0gZWwucGFyZW50RWxlbWVudCB8fCBlbC5wYXJlbnROb2RlO1xuICB9IHdoaWxlIChcbiAgICBlbCAhPT0gbnVsbCAmJlxuICAgIGVsLm5vZGVUeXBlID09PSAxICYmXG4gICAgISgoYm9yZGVyRWwgJiYgYm9yZGVyRWwuaXNTYW1lTm9kZShlbCkpIHx8IGVsLm1hdGNoZXMoUEhYX1ZJRVdfU0VMRUNUT1IpKVxuICApO1xuICByZXR1cm4gbnVsbDtcbn07XG5cbmV4cG9ydCBjb25zdCBpc09iamVjdCA9IChvYmopID0+IHtcbiAgcmV0dXJuIG9iaiAhPT0gbnVsbCAmJiB0eXBlb2Ygb2JqID09PSBcIm9iamVjdFwiICYmICEob2JqIGluc3RhbmNlb2YgQXJyYXkpO1xufTtcblxuZXhwb3J0IGNvbnN0IGlzRXF1YWxPYmogPSAob2JqMSwgb2JqMikgPT5cbiAgSlNPTi5zdHJpbmdpZnkob2JqMSkgPT09IEpTT04uc3RyaW5naWZ5KG9iajIpO1xuXG5leHBvcnQgY29uc3QgaXNFbXB0eSA9IChvYmopID0+IHtcbiAgZm9yIChjb25zdCB4IGluIG9iaikge1xuICAgIHJldHVybiBmYWxzZTtcbiAgfVxuICByZXR1cm4gdHJ1ZTtcbn07XG5cbmV4cG9ydCBjb25zdCBtYXliZSA9IChlbCwgY2FsbGJhY2spID0+IGVsICYmIGNhbGxiYWNrKGVsKTtcblxuZXhwb3J0IGNvbnN0IGNoYW5uZWxVcGxvYWRlciA9IGZ1bmN0aW9uIChlbnRyaWVzLCBvbkVycm9yLCByZXNwLCBsaXZlU29ja2V0KSB7XG4gIGVudHJpZXMuZm9yRWFjaCgoZW50cnkpID0+IHtcbiAgICBjb25zdCBlbnRyeVVwbG9hZGVyID0gbmV3IEVudHJ5VXBsb2FkZXIoZW50cnksIHJlc3AuY29uZmlnLCBsaXZlU29ja2V0KTtcbiAgICBlbnRyeVVwbG9hZGVyLnVwbG9hZCgpO1xuICB9KTtcbn07XG4iLCAiY29uc3QgQnJvd3NlciA9IHtcbiAgY2FuUHVzaFN0YXRlKCkge1xuICAgIHJldHVybiB0eXBlb2YgaGlzdG9yeS5wdXNoU3RhdGUgIT09IFwidW5kZWZpbmVkXCI7XG4gIH0sXG5cbiAgZHJvcExvY2FsKGxvY2FsU3RvcmFnZSwgbmFtZXNwYWNlLCBzdWJrZXkpIHtcbiAgICByZXR1cm4gbG9jYWxTdG9yYWdlLnJlbW92ZUl0ZW0odGhpcy5sb2NhbEtleShuYW1lc3BhY2UsIHN1YmtleSkpO1xuICB9LFxuXG4gIHVwZGF0ZUxvY2FsKGxvY2FsU3RvcmFnZSwgbmFtZXNwYWNlLCBzdWJrZXksIGluaXRpYWwsIGZ1bmMpIHtcbiAgICBjb25zdCBjdXJyZW50ID0gdGhpcy5nZXRMb2NhbChsb2NhbFN0b3JhZ2UsIG5hbWVzcGFjZSwgc3Via2V5KTtcbiAgICBjb25zdCBrZXkgPSB0aGlzLmxvY2FsS2V5KG5hbWVzcGFjZSwgc3Via2V5KTtcbiAgICBjb25zdCBuZXdWYWwgPSBjdXJyZW50ID09PSBudWxsID8gaW5pdGlhbCA6IGZ1bmMoY3VycmVudCk7XG4gICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oa2V5LCBKU09OLnN0cmluZ2lmeShuZXdWYWwpKTtcbiAgICByZXR1cm4gbmV3VmFsO1xuICB9LFxuXG4gIGdldExvY2FsKGxvY2FsU3RvcmFnZSwgbmFtZXNwYWNlLCBzdWJrZXkpIHtcbiAgICByZXR1cm4gSlNPTi5wYXJzZShsb2NhbFN0b3JhZ2UuZ2V0SXRlbSh0aGlzLmxvY2FsS2V5KG5hbWVzcGFjZSwgc3Via2V5KSkpO1xuICB9LFxuXG4gIHVwZGF0ZUN1cnJlbnRTdGF0ZShjYWxsYmFjaykge1xuICAgIGlmICghdGhpcy5jYW5QdXNoU3RhdGUoKSkge1xuICAgICAgcmV0dXJuO1xuICAgIH1cbiAgICBoaXN0b3J5LnJlcGxhY2VTdGF0ZShcbiAgICAgIGNhbGxiYWNrKGhpc3Rvcnkuc3RhdGUgfHwge30pLFxuICAgICAgXCJcIixcbiAgICAgIHdpbmRvdy5sb2NhdGlvbi5ocmVmLFxuICAgICk7XG4gIH0sXG5cbiAgcHVzaFN0YXRlKGtpbmQsIG1ldGEsIHRvKSB7XG4gICAgaWYgKHRoaXMuY2FuUHVzaFN0YXRlKCkpIHtcbiAgICAgIGlmICh0byAhPT0gd2luZG93LmxvY2F0aW9uLmhyZWYpIHtcbiAgICAgICAgaWYgKG1ldGEudHlwZSA9PSBcInJlZGlyZWN0XCIgJiYgbWV0YS5zY3JvbGwpIHtcbiAgICAgICAgICAvLyBJZiB3ZSdyZSByZWRpcmVjdGluZyBzdG9yZSB0aGUgY3VycmVudCBzY3JvbGxZIGZvciB0aGUgY3VycmVudCBoaXN0b3J5IHN0YXRlLlxuICAgICAgICAgIGNvbnN0IGN1cnJlbnRTdGF0ZSA9IGhpc3Rvcnkuc3RhdGUgfHwge307XG4gICAgICAgICAgY3VycmVudFN0YXRlLnNjcm9sbCA9IG1ldGEuc2Nyb2xsO1xuICAgICAgICAgIGhpc3RvcnkucmVwbGFjZVN0YXRlKGN1cnJlbnRTdGF0ZSwgXCJcIiwgd2luZG93LmxvY2F0aW9uLmhyZWYpO1xuICAgICAgICB9XG5cbiAgICAgICAgZGVsZXRlIG1ldGEuc2Nyb2xsOyAvLyBPbmx5IHN0b3JlIHRoZSBzY3JvbGwgaW4gdGhlIHJlZGlyZWN0IGNhc2UuXG4gICAgICAgIGhpc3Rvcnlba2luZCArIFwiU3RhdGVcIl0obWV0YSwgXCJcIiwgdG8gfHwgbnVsbCk7IC8vIElFIHdpbGwgY29lcmNlIHVuZGVmaW5lZCB0byBzdHJpbmdcblxuICAgICAgICAvLyB3aGVuIHVzaW5nIG5hdmlnYXRlLCB3ZSdkIGNhbGwgcHVzaFN0YXRlIGltbWVkaWF0ZWx5IGJlZm9yZSBwYXRjaGluZyB0aGUgRE9NLFxuICAgICAgICAvLyBqdW1waW5nIGJhY2sgdG8gdGhlIHRvcCBvZiB0aGUgcGFnZSwgZWZmZWN0aXZlbHkgaWdub3JpbmcgdGhlIHNjcm9sbEludG9WaWV3O1xuICAgICAgICAvLyB0aGVyZWZvcmUgd2Ugd2FpdCBmb3IgdGhlIG5leHQgZnJhbWUgKGFmdGVyIHRoZSBET00gcGF0Y2gpIGFuZCBvbmx5IHRoZW4gdHJ5XG4gICAgICAgIC8vIHRvIHNjcm9sbCB0byB0aGUgaGFzaEVsXG4gICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgIGNvbnN0IGhhc2hFbCA9IHRoaXMuZ2V0SGFzaFRhcmdldEVsKHdpbmRvdy5sb2NhdGlvbi5oYXNoKTtcblxuICAgICAgICAgIGlmIChoYXNoRWwpIHtcbiAgICAgICAgICAgIGhhc2hFbC5zY3JvbGxJbnRvVmlldygpO1xuICAgICAgICAgIH0gZWxzZSBpZiAobWV0YS50eXBlID09PSBcInJlZGlyZWN0XCIpIHtcbiAgICAgICAgICAgIHdpbmRvdy5zY3JvbGwoMCwgMCk7XG4gICAgICAgICAgfVxuICAgICAgICB9KTtcbiAgICAgIH1cbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy5yZWRpcmVjdCh0byk7XG4gICAgfVxuICB9LFxuXG4gIHNldENvb2tpZShuYW1lLCB2YWx1ZSwgbWF4QWdlU2Vjb25kcykge1xuICAgIGNvbnN0IGV4cGlyZXMgPVxuICAgICAgdHlwZW9mIG1heEFnZVNlY29uZHMgPT09IFwibnVtYmVyXCIgPyBgIG1heC1hZ2U9JHttYXhBZ2VTZWNvbmRzfTtgIDogXCJcIjtcbiAgICBkb2N1bWVudC5jb29raWUgPSBgJHtuYW1lfT0ke3ZhbHVlfTske2V4cGlyZXN9IHBhdGg9L2A7XG4gIH0sXG5cbiAgZ2V0Q29va2llKG5hbWUpIHtcbiAgICByZXR1cm4gZG9jdW1lbnQuY29va2llLnJlcGxhY2UoXG4gICAgICBuZXcgUmVnRXhwKGAoPzooPzpefC4qO1xccyopJHtuYW1lfVxccypcXD1cXHMqKFteO10qKS4qJCl8Xi4qJGApLFxuICAgICAgXCIkMVwiLFxuICAgICk7XG4gIH0sXG5cbiAgZGVsZXRlQ29va2llKG5hbWUpIHtcbiAgICBkb2N1bWVudC5jb29raWUgPSBgJHtuYW1lfT07IG1heC1hZ2U9LTE7IHBhdGg9L2A7XG4gIH0sXG5cbiAgcmVkaXJlY3QoXG4gICAgdG9VUkwsXG4gICAgZmxhc2gsXG4gICAgbmF2aWdhdGUgPSAodXJsKSA9PiB7XG4gICAgICB3aW5kb3cubG9jYXRpb24uaHJlZiA9IHVybDtcbiAgICB9LFxuICApIHtcbiAgICBpZiAoZmxhc2gpIHtcbiAgICAgIHRoaXMuc2V0Q29va2llKFwiX19waG9lbml4X2ZsYXNoX19cIiwgZmxhc2gsIDYwKTtcbiAgICB9XG4gICAgbmF2aWdhdGUodG9VUkwpO1xuICB9LFxuXG4gIGxvY2FsS2V5KG5hbWVzcGFjZSwgc3Via2V5KSB7XG4gICAgcmV0dXJuIGAke25hbWVzcGFjZX0tJHtzdWJrZXl9YDtcbiAgfSxcblxuICBnZXRIYXNoVGFyZ2V0RWwobWF5YmVIYXNoKSB7XG4gICAgY29uc3QgaGFzaCA9IG1heWJlSGFzaC50b1N0cmluZygpLnN1YnN0cmluZygxKTtcbiAgICBpZiAoaGFzaCA9PT0gXCJcIikge1xuICAgICAgcmV0dXJuO1xuICAgIH1cbiAgICByZXR1cm4gKFxuICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaGFzaCkgfHxcbiAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoYGFbbmFtZT1cIiR7aGFzaH1cIl1gKVxuICAgICk7XG4gIH0sXG59O1xuXG5leHBvcnQgZGVmYXVsdCBCcm93c2VyO1xuIiwgImltcG9ydCB7XG4gIENIRUNLQUJMRV9JTlBVVFMsXG4gIERFQk9VTkNFX1BSRVZfS0VZLFxuICBERUJPVU5DRV9UUklHR0VSLFxuICBGT0NVU0FCTEVfSU5QVVRTLFxuICBQSFhfQ09NUE9ORU5ULFxuICBQSFhfVklFV19SRUYsXG4gIFBIWF9URUxFUE9SVEVEX1JFRixcbiAgUEhYX0hBU19GT0NVU0VELFxuICBQSFhfSEFTX1NVQk1JVFRFRCxcbiAgUEhYX01BSU4sXG4gIFBIWF9QQVJFTlRfSUQsXG4gIFBIWF9QUklWQVRFLFxuICBQSFhfUkVGX1NSQyxcbiAgUEhYX1JFRl9MT0NLLFxuICBQSFhfUEVORElOR19BVFRSUyxcbiAgUEhYX1JPT1RfSUQsXG4gIFBIWF9TRVNTSU9OLFxuICBQSFhfU1RBVElDLFxuICBQSFhfVVBMT0FEX1JFRixcbiAgUEhYX1ZJRVdfU0VMRUNUT1IsXG4gIFBIWF9TVElDS1ksXG4gIFBIWF9FVkVOVF9DTEFTU0VTLFxuICBUSFJPVFRMRUQsXG4gIFBIWF9QT1JUQUwsXG4gIFBIWF9TVFJFQU0sXG59IGZyb20gXCIuL2NvbnN0YW50c1wiO1xuXG5pbXBvcnQgeyBsb2dFcnJvciB9IGZyb20gXCIuL3V0aWxzXCI7XG5cbmNvbnN0IERPTSA9IHtcbiAgYnlJZChpZCkge1xuICAgIHJldHVybiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkgfHwgbG9nRXJyb3IoYG5vIGlkIGZvdW5kIGZvciAke2lkfWApO1xuICB9LFxuXG4gIHJlbW92ZUNsYXNzKGVsLCBjbGFzc05hbWUpIHtcbiAgICBlbC5jbGFzc0xpc3QucmVtb3ZlKGNsYXNzTmFtZSk7XG4gICAgaWYgKGVsLmNsYXNzTGlzdC5sZW5ndGggPT09IDApIHtcbiAgICAgIGVsLnJlbW92ZUF0dHJpYnV0ZShcImNsYXNzXCIpO1xuICAgIH1cbiAgfSxcblxuICBhbGwobm9kZSwgcXVlcnksIGNhbGxiYWNrKSB7XG4gICAgaWYgKCFub2RlKSB7XG4gICAgICByZXR1cm4gW107XG4gICAgfVxuICAgIGNvbnN0IGFycmF5ID0gQXJyYXkuZnJvbShub2RlLnF1ZXJ5U2VsZWN0b3JBbGwocXVlcnkpKTtcbiAgICBpZiAoY2FsbGJhY2spIHtcbiAgICAgIGFycmF5LmZvckVhY2goY2FsbGJhY2spO1xuICAgIH1cbiAgICByZXR1cm4gYXJyYXk7XG4gIH0sXG5cbiAgY2hpbGROb2RlTGVuZ3RoKGh0bWwpIHtcbiAgICBjb25zdCB0ZW1wbGF0ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJ0ZW1wbGF0ZVwiKTtcbiAgICB0ZW1wbGF0ZS5pbm5lckhUTUwgPSBodG1sO1xuICAgIHJldHVybiB0ZW1wbGF0ZS5jb250ZW50LmNoaWxkRWxlbWVudENvdW50O1xuICB9LFxuXG4gIGlzVXBsb2FkSW5wdXQoZWwpIHtcbiAgICByZXR1cm4gZWwudHlwZSA9PT0gXCJmaWxlXCIgJiYgZWwuZ2V0QXR0cmlidXRlKFBIWF9VUExPQURfUkVGKSAhPT0gbnVsbDtcbiAgfSxcblxuICBpc0F1dG9VcGxvYWQoaW5wdXRFbCkge1xuICAgIHJldHVybiBpbnB1dEVsLmhhc0F0dHJpYnV0ZShcImRhdGEtcGh4LWF1dG8tdXBsb2FkXCIpO1xuICB9LFxuXG4gIGZpbmRVcGxvYWRJbnB1dHMobm9kZSkge1xuICAgIGNvbnN0IGZvcm1JZCA9IG5vZGUuaWQ7XG4gICAgY29uc3QgaW5wdXRzT3V0c2lkZUZvcm0gPSB0aGlzLmFsbChcbiAgICAgIGRvY3VtZW50LFxuICAgICAgYGlucHV0W3R5cGU9XCJmaWxlXCJdWyR7UEhYX1VQTE9BRF9SRUZ9XVtmb3JtPVwiJHtmb3JtSWR9XCJdYCxcbiAgICApO1xuICAgIHJldHVybiB0aGlzLmFsbChub2RlLCBgaW5wdXRbdHlwZT1cImZpbGVcIl1bJHtQSFhfVVBMT0FEX1JFRn1dYCkuY29uY2F0KFxuICAgICAgaW5wdXRzT3V0c2lkZUZvcm0sXG4gICAgKTtcbiAgfSxcblxuICBmaW5kQ29tcG9uZW50Tm9kZUxpc3Qodmlld0lkLCBjaWQsIGRvYyA9IGRvY3VtZW50KSB7XG4gICAgcmV0dXJuIHRoaXMuYWxsKFxuICAgICAgZG9jLFxuICAgICAgYFske1BIWF9WSUVXX1JFRn09XCIke3ZpZXdJZH1cIl1bJHtQSFhfQ09NUE9ORU5UfT1cIiR7Y2lkfVwiXWAsXG4gICAgKTtcbiAgfSxcblxuICBpc1BoeERlc3Ryb3llZChub2RlKSB7XG4gICAgcmV0dXJuIG5vZGUuaWQgJiYgRE9NLnByaXZhdGUobm9kZSwgXCJkZXN0cm95ZWRcIikgPyB0cnVlIDogZmFsc2U7XG4gIH0sXG5cbiAgd2FudHNOZXdUYWIoZSkge1xuICAgIGNvbnN0IHdhbnRzTmV3VGFiID1cbiAgICAgIGUuY3RybEtleSB8fCBlLnNoaWZ0S2V5IHx8IGUubWV0YUtleSB8fCAoZS5idXR0b24gJiYgZS5idXR0b24gPT09IDEpO1xuICAgIGNvbnN0IGlzRG93bmxvYWQgPVxuICAgICAgZS50YXJnZXQgaW5zdGFuY2VvZiBIVE1MQW5jaG9yRWxlbWVudCAmJlxuICAgICAgZS50YXJnZXQuaGFzQXR0cmlidXRlKFwiZG93bmxvYWRcIik7XG4gICAgY29uc3QgaXNUYXJnZXRCbGFuayA9XG4gICAgICBlLnRhcmdldC5oYXNBdHRyaWJ1dGUoXCJ0YXJnZXRcIikgJiZcbiAgICAgIGUudGFyZ2V0LmdldEF0dHJpYnV0ZShcInRhcmdldFwiKS50b0xvd2VyQ2FzZSgpID09PSBcIl9ibGFua1wiO1xuICAgIGNvbnN0IGlzVGFyZ2V0TmFtZWRUYWIgPVxuICAgICAgZS50YXJnZXQuaGFzQXR0cmlidXRlKFwidGFyZ2V0XCIpICYmXG4gICAgICAhZS50YXJnZXQuZ2V0QXR0cmlidXRlKFwidGFyZ2V0XCIpLnN0YXJ0c1dpdGgoXCJfXCIpO1xuICAgIHJldHVybiB3YW50c05ld1RhYiB8fCBpc1RhcmdldEJsYW5rIHx8IGlzRG93bmxvYWQgfHwgaXNUYXJnZXROYW1lZFRhYjtcbiAgfSxcblxuICBpc1VubG9hZGFibGVGb3JtU3VibWl0KGUpIHtcbiAgICAvLyBJZ25vcmUgZm9ybSBzdWJtaXNzaW9ucyBpbnRlbmRlZCB0byBjbG9zZSBhIG5hdGl2ZSA8ZGlhbG9nPiBlbGVtZW50XG4gICAgLy8gaHR0cHM6Ly9kZXZlbG9wZXIubW96aWxsYS5vcmcvZW4tVVMvZG9jcy9XZWIvSFRNTC9FbGVtZW50L2RpYWxvZyN1c2FnZV9ub3Rlc1xuICAgIGNvbnN0IGlzRGlhbG9nU3VibWl0ID1cbiAgICAgIChlLnRhcmdldCAmJiBlLnRhcmdldC5nZXRBdHRyaWJ1dGUoXCJtZXRob2RcIikgPT09IFwiZGlhbG9nXCIpIHx8XG4gICAgICAoZS5zdWJtaXR0ZXIgJiYgZS5zdWJtaXR0ZXIuZ2V0QXR0cmlidXRlKFwiZm9ybW1ldGhvZFwiKSA9PT0gXCJkaWFsb2dcIik7XG5cbiAgICBpZiAoaXNEaWFsb2dTdWJtaXQpIHtcbiAgICAgIHJldHVybiBmYWxzZTtcbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuICFlLmRlZmF1bHRQcmV2ZW50ZWQgJiYgIXRoaXMud2FudHNOZXdUYWIoZSk7XG4gICAgfVxuICB9LFxuXG4gIGlzTmV3UGFnZUNsaWNrKGUsIGN1cnJlbnRMb2NhdGlvbikge1xuICAgIGNvbnN0IGhyZWYgPVxuICAgICAgZS50YXJnZXQgaW5zdGFuY2VvZiBIVE1MQW5jaG9yRWxlbWVudFxuICAgICAgICA/IGUudGFyZ2V0LmdldEF0dHJpYnV0ZShcImhyZWZcIilcbiAgICAgICAgOiBudWxsO1xuICAgIGxldCB1cmw7XG5cbiAgICBpZiAoZS5kZWZhdWx0UHJldmVudGVkIHx8IGhyZWYgPT09IG51bGwgfHwgdGhpcy53YW50c05ld1RhYihlKSkge1xuICAgICAgcmV0dXJuIGZhbHNlO1xuICAgIH1cbiAgICBpZiAoaHJlZi5zdGFydHNXaXRoKFwibWFpbHRvOlwiKSB8fCBocmVmLnN0YXJ0c1dpdGgoXCJ0ZWw6XCIpKSB7XG4gICAgICByZXR1cm4gZmFsc2U7XG4gICAgfVxuICAgIGlmIChlLnRhcmdldC5pc0NvbnRlbnRFZGl0YWJsZSkge1xuICAgICAgcmV0dXJuIGZhbHNlO1xuICAgIH1cblxuICAgIHRyeSB7XG4gICAgICB1cmwgPSBuZXcgVVJMKGhyZWYpO1xuICAgIH0gY2F0Y2gge1xuICAgICAgdHJ5IHtcbiAgICAgICAgdXJsID0gbmV3IFVSTChocmVmLCBjdXJyZW50TG9jYXRpb24pO1xuICAgICAgfSBjYXRjaCB7XG4gICAgICAgIC8vIGJhZCBVUkwsIGZhbGxiYWNrIHRvIGxldCBicm93c2VyIHRyeSBpdCBhcyBleHRlcm5hbFxuICAgICAgICByZXR1cm4gdHJ1ZTtcbiAgICAgIH1cbiAgICB9XG5cbiAgICBpZiAoXG4gICAgICB1cmwuaG9zdCA9PT0gY3VycmVudExvY2F0aW9uLmhvc3QgJiZcbiAgICAgIHVybC5wcm90b2NvbCA9PT0gY3VycmVudExvY2F0aW9uLnByb3RvY29sXG4gICAgKSB7XG4gICAgICBpZiAoXG4gICAgICAgIHVybC5wYXRobmFtZSA9PT0gY3VycmVudExvY2F0aW9uLnBhdGhuYW1lICYmXG4gICAgICAgIHVybC5zZWFyY2ggPT09IGN1cnJlbnRMb2NhdGlvbi5zZWFyY2hcbiAgICAgICkge1xuICAgICAgICByZXR1cm4gdXJsLmhhc2ggPT09IFwiXCIgJiYgIXVybC5ocmVmLmVuZHNXaXRoKFwiI1wiKTtcbiAgICAgIH1cbiAgICB9XG4gICAgcmV0dXJuIHVybC5wcm90b2NvbC5zdGFydHNXaXRoKFwiaHR0cFwiKTtcbiAgfSxcblxuICBtYXJrUGh4Q2hpbGREZXN0cm95ZWQoZWwpIHtcbiAgICBpZiAodGhpcy5pc1BoeENoaWxkKGVsKSkge1xuICAgICAgZWwuc2V0QXR0cmlidXRlKFBIWF9TRVNTSU9OLCBcIlwiKTtcbiAgICB9XG4gICAgdGhpcy5wdXRQcml2YXRlKGVsLCBcImRlc3Ryb3llZFwiLCB0cnVlKTtcbiAgfSxcblxuICBmaW5kUGh4Q2hpbGRyZW5JbkZyYWdtZW50KGh0bWwsIHBhcmVudElkKSB7XG4gICAgY29uc3QgdGVtcGxhdGUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwidGVtcGxhdGVcIik7XG4gICAgdGVtcGxhdGUuaW5uZXJIVE1MID0gaHRtbDtcbiAgICByZXR1cm4gdGhpcy5maW5kUGh4Q2hpbGRyZW4odGVtcGxhdGUuY29udGVudCwgcGFyZW50SWQpO1xuICB9LFxuXG4gIGlzSWdub3JlZChlbCwgcGh4VXBkYXRlKSB7XG4gICAgcmV0dXJuIChcbiAgICAgIChlbC5nZXRBdHRyaWJ1dGUocGh4VXBkYXRlKSB8fCBlbC5nZXRBdHRyaWJ1dGUoXCJkYXRhLXBoeC11cGRhdGVcIikpID09PVxuICAgICAgXCJpZ25vcmVcIlxuICAgICk7XG4gIH0sXG5cbiAgaXNQaHhVcGRhdGUoZWwsIHBoeFVwZGF0ZSwgdXBkYXRlVHlwZXMpIHtcbiAgICByZXR1cm4gKFxuICAgICAgZWwuZ2V0QXR0cmlidXRlICYmIHVwZGF0ZVR5cGVzLmluZGV4T2YoZWwuZ2V0QXR0cmlidXRlKHBoeFVwZGF0ZSkpID49IDBcbiAgICApO1xuICB9LFxuXG4gIGZpbmRQaHhTdGlja3koZWwpIHtcbiAgICByZXR1cm4gdGhpcy5hbGwoZWwsIGBbJHtQSFhfU1RJQ0tZfV1gKTtcbiAgfSxcblxuICBmaW5kUGh4Q2hpbGRyZW4oZWwsIHBhcmVudElkKSB7XG4gICAgcmV0dXJuIHRoaXMuYWxsKGVsLCBgJHtQSFhfVklFV19TRUxFQ1RPUn1bJHtQSFhfUEFSRU5UX0lEfT1cIiR7cGFyZW50SWR9XCJdYCk7XG4gIH0sXG5cbiAgZmluZEV4aXN0aW5nUGFyZW50Q0lEcyh2aWV3SWQsIGNpZHMpIHtcbiAgICAvLyB3ZSBvbmx5IHdhbnQgdG8gZmluZCBwYXJlbnRzIHRoYXQgZXhpc3Qgb24gdGhlIHBhZ2VcbiAgICAvLyBpZiBhIGNpZCBpcyBub3Qgb24gdGhlIHBhZ2UsIHRoZSBvbmx5IHdheSBpdCBjYW4gYmUgYWRkZWQgYmFjayB0byB0aGUgcGFnZVxuICAgIC8vIGlzIGlmIGEgcGFyZW50IGFkZHMgaXQgYmFjaywgdGhlcmVmb3JlIGlmIGEgY2lkIGRvZXMgbm90IGV4aXN0IG9uIHRoZSBwYWdlLFxuICAgIC8vIHdlIHNob3VsZCBub3QgdHJ5IHRvIHJlbmRlciBpdCBieSBpdHNlbGYgKGJlY2F1c2UgaXQgd291bGQgYmUgcmVuZGVyZWQgdHdpY2UsXG4gICAgLy8gb25lIGJ5IHRoZSBwYXJlbnQsIGFuZCBhIHNlY29uZCB0aW1lIGJ5IGl0c2VsZilcbiAgICBjb25zdCBwYXJlbnRDaWRzID0gbmV3IFNldCgpO1xuICAgIGNvbnN0IGNoaWxkcmVuQ2lkcyA9IG5ldyBTZXQoKTtcblxuICAgIGNpZHMuZm9yRWFjaCgoY2lkKSA9PiB7XG4gICAgICB0aGlzLmFsbChcbiAgICAgICAgZG9jdW1lbnQsXG4gICAgICAgIGBbJHtQSFhfVklFV19SRUZ9PVwiJHt2aWV3SWR9XCJdWyR7UEhYX0NPTVBPTkVOVH09XCIke2NpZH1cIl1gLFxuICAgICAgKS5mb3JFYWNoKChwYXJlbnQpID0+IHtcbiAgICAgICAgcGFyZW50Q2lkcy5hZGQoY2lkKTtcbiAgICAgICAgdGhpcy5hbGwocGFyZW50LCBgWyR7UEhYX1ZJRVdfUkVGfT1cIiR7dmlld0lkfVwiXVske1BIWF9DT01QT05FTlR9XWApXG4gICAgICAgICAgLm1hcCgoZWwpID0+IHBhcnNlSW50KGVsLmdldEF0dHJpYnV0ZShQSFhfQ09NUE9ORU5UKSkpXG4gICAgICAgICAgLmZvckVhY2goKGNoaWxkQ0lEKSA9PiBjaGlsZHJlbkNpZHMuYWRkKGNoaWxkQ0lEKSk7XG4gICAgICB9KTtcbiAgICB9KTtcblxuICAgIGNoaWxkcmVuQ2lkcy5mb3JFYWNoKChjaGlsZENpZCkgPT4gcGFyZW50Q2lkcy5kZWxldGUoY2hpbGRDaWQpKTtcblxuICAgIHJldHVybiBwYXJlbnRDaWRzO1xuICB9LFxuXG4gIHByaXZhdGUoZWwsIGtleSkge1xuICAgIHJldHVybiBlbFtQSFhfUFJJVkFURV0gJiYgZWxbUEhYX1BSSVZBVEVdW2tleV07XG4gIH0sXG5cbiAgZGVsZXRlUHJpdmF0ZShlbCwga2V5KSB7XG4gICAgZWxbUEhYX1BSSVZBVEVdICYmIGRlbGV0ZSBlbFtQSFhfUFJJVkFURV1ba2V5XTtcbiAgfSxcblxuICBwdXRQcml2YXRlKGVsLCBrZXksIHZhbHVlKSB7XG4gICAgaWYgKCFlbFtQSFhfUFJJVkFURV0pIHtcbiAgICAgIGVsW1BIWF9QUklWQVRFXSA9IHt9O1xuICAgIH1cbiAgICBlbFtQSFhfUFJJVkFURV1ba2V5XSA9IHZhbHVlO1xuICB9LFxuXG4gIHVwZGF0ZVByaXZhdGUoZWwsIGtleSwgZGVmYXVsdFZhbCwgdXBkYXRlRnVuYykge1xuICAgIGNvbnN0IGV4aXN0aW5nID0gdGhpcy5wcml2YXRlKGVsLCBrZXkpO1xuICAgIGlmIChleGlzdGluZyA9PT0gdW5kZWZpbmVkKSB7XG4gICAgICB0aGlzLnB1dFByaXZhdGUoZWwsIGtleSwgdXBkYXRlRnVuYyhkZWZhdWx0VmFsKSk7XG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMucHV0UHJpdmF0ZShlbCwga2V5LCB1cGRhdGVGdW5jKGV4aXN0aW5nKSk7XG4gICAgfVxuICB9LFxuXG4gIHN5bmNQZW5kaW5nQXR0cnMoZnJvbUVsLCB0b0VsKSB7XG4gICAgaWYgKCFmcm9tRWwuaGFzQXR0cmlidXRlKFBIWF9SRUZfU1JDKSkge1xuICAgICAgcmV0dXJuO1xuICAgIH1cbiAgICBQSFhfRVZFTlRfQ0xBU1NFUy5mb3JFYWNoKChjbGFzc05hbWUpID0+IHtcbiAgICAgIGZyb21FbC5jbGFzc0xpc3QuY29udGFpbnMoY2xhc3NOYW1lKSAmJiB0b0VsLmNsYXNzTGlzdC5hZGQoY2xhc3NOYW1lKTtcbiAgICB9KTtcbiAgICBQSFhfUEVORElOR19BVFRSUy5maWx0ZXIoKGF0dHIpID0+IGZyb21FbC5oYXNBdHRyaWJ1dGUoYXR0cikpLmZvckVhY2goXG4gICAgICAoYXR0cikgPT4ge1xuICAgICAgICB0b0VsLnNldEF0dHJpYnV0ZShhdHRyLCBmcm9tRWwuZ2V0QXR0cmlidXRlKGF0dHIpKTtcbiAgICAgIH0sXG4gICAgKTtcbiAgfSxcblxuICBjb3B5UHJpdmF0ZXModGFyZ2V0LCBzb3VyY2UpIHtcbiAgICBpZiAoc291cmNlW1BIWF9QUklWQVRFXSkge1xuICAgICAgdGFyZ2V0W1BIWF9QUklWQVRFXSA9IHNvdXJjZVtQSFhfUFJJVkFURV07XG4gICAgfVxuICB9LFxuXG4gIHB1dFRpdGxlKHN0cikge1xuICAgIGNvbnN0IHRpdGxlRWwgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yKFwidGl0bGVcIik7XG4gICAgaWYgKHRpdGxlRWwpIHtcbiAgICAgIGNvbnN0IHsgcHJlZml4LCBzdWZmaXgsIGRlZmF1bHQ6IGRlZmF1bHRUaXRsZSB9ID0gdGl0bGVFbC5kYXRhc2V0O1xuICAgICAgY29uc3QgaXNFbXB0eSA9IHR5cGVvZiBzdHIgIT09IFwic3RyaW5nXCIgfHwgc3RyLnRyaW0oKSA9PT0gXCJcIjtcbiAgICAgIGlmIChpc0VtcHR5ICYmIHR5cGVvZiBkZWZhdWx0VGl0bGUgIT09IFwic3RyaW5nXCIpIHtcbiAgICAgICAgcmV0dXJuO1xuICAgICAgfVxuXG4gICAgICBjb25zdCBpbm5lciA9IGlzRW1wdHkgPyBkZWZhdWx0VGl0bGUgOiBzdHI7XG4gICAgICBkb2N1bWVudC50aXRsZSA9IGAke3ByZWZpeCB8fCBcIlwifSR7aW5uZXIgfHwgXCJcIn0ke3N1ZmZpeCB8fCBcIlwifWA7XG4gICAgfSBlbHNlIHtcbiAgICAgIGRvY3VtZW50LnRpdGxlID0gc3RyO1xuICAgIH1cbiAgfSxcblxuICBkZWJvdW5jZShcbiAgICBlbCxcbiAgICBldmVudCxcbiAgICBwaHhEZWJvdW5jZSxcbiAgICBkZWZhdWx0RGVib3VuY2UsXG4gICAgcGh4VGhyb3R0bGUsXG4gICAgZGVmYXVsdFRocm90dGxlLFxuICAgIGFzeW5jRmlsdGVyLFxuICAgIGNhbGxiYWNrLFxuICApIHtcbiAgICBsZXQgZGVib3VuY2UgPSBlbC5nZXRBdHRyaWJ1dGUocGh4RGVib3VuY2UpO1xuICAgIGxldCB0aHJvdHRsZSA9IGVsLmdldEF0dHJpYnV0ZShwaHhUaHJvdHRsZSk7XG5cbiAgICBpZiAoZGVib3VuY2UgPT09IFwiXCIpIHtcbiAgICAgIGRlYm91bmNlID0gZGVmYXVsdERlYm91bmNlO1xuICAgIH1cbiAgICBpZiAodGhyb3R0bGUgPT09IFwiXCIpIHtcbiAgICAgIHRocm90dGxlID0gZGVmYXVsdFRocm90dGxlO1xuICAgIH1cbiAgICBjb25zdCB2YWx1ZSA9IGRlYm91bmNlIHx8IHRocm90dGxlO1xuICAgIHN3aXRjaCAodmFsdWUpIHtcbiAgICAgIGNhc2UgbnVsbDpcbiAgICAgICAgcmV0dXJuIGNhbGxiYWNrKCk7XG5cbiAgICAgIGNhc2UgXCJibHVyXCI6XG4gICAgICAgIHRoaXMuaW5jQ3ljbGUoZWwsIFwiZGVib3VuY2UtYmx1ci1jeWNsZVwiLCAoKSA9PiB7XG4gICAgICAgICAgaWYgKGFzeW5jRmlsdGVyKCkpIHtcbiAgICAgICAgICAgIGNhbGxiYWNrKCk7XG4gICAgICAgICAgfVxuICAgICAgICB9KTtcbiAgICAgICAgaWYgKHRoaXMub25jZShlbCwgXCJkZWJvdW5jZS1ibHVyXCIpKSB7XG4gICAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcihcImJsdXJcIiwgKCkgPT5cbiAgICAgICAgICAgIHRoaXMudHJpZ2dlckN5Y2xlKGVsLCBcImRlYm91bmNlLWJsdXItY3ljbGVcIiksXG4gICAgICAgICAgKTtcbiAgICAgICAgfVxuICAgICAgICByZXR1cm47XG5cbiAgICAgIGRlZmF1bHQ6XG4gICAgICAgIGNvbnN0IHRpbWVvdXQgPSBwYXJzZUludCh2YWx1ZSk7XG4gICAgICAgIGNvbnN0IHRyaWdnZXIgPSAoKSA9PlxuICAgICAgICAgIHRocm90dGxlID8gdGhpcy5kZWxldGVQcml2YXRlKGVsLCBUSFJPVFRMRUQpIDogY2FsbGJhY2soKTtcbiAgICAgICAgY29uc3QgY3VycmVudEN5Y2xlID0gdGhpcy5pbmNDeWNsZShlbCwgREVCT1VOQ0VfVFJJR0dFUiwgdHJpZ2dlcik7XG4gICAgICAgIGlmIChpc05hTih0aW1lb3V0KSkge1xuICAgICAgICAgIHJldHVybiBsb2dFcnJvcihgaW52YWxpZCB0aHJvdHRsZS9kZWJvdW5jZSB2YWx1ZTogJHt2YWx1ZX1gKTtcbiAgICAgICAgfVxuICAgICAgICBpZiAodGhyb3R0bGUpIHtcbiAgICAgICAgICBsZXQgbmV3S2V5RG93biA9IGZhbHNlO1xuICAgICAgICAgIGlmIChldmVudC50eXBlID09PSBcImtleWRvd25cIikge1xuICAgICAgICAgICAgY29uc3QgcHJldktleSA9IHRoaXMucHJpdmF0ZShlbCwgREVCT1VOQ0VfUFJFVl9LRVkpO1xuICAgICAgICAgICAgdGhpcy5wdXRQcml2YXRlKGVsLCBERUJPVU5DRV9QUkVWX0tFWSwgZXZlbnQua2V5KTtcbiAgICAgICAgICAgIG5ld0tleURvd24gPSBwcmV2S2V5ICE9PSBldmVudC5rZXk7XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgaWYgKCFuZXdLZXlEb3duICYmIHRoaXMucHJpdmF0ZShlbCwgVEhST1RUTEVEKSkge1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBjYWxsYmFjaygpO1xuICAgICAgICAgICAgY29uc3QgdCA9IHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgICAgICAgICBpZiAoYXN5bmNGaWx0ZXIoKSkge1xuICAgICAgICAgICAgICAgIHRoaXMudHJpZ2dlckN5Y2xlKGVsLCBERUJPVU5DRV9UUklHR0VSKTtcbiAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgfSwgdGltZW91dCk7XG4gICAgICAgICAgICB0aGlzLnB1dFByaXZhdGUoZWwsIFRIUk9UVExFRCwgdCk7XG4gICAgICAgICAgfVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgICAgICAgaWYgKGFzeW5jRmlsdGVyKCkpIHtcbiAgICAgICAgICAgICAgdGhpcy50cmlnZ2VyQ3ljbGUoZWwsIERFQk9VTkNFX1RSSUdHRVIsIGN1cnJlbnRDeWNsZSk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgfSwgdGltZW91dCk7XG4gICAgICAgIH1cblxuICAgICAgICBjb25zdCBmb3JtID0gZWwuZm9ybTtcbiAgICAgICAgaWYgKGZvcm0gJiYgdGhpcy5vbmNlKGZvcm0sIFwiYmluZC1kZWJvdW5jZVwiKSkge1xuICAgICAgICAgIGZvcm0uYWRkRXZlbnRMaXN0ZW5lcihcInN1Ym1pdFwiLCAoKSA9PiB7XG4gICAgICAgICAgICBBcnJheS5mcm9tKG5ldyBGb3JtRGF0YShmb3JtKS5lbnRyaWVzKCksIChbbmFtZV0pID0+IHtcbiAgICAgICAgICAgICAgY29uc3QgaW5wdXQgPSBmb3JtLnF1ZXJ5U2VsZWN0b3IoYFtuYW1lPVwiJHtuYW1lfVwiXWApO1xuICAgICAgICAgICAgICB0aGlzLmluY0N5Y2xlKGlucHV0LCBERUJPVU5DRV9UUklHR0VSKTtcbiAgICAgICAgICAgICAgdGhpcy5kZWxldGVQcml2YXRlKGlucHV0LCBUSFJPVFRMRUQpO1xuICAgICAgICAgICAgfSk7XG4gICAgICAgICAgfSk7XG4gICAgICAgIH1cbiAgICAgICAgaWYgKHRoaXMub25jZShlbCwgXCJiaW5kLWRlYm91bmNlXCIpKSB7XG4gICAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcihcImJsdXJcIiwgKCkgPT4ge1xuICAgICAgICAgICAgLy8gYmVjYXVzZSB3ZSB0cmlnZ2VyIHRoZSBjYWxsYmFjayBoZXJlLFxuICAgICAgICAgICAgLy8gd2UgYWxzbyBjbGVhciB0aGUgdGhyb3R0bGUgdGltZW91dCB0byBwcmV2ZW50IHRoZSBjYWxsYmFja1xuICAgICAgICAgICAgLy8gZnJvbSBiZWluZyBjYWxsZWQgYWdhaW4gYWZ0ZXIgdGhlIHRpbWVvdXQgZmlyZXNcbiAgICAgICAgICAgIGNsZWFyVGltZW91dCh0aGlzLnByaXZhdGUoZWwsIFRIUk9UVExFRCkpO1xuICAgICAgICAgICAgdGhpcy50cmlnZ2VyQ3ljbGUoZWwsIERFQk9VTkNFX1RSSUdHRVIpO1xuICAgICAgICAgIH0pO1xuICAgICAgICB9XG4gICAgfVxuICB9LFxuXG4gIHRyaWdnZXJDeWNsZShlbCwga2V5LCBjdXJyZW50Q3ljbGUpIHtcbiAgICBjb25zdCBbY3ljbGUsIHRyaWdnZXJdID0gdGhpcy5wcml2YXRlKGVsLCBrZXkpO1xuICAgIGlmICghY3VycmVudEN5Y2xlKSB7XG4gICAgICBjdXJyZW50Q3ljbGUgPSBjeWNsZTtcbiAgICB9XG4gICAgaWYgKGN1cnJlbnRDeWNsZSA9PT0gY3ljbGUpIHtcbiAgICAgIHRoaXMuaW5jQ3ljbGUoZWwsIGtleSk7XG4gICAgICB0cmlnZ2VyKCk7XG4gICAgfVxuICB9LFxuXG4gIG9uY2UoZWwsIGtleSkge1xuICAgIGlmICh0aGlzLnByaXZhdGUoZWwsIGtleSkgPT09IHRydWUpIHtcbiAgICAgIHJldHVybiBmYWxzZTtcbiAgICB9XG4gICAgdGhpcy5wdXRQcml2YXRlKGVsLCBrZXksIHRydWUpO1xuICAgIHJldHVybiB0cnVlO1xuICB9LFxuXG4gIGluY0N5Y2xlKGVsLCBrZXksIHRyaWdnZXIgPSBmdW5jdGlvbiAoKSB7fSkge1xuICAgIGxldCBbY3VycmVudEN5Y2xlXSA9IHRoaXMucHJpdmF0ZShlbCwga2V5KSB8fCBbMCwgdHJpZ2dlcl07XG4gICAgY3VycmVudEN5Y2xlKys7XG4gICAgdGhpcy5wdXRQcml2YXRlKGVsLCBrZXksIFtjdXJyZW50Q3ljbGUsIHRyaWdnZXJdKTtcbiAgICByZXR1cm4gY3VycmVudEN5Y2xlO1xuICB9LFxuXG4gIC8vIG1haW50YWlucyBvciBhZGRzIHByaXZhdGVseSB1c2VkIGhvb2sgaW5mb3JtYXRpb25cbiAgLy8gZnJvbUVsIGFuZCB0b0VsIGNhbiBiZSB0aGUgc2FtZSBlbGVtZW50IGluIHRoZSBjYXNlIG9mIGEgbmV3bHkgYWRkZWQgbm9kZVxuICAvLyBmcm9tRWwgYW5kIHRvRWwgY2FuIGJlIGFueSBIVE1MIG5vZGUgdHlwZSwgc28gd2UgbmVlZCB0byBjaGVjayBpZiBpdCdzIGFuIGVsZW1lbnQgbm9kZVxuICBtYWludGFpblByaXZhdGVIb29rcyhmcm9tRWwsIHRvRWwsIHBoeFZpZXdwb3J0VG9wLCBwaHhWaWV3cG9ydEJvdHRvbSkge1xuICAgIC8vIG1haW50YWluIHRoZSBob29rcyBjcmVhdGVkIHdpdGggY3JlYXRlSG9va1xuICAgIGlmIChcbiAgICAgIGZyb21FbC5oYXNBdHRyaWJ1dGUgJiZcbiAgICAgIGZyb21FbC5oYXNBdHRyaWJ1dGUoXCJkYXRhLXBoeC1ob29rXCIpICYmXG4gICAgICAhdG9FbC5oYXNBdHRyaWJ1dGUoXCJkYXRhLXBoeC1ob29rXCIpXG4gICAgKSB7XG4gICAgICB0b0VsLnNldEF0dHJpYnV0ZShcImRhdGEtcGh4LWhvb2tcIiwgZnJvbUVsLmdldEF0dHJpYnV0ZShcImRhdGEtcGh4LWhvb2tcIikpO1xuICAgIH1cbiAgICAvLyBhZGQgaG9va3MgdG8gZWxlbWVudHMgd2l0aCB2aWV3cG9ydCBhdHRyaWJ1dGVzXG4gICAgaWYgKFxuICAgICAgdG9FbC5oYXNBdHRyaWJ1dGUgJiZcbiAgICAgICh0b0VsLmhhc0F0dHJpYnV0ZShwaHhWaWV3cG9ydFRvcCkgfHxcbiAgICAgICAgdG9FbC5oYXNBdHRyaWJ1dGUocGh4Vmlld3BvcnRCb3R0b20pKVxuICAgICkge1xuICAgICAgdG9FbC5zZXRBdHRyaWJ1dGUoXCJkYXRhLXBoeC1ob29rXCIsIFwiUGhvZW5peC5JbmZpbml0ZVNjcm9sbFwiKTtcbiAgICB9XG4gIH0sXG5cbiAgcHV0Q3VzdG9tRWxIb29rKGVsLCBob29rKSB7XG4gICAgaWYgKGVsLmlzQ29ubmVjdGVkKSB7XG4gICAgICBlbC5zZXRBdHRyaWJ1dGUoXCJkYXRhLXBoeC1ob29rXCIsIFwiXCIpO1xuICAgIH0gZWxzZSB7XG4gICAgICBjb25zb2xlLmVycm9yKGBcbiAgICAgICAgaG9vayBhdHRhY2hlZCB0byBub24tY29ubmVjdGVkIERPTSBlbGVtZW50XG4gICAgICAgIGVuc3VyZSB5b3UgYXJlIGNhbGxpbmcgY3JlYXRlSG9vayB3aXRoaW4geW91ciBjb25uZWN0ZWRDYWxsYmFjay4gJHtlbC5vdXRlckhUTUx9XG4gICAgICBgKTtcbiAgICB9XG4gICAgdGhpcy5wdXRQcml2YXRlKGVsLCBcImN1c3RvbS1lbC1ob29rXCIsIGhvb2spO1xuICB9LFxuXG4gIGdldEN1c3RvbUVsSG9vayhlbCkge1xuICAgIHJldHVybiB0aGlzLnByaXZhdGUoZWwsIFwiY3VzdG9tLWVsLWhvb2tcIik7XG4gIH0sXG5cbiAgaXNVc2VkSW5wdXQoZWwpIHtcbiAgICByZXR1cm4gKFxuICAgICAgZWwubm9kZVR5cGUgPT09IE5vZGUuRUxFTUVOVF9OT0RFICYmXG4gICAgICAodGhpcy5wcml2YXRlKGVsLCBQSFhfSEFTX0ZPQ1VTRUQpIHx8IHRoaXMucHJpdmF0ZShlbCwgUEhYX0hBU19TVUJNSVRURUQpKVxuICAgICk7XG4gIH0sXG5cbiAgcmVzZXRGb3JtKGZvcm0pIHtcbiAgICBBcnJheS5mcm9tKGZvcm0uZWxlbWVudHMpLmZvckVhY2goKGlucHV0KSA9PiB7XG4gICAgICB0aGlzLmRlbGV0ZVByaXZhdGUoaW5wdXQsIFBIWF9IQVNfRk9DVVNFRCk7XG4gICAgICB0aGlzLmRlbGV0ZVByaXZhdGUoaW5wdXQsIFBIWF9IQVNfU1VCTUlUVEVEKTtcbiAgICB9KTtcbiAgfSxcblxuICBpc1BoeENoaWxkKG5vZGUpIHtcbiAgICByZXR1cm4gbm9kZS5nZXRBdHRyaWJ1dGUgJiYgbm9kZS5nZXRBdHRyaWJ1dGUoUEhYX1BBUkVOVF9JRCk7XG4gIH0sXG5cbiAgaXNQaHhTdGlja3kobm9kZSkge1xuICAgIHJldHVybiBub2RlLmdldEF0dHJpYnV0ZSAmJiBub2RlLmdldEF0dHJpYnV0ZShQSFhfU1RJQ0tZKSAhPT0gbnVsbDtcbiAgfSxcblxuICBpc0NoaWxkT2ZBbnkoZWwsIHBhcmVudHMpIHtcbiAgICByZXR1cm4gISFwYXJlbnRzLmZpbmQoKHBhcmVudCkgPT4gcGFyZW50LmNvbnRhaW5zKGVsKSk7XG4gIH0sXG5cbiAgZmlyc3RQaHhDaGlsZChlbCkge1xuICAgIHJldHVybiB0aGlzLmlzUGh4Q2hpbGQoZWwpID8gZWwgOiB0aGlzLmFsbChlbCwgYFske1BIWF9QQVJFTlRfSUR9XWApWzBdO1xuICB9LFxuXG4gIGlzUG9ydGFsVGVtcGxhdGUoZWwpIHtcbiAgICByZXR1cm4gZWwudGFnTmFtZSA9PT0gXCJURU1QTEFURVwiICYmIGVsLmhhc0F0dHJpYnV0ZShQSFhfUE9SVEFMKTtcbiAgfSxcblxuICBjbG9zZXN0Vmlld0VsKGVsKSB7XG4gICAgLy8gZmluZCB0aGUgY2xvc2VzdCBwb3J0YWwgb3IgdmlldyBlbGVtZW50LCB3aGljaGV2ZXIgY29tZXMgZmlyc3RcbiAgICBjb25zdCBwb3J0YWxPclZpZXdFbCA9IGVsLmNsb3Nlc3QoXG4gICAgICBgWyR7UEhYX1RFTEVQT1JURURfUkVGfV0sJHtQSFhfVklFV19TRUxFQ1RPUn1gLFxuICAgICk7XG4gICAgaWYgKCFwb3J0YWxPclZpZXdFbCkge1xuICAgICAgcmV0dXJuIG51bGw7XG4gICAgfVxuICAgIGlmIChwb3J0YWxPclZpZXdFbC5oYXNBdHRyaWJ1dGUoUEhYX1RFTEVQT1JURURfUkVGKSkge1xuICAgICAgLy8gUEhYX1RFTEVQT1JURURfUkVGIGlzIHNldCB0byB0aGUgaWQgb2YgdGhlIHZpZXcgdGhhdCBvd25zIHRoZSBwb3J0YWwgZWxlbWVudFxuICAgICAgcmV0dXJuIHRoaXMuYnlJZChwb3J0YWxPclZpZXdFbC5nZXRBdHRyaWJ1dGUoUEhYX1RFTEVQT1JURURfUkVGKSk7XG4gICAgfSBlbHNlIGlmIChwb3J0YWxPclZpZXdFbC5oYXNBdHRyaWJ1dGUoUEhYX1NFU1NJT04pKSB7XG4gICAgICByZXR1cm4gcG9ydGFsT3JWaWV3RWw7XG4gICAgfVxuICAgIHJldHVybiBudWxsO1xuICB9LFxuXG4gIGRpc3BhdGNoRXZlbnQodGFyZ2V0LCBuYW1lLCBvcHRzID0ge30pIHtcbiAgICBsZXQgZGVmYXVsdEJ1YmJsZSA9IHRydWU7XG4gICAgY29uc3QgaXNVcGxvYWRUYXJnZXQgPVxuICAgICAgdGFyZ2V0Lm5vZGVOYW1lID09PSBcIklOUFVUXCIgJiYgdGFyZ2V0LnR5cGUgPT09IFwiZmlsZVwiO1xuICAgIGlmIChpc1VwbG9hZFRhcmdldCAmJiBuYW1lID09PSBcImNsaWNrXCIpIHtcbiAgICAgIGRlZmF1bHRCdWJibGUgPSBmYWxzZTtcbiAgICB9XG4gICAgY29uc3QgYnViYmxlcyA9IG9wdHMuYnViYmxlcyA9PT0gdW5kZWZpbmVkID8gZGVmYXVsdEJ1YmJsZSA6ICEhb3B0cy5idWJibGVzO1xuICAgIGNvbnN0IGV2ZW50T3B0cyA9IHtcbiAgICAgIGJ1YmJsZXM6IGJ1YmJsZXMsXG4gICAgICBjYW5jZWxhYmxlOiB0cnVlLFxuICAgICAgZGV0YWlsOiBvcHRzLmRldGFpbCB8fCB7fSxcbiAgICB9O1xuICAgIGNvbnN0IGV2ZW50ID1cbiAgICAgIG5hbWUgPT09IFwiY2xpY2tcIlxuICAgICAgICA/IG5ldyBNb3VzZUV2ZW50KFwiY2xpY2tcIiwgZXZlbnRPcHRzKVxuICAgICAgICA6IG5ldyBDdXN0b21FdmVudChuYW1lLCBldmVudE9wdHMpO1xuICAgIHRhcmdldC5kaXNwYXRjaEV2ZW50KGV2ZW50KTtcbiAgfSxcblxuICBjbG9uZU5vZGUobm9kZSwgaHRtbCkge1xuICAgIGlmICh0eXBlb2YgaHRtbCA9PT0gXCJ1bmRlZmluZWRcIikge1xuICAgICAgcmV0dXJuIG5vZGUuY2xvbmVOb2RlKHRydWUpO1xuICAgIH0gZWxzZSB7XG4gICAgICBjb25zdCBjbG9uZWQgPSBub2RlLmNsb25lTm9kZShmYWxzZSk7XG4gICAgICBjbG9uZWQuaW5uZXJIVE1MID0gaHRtbDtcbiAgICAgIHJldHVybiBjbG9uZWQ7XG4gICAgfVxuICB9LFxuXG4gIC8vIG1lcmdlIGF0dHJpYnV0ZXMgZnJvbSBzb3VyY2UgdG8gdGFyZ2V0XG4gIC8vIGlmIGFuIGVsZW1lbnQgaXMgaWdub3JlZCwgd2Ugb25seSBtZXJnZSBkYXRhIGF0dHJpYnV0ZXNcbiAgLy8gaW5jbHVkaW5nIHJlbW92aW5nIGRhdGEgYXR0cmlidXRlcyB0aGF0IGFyZSBubyBsb25nZXIgaW4gdGhlIHNvdXJjZVxuICBtZXJnZUF0dHJzKHRhcmdldCwgc291cmNlLCBvcHRzID0ge30pIHtcbiAgICBjb25zdCBleGNsdWRlID0gbmV3IFNldChvcHRzLmV4Y2x1ZGUgfHwgW10pO1xuICAgIGNvbnN0IGlzSWdub3JlZCA9IG9wdHMuaXNJZ25vcmVkO1xuICAgIGNvbnN0IHNvdXJjZUF0dHJzID0gc291cmNlLmF0dHJpYnV0ZXM7XG4gICAgZm9yIChsZXQgaSA9IHNvdXJjZUF0dHJzLmxlbmd0aCAtIDE7IGkgPj0gMDsgaS0tKSB7XG4gICAgICBjb25zdCBuYW1lID0gc291cmNlQXR0cnNbaV0ubmFtZTtcbiAgICAgIGlmICghZXhjbHVkZS5oYXMobmFtZSkpIHtcbiAgICAgICAgY29uc3Qgc291cmNlVmFsdWUgPSBzb3VyY2UuZ2V0QXR0cmlidXRlKG5hbWUpO1xuICAgICAgICBpZiAoXG4gICAgICAgICAgdGFyZ2V0LmdldEF0dHJpYnV0ZShuYW1lKSAhPT0gc291cmNlVmFsdWUgJiZcbiAgICAgICAgICAoIWlzSWdub3JlZCB8fCAoaXNJZ25vcmVkICYmIG5hbWUuc3RhcnRzV2l0aChcImRhdGEtXCIpKSlcbiAgICAgICAgKSB7XG4gICAgICAgICAgdGFyZ2V0LnNldEF0dHJpYnV0ZShuYW1lLCBzb3VyY2VWYWx1ZSk7XG4gICAgICAgIH1cbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIC8vIFdlIGV4Y2x1ZGUgdGhlIHZhbHVlIGZyb20gYmVpbmcgbWVyZ2VkIG9uIGZvY3VzZWQgaW5wdXRzLCBiZWNhdXNlIHRoZVxuICAgICAgICAvLyB1c2VyJ3MgaW5wdXQgc2hvdWxkIGFsd2F5cyB3aW4uXG4gICAgICAgIC8vIFdlIGNhbiBzdGlsbCBhc3NpZ24gaXQgYXMgbG9uZyBhcyB0aGUgdmFsdWUgcHJvcGVydHkgaXMgdGhlIHNhbWUsIHRob3VnaC5cbiAgICAgICAgLy8gVGhpcyBwcmV2ZW50cyBhIHNpdHVhdGlvbiB3aGVyZSB0aGUgdXBkYXRlZCBob29rIGlzIG5vdCBiZWluZyB0cmlnZ2VyZWRcbiAgICAgICAgLy8gd2hlbiBhbiBpbnB1dCBpcyBiYWNrIGluIGl0cyBcIm9yaWdpbmFsIHN0YXRlXCIsIGJlY2F1c2UgdGhlIGF0dHJpYnV0ZVxuICAgICAgICAvLyB3YXMgbmV2ZXIgY2hhbmdlZCwgc2VlOlxuICAgICAgICAvLyBodHRwczovL2dpdGh1Yi5jb20vcGhvZW5peGZyYW1ld29yay9waG9lbml4X2xpdmVfdmlldy9pc3N1ZXMvMjE2M1xuICAgICAgICBpZiAobmFtZSA9PT0gXCJ2YWx1ZVwiICYmIHRhcmdldC52YWx1ZSA9PT0gc291cmNlLnZhbHVlKSB7XG4gICAgICAgICAgLy8gYWN0dWFsbHkgc2V0IHRoZSB2YWx1ZSBhdHRyaWJ1dGUgdG8gc3luYyBpdCB3aXRoIHRoZSB2YWx1ZSBwcm9wZXJ0eVxuICAgICAgICAgIHRhcmdldC5zZXRBdHRyaWJ1dGUoXCJ2YWx1ZVwiLCBzb3VyY2UuZ2V0QXR0cmlidXRlKG5hbWUpKTtcbiAgICAgICAgfVxuICAgICAgfVxuICAgIH1cblxuICAgIGNvbnN0IHRhcmdldEF0dHJzID0gdGFyZ2V0LmF0dHJpYnV0ZXM7XG4gICAgZm9yIChsZXQgaSA9IHRhcmdldEF0dHJzLmxlbmd0aCAtIDE7IGkgPj0gMDsgaS0tKSB7XG4gICAgICBjb25zdCBuYW1lID0gdGFyZ2V0QXR0cnNbaV0ubmFtZTtcbiAgICAgIGlmIChpc0lnbm9yZWQpIHtcbiAgICAgICAgaWYgKFxuICAgICAgICAgIG5hbWUuc3RhcnRzV2l0aChcImRhdGEtXCIpICYmXG4gICAgICAgICAgIXNvdXJjZS5oYXNBdHRyaWJ1dGUobmFtZSkgJiZcbiAgICAgICAgICAhUEhYX1BFTkRJTkdfQVRUUlMuaW5jbHVkZXMobmFtZSlcbiAgICAgICAgKSB7XG4gICAgICAgICAgdGFyZ2V0LnJlbW92ZUF0dHJpYnV0ZShuYW1lKTtcbiAgICAgICAgfVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgaWYgKCFzb3VyY2UuaGFzQXR0cmlidXRlKG5hbWUpKSB7XG4gICAgICAgICAgdGFyZ2V0LnJlbW92ZUF0dHJpYnV0ZShuYW1lKTtcbiAgICAgICAgfVxuICAgICAgfVxuICAgIH1cbiAgfSxcblxuICBtZXJnZUZvY3VzZWRJbnB1dCh0YXJnZXQsIHNvdXJjZSkge1xuICAgIC8vIHNraXAgc2VsZWN0cyBiZWNhdXNlIEZGIHdpbGwgcmVzZXQgaGlnaGxpZ2h0ZWQgaW5kZXggZm9yIGFueSBzZXRBdHRyaWJ1dGVcbiAgICBpZiAoISh0YXJnZXQgaW5zdGFuY2VvZiBIVE1MU2VsZWN0RWxlbWVudCkpIHtcbiAgICAgIERPTS5tZXJnZUF0dHJzKHRhcmdldCwgc291cmNlLCB7IGV4Y2x1ZGU6IFtcInZhbHVlXCJdIH0pO1xuICAgIH1cblxuICAgIGlmIChzb3VyY2UucmVhZE9ubHkpIHtcbiAgICAgIHRhcmdldC5zZXRBdHRyaWJ1dGUoXCJyZWFkb25seVwiLCB0cnVlKTtcbiAgICB9IGVsc2Uge1xuICAgICAgdGFyZ2V0LnJlbW92ZUF0dHJpYnV0ZShcInJlYWRvbmx5XCIpO1xuICAgIH1cbiAgfSxcblxuICBoYXNTZWxlY3Rpb25SYW5nZShlbCkge1xuICAgIHJldHVybiAoXG4gICAgICBlbC5zZXRTZWxlY3Rpb25SYW5nZSAmJiAoZWwudHlwZSA9PT0gXCJ0ZXh0XCIgfHwgZWwudHlwZSA9PT0gXCJ0ZXh0YXJlYVwiKVxuICAgICk7XG4gIH0sXG5cbiAgcmVzdG9yZUZvY3VzKGZvY3VzZWQsIHNlbGVjdGlvblN0YXJ0LCBzZWxlY3Rpb25FbmQpIHtcbiAgICBpZiAoZm9jdXNlZCBpbnN0YW5jZW9mIEhUTUxTZWxlY3RFbGVtZW50KSB7XG4gICAgICBmb2N1c2VkLmZvY3VzKCk7XG4gICAgfVxuICAgIGlmICghRE9NLmlzVGV4dHVhbElucHV0KGZvY3VzZWQpKSB7XG4gICAgICByZXR1cm47XG4gICAgfVxuXG4gICAgY29uc3Qgd2FzRm9jdXNlZCA9IGZvY3VzZWQubWF0Y2hlcyhcIjpmb2N1c1wiKTtcbiAgICBpZiAoIXdhc0ZvY3VzZWQpIHtcbiAgICAgIGZvY3VzZWQuZm9jdXMoKTtcbiAgICB9XG4gICAgaWYgKHRoaXMuaGFzU2VsZWN0aW9uUmFuZ2UoZm9jdXNlZCkpIHtcbiAgICAgIGZvY3VzZWQuc2V0U2VsZWN0aW9uUmFuZ2Uoc2VsZWN0aW9uU3RhcnQsIHNlbGVjdGlvbkVuZCk7XG4gICAgfVxuICB9LFxuXG4gIGlzRm9ybUlucHV0KGVsKSB7XG4gICAgaWYgKGVsLmxvY2FsTmFtZSAmJiBjdXN0b21FbGVtZW50cy5nZXQoZWwubG9jYWxOYW1lKSkge1xuICAgICAgLy8gQ3VzdG9tIEVsZW1lbnRzIG1heSBiZSBmb3JtIGFzc29jaWF0ZWQuIFRoaXMgYWxsb3dzIHRoZW1cbiAgICAgIC8vIHRvIHBhcnRpY2lwYXRlIHdpdGhpbiBhIGZvcm0ncyBsaWZlY3ljbGUsIGluY2x1ZGluZyBmb3JtXG4gICAgICAvLyB2YWxpZGl0eSBhbmQgZm9ybSBzdWJtaXNzaW9ucy5cbiAgICAgIC8vIFRoZSBzcGVjIGZvciBGb3JtIEFzc29jaWF0ZWQgY3VzdG9tIGVsZW1lbnRzIHJlcXVpcmVzIHRoZVxuICAgICAgLy8gY3VzdG9tIGVsZW1lbnQncyBjbGFzcyB0byBjb250YWluIGEgc3RhdGljIGJvb2xlYW4gdmFsdWUgb2YgYGZvcm1Bc3NvY2lhdGVkYFxuICAgICAgLy8gd2hpY2ggaWRlbnRpZmllcyB0aGlzIGNsYXNzIGFzIGFsbG93ZWQgdG8gYXNzb2NpYXRlIHRvIGEgZm9ybS5cbiAgICAgIC8vIFNlZSBodHRwczovL2h0bWwuc3BlYy53aGF0d2cub3JnL2Rldi9jdXN0b20tZWxlbWVudHMuaHRtbCNjdXN0b20tZWxlbWVudHMtZmFjZS1leGFtcGxlXG4gICAgICAvLyBmb3IgZGV0YWlscy5cbiAgICAgIHJldHVybiBjdXN0b21FbGVtZW50cy5nZXQoZWwubG9jYWxOYW1lKVtgZm9ybUFzc29jaWF0ZWRgXTtcbiAgICB9XG5cbiAgICByZXR1cm4gKFxuICAgICAgL14oPzppbnB1dHxzZWxlY3R8dGV4dGFyZWEpJC9pLnRlc3QoZWwudGFnTmFtZSkgJiYgZWwudHlwZSAhPT0gXCJidXR0b25cIlxuICAgICk7XG4gIH0sXG5cbiAgc3luY0F0dHJzVG9Qcm9wcyhlbCkge1xuICAgIGlmIChcbiAgICAgIGVsIGluc3RhbmNlb2YgSFRNTElucHV0RWxlbWVudCAmJlxuICAgICAgQ0hFQ0tBQkxFX0lOUFVUUy5pbmRleE9mKGVsLnR5cGUudG9Mb2NhbGVMb3dlckNhc2UoKSkgPj0gMFxuICAgICkge1xuICAgICAgZWwuY2hlY2tlZCA9IGVsLmdldEF0dHJpYnV0ZShcImNoZWNrZWRcIikgIT09IG51bGw7XG4gICAgfVxuICB9LFxuXG4gIGlzVGV4dHVhbElucHV0KGVsKSB7XG4gICAgcmV0dXJuIEZPQ1VTQUJMRV9JTlBVVFMuaW5kZXhPZihlbC50eXBlKSA+PSAwO1xuICB9LFxuXG4gIGlzTm93VHJpZ2dlckZvcm1FeHRlcm5hbChlbCwgcGh4VHJpZ2dlckV4dGVybmFsKSB7XG4gICAgcmV0dXJuIChcbiAgICAgIGVsLmdldEF0dHJpYnV0ZSAmJlxuICAgICAgZWwuZ2V0QXR0cmlidXRlKHBoeFRyaWdnZXJFeHRlcm5hbCkgIT09IG51bGwgJiZcbiAgICAgIGRvY3VtZW50LmJvZHkuY29udGFpbnMoZWwpXG4gICAgKTtcbiAgfSxcblxuICBjbGVhbkNoaWxkTm9kZXMoY29udGFpbmVyLCBwaHhVcGRhdGUpIHtcbiAgICBpZiAoXG4gICAgICBET00uaXNQaHhVcGRhdGUoY29udGFpbmVyLCBwaHhVcGRhdGUsIFtcImFwcGVuZFwiLCBcInByZXBlbmRcIiwgUEhYX1NUUkVBTV0pXG4gICAgKSB7XG4gICAgICBjb25zdCB0b1JlbW92ZSA9IFtdO1xuICAgICAgY29udGFpbmVyLmNoaWxkTm9kZXMuZm9yRWFjaCgoY2hpbGROb2RlKSA9PiB7XG4gICAgICAgIGlmICghY2hpbGROb2RlLmlkKSB7XG4gICAgICAgICAgLy8gU2tpcCB3YXJuaW5nIGlmIGl0J3MgYW4gZW1wdHkgdGV4dCBub2RlIChlLmcuIGEgbmV3LWxpbmUpXG4gICAgICAgICAgY29uc3QgaXNFbXB0eVRleHROb2RlID1cbiAgICAgICAgICAgIGNoaWxkTm9kZS5ub2RlVHlwZSA9PT0gTm9kZS5URVhUX05PREUgJiZcbiAgICAgICAgICAgIGNoaWxkTm9kZS5ub2RlVmFsdWUudHJpbSgpID09PSBcIlwiO1xuICAgICAgICAgIGlmICghaXNFbXB0eVRleHROb2RlICYmIGNoaWxkTm9kZS5ub2RlVHlwZSAhPT0gTm9kZS5DT01NRU5UX05PREUpIHtcbiAgICAgICAgICAgIGxvZ0Vycm9yKFxuICAgICAgICAgICAgICBcIm9ubHkgSFRNTCBlbGVtZW50IHRhZ3Mgd2l0aCBhbiBpZCBhcmUgYWxsb3dlZCBpbnNpZGUgY29udGFpbmVycyB3aXRoIHBoeC11cGRhdGUuXFxuXFxuXCIgK1xuICAgICAgICAgICAgICAgIGByZW1vdmluZyBpbGxlZ2FsIG5vZGU6IFwiJHsoY2hpbGROb2RlLm91dGVySFRNTCB8fCBjaGlsZE5vZGUubm9kZVZhbHVlKS50cmltKCl9XCJcXG5cXG5gLFxuICAgICAgICAgICAgKTtcbiAgICAgICAgICB9XG4gICAgICAgICAgdG9SZW1vdmUucHVzaChjaGlsZE5vZGUpO1xuICAgICAgICB9XG4gICAgICB9KTtcbiAgICAgIHRvUmVtb3ZlLmZvckVhY2goKGNoaWxkTm9kZSkgPT4gY2hpbGROb2RlLnJlbW92ZSgpKTtcbiAgICB9XG4gIH0sXG5cbiAgcmVwbGFjZVJvb3RDb250YWluZXIoY29udGFpbmVyLCB0YWdOYW1lLCBhdHRycykge1xuICAgIGNvbnN0IHJldGFpbmVkQXR0cnMgPSBuZXcgU2V0KFtcbiAgICAgIFwiaWRcIixcbiAgICAgIFBIWF9TRVNTSU9OLFxuICAgICAgUEhYX1NUQVRJQyxcbiAgICAgIFBIWF9NQUlOLFxuICAgICAgUEhYX1JPT1RfSUQsXG4gICAgXSk7XG4gICAgaWYgKGNvbnRhaW5lci50YWdOYW1lLnRvTG93ZXJDYXNlKCkgPT09IHRhZ05hbWUudG9Mb3dlckNhc2UoKSkge1xuICAgICAgQXJyYXkuZnJvbShjb250YWluZXIuYXR0cmlidXRlcylcbiAgICAgICAgLmZpbHRlcigoYXR0cikgPT4gIXJldGFpbmVkQXR0cnMuaGFzKGF0dHIubmFtZS50b0xvd2VyQ2FzZSgpKSlcbiAgICAgICAgLmZvckVhY2goKGF0dHIpID0+IGNvbnRhaW5lci5yZW1vdmVBdHRyaWJ1dGUoYXR0ci5uYW1lKSk7XG5cbiAgICAgIE9iamVjdC5rZXlzKGF0dHJzKVxuICAgICAgICAuZmlsdGVyKChuYW1lKSA9PiAhcmV0YWluZWRBdHRycy5oYXMobmFtZS50b0xvd2VyQ2FzZSgpKSlcbiAgICAgICAgLmZvckVhY2goKGF0dHIpID0+IGNvbnRhaW5lci5zZXRBdHRyaWJ1dGUoYXR0ciwgYXR0cnNbYXR0cl0pKTtcblxuICAgICAgcmV0dXJuIGNvbnRhaW5lcjtcbiAgICB9IGVsc2Uge1xuICAgICAgY29uc3QgbmV3Q29udGFpbmVyID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCh0YWdOYW1lKTtcbiAgICAgIE9iamVjdC5rZXlzKGF0dHJzKS5mb3JFYWNoKChhdHRyKSA9PlxuICAgICAgICBuZXdDb250YWluZXIuc2V0QXR0cmlidXRlKGF0dHIsIGF0dHJzW2F0dHJdKSxcbiAgICAgICk7XG4gICAgICByZXRhaW5lZEF0dHJzLmZvckVhY2goKGF0dHIpID0+XG4gICAgICAgIG5ld0NvbnRhaW5lci5zZXRBdHRyaWJ1dGUoYXR0ciwgY29udGFpbmVyLmdldEF0dHJpYnV0ZShhdHRyKSksXG4gICAgICApO1xuICAgICAgbmV3Q29udGFpbmVyLmlubmVySFRNTCA9IGNvbnRhaW5lci5pbm5lckhUTUw7XG4gICAgICBjb250YWluZXIucmVwbGFjZVdpdGgobmV3Q29udGFpbmVyKTtcbiAgICAgIHJldHVybiBuZXdDb250YWluZXI7XG4gICAgfVxuICB9LFxuXG4gIGdldFN0aWNreShlbCwgbmFtZSwgZGVmYXVsdFZhbCkge1xuICAgIGNvbnN0IG9wID0gKERPTS5wcml2YXRlKGVsLCBcInN0aWNreVwiKSB8fCBbXSkuZmluZChcbiAgICAgIChbZXhpc3RpbmdOYW1lXSkgPT4gbmFtZSA9PT0gZXhpc3RpbmdOYW1lLFxuICAgICk7XG4gICAgaWYgKG9wKSB7XG4gICAgICBjb25zdCBbX25hbWUsIF9vcCwgc3Rhc2hlZFJlc3VsdF0gPSBvcDtcbiAgICAgIHJldHVybiBzdGFzaGVkUmVzdWx0O1xuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gdHlwZW9mIGRlZmF1bHRWYWwgPT09IFwiZnVuY3Rpb25cIiA/IGRlZmF1bHRWYWwoKSA6IGRlZmF1bHRWYWw7XG4gICAgfVxuICB9LFxuXG4gIGRlbGV0ZVN0aWNreShlbCwgbmFtZSkge1xuICAgIHRoaXMudXBkYXRlUHJpdmF0ZShlbCwgXCJzdGlja3lcIiwgW10sIChvcHMpID0+IHtcbiAgICAgIHJldHVybiBvcHMuZmlsdGVyKChbZXhpc3RpbmdOYW1lLCBfXSkgPT4gZXhpc3RpbmdOYW1lICE9PSBuYW1lKTtcbiAgICB9KTtcbiAgfSxcblxuICBwdXRTdGlja3koZWwsIG5hbWUsIG9wKSB7XG4gICAgY29uc3Qgc3Rhc2hlZFJlc3VsdCA9IG9wKGVsKTtcbiAgICB0aGlzLnVwZGF0ZVByaXZhdGUoZWwsIFwic3RpY2t5XCIsIFtdLCAob3BzKSA9PiB7XG4gICAgICBjb25zdCBleGlzdGluZ0luZGV4ID0gb3BzLmZpbmRJbmRleChcbiAgICAgICAgKFtleGlzdGluZ05hbWVdKSA9PiBuYW1lID09PSBleGlzdGluZ05hbWUsXG4gICAgICApO1xuICAgICAgaWYgKGV4aXN0aW5nSW5kZXggPj0gMCkge1xuICAgICAgICBvcHNbZXhpc3RpbmdJbmRleF0gPSBbbmFtZSwgb3AsIHN0YXNoZWRSZXN1bHRdO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgb3BzLnB1c2goW25hbWUsIG9wLCBzdGFzaGVkUmVzdWx0XSk7XG4gICAgICB9XG4gICAgICByZXR1cm4gb3BzO1xuICAgIH0pO1xuICB9LFxuXG4gIGFwcGx5U3RpY2t5T3BlcmF0aW9ucyhlbCkge1xuICAgIGNvbnN0IG9wcyA9IERPTS5wcml2YXRlKGVsLCBcInN0aWNreVwiKTtcbiAgICBpZiAoIW9wcykge1xuICAgICAgcmV0dXJuO1xuICAgIH1cblxuICAgIG9wcy5mb3JFYWNoKChbbmFtZSwgb3AsIF9zdGFzaGVkXSkgPT4gdGhpcy5wdXRTdGlja3koZWwsIG5hbWUsIG9wKSk7XG4gIH0sXG5cbiAgaXNMb2NrZWQoZWwpIHtcbiAgICByZXR1cm4gZWwuaGFzQXR0cmlidXRlICYmIGVsLmhhc0F0dHJpYnV0ZShQSFhfUkVGX0xPQ0spO1xuICB9LFxufTtcblxuZXhwb3J0IGRlZmF1bHQgRE9NO1xuIiwgImltcG9ydCB7XG4gIFBIWF9BQ1RJVkVfRU5UUllfUkVGUyxcbiAgUEhYX0xJVkVfRklMRV9VUERBVEVELFxuICBQSFhfUFJFRkxJR0hURURfUkVGUyxcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCI7XG5cbmltcG9ydCB7IGNoYW5uZWxVcGxvYWRlciwgbG9nRXJyb3IgfSBmcm9tIFwiLi91dGlsc1wiO1xuXG5pbXBvcnQgTGl2ZVVwbG9hZGVyIGZyb20gXCIuL2xpdmVfdXBsb2FkZXJcIjtcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgVXBsb2FkRW50cnkge1xuICBzdGF0aWMgaXNBY3RpdmUoZmlsZUVsLCBmaWxlKSB7XG4gICAgY29uc3QgaXNOZXcgPSBmaWxlLl9waHhSZWYgPT09IHVuZGVmaW5lZDtcbiAgICBjb25zdCBhY3RpdmVSZWZzID0gZmlsZUVsLmdldEF0dHJpYnV0ZShQSFhfQUNUSVZFX0VOVFJZX1JFRlMpLnNwbGl0KFwiLFwiKTtcbiAgICBjb25zdCBpc0FjdGl2ZSA9IGFjdGl2ZVJlZnMuaW5kZXhPZihMaXZlVXBsb2FkZXIuZ2VuRmlsZVJlZihmaWxlKSkgPj0gMDtcbiAgICByZXR1cm4gZmlsZS5zaXplID4gMCAmJiAoaXNOZXcgfHwgaXNBY3RpdmUpO1xuICB9XG5cbiAgc3RhdGljIGlzUHJlZmxpZ2h0ZWQoZmlsZUVsLCBmaWxlKSB7XG4gICAgY29uc3QgcHJlZmxpZ2h0ZWRSZWZzID0gZmlsZUVsXG4gICAgICAuZ2V0QXR0cmlidXRlKFBIWF9QUkVGTElHSFRFRF9SRUZTKVxuICAgICAgLnNwbGl0KFwiLFwiKTtcbiAgICBjb25zdCBpc1ByZWZsaWdodGVkID1cbiAgICAgIHByZWZsaWdodGVkUmVmcy5pbmRleE9mKExpdmVVcGxvYWRlci5nZW5GaWxlUmVmKGZpbGUpKSA+PSAwO1xuICAgIHJldHVybiBpc1ByZWZsaWdodGVkICYmIHRoaXMuaXNBY3RpdmUoZmlsZUVsLCBmaWxlKTtcbiAgfVxuXG4gIHN0YXRpYyBpc1ByZWZsaWdodEluUHJvZ3Jlc3MoZmlsZSkge1xuICAgIHJldHVybiBmaWxlLl9wcmVmbGlnaHRJblByb2dyZXNzID09PSB0cnVlO1xuICB9XG5cbiAgc3RhdGljIG1hcmtQcmVmbGlnaHRJblByb2dyZXNzKGZpbGUpIHtcbiAgICBmaWxlLl9wcmVmbGlnaHRJblByb2dyZXNzID0gdHJ1ZTtcbiAgfVxuXG4gIGNvbnN0cnVjdG9yKGZpbGVFbCwgZmlsZSwgdmlldywgYXV0b1VwbG9hZCkge1xuICAgIHRoaXMucmVmID0gTGl2ZVVwbG9hZGVyLmdlbkZpbGVSZWYoZmlsZSk7XG4gICAgdGhpcy5maWxlRWwgPSBmaWxlRWw7XG4gICAgdGhpcy5maWxlID0gZmlsZTtcbiAgICB0aGlzLnZpZXcgPSB2aWV3O1xuICAgIHRoaXMubWV0YSA9IG51bGw7XG4gICAgdGhpcy5faXNDYW5jZWxsZWQgPSBmYWxzZTtcbiAgICB0aGlzLl9pc0RvbmUgPSBmYWxzZTtcbiAgICB0aGlzLl9wcm9ncmVzcyA9IDA7XG4gICAgdGhpcy5fbGFzdFByb2dyZXNzU2VudCA9IC0xO1xuICAgIHRoaXMuX29uRG9uZSA9IGZ1bmN0aW9uICgpIHt9O1xuICAgIHRoaXMuX29uRWxVcGRhdGVkID0gdGhpcy5vbkVsVXBkYXRlZC5iaW5kKHRoaXMpO1xuICAgIHRoaXMuZmlsZUVsLmFkZEV2ZW50TGlzdGVuZXIoUEhYX0xJVkVfRklMRV9VUERBVEVELCB0aGlzLl9vbkVsVXBkYXRlZCk7XG4gICAgdGhpcy5hdXRvVXBsb2FkID0gYXV0b1VwbG9hZDtcbiAgfVxuXG4gIG1ldGFkYXRhKCkge1xuICAgIHJldHVybiB0aGlzLm1ldGE7XG4gIH1cblxuICBwcm9ncmVzcyhwcm9ncmVzcykge1xuICAgIHRoaXMuX3Byb2dyZXNzID0gTWF0aC5mbG9vcihwcm9ncmVzcyk7XG4gICAgaWYgKHRoaXMuX3Byb2dyZXNzID4gdGhpcy5fbGFzdFByb2dyZXNzU2VudCkge1xuICAgICAgaWYgKHRoaXMuX3Byb2dyZXNzID49IDEwMCkge1xuICAgICAgICB0aGlzLl9wcm9ncmVzcyA9IDEwMDtcbiAgICAgICAgdGhpcy5fbGFzdFByb2dyZXNzU2VudCA9IDEwMDtcbiAgICAgICAgdGhpcy5faXNEb25lID0gdHJ1ZTtcbiAgICAgICAgdGhpcy52aWV3LnB1c2hGaWxlUHJvZ3Jlc3ModGhpcy5maWxlRWwsIHRoaXMucmVmLCAxMDAsICgpID0+IHtcbiAgICAgICAgICBMaXZlVXBsb2FkZXIudW50cmFja0ZpbGUodGhpcy5maWxlRWwsIHRoaXMuZmlsZSk7XG4gICAgICAgICAgdGhpcy5fb25Eb25lKCk7XG4gICAgICAgIH0pO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdGhpcy5fbGFzdFByb2dyZXNzU2VudCA9IHRoaXMuX3Byb2dyZXNzO1xuICAgICAgICB0aGlzLnZpZXcucHVzaEZpbGVQcm9ncmVzcyh0aGlzLmZpbGVFbCwgdGhpcy5yZWYsIHRoaXMuX3Byb2dyZXNzKTtcbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICBpc0NhbmNlbGxlZCgpIHtcbiAgICByZXR1cm4gdGhpcy5faXNDYW5jZWxsZWQ7XG4gIH1cblxuICBjYW5jZWwoKSB7XG4gICAgdGhpcy5maWxlLl9wcmVmbGlnaHRJblByb2dyZXNzID0gZmFsc2U7XG4gICAgdGhpcy5faXNDYW5jZWxsZWQgPSB0cnVlO1xuICAgIHRoaXMuX2lzRG9uZSA9IHRydWU7XG4gICAgdGhpcy5fb25Eb25lKCk7XG4gIH1cblxuICBpc0RvbmUoKSB7XG4gICAgcmV0dXJuIHRoaXMuX2lzRG9uZTtcbiAgfVxuXG4gIGVycm9yKHJlYXNvbiA9IFwiZmFpbGVkXCIpIHtcbiAgICB0aGlzLmZpbGVFbC5yZW1vdmVFdmVudExpc3RlbmVyKFBIWF9MSVZFX0ZJTEVfVVBEQVRFRCwgdGhpcy5fb25FbFVwZGF0ZWQpO1xuICAgIHRoaXMudmlldy5wdXNoRmlsZVByb2dyZXNzKHRoaXMuZmlsZUVsLCB0aGlzLnJlZiwgeyBlcnJvcjogcmVhc29uIH0pO1xuICAgIGlmICghdGhpcy5pc0F1dG9VcGxvYWQoKSkge1xuICAgICAgTGl2ZVVwbG9hZGVyLmNsZWFyRmlsZXModGhpcy5maWxlRWwpO1xuICAgIH1cbiAgfVxuXG4gIGlzQXV0b1VwbG9hZCgpIHtcbiAgICByZXR1cm4gdGhpcy5hdXRvVXBsb2FkO1xuICB9XG5cbiAgLy9wcml2YXRlXG5cbiAgb25Eb25lKGNhbGxiYWNrKSB7XG4gICAgdGhpcy5fb25Eb25lID0gKCkgPT4ge1xuICAgICAgdGhpcy5maWxlRWwucmVtb3ZlRXZlbnRMaXN0ZW5lcihQSFhfTElWRV9GSUxFX1VQREFURUQsIHRoaXMuX29uRWxVcGRhdGVkKTtcbiAgICAgIGNhbGxiYWNrKCk7XG4gICAgfTtcbiAgfVxuXG4gIG9uRWxVcGRhdGVkKCkge1xuICAgIGNvbnN0IGFjdGl2ZVJlZnMgPSB0aGlzLmZpbGVFbFxuICAgICAgLmdldEF0dHJpYnV0ZShQSFhfQUNUSVZFX0VOVFJZX1JFRlMpXG4gICAgICAuc3BsaXQoXCIsXCIpO1xuICAgIGlmIChhY3RpdmVSZWZzLmluZGV4T2YodGhpcy5yZWYpID09PSAtMSkge1xuICAgICAgTGl2ZVVwbG9hZGVyLnVudHJhY2tGaWxlKHRoaXMuZmlsZUVsLCB0aGlzLmZpbGUpO1xuICAgICAgdGhpcy5jYW5jZWwoKTtcbiAgICB9XG4gIH1cblxuICB0b1ByZWZsaWdodFBheWxvYWQoKSB7XG4gICAgcmV0dXJuIHtcbiAgICAgIGxhc3RfbW9kaWZpZWQ6IHRoaXMuZmlsZS5sYXN0TW9kaWZpZWQsXG4gICAgICBuYW1lOiB0aGlzLmZpbGUubmFtZSxcbiAgICAgIHJlbGF0aXZlX3BhdGg6IHRoaXMuZmlsZS53ZWJraXRSZWxhdGl2ZVBhdGgsXG4gICAgICBzaXplOiB0aGlzLmZpbGUuc2l6ZSxcbiAgICAgIHR5cGU6IHRoaXMuZmlsZS50eXBlLFxuICAgICAgcmVmOiB0aGlzLnJlZixcbiAgICAgIG1ldGE6IHR5cGVvZiB0aGlzLmZpbGUubWV0YSA9PT0gXCJmdW5jdGlvblwiID8gdGhpcy5maWxlLm1ldGEoKSA6IHVuZGVmaW5lZCxcbiAgICB9O1xuICB9XG5cbiAgdXBsb2FkZXIodXBsb2FkZXJzKSB7XG4gICAgaWYgKHRoaXMubWV0YS51cGxvYWRlcikge1xuICAgICAgY29uc3QgY2FsbGJhY2sgPVxuICAgICAgICB1cGxvYWRlcnNbdGhpcy5tZXRhLnVwbG9hZGVyXSB8fFxuICAgICAgICBsb2dFcnJvcihgbm8gdXBsb2FkZXIgY29uZmlndXJlZCBmb3IgJHt0aGlzLm1ldGEudXBsb2FkZXJ9YCk7XG4gICAgICByZXR1cm4geyBuYW1lOiB0aGlzLm1ldGEudXBsb2FkZXIsIGNhbGxiYWNrOiBjYWxsYmFjayB9O1xuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4geyBuYW1lOiBcImNoYW5uZWxcIiwgY2FsbGJhY2s6IGNoYW5uZWxVcGxvYWRlciB9O1xuICAgIH1cbiAgfVxuXG4gIHppcFBvc3RGbGlnaHQocmVzcCkge1xuICAgIHRoaXMubWV0YSA9IHJlc3AuZW50cmllc1t0aGlzLnJlZl07XG4gICAgaWYgKCF0aGlzLm1ldGEpIHtcbiAgICAgIGxvZ0Vycm9yKGBubyBwcmVmbGlnaHQgdXBsb2FkIHJlc3BvbnNlIHJldHVybmVkIHdpdGggcmVmICR7dGhpcy5yZWZ9YCwge1xuICAgICAgICBpbnB1dDogdGhpcy5maWxlRWwsXG4gICAgICAgIHJlc3BvbnNlOiByZXNwLFxuICAgICAgfSk7XG4gICAgfVxuICB9XG59XG4iLCAiaW1wb3J0IHtcbiAgUEhYX0RPTkVfUkVGUyxcbiAgUEhYX1BSRUZMSUdIVEVEX1JFRlMsXG4gIFBIWF9VUExPQURfUkVGLFxufSBmcm9tIFwiLi9jb25zdGFudHNcIjtcblxuaW1wb3J0IHt9IGZyb20gXCIuL3V0aWxzXCI7XG5cbmltcG9ydCBET00gZnJvbSBcIi4vZG9tXCI7XG5pbXBvcnQgVXBsb2FkRW50cnkgZnJvbSBcIi4vdXBsb2FkX2VudHJ5XCI7XG5cbmxldCBsaXZlVXBsb2FkZXJGaWxlUmVmID0gMDtcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgTGl2ZVVwbG9hZGVyIHtcbiAgc3RhdGljIGdlbkZpbGVSZWYoZmlsZSkge1xuICAgIGNvbnN0IHJlZiA9IGZpbGUuX3BoeFJlZjtcbiAgICBpZiAocmVmICE9PSB1bmRlZmluZWQpIHtcbiAgICAgIHJldHVybiByZWY7XG4gICAgfSBlbHNlIHtcbiAgICAgIGZpbGUuX3BoeFJlZiA9IChsaXZlVXBsb2FkZXJGaWxlUmVmKyspLnRvU3RyaW5nKCk7XG4gICAgICByZXR1cm4gZmlsZS5fcGh4UmVmO1xuICAgIH1cbiAgfVxuXG4gIHN0YXRpYyBnZXRFbnRyeURhdGFVUkwoaW5wdXRFbCwgcmVmLCBjYWxsYmFjaykge1xuICAgIGNvbnN0IGZpbGUgPSB0aGlzLmFjdGl2ZUZpbGVzKGlucHV0RWwpLmZpbmQoXG4gICAgICAoZmlsZSkgPT4gdGhpcy5nZW5GaWxlUmVmKGZpbGUpID09PSByZWYsXG4gICAgKTtcbiAgICBjYWxsYmFjayhVUkwuY3JlYXRlT2JqZWN0VVJMKGZpbGUpKTtcbiAgfVxuXG4gIHN0YXRpYyBoYXNVcGxvYWRzSW5Qcm9ncmVzcyhmb3JtRWwpIHtcbiAgICBsZXQgYWN0aXZlID0gMDtcbiAgICBET00uZmluZFVwbG9hZElucHV0cyhmb3JtRWwpLmZvckVhY2goKGlucHV0KSA9PiB7XG4gICAgICBpZiAoXG4gICAgICAgIGlucHV0LmdldEF0dHJpYnV0ZShQSFhfUFJFRkxJR0hURURfUkVGUykgIT09XG4gICAgICAgIGlucHV0LmdldEF0dHJpYnV0ZShQSFhfRE9ORV9SRUZTKVxuICAgICAgKSB7XG4gICAgICAgIGFjdGl2ZSsrO1xuICAgICAgfVxuICAgIH0pO1xuICAgIHJldHVybiBhY3RpdmUgPiAwO1xuICB9XG5cbiAgc3RhdGljIHNlcmlhbGl6ZVVwbG9hZHMoaW5wdXRFbCkge1xuICAgIGNvbnN0IGZpbGVzID0gdGhpcy5hY3RpdmVGaWxlcyhpbnB1dEVsKTtcbiAgICBjb25zdCBmaWxlRGF0YSA9IHt9O1xuICAgIGZpbGVzLmZvckVhY2goKGZpbGUpID0+IHtcbiAgICAgIGNvbnN0IGVudHJ5ID0geyBwYXRoOiBpbnB1dEVsLm5hbWUgfTtcbiAgICAgIGNvbnN0IHVwbG9hZFJlZiA9IGlucHV0RWwuZ2V0QXR0cmlidXRlKFBIWF9VUExPQURfUkVGKTtcbiAgICAgIGZpbGVEYXRhW3VwbG9hZFJlZl0gPSBmaWxlRGF0YVt1cGxvYWRSZWZdIHx8IFtdO1xuICAgICAgZW50cnkucmVmID0gdGhpcy5nZW5GaWxlUmVmKGZpbGUpO1xuICAgICAgZW50cnkubGFzdF9tb2RpZmllZCA9IGZpbGUubGFzdE1vZGlmaWVkO1xuICAgICAgZW50cnkubmFtZSA9IGZpbGUubmFtZSB8fCBlbnRyeS5yZWY7XG4gICAgICBlbnRyeS5yZWxhdGl2ZV9wYXRoID0gZmlsZS53ZWJraXRSZWxhdGl2ZVBhdGg7XG4gICAgICBlbnRyeS50eXBlID0gZmlsZS50eXBlO1xuICAgICAgZW50cnkuc2l6ZSA9IGZpbGUuc2l6ZTtcbiAgICAgIGlmICh0eXBlb2YgZmlsZS5tZXRhID09PSBcImZ1bmN0aW9uXCIpIHtcbiAgICAgICAgZW50cnkubWV0YSA9IGZpbGUubWV0YSgpO1xuICAgICAgfVxuICAgICAgZmlsZURhdGFbdXBsb2FkUmVmXS5wdXNoKGVudHJ5KTtcbiAgICB9KTtcbiAgICByZXR1cm4gZmlsZURhdGE7XG4gIH1cblxuICBzdGF0aWMgY2xlYXJGaWxlcyhpbnB1dEVsKSB7XG4gICAgaW5wdXRFbC52YWx1ZSA9IG51bGw7XG4gICAgaW5wdXRFbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1VQTE9BRF9SRUYpO1xuICAgIERPTS5wdXRQcml2YXRlKGlucHV0RWwsIFwiZmlsZXNcIiwgW10pO1xuICB9XG5cbiAgc3RhdGljIHVudHJhY2tGaWxlKGlucHV0RWwsIGZpbGUpIHtcbiAgICBET00ucHV0UHJpdmF0ZShcbiAgICAgIGlucHV0RWwsXG4gICAgICBcImZpbGVzXCIsXG4gICAgICBET00ucHJpdmF0ZShpbnB1dEVsLCBcImZpbGVzXCIpLmZpbHRlcigoZikgPT4gIU9iamVjdC5pcyhmLCBmaWxlKSksXG4gICAgKTtcbiAgfVxuXG4gIC8qKlxuICAgKiBAcGFyYW0ge0hUTUxJbnB1dEVsZW1lbnR9IGlucHV0RWxcbiAgICogQHBhcmFtIHtBcnJheTxGaWxlfEJsb2I+fSBmaWxlc1xuICAgKiBAcGFyYW0ge0RhdGFUcmFuc2Zlcn0gW2RhdGFUcmFuc2Zlcl1cbiAgICovXG4gIHN0YXRpYyB0cmFja0ZpbGVzKGlucHV0RWwsIGZpbGVzLCBkYXRhVHJhbnNmZXIpIHtcbiAgICBpZiAoaW5wdXRFbC5nZXRBdHRyaWJ1dGUoXCJtdWx0aXBsZVwiKSAhPT0gbnVsbCkge1xuICAgICAgY29uc3QgbmV3RmlsZXMgPSBmaWxlcy5maWx0ZXIoXG4gICAgICAgIChmaWxlKSA9PiAhdGhpcy5hY3RpdmVGaWxlcyhpbnB1dEVsKS5maW5kKChmKSA9PiBPYmplY3QuaXMoZiwgZmlsZSkpLFxuICAgICAgKTtcbiAgICAgIERPTS51cGRhdGVQcml2YXRlKGlucHV0RWwsIFwiZmlsZXNcIiwgW10sIChleGlzdGluZykgPT5cbiAgICAgICAgZXhpc3RpbmcuY29uY2F0KG5ld0ZpbGVzKSxcbiAgICAgICk7XG4gICAgICBpbnB1dEVsLnZhbHVlID0gbnVsbDtcbiAgICB9IGVsc2Uge1xuICAgICAgLy8gUmVzZXQgaW5wdXRFbCBmaWxlcyB0byBhbGlnbiBvdXRwdXQgd2l0aCBwcm9ncmFtbWF0aWMgY2hhbmdlcyAoaS5lLiBkcmFnIGFuZCBkcm9wKVxuICAgICAgaWYgKGRhdGFUcmFuc2ZlciAmJiBkYXRhVHJhbnNmZXIuZmlsZXMubGVuZ3RoID4gMCkge1xuICAgICAgICBpbnB1dEVsLmZpbGVzID0gZGF0YVRyYW5zZmVyLmZpbGVzO1xuICAgICAgfVxuICAgICAgRE9NLnB1dFByaXZhdGUoaW5wdXRFbCwgXCJmaWxlc1wiLCBmaWxlcyk7XG4gICAgfVxuICB9XG5cbiAgc3RhdGljIGFjdGl2ZUZpbGVJbnB1dHMoZm9ybUVsKSB7XG4gICAgY29uc3QgZmlsZUlucHV0cyA9IERPTS5maW5kVXBsb2FkSW5wdXRzKGZvcm1FbCk7XG4gICAgcmV0dXJuIEFycmF5LmZyb20oZmlsZUlucHV0cykuZmlsdGVyKFxuICAgICAgKGVsKSA9PiBlbC5maWxlcyAmJiB0aGlzLmFjdGl2ZUZpbGVzKGVsKS5sZW5ndGggPiAwLFxuICAgICk7XG4gIH1cblxuICBzdGF0aWMgYWN0aXZlRmlsZXMoaW5wdXQpIHtcbiAgICByZXR1cm4gKERPTS5wcml2YXRlKGlucHV0LCBcImZpbGVzXCIpIHx8IFtdKS5maWx0ZXIoKGYpID0+XG4gICAgICBVcGxvYWRFbnRyeS5pc0FjdGl2ZShpbnB1dCwgZiksXG4gICAgKTtcbiAgfVxuXG4gIHN0YXRpYyBpbnB1dHNBd2FpdGluZ1ByZWZsaWdodChmb3JtRWwpIHtcbiAgICBjb25zdCBmaWxlSW5wdXRzID0gRE9NLmZpbmRVcGxvYWRJbnB1dHMoZm9ybUVsKTtcbiAgICByZXR1cm4gQXJyYXkuZnJvbShmaWxlSW5wdXRzKS5maWx0ZXIoXG4gICAgICAoaW5wdXQpID0+IHRoaXMuZmlsZXNBd2FpdGluZ1ByZWZsaWdodChpbnB1dCkubGVuZ3RoID4gMCxcbiAgICApO1xuICB9XG5cbiAgc3RhdGljIGZpbGVzQXdhaXRpbmdQcmVmbGlnaHQoaW5wdXQpIHtcbiAgICByZXR1cm4gdGhpcy5hY3RpdmVGaWxlcyhpbnB1dCkuZmlsdGVyKFxuICAgICAgKGYpID0+XG4gICAgICAgICFVcGxvYWRFbnRyeS5pc1ByZWZsaWdodGVkKGlucHV0LCBmKSAmJlxuICAgICAgICAhVXBsb2FkRW50cnkuaXNQcmVmbGlnaHRJblByb2dyZXNzKGYpLFxuICAgICk7XG4gIH1cblxuICBzdGF0aWMgbWFya1ByZWZsaWdodEluUHJvZ3Jlc3MoZW50cmllcykge1xuICAgIGVudHJpZXMuZm9yRWFjaCgoZW50cnkpID0+IFVwbG9hZEVudHJ5Lm1hcmtQcmVmbGlnaHRJblByb2dyZXNzKGVudHJ5LmZpbGUpKTtcbiAgfVxuXG4gIGNvbnN0cnVjdG9yKGlucHV0RWwsIHZpZXcsIG9uQ29tcGxldGUpIHtcbiAgICB0aGlzLmF1dG9VcGxvYWQgPSBET00uaXNBdXRvVXBsb2FkKGlucHV0RWwpO1xuICAgIHRoaXMudmlldyA9IHZpZXc7XG4gICAgdGhpcy5vbkNvbXBsZXRlID0gb25Db21wbGV0ZTtcbiAgICB0aGlzLl9lbnRyaWVzID0gQXJyYXkuZnJvbShcbiAgICAgIExpdmVVcGxvYWRlci5maWxlc0F3YWl0aW5nUHJlZmxpZ2h0KGlucHV0RWwpIHx8IFtdLFxuICAgICkubWFwKChmaWxlKSA9PiBuZXcgVXBsb2FkRW50cnkoaW5wdXRFbCwgZmlsZSwgdmlldywgdGhpcy5hdXRvVXBsb2FkKSk7XG5cbiAgICAvLyBwcmV2ZW50IHNlbmRpbmcgZHVwbGljYXRlIHByZWZsaWdodCByZXF1ZXN0c1xuICAgIExpdmVVcGxvYWRlci5tYXJrUHJlZmxpZ2h0SW5Qcm9ncmVzcyh0aGlzLl9lbnRyaWVzKTtcblxuICAgIHRoaXMubnVtRW50cmllc0luUHJvZ3Jlc3MgPSB0aGlzLl9lbnRyaWVzLmxlbmd0aDtcbiAgfVxuXG4gIGlzQXV0b1VwbG9hZCgpIHtcbiAgICByZXR1cm4gdGhpcy5hdXRvVXBsb2FkO1xuICB9XG5cbiAgZW50cmllcygpIHtcbiAgICByZXR1cm4gdGhpcy5fZW50cmllcztcbiAgfVxuXG4gIGluaXRBZGFwdGVyVXBsb2FkKHJlc3AsIG9uRXJyb3IsIGxpdmVTb2NrZXQpIHtcbiAgICB0aGlzLl9lbnRyaWVzID0gdGhpcy5fZW50cmllcy5tYXAoKGVudHJ5KSA9PiB7XG4gICAgICBpZiAoZW50cnkuaXNDYW5jZWxsZWQoKSkge1xuICAgICAgICB0aGlzLm51bUVudHJpZXNJblByb2dyZXNzLS07XG4gICAgICAgIGlmICh0aGlzLm51bUVudHJpZXNJblByb2dyZXNzID09PSAwKSB7XG4gICAgICAgICAgdGhpcy5vbkNvbXBsZXRlKCk7XG4gICAgICAgIH1cbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIGVudHJ5LnppcFBvc3RGbGlnaHQocmVzcCk7XG4gICAgICAgIGVudHJ5Lm9uRG9uZSgoKSA9PiB7XG4gICAgICAgICAgdGhpcy5udW1FbnRyaWVzSW5Qcm9ncmVzcy0tO1xuICAgICAgICAgIGlmICh0aGlzLm51bUVudHJpZXNJblByb2dyZXNzID09PSAwKSB7XG4gICAgICAgICAgICB0aGlzLm9uQ29tcGxldGUoKTtcbiAgICAgICAgICB9XG4gICAgICAgIH0pO1xuICAgICAgfVxuICAgICAgcmV0dXJuIGVudHJ5O1xuICAgIH0pO1xuXG4gICAgY29uc3QgZ3JvdXBlZEVudHJpZXMgPSB0aGlzLl9lbnRyaWVzLnJlZHVjZSgoYWNjLCBlbnRyeSkgPT4ge1xuICAgICAgaWYgKCFlbnRyeS5tZXRhKSB7XG4gICAgICAgIHJldHVybiBhY2M7XG4gICAgICB9XG4gICAgICBjb25zdCB7IG5hbWUsIGNhbGxiYWNrIH0gPSBlbnRyeS51cGxvYWRlcihsaXZlU29ja2V0LnVwbG9hZGVycyk7XG4gICAgICBhY2NbbmFtZV0gPSBhY2NbbmFtZV0gfHwgeyBjYWxsYmFjazogY2FsbGJhY2ssIGVudHJpZXM6IFtdIH07XG4gICAgICBhY2NbbmFtZV0uZW50cmllcy5wdXNoKGVudHJ5KTtcbiAgICAgIHJldHVybiBhY2M7XG4gICAgfSwge30pO1xuXG4gICAgZm9yIChjb25zdCBuYW1lIGluIGdyb3VwZWRFbnRyaWVzKSB7XG4gICAgICBjb25zdCB7IGNhbGxiYWNrLCBlbnRyaWVzIH0gPSBncm91cGVkRW50cmllc1tuYW1lXTtcbiAgICAgIGNhbGxiYWNrKGVudHJpZXMsIG9uRXJyb3IsIHJlc3AsIGxpdmVTb2NrZXQpO1xuICAgIH1cbiAgfVxufVxuIiwgImNvbnN0IEFSSUEgPSB7XG4gIGFueU9mKGluc3RhbmNlLCBjbGFzc2VzKSB7XG4gICAgcmV0dXJuIGNsYXNzZXMuZmluZCgobmFtZSkgPT4gaW5zdGFuY2UgaW5zdGFuY2VvZiBuYW1lKTtcbiAgfSxcblxuICBpc0ZvY3VzYWJsZShlbCwgaW50ZXJhY3RpdmVPbmx5KSB7XG4gICAgcmV0dXJuIChcbiAgICAgIChlbCBpbnN0YW5jZW9mIEhUTUxBbmNob3JFbGVtZW50ICYmIGVsLnJlbCAhPT0gXCJpZ25vcmVcIikgfHxcbiAgICAgIChlbCBpbnN0YW5jZW9mIEhUTUxBcmVhRWxlbWVudCAmJiBlbC5ocmVmICE9PSB1bmRlZmluZWQpIHx8XG4gICAgICAoIWVsLmRpc2FibGVkICYmXG4gICAgICAgIHRoaXMuYW55T2YoZWwsIFtcbiAgICAgICAgICBIVE1MSW5wdXRFbGVtZW50LFxuICAgICAgICAgIEhUTUxTZWxlY3RFbGVtZW50LFxuICAgICAgICAgIEhUTUxUZXh0QXJlYUVsZW1lbnQsXG4gICAgICAgICAgSFRNTEJ1dHRvbkVsZW1lbnQsXG4gICAgICAgIF0pKSB8fFxuICAgICAgZWwgaW5zdGFuY2VvZiBIVE1MSUZyYW1lRWxlbWVudCB8fFxuICAgICAgKGVsLnRhYkluZGV4ID49IDAgJiYgZWwuZ2V0QXR0cmlidXRlKFwiYXJpYS1oaWRkZW5cIikgIT09IFwidHJ1ZVwiKSB8fFxuICAgICAgKCFpbnRlcmFjdGl2ZU9ubHkgJiZcbiAgICAgICAgZWwuZ2V0QXR0cmlidXRlKFwidGFiaW5kZXhcIikgIT09IG51bGwgJiZcbiAgICAgICAgZWwuZ2V0QXR0cmlidXRlKFwiYXJpYS1oaWRkZW5cIikgIT09IFwidHJ1ZVwiKVxuICAgICk7XG4gIH0sXG5cbiAgYXR0ZW1wdEZvY3VzKGVsLCBpbnRlcmFjdGl2ZU9ubHkpIHtcbiAgICBpZiAodGhpcy5pc0ZvY3VzYWJsZShlbCwgaW50ZXJhY3RpdmVPbmx5KSkge1xuICAgICAgdHJ5IHtcbiAgICAgICAgZWwuZm9jdXMoKTtcbiAgICAgIH0gY2F0Y2gge1xuICAgICAgICAvLyB0aGF0J3MgZmluZVxuICAgICAgfVxuICAgIH1cbiAgICByZXR1cm4gISFkb2N1bWVudC5hY3RpdmVFbGVtZW50ICYmIGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQuaXNTYW1lTm9kZShlbCk7XG4gIH0sXG5cbiAgZm9jdXNGaXJzdEludGVyYWN0aXZlKGVsKSB7XG4gICAgbGV0IGNoaWxkID0gZWwuZmlyc3RFbGVtZW50Q2hpbGQ7XG4gICAgd2hpbGUgKGNoaWxkKSB7XG4gICAgICBpZiAodGhpcy5hdHRlbXB0Rm9jdXMoY2hpbGQsIHRydWUpIHx8IHRoaXMuZm9jdXNGaXJzdEludGVyYWN0aXZlKGNoaWxkKSkge1xuICAgICAgICByZXR1cm4gdHJ1ZTtcbiAgICAgIH1cbiAgICAgIGNoaWxkID0gY2hpbGQubmV4dEVsZW1lbnRTaWJsaW5nO1xuICAgIH1cbiAgfSxcblxuICBmb2N1c0ZpcnN0KGVsKSB7XG4gICAgbGV0IGNoaWxkID0gZWwuZmlyc3RFbGVtZW50Q2hpbGQ7XG4gICAgd2hpbGUgKGNoaWxkKSB7XG4gICAgICBpZiAodGhpcy5hdHRlbXB0Rm9jdXMoY2hpbGQpIHx8IHRoaXMuZm9jdXNGaXJzdChjaGlsZCkpIHtcbiAgICAgICAgcmV0dXJuIHRydWU7XG4gICAgICB9XG4gICAgICBjaGlsZCA9IGNoaWxkLm5leHRFbGVtZW50U2libGluZztcbiAgICB9XG4gIH0sXG5cbiAgZm9jdXNMYXN0KGVsKSB7XG4gICAgbGV0IGNoaWxkID0gZWwubGFzdEVsZW1lbnRDaGlsZDtcbiAgICB3aGlsZSAoY2hpbGQpIHtcbiAgICAgIGlmICh0aGlzLmF0dGVtcHRGb2N1cyhjaGlsZCkgfHwgdGhpcy5mb2N1c0xhc3QoY2hpbGQpKSB7XG4gICAgICAgIHJldHVybiB0cnVlO1xuICAgICAgfVxuICAgICAgY2hpbGQgPSBjaGlsZC5wcmV2aW91c0VsZW1lbnRTaWJsaW5nO1xuICAgIH1cbiAgfSxcbn07XG5leHBvcnQgZGVmYXVsdCBBUklBO1xuIiwgImltcG9ydCB7XG4gIFBIWF9BQ1RJVkVfRU5UUllfUkVGUyxcbiAgUEhYX0xJVkVfRklMRV9VUERBVEVELFxuICBQSFhfUFJFRkxJR0hURURfUkVGUyxcbiAgUEhYX1VQTE9BRF9SRUYsXG59IGZyb20gXCIuL2NvbnN0YW50c1wiO1xuXG5pbXBvcnQgTGl2ZVVwbG9hZGVyIGZyb20gXCIuL2xpdmVfdXBsb2FkZXJcIjtcbmltcG9ydCBBUklBIGZyb20gXCIuL2FyaWFcIjtcblxuY29uc3QgSG9va3MgPSB7XG4gIExpdmVGaWxlVXBsb2FkOiB7XG4gICAgYWN0aXZlUmVmcygpIHtcbiAgICAgIHJldHVybiB0aGlzLmVsLmdldEF0dHJpYnV0ZShQSFhfQUNUSVZFX0VOVFJZX1JFRlMpO1xuICAgIH0sXG5cbiAgICBwcmVmbGlnaHRlZFJlZnMoKSB7XG4gICAgICByZXR1cm4gdGhpcy5lbC5nZXRBdHRyaWJ1dGUoUEhYX1BSRUZMSUdIVEVEX1JFRlMpO1xuICAgIH0sXG5cbiAgICBtb3VudGVkKCkge1xuICAgICAgdGhpcy5wcmVmbGlnaHRlZFdhcyA9IHRoaXMucHJlZmxpZ2h0ZWRSZWZzKCk7XG4gICAgfSxcblxuICAgIHVwZGF0ZWQoKSB7XG4gICAgICBjb25zdCBuZXdQcmVmbGlnaHRzID0gdGhpcy5wcmVmbGlnaHRlZFJlZnMoKTtcbiAgICAgIGlmICh0aGlzLnByZWZsaWdodGVkV2FzICE9PSBuZXdQcmVmbGlnaHRzKSB7XG4gICAgICAgIHRoaXMucHJlZmxpZ2h0ZWRXYXMgPSBuZXdQcmVmbGlnaHRzO1xuICAgICAgICBpZiAobmV3UHJlZmxpZ2h0cyA9PT0gXCJcIikge1xuICAgICAgICAgIHRoaXMuX192aWV3KCkuY2FuY2VsU3VibWl0KHRoaXMuZWwuZm9ybSk7XG4gICAgICAgIH1cbiAgICAgIH1cblxuICAgICAgaWYgKHRoaXMuYWN0aXZlUmVmcygpID09PSBcIlwiKSB7XG4gICAgICAgIHRoaXMuZWwudmFsdWUgPSBudWxsO1xuICAgICAgfVxuICAgICAgdGhpcy5lbC5kaXNwYXRjaEV2ZW50KG5ldyBDdXN0b21FdmVudChQSFhfTElWRV9GSUxFX1VQREFURUQpKTtcbiAgICB9LFxuICB9LFxuXG4gIExpdmVJbWdQcmV2aWV3OiB7XG4gICAgbW91bnRlZCgpIHtcbiAgICAgIHRoaXMucmVmID0gdGhpcy5lbC5nZXRBdHRyaWJ1dGUoXCJkYXRhLXBoeC1lbnRyeS1yZWZcIik7XG4gICAgICB0aGlzLmlucHV0RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChcbiAgICAgICAgdGhpcy5lbC5nZXRBdHRyaWJ1dGUoUEhYX1VQTE9BRF9SRUYpLFxuICAgICAgKTtcbiAgICAgIExpdmVVcGxvYWRlci5nZXRFbnRyeURhdGFVUkwodGhpcy5pbnB1dEVsLCB0aGlzLnJlZiwgKHVybCkgPT4ge1xuICAgICAgICB0aGlzLnVybCA9IHVybDtcbiAgICAgICAgdGhpcy5lbC5zcmMgPSB1cmw7XG4gICAgICB9KTtcbiAgICB9LFxuICAgIGRlc3Ryb3llZCgpIHtcbiAgICAgIFVSTC5yZXZva2VPYmplY3RVUkwodGhpcy51cmwpO1xuICAgIH0sXG4gIH0sXG4gIEZvY3VzV3JhcDoge1xuICAgIG1vdW50ZWQoKSB7XG4gICAgICB0aGlzLmZvY3VzU3RhcnQgPSB0aGlzLmVsLmZpcnN0RWxlbWVudENoaWxkO1xuICAgICAgdGhpcy5mb2N1c0VuZCA9IHRoaXMuZWwubGFzdEVsZW1lbnRDaGlsZDtcbiAgICAgIHRoaXMuZm9jdXNTdGFydC5hZGRFdmVudExpc3RlbmVyKFwiZm9jdXNcIiwgKGUpID0+IHtcbiAgICAgICAgaWYgKCFlLnJlbGF0ZWRUYXJnZXQgfHwgIXRoaXMuZWwuY29udGFpbnMoZS5yZWxhdGVkVGFyZ2V0KSkge1xuICAgICAgICAgIC8vIEhhbmRsZSBmb2N1cyBlbnRlcmluZyBmcm9tIG91dHNpZGUgKGUuZy4gVGFiIHdoZW4gYm9keSBpcyBmb2N1c2VkKVxuICAgICAgICAgIC8vIGh0dHBzOi8vZ2l0aHViLmNvbS9waG9lbml4ZnJhbWV3b3JrL3Bob2VuaXhfbGl2ZV92aWV3L2lzc3Vlcy8zNjM2XG4gICAgICAgICAgY29uc3QgbmV4dEZvY3VzID0gZS50YXJnZXQubmV4dEVsZW1lbnRTaWJsaW5nO1xuICAgICAgICAgIEFSSUEuYXR0ZW1wdEZvY3VzKG5leHRGb2N1cykgfHwgQVJJQS5mb2N1c0ZpcnN0KG5leHRGb2N1cyk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgQVJJQS5mb2N1c0xhc3QodGhpcy5lbCk7XG4gICAgICAgIH1cbiAgICAgIH0pO1xuICAgICAgdGhpcy5mb2N1c0VuZC5hZGRFdmVudExpc3RlbmVyKFwiZm9jdXNcIiwgKGUpID0+IHtcbiAgICAgICAgaWYgKCFlLnJlbGF0ZWRUYXJnZXQgfHwgIXRoaXMuZWwuY29udGFpbnMoZS5yZWxhdGVkVGFyZ2V0KSkge1xuICAgICAgICAgIC8vIEhhbmRsZSBmb2N1cyBlbnRlcmluZyBmcm9tIG91dHNpZGUgKGUuZy4gU2hpZnQrVGFiIHdoZW4gYm9keSBpcyBmb2N1c2VkKVxuICAgICAgICAgIC8vIGh0dHBzOi8vZ2l0aHViLmNvbS9waG9lbml4ZnJhbWV3b3JrL3Bob2VuaXhfbGl2ZV92aWV3L2lzc3Vlcy8zNjM2XG4gICAgICAgICAgY29uc3QgbmV4dEZvY3VzID0gZS50YXJnZXQucHJldmlvdXNFbGVtZW50U2libGluZztcbiAgICAgICAgICBBUklBLmF0dGVtcHRGb2N1cyhuZXh0Rm9jdXMpIHx8IEFSSUEuZm9jdXNMYXN0KG5leHRGb2N1cyk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgQVJJQS5mb2N1c0ZpcnN0KHRoaXMuZWwpO1xuICAgICAgICB9XG4gICAgICB9KTtcbiAgICAgIC8vIG9ubHkgdHJ5IHRvIGNoYW5nZSB0aGUgZm9jdXMgaWYgaXQgaXMgbm90IGFscmVhZHkgaW5zaWRlXG4gICAgICBpZiAoIXRoaXMuZWwuY29udGFpbnMoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCkpIHtcbiAgICAgICAgdGhpcy5lbC5hZGRFdmVudExpc3RlbmVyKFwicGh4OnNob3ctZW5kXCIsICgpID0+IHRoaXMuZWwuZm9jdXMoKSk7XG4gICAgICAgIGlmICh3aW5kb3cuZ2V0Q29tcHV0ZWRTdHlsZSh0aGlzLmVsKS5kaXNwbGF5ICE9PSBcIm5vbmVcIikge1xuICAgICAgICAgIEFSSUEuZm9jdXNGaXJzdCh0aGlzLmVsKTtcbiAgICAgICAgfVxuICAgICAgfVxuICAgIH0sXG4gIH0sXG59O1xuXG5jb25zdCBmaW5kU2Nyb2xsQ29udGFpbmVyID0gKGVsKSA9PiB7XG4gIC8vIHRoZSBzY3JvbGwgZXZlbnQgd29uJ3QgYmUgZmlyZWQgb24gdGhlIGh0bWwvYm9keSBlbGVtZW50IGV2ZW4gaWYgb3ZlcmZsb3cgaXMgc2V0XG4gIC8vIHRoZXJlZm9yZSB3ZSByZXR1cm4gbnVsbCB0byBpbnN0ZWFkIGxpc3RlbiBmb3Igc2Nyb2xsIGV2ZW50cyBvbiBkb2N1bWVudFxuICBpZiAoW1wiSFRNTFwiLCBcIkJPRFlcIl0uaW5kZXhPZihlbC5ub2RlTmFtZS50b1VwcGVyQ2FzZSgpKSA+PSAwKSByZXR1cm4gbnVsbDtcbiAgaWYgKFtcInNjcm9sbFwiLCBcImF1dG9cIl0uaW5kZXhPZihnZXRDb21wdXRlZFN0eWxlKGVsKS5vdmVyZmxvd1kpID49IDApXG4gICAgcmV0dXJuIGVsO1xuICByZXR1cm4gZmluZFNjcm9sbENvbnRhaW5lcihlbC5wYXJlbnRFbGVtZW50KTtcbn07XG5cbmNvbnN0IHNjcm9sbFRvcCA9IChzY3JvbGxDb250YWluZXIpID0+IHtcbiAgaWYgKHNjcm9sbENvbnRhaW5lcikge1xuICAgIHJldHVybiBzY3JvbGxDb250YWluZXIuc2Nyb2xsVG9wO1xuICB9IGVsc2Uge1xuICAgIHJldHVybiBkb2N1bWVudC5kb2N1bWVudEVsZW1lbnQuc2Nyb2xsVG9wIHx8IGRvY3VtZW50LmJvZHkuc2Nyb2xsVG9wO1xuICB9XG59O1xuXG5jb25zdCBib3R0b20gPSAoc2Nyb2xsQ29udGFpbmVyKSA9PiB7XG4gIGlmIChzY3JvbGxDb250YWluZXIpIHtcbiAgICByZXR1cm4gc2Nyb2xsQ29udGFpbmVyLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpLmJvdHRvbTtcbiAgfSBlbHNlIHtcbiAgICAvLyB3aGVuIHdlIGhhdmUgbm8gY29udGFpbmVyLCB0aGUgd2hvbGUgcGFnZSBzY3JvbGxzLFxuICAgIC8vIHRoZXJlZm9yZSB0aGUgYm90dG9tIGNvb3JkaW5hdGUgaXMgdGhlIHZpZXdwb3J0IGhlaWdodFxuICAgIHJldHVybiB3aW5kb3cuaW5uZXJIZWlnaHQgfHwgZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LmNsaWVudEhlaWdodDtcbiAgfVxufTtcblxuY29uc3QgdG9wID0gKHNjcm9sbENvbnRhaW5lcikgPT4ge1xuICBpZiAoc2Nyb2xsQ29udGFpbmVyKSB7XG4gICAgcmV0dXJuIHNjcm9sbENvbnRhaW5lci5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKS50b3A7XG4gIH0gZWxzZSB7XG4gICAgLy8gd2hlbiB3ZSBoYXZlIG5vIGNvbnRhaW5lciB0aGUgd2hvbGUgcGFnZSBzY3JvbGxzLFxuICAgIC8vIHRoZXJlZm9yZSB0aGUgdG9wIGNvb3JkaW5hdGUgaXMgMFxuICAgIHJldHVybiAwO1xuICB9XG59O1xuXG5jb25zdCBpc0F0Vmlld3BvcnRUb3AgPSAoZWwsIHNjcm9sbENvbnRhaW5lcikgPT4ge1xuICBjb25zdCByZWN0ID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7XG4gIHJldHVybiAoXG4gICAgTWF0aC5jZWlsKHJlY3QudG9wKSA+PSB0b3Aoc2Nyb2xsQ29udGFpbmVyKSAmJlxuICAgIE1hdGguY2VpbChyZWN0LmxlZnQpID49IDAgJiZcbiAgICBNYXRoLmZsb29yKHJlY3QudG9wKSA8PSBib3R0b20oc2Nyb2xsQ29udGFpbmVyKVxuICApO1xufTtcblxuY29uc3QgaXNBdFZpZXdwb3J0Qm90dG9tID0gKGVsLCBzY3JvbGxDb250YWluZXIpID0+IHtcbiAgY29uc3QgcmVjdCA9IGVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpO1xuICByZXR1cm4gKFxuICAgIE1hdGguY2VpbChyZWN0LmJvdHRvbSkgPj0gdG9wKHNjcm9sbENvbnRhaW5lcikgJiZcbiAgICBNYXRoLmNlaWwocmVjdC5sZWZ0KSA+PSAwICYmXG4gICAgTWF0aC5mbG9vcihyZWN0LmJvdHRvbSkgPD0gYm90dG9tKHNjcm9sbENvbnRhaW5lcilcbiAgKTtcbn07XG5cbmNvbnN0IGlzV2l0aGluVmlld3BvcnQgPSAoZWwsIHNjcm9sbENvbnRhaW5lcikgPT4ge1xuICBjb25zdCByZWN0ID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7XG4gIHJldHVybiAoXG4gICAgTWF0aC5jZWlsKHJlY3QudG9wKSA+PSB0b3Aoc2Nyb2xsQ29udGFpbmVyKSAmJlxuICAgIE1hdGguY2VpbChyZWN0LmxlZnQpID49IDAgJiZcbiAgICBNYXRoLmZsb29yKHJlY3QudG9wKSA8PSBib3R0b20oc2Nyb2xsQ29udGFpbmVyKVxuICApO1xufTtcblxuSG9va3MuSW5maW5pdGVTY3JvbGwgPSB7XG4gIG1vdW50ZWQoKSB7XG4gICAgdGhpcy5zY3JvbGxDb250YWluZXIgPSBmaW5kU2Nyb2xsQ29udGFpbmVyKHRoaXMuZWwpO1xuICAgIGxldCBzY3JvbGxCZWZvcmUgPSBzY3JvbGxUb3AodGhpcy5zY3JvbGxDb250YWluZXIpO1xuICAgIGxldCB0b3BPdmVycmFuID0gZmFsc2U7XG4gICAgY29uc3QgdGhyb3R0bGVJbnRlcnZhbCA9IDUwMDtcbiAgICBsZXQgcGVuZGluZ09wID0gbnVsbDtcblxuICAgIGNvbnN0IG9uVG9wT3ZlcnJ1biA9IHRoaXMudGhyb3R0bGUoXG4gICAgICB0aHJvdHRsZUludGVydmFsLFxuICAgICAgKHRvcEV2ZW50LCBmaXJzdENoaWxkKSA9PiB7XG4gICAgICAgIHBlbmRpbmdPcCA9ICgpID0+IHRydWU7XG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5qcygpLnB1c2godGhpcy5lbCwgdG9wRXZlbnQsIHtcbiAgICAgICAgICB2YWx1ZTogeyBpZDogZmlyc3RDaGlsZC5pZCwgX292ZXJyYW46IHRydWUgfSxcbiAgICAgICAgICBjYWxsYmFjazogKCkgPT4ge1xuICAgICAgICAgICAgcGVuZGluZ09wID0gbnVsbDtcbiAgICAgICAgICB9LFxuICAgICAgICB9KTtcbiAgICAgIH0sXG4gICAgKTtcblxuICAgIGNvbnN0IG9uRmlyc3RDaGlsZEF0VG9wID0gdGhpcy50aHJvdHRsZShcbiAgICAgIHRocm90dGxlSW50ZXJ2YWwsXG4gICAgICAodG9wRXZlbnQsIGZpcnN0Q2hpbGQpID0+IHtcbiAgICAgICAgcGVuZGluZ09wID0gKCkgPT4gZmlyc3RDaGlsZC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiBcInN0YXJ0XCIgfSk7XG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5qcygpLnB1c2godGhpcy5lbCwgdG9wRXZlbnQsIHtcbiAgICAgICAgICB2YWx1ZTogeyBpZDogZmlyc3RDaGlsZC5pZCB9LFxuICAgICAgICAgIGNhbGxiYWNrOiAoKSA9PiB7XG4gICAgICAgICAgICBwZW5kaW5nT3AgPSBudWxsO1xuICAgICAgICAgICAgLy8gbWFrZSBzdXJlIHRoYXQgdGhlIERPTSBpcyBwYXRjaGVkIGJ5IHdhaXRpbmcgZm9yIHRoZSBuZXh0IHRpY2tcbiAgICAgICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgICAgICBpZiAoIWlzV2l0aGluVmlld3BvcnQoZmlyc3RDaGlsZCwgdGhpcy5zY3JvbGxDb250YWluZXIpKSB7XG4gICAgICAgICAgICAgICAgZmlyc3RDaGlsZC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiBcInN0YXJ0XCIgfSk7XG4gICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH0pO1xuICAgICAgICAgIH0sXG4gICAgICAgIH0pO1xuICAgICAgfSxcbiAgICApO1xuXG4gICAgY29uc3Qgb25MYXN0Q2hpbGRBdEJvdHRvbSA9IHRoaXMudGhyb3R0bGUoXG4gICAgICB0aHJvdHRsZUludGVydmFsLFxuICAgICAgKGJvdHRvbUV2ZW50LCBsYXN0Q2hpbGQpID0+IHtcbiAgICAgICAgcGVuZGluZ09wID0gKCkgPT4gbGFzdENoaWxkLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6IFwiZW5kXCIgfSk7XG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5qcygpLnB1c2godGhpcy5lbCwgYm90dG9tRXZlbnQsIHtcbiAgICAgICAgICB2YWx1ZTogeyBpZDogbGFzdENoaWxkLmlkIH0sXG4gICAgICAgICAgY2FsbGJhY2s6ICgpID0+IHtcbiAgICAgICAgICAgIHBlbmRpbmdPcCA9IG51bGw7XG4gICAgICAgICAgICAvLyBtYWtlIHN1cmUgdGhhdCB0aGUgRE9NIGlzIHBhdGNoZWQgYnkgd2FpdGluZyBmb3IgdGhlIG5leHQgdGlja1xuICAgICAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICAgICAgICAgIGlmICghaXNXaXRoaW5WaWV3cG9ydChsYXN0Q2hpbGQsIHRoaXMuc2Nyb2xsQ29udGFpbmVyKSkge1xuICAgICAgICAgICAgICAgIGxhc3RDaGlsZC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiBcImVuZFwiIH0pO1xuICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9KTtcbiAgICAgICAgICB9LFxuICAgICAgICB9KTtcbiAgICAgIH0sXG4gICAgKTtcblxuICAgIHRoaXMub25TY3JvbGwgPSAoX2UpID0+IHtcbiAgICAgIGNvbnN0IHNjcm9sbE5vdyA9IHNjcm9sbFRvcCh0aGlzLnNjcm9sbENvbnRhaW5lcik7XG5cbiAgICAgIGlmIChwZW5kaW5nT3ApIHtcbiAgICAgICAgc2Nyb2xsQmVmb3JlID0gc2Nyb2xsTm93O1xuICAgICAgICByZXR1cm4gcGVuZGluZ09wKCk7XG4gICAgICB9XG4gICAgICBjb25zdCByZWN0ID0gdGhpcy5lbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTtcbiAgICAgIGNvbnN0IHRvcEV2ZW50ID0gdGhpcy5lbC5nZXRBdHRyaWJ1dGUoXG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5iaW5kaW5nKFwidmlld3BvcnQtdG9wXCIpLFxuICAgICAgKTtcbiAgICAgIGNvbnN0IGJvdHRvbUV2ZW50ID0gdGhpcy5lbC5nZXRBdHRyaWJ1dGUoXG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5iaW5kaW5nKFwidmlld3BvcnQtYm90dG9tXCIpLFxuICAgICAgKTtcbiAgICAgIGNvbnN0IGxhc3RDaGlsZCA9IHRoaXMuZWwubGFzdEVsZW1lbnRDaGlsZDtcbiAgICAgIGNvbnN0IGZpcnN0Q2hpbGQgPSB0aGlzLmVsLmZpcnN0RWxlbWVudENoaWxkO1xuICAgICAgY29uc3QgaXNTY3JvbGxpbmdVcCA9IHNjcm9sbE5vdyA8IHNjcm9sbEJlZm9yZTtcbiAgICAgIGNvbnN0IGlzU2Nyb2xsaW5nRG93biA9IHNjcm9sbE5vdyA+IHNjcm9sbEJlZm9yZTtcblxuICAgICAgLy8gZWwgb3ZlcnJhbiB3aGlsZSBzY3JvbGxpbmcgdXBcbiAgICAgIGlmIChpc1Njcm9sbGluZ1VwICYmIHRvcEV2ZW50ICYmICF0b3BPdmVycmFuICYmIHJlY3QudG9wID49IDApIHtcbiAgICAgICAgdG9wT3ZlcnJhbiA9IHRydWU7XG4gICAgICAgIG9uVG9wT3ZlcnJ1bih0b3BFdmVudCwgZmlyc3RDaGlsZCk7XG4gICAgICB9IGVsc2UgaWYgKGlzU2Nyb2xsaW5nRG93biAmJiB0b3BPdmVycmFuICYmIHJlY3QudG9wIDw9IDApIHtcbiAgICAgICAgdG9wT3ZlcnJhbiA9IGZhbHNlO1xuICAgICAgfVxuXG4gICAgICBpZiAoXG4gICAgICAgIHRvcEV2ZW50ICYmXG4gICAgICAgIGlzU2Nyb2xsaW5nVXAgJiZcbiAgICAgICAgaXNBdFZpZXdwb3J0VG9wKGZpcnN0Q2hpbGQsIHRoaXMuc2Nyb2xsQ29udGFpbmVyKVxuICAgICAgKSB7XG4gICAgICAgIG9uRmlyc3RDaGlsZEF0VG9wKHRvcEV2ZW50LCBmaXJzdENoaWxkKTtcbiAgICAgIH0gZWxzZSBpZiAoXG4gICAgICAgIGJvdHRvbUV2ZW50ICYmXG4gICAgICAgIGlzU2Nyb2xsaW5nRG93biAmJlxuICAgICAgICBpc0F0Vmlld3BvcnRCb3R0b20obGFzdENoaWxkLCB0aGlzLnNjcm9sbENvbnRhaW5lcilcbiAgICAgICkge1xuICAgICAgICBvbkxhc3RDaGlsZEF0Qm90dG9tKGJvdHRvbUV2ZW50LCBsYXN0Q2hpbGQpO1xuICAgICAgfVxuICAgICAgc2Nyb2xsQmVmb3JlID0gc2Nyb2xsTm93O1xuICAgIH07XG5cbiAgICBpZiAodGhpcy5zY3JvbGxDb250YWluZXIpIHtcbiAgICAgIHRoaXMuc2Nyb2xsQ29udGFpbmVyLmFkZEV2ZW50TGlzdGVuZXIoXCJzY3JvbGxcIiwgdGhpcy5vblNjcm9sbCk7XG4gICAgfSBlbHNlIHtcbiAgICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwic2Nyb2xsXCIsIHRoaXMub25TY3JvbGwpO1xuICAgIH1cbiAgfSxcblxuICBkZXN0cm95ZWQoKSB7XG4gICAgaWYgKHRoaXMuc2Nyb2xsQ29udGFpbmVyKSB7XG4gICAgICB0aGlzLnNjcm9sbENvbnRhaW5lci5yZW1vdmVFdmVudExpc3RlbmVyKFwic2Nyb2xsXCIsIHRoaXMub25TY3JvbGwpO1xuICAgIH0gZWxzZSB7XG4gICAgICB3aW5kb3cucmVtb3ZlRXZlbnRMaXN0ZW5lcihcInNjcm9sbFwiLCB0aGlzLm9uU2Nyb2xsKTtcbiAgICB9XG4gIH0sXG5cbiAgdGhyb3R0bGUoaW50ZXJ2YWwsIGNhbGxiYWNrKSB7XG4gICAgbGV0IGxhc3RDYWxsQXQgPSAwO1xuICAgIGxldCB0aW1lcjtcblxuICAgIHJldHVybiAoLi4uYXJncykgPT4ge1xuICAgICAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTtcbiAgICAgIGNvbnN0IHJlbWFpbmluZ1RpbWUgPSBpbnRlcnZhbCAtIChub3cgLSBsYXN0Q2FsbEF0KTtcblxuICAgICAgaWYgKHJlbWFpbmluZ1RpbWUgPD0gMCB8fCByZW1haW5pbmdUaW1lID4gaW50ZXJ2YWwpIHtcbiAgICAgICAgaWYgKHRpbWVyKSB7XG4gICAgICAgICAgY2xlYXJUaW1lb3V0KHRpbWVyKTtcbiAgICAgICAgICB0aW1lciA9IG51bGw7XG4gICAgICAgIH1cbiAgICAgICAgbGFzdENhbGxBdCA9IG5vdztcbiAgICAgICAgY2FsbGJhY2soLi4uYXJncyk7XG4gICAgICB9IGVsc2UgaWYgKCF0aW1lcikge1xuICAgICAgICB0aW1lciA9IHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgICAgIGxhc3RDYWxsQXQgPSBEYXRlLm5vdygpO1xuICAgICAgICAgIHRpbWVyID0gbnVsbDtcbiAgICAgICAgICBjYWxsYmFjayguLi5hcmdzKTtcbiAgICAgICAgfSwgcmVtYWluaW5nVGltZSk7XG4gICAgICB9XG4gICAgfTtcbiAgfSxcbn07XG5leHBvcnQgZGVmYXVsdCBIb29rcztcbiIsICJpbXBvcnQge1xuICBQSFhfUkVGX0xPQURJTkcsXG4gIFBIWF9SRUZfTE9DSyxcbiAgUEhYX1JFRl9TUkMsXG4gIFBIWF9QRU5ESU5HX1JFRlMsXG4gIFBIWF9FVkVOVF9DTEFTU0VTLFxuICBQSFhfRElTQUJMRUQsXG4gIFBIWF9SRUFET05MWSxcbiAgUEhYX0RJU0FCTEVfV0lUSF9SRVNUT1JFLFxufSBmcm9tIFwiLi9jb25zdGFudHNcIjtcblxuaW1wb3J0IERPTSBmcm9tIFwiLi9kb21cIjtcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgRWxlbWVudFJlZiB7XG4gIHN0YXRpYyBvblVubG9jayhlbCwgY2FsbGJhY2spIHtcbiAgICBpZiAoIURPTS5pc0xvY2tlZChlbCkgJiYgIWVsLmNsb3Nlc3QoYFske1BIWF9SRUZfTE9DS31dYCkpIHtcbiAgICAgIHJldHVybiBjYWxsYmFjaygpO1xuICAgIH1cbiAgICBjb25zdCBjbG9zZXN0TG9jayA9IGVsLmNsb3Nlc3QoYFske1BIWF9SRUZfTE9DS31dYCk7XG4gICAgY29uc3QgcmVmID0gY2xvc2VzdExvY2tcbiAgICAgIC5jbG9zZXN0KGBbJHtQSFhfUkVGX0xPQ0t9XWApXG4gICAgICAuZ2V0QXR0cmlidXRlKFBIWF9SRUZfTE9DSyk7XG4gICAgY2xvc2VzdExvY2suYWRkRXZlbnRMaXN0ZW5lcihcbiAgICAgIGBwaHg6dW5kby1sb2NrOiR7cmVmfWAsXG4gICAgICAoKSA9PiB7XG4gICAgICAgIGNhbGxiYWNrKCk7XG4gICAgICB9LFxuICAgICAgeyBvbmNlOiB0cnVlIH0sXG4gICAgKTtcbiAgfVxuXG4gIGNvbnN0cnVjdG9yKGVsKSB7XG4gICAgdGhpcy5lbCA9IGVsO1xuICAgIHRoaXMubG9hZGluZ1JlZiA9IGVsLmhhc0F0dHJpYnV0ZShQSFhfUkVGX0xPQURJTkcpXG4gICAgICA/IHBhcnNlSW50KGVsLmdldEF0dHJpYnV0ZShQSFhfUkVGX0xPQURJTkcpLCAxMClcbiAgICAgIDogbnVsbDtcbiAgICB0aGlzLmxvY2tSZWYgPSBlbC5oYXNBdHRyaWJ1dGUoUEhYX1JFRl9MT0NLKVxuICAgICAgPyBwYXJzZUludChlbC5nZXRBdHRyaWJ1dGUoUEhYX1JFRl9MT0NLKSwgMTApXG4gICAgICA6IG51bGw7XG4gIH1cblxuICAvLyBwdWJsaWNcblxuICBtYXliZVVuZG8ocmVmLCBwaHhFdmVudCwgZWFjaENsb25lQ2FsbGJhY2spIHtcbiAgICBpZiAoIXRoaXMuaXNXaXRoaW4ocmVmKSkge1xuICAgICAgLy8gd2UgY2Fubm90IHVuZG8gdGhlIGxvY2sgLyBsb2FkaW5nIG5vdywgYXMgdGhlcmUgaXMgYSBuZXdlciBvbmUgYWxyZWFkeSBzZXQ7XG4gICAgICAvLyB3ZSBuZWVkIHRvIHN0b3JlIHRoZSBvcmlnaW5hbCByZWYgd2UgdHJpZWQgdG8gc2VuZCB0aGUgdW5kbyBldmVudCBsYXRlclxuICAgICAgRE9NLnVwZGF0ZVByaXZhdGUodGhpcy5lbCwgUEhYX1BFTkRJTkdfUkVGUywgW10sIChwZW5kaW5nUmVmcykgPT4ge1xuICAgICAgICBwZW5kaW5nUmVmcy5wdXNoKHJlZik7XG4gICAgICAgIHJldHVybiBwZW5kaW5nUmVmcztcbiAgICAgIH0pO1xuICAgICAgcmV0dXJuO1xuICAgIH1cblxuICAgIC8vIHVuZG8gbG9ja3MgYW5kIGFwcGx5IGNsb25lc1xuICAgIHRoaXMudW5kb0xvY2tzKHJlZiwgcGh4RXZlbnQsIGVhY2hDbG9uZUNhbGxiYWNrKTtcblxuICAgIC8vIHVuZG8gbG9hZGluZyBzdGF0ZXNcbiAgICB0aGlzLnVuZG9Mb2FkaW5nKHJlZiwgcGh4RXZlbnQpO1xuXG4gICAgLy8gZW5zdXJlIHVuZG8gZXZlbnRzIGFyZSBmaXJlZCBmb3IgcGVuZGluZyByZWZzIHRoYXRcbiAgICAvLyBhcmUgcmVzb2x2ZWQgYnkgdGhlIGN1cnJlbnQgcmVmLCBvdGhlcndpc2Ugd2UnZCBsZWFrIGV2ZW50IGxpc3RlbmVyc1xuICAgIERPTS51cGRhdGVQcml2YXRlKHRoaXMuZWwsIFBIWF9QRU5ESU5HX1JFRlMsIFtdLCAocGVuZGluZ1JlZnMpID0+IHtcbiAgICAgIHJldHVybiBwZW5kaW5nUmVmcy5maWx0ZXIoKHBlbmRpbmdSZWYpID0+IHtcbiAgICAgICAgbGV0IG9wdHMgPSB7XG4gICAgICAgICAgZGV0YWlsOiB7IHJlZjogcGVuZGluZ1JlZiwgZXZlbnQ6IHBoeEV2ZW50IH0sXG4gICAgICAgICAgYnViYmxlczogdHJ1ZSxcbiAgICAgICAgICBjYW5jZWxhYmxlOiBmYWxzZSxcbiAgICAgICAgfTtcbiAgICAgICAgaWYgKHRoaXMubG9hZGluZ1JlZiAmJiB0aGlzLmxvYWRpbmdSZWYgPiBwZW5kaW5nUmVmKSB7XG4gICAgICAgICAgdGhpcy5lbC5kaXNwYXRjaEV2ZW50KFxuICAgICAgICAgICAgbmV3IEN1c3RvbUV2ZW50KGBwaHg6dW5kby1sb2FkaW5nOiR7cGVuZGluZ1JlZn1gLCBvcHRzKSxcbiAgICAgICAgICApO1xuICAgICAgICB9XG4gICAgICAgIGlmICh0aGlzLmxvY2tSZWYgJiYgdGhpcy5sb2NrUmVmID4gcGVuZGluZ1JlZikge1xuICAgICAgICAgIHRoaXMuZWwuZGlzcGF0Y2hFdmVudChcbiAgICAgICAgICAgIG5ldyBDdXN0b21FdmVudChgcGh4OnVuZG8tbG9jazoke3BlbmRpbmdSZWZ9YCwgb3B0cyksXG4gICAgICAgICAgKTtcbiAgICAgICAgfVxuICAgICAgICByZXR1cm4gcGVuZGluZ1JlZiA+IHJlZjtcbiAgICAgIH0pO1xuICAgIH0pO1xuXG4gICAgLy8gY2xlYW4gdXAgaWYgZnVsbHkgcmVzb2x2ZWRcbiAgICBpZiAodGhpcy5pc0Z1bGx5UmVzb2x2ZWRCeShyZWYpKSB7XG4gICAgICB0aGlzLmVsLnJlbW92ZUF0dHJpYnV0ZShQSFhfUkVGX1NSQyk7XG4gICAgfVxuICB9XG5cbiAgLy8gcHJpdmF0ZVxuXG4gIGlzV2l0aGluKHJlZikge1xuICAgIHJldHVybiAhKFxuICAgICAgdGhpcy5sb2FkaW5nUmVmICE9PSBudWxsICYmXG4gICAgICB0aGlzLmxvYWRpbmdSZWYgPiByZWYgJiZcbiAgICAgIHRoaXMubG9ja1JlZiAhPT0gbnVsbCAmJlxuICAgICAgdGhpcy5sb2NrUmVmID4gcmVmXG4gICAgKTtcbiAgfVxuXG4gIC8vIENoZWNrIGZvciBjbG9uZWQgUEhYX1JFRl9MT0NLIGVsZW1lbnQgdGhhdCBoYXMgYmVlbiBtb3JwaGVkIGJlaGluZFxuICAvLyB0aGUgc2NlbmVzIHdoaWxlIHRoaXMgZWxlbWVudCB3YXMgbG9ja2VkIGluIHRoZSBET00uXG4gIC8vIFdoZW4gd2UgYXBwbHkgdGhlIGNsb25lZCB0cmVlIHRvIHRoZSBhY3RpdmUgRE9NIGVsZW1lbnQsIHdlIG11c3RcbiAgLy9cbiAgLy8gICAxLiBleGVjdXRlIHBlbmRpbmcgbW91bnRlZCBob29rcyBmb3Igbm9kZXMgbm93IGluIHRoZSBET01cbiAgLy8gICAyLiB1bmRvIGFueSByZWYgaW5zaWRlIHRoZSBjbG9uZWQgdHJlZSB0aGF0IGhhcyBzaW5jZSBiZWVuIGFjaydkXG4gIHVuZG9Mb2NrcyhyZWYsIHBoeEV2ZW50LCBlYWNoQ2xvbmVDYWxsYmFjaykge1xuICAgIGlmICghdGhpcy5pc0xvY2tVbmRvbmVCeShyZWYpKSB7XG4gICAgICByZXR1cm47XG4gICAgfVxuXG4gICAgY29uc3QgY2xvbmVkVHJlZSA9IERPTS5wcml2YXRlKHRoaXMuZWwsIFBIWF9SRUZfTE9DSyk7XG4gICAgaWYgKGNsb25lZFRyZWUpIHtcbiAgICAgIGVhY2hDbG9uZUNhbGxiYWNrKGNsb25lZFRyZWUpO1xuICAgICAgRE9NLmRlbGV0ZVByaXZhdGUodGhpcy5lbCwgUEhYX1JFRl9MT0NLKTtcbiAgICB9XG4gICAgdGhpcy5lbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1JFRl9MT0NLKTtcblxuICAgIGNvbnN0IG9wdHMgPSB7XG4gICAgICBkZXRhaWw6IHsgcmVmOiByZWYsIGV2ZW50OiBwaHhFdmVudCB9LFxuICAgICAgYnViYmxlczogdHJ1ZSxcbiAgICAgIGNhbmNlbGFibGU6IGZhbHNlLFxuICAgIH07XG4gICAgdGhpcy5lbC5kaXNwYXRjaEV2ZW50KFxuICAgICAgbmV3IEN1c3RvbUV2ZW50KGBwaHg6dW5kby1sb2NrOiR7dGhpcy5sb2NrUmVmfWAsIG9wdHMpLFxuICAgICk7XG4gIH1cblxuICB1bmRvTG9hZGluZyhyZWYsIHBoeEV2ZW50KSB7XG4gICAgaWYgKCF0aGlzLmlzTG9hZGluZ1VuZG9uZUJ5KHJlZikpIHtcbiAgICAgIGlmIChcbiAgICAgICAgdGhpcy5jYW5VbmRvTG9hZGluZyhyZWYpICYmXG4gICAgICAgIHRoaXMuZWwuY2xhc3NMaXN0LmNvbnRhaW5zKFwicGh4LXN1Ym1pdC1sb2FkaW5nXCIpXG4gICAgICApIHtcbiAgICAgICAgdGhpcy5lbC5jbGFzc0xpc3QucmVtb3ZlKFwicGh4LWNoYW5nZS1sb2FkaW5nXCIpO1xuICAgICAgfVxuICAgICAgcmV0dXJuO1xuICAgIH1cblxuICAgIGlmICh0aGlzLmNhblVuZG9Mb2FkaW5nKHJlZikpIHtcbiAgICAgIHRoaXMuZWwucmVtb3ZlQXR0cmlidXRlKFBIWF9SRUZfTE9BRElORyk7XG4gICAgICBjb25zdCBkaXNhYmxlZFZhbCA9IHRoaXMuZWwuZ2V0QXR0cmlidXRlKFBIWF9ESVNBQkxFRCk7XG4gICAgICBjb25zdCByZWFkT25seVZhbCA9IHRoaXMuZWwuZ2V0QXR0cmlidXRlKFBIWF9SRUFET05MWSk7XG4gICAgICAvLyByZXN0b3JlIGlucHV0c1xuICAgICAgaWYgKHJlYWRPbmx5VmFsICE9PSBudWxsKSB7XG4gICAgICAgIHRoaXMuZWwucmVhZE9ubHkgPSByZWFkT25seVZhbCA9PT0gXCJ0cnVlXCIgPyB0cnVlIDogZmFsc2U7XG4gICAgICAgIHRoaXMuZWwucmVtb3ZlQXR0cmlidXRlKFBIWF9SRUFET05MWSk7XG4gICAgICB9XG4gICAgICBpZiAoZGlzYWJsZWRWYWwgIT09IG51bGwpIHtcbiAgICAgICAgdGhpcy5lbC5kaXNhYmxlZCA9IGRpc2FibGVkVmFsID09PSBcInRydWVcIiA/IHRydWUgOiBmYWxzZTtcbiAgICAgICAgdGhpcy5lbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX0RJU0FCTEVEKTtcbiAgICAgIH1cbiAgICAgIC8vIHJlc3RvcmUgZGlzYWJsZXNcbiAgICAgIGNvbnN0IGRpc2FibGVSZXN0b3JlID0gdGhpcy5lbC5nZXRBdHRyaWJ1dGUoUEhYX0RJU0FCTEVfV0lUSF9SRVNUT1JFKTtcbiAgICAgIGlmIChkaXNhYmxlUmVzdG9yZSAhPT0gbnVsbCkge1xuICAgICAgICB0aGlzLmVsLmlubmVyVGV4dCA9IGRpc2FibGVSZXN0b3JlO1xuICAgICAgICB0aGlzLmVsLnJlbW92ZUF0dHJpYnV0ZShQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUpO1xuICAgICAgfVxuXG4gICAgICBjb25zdCBvcHRzID0ge1xuICAgICAgICBkZXRhaWw6IHsgcmVmOiByZWYsIGV2ZW50OiBwaHhFdmVudCB9LFxuICAgICAgICBidWJibGVzOiB0cnVlLFxuICAgICAgICBjYW5jZWxhYmxlOiBmYWxzZSxcbiAgICAgIH07XG4gICAgICB0aGlzLmVsLmRpc3BhdGNoRXZlbnQoXG4gICAgICAgIG5ldyBDdXN0b21FdmVudChgcGh4OnVuZG8tbG9hZGluZzoke3RoaXMubG9hZGluZ1JlZn1gLCBvcHRzKSxcbiAgICAgICk7XG4gICAgfVxuXG4gICAgLy8gcmVtb3ZlIGNsYXNzZXNcbiAgICBQSFhfRVZFTlRfQ0xBU1NFUy5mb3JFYWNoKChuYW1lKSA9PiB7XG4gICAgICBpZiAobmFtZSAhPT0gXCJwaHgtc3VibWl0LWxvYWRpbmdcIiB8fCB0aGlzLmNhblVuZG9Mb2FkaW5nKHJlZikpIHtcbiAgICAgICAgRE9NLnJlbW92ZUNsYXNzKHRoaXMuZWwsIG5hbWUpO1xuICAgICAgfVxuICAgIH0pO1xuICB9XG5cbiAgaXNMb2FkaW5nVW5kb25lQnkocmVmKSB7XG4gICAgcmV0dXJuIHRoaXMubG9hZGluZ1JlZiA9PT0gbnVsbCA/IGZhbHNlIDogdGhpcy5sb2FkaW5nUmVmIDw9IHJlZjtcbiAgfVxuICBpc0xvY2tVbmRvbmVCeShyZWYpIHtcbiAgICByZXR1cm4gdGhpcy5sb2NrUmVmID09PSBudWxsID8gZmFsc2UgOiB0aGlzLmxvY2tSZWYgPD0gcmVmO1xuICB9XG5cbiAgaXNGdWxseVJlc29sdmVkQnkocmVmKSB7XG4gICAgcmV0dXJuIChcbiAgICAgICh0aGlzLmxvYWRpbmdSZWYgPT09IG51bGwgfHwgdGhpcy5sb2FkaW5nUmVmIDw9IHJlZikgJiZcbiAgICAgICh0aGlzLmxvY2tSZWYgPT09IG51bGwgfHwgdGhpcy5sb2NrUmVmIDw9IHJlZilcbiAgICApO1xuICB9XG5cbiAgLy8gb25seSByZW1vdmUgdGhlIHBoeC1zdWJtaXQtbG9hZGluZyBjbGFzcyBpZiB3ZSBhcmUgbm90IGxvY2tlZFxuICBjYW5VbmRvTG9hZGluZyhyZWYpIHtcbiAgICByZXR1cm4gdGhpcy5sb2NrUmVmID09PSBudWxsIHx8IHRoaXMubG9ja1JlZiA8PSByZWY7XG4gIH1cbn1cbiIsICJpbXBvcnQgeyBtYXliZSB9IGZyb20gXCIuL3V0aWxzXCI7XG5cbmltcG9ydCBET00gZnJvbSBcIi4vZG9tXCI7XG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIERPTVBvc3RNb3JwaFJlc3RvcmVyIHtcbiAgY29uc3RydWN0b3IoY29udGFpbmVyQmVmb3JlLCBjb250YWluZXJBZnRlciwgdXBkYXRlVHlwZSkge1xuICAgIGNvbnN0IGlkc0JlZm9yZSA9IG5ldyBTZXQoKTtcbiAgICBjb25zdCBpZHNBZnRlciA9IG5ldyBTZXQoXG4gICAgICBbLi4uY29udGFpbmVyQWZ0ZXIuY2hpbGRyZW5dLm1hcCgoY2hpbGQpID0+IGNoaWxkLmlkKSxcbiAgICApO1xuXG4gICAgY29uc3QgZWxlbWVudHNUb01vZGlmeSA9IFtdO1xuXG4gICAgQXJyYXkuZnJvbShjb250YWluZXJCZWZvcmUuY2hpbGRyZW4pLmZvckVhY2goKGNoaWxkKSA9PiB7XG4gICAgICBpZiAoY2hpbGQuaWQpIHtcbiAgICAgICAgLy8gYWxsIG9mIG91ciBjaGlsZHJlbiBzaG91bGQgYmUgZWxlbWVudHMgd2l0aCBpZHNcbiAgICAgICAgaWRzQmVmb3JlLmFkZChjaGlsZC5pZCk7XG4gICAgICAgIGlmIChpZHNBZnRlci5oYXMoY2hpbGQuaWQpKSB7XG4gICAgICAgICAgY29uc3QgcHJldmlvdXNFbGVtZW50SWQgPVxuICAgICAgICAgICAgY2hpbGQucHJldmlvdXNFbGVtZW50U2libGluZyAmJiBjaGlsZC5wcmV2aW91c0VsZW1lbnRTaWJsaW5nLmlkO1xuICAgICAgICAgIGVsZW1lbnRzVG9Nb2RpZnkucHVzaCh7XG4gICAgICAgICAgICBlbGVtZW50SWQ6IGNoaWxkLmlkLFxuICAgICAgICAgICAgcHJldmlvdXNFbGVtZW50SWQ6IHByZXZpb3VzRWxlbWVudElkLFxuICAgICAgICAgIH0pO1xuICAgICAgICB9XG4gICAgICB9XG4gICAgfSk7XG5cbiAgICB0aGlzLmNvbnRhaW5lcklkID0gY29udGFpbmVyQWZ0ZXIuaWQ7XG4gICAgdGhpcy51cGRhdGVUeXBlID0gdXBkYXRlVHlwZTtcbiAgICB0aGlzLmVsZW1lbnRzVG9Nb2RpZnkgPSBlbGVtZW50c1RvTW9kaWZ5O1xuICAgIHRoaXMuZWxlbWVudElkc1RvQWRkID0gWy4uLmlkc0FmdGVyXS5maWx0ZXIoKGlkKSA9PiAhaWRzQmVmb3JlLmhhcyhpZCkpO1xuICB9XG5cbiAgLy8gV2UgZG8gdGhlIGZvbGxvd2luZyB0byBvcHRpbWl6ZSBhcHBlbmQvcHJlcGVuZCBvcGVyYXRpb25zOlxuICAvLyAgIDEpIFRyYWNrIGlkcyBvZiBtb2RpZmllZCBlbGVtZW50cyAmIG9mIG5ldyBlbGVtZW50c1xuICAvLyAgIDIpIEFsbCB0aGUgbW9kaWZpZWQgZWxlbWVudHMgYXJlIHB1dCBiYWNrIGluIHRoZSBjb3JyZWN0IHBvc2l0aW9uIGluIHRoZSBET00gdHJlZVxuICAvLyAgICAgIGJ5IHN0b3JpbmcgdGhlIGlkIG9mIHRoZWlyIHByZXZpb3VzIHNpYmxpbmdcbiAgLy8gICAzKSBOZXcgZWxlbWVudHMgYXJlIGdvaW5nIHRvIGJlIHB1dCBpbiB0aGUgcmlnaHQgcGxhY2UgYnkgbW9ycGhkb20gZHVyaW5nIGFwcGVuZC5cbiAgLy8gICAgICBGb3IgcHJlcGVuZCwgd2UgbW92ZSB0aGVtIHRvIHRoZSBmaXJzdCBwb3NpdGlvbiBpbiB0aGUgY29udGFpbmVyXG4gIHBlcmZvcm0oKSB7XG4gICAgY29uc3QgY29udGFpbmVyID0gRE9NLmJ5SWQodGhpcy5jb250YWluZXJJZCk7XG4gICAgaWYgKCFjb250YWluZXIpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgdGhpcy5lbGVtZW50c1RvTW9kaWZ5LmZvckVhY2goKGVsZW1lbnRUb01vZGlmeSkgPT4ge1xuICAgICAgaWYgKGVsZW1lbnRUb01vZGlmeS5wcmV2aW91c0VsZW1lbnRJZCkge1xuICAgICAgICBtYXliZShcbiAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChlbGVtZW50VG9Nb2RpZnkucHJldmlvdXNFbGVtZW50SWQpLFxuICAgICAgICAgIChwcmV2aW91c0VsZW0pID0+IHtcbiAgICAgICAgICAgIG1heWJlKFxuICAgICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChlbGVtZW50VG9Nb2RpZnkuZWxlbWVudElkKSxcbiAgICAgICAgICAgICAgKGVsZW0pID0+IHtcbiAgICAgICAgICAgICAgICBjb25zdCBpc0luUmlnaHRQbGFjZSA9XG4gICAgICAgICAgICAgICAgICBlbGVtLnByZXZpb3VzRWxlbWVudFNpYmxpbmcgJiZcbiAgICAgICAgICAgICAgICAgIGVsZW0ucHJldmlvdXNFbGVtZW50U2libGluZy5pZCA9PSBwcmV2aW91c0VsZW0uaWQ7XG4gICAgICAgICAgICAgICAgaWYgKCFpc0luUmlnaHRQbGFjZSkge1xuICAgICAgICAgICAgICAgICAgcHJldmlvdXNFbGVtLmluc2VydEFkamFjZW50RWxlbWVudChcImFmdGVyZW5kXCIsIGVsZW0pO1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICk7XG4gICAgICAgICAgfSxcbiAgICAgICAgKTtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIC8vIFRoaXMgaXMgdGhlIGZpcnN0IGVsZW1lbnQgaW4gdGhlIGNvbnRhaW5lclxuICAgICAgICBtYXliZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZChlbGVtZW50VG9Nb2RpZnkuZWxlbWVudElkKSwgKGVsZW0pID0+IHtcbiAgICAgICAgICBjb25zdCBpc0luUmlnaHRQbGFjZSA9IGVsZW0ucHJldmlvdXNFbGVtZW50U2libGluZyA9PSBudWxsO1xuICAgICAgICAgIGlmICghaXNJblJpZ2h0UGxhY2UpIHtcbiAgICAgICAgICAgIGNvbnRhaW5lci5pbnNlcnRBZGphY2VudEVsZW1lbnQoXCJhZnRlcmJlZ2luXCIsIGVsZW0pO1xuICAgICAgICAgIH1cbiAgICAgICAgfSk7XG4gICAgICB9XG4gICAgfSk7XG5cbiAgICBpZiAodGhpcy51cGRhdGVUeXBlID09IFwicHJlcGVuZFwiKSB7XG4gICAgICB0aGlzLmVsZW1lbnRJZHNUb0FkZC5yZXZlcnNlKCkuZm9yRWFjaCgoZWxlbUlkKSA9PiB7XG4gICAgICAgIG1heWJlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGVsZW1JZCksIChlbGVtKSA9PlxuICAgICAgICAgIGNvbnRhaW5lci5pbnNlcnRBZGphY2VudEVsZW1lbnQoXCJhZnRlcmJlZ2luXCIsIGVsZW0pLFxuICAgICAgICApO1xuICAgICAgfSk7XG4gICAgfVxuICB9XG59XG4iLCAidmFyIERPQ1VNRU5UX0ZSQUdNRU5UX05PREUgPSAxMTtcblxuZnVuY3Rpb24gbW9ycGhBdHRycyhmcm9tTm9kZSwgdG9Ob2RlKSB7XG4gICAgdmFyIHRvTm9kZUF0dHJzID0gdG9Ob2RlLmF0dHJpYnV0ZXM7XG4gICAgdmFyIGF0dHI7XG4gICAgdmFyIGF0dHJOYW1lO1xuICAgIHZhciBhdHRyTmFtZXNwYWNlVVJJO1xuICAgIHZhciBhdHRyVmFsdWU7XG4gICAgdmFyIGZyb21WYWx1ZTtcblxuICAgIC8vIGRvY3VtZW50LWZyYWdtZW50cyBkb250IGhhdmUgYXR0cmlidXRlcyBzbyBsZXRzIG5vdCBkbyBhbnl0aGluZ1xuICAgIGlmICh0b05vZGUubm9kZVR5cGUgPT09IERPQ1VNRU5UX0ZSQUdNRU5UX05PREUgfHwgZnJvbU5vZGUubm9kZVR5cGUgPT09IERPQ1VNRU5UX0ZSQUdNRU5UX05PREUpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG5cbiAgICAvLyB1cGRhdGUgYXR0cmlidXRlcyBvbiBvcmlnaW5hbCBET00gZWxlbWVudFxuICAgIGZvciAodmFyIGkgPSB0b05vZGVBdHRycy5sZW5ndGggLSAxOyBpID49IDA7IGktLSkge1xuICAgICAgICBhdHRyID0gdG9Ob2RlQXR0cnNbaV07XG4gICAgICAgIGF0dHJOYW1lID0gYXR0ci5uYW1lO1xuICAgICAgICBhdHRyTmFtZXNwYWNlVVJJID0gYXR0ci5uYW1lc3BhY2VVUkk7XG4gICAgICAgIGF0dHJWYWx1ZSA9IGF0dHIudmFsdWU7XG5cbiAgICAgICAgaWYgKGF0dHJOYW1lc3BhY2VVUkkpIHtcbiAgICAgICAgICAgIGF0dHJOYW1lID0gYXR0ci5sb2NhbE5hbWUgfHwgYXR0ck5hbWU7XG4gICAgICAgICAgICBmcm9tVmFsdWUgPSBmcm9tTm9kZS5nZXRBdHRyaWJ1dGVOUyhhdHRyTmFtZXNwYWNlVVJJLCBhdHRyTmFtZSk7XG5cbiAgICAgICAgICAgIGlmIChmcm9tVmFsdWUgIT09IGF0dHJWYWx1ZSkge1xuICAgICAgICAgICAgICAgIGlmIChhdHRyLnByZWZpeCA9PT0gJ3htbG5zJyl7XG4gICAgICAgICAgICAgICAgICAgIGF0dHJOYW1lID0gYXR0ci5uYW1lOyAvLyBJdCdzIG5vdCBhbGxvd2VkIHRvIHNldCBhbiBhdHRyaWJ1dGUgd2l0aCB0aGUgWE1MTlMgbmFtZXNwYWNlIHdpdGhvdXQgc3BlY2lmeWluZyB0aGUgYHhtbG5zYCBwcmVmaXhcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgZnJvbU5vZGUuc2V0QXR0cmlidXRlTlMoYXR0ck5hbWVzcGFjZVVSSSwgYXR0ck5hbWUsIGF0dHJWYWx1ZSk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBmcm9tVmFsdWUgPSBmcm9tTm9kZS5nZXRBdHRyaWJ1dGUoYXR0ck5hbWUpO1xuXG4gICAgICAgICAgICBpZiAoZnJvbVZhbHVlICE9PSBhdHRyVmFsdWUpIHtcbiAgICAgICAgICAgICAgICBmcm9tTm9kZS5zZXRBdHRyaWJ1dGUoYXR0ck5hbWUsIGF0dHJWYWx1ZSk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvLyBSZW1vdmUgYW55IGV4dHJhIGF0dHJpYnV0ZXMgZm91bmQgb24gdGhlIG9yaWdpbmFsIERPTSBlbGVtZW50IHRoYXRcbiAgICAvLyB3ZXJlbid0IGZvdW5kIG9uIHRoZSB0YXJnZXQgZWxlbWVudC5cbiAgICB2YXIgZnJvbU5vZGVBdHRycyA9IGZyb21Ob2RlLmF0dHJpYnV0ZXM7XG5cbiAgICBmb3IgKHZhciBkID0gZnJvbU5vZGVBdHRycy5sZW5ndGggLSAxOyBkID49IDA7IGQtLSkge1xuICAgICAgICBhdHRyID0gZnJvbU5vZGVBdHRyc1tkXTtcbiAgICAgICAgYXR0ck5hbWUgPSBhdHRyLm5hbWU7XG4gICAgICAgIGF0dHJOYW1lc3BhY2VVUkkgPSBhdHRyLm5hbWVzcGFjZVVSSTtcblxuICAgICAgICBpZiAoYXR0ck5hbWVzcGFjZVVSSSkge1xuICAgICAgICAgICAgYXR0ck5hbWUgPSBhdHRyLmxvY2FsTmFtZSB8fCBhdHRyTmFtZTtcblxuICAgICAgICAgICAgaWYgKCF0b05vZGUuaGFzQXR0cmlidXRlTlMoYXR0ck5hbWVzcGFjZVVSSSwgYXR0ck5hbWUpKSB7XG4gICAgICAgICAgICAgICAgZnJvbU5vZGUucmVtb3ZlQXR0cmlidXRlTlMoYXR0ck5hbWVzcGFjZVVSSSwgYXR0ck5hbWUpO1xuICAgICAgICAgICAgfVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgaWYgKCF0b05vZGUuaGFzQXR0cmlidXRlKGF0dHJOYW1lKSkge1xuICAgICAgICAgICAgICAgIGZyb21Ob2RlLnJlbW92ZUF0dHJpYnV0ZShhdHRyTmFtZSk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICB9XG59XG5cbnZhciByYW5nZTsgLy8gQ3JlYXRlIGEgcmFuZ2Ugb2JqZWN0IGZvciBlZmZpY2VudGx5IHJlbmRlcmluZyBzdHJpbmdzIHRvIGVsZW1lbnRzLlxudmFyIE5TX1hIVE1MID0gJ2h0dHA6Ly93d3cudzMub3JnLzE5OTkveGh0bWwnO1xuXG52YXIgZG9jID0gdHlwZW9mIGRvY3VtZW50ID09PSAndW5kZWZpbmVkJyA/IHVuZGVmaW5lZCA6IGRvY3VtZW50O1xudmFyIEhBU19URU1QTEFURV9TVVBQT1JUID0gISFkb2MgJiYgJ2NvbnRlbnQnIGluIGRvYy5jcmVhdGVFbGVtZW50KCd0ZW1wbGF0ZScpO1xudmFyIEhBU19SQU5HRV9TVVBQT1JUID0gISFkb2MgJiYgZG9jLmNyZWF0ZVJhbmdlICYmICdjcmVhdGVDb250ZXh0dWFsRnJhZ21lbnQnIGluIGRvYy5jcmVhdGVSYW5nZSgpO1xuXG5mdW5jdGlvbiBjcmVhdGVGcmFnbWVudEZyb21UZW1wbGF0ZShzdHIpIHtcbiAgICB2YXIgdGVtcGxhdGUgPSBkb2MuY3JlYXRlRWxlbWVudCgndGVtcGxhdGUnKTtcbiAgICB0ZW1wbGF0ZS5pbm5lckhUTUwgPSBzdHI7XG4gICAgcmV0dXJuIHRlbXBsYXRlLmNvbnRlbnQuY2hpbGROb2Rlc1swXTtcbn1cblxuZnVuY3Rpb24gY3JlYXRlRnJhZ21lbnRGcm9tUmFuZ2Uoc3RyKSB7XG4gICAgaWYgKCFyYW5nZSkge1xuICAgICAgICByYW5nZSA9IGRvYy5jcmVhdGVSYW5nZSgpO1xuICAgICAgICByYW5nZS5zZWxlY3ROb2RlKGRvYy5ib2R5KTtcbiAgICB9XG5cbiAgICB2YXIgZnJhZ21lbnQgPSByYW5nZS5jcmVhdGVDb250ZXh0dWFsRnJhZ21lbnQoc3RyKTtcbiAgICByZXR1cm4gZnJhZ21lbnQuY2hpbGROb2Rlc1swXTtcbn1cblxuZnVuY3Rpb24gY3JlYXRlRnJhZ21lbnRGcm9tV3JhcChzdHIpIHtcbiAgICB2YXIgZnJhZ21lbnQgPSBkb2MuY3JlYXRlRWxlbWVudCgnYm9keScpO1xuICAgIGZyYWdtZW50LmlubmVySFRNTCA9IHN0cjtcbiAgICByZXR1cm4gZnJhZ21lbnQuY2hpbGROb2Rlc1swXTtcbn1cblxuLyoqXG4gKiBUaGlzIGlzIGFib3V0IHRoZSBzYW1lXG4gKiB2YXIgaHRtbCA9IG5ldyBET01QYXJzZXIoKS5wYXJzZUZyb21TdHJpbmcoc3RyLCAndGV4dC9odG1sJyk7XG4gKiByZXR1cm4gaHRtbC5ib2R5LmZpcnN0Q2hpbGQ7XG4gKlxuICogQG1ldGhvZCB0b0VsZW1lbnRcbiAqIEBwYXJhbSB7U3RyaW5nfSBzdHJcbiAqL1xuZnVuY3Rpb24gdG9FbGVtZW50KHN0cikge1xuICAgIHN0ciA9IHN0ci50cmltKCk7XG4gICAgaWYgKEhBU19URU1QTEFURV9TVVBQT1JUKSB7XG4gICAgICAvLyBhdm9pZCByZXN0cmljdGlvbnMgb24gY29udGVudCBmb3IgdGhpbmdzIGxpa2UgYDx0cj48dGg+SGk8L3RoPjwvdHI+YCB3aGljaFxuICAgICAgLy8gY3JlYXRlQ29udGV4dHVhbEZyYWdtZW50IGRvZXNuJ3Qgc3VwcG9ydFxuICAgICAgLy8gPHRlbXBsYXRlPiBzdXBwb3J0IG5vdCBhdmFpbGFibGUgaW4gSUVcbiAgICAgIHJldHVybiBjcmVhdGVGcmFnbWVudEZyb21UZW1wbGF0ZShzdHIpO1xuICAgIH0gZWxzZSBpZiAoSEFTX1JBTkdFX1NVUFBPUlQpIHtcbiAgICAgIHJldHVybiBjcmVhdGVGcmFnbWVudEZyb21SYW5nZShzdHIpO1xuICAgIH1cblxuICAgIHJldHVybiBjcmVhdGVGcmFnbWVudEZyb21XcmFwKHN0cik7XG59XG5cbi8qKlxuICogUmV0dXJucyB0cnVlIGlmIHR3byBub2RlJ3MgbmFtZXMgYXJlIHRoZSBzYW1lLlxuICpcbiAqIE5PVEU6IFdlIGRvbid0IGJvdGhlciBjaGVja2luZyBgbmFtZXNwYWNlVVJJYCBiZWNhdXNlIHlvdSB3aWxsIG5ldmVyIGZpbmQgdHdvIEhUTUwgZWxlbWVudHMgd2l0aCB0aGUgc2FtZVxuICogICAgICAgbm9kZU5hbWUgYW5kIGRpZmZlcmVudCBuYW1lc3BhY2UgVVJJcy5cbiAqXG4gKiBAcGFyYW0ge0VsZW1lbnR9IGFcbiAqIEBwYXJhbSB7RWxlbWVudH0gYiBUaGUgdGFyZ2V0IGVsZW1lbnRcbiAqIEByZXR1cm4ge2Jvb2xlYW59XG4gKi9cbmZ1bmN0aW9uIGNvbXBhcmVOb2RlTmFtZXMoZnJvbUVsLCB0b0VsKSB7XG4gICAgdmFyIGZyb21Ob2RlTmFtZSA9IGZyb21FbC5ub2RlTmFtZTtcbiAgICB2YXIgdG9Ob2RlTmFtZSA9IHRvRWwubm9kZU5hbWU7XG4gICAgdmFyIGZyb21Db2RlU3RhcnQsIHRvQ29kZVN0YXJ0O1xuXG4gICAgaWYgKGZyb21Ob2RlTmFtZSA9PT0gdG9Ob2RlTmFtZSkge1xuICAgICAgICByZXR1cm4gdHJ1ZTtcbiAgICB9XG5cbiAgICBmcm9tQ29kZVN0YXJ0ID0gZnJvbU5vZGVOYW1lLmNoYXJDb2RlQXQoMCk7XG4gICAgdG9Db2RlU3RhcnQgPSB0b05vZGVOYW1lLmNoYXJDb2RlQXQoMCk7XG5cbiAgICAvLyBJZiB0aGUgdGFyZ2V0IGVsZW1lbnQgaXMgYSB2aXJ0dWFsIERPTSBub2RlIG9yIFNWRyBub2RlIHRoZW4gd2UgbWF5XG4gICAgLy8gbmVlZCB0byBub3JtYWxpemUgdGhlIHRhZyBuYW1lIGJlZm9yZSBjb21wYXJpbmcuIE5vcm1hbCBIVE1MIGVsZW1lbnRzIHRoYXQgYXJlXG4gICAgLy8gaW4gdGhlIFwiaHR0cDovL3d3dy53My5vcmcvMTk5OS94aHRtbFwiXG4gICAgLy8gYXJlIGNvbnZlcnRlZCB0byB1cHBlciBjYXNlXG4gICAgaWYgKGZyb21Db2RlU3RhcnQgPD0gOTAgJiYgdG9Db2RlU3RhcnQgPj0gOTcpIHsgLy8gZnJvbSBpcyB1cHBlciBhbmQgdG8gaXMgbG93ZXJcbiAgICAgICAgcmV0dXJuIGZyb21Ob2RlTmFtZSA9PT0gdG9Ob2RlTmFtZS50b1VwcGVyQ2FzZSgpO1xuICAgIH0gZWxzZSBpZiAodG9Db2RlU3RhcnQgPD0gOTAgJiYgZnJvbUNvZGVTdGFydCA+PSA5NykgeyAvLyB0byBpcyB1cHBlciBhbmQgZnJvbSBpcyBsb3dlclxuICAgICAgICByZXR1cm4gdG9Ob2RlTmFtZSA9PT0gZnJvbU5vZGVOYW1lLnRvVXBwZXJDYXNlKCk7XG4gICAgfSBlbHNlIHtcbiAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgIH1cbn1cblxuLyoqXG4gKiBDcmVhdGUgYW4gZWxlbWVudCwgb3B0aW9uYWxseSB3aXRoIGEga25vd24gbmFtZXNwYWNlIFVSSS5cbiAqXG4gKiBAcGFyYW0ge3N0cmluZ30gbmFtZSB0aGUgZWxlbWVudCBuYW1lLCBlLmcuICdkaXYnIG9yICdzdmcnXG4gKiBAcGFyYW0ge3N0cmluZ30gW25hbWVzcGFjZVVSSV0gdGhlIGVsZW1lbnQncyBuYW1lc3BhY2UgVVJJLCBpLmUuIHRoZSB2YWx1ZSBvZlxuICogaXRzIGB4bWxuc2AgYXR0cmlidXRlIG9yIGl0cyBpbmZlcnJlZCBuYW1lc3BhY2UuXG4gKlxuICogQHJldHVybiB7RWxlbWVudH1cbiAqL1xuZnVuY3Rpb24gY3JlYXRlRWxlbWVudE5TKG5hbWUsIG5hbWVzcGFjZVVSSSkge1xuICAgIHJldHVybiAhbmFtZXNwYWNlVVJJIHx8IG5hbWVzcGFjZVVSSSA9PT0gTlNfWEhUTUwgP1xuICAgICAgICBkb2MuY3JlYXRlRWxlbWVudChuYW1lKSA6XG4gICAgICAgIGRvYy5jcmVhdGVFbGVtZW50TlMobmFtZXNwYWNlVVJJLCBuYW1lKTtcbn1cblxuLyoqXG4gKiBDb3BpZXMgdGhlIGNoaWxkcmVuIG9mIG9uZSBET00gZWxlbWVudCB0byBhbm90aGVyIERPTSBlbGVtZW50XG4gKi9cbmZ1bmN0aW9uIG1vdmVDaGlsZHJlbihmcm9tRWwsIHRvRWwpIHtcbiAgICB2YXIgY3VyQ2hpbGQgPSBmcm9tRWwuZmlyc3RDaGlsZDtcbiAgICB3aGlsZSAoY3VyQ2hpbGQpIHtcbiAgICAgICAgdmFyIG5leHRDaGlsZCA9IGN1ckNoaWxkLm5leHRTaWJsaW5nO1xuICAgICAgICB0b0VsLmFwcGVuZENoaWxkKGN1ckNoaWxkKTtcbiAgICAgICAgY3VyQ2hpbGQgPSBuZXh0Q2hpbGQ7XG4gICAgfVxuICAgIHJldHVybiB0b0VsO1xufVxuXG5mdW5jdGlvbiBzeW5jQm9vbGVhbkF0dHJQcm9wKGZyb21FbCwgdG9FbCwgbmFtZSkge1xuICAgIGlmIChmcm9tRWxbbmFtZV0gIT09IHRvRWxbbmFtZV0pIHtcbiAgICAgICAgZnJvbUVsW25hbWVdID0gdG9FbFtuYW1lXTtcbiAgICAgICAgaWYgKGZyb21FbFtuYW1lXSkge1xuICAgICAgICAgICAgZnJvbUVsLnNldEF0dHJpYnV0ZShuYW1lLCAnJyk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBmcm9tRWwucmVtb3ZlQXR0cmlidXRlKG5hbWUpO1xuICAgICAgICB9XG4gICAgfVxufVxuXG52YXIgc3BlY2lhbEVsSGFuZGxlcnMgPSB7XG4gICAgT1BUSU9OOiBmdW5jdGlvbihmcm9tRWwsIHRvRWwpIHtcbiAgICAgICAgdmFyIHBhcmVudE5vZGUgPSBmcm9tRWwucGFyZW50Tm9kZTtcbiAgICAgICAgaWYgKHBhcmVudE5vZGUpIHtcbiAgICAgICAgICAgIHZhciBwYXJlbnROYW1lID0gcGFyZW50Tm9kZS5ub2RlTmFtZS50b1VwcGVyQ2FzZSgpO1xuICAgICAgICAgICAgaWYgKHBhcmVudE5hbWUgPT09ICdPUFRHUk9VUCcpIHtcbiAgICAgICAgICAgICAgICBwYXJlbnROb2RlID0gcGFyZW50Tm9kZS5wYXJlbnROb2RlO1xuICAgICAgICAgICAgICAgIHBhcmVudE5hbWUgPSBwYXJlbnROb2RlICYmIHBhcmVudE5vZGUubm9kZU5hbWUudG9VcHBlckNhc2UoKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgICAgIGlmIChwYXJlbnROYW1lID09PSAnU0VMRUNUJyAmJiAhcGFyZW50Tm9kZS5oYXNBdHRyaWJ1dGUoJ211bHRpcGxlJykpIHtcbiAgICAgICAgICAgICAgICBpZiAoZnJvbUVsLmhhc0F0dHJpYnV0ZSgnc2VsZWN0ZWQnKSAmJiAhdG9FbC5zZWxlY3RlZCkge1xuICAgICAgICAgICAgICAgICAgICAvLyBXb3JrYXJvdW5kIGZvciBNUyBFZGdlIGJ1ZyB3aGVyZSB0aGUgJ3NlbGVjdGVkJyBhdHRyaWJ1dGUgY2FuIG9ubHkgYmVcbiAgICAgICAgICAgICAgICAgICAgLy8gcmVtb3ZlZCBpZiBzZXQgdG8gYSBub24tZW1wdHkgdmFsdWU6XG4gICAgICAgICAgICAgICAgICAgIC8vIGh0dHBzOi8vZGV2ZWxvcGVyLm1pY3Jvc29mdC5jb20vZW4tdXMvbWljcm9zb2Z0LWVkZ2UvcGxhdGZvcm0vaXNzdWVzLzEyMDg3Njc5L1xuICAgICAgICAgICAgICAgICAgICBmcm9tRWwuc2V0QXR0cmlidXRlKCdzZWxlY3RlZCcsICdzZWxlY3RlZCcpO1xuICAgICAgICAgICAgICAgICAgICBmcm9tRWwucmVtb3ZlQXR0cmlidXRlKCdzZWxlY3RlZCcpO1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICAvLyBXZSBoYXZlIHRvIHJlc2V0IHNlbGVjdCBlbGVtZW50J3Mgc2VsZWN0ZWRJbmRleCB0byAtMSwgb3RoZXJ3aXNlIHNldHRpbmdcbiAgICAgICAgICAgICAgICAvLyBmcm9tRWwuc2VsZWN0ZWQgdXNpbmcgdGhlIHN5bmNCb29sZWFuQXR0clByb3AgYmVsb3cgaGFzIG5vIGVmZmVjdC5cbiAgICAgICAgICAgICAgICAvLyBUaGUgY29ycmVjdCBzZWxlY3RlZEluZGV4IHdpbGwgYmUgc2V0IGluIHRoZSBTRUxFQ1Qgc3BlY2lhbCBoYW5kbGVyIGJlbG93LlxuICAgICAgICAgICAgICAgIHBhcmVudE5vZGUuc2VsZWN0ZWRJbmRleCA9IC0xO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG4gICAgICAgIHN5bmNCb29sZWFuQXR0clByb3AoZnJvbUVsLCB0b0VsLCAnc2VsZWN0ZWQnKTtcbiAgICB9LFxuICAgIC8qKlxuICAgICAqIFRoZSBcInZhbHVlXCIgYXR0cmlidXRlIGlzIHNwZWNpYWwgZm9yIHRoZSA8aW5wdXQ+IGVsZW1lbnQgc2luY2UgaXQgc2V0c1xuICAgICAqIHRoZSBpbml0aWFsIHZhbHVlLiBDaGFuZ2luZyB0aGUgXCJ2YWx1ZVwiIGF0dHJpYnV0ZSB3aXRob3V0IGNoYW5naW5nIHRoZVxuICAgICAqIFwidmFsdWVcIiBwcm9wZXJ0eSB3aWxsIGhhdmUgbm8gZWZmZWN0IHNpbmNlIGl0IGlzIG9ubHkgdXNlZCB0byB0aGUgc2V0IHRoZVxuICAgICAqIGluaXRpYWwgdmFsdWUuICBTaW1pbGFyIGZvciB0aGUgXCJjaGVja2VkXCIgYXR0cmlidXRlLCBhbmQgXCJkaXNhYmxlZFwiLlxuICAgICAqL1xuICAgIElOUFVUOiBmdW5jdGlvbihmcm9tRWwsIHRvRWwpIHtcbiAgICAgICAgc3luY0Jvb2xlYW5BdHRyUHJvcChmcm9tRWwsIHRvRWwsICdjaGVja2VkJyk7XG4gICAgICAgIHN5bmNCb29sZWFuQXR0clByb3AoZnJvbUVsLCB0b0VsLCAnZGlzYWJsZWQnKTtcblxuICAgICAgICBpZiAoZnJvbUVsLnZhbHVlICE9PSB0b0VsLnZhbHVlKSB7XG4gICAgICAgICAgICBmcm9tRWwudmFsdWUgPSB0b0VsLnZhbHVlO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKCF0b0VsLmhhc0F0dHJpYnV0ZSgndmFsdWUnKSkge1xuICAgICAgICAgICAgZnJvbUVsLnJlbW92ZUF0dHJpYnV0ZSgndmFsdWUnKTtcbiAgICAgICAgfVxuICAgIH0sXG5cbiAgICBURVhUQVJFQTogZnVuY3Rpb24oZnJvbUVsLCB0b0VsKSB7XG4gICAgICAgIHZhciBuZXdWYWx1ZSA9IHRvRWwudmFsdWU7XG4gICAgICAgIGlmIChmcm9tRWwudmFsdWUgIT09IG5ld1ZhbHVlKSB7XG4gICAgICAgICAgICBmcm9tRWwudmFsdWUgPSBuZXdWYWx1ZTtcbiAgICAgICAgfVxuXG4gICAgICAgIHZhciBmaXJzdENoaWxkID0gZnJvbUVsLmZpcnN0Q2hpbGQ7XG4gICAgICAgIGlmIChmaXJzdENoaWxkKSB7XG4gICAgICAgICAgICAvLyBOZWVkZWQgZm9yIElFLiBBcHBhcmVudGx5IElFIHNldHMgdGhlIHBsYWNlaG9sZGVyIGFzIHRoZVxuICAgICAgICAgICAgLy8gbm9kZSB2YWx1ZSBhbmQgdmlzZSB2ZXJzYS4gVGhpcyBpZ25vcmVzIGFuIGVtcHR5IHVwZGF0ZS5cbiAgICAgICAgICAgIHZhciBvbGRWYWx1ZSA9IGZpcnN0Q2hpbGQubm9kZVZhbHVlO1xuXG4gICAgICAgICAgICBpZiAob2xkVmFsdWUgPT0gbmV3VmFsdWUgfHwgKCFuZXdWYWx1ZSAmJiBvbGRWYWx1ZSA9PSBmcm9tRWwucGxhY2Vob2xkZXIpKSB7XG4gICAgICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICBmaXJzdENoaWxkLm5vZGVWYWx1ZSA9IG5ld1ZhbHVlO1xuICAgICAgICB9XG4gICAgfSxcbiAgICBTRUxFQ1Q6IGZ1bmN0aW9uKGZyb21FbCwgdG9FbCkge1xuICAgICAgICBpZiAoIXRvRWwuaGFzQXR0cmlidXRlKCdtdWx0aXBsZScpKSB7XG4gICAgICAgICAgICB2YXIgc2VsZWN0ZWRJbmRleCA9IC0xO1xuICAgICAgICAgICAgdmFyIGkgPSAwO1xuICAgICAgICAgICAgLy8gV2UgaGF2ZSB0byBsb29wIHRocm91Z2ggY2hpbGRyZW4gb2YgZnJvbUVsLCBub3QgdG9FbCBzaW5jZSBub2RlcyBjYW4gYmUgbW92ZWRcbiAgICAgICAgICAgIC8vIGZyb20gdG9FbCB0byBmcm9tRWwgZGlyZWN0bHkgd2hlbiBtb3JwaGluZy5cbiAgICAgICAgICAgIC8vIEF0IHRoZSB0aW1lIHRoaXMgc3BlY2lhbCBoYW5kbGVyIGlzIGludm9rZWQsIGFsbCBjaGlsZHJlbiBoYXZlIGFscmVhZHkgYmVlbiBtb3JwaGVkXG4gICAgICAgICAgICAvLyBhbmQgYXBwZW5kZWQgdG8gLyByZW1vdmVkIGZyb20gZnJvbUVsLCBzbyB1c2luZyBmcm9tRWwgaGVyZSBpcyBzYWZlIGFuZCBjb3JyZWN0LlxuICAgICAgICAgICAgdmFyIGN1ckNoaWxkID0gZnJvbUVsLmZpcnN0Q2hpbGQ7XG4gICAgICAgICAgICB2YXIgb3B0Z3JvdXA7XG4gICAgICAgICAgICB2YXIgbm9kZU5hbWU7XG4gICAgICAgICAgICB3aGlsZShjdXJDaGlsZCkge1xuICAgICAgICAgICAgICAgIG5vZGVOYW1lID0gY3VyQ2hpbGQubm9kZU5hbWUgJiYgY3VyQ2hpbGQubm9kZU5hbWUudG9VcHBlckNhc2UoKTtcbiAgICAgICAgICAgICAgICBpZiAobm9kZU5hbWUgPT09ICdPUFRHUk9VUCcpIHtcbiAgICAgICAgICAgICAgICAgICAgb3B0Z3JvdXAgPSBjdXJDaGlsZDtcbiAgICAgICAgICAgICAgICAgICAgY3VyQ2hpbGQgPSBvcHRncm91cC5maXJzdENoaWxkO1xuICAgICAgICAgICAgICAgICAgICAvLyBoYW5kbGUgZW1wdHkgb3B0Z3JvdXBzXG4gICAgICAgICAgICAgICAgICAgIGlmICghY3VyQ2hpbGQpIHtcbiAgICAgICAgICAgICAgICAgICAgICAgIGN1ckNoaWxkID0gb3B0Z3JvdXAubmV4dFNpYmxpbmc7XG4gICAgICAgICAgICAgICAgICAgICAgICBvcHRncm91cCA9IG51bGw7XG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgICAgICBpZiAobm9kZU5hbWUgPT09ICdPUFRJT04nKSB7XG4gICAgICAgICAgICAgICAgICAgICAgICBpZiAoY3VyQ2hpbGQuaGFzQXR0cmlidXRlKCdzZWxlY3RlZCcpKSB7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgc2VsZWN0ZWRJbmRleCA9IGk7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgYnJlYWs7XG4gICAgICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgICAgICAgICBpKys7XG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICAgICAgY3VyQ2hpbGQgPSBjdXJDaGlsZC5uZXh0U2libGluZztcbiAgICAgICAgICAgICAgICAgICAgaWYgKCFjdXJDaGlsZCAmJiBvcHRncm91cCkge1xuICAgICAgICAgICAgICAgICAgICAgICAgY3VyQ2hpbGQgPSBvcHRncm91cC5uZXh0U2libGluZztcbiAgICAgICAgICAgICAgICAgICAgICAgIG9wdGdyb3VwID0gbnVsbDtcbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgZnJvbUVsLnNlbGVjdGVkSW5kZXggPSBzZWxlY3RlZEluZGV4O1xuICAgICAgICB9XG4gICAgfVxufTtcblxudmFyIEVMRU1FTlRfTk9ERSA9IDE7XG52YXIgRE9DVU1FTlRfRlJBR01FTlRfTk9ERSQxID0gMTE7XG52YXIgVEVYVF9OT0RFID0gMztcbnZhciBDT01NRU5UX05PREUgPSA4O1xuXG5mdW5jdGlvbiBub29wKCkge31cblxuZnVuY3Rpb24gZGVmYXVsdEdldE5vZGVLZXkobm9kZSkge1xuICBpZiAobm9kZSkge1xuICAgIHJldHVybiAobm9kZS5nZXRBdHRyaWJ1dGUgJiYgbm9kZS5nZXRBdHRyaWJ1dGUoJ2lkJykpIHx8IG5vZGUuaWQ7XG4gIH1cbn1cblxuZnVuY3Rpb24gbW9ycGhkb21GYWN0b3J5KG1vcnBoQXR0cnMpIHtcblxuICByZXR1cm4gZnVuY3Rpb24gbW9ycGhkb20oZnJvbU5vZGUsIHRvTm9kZSwgb3B0aW9ucykge1xuICAgIGlmICghb3B0aW9ucykge1xuICAgICAgb3B0aW9ucyA9IHt9O1xuICAgIH1cblxuICAgIGlmICh0eXBlb2YgdG9Ob2RlID09PSAnc3RyaW5nJykge1xuICAgICAgaWYgKGZyb21Ob2RlLm5vZGVOYW1lID09PSAnI2RvY3VtZW50JyB8fCBmcm9tTm9kZS5ub2RlTmFtZSA9PT0gJ0hUTUwnIHx8IGZyb21Ob2RlLm5vZGVOYW1lID09PSAnQk9EWScpIHtcbiAgICAgICAgdmFyIHRvTm9kZUh0bWwgPSB0b05vZGU7XG4gICAgICAgIHRvTm9kZSA9IGRvYy5jcmVhdGVFbGVtZW50KCdodG1sJyk7XG4gICAgICAgIHRvTm9kZS5pbm5lckhUTUwgPSB0b05vZGVIdG1sO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdG9Ob2RlID0gdG9FbGVtZW50KHRvTm9kZSk7XG4gICAgICB9XG4gICAgfSBlbHNlIGlmICh0b05vZGUubm9kZVR5cGUgPT09IERPQ1VNRU5UX0ZSQUdNRU5UX05PREUkMSkge1xuICAgICAgdG9Ob2RlID0gdG9Ob2RlLmZpcnN0RWxlbWVudENoaWxkO1xuICAgIH1cblxuICAgIHZhciBnZXROb2RlS2V5ID0gb3B0aW9ucy5nZXROb2RlS2V5IHx8IGRlZmF1bHRHZXROb2RlS2V5O1xuICAgIHZhciBvbkJlZm9yZU5vZGVBZGRlZCA9IG9wdGlvbnMub25CZWZvcmVOb2RlQWRkZWQgfHwgbm9vcDtcbiAgICB2YXIgb25Ob2RlQWRkZWQgPSBvcHRpb25zLm9uTm9kZUFkZGVkIHx8IG5vb3A7XG4gICAgdmFyIG9uQmVmb3JlRWxVcGRhdGVkID0gb3B0aW9ucy5vbkJlZm9yZUVsVXBkYXRlZCB8fCBub29wO1xuICAgIHZhciBvbkVsVXBkYXRlZCA9IG9wdGlvbnMub25FbFVwZGF0ZWQgfHwgbm9vcDtcbiAgICB2YXIgb25CZWZvcmVOb2RlRGlzY2FyZGVkID0gb3B0aW9ucy5vbkJlZm9yZU5vZGVEaXNjYXJkZWQgfHwgbm9vcDtcbiAgICB2YXIgb25Ob2RlRGlzY2FyZGVkID0gb3B0aW9ucy5vbk5vZGVEaXNjYXJkZWQgfHwgbm9vcDtcbiAgICB2YXIgb25CZWZvcmVFbENoaWxkcmVuVXBkYXRlZCA9IG9wdGlvbnMub25CZWZvcmVFbENoaWxkcmVuVXBkYXRlZCB8fCBub29wO1xuICAgIHZhciBza2lwRnJvbUNoaWxkcmVuID0gb3B0aW9ucy5za2lwRnJvbUNoaWxkcmVuIHx8IG5vb3A7XG4gICAgdmFyIGFkZENoaWxkID0gb3B0aW9ucy5hZGRDaGlsZCB8fCBmdW5jdGlvbihwYXJlbnQsIGNoaWxkKXsgcmV0dXJuIHBhcmVudC5hcHBlbmRDaGlsZChjaGlsZCk7IH07XG4gICAgdmFyIGNoaWxkcmVuT25seSA9IG9wdGlvbnMuY2hpbGRyZW5Pbmx5ID09PSB0cnVlO1xuXG4gICAgLy8gVGhpcyBvYmplY3QgaXMgdXNlZCBhcyBhIGxvb2t1cCB0byBxdWlja2x5IGZpbmQgYWxsIGtleWVkIGVsZW1lbnRzIGluIHRoZSBvcmlnaW5hbCBET00gdHJlZS5cbiAgICB2YXIgZnJvbU5vZGVzTG9va3VwID0gT2JqZWN0LmNyZWF0ZShudWxsKTtcbiAgICB2YXIga2V5ZWRSZW1vdmFsTGlzdCA9IFtdO1xuXG4gICAgZnVuY3Rpb24gYWRkS2V5ZWRSZW1vdmFsKGtleSkge1xuICAgICAga2V5ZWRSZW1vdmFsTGlzdC5wdXNoKGtleSk7XG4gICAgfVxuXG4gICAgZnVuY3Rpb24gd2Fsa0Rpc2NhcmRlZENoaWxkTm9kZXMobm9kZSwgc2tpcEtleWVkTm9kZXMpIHtcbiAgICAgIGlmIChub2RlLm5vZGVUeXBlID09PSBFTEVNRU5UX05PREUpIHtcbiAgICAgICAgdmFyIGN1ckNoaWxkID0gbm9kZS5maXJzdENoaWxkO1xuICAgICAgICB3aGlsZSAoY3VyQ2hpbGQpIHtcblxuICAgICAgICAgIHZhciBrZXkgPSB1bmRlZmluZWQ7XG5cbiAgICAgICAgICBpZiAoc2tpcEtleWVkTm9kZXMgJiYgKGtleSA9IGdldE5vZGVLZXkoY3VyQ2hpbGQpKSkge1xuICAgICAgICAgICAgLy8gSWYgd2UgYXJlIHNraXBwaW5nIGtleWVkIG5vZGVzIHRoZW4gd2UgYWRkIHRoZSBrZXlcbiAgICAgICAgICAgIC8vIHRvIGEgbGlzdCBzbyB0aGF0IGl0IGNhbiBiZSBoYW5kbGVkIGF0IHRoZSB2ZXJ5IGVuZC5cbiAgICAgICAgICAgIGFkZEtleWVkUmVtb3ZhbChrZXkpO1xuICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAvLyBPbmx5IHJlcG9ydCB0aGUgbm9kZSBhcyBkaXNjYXJkZWQgaWYgaXQgaXMgbm90IGtleWVkLiBXZSBkbyB0aGlzIGJlY2F1c2VcbiAgICAgICAgICAgIC8vIGF0IHRoZSBlbmQgd2UgbG9vcCB0aHJvdWdoIGFsbCBrZXllZCBlbGVtZW50cyB0aGF0IHdlcmUgdW5tYXRjaGVkXG4gICAgICAgICAgICAvLyBhbmQgdGhlbiBkaXNjYXJkIHRoZW0gaW4gb25lIGZpbmFsIHBhc3MuXG4gICAgICAgICAgICBvbk5vZGVEaXNjYXJkZWQoY3VyQ2hpbGQpO1xuICAgICAgICAgICAgaWYgKGN1ckNoaWxkLmZpcnN0Q2hpbGQpIHtcbiAgICAgICAgICAgICAgd2Fsa0Rpc2NhcmRlZENoaWxkTm9kZXMoY3VyQ2hpbGQsIHNraXBLZXllZE5vZGVzKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgICB9XG5cbiAgICAgICAgICBjdXJDaGlsZCA9IGN1ckNoaWxkLm5leHRTaWJsaW5nO1xuICAgICAgICB9XG4gICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgKiBSZW1vdmVzIGEgRE9NIG5vZGUgb3V0IG9mIHRoZSBvcmlnaW5hbCBET01cbiAgICAqXG4gICAgKiBAcGFyYW0gIHtOb2RlfSBub2RlIFRoZSBub2RlIHRvIHJlbW92ZVxuICAgICogQHBhcmFtICB7Tm9kZX0gcGFyZW50Tm9kZSBUaGUgbm9kZXMgcGFyZW50XG4gICAgKiBAcGFyYW0gIHtCb29sZWFufSBza2lwS2V5ZWROb2RlcyBJZiB0cnVlIHRoZW4gZWxlbWVudHMgd2l0aCBrZXlzIHdpbGwgYmUgc2tpcHBlZCBhbmQgbm90IGRpc2NhcmRlZC5cbiAgICAqIEByZXR1cm4ge3VuZGVmaW5lZH1cbiAgICAqL1xuICAgIGZ1bmN0aW9uIHJlbW92ZU5vZGUobm9kZSwgcGFyZW50Tm9kZSwgc2tpcEtleWVkTm9kZXMpIHtcbiAgICAgIGlmIChvbkJlZm9yZU5vZGVEaXNjYXJkZWQobm9kZSkgPT09IGZhbHNlKSB7XG4gICAgICAgIHJldHVybjtcbiAgICAgIH1cblxuICAgICAgaWYgKHBhcmVudE5vZGUpIHtcbiAgICAgICAgcGFyZW50Tm9kZS5yZW1vdmVDaGlsZChub2RlKTtcbiAgICAgIH1cblxuICAgICAgb25Ob2RlRGlzY2FyZGVkKG5vZGUpO1xuICAgICAgd2Fsa0Rpc2NhcmRlZENoaWxkTm9kZXMobm9kZSwgc2tpcEtleWVkTm9kZXMpO1xuICAgIH1cblxuICAgIC8vIC8vIFRyZWVXYWxrZXIgaW1wbGVtZW50YXRpb24gaXMgbm8gZmFzdGVyLCBidXQga2VlcGluZyB0aGlzIGFyb3VuZCBpbiBjYXNlIHRoaXMgY2hhbmdlcyBpbiB0aGUgZnV0dXJlXG4gICAgLy8gZnVuY3Rpb24gaW5kZXhUcmVlKHJvb3QpIHtcbiAgICAvLyAgICAgdmFyIHRyZWVXYWxrZXIgPSBkb2N1bWVudC5jcmVhdGVUcmVlV2Fsa2VyKFxuICAgIC8vICAgICAgICAgcm9vdCxcbiAgICAvLyAgICAgICAgIE5vZGVGaWx0ZXIuU0hPV19FTEVNRU5UKTtcbiAgICAvL1xuICAgIC8vICAgICB2YXIgZWw7XG4gICAgLy8gICAgIHdoaWxlKChlbCA9IHRyZWVXYWxrZXIubmV4dE5vZGUoKSkpIHtcbiAgICAvLyAgICAgICAgIHZhciBrZXkgPSBnZXROb2RlS2V5KGVsKTtcbiAgICAvLyAgICAgICAgIGlmIChrZXkpIHtcbiAgICAvLyAgICAgICAgICAgICBmcm9tTm9kZXNMb29rdXBba2V5XSA9IGVsO1xuICAgIC8vICAgICAgICAgfVxuICAgIC8vICAgICB9XG4gICAgLy8gfVxuXG4gICAgLy8gLy8gTm9kZUl0ZXJhdG9yIGltcGxlbWVudGF0aW9uIGlzIG5vIGZhc3RlciwgYnV0IGtlZXBpbmcgdGhpcyBhcm91bmQgaW4gY2FzZSB0aGlzIGNoYW5nZXMgaW4gdGhlIGZ1dHVyZVxuICAgIC8vXG4gICAgLy8gZnVuY3Rpb24gaW5kZXhUcmVlKG5vZGUpIHtcbiAgICAvLyAgICAgdmFyIG5vZGVJdGVyYXRvciA9IGRvY3VtZW50LmNyZWF0ZU5vZGVJdGVyYXRvcihub2RlLCBOb2RlRmlsdGVyLlNIT1dfRUxFTUVOVCk7XG4gICAgLy8gICAgIHZhciBlbDtcbiAgICAvLyAgICAgd2hpbGUoKGVsID0gbm9kZUl0ZXJhdG9yLm5leHROb2RlKCkpKSB7XG4gICAgLy8gICAgICAgICB2YXIga2V5ID0gZ2V0Tm9kZUtleShlbCk7XG4gICAgLy8gICAgICAgICBpZiAoa2V5KSB7XG4gICAgLy8gICAgICAgICAgICAgZnJvbU5vZGVzTG9va3VwW2tleV0gPSBlbDtcbiAgICAvLyAgICAgICAgIH1cbiAgICAvLyAgICAgfVxuICAgIC8vIH1cblxuICAgIGZ1bmN0aW9uIGluZGV4VHJlZShub2RlKSB7XG4gICAgICBpZiAobm9kZS5ub2RlVHlwZSA9PT0gRUxFTUVOVF9OT0RFIHx8IG5vZGUubm9kZVR5cGUgPT09IERPQ1VNRU5UX0ZSQUdNRU5UX05PREUkMSkge1xuICAgICAgICB2YXIgY3VyQ2hpbGQgPSBub2RlLmZpcnN0Q2hpbGQ7XG4gICAgICAgIHdoaWxlIChjdXJDaGlsZCkge1xuICAgICAgICAgIHZhciBrZXkgPSBnZXROb2RlS2V5KGN1ckNoaWxkKTtcbiAgICAgICAgICBpZiAoa2V5KSB7XG4gICAgICAgICAgICBmcm9tTm9kZXNMb29rdXBba2V5XSA9IGN1ckNoaWxkO1xuICAgICAgICAgIH1cblxuICAgICAgICAgIC8vIFdhbGsgcmVjdXJzaXZlbHlcbiAgICAgICAgICBpbmRleFRyZWUoY3VyQ2hpbGQpO1xuXG4gICAgICAgICAgY3VyQ2hpbGQgPSBjdXJDaGlsZC5uZXh0U2libGluZztcbiAgICAgICAgfVxuICAgICAgfVxuICAgIH1cblxuICAgIGluZGV4VHJlZShmcm9tTm9kZSk7XG5cbiAgICBmdW5jdGlvbiBoYW5kbGVOb2RlQWRkZWQoZWwpIHtcbiAgICAgIG9uTm9kZUFkZGVkKGVsKTtcblxuICAgICAgdmFyIGN1ckNoaWxkID0gZWwuZmlyc3RDaGlsZDtcbiAgICAgIHdoaWxlIChjdXJDaGlsZCkge1xuICAgICAgICB2YXIgbmV4dFNpYmxpbmcgPSBjdXJDaGlsZC5uZXh0U2libGluZztcblxuICAgICAgICB2YXIga2V5ID0gZ2V0Tm9kZUtleShjdXJDaGlsZCk7XG4gICAgICAgIGlmIChrZXkpIHtcbiAgICAgICAgICB2YXIgdW5tYXRjaGVkRnJvbUVsID0gZnJvbU5vZGVzTG9va3VwW2tleV07XG4gICAgICAgICAgLy8gaWYgd2UgZmluZCBhIGR1cGxpY2F0ZSAjaWQgbm9kZSBpbiBjYWNoZSwgcmVwbGFjZSBgZWxgIHdpdGggY2FjaGUgdmFsdWVcbiAgICAgICAgICAvLyBhbmQgbW9ycGggaXQgdG8gdGhlIGNoaWxkIG5vZGUuXG4gICAgICAgICAgaWYgKHVubWF0Y2hlZEZyb21FbCAmJiBjb21wYXJlTm9kZU5hbWVzKGN1ckNoaWxkLCB1bm1hdGNoZWRGcm9tRWwpKSB7XG4gICAgICAgICAgICBjdXJDaGlsZC5wYXJlbnROb2RlLnJlcGxhY2VDaGlsZCh1bm1hdGNoZWRGcm9tRWwsIGN1ckNoaWxkKTtcbiAgICAgICAgICAgIG1vcnBoRWwodW5tYXRjaGVkRnJvbUVsLCBjdXJDaGlsZCk7XG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGhhbmRsZU5vZGVBZGRlZChjdXJDaGlsZCk7XG4gICAgICAgICAgfVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIC8vIHJlY3Vyc2l2ZWx5IGNhbGwgZm9yIGN1ckNoaWxkIGFuZCBpdCdzIGNoaWxkcmVuIHRvIHNlZSBpZiB3ZSBmaW5kIHNvbWV0aGluZyBpblxuICAgICAgICAgIC8vIGZyb21Ob2Rlc0xvb2t1cFxuICAgICAgICAgIGhhbmRsZU5vZGVBZGRlZChjdXJDaGlsZCk7XG4gICAgICAgIH1cblxuICAgICAgICBjdXJDaGlsZCA9IG5leHRTaWJsaW5nO1xuICAgICAgfVxuICAgIH1cblxuICAgIGZ1bmN0aW9uIGNsZWFudXBGcm9tRWwoZnJvbUVsLCBjdXJGcm9tTm9kZUNoaWxkLCBjdXJGcm9tTm9kZUtleSkge1xuICAgICAgLy8gV2UgaGF2ZSBwcm9jZXNzZWQgYWxsIG9mIHRoZSBcInRvIG5vZGVzXCIuIElmIGN1ckZyb21Ob2RlQ2hpbGQgaXNcbiAgICAgIC8vIG5vbi1udWxsIHRoZW4gd2Ugc3RpbGwgaGF2ZSBzb21lIGZyb20gbm9kZXMgbGVmdCBvdmVyIHRoYXQgbmVlZFxuICAgICAgLy8gdG8gYmUgcmVtb3ZlZFxuICAgICAgd2hpbGUgKGN1ckZyb21Ob2RlQ2hpbGQpIHtcbiAgICAgICAgdmFyIGZyb21OZXh0U2libGluZyA9IGN1ckZyb21Ob2RlQ2hpbGQubmV4dFNpYmxpbmc7XG4gICAgICAgIGlmICgoY3VyRnJvbU5vZGVLZXkgPSBnZXROb2RlS2V5KGN1ckZyb21Ob2RlQ2hpbGQpKSkge1xuICAgICAgICAgIC8vIFNpbmNlIHRoZSBub2RlIGlzIGtleWVkIGl0IG1pZ2h0IGJlIG1hdGNoZWQgdXAgbGF0ZXIgc28gd2UgZGVmZXJcbiAgICAgICAgICAvLyB0aGUgYWN0dWFsIHJlbW92YWwgdG8gbGF0ZXJcbiAgICAgICAgICBhZGRLZXllZFJlbW92YWwoY3VyRnJvbU5vZGVLZXkpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIC8vIE5PVEU6IHdlIHNraXAgbmVzdGVkIGtleWVkIG5vZGVzIGZyb20gYmVpbmcgcmVtb3ZlZCBzaW5jZSB0aGVyZSBpc1xuICAgICAgICAgIC8vICAgICAgIHN0aWxsIGEgY2hhbmNlIHRoZXkgd2lsbCBiZSBtYXRjaGVkIHVwIGxhdGVyXG4gICAgICAgICAgcmVtb3ZlTm9kZShjdXJGcm9tTm9kZUNoaWxkLCBmcm9tRWwsIHRydWUgLyogc2tpcCBrZXllZCBub2RlcyAqLyk7XG4gICAgICAgIH1cbiAgICAgICAgY3VyRnJvbU5vZGVDaGlsZCA9IGZyb21OZXh0U2libGluZztcbiAgICAgIH1cbiAgICB9XG5cbiAgICBmdW5jdGlvbiBtb3JwaEVsKGZyb21FbCwgdG9FbCwgY2hpbGRyZW5Pbmx5KSB7XG4gICAgICB2YXIgdG9FbEtleSA9IGdldE5vZGVLZXkodG9FbCk7XG5cbiAgICAgIGlmICh0b0VsS2V5KSB7XG4gICAgICAgIC8vIElmIGFuIGVsZW1lbnQgd2l0aCBhbiBJRCBpcyBiZWluZyBtb3JwaGVkIHRoZW4gaXQgd2lsbCBiZSBpbiB0aGUgZmluYWxcbiAgICAgICAgLy8gRE9NIHNvIGNsZWFyIGl0IG91dCBvZiB0aGUgc2F2ZWQgZWxlbWVudHMgY29sbGVjdGlvblxuICAgICAgICBkZWxldGUgZnJvbU5vZGVzTG9va3VwW3RvRWxLZXldO1xuICAgICAgfVxuXG4gICAgICBpZiAoIWNoaWxkcmVuT25seSkge1xuICAgICAgICAvLyBvcHRpb25hbFxuICAgICAgICB2YXIgYmVmb3JlVXBkYXRlUmVzdWx0ID0gb25CZWZvcmVFbFVwZGF0ZWQoZnJvbUVsLCB0b0VsKTtcbiAgICAgICAgaWYgKGJlZm9yZVVwZGF0ZVJlc3VsdCA9PT0gZmFsc2UpIHtcbiAgICAgICAgICByZXR1cm47XG4gICAgICAgIH0gZWxzZSBpZiAoYmVmb3JlVXBkYXRlUmVzdWx0IGluc3RhbmNlb2YgSFRNTEVsZW1lbnQpIHtcbiAgICAgICAgICBmcm9tRWwgPSBiZWZvcmVVcGRhdGVSZXN1bHQ7XG4gICAgICAgICAgLy8gcmVpbmRleCB0aGUgbmV3IGZyb21FbCBpbiBjYXNlIGl0J3Mgbm90IGluIHRoZSBzYW1lXG4gICAgICAgICAgLy8gdHJlZSBhcyB0aGUgb3JpZ2luYWwgZnJvbUVsXG4gICAgICAgICAgLy8gKFBob2VuaXggTGl2ZVZpZXcgc29tZXRpbWVzIHJldHVybnMgYSBjbG9uZWQgdHJlZSxcbiAgICAgICAgICAvLyAgYnV0IGtleWVkIGxvb2t1cHMgd291bGQgc3RpbGwgcG9pbnQgdG8gdGhlIG9yaWdpbmFsIHRyZWUpXG4gICAgICAgICAgaW5kZXhUcmVlKGZyb21FbCk7XG4gICAgICAgIH1cblxuICAgICAgICAvLyB1cGRhdGUgYXR0cmlidXRlcyBvbiBvcmlnaW5hbCBET00gZWxlbWVudCBmaXJzdFxuICAgICAgICBtb3JwaEF0dHJzKGZyb21FbCwgdG9FbCk7XG4gICAgICAgIC8vIG9wdGlvbmFsXG4gICAgICAgIG9uRWxVcGRhdGVkKGZyb21FbCk7XG5cbiAgICAgICAgaWYgKG9uQmVmb3JlRWxDaGlsZHJlblVwZGF0ZWQoZnJvbUVsLCB0b0VsKSA9PT0gZmFsc2UpIHtcbiAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cbiAgICAgIH1cblxuICAgICAgaWYgKGZyb21FbC5ub2RlTmFtZSAhPT0gJ1RFWFRBUkVBJykge1xuICAgICAgICBtb3JwaENoaWxkcmVuKGZyb21FbCwgdG9FbCk7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICBzcGVjaWFsRWxIYW5kbGVycy5URVhUQVJFQShmcm9tRWwsIHRvRWwpO1xuICAgICAgfVxuICAgIH1cblxuICAgIGZ1bmN0aW9uIG1vcnBoQ2hpbGRyZW4oZnJvbUVsLCB0b0VsKSB7XG4gICAgICB2YXIgc2tpcEZyb20gPSBza2lwRnJvbUNoaWxkcmVuKGZyb21FbCwgdG9FbCk7XG4gICAgICB2YXIgY3VyVG9Ob2RlQ2hpbGQgPSB0b0VsLmZpcnN0Q2hpbGQ7XG4gICAgICB2YXIgY3VyRnJvbU5vZGVDaGlsZCA9IGZyb21FbC5maXJzdENoaWxkO1xuICAgICAgdmFyIGN1clRvTm9kZUtleTtcbiAgICAgIHZhciBjdXJGcm9tTm9kZUtleTtcblxuICAgICAgdmFyIGZyb21OZXh0U2libGluZztcbiAgICAgIHZhciB0b05leHRTaWJsaW5nO1xuICAgICAgdmFyIG1hdGNoaW5nRnJvbUVsO1xuXG4gICAgICAvLyB3YWxrIHRoZSBjaGlsZHJlblxuICAgICAgb3V0ZXI6IHdoaWxlIChjdXJUb05vZGVDaGlsZCkge1xuICAgICAgICB0b05leHRTaWJsaW5nID0gY3VyVG9Ob2RlQ2hpbGQubmV4dFNpYmxpbmc7XG4gICAgICAgIGN1clRvTm9kZUtleSA9IGdldE5vZGVLZXkoY3VyVG9Ob2RlQ2hpbGQpO1xuXG4gICAgICAgIC8vIHdhbGsgdGhlIGZyb21Ob2RlIGNoaWxkcmVuIGFsbCB0aGUgd2F5IHRocm91Z2hcbiAgICAgICAgd2hpbGUgKCFza2lwRnJvbSAmJiBjdXJGcm9tTm9kZUNoaWxkKSB7XG4gICAgICAgICAgZnJvbU5leHRTaWJsaW5nID0gY3VyRnJvbU5vZGVDaGlsZC5uZXh0U2libGluZztcblxuICAgICAgICAgIGlmIChjdXJUb05vZGVDaGlsZC5pc1NhbWVOb2RlICYmIGN1clRvTm9kZUNoaWxkLmlzU2FtZU5vZGUoY3VyRnJvbU5vZGVDaGlsZCkpIHtcbiAgICAgICAgICAgIGN1clRvTm9kZUNoaWxkID0gdG9OZXh0U2libGluZztcbiAgICAgICAgICAgIGN1ckZyb21Ob2RlQ2hpbGQgPSBmcm9tTmV4dFNpYmxpbmc7XG4gICAgICAgICAgICBjb250aW51ZSBvdXRlcjtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICBjdXJGcm9tTm9kZUtleSA9IGdldE5vZGVLZXkoY3VyRnJvbU5vZGVDaGlsZCk7XG5cbiAgICAgICAgICB2YXIgY3VyRnJvbU5vZGVUeXBlID0gY3VyRnJvbU5vZGVDaGlsZC5ub2RlVHlwZTtcblxuICAgICAgICAgIC8vIHRoaXMgbWVhbnMgaWYgdGhlIGN1ckZyb21Ob2RlQ2hpbGQgZG9lc250IGhhdmUgYSBtYXRjaCB3aXRoIHRoZSBjdXJUb05vZGVDaGlsZFxuICAgICAgICAgIHZhciBpc0NvbXBhdGlibGUgPSB1bmRlZmluZWQ7XG5cbiAgICAgICAgICBpZiAoY3VyRnJvbU5vZGVUeXBlID09PSBjdXJUb05vZGVDaGlsZC5ub2RlVHlwZSkge1xuICAgICAgICAgICAgaWYgKGN1ckZyb21Ob2RlVHlwZSA9PT0gRUxFTUVOVF9OT0RFKSB7XG4gICAgICAgICAgICAgIC8vIEJvdGggbm9kZXMgYmVpbmcgY29tcGFyZWQgYXJlIEVsZW1lbnQgbm9kZXNcblxuICAgICAgICAgICAgICBpZiAoY3VyVG9Ob2RlS2V5KSB7XG4gICAgICAgICAgICAgICAgLy8gVGhlIHRhcmdldCBub2RlIGhhcyBhIGtleSBzbyB3ZSB3YW50IHRvIG1hdGNoIGl0IHVwIHdpdGggdGhlIGNvcnJlY3QgZWxlbWVudFxuICAgICAgICAgICAgICAgIC8vIGluIHRoZSBvcmlnaW5hbCBET00gdHJlZVxuICAgICAgICAgICAgICAgIGlmIChjdXJUb05vZGVLZXkgIT09IGN1ckZyb21Ob2RlS2V5KSB7XG4gICAgICAgICAgICAgICAgICAvLyBUaGUgY3VycmVudCBlbGVtZW50IGluIHRoZSBvcmlnaW5hbCBET00gdHJlZSBkb2VzIG5vdCBoYXZlIGEgbWF0Y2hpbmcga2V5IHNvXG4gICAgICAgICAgICAgICAgICAvLyBsZXQncyBjaGVjayBvdXIgbG9va3VwIHRvIHNlZSBpZiB0aGVyZSBpcyBhIG1hdGNoaW5nIGVsZW1lbnQgaW4gdGhlIG9yaWdpbmFsXG4gICAgICAgICAgICAgICAgICAvLyBET00gdHJlZVxuICAgICAgICAgICAgICAgICAgaWYgKChtYXRjaGluZ0Zyb21FbCA9IGZyb21Ob2Rlc0xvb2t1cFtjdXJUb05vZGVLZXldKSkge1xuICAgICAgICAgICAgICAgICAgICBpZiAoZnJvbU5leHRTaWJsaW5nID09PSBtYXRjaGluZ0Zyb21FbCkge1xuICAgICAgICAgICAgICAgICAgICAgIC8vIFNwZWNpYWwgY2FzZSBmb3Igc2luZ2xlIGVsZW1lbnQgcmVtb3ZhbHMuIFRvIGF2b2lkIHJlbW92aW5nIHRoZSBvcmlnaW5hbFxuICAgICAgICAgICAgICAgICAgICAgIC8vIERPTSBub2RlIG91dCBvZiB0aGUgdHJlZSAoc2luY2UgdGhhdCBjYW4gYnJlYWsgQ1NTIHRyYW5zaXRpb25zLCBldGMuKSxcbiAgICAgICAgICAgICAgICAgICAgICAvLyB3ZSB3aWxsIGluc3RlYWQgZGlzY2FyZCB0aGUgY3VycmVudCBub2RlIGFuZCB3YWl0IHVudGlsIHRoZSBuZXh0XG4gICAgICAgICAgICAgICAgICAgICAgLy8gaXRlcmF0aW9uIHRvIHByb3Blcmx5IG1hdGNoIHVwIHRoZSBrZXllZCB0YXJnZXQgZWxlbWVudCB3aXRoIGl0cyBtYXRjaGluZ1xuICAgICAgICAgICAgICAgICAgICAgIC8vIGVsZW1lbnQgaW4gdGhlIG9yaWdpbmFsIHRyZWVcbiAgICAgICAgICAgICAgICAgICAgICBpc0NvbXBhdGlibGUgPSBmYWxzZTtcbiAgICAgICAgICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICAgICAgICAvLyBXZSBmb3VuZCBhIG1hdGNoaW5nIGtleWVkIGVsZW1lbnQgc29tZXdoZXJlIGluIHRoZSBvcmlnaW5hbCBET00gdHJlZS5cbiAgICAgICAgICAgICAgICAgICAgICAvLyBMZXQncyBtb3ZlIHRoZSBvcmlnaW5hbCBET00gbm9kZSBpbnRvIHRoZSBjdXJyZW50IHBvc2l0aW9uIGFuZCBtb3JwaFxuICAgICAgICAgICAgICAgICAgICAgIC8vIGl0LlxuXG4gICAgICAgICAgICAgICAgICAgICAgLy8gTk9URTogV2UgdXNlIGluc2VydEJlZm9yZSBpbnN0ZWFkIG9mIHJlcGxhY2VDaGlsZCBiZWNhdXNlIHdlIHdhbnQgdG8gZ28gdGhyb3VnaFxuICAgICAgICAgICAgICAgICAgICAgIC8vIHRoZSBgcmVtb3ZlTm9kZSgpYCBmdW5jdGlvbiBmb3IgdGhlIG5vZGUgdGhhdCBpcyBiZWluZyBkaXNjYXJkZWQgc28gdGhhdFxuICAgICAgICAgICAgICAgICAgICAgIC8vIGFsbCBsaWZlY3ljbGUgaG9va3MgYXJlIGNvcnJlY3RseSBpbnZva2VkXG4gICAgICAgICAgICAgICAgICAgICAgZnJvbUVsLmluc2VydEJlZm9yZShtYXRjaGluZ0Zyb21FbCwgY3VyRnJvbU5vZGVDaGlsZCk7XG5cbiAgICAgICAgICAgICAgICAgICAgICAvLyBmcm9tTmV4dFNpYmxpbmcgPSBjdXJGcm9tTm9kZUNoaWxkLm5leHRTaWJsaW5nO1xuXG4gICAgICAgICAgICAgICAgICAgICAgaWYgKGN1ckZyb21Ob2RlS2V5KSB7XG4gICAgICAgICAgICAgICAgICAgICAgICAvLyBTaW5jZSB0aGUgbm9kZSBpcyBrZXllZCBpdCBtaWdodCBiZSBtYXRjaGVkIHVwIGxhdGVyIHNvIHdlIGRlZmVyXG4gICAgICAgICAgICAgICAgICAgICAgICAvLyB0aGUgYWN0dWFsIHJlbW92YWwgdG8gbGF0ZXJcbiAgICAgICAgICAgICAgICAgICAgICAgIGFkZEtleWVkUmVtb3ZhbChjdXJGcm9tTm9kZUtleSk7XG4gICAgICAgICAgICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICAgICAgICAgIC8vIE5PVEU6IHdlIHNraXAgbmVzdGVkIGtleWVkIG5vZGVzIGZyb20gYmVpbmcgcmVtb3ZlZCBzaW5jZSB0aGVyZSBpc1xuICAgICAgICAgICAgICAgICAgICAgICAgLy8gICAgICAgc3RpbGwgYSBjaGFuY2UgdGhleSB3aWxsIGJlIG1hdGNoZWQgdXAgbGF0ZXJcbiAgICAgICAgICAgICAgICAgICAgICAgIHJlbW92ZU5vZGUoY3VyRnJvbU5vZGVDaGlsZCwgZnJvbUVsLCB0cnVlIC8qIHNraXAga2V5ZWQgbm9kZXMgKi8pO1xuICAgICAgICAgICAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgICAgICAgICAgIGN1ckZyb21Ob2RlQ2hpbGQgPSBtYXRjaGluZ0Zyb21FbDtcbiAgICAgICAgICAgICAgICAgICAgICBjdXJGcm9tTm9kZUtleSA9IGdldE5vZGVLZXkoY3VyRnJvbU5vZGVDaGlsZCk7XG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgIC8vIFRoZSBub2RlcyBhcmUgbm90IGNvbXBhdGlibGUgc2luY2UgdGhlIFwidG9cIiBub2RlIGhhcyBhIGtleSBhbmQgdGhlcmVcbiAgICAgICAgICAgICAgICAgICAgLy8gaXMgbm8gbWF0Y2hpbmcga2V5ZWQgbm9kZSBpbiB0aGUgc291cmNlIHRyZWVcbiAgICAgICAgICAgICAgICAgICAgaXNDb21wYXRpYmxlID0gZmFsc2U7XG4gICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICB9IGVsc2UgaWYgKGN1ckZyb21Ob2RlS2V5KSB7XG4gICAgICAgICAgICAgICAgLy8gVGhlIG9yaWdpbmFsIGhhcyBhIGtleVxuICAgICAgICAgICAgICAgIGlzQ29tcGF0aWJsZSA9IGZhbHNlO1xuICAgICAgICAgICAgICB9XG5cbiAgICAgICAgICAgICAgaXNDb21wYXRpYmxlID0gaXNDb21wYXRpYmxlICE9PSBmYWxzZSAmJiBjb21wYXJlTm9kZU5hbWVzKGN1ckZyb21Ob2RlQ2hpbGQsIGN1clRvTm9kZUNoaWxkKTtcbiAgICAgICAgICAgICAgaWYgKGlzQ29tcGF0aWJsZSkge1xuICAgICAgICAgICAgICAgIC8vIFdlIGZvdW5kIGNvbXBhdGlibGUgRE9NIGVsZW1lbnRzIHNvIHRyYW5zZm9ybVxuICAgICAgICAgICAgICAgIC8vIHRoZSBjdXJyZW50IFwiZnJvbVwiIG5vZGUgdG8gbWF0Y2ggdGhlIGN1cnJlbnRcbiAgICAgICAgICAgICAgICAvLyB0YXJnZXQgRE9NIG5vZGUuXG4gICAgICAgICAgICAgICAgLy8gTU9SUEhcbiAgICAgICAgICAgICAgICBtb3JwaEVsKGN1ckZyb21Ob2RlQ2hpbGQsIGN1clRvTm9kZUNoaWxkKTtcbiAgICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICB9IGVsc2UgaWYgKGN1ckZyb21Ob2RlVHlwZSA9PT0gVEVYVF9OT0RFIHx8IGN1ckZyb21Ob2RlVHlwZSA9PSBDT01NRU5UX05PREUpIHtcbiAgICAgICAgICAgICAgLy8gQm90aCBub2RlcyBiZWluZyBjb21wYXJlZCBhcmUgVGV4dCBvciBDb21tZW50IG5vZGVzXG4gICAgICAgICAgICAgIGlzQ29tcGF0aWJsZSA9IHRydWU7XG4gICAgICAgICAgICAgIC8vIFNpbXBseSB1cGRhdGUgbm9kZVZhbHVlIG9uIHRoZSBvcmlnaW5hbCBub2RlIHRvXG4gICAgICAgICAgICAgIC8vIGNoYW5nZSB0aGUgdGV4dCB2YWx1ZVxuICAgICAgICAgICAgICBpZiAoY3VyRnJvbU5vZGVDaGlsZC5ub2RlVmFsdWUgIT09IGN1clRvTm9kZUNoaWxkLm5vZGVWYWx1ZSkge1xuICAgICAgICAgICAgICAgIGN1ckZyb21Ob2RlQ2hpbGQubm9kZVZhbHVlID0gY3VyVG9Ob2RlQ2hpbGQubm9kZVZhbHVlO1xuICAgICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIH1cbiAgICAgICAgICB9XG5cbiAgICAgICAgICBpZiAoaXNDb21wYXRpYmxlKSB7XG4gICAgICAgICAgICAvLyBBZHZhbmNlIGJvdGggdGhlIFwidG9cIiBjaGlsZCBhbmQgdGhlIFwiZnJvbVwiIGNoaWxkIHNpbmNlIHdlIGZvdW5kIGEgbWF0Y2hcbiAgICAgICAgICAgIC8vIE5vdGhpbmcgZWxzZSB0byBkbyBhcyB3ZSBhbHJlYWR5IHJlY3Vyc2l2ZWx5IGNhbGxlZCBtb3JwaENoaWxkcmVuIGFib3ZlXG4gICAgICAgICAgICBjdXJUb05vZGVDaGlsZCA9IHRvTmV4dFNpYmxpbmc7XG4gICAgICAgICAgICBjdXJGcm9tTm9kZUNoaWxkID0gZnJvbU5leHRTaWJsaW5nO1xuICAgICAgICAgICAgY29udGludWUgb3V0ZXI7XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgLy8gTm8gY29tcGF0aWJsZSBtYXRjaCBzbyByZW1vdmUgdGhlIG9sZCBub2RlIGZyb20gdGhlIERPTSBhbmQgY29udGludWUgdHJ5aW5nIHRvIGZpbmQgYVxuICAgICAgICAgIC8vIG1hdGNoIGluIHRoZSBvcmlnaW5hbCBET00uIEhvd2V2ZXIsIHdlIG9ubHkgZG8gdGhpcyBpZiB0aGUgZnJvbSBub2RlIGlzIG5vdCBrZXllZFxuICAgICAgICAgIC8vIHNpbmNlIGl0IGlzIHBvc3NpYmxlIHRoYXQgYSBrZXllZCBub2RlIG1pZ2h0IG1hdGNoIHVwIHdpdGggYSBub2RlIHNvbWV3aGVyZSBlbHNlIGluIHRoZVxuICAgICAgICAgIC8vIHRhcmdldCB0cmVlIGFuZCB3ZSBkb24ndCB3YW50IHRvIGRpc2NhcmQgaXQganVzdCB5ZXQgc2luY2UgaXQgc3RpbGwgbWlnaHQgZmluZCBhXG4gICAgICAgICAgLy8gaG9tZSBpbiB0aGUgZmluYWwgRE9NIHRyZWUuIEFmdGVyIGV2ZXJ5dGhpbmcgaXMgZG9uZSB3ZSB3aWxsIHJlbW92ZSBhbnkga2V5ZWQgbm9kZXNcbiAgICAgICAgICAvLyB0aGF0IGRpZG4ndCBmaW5kIGEgaG9tZVxuICAgICAgICAgIGlmIChjdXJGcm9tTm9kZUtleSkge1xuICAgICAgICAgICAgLy8gU2luY2UgdGhlIG5vZGUgaXMga2V5ZWQgaXQgbWlnaHQgYmUgbWF0Y2hlZCB1cCBsYXRlciBzbyB3ZSBkZWZlclxuICAgICAgICAgICAgLy8gdGhlIGFjdHVhbCByZW1vdmFsIHRvIGxhdGVyXG4gICAgICAgICAgICBhZGRLZXllZFJlbW92YWwoY3VyRnJvbU5vZGVLZXkpO1xuICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAvLyBOT1RFOiB3ZSBza2lwIG5lc3RlZCBrZXllZCBub2RlcyBmcm9tIGJlaW5nIHJlbW92ZWQgc2luY2UgdGhlcmUgaXNcbiAgICAgICAgICAgIC8vICAgICAgIHN0aWxsIGEgY2hhbmNlIHRoZXkgd2lsbCBiZSBtYXRjaGVkIHVwIGxhdGVyXG4gICAgICAgICAgICByZW1vdmVOb2RlKGN1ckZyb21Ob2RlQ2hpbGQsIGZyb21FbCwgdHJ1ZSAvKiBza2lwIGtleWVkIG5vZGVzICovKTtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICBjdXJGcm9tTm9kZUNoaWxkID0gZnJvbU5leHRTaWJsaW5nO1xuICAgICAgICB9IC8vIEVORDogd2hpbGUoY3VyRnJvbU5vZGVDaGlsZCkge31cblxuICAgICAgICAvLyBJZiB3ZSBnb3QgdGhpcyBmYXIgdGhlbiB3ZSBkaWQgbm90IGZpbmQgYSBjYW5kaWRhdGUgbWF0Y2ggZm9yXG4gICAgICAgIC8vIG91ciBcInRvIG5vZGVcIiBhbmQgd2UgZXhoYXVzdGVkIGFsbCBvZiB0aGUgY2hpbGRyZW4gXCJmcm9tXCJcbiAgICAgICAgLy8gbm9kZXMuIFRoZXJlZm9yZSwgd2Ugd2lsbCBqdXN0IGFwcGVuZCB0aGUgY3VycmVudCBcInRvXCIgbm9kZVxuICAgICAgICAvLyB0byB0aGUgZW5kXG4gICAgICAgIGlmIChjdXJUb05vZGVLZXkgJiYgKG1hdGNoaW5nRnJvbUVsID0gZnJvbU5vZGVzTG9va3VwW2N1clRvTm9kZUtleV0pICYmIGNvbXBhcmVOb2RlTmFtZXMobWF0Y2hpbmdGcm9tRWwsIGN1clRvTm9kZUNoaWxkKSkge1xuICAgICAgICAgIC8vIE1PUlBIXG4gICAgICAgICAgaWYoIXNraXBGcm9tKXsgYWRkQ2hpbGQoZnJvbUVsLCBtYXRjaGluZ0Zyb21FbCk7IH1cbiAgICAgICAgICBtb3JwaEVsKG1hdGNoaW5nRnJvbUVsLCBjdXJUb05vZGVDaGlsZCk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgdmFyIG9uQmVmb3JlTm9kZUFkZGVkUmVzdWx0ID0gb25CZWZvcmVOb2RlQWRkZWQoY3VyVG9Ob2RlQ2hpbGQpO1xuICAgICAgICAgIGlmIChvbkJlZm9yZU5vZGVBZGRlZFJlc3VsdCAhPT0gZmFsc2UpIHtcbiAgICAgICAgICAgIGlmIChvbkJlZm9yZU5vZGVBZGRlZFJlc3VsdCkge1xuICAgICAgICAgICAgICBjdXJUb05vZGVDaGlsZCA9IG9uQmVmb3JlTm9kZUFkZGVkUmVzdWx0O1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICBpZiAoY3VyVG9Ob2RlQ2hpbGQuYWN0dWFsaXplKSB7XG4gICAgICAgICAgICAgIGN1clRvTm9kZUNoaWxkID0gY3VyVG9Ob2RlQ2hpbGQuYWN0dWFsaXplKGZyb21FbC5vd25lckRvY3VtZW50IHx8IGRvYyk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICBhZGRDaGlsZChmcm9tRWwsIGN1clRvTm9kZUNoaWxkKTtcbiAgICAgICAgICAgIGhhbmRsZU5vZGVBZGRlZChjdXJUb05vZGVDaGlsZCk7XG4gICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgY3VyVG9Ob2RlQ2hpbGQgPSB0b05leHRTaWJsaW5nO1xuICAgICAgICBjdXJGcm9tTm9kZUNoaWxkID0gZnJvbU5leHRTaWJsaW5nO1xuICAgICAgfVxuXG4gICAgICBjbGVhbnVwRnJvbUVsKGZyb21FbCwgY3VyRnJvbU5vZGVDaGlsZCwgY3VyRnJvbU5vZGVLZXkpO1xuXG4gICAgICB2YXIgc3BlY2lhbEVsSGFuZGxlciA9IHNwZWNpYWxFbEhhbmRsZXJzW2Zyb21FbC5ub2RlTmFtZV07XG4gICAgICBpZiAoc3BlY2lhbEVsSGFuZGxlcikge1xuICAgICAgICBzcGVjaWFsRWxIYW5kbGVyKGZyb21FbCwgdG9FbCk7XG4gICAgICB9XG4gICAgfSAvLyBFTkQ6IG1vcnBoQ2hpbGRyZW4oLi4uKVxuXG4gICAgdmFyIG1vcnBoZWROb2RlID0gZnJvbU5vZGU7XG4gICAgdmFyIG1vcnBoZWROb2RlVHlwZSA9IG1vcnBoZWROb2RlLm5vZGVUeXBlO1xuICAgIHZhciB0b05vZGVUeXBlID0gdG9Ob2RlLm5vZGVUeXBlO1xuXG4gICAgaWYgKCFjaGlsZHJlbk9ubHkpIHtcbiAgICAgIC8vIEhhbmRsZSB0aGUgY2FzZSB3aGVyZSB3ZSBhcmUgZ2l2ZW4gdHdvIERPTSBub2RlcyB0aGF0IGFyZSBub3RcbiAgICAgIC8vIGNvbXBhdGlibGUgKGUuZy4gPGRpdj4gLS0+IDxzcGFuPiBvciA8ZGl2PiAtLT4gVEVYVClcbiAgICAgIGlmIChtb3JwaGVkTm9kZVR5cGUgPT09IEVMRU1FTlRfTk9ERSkge1xuICAgICAgICBpZiAodG9Ob2RlVHlwZSA9PT0gRUxFTUVOVF9OT0RFKSB7XG4gICAgICAgICAgaWYgKCFjb21wYXJlTm9kZU5hbWVzKGZyb21Ob2RlLCB0b05vZGUpKSB7XG4gICAgICAgICAgICBvbk5vZGVEaXNjYXJkZWQoZnJvbU5vZGUpO1xuICAgICAgICAgICAgbW9ycGhlZE5vZGUgPSBtb3ZlQ2hpbGRyZW4oZnJvbU5vZGUsIGNyZWF0ZUVsZW1lbnROUyh0b05vZGUubm9kZU5hbWUsIHRvTm9kZS5uYW1lc3BhY2VVUkkpKTtcbiAgICAgICAgICB9XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgLy8gR29pbmcgZnJvbSBhbiBlbGVtZW50IG5vZGUgdG8gYSB0ZXh0IG5vZGVcbiAgICAgICAgICBtb3JwaGVkTm9kZSA9IHRvTm9kZTtcbiAgICAgICAgfVxuICAgICAgfSBlbHNlIGlmIChtb3JwaGVkTm9kZVR5cGUgPT09IFRFWFRfTk9ERSB8fCBtb3JwaGVkTm9kZVR5cGUgPT09IENPTU1FTlRfTk9ERSkgeyAvLyBUZXh0IG9yIGNvbW1lbnQgbm9kZVxuICAgICAgICBpZiAodG9Ob2RlVHlwZSA9PT0gbW9ycGhlZE5vZGVUeXBlKSB7XG4gICAgICAgICAgaWYgKG1vcnBoZWROb2RlLm5vZGVWYWx1ZSAhPT0gdG9Ob2RlLm5vZGVWYWx1ZSkge1xuICAgICAgICAgICAgbW9ycGhlZE5vZGUubm9kZVZhbHVlID0gdG9Ob2RlLm5vZGVWYWx1ZTtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICByZXR1cm4gbW9ycGhlZE5vZGU7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgLy8gVGV4dCBub2RlIHRvIHNvbWV0aGluZyBlbHNlXG4gICAgICAgICAgbW9ycGhlZE5vZGUgPSB0b05vZGU7XG4gICAgICAgIH1cbiAgICAgIH1cbiAgICB9XG5cbiAgICBpZiAobW9ycGhlZE5vZGUgPT09IHRvTm9kZSkge1xuICAgICAgLy8gVGhlIFwidG8gbm9kZVwiIHdhcyBub3QgY29tcGF0aWJsZSB3aXRoIHRoZSBcImZyb20gbm9kZVwiIHNvIHdlIGhhZCB0b1xuICAgICAgLy8gdG9zcyBvdXQgdGhlIFwiZnJvbSBub2RlXCIgYW5kIHVzZSB0aGUgXCJ0byBub2RlXCJcbiAgICAgIG9uTm9kZURpc2NhcmRlZChmcm9tTm9kZSk7XG4gICAgfSBlbHNlIHtcbiAgICAgIGlmICh0b05vZGUuaXNTYW1lTm9kZSAmJiB0b05vZGUuaXNTYW1lTm9kZShtb3JwaGVkTm9kZSkpIHtcbiAgICAgICAgcmV0dXJuO1xuICAgICAgfVxuXG4gICAgICBtb3JwaEVsKG1vcnBoZWROb2RlLCB0b05vZGUsIGNoaWxkcmVuT25seSk7XG5cbiAgICAgIC8vIFdlIG5vdyBuZWVkIHRvIGxvb3Agb3ZlciBhbnkga2V5ZWQgbm9kZXMgdGhhdCBtaWdodCBuZWVkIHRvIGJlXG4gICAgICAvLyByZW1vdmVkLiBXZSBvbmx5IGRvIHRoZSByZW1vdmFsIGlmIHdlIGtub3cgdGhhdCB0aGUga2V5ZWQgbm9kZVxuICAgICAgLy8gbmV2ZXIgZm91bmQgYSBtYXRjaC4gV2hlbiBhIGtleWVkIG5vZGUgaXMgbWF0Y2hlZCB1cCB3ZSByZW1vdmVcbiAgICAgIC8vIGl0IG91dCBvZiBmcm9tTm9kZXNMb29rdXAgYW5kIHdlIHVzZSBmcm9tTm9kZXNMb29rdXAgdG8gZGV0ZXJtaW5lXG4gICAgICAvLyBpZiBhIGtleWVkIG5vZGUgaGFzIGJlZW4gbWF0Y2hlZCB1cCBvciBub3RcbiAgICAgIGlmIChrZXllZFJlbW92YWxMaXN0KSB7XG4gICAgICAgIGZvciAodmFyIGk9MCwgbGVuPWtleWVkUmVtb3ZhbExpc3QubGVuZ3RoOyBpPGxlbjsgaSsrKSB7XG4gICAgICAgICAgdmFyIGVsVG9SZW1vdmUgPSBmcm9tTm9kZXNMb29rdXBba2V5ZWRSZW1vdmFsTGlzdFtpXV07XG4gICAgICAgICAgaWYgKGVsVG9SZW1vdmUpIHtcbiAgICAgICAgICAgIHJlbW92ZU5vZGUoZWxUb1JlbW92ZSwgZWxUb1JlbW92ZS5wYXJlbnROb2RlLCBmYWxzZSk7XG4gICAgICAgICAgfVxuICAgICAgICB9XG4gICAgICB9XG4gICAgfVxuXG4gICAgaWYgKCFjaGlsZHJlbk9ubHkgJiYgbW9ycGhlZE5vZGUgIT09IGZyb21Ob2RlICYmIGZyb21Ob2RlLnBhcmVudE5vZGUpIHtcbiAgICAgIGlmIChtb3JwaGVkTm9kZS5hY3R1YWxpemUpIHtcbiAgICAgICAgbW9ycGhlZE5vZGUgPSBtb3JwaGVkTm9kZS5hY3R1YWxpemUoZnJvbU5vZGUub3duZXJEb2N1bWVudCB8fCBkb2MpO1xuICAgICAgfVxuICAgICAgLy8gSWYgd2UgaGFkIHRvIHN3YXAgb3V0IHRoZSBmcm9tIG5vZGUgd2l0aCBhIG5ldyBub2RlIGJlY2F1c2UgdGhlIG9sZFxuICAgICAgLy8gbm9kZSB3YXMgbm90IGNvbXBhdGlibGUgd2l0aCB0aGUgdGFyZ2V0IG5vZGUgdGhlbiB3ZSBuZWVkIHRvXG4gICAgICAvLyByZXBsYWNlIHRoZSBvbGQgRE9NIG5vZGUgaW4gdGhlIG9yaWdpbmFsIERPTSB0cmVlLiBUaGlzIGlzIG9ubHlcbiAgICAgIC8vIHBvc3NpYmxlIGlmIHRoZSBvcmlnaW5hbCBET00gbm9kZSB3YXMgcGFydCBvZiBhIERPTSB0cmVlIHdoaWNoXG4gICAgICAvLyB3ZSBrbm93IGlzIHRoZSBjYXNlIGlmIGl0IGhhcyBhIHBhcmVudCBub2RlLlxuICAgICAgZnJvbU5vZGUucGFyZW50Tm9kZS5yZXBsYWNlQ2hpbGQobW9ycGhlZE5vZGUsIGZyb21Ob2RlKTtcbiAgICB9XG5cbiAgICByZXR1cm4gbW9ycGhlZE5vZGU7XG4gIH07XG59XG5cbnZhciBtb3JwaGRvbSA9IG1vcnBoZG9tRmFjdG9yeShtb3JwaEF0dHJzKTtcblxuZXhwb3J0IGRlZmF1bHQgbW9ycGhkb207XG4iLCAiaW1wb3J0IHtcbiAgUEhYX0NPTVBPTkVOVCxcbiAgUEhYX1BSVU5FLFxuICBQSFhfUk9PVF9JRCxcbiAgUEhYX1NFU1NJT04sXG4gIFBIWF9TS0lQLFxuICBQSFhfTUFHSUNfSUQsXG4gIFBIWF9TVEFUSUMsXG4gIFBIWF9UUklHR0VSX0FDVElPTixcbiAgUEhYX1VQREFURSxcbiAgUEhYX1JFRl9TUkMsXG4gIFBIWF9SRUZfTE9DSyxcbiAgUEhYX1NUUkVBTSxcbiAgUEhYX1NUUkVBTV9SRUYsXG4gIFBIWF9WSUVXUE9SVF9UT1AsXG4gIFBIWF9WSUVXUE9SVF9CT1RUT00sXG4gIFBIWF9QT1JUQUwsXG4gIFBIWF9URUxFUE9SVEVEX1JFRixcbiAgUEhYX1RFTEVQT1JURURfU1JDLFxuICBQSFhfUlVOVElNRV9IT09LLFxufSBmcm9tIFwiLi9jb25zdGFudHNcIjtcblxuaW1wb3J0IHsgZGV0ZWN0RHVwbGljYXRlSWRzLCBkZXRlY3RJbnZhbGlkU3RyZWFtSW5zZXJ0cywgaXNDaWQgfSBmcm9tIFwiLi91dGlsc1wiO1xuaW1wb3J0IEVsZW1lbnRSZWYgZnJvbSBcIi4vZWxlbWVudF9yZWZcIjtcbmltcG9ydCBET00gZnJvbSBcIi4vZG9tXCI7XG5pbXBvcnQgRE9NUG9zdE1vcnBoUmVzdG9yZXIgZnJvbSBcIi4vZG9tX3Bvc3RfbW9ycGhfcmVzdG9yZXJcIjtcbmltcG9ydCBtb3JwaGRvbSBmcm9tIFwibW9ycGhkb21cIjtcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgRE9NUGF0Y2gge1xuICBjb25zdHJ1Y3Rvcih2aWV3LCBjb250YWluZXIsIGlkLCBodG1sLCBzdHJlYW1zLCB0YXJnZXRDSUQsIG9wdHMgPSB7fSkge1xuICAgIHRoaXMudmlldyA9IHZpZXc7XG4gICAgdGhpcy5saXZlU29ja2V0ID0gdmlldy5saXZlU29ja2V0O1xuICAgIHRoaXMuY29udGFpbmVyID0gY29udGFpbmVyO1xuICAgIHRoaXMuaWQgPSBpZDtcbiAgICB0aGlzLnJvb3RJRCA9IHZpZXcucm9vdC5pZDtcbiAgICB0aGlzLmh0bWwgPSBodG1sO1xuICAgIHRoaXMuc3RyZWFtcyA9IHN0cmVhbXM7XG4gICAgdGhpcy5zdHJlYW1JbnNlcnRzID0ge307XG4gICAgdGhpcy5zdHJlYW1Db21wb25lbnRSZXN0b3JlID0ge307XG4gICAgdGhpcy50YXJnZXRDSUQgPSB0YXJnZXRDSUQ7XG4gICAgdGhpcy5jaWRQYXRjaCA9IGlzQ2lkKHRoaXMudGFyZ2V0Q0lEKTtcbiAgICB0aGlzLnBlbmRpbmdSZW1vdmVzID0gW107XG4gICAgdGhpcy5waHhSZW1vdmUgPSB0aGlzLmxpdmVTb2NrZXQuYmluZGluZyhcInJlbW92ZVwiKTtcbiAgICB0aGlzLnRhcmdldENvbnRhaW5lciA9IHRoaXMuaXNDSURQYXRjaCgpXG4gICAgICA/IHRoaXMudGFyZ2V0Q0lEQ29udGFpbmVyKGh0bWwpXG4gICAgICA6IGNvbnRhaW5lcjtcbiAgICB0aGlzLmNhbGxiYWNrcyA9IHtcbiAgICAgIGJlZm9yZWFkZGVkOiBbXSxcbiAgICAgIGJlZm9yZXVwZGF0ZWQ6IFtdLFxuICAgICAgYmVmb3JlcGh4Q2hpbGRBZGRlZDogW10sXG4gICAgICBhZnRlcmFkZGVkOiBbXSxcbiAgICAgIGFmdGVydXBkYXRlZDogW10sXG4gICAgICBhZnRlcmRpc2NhcmRlZDogW10sXG4gICAgICBhZnRlcnBoeENoaWxkQWRkZWQ6IFtdLFxuICAgICAgYWZ0ZXJ0cmFuc2l0aW9uc0Rpc2NhcmRlZDogW10sXG4gICAgfTtcbiAgICB0aGlzLndpdGhDaGlsZHJlbiA9IG9wdHMud2l0aENoaWxkcmVuIHx8IG9wdHMudW5kb1JlZiB8fCBmYWxzZTtcbiAgICB0aGlzLnVuZG9SZWYgPSBvcHRzLnVuZG9SZWY7XG4gIH1cblxuICBiZWZvcmUoa2luZCwgY2FsbGJhY2spIHtcbiAgICB0aGlzLmNhbGxiYWNrc1tgYmVmb3JlJHtraW5kfWBdLnB1c2goY2FsbGJhY2spO1xuICB9XG4gIGFmdGVyKGtpbmQsIGNhbGxiYWNrKSB7XG4gICAgdGhpcy5jYWxsYmFja3NbYGFmdGVyJHtraW5kfWBdLnB1c2goY2FsbGJhY2spO1xuICB9XG5cbiAgdHJhY2tCZWZvcmUoa2luZCwgLi4uYXJncykge1xuICAgIHRoaXMuY2FsbGJhY2tzW2BiZWZvcmUke2tpbmR9YF0uZm9yRWFjaCgoY2FsbGJhY2spID0+IGNhbGxiYWNrKC4uLmFyZ3MpKTtcbiAgfVxuXG4gIHRyYWNrQWZ0ZXIoa2luZCwgLi4uYXJncykge1xuICAgIHRoaXMuY2FsbGJhY2tzW2BhZnRlciR7a2luZH1gXS5mb3JFYWNoKChjYWxsYmFjaykgPT4gY2FsbGJhY2soLi4uYXJncykpO1xuICB9XG5cbiAgbWFya1BydW5hYmxlQ29udGVudEZvclJlbW92YWwoKSB7XG4gICAgY29uc3QgcGh4VXBkYXRlID0gdGhpcy5saXZlU29ja2V0LmJpbmRpbmcoUEhYX1VQREFURSk7XG4gICAgRE9NLmFsbChcbiAgICAgIHRoaXMuY29udGFpbmVyLFxuICAgICAgYFske3BoeFVwZGF0ZX09YXBwZW5kXSA+ICosIFske3BoeFVwZGF0ZX09cHJlcGVuZF0gPiAqYCxcbiAgICAgIChlbCkgPT4ge1xuICAgICAgICBlbC5zZXRBdHRyaWJ1dGUoUEhYX1BSVU5FLCBcIlwiKTtcbiAgICAgIH0sXG4gICAgKTtcbiAgfVxuXG4gIHBlcmZvcm0oaXNKb2luUGF0Y2gpIHtcbiAgICBjb25zdCB7IHZpZXcsIGxpdmVTb2NrZXQsIGh0bWwsIGNvbnRhaW5lciwgdGFyZ2V0Q29udGFpbmVyIH0gPSB0aGlzO1xuICAgIGlmICh0aGlzLmlzQ0lEUGF0Y2goKSAmJiAhdGFyZ2V0Q29udGFpbmVyKSB7XG4gICAgICByZXR1cm47XG4gICAgfVxuXG4gICAgY29uc3QgZm9jdXNlZCA9IGxpdmVTb2NrZXQuZ2V0QWN0aXZlRWxlbWVudCgpO1xuICAgIGNvbnN0IHsgc2VsZWN0aW9uU3RhcnQsIHNlbGVjdGlvbkVuZCB9ID1cbiAgICAgIGZvY3VzZWQgJiYgRE9NLmhhc1NlbGVjdGlvblJhbmdlKGZvY3VzZWQpID8gZm9jdXNlZCA6IHt9O1xuICAgIGNvbnN0IHBoeFVwZGF0ZSA9IGxpdmVTb2NrZXQuYmluZGluZyhQSFhfVVBEQVRFKTtcbiAgICBjb25zdCBwaHhWaWV3cG9ydFRvcCA9IGxpdmVTb2NrZXQuYmluZGluZyhQSFhfVklFV1BPUlRfVE9QKTtcbiAgICBjb25zdCBwaHhWaWV3cG9ydEJvdHRvbSA9IGxpdmVTb2NrZXQuYmluZGluZyhQSFhfVklFV1BPUlRfQk9UVE9NKTtcbiAgICBjb25zdCBwaHhUcmlnZ2VyRXh0ZXJuYWwgPSBsaXZlU29ja2V0LmJpbmRpbmcoUEhYX1RSSUdHRVJfQUNUSU9OKTtcbiAgICBjb25zdCBhZGRlZCA9IFtdO1xuICAgIGNvbnN0IHVwZGF0ZXMgPSBbXTtcbiAgICBjb25zdCBhcHBlbmRQcmVwZW5kVXBkYXRlcyA9IFtdO1xuXG4gICAgLy8gYXMgdGhlIHBvcnRhbCB0YXJnZXQgaXRzZWxmIGNvdWxkIGJlIGF0IHRoZSBlbmQgb2YgdGhlIERPTSxcbiAgICAvLyBpdCBtYXkgbm90IGJlIHByZXNlbnQgd2hpbGUgbW9ycGhpbmcgcHJldmlvdXMgcGFydHM7XG4gICAgLy8gdGhlcmVmb3JlIHdlIGFwcGx5IGFsbCB0ZWxlcG9ydHMgYWZ0ZXIgdGhlIG1vcnBoaW5nIGlzIGRvbmUrXG4gICAgY29uc3QgcG9ydGFsQ2FsbGJhY2tzID0gW107XG5cbiAgICBsZXQgZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkID0gbnVsbDtcblxuICAgIGNvbnN0IG1vcnBoID0gKFxuICAgICAgdGFyZ2V0Q29udGFpbmVyLFxuICAgICAgc291cmNlLFxuICAgICAgd2l0aENoaWxkcmVuID0gdGhpcy53aXRoQ2hpbGRyZW4sXG4gICAgKSA9PiB7XG4gICAgICBjb25zdCBtb3JwaENhbGxiYWNrcyA9IHtcbiAgICAgICAgLy8gbm9ybWFsbHksIHdlIGFyZSBydW5uaW5nIHdpdGggY2hpbGRyZW5Pbmx5LCBhcyB0aGUgcGF0Y2ggSFRNTCBmb3IgYSBMVlxuICAgICAgICAvLyBkb2VzIG5vdCBpbmNsdWRlIHRoZSBMViBhdHRycyAoZGF0YS1waHgtc2Vzc2lvbiwgZXRjLilcbiAgICAgICAgLy8gd2hlbiB3ZSBhcmUgcGF0Y2hpbmcgYSBsaXZlIGNvbXBvbmVudCwgd2UgZG8gd2FudCB0byBwYXRjaCB0aGUgcm9vdCBlbGVtZW50IGFzIHdlbGw7XG4gICAgICAgIC8vIGFub3RoZXIgY2FzZSBpcyB0aGUgcmVjdXJzaXZlIHBhdGNoIG9mIGEgc3RyZWFtIGl0ZW0gdGhhdCB3YXMga2VwdCBvbiByZXNldCAoLT4gb25CZWZvcmVOb2RlQWRkZWQpXG4gICAgICAgIGNoaWxkcmVuT25seTpcbiAgICAgICAgICB0YXJnZXRDb250YWluZXIuZ2V0QXR0cmlidXRlKFBIWF9DT01QT05FTlQpID09PSBudWxsICYmICF3aXRoQ2hpbGRyZW4sXG4gICAgICAgIGdldE5vZGVLZXk6IChub2RlKSA9PiB7XG4gICAgICAgICAgaWYgKERPTS5pc1BoeERlc3Ryb3llZChub2RlKSkge1xuICAgICAgICAgICAgcmV0dXJuIG51bGw7XG4gICAgICAgICAgfVxuICAgICAgICAgIC8vIElmIHdlIGhhdmUgYSBqb2luIHBhdGNoLCB0aGVuIGJ5IGRlZmluaXRpb24gdGhlcmUgd2FzIG5vIFBIWF9NQUdJQ19JRC5cbiAgICAgICAgICAvLyBUaGlzIGlzIGltcG9ydGFudCB0byByZWR1Y2UgdGhlIGFtb3VudCBvZiBlbGVtZW50cyBtb3JwaGRvbSBkaXNjYXJkcy5cbiAgICAgICAgICBpZiAoaXNKb2luUGF0Y2gpIHtcbiAgICAgICAgICAgIHJldHVybiBub2RlLmlkO1xuICAgICAgICAgIH1cbiAgICAgICAgICByZXR1cm4gKFxuICAgICAgICAgICAgbm9kZS5pZCB8fCAobm9kZS5nZXRBdHRyaWJ1dGUgJiYgbm9kZS5nZXRBdHRyaWJ1dGUoUEhYX01BR0lDX0lEKSlcbiAgICAgICAgICApO1xuICAgICAgICB9LFxuICAgICAgICAvLyBza2lwIGluZGV4aW5nIGZyb20gY2hpbGRyZW4gd2hlbiBjb250YWluZXIgaXMgc3RyZWFtXG4gICAgICAgIHNraXBGcm9tQ2hpbGRyZW46IChmcm9tKSA9PiB7XG4gICAgICAgICAgcmV0dXJuIGZyb20uZ2V0QXR0cmlidXRlKHBoeFVwZGF0ZSkgPT09IFBIWF9TVFJFQU07XG4gICAgICAgIH0sXG4gICAgICAgIC8vIHRlbGwgbW9ycGhkb20gaG93IHRvIGFkZCBhIGNoaWxkXG4gICAgICAgIGFkZENoaWxkOiAocGFyZW50LCBjaGlsZCkgPT4ge1xuICAgICAgICAgIGNvbnN0IHsgcmVmLCBzdHJlYW1BdCB9ID0gdGhpcy5nZXRTdHJlYW1JbnNlcnQoY2hpbGQpO1xuICAgICAgICAgIGlmIChyZWYgPT09IHVuZGVmaW5lZCkge1xuICAgICAgICAgICAgcmV0dXJuIHBhcmVudC5hcHBlbmRDaGlsZChjaGlsZCk7XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgdGhpcy5zZXRTdHJlYW1SZWYoY2hpbGQsIHJlZik7XG5cbiAgICAgICAgICAvLyBzdHJlYW1pbmdcbiAgICAgICAgICBpZiAoc3RyZWFtQXQgPT09IDApIHtcbiAgICAgICAgICAgIHBhcmVudC5pbnNlcnRBZGphY2VudEVsZW1lbnQoXCJhZnRlcmJlZ2luXCIsIGNoaWxkKTtcbiAgICAgICAgICB9IGVsc2UgaWYgKHN0cmVhbUF0ID09PSAtMSkge1xuICAgICAgICAgICAgY29uc3QgbGFzdENoaWxkID0gcGFyZW50Lmxhc3RFbGVtZW50Q2hpbGQ7XG4gICAgICAgICAgICBpZiAobGFzdENoaWxkICYmICFsYXN0Q2hpbGQuaGFzQXR0cmlidXRlKFBIWF9TVFJFQU1fUkVGKSkge1xuICAgICAgICAgICAgICBjb25zdCBub25TdHJlYW1DaGlsZCA9IEFycmF5LmZyb20ocGFyZW50LmNoaWxkcmVuKS5maW5kKFxuICAgICAgICAgICAgICAgIChjKSA9PiAhYy5oYXNBdHRyaWJ1dGUoUEhYX1NUUkVBTV9SRUYpLFxuICAgICAgICAgICAgICApO1xuICAgICAgICAgICAgICBwYXJlbnQuaW5zZXJ0QmVmb3JlKGNoaWxkLCBub25TdHJlYW1DaGlsZCk7XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICBwYXJlbnQuYXBwZW5kQ2hpbGQoY2hpbGQpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgIH0gZWxzZSBpZiAoc3RyZWFtQXQgPiAwKSB7XG4gICAgICAgICAgICBjb25zdCBzaWJsaW5nID0gQXJyYXkuZnJvbShwYXJlbnQuY2hpbGRyZW4pW3N0cmVhbUF0XTtcbiAgICAgICAgICAgIHBhcmVudC5pbnNlcnRCZWZvcmUoY2hpbGQsIHNpYmxpbmcpO1xuICAgICAgICAgIH1cbiAgICAgICAgfSxcbiAgICAgICAgb25CZWZvcmVOb2RlQWRkZWQ6IChlbCkgPT4ge1xuICAgICAgICAgIC8vIGRvbid0IGFkZCB1cGRhdGVfb25seSBub2RlcyBpZiB0aGV5IGRpZCBub3QgYWxyZWFkeSBleGlzdFxuICAgICAgICAgIGlmIChcbiAgICAgICAgICAgIHRoaXMuZ2V0U3RyZWFtSW5zZXJ0KGVsKT8udXBkYXRlT25seSAmJlxuICAgICAgICAgICAgIXRoaXMuc3RyZWFtQ29tcG9uZW50UmVzdG9yZVtlbC5pZF1cbiAgICAgICAgICApIHtcbiAgICAgICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICBET00ubWFpbnRhaW5Qcml2YXRlSG9va3MoZWwsIGVsLCBwaHhWaWV3cG9ydFRvcCwgcGh4Vmlld3BvcnRCb3R0b20pO1xuICAgICAgICAgIHRoaXMudHJhY2tCZWZvcmUoXCJhZGRlZFwiLCBlbCk7XG5cbiAgICAgICAgICBsZXQgbW9ycGhlZEVsID0gZWw7XG4gICAgICAgICAgLy8gdGhpcyBpcyBhIHN0cmVhbSBpdGVtIHRoYXQgd2FzIGtlcHQgb24gcmVzZXQsIHJlY3Vyc2l2ZWx5IG1vcnBoIGl0XG4gICAgICAgICAgaWYgKHRoaXMuc3RyZWFtQ29tcG9uZW50UmVzdG9yZVtlbC5pZF0pIHtcbiAgICAgICAgICAgIG1vcnBoZWRFbCA9IHRoaXMuc3RyZWFtQ29tcG9uZW50UmVzdG9yZVtlbC5pZF07XG4gICAgICAgICAgICBkZWxldGUgdGhpcy5zdHJlYW1Db21wb25lbnRSZXN0b3JlW2VsLmlkXTtcbiAgICAgICAgICAgIG1vcnBoKG1vcnBoZWRFbCwgZWwsIHRydWUpO1xuICAgICAgICAgIH1cblxuICAgICAgICAgIHJldHVybiBtb3JwaGVkRWw7XG4gICAgICAgIH0sXG4gICAgICAgIG9uTm9kZUFkZGVkOiAoZWwpID0+IHtcbiAgICAgICAgICBpZiAoZWwuZ2V0QXR0cmlidXRlKSB7XG4gICAgICAgICAgICB0aGlzLm1heWJlUmVPcmRlclN0cmVhbShlbCwgdHJ1ZSk7XG4gICAgICAgICAgfVxuICAgICAgICAgIC8vIHBoeC1wb3J0YWwgaGFuZGxpbmdcbiAgICAgICAgICBpZiAoRE9NLmlzUG9ydGFsVGVtcGxhdGUoZWwpKSB7XG4gICAgICAgICAgICBwb3J0YWxDYWxsYmFja3MucHVzaCgoKSA9PiB0aGlzLnRlbGVwb3J0KGVsLCBtb3JwaCkpO1xuICAgICAgICAgIH1cblxuICAgICAgICAgIC8vIGhhY2sgdG8gZml4IFNhZmFyaSBoYW5kbGluZyBvZiBpbWcgc3Jjc2V0IGFuZCB2aWRlbyB0YWdzXG4gICAgICAgICAgaWYgKGVsIGluc3RhbmNlb2YgSFRNTEltYWdlRWxlbWVudCAmJiBlbC5zcmNzZXQpIHtcbiAgICAgICAgICAgIC8vIGVzbGludC1kaXNhYmxlLW5leHQtbGluZSBuby1zZWxmLWFzc2lnblxuICAgICAgICAgICAgZWwuc3Jjc2V0ID0gZWwuc3Jjc2V0O1xuICAgICAgICAgIH0gZWxzZSBpZiAoZWwgaW5zdGFuY2VvZiBIVE1MVmlkZW9FbGVtZW50ICYmIGVsLmF1dG9wbGF5KSB7XG4gICAgICAgICAgICBlbC5wbGF5KCk7XG4gICAgICAgICAgfVxuICAgICAgICAgIGlmIChET00uaXNOb3dUcmlnZ2VyRm9ybUV4dGVybmFsKGVsLCBwaHhUcmlnZ2VyRXh0ZXJuYWwpKSB7XG4gICAgICAgICAgICBleHRlcm5hbEZvcm1UcmlnZ2VyZWQgPSBlbDtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICAvLyBuZXN0ZWQgdmlldyBoYW5kbGluZ1xuICAgICAgICAgIGlmIChcbiAgICAgICAgICAgIChET00uaXNQaHhDaGlsZChlbCkgJiYgdmlldy5vd25zRWxlbWVudChlbCkpIHx8XG4gICAgICAgICAgICAoRE9NLmlzUGh4U3RpY2t5KGVsKSAmJiB2aWV3Lm93bnNFbGVtZW50KGVsLnBhcmVudE5vZGUpKVxuICAgICAgICAgICkge1xuICAgICAgICAgICAgdGhpcy50cmFja0FmdGVyKFwicGh4Q2hpbGRBZGRlZFwiLCBlbCk7XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgLy8gZGF0YS1waHgtcnVudGltZS1ob29rXG4gICAgICAgICAgaWYgKGVsLm5vZGVOYW1lID09PSBcIlNDUklQVFwiICYmIGVsLmhhc0F0dHJpYnV0ZShQSFhfUlVOVElNRV9IT09LKSkge1xuICAgICAgICAgICAgdGhpcy5oYW5kbGVSdW50aW1lSG9vayhlbCwgc291cmNlKTtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICBhZGRlZC5wdXNoKGVsKTtcbiAgICAgICAgfSxcbiAgICAgICAgb25Ob2RlRGlzY2FyZGVkOiAoZWwpID0+IHRoaXMub25Ob2RlRGlzY2FyZGVkKGVsKSxcbiAgICAgICAgb25CZWZvcmVOb2RlRGlzY2FyZGVkOiAoZWwpID0+IHtcbiAgICAgICAgICBpZiAoZWwuZ2V0QXR0cmlidXRlICYmIGVsLmdldEF0dHJpYnV0ZShQSFhfUFJVTkUpICE9PSBudWxsKSB7XG4gICAgICAgICAgICByZXR1cm4gdHJ1ZTtcbiAgICAgICAgICB9XG4gICAgICAgICAgaWYgKFxuICAgICAgICAgICAgZWwucGFyZW50RWxlbWVudCAhPT0gbnVsbCAmJlxuICAgICAgICAgICAgZWwuaWQgJiZcbiAgICAgICAgICAgIERPTS5pc1BoeFVwZGF0ZShlbC5wYXJlbnRFbGVtZW50LCBwaHhVcGRhdGUsIFtcbiAgICAgICAgICAgICAgUEhYX1NUUkVBTSxcbiAgICAgICAgICAgICAgXCJhcHBlbmRcIixcbiAgICAgICAgICAgICAgXCJwcmVwZW5kXCIsXG4gICAgICAgICAgICBdKVxuICAgICAgICAgICkge1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICAgIH1cbiAgICAgICAgICAvLyBkb24ndCByZW1vdmUgdGVsZXBvcnRlZCBlbGVtZW50c1xuICAgICAgICAgIGlmIChlbC5nZXRBdHRyaWJ1dGUgJiYgZWwuZ2V0QXR0cmlidXRlKFBIWF9URUxFUE9SVEVEX1JFRikpIHtcbiAgICAgICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgICAgICB9XG4gICAgICAgICAgaWYgKHRoaXMubWF5YmVQZW5kaW5nUmVtb3ZlKGVsKSkge1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICAgIH1cbiAgICAgICAgICBpZiAodGhpcy5za2lwQ0lEU2libGluZyhlbCkpIHtcbiAgICAgICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICBpZiAoRE9NLmlzUG9ydGFsVGVtcGxhdGUoZWwpKSB7XG4gICAgICAgICAgICAvLyBpZiB0aGUgcG9ydGFsIHRlbXBsYXRlIGl0c2VsZiBpcyByZW1vdmVkLCByZW1vdmUgdGhlIHRlbGVwb3J0ZWQgZWxlbWVudCBhcyB3ZWxsO1xuICAgICAgICAgICAgLy8gd2UgYWxzbyBwZXJmb3JtIGEgY2hlY2sgYWZ0ZXIgbW9ycGhkb20gaXMgZmluaXNoZWQgdG8gY2F0Y2ggcGFyZW50IHJlbW92YWxzXG4gICAgICAgICAgICBjb25zdCB0ZWxlcG9ydGVkRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChcbiAgICAgICAgICAgICAgZWwuY29udGVudC5maXJzdEVsZW1lbnRDaGlsZC5pZCxcbiAgICAgICAgICAgICk7XG4gICAgICAgICAgICBpZiAodGVsZXBvcnRlZEVsKSB7XG4gICAgICAgICAgICAgIHRlbGVwb3J0ZWRFbC5yZW1vdmUoKTtcbiAgICAgICAgICAgICAgbW9ycGhDYWxsYmFja3Mub25Ob2RlRGlzY2FyZGVkKHRlbGVwb3J0ZWRFbCk7XG4gICAgICAgICAgICAgIHRoaXMudmlldy5kcm9wUG9ydGFsRWxlbWVudElkKHRlbGVwb3J0ZWRFbC5pZCk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgcmV0dXJuIHRydWU7XG4gICAgICAgIH0sXG4gICAgICAgIG9uRWxVcGRhdGVkOiAoZWwpID0+IHtcbiAgICAgICAgICBpZiAoRE9NLmlzTm93VHJpZ2dlckZvcm1FeHRlcm5hbChlbCwgcGh4VHJpZ2dlckV4dGVybmFsKSkge1xuICAgICAgICAgICAgZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkID0gZWw7XG4gICAgICAgICAgfVxuICAgICAgICAgIHVwZGF0ZXMucHVzaChlbCk7XG4gICAgICAgICAgdGhpcy5tYXliZVJlT3JkZXJTdHJlYW0oZWwsIGZhbHNlKTtcbiAgICAgICAgfSxcbiAgICAgICAgb25CZWZvcmVFbFVwZGF0ZWQ6IChmcm9tRWwsIHRvRWwpID0+IHtcbiAgICAgICAgICAvLyBpZiB3ZSBhcmUgcGF0Y2hpbmcgdGhlIHJvb3QgdGFyZ2V0IGNvbnRhaW5lciBhbmQgdGhlIGlkIGhhcyBjaGFuZ2VkLCB0cmVhdCBpdCBhcyBhIG5ldyBub2RlXG4gICAgICAgICAgLy8gYnkgcmVwbGFjaW5nIHRoZSBmcm9tRWwgd2l0aCB0aGUgdG9FbCwgd2hpY2ggZW5zdXJlcyBob29rcyBhcmUgdG9ybiBkb3duIGFuZCByZS1jcmVhdGVkXG4gICAgICAgICAgaWYgKFxuICAgICAgICAgICAgZnJvbUVsLmlkICYmXG4gICAgICAgICAgICBmcm9tRWwuaXNTYW1lTm9kZSh0YXJnZXRDb250YWluZXIpICYmXG4gICAgICAgICAgICBmcm9tRWwuaWQgIT09IHRvRWwuaWRcbiAgICAgICAgICApIHtcbiAgICAgICAgICAgIG1vcnBoQ2FsbGJhY2tzLm9uTm9kZURpc2NhcmRlZChmcm9tRWwpO1xuICAgICAgICAgICAgZnJvbUVsLnJlcGxhY2VXaXRoKHRvRWwpO1xuICAgICAgICAgICAgcmV0dXJuIG1vcnBoQ2FsbGJhY2tzLm9uTm9kZUFkZGVkKHRvRWwpO1xuICAgICAgICAgIH1cbiAgICAgICAgICBET00uc3luY1BlbmRpbmdBdHRycyhmcm9tRWwsIHRvRWwpO1xuICAgICAgICAgIERPTS5tYWludGFpblByaXZhdGVIb29rcyhcbiAgICAgICAgICAgIGZyb21FbCxcbiAgICAgICAgICAgIHRvRWwsXG4gICAgICAgICAgICBwaHhWaWV3cG9ydFRvcCxcbiAgICAgICAgICAgIHBoeFZpZXdwb3J0Qm90dG9tLFxuICAgICAgICAgICk7XG4gICAgICAgICAgRE9NLmNsZWFuQ2hpbGROb2Rlcyh0b0VsLCBwaHhVcGRhdGUpO1xuICAgICAgICAgIGlmICh0aGlzLnNraXBDSURTaWJsaW5nKHRvRWwpKSB7XG4gICAgICAgICAgICAvLyBpZiB0aGlzIGlzIGEgbGl2ZSBjb21wb25lbnQgdXNlZCBpbiBhIHN0cmVhbSwgd2UgbWF5IG5lZWQgdG8gcmVvcmRlciBpdFxuICAgICAgICAgICAgdGhpcy5tYXliZVJlT3JkZXJTdHJlYW0oZnJvbUVsKTtcbiAgICAgICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgICAgICB9XG4gICAgICAgICAgaWYgKERPTS5pc1BoeFN0aWNreShmcm9tRWwpKSB7XG4gICAgICAgICAgICBbUEhYX1NFU1NJT04sIFBIWF9TVEFUSUMsIFBIWF9ST09UX0lEXVxuICAgICAgICAgICAgICAubWFwKChhdHRyKSA9PiBbXG4gICAgICAgICAgICAgICAgYXR0cixcbiAgICAgICAgICAgICAgICBmcm9tRWwuZ2V0QXR0cmlidXRlKGF0dHIpLFxuICAgICAgICAgICAgICAgIHRvRWwuZ2V0QXR0cmlidXRlKGF0dHIpLFxuICAgICAgICAgICAgICBdKVxuICAgICAgICAgICAgICAuZm9yRWFjaCgoW2F0dHIsIGZyb21WYWwsIHRvVmFsXSkgPT4ge1xuICAgICAgICAgICAgICAgIGlmICh0b1ZhbCAmJiBmcm9tVmFsICE9PSB0b1ZhbCkge1xuICAgICAgICAgICAgICAgICAgZnJvbUVsLnNldEF0dHJpYnV0ZShhdHRyLCB0b1ZhbCk7XG4gICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICB9KTtcblxuICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICAgIH1cbiAgICAgICAgICBpZiAoXG4gICAgICAgICAgICBET00uaXNJZ25vcmVkKGZyb21FbCwgcGh4VXBkYXRlKSB8fFxuICAgICAgICAgICAgKGZyb21FbC5mb3JtICYmIGZyb21FbC5mb3JtLmlzU2FtZU5vZGUoZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkKSlcbiAgICAgICAgICApIHtcbiAgICAgICAgICAgIHRoaXMudHJhY2tCZWZvcmUoXCJ1cGRhdGVkXCIsIGZyb21FbCwgdG9FbCk7XG4gICAgICAgICAgICBET00ubWVyZ2VBdHRycyhmcm9tRWwsIHRvRWwsIHtcbiAgICAgICAgICAgICAgaXNJZ25vcmVkOiBET00uaXNJZ25vcmVkKGZyb21FbCwgcGh4VXBkYXRlKSxcbiAgICAgICAgICAgIH0pO1xuICAgICAgICAgICAgdXBkYXRlcy5wdXNoKGZyb21FbCk7XG4gICAgICAgICAgICBET00uYXBwbHlTdGlja3lPcGVyYXRpb25zKGZyb21FbCk7XG4gICAgICAgICAgICByZXR1cm4gZmFsc2U7XG4gICAgICAgICAgfVxuICAgICAgICAgIGlmIChcbiAgICAgICAgICAgIGZyb21FbC50eXBlID09PSBcIm51bWJlclwiICYmXG4gICAgICAgICAgICBmcm9tRWwudmFsaWRpdHkgJiZcbiAgICAgICAgICAgIGZyb21FbC52YWxpZGl0eS5iYWRJbnB1dFxuICAgICAgICAgICkge1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICAgIH1cbiAgICAgICAgICAvLyBJZiB0aGUgZWxlbWVudCBoYXMgUEhYX1JFRl9TUkMsIGl0IGlzIGxvYWRpbmcgb3IgbG9ja2VkIGFuZCBhd2FpdGluZyBhbiBhY2suXG4gICAgICAgICAgLy8gSWYgaXQncyBsb2NrZWQsIHdlIGNsb25lIHRoZSBmcm9tRWwgdHJlZSBhbmQgaW5zdHJ1Y3QgbW9ycGhkb20gdG8gdXNlXG4gICAgICAgICAgLy8gdGhlIGNsb25lZCB0cmVlIGFzIHRoZSBzb3VyY2Ugb2YgdGhlIG1vcnBoIGZvciB0aGlzIGJyYW5jaCBmcm9tIGhlcmUgb24gb3V0LlxuICAgICAgICAgIC8vIFdlIGtlZXAgYSByZWZlcmVuY2UgdG8gdGhlIGNsb25lZCB0cmVlIGluIHRoZSBlbGVtZW50J3MgcHJpdmF0ZSBkYXRhLCBhbmRcbiAgICAgICAgICAvLyBvbiBhY2sgKHZpZXcudW5kb1JlZnMpLCB3ZSBtb3JwaCB0aGUgY2xvbmVkIHRyZWUgd2l0aCB0aGUgdHJ1ZSBmcm9tRWwgaW4gdGhlIERPTSB0b1xuICAgICAgICAgIC8vIGFwcGx5IGFueSBjaGFuZ2VzIHRoYXQgaGFwcGVuZWQgd2hpbGUgdGhlIGVsZW1lbnQgd2FzIGxvY2tlZC5cbiAgICAgICAgICBjb25zdCBpc0ZvY3VzZWRGb3JtRWwgPVxuICAgICAgICAgICAgZm9jdXNlZCAmJiBmcm9tRWwuaXNTYW1lTm9kZShmb2N1c2VkKSAmJiBET00uaXNGb3JtSW5wdXQoZnJvbUVsKTtcbiAgICAgICAgICBjb25zdCBmb2N1c2VkU2VsZWN0Q2hhbmdlZCA9XG4gICAgICAgICAgICBpc0ZvY3VzZWRGb3JtRWwgJiYgdGhpcy5pc0NoYW5nZWRTZWxlY3QoZnJvbUVsLCB0b0VsKTtcbiAgICAgICAgICBpZiAoZnJvbUVsLmhhc0F0dHJpYnV0ZShQSFhfUkVGX1NSQykpIHtcbiAgICAgICAgICAgIGNvbnN0IHJlZiA9IG5ldyBFbGVtZW50UmVmKGZyb21FbCk7XG4gICAgICAgICAgICAvLyBvbmx5IHBlcmZvcm0gdGhlIGNsb25lIHN0ZXAgaWYgdGhpcyBpcyBub3QgYSBwYXRjaCB0aGF0IHVubG9ja3NcbiAgICAgICAgICAgIGlmIChcbiAgICAgICAgICAgICAgcmVmLmxvY2tSZWYgJiZcbiAgICAgICAgICAgICAgKCF0aGlzLnVuZG9SZWYgfHwgIXJlZi5pc0xvY2tVbmRvbmVCeSh0aGlzLnVuZG9SZWYpKVxuICAgICAgICAgICAgKSB7XG4gICAgICAgICAgICAgIGlmIChET00uaXNVcGxvYWRJbnB1dChmcm9tRWwpKSB7XG4gICAgICAgICAgICAgICAgRE9NLm1lcmdlQXR0cnMoZnJvbUVsLCB0b0VsLCB7IGlzSWdub3JlZDogdHJ1ZSB9KTtcbiAgICAgICAgICAgICAgICB0aGlzLnRyYWNrQmVmb3JlKFwidXBkYXRlZFwiLCBmcm9tRWwsIHRvRWwpO1xuICAgICAgICAgICAgICAgIHVwZGF0ZXMucHVzaChmcm9tRWwpO1xuICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgIERPTS5hcHBseVN0aWNreU9wZXJhdGlvbnMoZnJvbUVsKTtcbiAgICAgICAgICAgICAgY29uc3QgaXNMb2NrZWQgPSBmcm9tRWwuaGFzQXR0cmlidXRlKFBIWF9SRUZfTE9DSyk7XG4gICAgICAgICAgICAgIGNvbnN0IGNsb25lID0gaXNMb2NrZWRcbiAgICAgICAgICAgICAgICA/IERPTS5wcml2YXRlKGZyb21FbCwgUEhYX1JFRl9MT0NLKSB8fCBmcm9tRWwuY2xvbmVOb2RlKHRydWUpXG4gICAgICAgICAgICAgICAgOiBudWxsO1xuICAgICAgICAgICAgICBpZiAoY2xvbmUpIHtcbiAgICAgICAgICAgICAgICBET00ucHV0UHJpdmF0ZShmcm9tRWwsIFBIWF9SRUZfTE9DSywgY2xvbmUpO1xuICAgICAgICAgICAgICAgIGlmICghaXNGb2N1c2VkRm9ybUVsKSB7XG4gICAgICAgICAgICAgICAgICBmcm9tRWwgPSBjbG9uZTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH1cbiAgICAgICAgICB9XG5cbiAgICAgICAgICAvLyBuZXN0ZWQgdmlldyBoYW5kbGluZ1xuICAgICAgICAgIGlmIChET00uaXNQaHhDaGlsZCh0b0VsKSkge1xuICAgICAgICAgICAgY29uc3QgcHJldlNlc3Npb24gPSBmcm9tRWwuZ2V0QXR0cmlidXRlKFBIWF9TRVNTSU9OKTtcbiAgICAgICAgICAgIERPTS5tZXJnZUF0dHJzKGZyb21FbCwgdG9FbCwgeyBleGNsdWRlOiBbUEhYX1NUQVRJQ10gfSk7XG4gICAgICAgICAgICBpZiAocHJldlNlc3Npb24gIT09IFwiXCIpIHtcbiAgICAgICAgICAgICAgZnJvbUVsLnNldEF0dHJpYnV0ZShQSFhfU0VTU0lPTiwgcHJldlNlc3Npb24pO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgZnJvbUVsLnNldEF0dHJpYnV0ZShQSFhfUk9PVF9JRCwgdGhpcy5yb290SUQpO1xuICAgICAgICAgICAgRE9NLmFwcGx5U3RpY2t5T3BlcmF0aW9ucyhmcm9tRWwpO1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICAgIH1cblxuICAgICAgICAgIC8vIGlmIHdlIGFyZSB1bmRvaW5nIGEgbG9jaywgY29weSBwb3RlbnRpYWxseSBuZXN0ZWQgY2xvbmVzIG92ZXJcbiAgICAgICAgICBpZiAodGhpcy51bmRvUmVmICYmIERPTS5wcml2YXRlKHRvRWwsIFBIWF9SRUZfTE9DSykpIHtcbiAgICAgICAgICAgIERPTS5wdXRQcml2YXRlKFxuICAgICAgICAgICAgICBmcm9tRWwsXG4gICAgICAgICAgICAgIFBIWF9SRUZfTE9DSyxcbiAgICAgICAgICAgICAgRE9NLnByaXZhdGUodG9FbCwgUEhYX1JFRl9MT0NLKSxcbiAgICAgICAgICAgICk7XG4gICAgICAgICAgfVxuICAgICAgICAgIC8vIG5vdyBjb3B5IHJlZ3VsYXIgRE9NLnByaXZhdGUgZGF0YVxuICAgICAgICAgIERPTS5jb3B5UHJpdmF0ZXModG9FbCwgZnJvbUVsKTtcblxuICAgICAgICAgIC8vIHBoeC1wb3J0YWwgaGFuZGxpbmdcbiAgICAgICAgICBpZiAoRE9NLmlzUG9ydGFsVGVtcGxhdGUodG9FbCkpIHtcbiAgICAgICAgICAgIHBvcnRhbENhbGxiYWNrcy5wdXNoKCgpID0+IHRoaXMudGVsZXBvcnQodG9FbCwgbW9ycGgpKTtcbiAgICAgICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICAvLyBza2lwIHBhdGNoaW5nIGZvY3VzZWQgaW5wdXRzIHVubGVzcyBmb2N1cyBpcyBhIHNlbGVjdCB0aGF0IGhhcyBjaGFuZ2VkIG9wdGlvbnNcbiAgICAgICAgICBpZiAoXG4gICAgICAgICAgICBpc0ZvY3VzZWRGb3JtRWwgJiZcbiAgICAgICAgICAgIGZyb21FbC50eXBlICE9PSBcImhpZGRlblwiICYmXG4gICAgICAgICAgICAhZm9jdXNlZFNlbGVjdENoYW5nZWRcbiAgICAgICAgICApIHtcbiAgICAgICAgICAgIHRoaXMudHJhY2tCZWZvcmUoXCJ1cGRhdGVkXCIsIGZyb21FbCwgdG9FbCk7XG4gICAgICAgICAgICBET00ubWVyZ2VGb2N1c2VkSW5wdXQoZnJvbUVsLCB0b0VsKTtcbiAgICAgICAgICAgIERPTS5zeW5jQXR0cnNUb1Byb3BzKGZyb21FbCk7XG4gICAgICAgICAgICB1cGRhdGVzLnB1c2goZnJvbUVsKTtcbiAgICAgICAgICAgIERPTS5hcHBseVN0aWNreU9wZXJhdGlvbnMoZnJvbUVsKTtcbiAgICAgICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgLy8gYmx1ciBmb2N1c2VkIHNlbGVjdCBpZiBpdCBjaGFuZ2VkIHNvIG5hdGl2ZSBVSSBpcyB1cGRhdGVkIChpZSBzYWZhcmkgd29uJ3QgdXBkYXRlIHZpc2libGUgb3B0aW9ucylcbiAgICAgICAgICAgIGlmIChmb2N1c2VkU2VsZWN0Q2hhbmdlZCkge1xuICAgICAgICAgICAgICBmcm9tRWwuYmx1cigpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgaWYgKERPTS5pc1BoeFVwZGF0ZSh0b0VsLCBwaHhVcGRhdGUsIFtcImFwcGVuZFwiLCBcInByZXBlbmRcIl0pKSB7XG4gICAgICAgICAgICAgIGFwcGVuZFByZXBlbmRVcGRhdGVzLnB1c2goXG4gICAgICAgICAgICAgICAgbmV3IERPTVBvc3RNb3JwaFJlc3RvcmVyKFxuICAgICAgICAgICAgICAgICAgZnJvbUVsLFxuICAgICAgICAgICAgICAgICAgdG9FbCxcbiAgICAgICAgICAgICAgICAgIHRvRWwuZ2V0QXR0cmlidXRlKHBoeFVwZGF0ZSksXG4gICAgICAgICAgICAgICAgKSxcbiAgICAgICAgICAgICAgKTtcbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgRE9NLnN5bmNBdHRyc1RvUHJvcHModG9FbCk7XG4gICAgICAgICAgICBET00uYXBwbHlTdGlja3lPcGVyYXRpb25zKHRvRWwpO1xuICAgICAgICAgICAgdGhpcy50cmFja0JlZm9yZShcInVwZGF0ZWRcIiwgZnJvbUVsLCB0b0VsKTtcbiAgICAgICAgICAgIHJldHVybiBmcm9tRWw7XG4gICAgICAgICAgfVxuICAgICAgICB9LFxuICAgICAgfTtcblxuICAgICAgbW9ycGhkb20odGFyZ2V0Q29udGFpbmVyLCBzb3VyY2UsIG1vcnBoQ2FsbGJhY2tzKTtcbiAgICB9O1xuXG4gICAgdGhpcy50cmFja0JlZm9yZShcImFkZGVkXCIsIGNvbnRhaW5lcik7XG4gICAgdGhpcy50cmFja0JlZm9yZShcInVwZGF0ZWRcIiwgY29udGFpbmVyLCBjb250YWluZXIpO1xuXG4gICAgbGl2ZVNvY2tldC50aW1lKFwibW9ycGhkb21cIiwgKCkgPT4ge1xuICAgICAgdGhpcy5zdHJlYW1zLmZvckVhY2goKFtyZWYsIGluc2VydHMsIGRlbGV0ZUlkcywgcmVzZXRdKSA9PiB7XG4gICAgICAgIGluc2VydHMuZm9yRWFjaCgoW2tleSwgc3RyZWFtQXQsIGxpbWl0LCB1cGRhdGVPbmx5XSkgPT4ge1xuICAgICAgICAgIHRoaXMuc3RyZWFtSW5zZXJ0c1trZXldID0geyByZWYsIHN0cmVhbUF0LCBsaW1pdCwgcmVzZXQsIHVwZGF0ZU9ubHkgfTtcbiAgICAgICAgfSk7XG4gICAgICAgIGlmIChyZXNldCAhPT0gdW5kZWZpbmVkKSB7XG4gICAgICAgICAgRE9NLmFsbChjb250YWluZXIsIGBbJHtQSFhfU1RSRUFNX1JFRn09XCIke3JlZn1cIl1gLCAoY2hpbGQpID0+IHtcbiAgICAgICAgICAgIHRoaXMucmVtb3ZlU3RyZWFtQ2hpbGRFbGVtZW50KGNoaWxkKTtcbiAgICAgICAgICB9KTtcbiAgICAgICAgfVxuICAgICAgICBkZWxldGVJZHMuZm9yRWFjaCgoaWQpID0+IHtcbiAgICAgICAgICBjb25zdCBjaGlsZCA9IGNvbnRhaW5lci5xdWVyeVNlbGVjdG9yKGBbaWQ9XCIke2lkfVwiXWApO1xuICAgICAgICAgIGlmIChjaGlsZCkge1xuICAgICAgICAgICAgdGhpcy5yZW1vdmVTdHJlYW1DaGlsZEVsZW1lbnQoY2hpbGQpO1xuICAgICAgICAgIH1cbiAgICAgICAgfSk7XG4gICAgICB9KTtcblxuICAgICAgLy8gY2xlYXIgc3RyZWFtIGl0ZW1zIGZyb20gdGhlIGRlYWQgcmVuZGVyIGlmIHRoZXkgYXJlIG5vdCBpbnNlcnRlZCBhZ2FpblxuICAgICAgaWYgKGlzSm9pblBhdGNoKSB7XG4gICAgICAgIERPTS5hbGwodGhpcy5jb250YWluZXIsIGBbJHtwaHhVcGRhdGV9PSR7UEhYX1NUUkVBTX1dYClcbiAgICAgICAgICAvLyBpdCBpcyBpbXBvcnRhbnQgdG8gZmlsdGVyIHRoZSBlbGVtZW50IGJlZm9yZSByZW1vdmluZyB0aGVtLCBhc1xuICAgICAgICAgIC8vIGl0IG1heSBoYXBwZW4gdGhhdCBzdHJlYW1zIGFyZSBuZXN0ZWQgYW5kIHRoZSBvd25lciBjaGVjayBmYWlscyBpZlxuICAgICAgICAgIC8vIGEgcGFyZW50IGlzIHJlbW92ZWQgYmVmb3JlIGEgY2hpbGRcbiAgICAgICAgICAuZmlsdGVyKChlbCkgPT4gdGhpcy52aWV3Lm93bnNFbGVtZW50KGVsKSlcbiAgICAgICAgICAuZm9yRWFjaCgoZWwpID0+IHtcbiAgICAgICAgICAgIEFycmF5LmZyb20oZWwuY2hpbGRyZW4pLmZvckVhY2goKGNoaWxkKSA9PiB7XG4gICAgICAgICAgICAgIC8vIHdlIGFscmVhZHkgcGVyZm9ybWVkIHRoZSBvd25lciBjaGVjaywgZWFjaCBjaGlsZCBpcyBndWFyYW50ZWVkIHRvIGJlIG93bmVkXG4gICAgICAgICAgICAgIC8vIGJ5IHRoZSB2aWV3LiBUbyBwcmV2ZW50IHRoZSBuZXN0ZWQgb3duZXIgY2hlY2sgZnJvbSBmYWlsaW5nIGluIGNhc2Ugb2YgbmVzdGVkXG4gICAgICAgICAgICAgIC8vIHN0cmVhbXMgd2hlcmUgdGhlIHBhcmVudCBpcyByZW1vdmVkIGJlZm9yZSB0aGUgY2hpbGQsIHdlIGZvcmNlIHRoZSByZW1vdmFsXG4gICAgICAgICAgICAgIHRoaXMucmVtb3ZlU3RyZWFtQ2hpbGRFbGVtZW50KGNoaWxkLCB0cnVlKTtcbiAgICAgICAgICAgIH0pO1xuICAgICAgICAgIH0pO1xuICAgICAgfVxuXG4gICAgICBtb3JwaCh0YXJnZXRDb250YWluZXIsIGh0bWwpO1xuICAgICAgLy8gbm9ybWFsIHBhdGNoIGNvbXBsZXRlLCB0ZWxlcG9ydCBlbGVtZW50cyBub3dcbiAgICAgIHBvcnRhbENhbGxiYWNrcy5mb3JFYWNoKChjYWxsYmFjaykgPT4gY2FsbGJhY2soKSk7XG4gICAgICAvLyBjaGVjayBmb3IgYW55IHRlbGVwb3J0ZWQgZWxlbWVudHMgdGhhdCBhcmUgbm90IGluIHRoZSB2aWV3IGFueSBtb3JlXG4gICAgICAvLyBhbmQgcmVtb3ZlIHRoZW1cbiAgICAgIHRoaXMudmlldy5wb3J0YWxFbGVtZW50SWRzLmZvckVhY2goKGlkKSA9PiB7XG4gICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpO1xuICAgICAgICBpZiAoZWwpIHtcbiAgICAgICAgICBjb25zdCBzb3VyY2UgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChcbiAgICAgICAgICAgIGVsLmdldEF0dHJpYnV0ZShQSFhfVEVMRVBPUlRFRF9TUkMpLFxuICAgICAgICAgICk7XG4gICAgICAgICAgaWYgKCFzb3VyY2UpIHtcbiAgICAgICAgICAgIGVsLnJlbW92ZSgpO1xuICAgICAgICAgICAgdGhpcy5vbk5vZGVEaXNjYXJkZWQoZWwpO1xuICAgICAgICAgICAgdGhpcy52aWV3LmRyb3BQb3J0YWxFbGVtZW50SWQoaWQpO1xuICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgICAgfSk7XG4gICAgfSk7XG5cbiAgICBpZiAobGl2ZVNvY2tldC5pc0RlYnVnRW5hYmxlZCgpKSB7XG4gICAgICBkZXRlY3REdXBsaWNhdGVJZHMoKTtcbiAgICAgIGRldGVjdEludmFsaWRTdHJlYW1JbnNlcnRzKHRoaXMuc3RyZWFtSW5zZXJ0cyk7XG4gICAgICAvLyB3YXJuIGlmIHRoZXJlIGFyZSBhbnkgaW5wdXRzIG5hbWVkIFwiaWRcIlxuICAgICAgQXJyYXkuZnJvbShkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKFwiaW5wdXRbbmFtZT1pZF1cIikpLmZvckVhY2goXG4gICAgICAgIChub2RlKSA9PiB7XG4gICAgICAgICAgaWYgKG5vZGUgaW5zdGFuY2VvZiBIVE1MSW5wdXRFbGVtZW50ICYmIG5vZGUuZm9ybSkge1xuICAgICAgICAgICAgY29uc29sZS5lcnJvcihcbiAgICAgICAgICAgICAgJ0RldGVjdGVkIGFuIGlucHV0IHdpdGggbmFtZT1cImlkXCIgaW5zaWRlIGEgZm9ybSEgVGhpcyB3aWxsIGNhdXNlIHByb2JsZW1zIHdoZW4gcGF0Y2hpbmcgdGhlIERPTS5cXG4nLFxuICAgICAgICAgICAgICBub2RlLFxuICAgICAgICAgICAgKTtcbiAgICAgICAgICB9XG4gICAgICAgIH0sXG4gICAgICApO1xuICAgIH1cblxuICAgIGlmIChhcHBlbmRQcmVwZW5kVXBkYXRlcy5sZW5ndGggPiAwKSB7XG4gICAgICBsaXZlU29ja2V0LnRpbWUoXCJwb3N0LW1vcnBoIGFwcGVuZC9wcmVwZW5kIHJlc3RvcmF0aW9uXCIsICgpID0+IHtcbiAgICAgICAgYXBwZW5kUHJlcGVuZFVwZGF0ZXMuZm9yRWFjaCgodXBkYXRlKSA9PiB1cGRhdGUucGVyZm9ybSgpKTtcbiAgICAgIH0pO1xuICAgIH1cblxuICAgIGxpdmVTb2NrZXQuc2lsZW5jZUV2ZW50cygoKSA9PlxuICAgICAgRE9NLnJlc3RvcmVGb2N1cyhmb2N1c2VkLCBzZWxlY3Rpb25TdGFydCwgc2VsZWN0aW9uRW5kKSxcbiAgICApO1xuICAgIERPTS5kaXNwYXRjaEV2ZW50KGRvY3VtZW50LCBcInBoeDp1cGRhdGVcIik7XG4gICAgYWRkZWQuZm9yRWFjaCgoZWwpID0+IHRoaXMudHJhY2tBZnRlcihcImFkZGVkXCIsIGVsKSk7XG4gICAgdXBkYXRlcy5mb3JFYWNoKChlbCkgPT4gdGhpcy50cmFja0FmdGVyKFwidXBkYXRlZFwiLCBlbCkpO1xuXG4gICAgdGhpcy50cmFuc2l0aW9uUGVuZGluZ1JlbW92ZXMoKTtcblxuICAgIGlmIChleHRlcm5hbEZvcm1UcmlnZ2VyZWQpIHtcbiAgICAgIGxpdmVTb2NrZXQudW5sb2FkKCk7XG4gICAgICAvLyBjaGVjayBmb3Igc3VibWl0dGVyIGFuZCBpbmplY3QgaXQgYXMgaGlkZGVuIGlucHV0IGZvciBleHRlcm5hbCBzdWJtaXQ7XG4gICAgICAvLyBJbiB0aGVvcnksIGl0IGNvdWxkIGhhcHBlbiB0aGF0IHRoZSBzdG9yZWQgc3VibWl0dGVyIGlzIG91dGRhdGVkIGFuZCBkb2Vzbid0XG4gICAgICAvLyBleGlzdCBpbiB0aGUgRE9NIGFueSBtb3JlLCBidXQgdGhpcyBpcyB1bmxpa2VseSwgc28gd2UganVzdCBhY2NlcHQgaXQgZm9yIG5vdy5cbiAgICAgIGNvbnN0IHN1Ym1pdHRlciA9IERPTS5wcml2YXRlKGV4dGVybmFsRm9ybVRyaWdnZXJlZCwgXCJzdWJtaXR0ZXJcIik7XG4gICAgICBpZiAoc3VibWl0dGVyICYmIHN1Ym1pdHRlci5uYW1lICYmIHRhcmdldENvbnRhaW5lci5jb250YWlucyhzdWJtaXR0ZXIpKSB7XG4gICAgICAgIGNvbnN0IGlucHV0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcImlucHV0XCIpO1xuICAgICAgICBpbnB1dC50eXBlID0gXCJoaWRkZW5cIjtcbiAgICAgICAgY29uc3QgZm9ybUlkID0gc3VibWl0dGVyLmdldEF0dHJpYnV0ZShcImZvcm1cIik7XG4gICAgICAgIGlmIChmb3JtSWQpIHtcbiAgICAgICAgICBpbnB1dC5zZXRBdHRyaWJ1dGUoXCJmb3JtXCIsIGZvcm1JZCk7XG4gICAgICAgIH1cbiAgICAgICAgaW5wdXQubmFtZSA9IHN1Ym1pdHRlci5uYW1lO1xuICAgICAgICBpbnB1dC52YWx1ZSA9IHN1Ym1pdHRlci52YWx1ZTtcbiAgICAgICAgc3VibWl0dGVyLnBhcmVudEVsZW1lbnQuaW5zZXJ0QmVmb3JlKGlucHV0LCBzdWJtaXR0ZXIpO1xuICAgICAgfVxuICAgICAgLy8gdXNlIHByb3RvdHlwZSdzIHN1Ym1pdCBpbiBjYXNlIHRoZXJlJ3MgYSBmb3JtIGNvbnRyb2wgd2l0aCBuYW1lIG9yIGlkIG9mIFwic3VibWl0XCJcbiAgICAgIC8vIGh0dHBzOi8vZGV2ZWxvcGVyLm1vemlsbGEub3JnL2VuLVVTL2RvY3MvV2ViL0FQSS9IVE1MRm9ybUVsZW1lbnQvc3VibWl0XG4gICAgICBPYmplY3QuZ2V0UHJvdG90eXBlT2YoZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkKS5zdWJtaXQuY2FsbChcbiAgICAgICAgZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkLFxuICAgICAgKTtcbiAgICB9XG4gICAgcmV0dXJuIHRydWU7XG4gIH1cblxuICBvbk5vZGVEaXNjYXJkZWQoZWwpIHtcbiAgICAvLyBuZXN0ZWQgdmlldyBoYW5kbGluZ1xuICAgIGlmIChET00uaXNQaHhDaGlsZChlbCkgfHwgRE9NLmlzUGh4U3RpY2t5KGVsKSkge1xuICAgICAgdGhpcy5saXZlU29ja2V0LmRlc3Ryb3lWaWV3QnlFbChlbCk7XG4gICAgfVxuICAgIHRoaXMudHJhY2tBZnRlcihcImRpc2NhcmRlZFwiLCBlbCk7XG4gIH1cblxuICBtYXliZVBlbmRpbmdSZW1vdmUobm9kZSkge1xuICAgIGlmIChub2RlLmdldEF0dHJpYnV0ZSAmJiBub2RlLmdldEF0dHJpYnV0ZSh0aGlzLnBoeFJlbW92ZSkgIT09IG51bGwpIHtcbiAgICAgIHRoaXMucGVuZGluZ1JlbW92ZXMucHVzaChub2RlKTtcbiAgICAgIHJldHVybiB0cnVlO1xuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gZmFsc2U7XG4gICAgfVxuICB9XG5cbiAgcmVtb3ZlU3RyZWFtQ2hpbGRFbGVtZW50KGNoaWxkLCBmb3JjZSA9IGZhbHNlKSB7XG4gICAgLy8gbWFrZSBzdXJlIHRvIG9ubHkgcmVtb3ZlIGVsZW1lbnRzIG93bmVkIGJ5IHRoZSBjdXJyZW50IHZpZXdcbiAgICAvLyBzZWUgaHR0cHM6Ly9naXRodWIuY29tL3Bob2VuaXhmcmFtZXdvcmsvcGhvZW5peF9saXZlX3ZpZXcvaXNzdWVzLzMwNDdcbiAgICAvLyBhbmQgaHR0cHM6Ly9naXRodWIuY29tL3Bob2VuaXhmcmFtZXdvcmsvcGhvZW5peF9saXZlX3ZpZXcvaXNzdWVzLzM2ODFcbiAgICBpZiAoIWZvcmNlICYmICF0aGlzLnZpZXcub3duc0VsZW1lbnQoY2hpbGQpKSB7XG4gICAgICByZXR1cm47XG4gICAgfVxuXG4gICAgLy8gd2UgbmVlZCB0byBzdG9yZSB0aGUgbm9kZSBpZiBpdCBpcyBhY3R1YWxseSByZS1hZGRlZCBpbiB0aGUgc2FtZSBwYXRjaFxuICAgIC8vIHdlIGRvIE5PVCB3YW50IHRvIGV4ZWN1dGUgcGh4LXJlbW92ZSwgd2UgZG8gTk9UIHdhbnQgdG8gY2FsbCBvbk5vZGVEaXNjYXJkZWRcbiAgICBpZiAodGhpcy5zdHJlYW1JbnNlcnRzW2NoaWxkLmlkXSkge1xuICAgICAgdGhpcy5zdHJlYW1Db21wb25lbnRSZXN0b3JlW2NoaWxkLmlkXSA9IGNoaWxkO1xuICAgICAgY2hpbGQucmVtb3ZlKCk7XG4gICAgfSBlbHNlIHtcbiAgICAgIC8vIG9ubHkgcmVtb3ZlIHRoZSBlbGVtZW50IG5vdyBpZiBpdCBoYXMgbm8gcGh4LXJlbW92ZSBiaW5kaW5nXG4gICAgICBpZiAoIXRoaXMubWF5YmVQZW5kaW5nUmVtb3ZlKGNoaWxkKSkge1xuICAgICAgICBjaGlsZC5yZW1vdmUoKTtcbiAgICAgICAgdGhpcy5vbk5vZGVEaXNjYXJkZWQoY2hpbGQpO1xuICAgICAgfVxuICAgIH1cbiAgfVxuXG4gIGdldFN0cmVhbUluc2VydChlbCkge1xuICAgIGNvbnN0IGluc2VydCA9IGVsLmlkID8gdGhpcy5zdHJlYW1JbnNlcnRzW2VsLmlkXSA6IHt9O1xuICAgIHJldHVybiBpbnNlcnQgfHwge307XG4gIH1cblxuICBzZXRTdHJlYW1SZWYoZWwsIHJlZikge1xuICAgIERPTS5wdXRTdGlja3koZWwsIFBIWF9TVFJFQU1fUkVGLCAoZWwpID0+XG4gICAgICBlbC5zZXRBdHRyaWJ1dGUoUEhYX1NUUkVBTV9SRUYsIHJlZiksXG4gICAgKTtcbiAgfVxuXG4gIG1heWJlUmVPcmRlclN0cmVhbShlbCwgaXNOZXcpIHtcbiAgICBjb25zdCB7IHJlZiwgc3RyZWFtQXQsIHJlc2V0IH0gPSB0aGlzLmdldFN0cmVhbUluc2VydChlbCk7XG4gICAgaWYgKHN0cmVhbUF0ID09PSB1bmRlZmluZWQpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG5cbiAgICAvLyB3ZSBuZWVkIHRvIHNldCB0aGUgUEhYX1NUUkVBTV9SRUYgaGVyZSBhcyB3ZWxsIGFzIGFkZENoaWxkIGlzIGludm9rZWQgb25seSBmb3IgcGFyZW50c1xuICAgIHRoaXMuc2V0U3RyZWFtUmVmKGVsLCByZWYpO1xuXG4gICAgaWYgKCFyZXNldCAmJiAhaXNOZXcpIHtcbiAgICAgIC8vIHdlIG9ubHkgcmVvcmRlciBpZiB0aGUgZWxlbWVudCBpcyBuZXcgb3IgaXQncyBhIHN0cmVhbSByZXNldFxuICAgICAgcmV0dXJuO1xuICAgIH1cblxuICAgIC8vIGNoZWNrIGlmIHRoZSBlbGVtZW50IGhhcyBhIHBhcmVudCBlbGVtZW50O1xuICAgIC8vIGl0IGRvZXNuJ3QgaWYgd2UgYXJlIGN1cnJlbnRseSByZWN1cnNpdmVseSBtb3JwaGluZyAocmVzdG9yaW5nIGEgc2F2ZWQgc3RyZWFtIGNoaWxkKVxuICAgIC8vIGJlY2F1c2UgdGhlIGVsZW1lbnQgaXMgbm90IHlldCBhZGRlZCB0byB0aGUgcmVhbCBkb207XG4gICAgLy8gcmVvcmRlcmluZyBkb2VzIG5vdCBtYWtlIHNlbnNlIGluIHRoYXQgY2FzZSBhbnl3YXlcbiAgICBpZiAoIWVsLnBhcmVudEVsZW1lbnQpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG5cbiAgICBpZiAoc3RyZWFtQXQgPT09IDApIHtcbiAgICAgIGVsLnBhcmVudEVsZW1lbnQuaW5zZXJ0QmVmb3JlKGVsLCBlbC5wYXJlbnRFbGVtZW50LmZpcnN0RWxlbWVudENoaWxkKTtcbiAgICB9IGVsc2UgaWYgKHN0cmVhbUF0ID4gMCkge1xuICAgICAgY29uc3QgY2hpbGRyZW4gPSBBcnJheS5mcm9tKGVsLnBhcmVudEVsZW1lbnQuY2hpbGRyZW4pO1xuICAgICAgY29uc3Qgb2xkSW5kZXggPSBjaGlsZHJlbi5pbmRleE9mKGVsKTtcbiAgICAgIGlmIChzdHJlYW1BdCA+PSBjaGlsZHJlbi5sZW5ndGggLSAxKSB7XG4gICAgICAgIGVsLnBhcmVudEVsZW1lbnQuYXBwZW5kQ2hpbGQoZWwpO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgY29uc3Qgc2libGluZyA9IGNoaWxkcmVuW3N0cmVhbUF0XTtcbiAgICAgICAgaWYgKG9sZEluZGV4ID4gc3RyZWFtQXQpIHtcbiAgICAgICAgICBlbC5wYXJlbnRFbGVtZW50Lmluc2VydEJlZm9yZShlbCwgc2libGluZyk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgZWwucGFyZW50RWxlbWVudC5pbnNlcnRCZWZvcmUoZWwsIHNpYmxpbmcubmV4dEVsZW1lbnRTaWJsaW5nKTtcbiAgICAgICAgfVxuICAgICAgfVxuICAgIH1cblxuICAgIHRoaXMubWF5YmVMaW1pdFN0cmVhbShlbCk7XG4gIH1cblxuICBtYXliZUxpbWl0U3RyZWFtKGVsKSB7XG4gICAgY29uc3QgeyBsaW1pdCB9ID0gdGhpcy5nZXRTdHJlYW1JbnNlcnQoZWwpO1xuICAgIGNvbnN0IGNoaWxkcmVuID0gbGltaXQgIT09IG51bGwgJiYgQXJyYXkuZnJvbShlbC5wYXJlbnRFbGVtZW50LmNoaWxkcmVuKTtcbiAgICBpZiAobGltaXQgJiYgbGltaXQgPCAwICYmIGNoaWxkcmVuLmxlbmd0aCA+IGxpbWl0ICogLTEpIHtcbiAgICAgIGNoaWxkcmVuXG4gICAgICAgIC5zbGljZSgwLCBjaGlsZHJlbi5sZW5ndGggKyBsaW1pdClcbiAgICAgICAgLmZvckVhY2goKGNoaWxkKSA9PiB0aGlzLnJlbW92ZVN0cmVhbUNoaWxkRWxlbWVudChjaGlsZCkpO1xuICAgIH0gZWxzZSBpZiAobGltaXQgJiYgbGltaXQgPj0gMCAmJiBjaGlsZHJlbi5sZW5ndGggPiBsaW1pdCkge1xuICAgICAgY2hpbGRyZW5cbiAgICAgICAgLnNsaWNlKGxpbWl0KVxuICAgICAgICAuZm9yRWFjaCgoY2hpbGQpID0+IHRoaXMucmVtb3ZlU3RyZWFtQ2hpbGRFbGVtZW50KGNoaWxkKSk7XG4gICAgfVxuICB9XG5cbiAgdHJhbnNpdGlvblBlbmRpbmdSZW1vdmVzKCkge1xuICAgIGNvbnN0IHsgcGVuZGluZ1JlbW92ZXMsIGxpdmVTb2NrZXQgfSA9IHRoaXM7XG4gICAgaWYgKHBlbmRpbmdSZW1vdmVzLmxlbmd0aCA+IDApIHtcbiAgICAgIGxpdmVTb2NrZXQudHJhbnNpdGlvblJlbW92ZXMocGVuZGluZ1JlbW92ZXMsICgpID0+IHtcbiAgICAgICAgcGVuZGluZ1JlbW92ZXMuZm9yRWFjaCgoZWwpID0+IHtcbiAgICAgICAgICBjb25zdCBjaGlsZCA9IERPTS5maXJzdFBoeENoaWxkKGVsKTtcbiAgICAgICAgICBpZiAoY2hpbGQpIHtcbiAgICAgICAgICAgIGxpdmVTb2NrZXQuZGVzdHJveVZpZXdCeUVsKGNoaWxkKTtcbiAgICAgICAgICB9XG4gICAgICAgICAgZWwucmVtb3ZlKCk7XG4gICAgICAgIH0pO1xuICAgICAgICB0aGlzLnRyYWNrQWZ0ZXIoXCJ0cmFuc2l0aW9uc0Rpc2NhcmRlZFwiLCBwZW5kaW5nUmVtb3Zlcyk7XG4gICAgICB9KTtcbiAgICB9XG4gIH1cblxuICBpc0NoYW5nZWRTZWxlY3QoZnJvbUVsLCB0b0VsKSB7XG4gICAgaWYgKCEoZnJvbUVsIGluc3RhbmNlb2YgSFRNTFNlbGVjdEVsZW1lbnQpIHx8IGZyb21FbC5tdWx0aXBsZSkge1xuICAgICAgcmV0dXJuIGZhbHNlO1xuICAgIH1cbiAgICBpZiAoZnJvbUVsLm9wdGlvbnMubGVuZ3RoICE9PSB0b0VsLm9wdGlvbnMubGVuZ3RoKSB7XG4gICAgICByZXR1cm4gdHJ1ZTtcbiAgICB9XG5cbiAgICAvLyBrZWVwIHRoZSBjdXJyZW50IHZhbHVlXG4gICAgdG9FbC52YWx1ZSA9IGZyb21FbC52YWx1ZTtcblxuICAgIC8vIGluIGdlbmVyYWwgd2UgaGF2ZSB0byBiZSB2ZXJ5IGNhcmVmdWwgd2l0aCB1c2luZyBpc0VxdWFsTm9kZSBhcyBpdCBkb2VzIG5vdCBhIHJlbGlhYmxlXG4gICAgLy8gRE9NIHRyZWUgZXF1YWxpdHkgY2hlY2ssIGJ1dCBmb3Igc2VsZWN0aW9uIGF0dHJpYnV0ZXMgYW5kIG9wdGlvbnMgaXQgd29ya3MgZmluZVxuICAgIHJldHVybiAhZnJvbUVsLmlzRXF1YWxOb2RlKHRvRWwpO1xuICB9XG5cbiAgaXNDSURQYXRjaCgpIHtcbiAgICByZXR1cm4gdGhpcy5jaWRQYXRjaDtcbiAgfVxuXG4gIHNraXBDSURTaWJsaW5nKGVsKSB7XG4gICAgcmV0dXJuIGVsLm5vZGVUeXBlID09PSBOb2RlLkVMRU1FTlRfTk9ERSAmJiBlbC5oYXNBdHRyaWJ1dGUoUEhYX1NLSVApO1xuICB9XG5cbiAgdGFyZ2V0Q0lEQ29udGFpbmVyKGh0bWwpIHtcbiAgICBpZiAoIXRoaXMuaXNDSURQYXRjaCgpKSB7XG4gICAgICByZXR1cm47XG4gICAgfVxuICAgIGNvbnN0IFtmaXJzdCwgLi4ucmVzdF0gPSBET00uZmluZENvbXBvbmVudE5vZGVMaXN0KFxuICAgICAgdGhpcy52aWV3LmlkLFxuICAgICAgdGhpcy50YXJnZXRDSUQsXG4gICAgKTtcbiAgICBpZiAocmVzdC5sZW5ndGggPT09IDAgJiYgRE9NLmNoaWxkTm9kZUxlbmd0aChodG1sKSA9PT0gMSkge1xuICAgICAgcmV0dXJuIGZpcnN0O1xuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gZmlyc3QgJiYgZmlyc3QucGFyZW50Tm9kZTtcbiAgICB9XG4gIH1cblxuICBpbmRleE9mKHBhcmVudCwgY2hpbGQpIHtcbiAgICByZXR1cm4gQXJyYXkuZnJvbShwYXJlbnQuY2hpbGRyZW4pLmluZGV4T2YoY2hpbGQpO1xuICB9XG5cbiAgdGVsZXBvcnQoZWwsIG1vcnBoKSB7XG4gICAgY29uc3QgdGFyZ2V0U2VsZWN0b3IgPSBlbC5nZXRBdHRyaWJ1dGUoUEhYX1BPUlRBTCk7XG4gICAgY29uc3QgcG9ydGFsQ29udGFpbmVyID0gZG9jdW1lbnQucXVlcnlTZWxlY3Rvcih0YXJnZXRTZWxlY3Rvcik7XG4gICAgaWYgKCFwb3J0YWxDb250YWluZXIpIHtcbiAgICAgIHRocm93IG5ldyBFcnJvcihcbiAgICAgICAgXCJwb3J0YWwgdGFyZ2V0IHdpdGggc2VsZWN0b3IgXCIgKyB0YXJnZXRTZWxlY3RvciArIFwiIG5vdCBmb3VuZFwiLFxuICAgICAgKTtcbiAgICB9XG4gICAgLy8gcGh4LXBvcnRhbCB0ZW1wbGF0ZXMgbXVzdCBoYXZlIGEgc2luZ2xlIHJvb3QgZWxlbWVudCwgc28gd2UgYXNzdW1lIHRoaXMgdG8gYmVcbiAgICAvLyB0aGUgY2FzZSBoZXJlXG4gICAgY29uc3QgdG9UZWxlcG9ydCA9IGVsLmNvbnRlbnQuZmlyc3RFbGVtZW50Q2hpbGQ7XG4gICAgLy8gdGhlIFBIWF9TS0lQIG9wdGltaXphdGlvbiBjYW4gYWxzbyBhcHBseSBpbnNpZGUgb2YgdGhlIDx0ZW1wbGF0ZT4gZWxlbWVudHNcbiAgICBpZiAodGhpcy5za2lwQ0lEU2libGluZyh0b1RlbGVwb3J0KSkge1xuICAgICAgcmV0dXJuO1xuICAgIH1cbiAgICBpZiAoIXRvVGVsZXBvcnQ/LmlkKSB7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoXG4gICAgICAgIFwicGh4LXBvcnRhbCB0ZW1wbGF0ZSBtdXN0IGhhdmUgYSBzaW5nbGUgcm9vdCBlbGVtZW50IHdpdGggSUQhXCIsXG4gICAgICApO1xuICAgIH1cbiAgICBjb25zdCBleGlzdGluZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKHRvVGVsZXBvcnQuaWQpO1xuICAgIGxldCBwb3J0YWxUYXJnZXQ7XG4gICAgaWYgKGV4aXN0aW5nKSB7XG4gICAgICAvLyBjaGVjayBpZiB0aGUgZWxlbWVudCBuZWVkcyB0byBiZSBtb3ZlZCB0byBhbm90aGVyIHRhcmdldFxuICAgICAgaWYgKCFwb3J0YWxDb250YWluZXIuY29udGFpbnMoZXhpc3RpbmcpKSB7XG4gICAgICAgIHBvcnRhbENvbnRhaW5lci5hcHBlbmRDaGlsZChleGlzdGluZyk7XG4gICAgICB9XG4gICAgICAvLyB3ZSBhbHJlYWR5IHRlbGVwb3J0ZWQgaW4gYSBwcmV2aW91cyBwYXRjaFxuICAgICAgcG9ydGFsVGFyZ2V0ID0gZXhpc3Rpbmc7XG4gICAgfSBlbHNlIHtcbiAgICAgIC8vIGNyZWF0ZSBlbXB0eSB0YXJnZXQgYW5kIG1vcnBoIGl0IHJlY3Vyc2l2ZWx5XG4gICAgICBwb3J0YWxUYXJnZXQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KHRvVGVsZXBvcnQudGFnTmFtZSk7XG4gICAgICBwb3J0YWxDb250YWluZXIuYXBwZW5kQ2hpbGQocG9ydGFsVGFyZ2V0KTtcbiAgICB9XG4gICAgLy8gbWFyayB0aGUgdGFyZ2V0IGFzIHRlbGVwb3J0ZWQ7XG4gICAgLy8gdG8gcHJldmVudCB1bm5lY2Vzc2FyeSBhdHRyaWJ1dGUgbW9kaWZpY2F0aW9ucywgd2Ugc2V0IHRoZSBhdHRyaWJ1dGVcbiAgICAvLyBvbiB0aGUgc291cmNlIGFuZCByZW1vdmUgaXQgYWZ0ZXIgbW9ycGhpbmcgKHdlIGNvdWxkIGFsc28ganVzdCBrZWVwIGl0KVxuICAgIC8vIG90aGVyd2lzZSBtb3JwaGRvbSB3b3VsZCByZW1vdmUgaXQsIGFzIHRoZSByZWYgaXMgbm90IHByZXNlbnQgaW4gdGhlIHNvdXJjZVxuICAgIC8vIGFuZCB3ZSdkIG5lZWQgdG8gc2V0IGl0IGJhY2sgYWZ0ZXIgZWFjaCBtb3JwaFxuICAgIHRvVGVsZXBvcnQuc2V0QXR0cmlidXRlKFBIWF9URUxFUE9SVEVEX1JFRiwgdGhpcy52aWV3LmlkKTtcbiAgICB0b1RlbGVwb3J0LnNldEF0dHJpYnV0ZShQSFhfVEVMRVBPUlRFRF9TUkMsIGVsLmlkKTtcbiAgICBtb3JwaChwb3J0YWxUYXJnZXQsIHRvVGVsZXBvcnQsIHRydWUpO1xuICAgIHRvVGVsZXBvcnQucmVtb3ZlQXR0cmlidXRlKFBIWF9URUxFUE9SVEVEX1JFRik7XG4gICAgdG9UZWxlcG9ydC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1RFTEVQT1JURURfU1JDKTtcbiAgICAvLyBzdG9yZSBhIHJlZmVyZW5jZSB0byB0aGUgdGVsZXBvcnRlZCBlbGVtZW50IGluIHRoZSB2aWV3XG4gICAgLy8gdG8gY2xlYW51cCB3aGVuIHRoZSB2aWV3IGlzIGRlc3Ryb3llZCwgaW4gY2FzZSB0aGUgcG9ydGFsIHRhcmdldFxuICAgIC8vIGlzIG91dHNpZGUgdGhlIHZpZXcgaXRzZWxmXG4gICAgdGhpcy52aWV3LnB1c2hQb3J0YWxFbGVtZW50SWQodG9UZWxlcG9ydC5pZCk7XG4gIH1cblxuICBoYW5kbGVSdW50aW1lSG9vayhlbCwgc291cmNlKSB7XG4gICAgLy8gdXN1YWxseSwgc2NyaXB0cyBhcmUgbm90IGV4ZWN1dGVkIHdoZW4gbW9ycGhkb20gYWRkcyB0aGVtIHRvIHRoZSBET01cbiAgICAvLyB3ZSBzcGVjaWFsIGNhc2UgcnVudGltZSBjb2xvY2F0ZWQgaG9va3NcbiAgICBjb25zdCBuYW1lID0gZWwuZ2V0QXR0cmlidXRlKFBIWF9SVU5USU1FX0hPT0spO1xuICAgIGxldCBub25jZSA9IGVsLmhhc0F0dHJpYnV0ZShcIm5vbmNlXCIpID8gZWwuZ2V0QXR0cmlidXRlKFwibm9uY2VcIikgOiBudWxsO1xuICAgIGlmIChlbC5oYXNBdHRyaWJ1dGUoXCJub25jZVwiKSkge1xuICAgICAgY29uc3QgdGVtcGxhdGUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwidGVtcGxhdGVcIik7XG4gICAgICB0ZW1wbGF0ZS5pbm5lckhUTUwgPSBzb3VyY2U7XG4gICAgICBub25jZSA9IHRlbXBsYXRlLmNvbnRlbnRcbiAgICAgICAgLnF1ZXJ5U2VsZWN0b3IoYHNjcmlwdFske1BIWF9SVU5USU1FX0hPT0t9PVwiJHtDU1MuZXNjYXBlKG5hbWUpfVwiXWApXG4gICAgICAgIC5nZXRBdHRyaWJ1dGUoXCJub25jZVwiKTtcbiAgICB9XG4gICAgY29uc3Qgc2NyaXB0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcInNjcmlwdFwiKTtcbiAgICBzY3JpcHQudGV4dENvbnRlbnQgPSBlbC50ZXh0Q29udGVudDtcbiAgICBET00ubWVyZ2VBdHRycyhzY3JpcHQsIGVsLCB7IGlzSWdub3JlZDogZmFsc2UgfSk7XG4gICAgaWYgKG5vbmNlKSB7XG4gICAgICBzY3JpcHQubm9uY2UgPSBub25jZTtcbiAgICB9XG4gICAgZWwucmVwbGFjZVdpdGgoc2NyaXB0KTtcbiAgICBlbCA9IHNjcmlwdDtcbiAgfVxufVxuIiwgImltcG9ydCB7XG4gIENPTVBPTkVOVFMsXG4gIFRFTVBMQVRFUyxcbiAgRVZFTlRTLFxuICBQSFhfQ09NUE9ORU5ULFxuICBQSFhfVklFV19SRUYsXG4gIFBIWF9TS0lQLFxuICBQSFhfTUFHSUNfSUQsXG4gIFJFUExZLFxuICBTVEFUSUMsXG4gIFRJVExFLFxuICBTVFJFQU0sXG4gIFJPT1QsXG4gIEtFWUVELFxuICBLRVlFRF9DT1VOVCxcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCI7XG5cbmltcG9ydCB7IGlzT2JqZWN0LCBsb2dFcnJvciwgaXNDaWQgfSBmcm9tIFwiLi91dGlsc1wiO1xuXG5jb25zdCBWT0lEX1RBR1MgPSBuZXcgU2V0KFtcbiAgXCJhcmVhXCIsXG4gIFwiYmFzZVwiLFxuICBcImJyXCIsXG4gIFwiY29sXCIsXG4gIFwiY29tbWFuZFwiLFxuICBcImVtYmVkXCIsXG4gIFwiaHJcIixcbiAgXCJpbWdcIixcbiAgXCJpbnB1dFwiLFxuICBcImtleWdlblwiLFxuICBcImxpbmtcIixcbiAgXCJtZXRhXCIsXG4gIFwicGFyYW1cIixcbiAgXCJzb3VyY2VcIixcbiAgXCJ0cmFja1wiLFxuICBcIndiclwiLFxuXSk7XG5jb25zdCBxdW90ZUNoYXJzID0gbmV3IFNldChbXCInXCIsICdcIiddKTtcblxuZXhwb3J0IGNvbnN0IG1vZGlmeVJvb3QgPSAoaHRtbCwgYXR0cnMsIGNsZWFySW5uZXJIVE1MKSA9PiB7XG4gIGxldCBpID0gMDtcbiAgbGV0IGluc2lkZUNvbW1lbnQgPSBmYWxzZTtcbiAgbGV0IGJlZm9yZVRhZywgYWZ0ZXJUYWcsIHRhZywgdGFnTmFtZUVuZHNBdCwgaWQsIG5ld0hUTUw7XG5cbiAgY29uc3QgbG9va2FoZWFkID0gaHRtbC5tYXRjaCgvXihcXHMqKD86PCEtLS4qPy0tPlxccyopKik8KFteXFxzXFwvPl0rKS8pO1xuICBpZiAobG9va2FoZWFkID09PSBudWxsKSB7XG4gICAgdGhyb3cgbmV3IEVycm9yKGBtYWxmb3JtZWQgaHRtbCAke2h0bWx9YCk7XG4gIH1cblxuICBpID0gbG9va2FoZWFkWzBdLmxlbmd0aDtcbiAgYmVmb3JlVGFnID0gbG9va2FoZWFkWzFdO1xuICB0YWcgPSBsb29rYWhlYWRbMl07XG4gIHRhZ05hbWVFbmRzQXQgPSBpO1xuXG4gIC8vIFNjYW4gdGhlIG9wZW5pbmcgdGFnIGZvciBpZCwgaWYgdGhlcmUgaXMgYW55XG4gIGZvciAoaTsgaSA8IGh0bWwubGVuZ3RoOyBpKyspIHtcbiAgICBpZiAoaHRtbC5jaGFyQXQoaSkgPT09IFwiPlwiKSB7XG4gICAgICBicmVhaztcbiAgICB9XG4gICAgaWYgKGh0bWwuY2hhckF0KGkpID09PSBcIj1cIikge1xuICAgICAgY29uc3QgaXNJZCA9IGh0bWwuc2xpY2UoaSAtIDMsIGkpID09PSBcIiBpZFwiO1xuICAgICAgaSsrO1xuICAgICAgY29uc3QgY2hhciA9IGh0bWwuY2hhckF0KGkpO1xuICAgICAgaWYgKHF1b3RlQ2hhcnMuaGFzKGNoYXIpKSB7XG4gICAgICAgIGNvbnN0IGF0dHJTdGFydHNBdCA9IGk7XG4gICAgICAgIGkrKztcbiAgICAgICAgZm9yIChpOyBpIDwgaHRtbC5sZW5ndGg7IGkrKykge1xuICAgICAgICAgIGlmIChodG1sLmNoYXJBdChpKSA9PT0gY2hhcikge1xuICAgICAgICAgICAgYnJlYWs7XG4gICAgICAgICAgfVxuICAgICAgICB9XG4gICAgICAgIGlmIChpc0lkKSB7XG4gICAgICAgICAgaWQgPSBodG1sLnNsaWNlKGF0dHJTdGFydHNBdCArIDEsIGkpO1xuICAgICAgICAgIGJyZWFrO1xuICAgICAgICB9XG4gICAgICB9XG4gICAgfVxuICB9XG5cbiAgbGV0IGNsb3NlQXQgPSBodG1sLmxlbmd0aCAtIDE7XG4gIGluc2lkZUNvbW1lbnQgPSBmYWxzZTtcbiAgd2hpbGUgKGNsb3NlQXQgPj0gYmVmb3JlVGFnLmxlbmd0aCArIHRhZy5sZW5ndGgpIHtcbiAgICBjb25zdCBjaGFyID0gaHRtbC5jaGFyQXQoY2xvc2VBdCk7XG4gICAgaWYgKGluc2lkZUNvbW1lbnQpIHtcbiAgICAgIGlmIChjaGFyID09PSBcIi1cIiAmJiBodG1sLnNsaWNlKGNsb3NlQXQgLSAzLCBjbG9zZUF0KSA9PT0gXCI8IS1cIikge1xuICAgICAgICBpbnNpZGVDb21tZW50ID0gZmFsc2U7XG4gICAgICAgIGNsb3NlQXQgLT0gNDtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIGNsb3NlQXQgLT0gMTtcbiAgICAgIH1cbiAgICB9IGVsc2UgaWYgKGNoYXIgPT09IFwiPlwiICYmIGh0bWwuc2xpY2UoY2xvc2VBdCAtIDIsIGNsb3NlQXQpID09PSBcIi0tXCIpIHtcbiAgICAgIGluc2lkZUNvbW1lbnQgPSB0cnVlO1xuICAgICAgY2xvc2VBdCAtPSAzO1xuICAgIH0gZWxzZSBpZiAoY2hhciA9PT0gXCI+XCIpIHtcbiAgICAgIGJyZWFrO1xuICAgIH0gZWxzZSB7XG4gICAgICBjbG9zZUF0IC09IDE7XG4gICAgfVxuICB9XG4gIGFmdGVyVGFnID0gaHRtbC5zbGljZShjbG9zZUF0ICsgMSwgaHRtbC5sZW5ndGgpO1xuXG4gIGNvbnN0IGF0dHJzU3RyID0gT2JqZWN0LmtleXMoYXR0cnMpXG4gICAgLm1hcCgoYXR0cikgPT4gKGF0dHJzW2F0dHJdID09PSB0cnVlID8gYXR0ciA6IGAke2F0dHJ9PVwiJHthdHRyc1thdHRyXX1cImApKVxuICAgIC5qb2luKFwiIFwiKTtcblxuICBpZiAoY2xlYXJJbm5lckhUTUwpIHtcbiAgICAvLyBLZWVwIHRoZSBpZCBpZiBhbnlcbiAgICBjb25zdCBpZEF0dHJTdHIgPSBpZCA/IGAgaWQ9XCIke2lkfVwiYCA6IFwiXCI7XG4gICAgaWYgKFZPSURfVEFHUy5oYXModGFnKSkge1xuICAgICAgbmV3SFRNTCA9IGA8JHt0YWd9JHtpZEF0dHJTdHJ9JHthdHRyc1N0ciA9PT0gXCJcIiA/IFwiXCIgOiBcIiBcIn0ke2F0dHJzU3RyfS8+YDtcbiAgICB9IGVsc2Uge1xuICAgICAgbmV3SFRNTCA9IGA8JHt0YWd9JHtpZEF0dHJTdHJ9JHthdHRyc1N0ciA9PT0gXCJcIiA/IFwiXCIgOiBcIiBcIn0ke2F0dHJzU3RyfT48LyR7dGFnfT5gO1xuICAgIH1cbiAgfSBlbHNlIHtcbiAgICBjb25zdCByZXN0ID0gaHRtbC5zbGljZSh0YWdOYW1lRW5kc0F0LCBjbG9zZUF0ICsgMSk7XG4gICAgbmV3SFRNTCA9IGA8JHt0YWd9JHthdHRyc1N0ciA9PT0gXCJcIiA/IFwiXCIgOiBcIiBcIn0ke2F0dHJzU3RyfSR7cmVzdH1gO1xuICB9XG5cbiAgcmV0dXJuIFtuZXdIVE1MLCBiZWZvcmVUYWcsIGFmdGVyVGFnXTtcbn07XG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFJlbmRlcmVkIHtcbiAgc3RhdGljIGV4dHJhY3QoZGlmZikge1xuICAgIGNvbnN0IHsgW1JFUExZXTogcmVwbHksIFtFVkVOVFNdOiBldmVudHMsIFtUSVRMRV06IHRpdGxlIH0gPSBkaWZmO1xuICAgIGRlbGV0ZSBkaWZmW1JFUExZXTtcbiAgICBkZWxldGUgZGlmZltFVkVOVFNdO1xuICAgIGRlbGV0ZSBkaWZmW1RJVExFXTtcbiAgICByZXR1cm4geyBkaWZmLCB0aXRsZSwgcmVwbHk6IHJlcGx5IHx8IG51bGwsIGV2ZW50czogZXZlbnRzIHx8IFtdIH07XG4gIH1cblxuICBjb25zdHJ1Y3Rvcih2aWV3SWQsIHJlbmRlcmVkKSB7XG4gICAgdGhpcy52aWV3SWQgPSB2aWV3SWQ7XG4gICAgdGhpcy5yZW5kZXJlZCA9IHt9O1xuICAgIHRoaXMubWFnaWNJZCA9IDA7XG4gICAgdGhpcy5tZXJnZURpZmYocmVuZGVyZWQpO1xuICB9XG5cbiAgcGFyZW50Vmlld0lkKCkge1xuICAgIHJldHVybiB0aGlzLnZpZXdJZDtcbiAgfVxuXG4gIHRvU3RyaW5nKG9ubHlDaWRzKSB7XG4gICAgY29uc3QgeyBidWZmZXI6IHN0ciwgc3RyZWFtczogc3RyZWFtcyB9ID0gdGhpcy5yZWN1cnNpdmVUb1N0cmluZyhcbiAgICAgIHRoaXMucmVuZGVyZWQsXG4gICAgICB0aGlzLnJlbmRlcmVkW0NPTVBPTkVOVFNdLFxuICAgICAgb25seUNpZHMsXG4gICAgICB0cnVlLFxuICAgICAge30sXG4gICAgKTtcbiAgICByZXR1cm4geyBidWZmZXI6IHN0ciwgc3RyZWFtczogc3RyZWFtcyB9O1xuICB9XG5cbiAgcmVjdXJzaXZlVG9TdHJpbmcoXG4gICAgcmVuZGVyZWQsXG4gICAgY29tcG9uZW50cyA9IHJlbmRlcmVkW0NPTVBPTkVOVFNdLFxuICAgIG9ubHlDaWRzLFxuICAgIGNoYW5nZVRyYWNraW5nLFxuICAgIHJvb3RBdHRycyxcbiAgKSB7XG4gICAgb25seUNpZHMgPSBvbmx5Q2lkcyA/IG5ldyBTZXQob25seUNpZHMpIDogbnVsbDtcbiAgICBjb25zdCBvdXRwdXQgPSB7XG4gICAgICBidWZmZXI6IFwiXCIsXG4gICAgICBjb21wb25lbnRzOiBjb21wb25lbnRzLFxuICAgICAgb25seUNpZHM6IG9ubHlDaWRzLFxuICAgICAgc3RyZWFtczogbmV3IFNldCgpLFxuICAgIH07XG4gICAgdGhpcy50b091dHB1dEJ1ZmZlcihyZW5kZXJlZCwgbnVsbCwgb3V0cHV0LCBjaGFuZ2VUcmFja2luZywgcm9vdEF0dHJzKTtcbiAgICByZXR1cm4geyBidWZmZXI6IG91dHB1dC5idWZmZXIsIHN0cmVhbXM6IG91dHB1dC5zdHJlYW1zIH07XG4gIH1cblxuICBjb21wb25lbnRDSURzKGRpZmYpIHtcbiAgICByZXR1cm4gT2JqZWN0LmtleXMoZGlmZltDT01QT05FTlRTXSB8fCB7fSkubWFwKChpKSA9PiBwYXJzZUludChpKSk7XG4gIH1cblxuICBpc0NvbXBvbmVudE9ubHlEaWZmKGRpZmYpIHtcbiAgICBpZiAoIWRpZmZbQ09NUE9ORU5UU10pIHtcbiAgICAgIHJldHVybiBmYWxzZTtcbiAgICB9XG4gICAgcmV0dXJuIE9iamVjdC5rZXlzKGRpZmYpLmxlbmd0aCA9PT0gMTtcbiAgfVxuXG4gIGdldENvbXBvbmVudChkaWZmLCBjaWQpIHtcbiAgICByZXR1cm4gZGlmZltDT01QT05FTlRTXVtjaWRdO1xuICB9XG5cbiAgcmVzZXRSZW5kZXIoY2lkKSB7XG4gICAgLy8gd2UgYXJlIHJhY2luZyBhIGNvbXBvbmVudCBkZXN0cm95LCBpdCBjb3VsZCBub3QgZXhpc3QsIHNvXG4gICAgLy8gbWFrZSBzdXJlIHRoYXQgd2UgZG9uJ3QgdHJ5IHRvIHNldCByZXNldCBvbiB1bmRlZmluZWRcbiAgICBpZiAodGhpcy5yZW5kZXJlZFtDT01QT05FTlRTXVtjaWRdKSB7XG4gICAgICB0aGlzLnJlbmRlcmVkW0NPTVBPTkVOVFNdW2NpZF0ucmVzZXQgPSB0cnVlO1xuICAgIH1cbiAgfVxuXG4gIG1lcmdlRGlmZihkaWZmKSB7XG4gICAgY29uc3QgbmV3YyA9IGRpZmZbQ09NUE9ORU5UU107XG4gICAgY29uc3QgY2FjaGUgPSB7fTtcbiAgICBkZWxldGUgZGlmZltDT01QT05FTlRTXTtcbiAgICB0aGlzLnJlbmRlcmVkID0gdGhpcy5tdXRhYmxlTWVyZ2UodGhpcy5yZW5kZXJlZCwgZGlmZik7XG4gICAgdGhpcy5yZW5kZXJlZFtDT01QT05FTlRTXSA9IHRoaXMucmVuZGVyZWRbQ09NUE9ORU5UU10gfHwge307XG5cbiAgICBpZiAobmV3Yykge1xuICAgICAgY29uc3Qgb2xkYyA9IHRoaXMucmVuZGVyZWRbQ09NUE9ORU5UU107XG5cbiAgICAgIGZvciAoY29uc3QgY2lkIGluIG5ld2MpIHtcbiAgICAgICAgbmV3Y1tjaWRdID0gdGhpcy5jYWNoZWRGaW5kQ29tcG9uZW50KGNpZCwgbmV3Y1tjaWRdLCBvbGRjLCBuZXdjLCBjYWNoZSk7XG4gICAgICB9XG5cbiAgICAgIGZvciAoY29uc3QgY2lkIGluIG5ld2MpIHtcbiAgICAgICAgb2xkY1tjaWRdID0gbmV3Y1tjaWRdO1xuICAgICAgfVxuICAgICAgZGlmZltDT01QT05FTlRTXSA9IG5ld2M7XG4gICAgfVxuICB9XG5cbiAgY2FjaGVkRmluZENvbXBvbmVudChjaWQsIGNkaWZmLCBvbGRjLCBuZXdjLCBjYWNoZSkge1xuICAgIGlmIChjYWNoZVtjaWRdKSB7XG4gICAgICByZXR1cm4gY2FjaGVbY2lkXTtcbiAgICB9IGVsc2Uge1xuICAgICAgbGV0IG5kaWZmLFxuICAgICAgICBzdGF0LFxuICAgICAgICBzY2lkID0gY2RpZmZbU1RBVElDXTtcblxuICAgICAgaWYgKGlzQ2lkKHNjaWQpKSB7XG4gICAgICAgIGxldCB0ZGlmZjtcblxuICAgICAgICBpZiAoc2NpZCA+IDApIHtcbiAgICAgICAgICB0ZGlmZiA9IHRoaXMuY2FjaGVkRmluZENvbXBvbmVudChzY2lkLCBuZXdjW3NjaWRdLCBvbGRjLCBuZXdjLCBjYWNoZSk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgdGRpZmYgPSBvbGRjWy1zY2lkXTtcbiAgICAgICAgfVxuXG4gICAgICAgIHN0YXQgPSB0ZGlmZltTVEFUSUNdO1xuICAgICAgICBuZGlmZiA9IHRoaXMuY2xvbmVNZXJnZSh0ZGlmZiwgY2RpZmYsIHRydWUpO1xuICAgICAgICBuZGlmZltTVEFUSUNdID0gc3RhdDtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIG5kaWZmID1cbiAgICAgICAgICBjZGlmZltTVEFUSUNdICE9PSB1bmRlZmluZWQgfHwgb2xkY1tjaWRdID09PSB1bmRlZmluZWRcbiAgICAgICAgICAgID8gY2RpZmZcbiAgICAgICAgICAgIDogdGhpcy5jbG9uZU1lcmdlKG9sZGNbY2lkXSwgY2RpZmYsIGZhbHNlKTtcbiAgICAgIH1cblxuICAgICAgY2FjaGVbY2lkXSA9IG5kaWZmO1xuICAgICAgcmV0dXJuIG5kaWZmO1xuICAgIH1cbiAgfVxuXG4gIG11dGFibGVNZXJnZSh0YXJnZXQsIHNvdXJjZSkge1xuICAgIGlmIChzb3VyY2VbU1RBVElDXSAhPT0gdW5kZWZpbmVkKSB7XG4gICAgICByZXR1cm4gc291cmNlO1xuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLmRvTXV0YWJsZU1lcmdlKHRhcmdldCwgc291cmNlKTtcbiAgICAgIHJldHVybiB0YXJnZXQ7XG4gICAgfVxuICB9XG5cbiAgZG9NdXRhYmxlTWVyZ2UodGFyZ2V0LCBzb3VyY2UpIHtcbiAgICBpZiAoc291cmNlW0tFWUVEXSkge1xuICAgICAgdGhpcy5tZXJnZUtleWVkKHRhcmdldCwgc291cmNlKTtcbiAgICB9IGVsc2Uge1xuICAgICAgZm9yIChjb25zdCBrZXkgaW4gc291cmNlKSB7XG4gICAgICAgIGNvbnN0IHZhbCA9IHNvdXJjZVtrZXldO1xuICAgICAgICBjb25zdCB0YXJnZXRWYWwgPSB0YXJnZXRba2V5XTtcbiAgICAgICAgY29uc3QgaXNPYmpWYWwgPSBpc09iamVjdCh2YWwpO1xuICAgICAgICBpZiAoaXNPYmpWYWwgJiYgdmFsW1NUQVRJQ10gPT09IHVuZGVmaW5lZCAmJiBpc09iamVjdCh0YXJnZXRWYWwpKSB7XG4gICAgICAgICAgdGhpcy5kb011dGFibGVNZXJnZSh0YXJnZXRWYWwsIHZhbCk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgdGFyZ2V0W2tleV0gPSB2YWw7XG4gICAgICAgIH1cbiAgICAgIH1cbiAgICB9XG4gICAgaWYgKHRhcmdldFtST09UXSkge1xuICAgICAgdGFyZ2V0Lm5ld1JlbmRlciA9IHRydWU7XG4gICAgfVxuICB9XG5cbiAgY2xvbmUoZGlmZikge1xuICAgIGlmIChcInN0cnVjdHVyZWRDbG9uZVwiIGluIHdpbmRvdykge1xuICAgICAgcmV0dXJuIHN0cnVjdHVyZWRDbG9uZShkaWZmKTtcbiAgICB9IGVsc2Uge1xuICAgICAgLy8gZmFsbGJhY2sgZm9yIGplc3RcbiAgICAgIHJldHVybiBKU09OLnBhcnNlKEpTT04uc3RyaW5naWZ5KGRpZmYpKTtcbiAgICB9XG4gIH1cblxuICAvLyBrZXllZCBjb21wcmVoZW5zaW9uc1xuICBtZXJnZUtleWVkKHRhcmdldCwgc291cmNlKSB7XG4gICAgLy8gd2UgbmVlZCB0byBjbG9uZSB0aGUgdGFyZ2V0IHNpbmNlIGVsZW1lbnRzIGNhbiBtb3ZlIGFuZCBvdGhlcndpc2VcbiAgICAvLyBpdCBjb3VsZCBoYXBwZW4gdGhhdCB3ZSBtb2RpZnkgYW4gZWxlbWVudCB0aGF0IHdlJ2xsIG5lZWQgdG8gcmVmZXIgdG9cbiAgICAvLyBsYXRlclxuICAgIGNvbnN0IGNsb25lZFRhcmdldCA9IHRoaXMuY2xvbmUodGFyZ2V0KTtcbiAgICBPYmplY3QuZW50cmllcyhzb3VyY2VbS0VZRURdKS5mb3JFYWNoKChbaSwgZW50cnldKSA9PiB7XG4gICAgICBpZiAoaSA9PT0gS0VZRURfQ09VTlQpIHtcbiAgICAgICAgcmV0dXJuO1xuICAgICAgfVxuICAgICAgaWYgKEFycmF5LmlzQXJyYXkoZW50cnkpKSB7XG4gICAgICAgIC8vIFtvbGRfaWR4LCBkaWZmXVxuICAgICAgICAvLyBtb3ZlZCB3aXRoIGRpZmZcbiAgICAgICAgY29uc3QgW29sZF9pZHgsIGRpZmZdID0gZW50cnk7XG4gICAgICAgIHRhcmdldFtLRVlFRF1baV0gPSBjbG9uZWRUYXJnZXRbS0VZRURdW29sZF9pZHhdO1xuICAgICAgICB0aGlzLmRvTXV0YWJsZU1lcmdlKHRhcmdldFtLRVlFRF1baV0sIGRpZmYpO1xuICAgICAgfSBlbHNlIGlmICh0eXBlb2YgZW50cnkgPT09IFwibnVtYmVyXCIpIHtcbiAgICAgICAgLy8gbW92ZWQgd2l0aG91dCBkaWZmXG4gICAgICAgIGNvbnN0IG9sZF9pZHggPSBlbnRyeTtcbiAgICAgICAgdGFyZ2V0W0tFWUVEXVtpXSA9IGNsb25lZFRhcmdldFtLRVlFRF1bb2xkX2lkeF07XG4gICAgICB9IGVsc2UgaWYgKHR5cGVvZiBlbnRyeSA9PT0gXCJvYmplY3RcIikge1xuICAgICAgICAvLyBkaWZmLCBzYW1lIHBvc2l0aW9uXG4gICAgICAgIGlmICghdGFyZ2V0W0tFWUVEXVtpXSkge1xuICAgICAgICAgIHRhcmdldFtLRVlFRF1baV0gPSB7fTtcbiAgICAgICAgfVxuICAgICAgICB0aGlzLmRvTXV0YWJsZU1lcmdlKHRhcmdldFtLRVlFRF1baV0sIGVudHJ5KTtcbiAgICAgIH1cbiAgICB9KTtcbiAgICAvLyBkcm9wIGV4dHJhIGVudHJpZXNcbiAgICBpZiAoc291cmNlW0tFWUVEXVtLRVlFRF9DT1VOVF0gPCB0YXJnZXRbS0VZRURdW0tFWUVEX0NPVU5UXSkge1xuICAgICAgZm9yIChcbiAgICAgICAgbGV0IGkgPSBzb3VyY2VbS0VZRURdW0tFWUVEX0NPVU5UXTtcbiAgICAgICAgaSA8IHRhcmdldFtLRVlFRF1bS0VZRURfQ09VTlRdO1xuICAgICAgICBpKytcbiAgICAgICkge1xuICAgICAgICBkZWxldGUgdGFyZ2V0W0tFWUVEXVtpXTtcbiAgICAgIH1cbiAgICB9XG4gICAgdGFyZ2V0W0tFWUVEXVtLRVlFRF9DT1VOVF0gPSBzb3VyY2VbS0VZRURdW0tFWUVEX0NPVU5UXTtcbiAgICBpZiAoc291cmNlW1NUUkVBTV0pIHtcbiAgICAgIHRhcmdldFtTVFJFQU1dID0gc291cmNlW1NUUkVBTV07XG4gICAgfVxuICAgIGlmIChzb3VyY2VbVEVNUExBVEVTXSkge1xuICAgICAgdGFyZ2V0W1RFTVBMQVRFU10gPSBzb3VyY2VbVEVNUExBVEVTXTtcbiAgICB9XG4gIH1cblxuICAvLyBNZXJnZXMgY2lkIHRyZWVzIHRvZ2V0aGVyLCBjb3B5aW5nIHN0YXRpY3MgZnJvbSBzb3VyY2UgdHJlZS5cbiAgLy9cbiAgLy8gVGhlIGBwcnVuZU1hZ2ljSWRgIGlzIHBhc3NlZCB0byBjb250cm9sIHBydW5pbmcgdGhlIG1hZ2ljSWQgb2YgdGhlXG4gIC8vIHRhcmdldC4gV2UgbXVzdCBhbHdheXMgcHJ1bmUgdGhlIG1hZ2ljSWQgd2hlbiB3ZSBhcmUgc2hhcmluZyBzdGF0aWNzXG4gIC8vIGZyb20gYW5vdGhlciBjb21wb25lbnQuIElmIG5vdCBwcnVuaW5nLCB3ZSByZXBsaWNhdGUgdGhlIGxvZ2ljIGZyb21cbiAgLy8gbXV0YWJsZU1lcmdlLCB3aGVyZSB3ZSBzZXQgbmV3UmVuZGVyIHRvIHRydWUgaWYgdGhlcmUgaXMgYSByb290XG4gIC8vIChlZmZlY3RpdmVseSBmb3JjaW5nIHRoZSBuZXcgdmVyc2lvbiB0byBiZSByZW5kZXJlZCBpbnN0ZWFkIG9mIHNraXBwZWQpXG4gIC8vXG4gIGNsb25lTWVyZ2UodGFyZ2V0LCBzb3VyY2UsIHBydW5lTWFnaWNJZCkge1xuICAgIGNvbnN0IG1lcmdlZCA9IHsgLi4udGFyZ2V0LCAuLi5zb3VyY2UgfTtcbiAgICBmb3IgKGNvbnN0IGtleSBpbiBtZXJnZWQpIHtcbiAgICAgIGNvbnN0IHZhbCA9IHNvdXJjZVtrZXldO1xuICAgICAgY29uc3QgdGFyZ2V0VmFsID0gdGFyZ2V0W2tleV07XG4gICAgICBpZiAoaXNPYmplY3QodmFsKSAmJiB2YWxbU1RBVElDXSA9PT0gdW5kZWZpbmVkICYmIGlzT2JqZWN0KHRhcmdldFZhbCkpIHtcbiAgICAgICAgbWVyZ2VkW2tleV0gPSB0aGlzLmNsb25lTWVyZ2UodGFyZ2V0VmFsLCB2YWwsIHBydW5lTWFnaWNJZCk7XG4gICAgICB9IGVsc2UgaWYgKHZhbCA9PT0gdW5kZWZpbmVkICYmIGlzT2JqZWN0KHRhcmdldFZhbCkpIHtcbiAgICAgICAgbWVyZ2VkW2tleV0gPSB0aGlzLmNsb25lTWVyZ2UodGFyZ2V0VmFsLCB7fSwgcHJ1bmVNYWdpY0lkKTtcbiAgICAgIH1cbiAgICB9XG4gICAgaWYgKHBydW5lTWFnaWNJZCkge1xuICAgICAgZGVsZXRlIG1lcmdlZC5tYWdpY0lkO1xuICAgICAgZGVsZXRlIG1lcmdlZC5uZXdSZW5kZXI7XG4gICAgfSBlbHNlIGlmICh0YXJnZXRbUk9PVF0pIHtcbiAgICAgIG1lcmdlZC5uZXdSZW5kZXIgPSB0cnVlO1xuICAgIH1cbiAgICByZXR1cm4gbWVyZ2VkO1xuICB9XG5cbiAgY29tcG9uZW50VG9TdHJpbmcoY2lkKSB7XG4gICAgY29uc3QgeyBidWZmZXI6IHN0ciwgc3RyZWFtcyB9ID0gdGhpcy5yZWN1cnNpdmVDSURUb1N0cmluZyhcbiAgICAgIHRoaXMucmVuZGVyZWRbQ09NUE9ORU5UU10sXG4gICAgICBjaWQsXG4gICAgICBudWxsLFxuICAgICk7XG4gICAgY29uc3QgW3N0cmlwcGVkSFRNTCwgX2JlZm9yZSwgX2FmdGVyXSA9IG1vZGlmeVJvb3Qoc3RyLCB7fSk7XG4gICAgcmV0dXJuIHsgYnVmZmVyOiBzdHJpcHBlZEhUTUwsIHN0cmVhbXM6IHN0cmVhbXMgfTtcbiAgfVxuXG4gIHBydW5lQ0lEcyhjaWRzKSB7XG4gICAgY2lkcy5mb3JFYWNoKChjaWQpID0+IGRlbGV0ZSB0aGlzLnJlbmRlcmVkW0NPTVBPTkVOVFNdW2NpZF0pO1xuICB9XG5cbiAgLy8gcHJpdmF0ZVxuXG4gIGdldCgpIHtcbiAgICByZXR1cm4gdGhpcy5yZW5kZXJlZDtcbiAgfVxuXG4gIGlzTmV3RmluZ2VycHJpbnQoZGlmZiA9IHt9KSB7XG4gICAgcmV0dXJuICEhZGlmZltTVEFUSUNdO1xuICB9XG5cbiAgdGVtcGxhdGVTdGF0aWMocGFydCwgdGVtcGxhdGVzKSB7XG4gICAgaWYgKHR5cGVvZiBwYXJ0ID09PSBcIm51bWJlclwiKSB7XG4gICAgICByZXR1cm4gdGVtcGxhdGVzW3BhcnRdO1xuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gcGFydDtcbiAgICB9XG4gIH1cblxuICBuZXh0TWFnaWNJRCgpIHtcbiAgICB0aGlzLm1hZ2ljSWQrKztcbiAgICByZXR1cm4gYG0ke3RoaXMubWFnaWNJZH0tJHt0aGlzLnBhcmVudFZpZXdJZCgpfWA7XG4gIH1cblxuICAvLyBDb252ZXJ0cyByZW5kZXJlZCB0cmVlIHRvIG91dHB1dCBidWZmZXIuXG4gIC8vXG4gIC8vIGNoYW5nZVRyYWNraW5nIGNvbnRyb2xzIGlmIHdlIGNhbiBhcHBseSB0aGUgUEhYX1NLSVAgb3B0aW1pemF0aW9uLlxuICB0b091dHB1dEJ1ZmZlcihyZW5kZXJlZCwgdGVtcGxhdGVzLCBvdXRwdXQsIGNoYW5nZVRyYWNraW5nLCByb290QXR0cnMgPSB7fSkge1xuICAgIGlmIChyZW5kZXJlZFtLRVlFRF0pIHtcbiAgICAgIHJldHVybiB0aGlzLmNvbXByZWhlbnNpb25Ub0J1ZmZlcihcbiAgICAgICAgcmVuZGVyZWQsXG4gICAgICAgIHRlbXBsYXRlcyxcbiAgICAgICAgb3V0cHV0LFxuICAgICAgICBjaGFuZ2VUcmFja2luZyxcbiAgICAgICk7XG4gICAgfVxuXG4gICAgLy8gVGVtcGxhdGVzIGFyZSBhIHdheSBvZiBzaGFyaW5nIHN0YXRpY3MgYmV0d2VlbiBtdWx0aXBsZSByZW5kZXJlZCBzdHJ1Y3RzLlxuICAgIC8vIFNpbmNlIExpdmVWaWV3IDEuMSwgdGhvc2UgY2FuIGFsc28gYXBwZWFyIGF0IHRoZSByb290IC0gZm9yIGV4YW1wbGUgaWYgb25lIHJlbmRlcnNcbiAgICAvLyB0d28gY29tcHJlaGVuc2lvbnMgdGhhdCBjYW4gc2hhcmUgc3RhdGljcy5cbiAgICAvLyBXaGVuZXZlciB3ZSBmaW5kIHRlbXBsYXRlcywgd2UgbmVlZCB0byB1c2UgdGhlbSByZWN1cnNpdmVseS4gQWxzbywgdGVtcGxhdGVzIGNhblxuICAgIC8vIGJlIHNlbnQgZm9yIGVhY2ggZGlmZiwgbm90IG9ubHkgZm9yIHRoZSBpbml0aWFsIG9uZS4gV2UgZG9uJ3Qgd2FudCB0byBtZXJnZSB0aGVtXG4gICAgLy8gdGhvdWdoLCBzbyB3ZSBhbHdheXMgcmVzb2x2ZSB0aGVtIGFuZCByZW1vdmUgdGhlbSBmcm9tIHRoZSByZW5kZXJlZCBvYmplY3QuXG4gICAgaWYgKHJlbmRlcmVkW1RFTVBMQVRFU10pIHtcbiAgICAgIHRlbXBsYXRlcyA9IHJlbmRlcmVkW1RFTVBMQVRFU107XG4gICAgICBkZWxldGUgcmVuZGVyZWRbVEVNUExBVEVTXTtcbiAgICB9XG5cbiAgICBsZXQgeyBbU1RBVElDXTogc3RhdGljcyB9ID0gcmVuZGVyZWQ7XG4gICAgc3RhdGljcyA9IHRoaXMudGVtcGxhdGVTdGF0aWMoc3RhdGljcywgdGVtcGxhdGVzKTtcbiAgICByZW5kZXJlZFtTVEFUSUNdID0gc3RhdGljcztcbiAgICBjb25zdCBpc1Jvb3QgPSByZW5kZXJlZFtST09UXTtcbiAgICBjb25zdCBwcmV2QnVmZmVyID0gb3V0cHV0LmJ1ZmZlcjtcbiAgICBpZiAoaXNSb290KSB7XG4gICAgICBvdXRwdXQuYnVmZmVyID0gXCJcIjtcbiAgICB9XG5cbiAgICAvLyB0aGlzIGNvbmRpdGlvbiBpcyBjYWxsZWQgd2hlbiBmaXJzdCByZW5kZXJpbmcgYW4gb3B0aW1pemFibGUgZnVuY3Rpb24gY29tcG9uZW50LlxuICAgIC8vIExDIGhhdmUgdGhlaXIgbWFnaWNJZCBwcmV2aW91c2x5IHNldFxuICAgIGlmIChjaGFuZ2VUcmFja2luZyAmJiBpc1Jvb3QgJiYgIXJlbmRlcmVkLm1hZ2ljSWQpIHtcbiAgICAgIHJlbmRlcmVkLm5ld1JlbmRlciA9IHRydWU7XG4gICAgICByZW5kZXJlZC5tYWdpY0lkID0gdGhpcy5uZXh0TWFnaWNJRCgpO1xuICAgIH1cblxuICAgIG91dHB1dC5idWZmZXIgKz0gc3RhdGljc1swXTtcbiAgICBmb3IgKGxldCBpID0gMTsgaSA8IHN0YXRpY3MubGVuZ3RoOyBpKyspIHtcbiAgICAgIHRoaXMuZHluYW1pY1RvQnVmZmVyKHJlbmRlcmVkW2kgLSAxXSwgdGVtcGxhdGVzLCBvdXRwdXQsIGNoYW5nZVRyYWNraW5nKTtcbiAgICAgIG91dHB1dC5idWZmZXIgKz0gc3RhdGljc1tpXTtcbiAgICB9XG5cbiAgICAvLyBBcHBsaWVzIHRoZSByb290IHRhZyBcInNraXBcIiBvcHRpbWl6YXRpb24gaWYgc3VwcG9ydGVkLCB3aGljaCBjbGVhcnNcbiAgICAvLyB0aGUgcm9vdCB0YWcgYXR0cmlidXRlcyBhbmQgaW5uZXJIVE1MLCBhbmQgb25seSBtYWludGFpbnMgdGhlIG1hZ2ljSWQuXG4gICAgLy8gV2UgY2FuIG9ubHkgc2tpcCB3aGVuIGNoYW5nZVRyYWNraW5nIGlzIHN1cHBvcnRlZCxcbiAgICAvLyBhbmQgd2hlbiB0aGUgcm9vdCBlbGVtZW50IGhhc24ndCBleHBlcmllbmNlZCBhbiB1bnJlbmRlcmVkIG1lcmdlIChuZXdSZW5kZXIgdHJ1ZSkuXG4gICAgaWYgKGlzUm9vdCkge1xuICAgICAgbGV0IHNraXAgPSBmYWxzZTtcbiAgICAgIGxldCBhdHRycztcbiAgICAgIC8vIFdoZW4gYSBMQyBpcyByZS1hZGRlZCB0byB0aGUgcGFnZSwgd2UgbmVlZCB0byByZS1yZW5kZXIgdGhlIGVudGlyZSBMQyB0cmVlLFxuICAgICAgLy8gdGhlcmVmb3JlIGNoYW5nZVRyYWNraW5nIGlzIGZhbHNlOyBob3dldmVyLCB3ZSBuZWVkIHRvIGtlZXAgYWxsIHRoZSBtYWdpY0lkc1xuICAgICAgLy8gZnJvbSBhbnkgZnVuY3Rpb24gY29tcG9uZW50IHNvIHRoZSBuZXh0IHRpbWUgdGhlIExDIGlzIHVwZGF0ZWQsIHdlIGNhbiBhcHBseVxuICAgICAgLy8gdGhlIHNraXAgb3B0aW1pemF0aW9uXG4gICAgICBpZiAoY2hhbmdlVHJhY2tpbmcgfHwgcmVuZGVyZWQubWFnaWNJZCkge1xuICAgICAgICBza2lwID0gY2hhbmdlVHJhY2tpbmcgJiYgIXJlbmRlcmVkLm5ld1JlbmRlcjtcbiAgICAgICAgYXR0cnMgPSB7IFtQSFhfTUFHSUNfSURdOiByZW5kZXJlZC5tYWdpY0lkLCAuLi5yb290QXR0cnMgfTtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIGF0dHJzID0gcm9vdEF0dHJzO1xuICAgICAgfVxuICAgICAgaWYgKHNraXApIHtcbiAgICAgICAgYXR0cnNbUEhYX1NLSVBdID0gdHJ1ZTtcbiAgICAgIH1cbiAgICAgIGNvbnN0IFtuZXdSb290LCBjb21tZW50QmVmb3JlLCBjb21tZW50QWZ0ZXJdID0gbW9kaWZ5Um9vdChcbiAgICAgICAgb3V0cHV0LmJ1ZmZlcixcbiAgICAgICAgYXR0cnMsXG4gICAgICAgIHNraXAsXG4gICAgICApO1xuICAgICAgcmVuZGVyZWQubmV3UmVuZGVyID0gZmFsc2U7XG4gICAgICBvdXRwdXQuYnVmZmVyID0gcHJldkJ1ZmZlciArIGNvbW1lbnRCZWZvcmUgKyBuZXdSb290ICsgY29tbWVudEFmdGVyO1xuICAgIH1cbiAgfVxuXG4gIGNvbXByZWhlbnNpb25Ub0J1ZmZlcihyZW5kZXJlZCwgdGVtcGxhdGVzLCBvdXRwdXQsIGNoYW5nZVRyYWNraW5nKSB7XG4gICAgY29uc3Qga2V5ZWRUZW1wbGF0ZXMgPSB0ZW1wbGF0ZXMgfHwgcmVuZGVyZWRbVEVNUExBVEVTXTtcbiAgICBjb25zdCBzdGF0aWNzID0gdGhpcy50ZW1wbGF0ZVN0YXRpYyhyZW5kZXJlZFtTVEFUSUNdLCB0ZW1wbGF0ZXMpO1xuICAgIHJlbmRlcmVkW1NUQVRJQ10gPSBzdGF0aWNzO1xuICAgIGRlbGV0ZSByZW5kZXJlZFtURU1QTEFURVNdO1xuICAgIGZvciAobGV0IGkgPSAwOyBpIDwgcmVuZGVyZWRbS0VZRURdW0tFWUVEX0NPVU5UXTsgaSsrKSB7XG4gICAgICBvdXRwdXQuYnVmZmVyICs9IHN0YXRpY3NbMF07XG4gICAgICBmb3IgKGxldCBqID0gMTsgaiA8IHN0YXRpY3MubGVuZ3RoOyBqKyspIHtcbiAgICAgICAgdGhpcy5keW5hbWljVG9CdWZmZXIoXG4gICAgICAgICAgcmVuZGVyZWRbS0VZRURdW2ldW2ogLSAxXSxcbiAgICAgICAgICBrZXllZFRlbXBsYXRlcyxcbiAgICAgICAgICBvdXRwdXQsXG4gICAgICAgICAgY2hhbmdlVHJhY2tpbmcsXG4gICAgICAgICk7XG4gICAgICAgIG91dHB1dC5idWZmZXIgKz0gc3RhdGljc1tqXTtcbiAgICAgIH1cbiAgICB9XG4gICAgLy8gd2UgZG9uJ3QgbmVlZCB0byBzdG9yZSB0aGUgcmVuZGVyZWQgdHJlZSBmb3Igc3RyZWFtc1xuICAgIGlmIChyZW5kZXJlZFtTVFJFQU1dKSB7XG4gICAgICBjb25zdCBzdHJlYW0gPSByZW5kZXJlZFtTVFJFQU1dO1xuICAgICAgY29uc3QgW19yZWYsIF9pbnNlcnRzLCBkZWxldGVJZHMsIHJlc2V0XSA9IHN0cmVhbSB8fCBbbnVsbCwge30sIFtdLCBudWxsXTtcbiAgICAgIGlmIChcbiAgICAgICAgc3RyZWFtICE9PSB1bmRlZmluZWQgJiZcbiAgICAgICAgKHJlbmRlcmVkW0tFWUVEXVtLRVlFRF9DT1VOVF0gPiAwIHx8IGRlbGV0ZUlkcy5sZW5ndGggPiAwIHx8IHJlc2V0KVxuICAgICAgKSB7XG4gICAgICAgIGRlbGV0ZSByZW5kZXJlZFtTVFJFQU1dO1xuICAgICAgICByZW5kZXJlZFtLRVlFRF0gPSB7XG4gICAgICAgICAgW0tFWUVEX0NPVU5UXTogMCxcbiAgICAgICAgfTtcbiAgICAgICAgb3V0cHV0LnN0cmVhbXMuYWRkKHN0cmVhbSk7XG4gICAgICB9XG4gICAgfVxuICB9XG5cbiAgZHluYW1pY1RvQnVmZmVyKHJlbmRlcmVkLCB0ZW1wbGF0ZXMsIG91dHB1dCwgY2hhbmdlVHJhY2tpbmcpIHtcbiAgICBpZiAodHlwZW9mIHJlbmRlcmVkID09PSBcIm51bWJlclwiKSB7XG4gICAgICBjb25zdCB7IGJ1ZmZlcjogc3RyLCBzdHJlYW1zIH0gPSB0aGlzLnJlY3Vyc2l2ZUNJRFRvU3RyaW5nKFxuICAgICAgICBvdXRwdXQuY29tcG9uZW50cyxcbiAgICAgICAgcmVuZGVyZWQsXG4gICAgICAgIG91dHB1dC5vbmx5Q2lkcyxcbiAgICAgICk7XG4gICAgICBvdXRwdXQuYnVmZmVyICs9IHN0cjtcbiAgICAgIG91dHB1dC5zdHJlYW1zID0gbmV3IFNldChbLi4ub3V0cHV0LnN0cmVhbXMsIC4uLnN0cmVhbXNdKTtcbiAgICB9IGVsc2UgaWYgKGlzT2JqZWN0KHJlbmRlcmVkKSkge1xuICAgICAgdGhpcy50b091dHB1dEJ1ZmZlcihyZW5kZXJlZCwgdGVtcGxhdGVzLCBvdXRwdXQsIGNoYW5nZVRyYWNraW5nLCB7fSk7XG4gICAgfSBlbHNlIHtcbiAgICAgIG91dHB1dC5idWZmZXIgKz0gcmVuZGVyZWQ7XG4gICAgfVxuICB9XG5cbiAgcmVjdXJzaXZlQ0lEVG9TdHJpbmcoY29tcG9uZW50cywgY2lkLCBvbmx5Q2lkcykge1xuICAgIGNvbnN0IGNvbXBvbmVudCA9XG4gICAgICBjb21wb25lbnRzW2NpZF0gfHwgbG9nRXJyb3IoYG5vIGNvbXBvbmVudCBmb3IgQ0lEICR7Y2lkfWAsIGNvbXBvbmVudHMpO1xuICAgIGNvbnN0IGF0dHJzID0geyBbUEhYX0NPTVBPTkVOVF06IGNpZCwgW1BIWF9WSUVXX1JFRl06IHRoaXMudmlld0lkIH07XG4gICAgY29uc3Qgc2tpcCA9IG9ubHlDaWRzICYmICFvbmx5Q2lkcy5oYXMoY2lkKTtcbiAgICAvLyBUd28gb3B0aW1pemF0aW9uIHBhdGhzIGFwcGx5IGhlcmU6XG4gICAgLy9cbiAgICAvLyAgIDEuIFRoZSBvbmx5Q2lkcyBvcHRpbWl6YXRpb24gd29ya3MgYnkgdGhlIHNlcnZlciBkaWZmIHRlbGxpbmcgdXMgb25seSBzcGVjaWZpY1xuICAgIC8vICAgICBjaWQncyBoYXZlIGNoYW5nZWQuIFRoaXMgYWxsb3dzIHVzIHRvIHNraXAgcmVuZGVyaW5nIGFueSBjb21wb25lbnQgdGhhdCBoYXNuJ3QgY2hhbmdlZCxcbiAgICAvLyAgICAgd2hpY2ggdWx0aW1hdGVseSBzZXRzIFBIWF9TS0lQIHJvb3QgYXR0cmlidXRlIGFuZCBhdm9pZHMgcmVuZGVyaW5nIHRoZSBpbm5lckhUTUwuXG4gICAgLy9cbiAgICAvLyAgIDIuIFRoZSByb290IFBIWF9TS0lQIG9wdGltaXphdGlvbiBnZW5lcmFsaXplcyB0byBhbGwgSEVFeCBmdW5jdGlvbiBjb21wb25lbnRzLCBhbmRcbiAgICAvLyAgICAgd29ya3MgaW4gdGhlIHNhbWUgUEhYX1NLSVAgYXR0cmlidXRlIGZhc2hpb24gYXMgMSwgYnV0IHRoZSBuZXdSZW5kZXIgdHJhY2tpbmcgaXMgZG9uZVxuICAgIC8vICAgICBhdCB0aGUgZ2VuZXJhbCBkaWZmIG1lcmdlIGxldmVsLiBJZiB3ZSBtZXJnZSBhIGRpZmYgd2l0aCBuZXcgZHluYW1pY3MsIHdlIG5lY2Vzc2FyaWx5IGhhdmVcbiAgICAvLyAgICAgZXhwZXJpZW5jZWQgYSBjaGFuZ2Ugd2hpY2ggbXVzdCBiZSBhIG5ld1JlbmRlciwgYW5kIHRodXMgd2UgY2FuJ3Qgc2tpcCB0aGUgcmVuZGVyLlxuICAgIC8vXG4gICAgLy8gQm90aCBvcHRpbWl6YXRpb24gZmxvd3MgYXBwbHkgaGVyZS4gbmV3UmVuZGVyIGlzIHNldCBiYXNlZCBvbiB0aGUgb25seUNpZHMgb3B0aW1pemF0aW9uLCBhbmRcbiAgICAvLyB3ZSB0cmFjayBhIGRldGVybWluaXN0aWMgbWFnaWNJZCBiYXNlZCBvbiB0aGUgY2lkLlxuICAgIC8vXG4gICAgLy8gY2hhbmdlVHJhY2tpbmcgaXMgYWJvdXQgdGhlIGVudGlyZSB0cmVlXG4gICAgLy8gbmV3UmVuZGVyIGlzIGFib3V0IHRoZSBjdXJyZW50IHJvb3QgaW4gdGhlIHRyZWVcbiAgICAvL1xuICAgIC8vIEJ5IGRlZmF1bHQgY2hhbmdlVHJhY2tpbmcgaXMgZW5hYmxlZCwgYnV0IHdlIHNwZWNpYWwgY2FzZSB0aGUgZmxvdyB3aGVyZSB0aGUgY2xpZW50IGlzIHBydW5pbmdcbiAgICAvLyBjaWRzIGFuZCB0aGUgc2VydmVyIGFkZHMgdGhlIGNvbXBvbmVudCBiYWNrLiBJbiBzdWNoIGNhc2VzLCB3ZSBleHBsaWNpdGx5IGRpc2FibGUgY2hhbmdlVHJhY2tpbmdcbiAgICAvLyB3aXRoIHJlc2V0UmVuZGVyIGZvciB0aGlzIGNpZCwgdGhlbiByZS1lbmFibGUgaXQgYWZ0ZXIgdGhlIHJlY3Vyc2l2ZSBjYWxsIHRvIHNraXAgdGhlIG9wdGltaXphdGlvblxuICAgIC8vIGZvciB0aGUgZW50aXJlIGNvbXBvbmVudCB0cmVlLlxuICAgIGNvbXBvbmVudC5uZXdSZW5kZXIgPSAhc2tpcDtcbiAgICBjb21wb25lbnQubWFnaWNJZCA9IGBjJHtjaWR9LSR7dGhpcy5wYXJlbnRWaWV3SWQoKX1gO1xuICAgIC8vIGVuYWJsZSBjaGFuZ2UgdHJhY2tpbmcgYXMgbG9uZyBhcyB0aGUgY29tcG9uZW50IGhhc24ndCBiZWVuIHJlc2V0XG4gICAgY29uc3QgY2hhbmdlVHJhY2tpbmcgPSAhY29tcG9uZW50LnJlc2V0O1xuICAgIGNvbnN0IHsgYnVmZmVyOiBodG1sLCBzdHJlYW1zIH0gPSB0aGlzLnJlY3Vyc2l2ZVRvU3RyaW5nKFxuICAgICAgY29tcG9uZW50LFxuICAgICAgY29tcG9uZW50cyxcbiAgICAgIG9ubHlDaWRzLFxuICAgICAgY2hhbmdlVHJhY2tpbmcsXG4gICAgICBhdHRycyxcbiAgICApO1xuICAgIC8vIGRpc2FibGUgcmVzZXQgYWZ0ZXIgd2UndmUgcmVuZGVyZWRcbiAgICBkZWxldGUgY29tcG9uZW50LnJlc2V0O1xuXG4gICAgcmV0dXJuIHsgYnVmZmVyOiBodG1sLCBzdHJlYW1zOiBzdHJlYW1zIH07XG4gIH1cbn1cbiIsICJpbXBvcnQgRE9NIGZyb20gXCIuL2RvbVwiO1xuaW1wb3J0IEFSSUEgZnJvbSBcIi4vYXJpYVwiO1xuXG5jb25zdCBmb2N1c1N0YWNrID0gW107XG5jb25zdCBkZWZhdWx0X3RyYW5zaXRpb25fdGltZSA9IDIwMDtcblxuY29uc3QgSlMgPSB7XG4gIC8vIHByaXZhdGVcbiAgZXhlYyhlLCBldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZGVmYXVsdHMpIHtcbiAgICBjb25zdCBbZGVmYXVsdEtpbmQsIGRlZmF1bHRBcmdzXSA9IGRlZmF1bHRzIHx8IFtcbiAgICAgIG51bGwsXG4gICAgICB7IGNhbGxiYWNrOiBkZWZhdWx0cyAmJiBkZWZhdWx0cy5jYWxsYmFjayB9LFxuICAgIF07XG4gICAgY29uc3QgY29tbWFuZHMgPVxuICAgICAgcGh4RXZlbnQuY2hhckF0KDApID09PSBcIltcIlxuICAgICAgICA/IEpTT04ucGFyc2UocGh4RXZlbnQpXG4gICAgICAgIDogW1tkZWZhdWx0S2luZCwgZGVmYXVsdEFyZ3NdXTtcblxuICAgIGNvbW1hbmRzLmZvckVhY2goKFtraW5kLCBhcmdzXSkgPT4ge1xuICAgICAgaWYgKGtpbmQgPT09IGRlZmF1bHRLaW5kKSB7XG4gICAgICAgIC8vIGFsd2F5cyBwcmVmZXIgdGhlIGFyZ3MsIGJ1dCBrZWVwIGV4aXN0aW5nIGtleXMgZnJvbSB0aGUgZGVmYXVsdEFyZ3NcbiAgICAgICAgYXJncyA9IHsgLi4uZGVmYXVsdEFyZ3MsIC4uLmFyZ3MgfTtcbiAgICAgICAgYXJncy5jYWxsYmFjayA9IGFyZ3MuY2FsbGJhY2sgfHwgZGVmYXVsdEFyZ3MuY2FsbGJhY2s7XG4gICAgICB9XG4gICAgICB0aGlzLmZpbHRlclRvRWxzKHZpZXcubGl2ZVNvY2tldCwgc291cmNlRWwsIGFyZ3MpLmZvckVhY2goKGVsKSA9PiB7XG4gICAgICAgIHRoaXNbYGV4ZWNfJHtraW5kfWBdKGUsIGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwgYXJncyk7XG4gICAgICB9KTtcbiAgICB9KTtcbiAgfSxcblxuICBpc1Zpc2libGUoZWwpIHtcbiAgICByZXR1cm4gISEoXG4gICAgICBlbC5vZmZzZXRXaWR0aCB8fFxuICAgICAgZWwub2Zmc2V0SGVpZ2h0IHx8XG4gICAgICBlbC5nZXRDbGllbnRSZWN0cygpLmxlbmd0aCA+IDBcbiAgICApO1xuICB9LFxuXG4gIC8vIHJldHVybnMgdHJ1ZSBpZiBhbnkgcGFydCBvZiB0aGUgZWxlbWVudCBpcyBpbnNpZGUgdGhlIHZpZXdwb3J0XG4gIGlzSW5WaWV3cG9ydChlbCkge1xuICAgIGNvbnN0IHJlY3QgPSBlbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTtcbiAgICBjb25zdCB3aW5kb3dIZWlnaHQgPVxuICAgICAgd2luZG93LmlubmVySGVpZ2h0IHx8IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5jbGllbnRIZWlnaHQ7XG4gICAgY29uc3Qgd2luZG93V2lkdGggPVxuICAgICAgd2luZG93LmlubmVyV2lkdGggfHwgZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LmNsaWVudFdpZHRoO1xuXG4gICAgcmV0dXJuIChcbiAgICAgIHJlY3QucmlnaHQgPiAwICYmXG4gICAgICByZWN0LmJvdHRvbSA+IDAgJiZcbiAgICAgIHJlY3QubGVmdCA8IHdpbmRvd1dpZHRoICYmXG4gICAgICByZWN0LnRvcCA8IHdpbmRvd0hlaWdodFxuICAgICk7XG4gIH0sXG5cbiAgLy8gcHJpdmF0ZVxuXG4gIC8vIGNvbW1hbmRzXG5cbiAgZXhlY19leGVjKGUsIGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwgeyBhdHRyLCB0byB9KSB7XG4gICAgY29uc3QgZW5jb2RlZEpTID0gZWwuZ2V0QXR0cmlidXRlKGF0dHIpO1xuICAgIGlmICghZW5jb2RlZEpTKSB7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoYGV4cGVjdGVkICR7YXR0cn0gdG8gY29udGFpbiBKUyBjb21tYW5kIG9uIFwiJHt0b31cImApO1xuICAgIH1cbiAgICB2aWV3LmxpdmVTb2NrZXQuZXhlY0pTKGVsLCBlbmNvZGVkSlMsIGV2ZW50VHlwZSk7XG4gIH0sXG5cbiAgZXhlY19kaXNwYXRjaChcbiAgICBlLFxuICAgIGV2ZW50VHlwZSxcbiAgICBwaHhFdmVudCxcbiAgICB2aWV3LFxuICAgIHNvdXJjZUVsLFxuICAgIGVsLFxuICAgIHsgZXZlbnQsIGRldGFpbCwgYnViYmxlcywgYmxvY2tpbmcgfSxcbiAgKSB7XG4gICAgZGV0YWlsID0gZGV0YWlsIHx8IHt9O1xuICAgIGRldGFpbC5kaXNwYXRjaGVyID0gc291cmNlRWw7XG4gICAgaWYgKGJsb2NraW5nKSB7XG4gICAgICBjb25zdCBwcm9taXNlID0gbmV3IFByb21pc2UoKHJlc29sdmUsIF9yZWplY3QpID0+IHtcbiAgICAgICAgZGV0YWlsLmRvbmUgPSByZXNvbHZlO1xuICAgICAgfSk7XG4gICAgICB2aWV3LmxpdmVTb2NrZXQuYXN5bmNUcmFuc2l0aW9uKHByb21pc2UpO1xuICAgIH1cbiAgICBET00uZGlzcGF0Y2hFdmVudChlbCwgZXZlbnQsIHsgZGV0YWlsLCBidWJibGVzIH0pO1xuICB9LFxuXG4gIGV4ZWNfcHVzaChlLCBldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIGFyZ3MpIHtcbiAgICBjb25zdCB7XG4gICAgICBldmVudCxcbiAgICAgIGRhdGEsXG4gICAgICB0YXJnZXQsXG4gICAgICBwYWdlX2xvYWRpbmcsXG4gICAgICBsb2FkaW5nLFxuICAgICAgdmFsdWUsXG4gICAgICBkaXNwYXRjaGVyLFxuICAgICAgY2FsbGJhY2ssXG4gICAgfSA9IGFyZ3M7XG4gICAgY29uc3QgcHVzaE9wdHMgPSB7XG4gICAgICBsb2FkaW5nLFxuICAgICAgdmFsdWUsXG4gICAgICB0YXJnZXQsXG4gICAgICBwYWdlX2xvYWRpbmc6ICEhcGFnZV9sb2FkaW5nLFxuICAgICAgb3JpZ2luYWxFdmVudDogZSxcbiAgICB9O1xuICAgIGNvbnN0IHRhcmdldFNyYyA9XG4gICAgICBldmVudFR5cGUgPT09IFwiY2hhbmdlXCIgJiYgZGlzcGF0Y2hlciA/IGRpc3BhdGNoZXIgOiBzb3VyY2VFbDtcbiAgICBjb25zdCBwaHhUYXJnZXQgPVxuICAgICAgdGFyZ2V0IHx8IHRhcmdldFNyYy5nZXRBdHRyaWJ1dGUodmlldy5iaW5kaW5nKFwidGFyZ2V0XCIpKSB8fCB0YXJnZXRTcmM7XG4gICAgY29uc3QgaGFuZGxlciA9ICh0YXJnZXRWaWV3LCB0YXJnZXRDdHgpID0+IHtcbiAgICAgIGlmICghdGFyZ2V0Vmlldy5pc0Nvbm5lY3RlZCgpKSB7XG4gICAgICAgIHJldHVybjtcbiAgICAgIH1cbiAgICAgIGlmIChldmVudFR5cGUgPT09IFwiY2hhbmdlXCIpIHtcbiAgICAgICAgbGV0IHsgbmV3Q2lkLCBfdGFyZ2V0IH0gPSBhcmdzO1xuICAgICAgICBfdGFyZ2V0ID1cbiAgICAgICAgICBfdGFyZ2V0IHx8IChET00uaXNGb3JtSW5wdXQoc291cmNlRWwpID8gc291cmNlRWwubmFtZSA6IHVuZGVmaW5lZCk7XG4gICAgICAgIGlmIChfdGFyZ2V0KSB7XG4gICAgICAgICAgcHVzaE9wdHMuX3RhcmdldCA9IF90YXJnZXQ7XG4gICAgICAgIH1cbiAgICAgICAgdGFyZ2V0Vmlldy5wdXNoSW5wdXQoXG4gICAgICAgICAgc291cmNlRWwsXG4gICAgICAgICAgdGFyZ2V0Q3R4LFxuICAgICAgICAgIG5ld0NpZCxcbiAgICAgICAgICBldmVudCB8fCBwaHhFdmVudCxcbiAgICAgICAgICBwdXNoT3B0cyxcbiAgICAgICAgICBjYWxsYmFjayxcbiAgICAgICAgKTtcbiAgICAgIH0gZWxzZSBpZiAoZXZlbnRUeXBlID09PSBcInN1Ym1pdFwiKSB7XG4gICAgICAgIGNvbnN0IHsgc3VibWl0dGVyIH0gPSBhcmdzO1xuICAgICAgICB0YXJnZXRWaWV3LnN1Ym1pdEZvcm0oXG4gICAgICAgICAgc291cmNlRWwsXG4gICAgICAgICAgdGFyZ2V0Q3R4LFxuICAgICAgICAgIGV2ZW50IHx8IHBoeEV2ZW50LFxuICAgICAgICAgIHN1Ym1pdHRlcixcbiAgICAgICAgICBwdXNoT3B0cyxcbiAgICAgICAgICBjYWxsYmFjayxcbiAgICAgICAgKTtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHRhcmdldFZpZXcucHVzaEV2ZW50KFxuICAgICAgICAgIGV2ZW50VHlwZSxcbiAgICAgICAgICBzb3VyY2VFbCxcbiAgICAgICAgICB0YXJnZXRDdHgsXG4gICAgICAgICAgZXZlbnQgfHwgcGh4RXZlbnQsXG4gICAgICAgICAgZGF0YSxcbiAgICAgICAgICBwdXNoT3B0cyxcbiAgICAgICAgICBjYWxsYmFjayxcbiAgICAgICAgKTtcbiAgICAgIH1cbiAgICB9O1xuICAgIC8vIGluIGNhc2Ugb2YgZm9ybVJlY292ZXJ5LCB0YXJnZXRWaWV3IGFuZCB0YXJnZXRDdHggYXJlIHBhc3NlZCBhcyBhcmd1bWVudFxuICAgIC8vIGFzIHRoZXkgYXJlIGxvb2tlZCB1cCBpbiBhIHRlbXBsYXRlIGVsZW1lbnQsIG5vdCB0aGUgcmVhbCBET01cbiAgICBpZiAoYXJncy50YXJnZXRWaWV3ICYmIGFyZ3MudGFyZ2V0Q3R4KSB7XG4gICAgICBoYW5kbGVyKGFyZ3MudGFyZ2V0VmlldywgYXJncy50YXJnZXRDdHgpO1xuICAgIH0gZWxzZSB7XG4gICAgICB2aWV3LndpdGhpblRhcmdldHMocGh4VGFyZ2V0LCBoYW5kbGVyKTtcbiAgICB9XG4gIH0sXG5cbiAgZXhlY19uYXZpZ2F0ZShlLCBldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIHsgaHJlZiwgcmVwbGFjZSB9KSB7XG4gICAgdmlldy5saXZlU29ja2V0Lmhpc3RvcnlSZWRpcmVjdChcbiAgICAgIGUsXG4gICAgICBocmVmLFxuICAgICAgcmVwbGFjZSA/IFwicmVwbGFjZVwiIDogXCJwdXNoXCIsXG4gICAgICBudWxsLFxuICAgICAgc291cmNlRWwsXG4gICAgKTtcbiAgfSxcblxuICBleGVjX3BhdGNoKGUsIGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwgeyBocmVmLCByZXBsYWNlIH0pIHtcbiAgICB2aWV3LmxpdmVTb2NrZXQucHVzaEhpc3RvcnlQYXRjaChcbiAgICAgIGUsXG4gICAgICBocmVmLFxuICAgICAgcmVwbGFjZSA/IFwicmVwbGFjZVwiIDogXCJwdXNoXCIsXG4gICAgICBzb3VyY2VFbCxcbiAgICApO1xuICB9LFxuXG4gIGV4ZWNfZm9jdXMoZSwgZXZlbnRUeXBlLCBwaHhFdmVudCwgdmlldywgc291cmNlRWwsIGVsKSB7XG4gICAgQVJJQS5hdHRlbXB0Rm9jdXMoZWwpO1xuICAgIC8vIGluIGNhc2UgdGhlIEpTLmZvY3VzIGNvbW1hbmQgaXMgaW4gYSBKUy5zaG93L2hpZGUvdG9nZ2xlIGNoYWluLCBmb3Igc2hvdyB3ZSBuZWVkXG4gICAgLy8gdG8gd2FpdCBmb3IgSlMuc2hvdyB0byBoYXZlIHVwZGF0ZWQgdGhlIGVsZW1lbnQncyBkaXNwbGF5IHByb3BlcnR5IChzZWUgZXhlY190b2dnbGUpXG4gICAgLy8gYnV0IHRoYXQgcnVuIGluIG5lc3RlZCBhbmltYXRpb24gZnJhbWVzLCB0aGVyZWZvcmUgd2UgbmVlZCB0byB1c2UgdGhlbSBoZXJlIGFzIHdlbGxcbiAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gQVJJQS5hdHRlbXB0Rm9jdXMoZWwpKTtcbiAgICB9KTtcbiAgfSxcblxuICBleGVjX2ZvY3VzX2ZpcnN0KGUsIGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCkge1xuICAgIEFSSUEuZm9jdXNGaXJzdEludGVyYWN0aXZlKGVsKSB8fCBBUklBLmZvY3VzRmlyc3QoZWwpO1xuICAgIC8vIGlmIHlvdSB3b25kZXIgYWJvdXQgdGhlIG5lc3RlZCBhbmltYXRpb24gZnJhbWVzLCBzZWUgZXhlY19mb2N1c1xuICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZShcbiAgICAgICAgKCkgPT4gQVJJQS5mb2N1c0ZpcnN0SW50ZXJhY3RpdmUoZWwpIHx8IEFSSUEuZm9jdXNGaXJzdChlbCksXG4gICAgICApO1xuICAgIH0pO1xuICB9LFxuXG4gIGV4ZWNfcHVzaF9mb2N1cyhlLCBldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwpIHtcbiAgICBmb2N1c1N0YWNrLnB1c2goZWwgfHwgc291cmNlRWwpO1xuICB9LFxuXG4gIGV4ZWNfcG9wX2ZvY3VzKF9lLCBfZXZlbnRUeXBlLCBfcGh4RXZlbnQsIF92aWV3LCBfc291cmNlRWwsIF9lbCkge1xuICAgIGNvbnN0IGVsID0gZm9jdXNTdGFjay5wb3AoKTtcbiAgICBpZiAoZWwpIHtcbiAgICAgIGVsLmZvY3VzKCk7XG4gICAgICAvLyBpZiB5b3Ugd29uZGVyIGFib3V0IHRoZSBuZXN0ZWQgYW5pbWF0aW9uIGZyYW1lcywgc2VlIGV4ZWNfZm9jdXNcbiAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IGVsLmZvY3VzKCkpO1xuICAgICAgfSk7XG4gICAgfVxuICB9LFxuXG4gIGV4ZWNfYWRkX2NsYXNzKFxuICAgIGUsXG4gICAgZXZlbnRUeXBlLFxuICAgIHBoeEV2ZW50LFxuICAgIHZpZXcsXG4gICAgc291cmNlRWwsXG4gICAgZWwsXG4gICAgeyBuYW1lcywgdHJhbnNpdGlvbiwgdGltZSwgYmxvY2tpbmcgfSxcbiAgKSB7XG4gICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIG5hbWVzLCBbXSwgdHJhbnNpdGlvbiwgdGltZSwgdmlldywgYmxvY2tpbmcpO1xuICB9LFxuXG4gIGV4ZWNfcmVtb3ZlX2NsYXNzKFxuICAgIGUsXG4gICAgZXZlbnRUeXBlLFxuICAgIHBoeEV2ZW50LFxuICAgIHZpZXcsXG4gICAgc291cmNlRWwsXG4gICAgZWwsXG4gICAgeyBuYW1lcywgdHJhbnNpdGlvbiwgdGltZSwgYmxvY2tpbmcgfSxcbiAgKSB7XG4gICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIFtdLCBuYW1lcywgdHJhbnNpdGlvbiwgdGltZSwgdmlldywgYmxvY2tpbmcpO1xuICB9LFxuXG4gIGV4ZWNfdG9nZ2xlX2NsYXNzKFxuICAgIGUsXG4gICAgZXZlbnRUeXBlLFxuICAgIHBoeEV2ZW50LFxuICAgIHZpZXcsXG4gICAgc291cmNlRWwsXG4gICAgZWwsXG4gICAgeyBuYW1lcywgdHJhbnNpdGlvbiwgdGltZSwgYmxvY2tpbmcgfSxcbiAgKSB7XG4gICAgdGhpcy50b2dnbGVDbGFzc2VzKGVsLCBuYW1lcywgdHJhbnNpdGlvbiwgdGltZSwgdmlldywgYmxvY2tpbmcpO1xuICB9LFxuXG4gIGV4ZWNfdG9nZ2xlX2F0dHIoXG4gICAgZSxcbiAgICBldmVudFR5cGUsXG4gICAgcGh4RXZlbnQsXG4gICAgdmlldyxcbiAgICBzb3VyY2VFbCxcbiAgICBlbCxcbiAgICB7IGF0dHI6IFthdHRyLCB2YWwxLCB2YWwyXSB9LFxuICApIHtcbiAgICB0aGlzLnRvZ2dsZUF0dHIoZWwsIGF0dHIsIHZhbDEsIHZhbDIpO1xuICB9LFxuXG4gIGV4ZWNfaWdub3JlX2F0dHJzKGUsIGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwgeyBhdHRycyB9KSB7XG4gICAgdGhpcy5pZ25vcmVBdHRycyhlbCwgYXR0cnMpO1xuICB9LFxuXG4gIGV4ZWNfdHJhbnNpdGlvbihcbiAgICBlLFxuICAgIGV2ZW50VHlwZSxcbiAgICBwaHhFdmVudCxcbiAgICB2aWV3LFxuICAgIHNvdXJjZUVsLFxuICAgIGVsLFxuICAgIHsgdGltZSwgdHJhbnNpdGlvbiwgYmxvY2tpbmcgfSxcbiAgKSB7XG4gICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIFtdLCBbXSwgdHJhbnNpdGlvbiwgdGltZSwgdmlldywgYmxvY2tpbmcpO1xuICB9LFxuXG4gIGV4ZWNfdG9nZ2xlKFxuICAgIGUsXG4gICAgZXZlbnRUeXBlLFxuICAgIHBoeEV2ZW50LFxuICAgIHZpZXcsXG4gICAgc291cmNlRWwsXG4gICAgZWwsXG4gICAgeyBkaXNwbGF5LCBpbnMsIG91dHMsIHRpbWUsIGJsb2NraW5nIH0sXG4gICkge1xuICAgIHRoaXMudG9nZ2xlKGV2ZW50VHlwZSwgdmlldywgZWwsIGRpc3BsYXksIGlucywgb3V0cywgdGltZSwgYmxvY2tpbmcpO1xuICB9LFxuXG4gIGV4ZWNfc2hvdyhcbiAgICBlLFxuICAgIGV2ZW50VHlwZSxcbiAgICBwaHhFdmVudCxcbiAgICB2aWV3LFxuICAgIHNvdXJjZUVsLFxuICAgIGVsLFxuICAgIHsgZGlzcGxheSwgdHJhbnNpdGlvbiwgdGltZSwgYmxvY2tpbmcgfSxcbiAgKSB7XG4gICAgdGhpcy5zaG93KGV2ZW50VHlwZSwgdmlldywgZWwsIGRpc3BsYXksIHRyYW5zaXRpb24sIHRpbWUsIGJsb2NraW5nKTtcbiAgfSxcblxuICBleGVjX2hpZGUoXG4gICAgZSxcbiAgICBldmVudFR5cGUsXG4gICAgcGh4RXZlbnQsXG4gICAgdmlldyxcbiAgICBzb3VyY2VFbCxcbiAgICBlbCxcbiAgICB7IGRpc3BsYXksIHRyYW5zaXRpb24sIHRpbWUsIGJsb2NraW5nIH0sXG4gICkge1xuICAgIHRoaXMuaGlkZShldmVudFR5cGUsIHZpZXcsIGVsLCBkaXNwbGF5LCB0cmFuc2l0aW9uLCB0aW1lLCBibG9ja2luZyk7XG4gIH0sXG5cbiAgZXhlY19zZXRfYXR0cihcbiAgICBlLFxuICAgIGV2ZW50VHlwZSxcbiAgICBwaHhFdmVudCxcbiAgICB2aWV3LFxuICAgIHNvdXJjZUVsLFxuICAgIGVsLFxuICAgIHsgYXR0cjogW2F0dHIsIHZhbF0gfSxcbiAgKSB7XG4gICAgdGhpcy5zZXRPclJlbW92ZUF0dHJzKGVsLCBbW2F0dHIsIHZhbF1dLCBbXSk7XG4gIH0sXG5cbiAgZXhlY19yZW1vdmVfYXR0cihlLCBldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIHsgYXR0ciB9KSB7XG4gICAgdGhpcy5zZXRPclJlbW92ZUF0dHJzKGVsLCBbXSwgW2F0dHJdKTtcbiAgfSxcblxuICBpZ25vcmVBdHRycyhlbCwgYXR0cnMpIHtcbiAgICBET00ucHV0UHJpdmF0ZShlbCwgXCJKUzppZ25vcmVfYXR0cnNcIiwge1xuICAgICAgYXBwbHk6IChmcm9tRWwsIHRvRWwpID0+IHtcbiAgICAgICAgQXJyYXkuZnJvbShmcm9tRWwuYXR0cmlidXRlcykuZm9yRWFjaCgoYXR0cikgPT4ge1xuICAgICAgICAgIGlmIChcbiAgICAgICAgICAgIGF0dHJzLnNvbWUoXG4gICAgICAgICAgICAgICh0b0lnbm9yZSkgPT5cbiAgICAgICAgICAgICAgICBhdHRyLm5hbWUgPT0gdG9JZ25vcmUgfHxcbiAgICAgICAgICAgICAgICAodG9JZ25vcmUuaW5jbHVkZXMoXCIqXCIpICYmIGF0dHIubmFtZS5tYXRjaCh0b0lnbm9yZSkgIT0gbnVsbCksXG4gICAgICAgICAgICApXG4gICAgICAgICAgKSB7XG4gICAgICAgICAgICB0b0VsLnNldEF0dHJpYnV0ZShhdHRyLm5hbWUsIGF0dHIudmFsdWUpO1xuICAgICAgICAgIH1cbiAgICAgICAgfSk7XG4gICAgICB9LFxuICAgIH0pO1xuICB9LFxuXG4gIG9uQmVmb3JlRWxVcGRhdGVkKGZyb21FbCwgdG9FbCkge1xuICAgIGNvbnN0IGlnbm9yZUF0dHJzID0gRE9NLnByaXZhdGUoZnJvbUVsLCBcIkpTOmlnbm9yZV9hdHRyc1wiKTtcbiAgICBpZiAoaWdub3JlQXR0cnMpIHtcbiAgICAgIGlnbm9yZUF0dHJzLmFwcGx5KGZyb21FbCwgdG9FbCk7XG4gICAgfVxuICB9LFxuXG4gIC8vIHV0aWxzIGZvciBjb21tYW5kc1xuXG4gIHNob3coZXZlbnRUeXBlLCB2aWV3LCBlbCwgZGlzcGxheSwgdHJhbnNpdGlvbiwgdGltZSwgYmxvY2tpbmcpIHtcbiAgICBpZiAoIXRoaXMuaXNWaXNpYmxlKGVsKSkge1xuICAgICAgdGhpcy50b2dnbGUoXG4gICAgICAgIGV2ZW50VHlwZSxcbiAgICAgICAgdmlldyxcbiAgICAgICAgZWwsXG4gICAgICAgIGRpc3BsYXksXG4gICAgICAgIHRyYW5zaXRpb24sXG4gICAgICAgIG51bGwsXG4gICAgICAgIHRpbWUsXG4gICAgICAgIGJsb2NraW5nLFxuICAgICAgKTtcbiAgICB9XG4gIH0sXG5cbiAgaGlkZShldmVudFR5cGUsIHZpZXcsIGVsLCBkaXNwbGF5LCB0cmFuc2l0aW9uLCB0aW1lLCBibG9ja2luZykge1xuICAgIGlmICh0aGlzLmlzVmlzaWJsZShlbCkpIHtcbiAgICAgIHRoaXMudG9nZ2xlKFxuICAgICAgICBldmVudFR5cGUsXG4gICAgICAgIHZpZXcsXG4gICAgICAgIGVsLFxuICAgICAgICBkaXNwbGF5LFxuICAgICAgICBudWxsLFxuICAgICAgICB0cmFuc2l0aW9uLFxuICAgICAgICB0aW1lLFxuICAgICAgICBibG9ja2luZyxcbiAgICAgICk7XG4gICAgfVxuICB9LFxuXG4gIHRvZ2dsZShldmVudFR5cGUsIHZpZXcsIGVsLCBkaXNwbGF5LCBpbnMsIG91dHMsIHRpbWUsIGJsb2NraW5nKSB7XG4gICAgdGltZSA9IHRpbWUgfHwgZGVmYXVsdF90cmFuc2l0aW9uX3RpbWU7XG4gICAgY29uc3QgW2luQ2xhc3NlcywgaW5TdGFydENsYXNzZXMsIGluRW5kQ2xhc3Nlc10gPSBpbnMgfHwgW1tdLCBbXSwgW11dO1xuICAgIGNvbnN0IFtvdXRDbGFzc2VzLCBvdXRTdGFydENsYXNzZXMsIG91dEVuZENsYXNzZXNdID0gb3V0cyB8fCBbW10sIFtdLCBbXV07XG4gICAgaWYgKGluQ2xhc3Nlcy5sZW5ndGggPiAwIHx8IG91dENsYXNzZXMubGVuZ3RoID4gMCkge1xuICAgICAgaWYgKHRoaXMuaXNWaXNpYmxlKGVsKSkge1xuICAgICAgICBjb25zdCBvblN0YXJ0ID0gKCkgPT4ge1xuICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKFxuICAgICAgICAgICAgZWwsXG4gICAgICAgICAgICBvdXRTdGFydENsYXNzZXMsXG4gICAgICAgICAgICBpbkNsYXNzZXMuY29uY2F0KGluU3RhcnRDbGFzc2VzKS5jb25jYXQoaW5FbmRDbGFzc2VzKSxcbiAgICAgICAgICApO1xuICAgICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIG91dENsYXNzZXMsIFtdKTtcbiAgICAgICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT5cbiAgICAgICAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIG91dEVuZENsYXNzZXMsIG91dFN0YXJ0Q2xhc3NlcyksXG4gICAgICAgICAgICApO1xuICAgICAgICAgIH0pO1xuICAgICAgICB9O1xuICAgICAgICBjb25zdCBvbkVuZCA9ICgpID0+IHtcbiAgICAgICAgICB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgW10sIG91dENsYXNzZXMuY29uY2F0KG91dEVuZENsYXNzZXMpKTtcbiAgICAgICAgICBET00ucHV0U3RpY2t5KFxuICAgICAgICAgICAgZWwsXG4gICAgICAgICAgICBcInRvZ2dsZVwiLFxuICAgICAgICAgICAgKGN1cnJlbnRFbCkgPT4gKGN1cnJlbnRFbC5zdHlsZS5kaXNwbGF5ID0gXCJub25lXCIpLFxuICAgICAgICAgICk7XG4gICAgICAgICAgZWwuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoXCJwaHg6aGlkZS1lbmRcIikpO1xuICAgICAgICB9O1xuICAgICAgICBlbC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudChcInBoeDpoaWRlLXN0YXJ0XCIpKTtcbiAgICAgICAgaWYgKGJsb2NraW5nID09PSBmYWxzZSkge1xuICAgICAgICAgIG9uU3RhcnQoKTtcbiAgICAgICAgICBzZXRUaW1lb3V0KG9uRW5kLCB0aW1lKTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICB2aWV3LnRyYW5zaXRpb24odGltZSwgb25TdGFydCwgb25FbmQpO1xuICAgICAgICB9XG4gICAgICB9IGVsc2Uge1xuICAgICAgICBpZiAoZXZlbnRUeXBlID09PSBcInJlbW92ZVwiKSB7XG4gICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG4gICAgICAgIGNvbnN0IG9uU3RhcnQgPSAoKSA9PiB7XG4gICAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoXG4gICAgICAgICAgICBlbCxcbiAgICAgICAgICAgIGluU3RhcnRDbGFzc2VzLFxuICAgICAgICAgICAgb3V0Q2xhc3Nlcy5jb25jYXQob3V0U3RhcnRDbGFzc2VzKS5jb25jYXQob3V0RW5kQ2xhc3NlcyksXG4gICAgICAgICAgKTtcbiAgICAgICAgICBjb25zdCBzdGlja3lEaXNwbGF5ID0gZGlzcGxheSB8fCB0aGlzLmRlZmF1bHREaXNwbGF5KGVsKTtcbiAgICAgICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgICAgICAgIC8vIGZpcnN0IGFkZCB0aGUgc3RhcnRpbmcgKyBhY3RpdmUgY2xhc3MsIFRIRU4gbWFrZSB0aGUgZWxlbWVudCB2aXNpYmxlXG4gICAgICAgICAgICAvLyBvdGhlcndpc2UgaWYgd2UgdG9nZ2xlZCB0aGUgdmlzaWJpbGl0eSBlYXJsaWVyIGNzcyBhbmltYXRpb25zXG4gICAgICAgICAgICAvLyB3b3VsZCBmbGlja2VyLCBhcyB0aGUgZWxlbWVudCBiZWNvbWVzIHZpc2libGUgYmVmb3JlIHRoZSBhY3RpdmUgYW5pbWF0aW9uXG4gICAgICAgICAgICAvLyBjbGFzcyBpcyBzZXQgKHNlZSBodHRwczovL2dpdGh1Yi5jb20vcGhvZW5peGZyYW1ld29yay9waG9lbml4X2xpdmVfdmlldy9pc3N1ZXMvMzQ1NilcbiAgICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBpbkNsYXNzZXMsIFtdKTtcbiAgICAgICAgICAgIC8vIGFkZE9yUmVtb3ZlQ2xhc3NlcyB1c2VzIGEgcmVxdWVzdEFuaW1hdGlvbkZyYW1lIGl0c2VsZiwgdGhlcmVmb3JlIHdlIG5lZWQgdG8gbW92ZSB0aGUgcHV0U3RpY2t5XG4gICAgICAgICAgICAvLyBpbnRvIHRoZSBuZXh0IHJlcXVlc3RBbmltYXRpb25GcmFtZS4uLlxuICAgICAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICAgICAgICAgIERPTS5wdXRTdGlja3koXG4gICAgICAgICAgICAgICAgZWwsXG4gICAgICAgICAgICAgICAgXCJ0b2dnbGVcIixcbiAgICAgICAgICAgICAgICAoY3VycmVudEVsKSA9PiAoY3VycmVudEVsLnN0eWxlLmRpc3BsYXkgPSBzdGlja3lEaXNwbGF5KSxcbiAgICAgICAgICAgICAgKTtcbiAgICAgICAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIGluRW5kQ2xhc3NlcywgaW5TdGFydENsYXNzZXMpO1xuICAgICAgICAgICAgfSk7XG4gICAgICAgICAgfSk7XG4gICAgICAgIH07XG4gICAgICAgIGNvbnN0IG9uRW5kID0gKCkgPT4ge1xuICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBbXSwgaW5DbGFzc2VzLmNvbmNhdChpbkVuZENsYXNzZXMpKTtcbiAgICAgICAgICBlbC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudChcInBoeDpzaG93LWVuZFwiKSk7XG4gICAgICAgIH07XG4gICAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwicGh4OnNob3ctc3RhcnRcIikpO1xuICAgICAgICBpZiAoYmxvY2tpbmcgPT09IGZhbHNlKSB7XG4gICAgICAgICAgb25TdGFydCgpO1xuICAgICAgICAgIHNldFRpbWVvdXQob25FbmQsIHRpbWUpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIHZpZXcudHJhbnNpdGlvbih0aW1lLCBvblN0YXJ0LCBvbkVuZCk7XG4gICAgICAgIH1cbiAgICAgIH1cbiAgICB9IGVsc2Uge1xuICAgICAgaWYgKHRoaXMuaXNWaXNpYmxlKGVsKSkge1xuICAgICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgICAgICBlbC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudChcInBoeDpoaWRlLXN0YXJ0XCIpKTtcbiAgICAgICAgICBET00ucHV0U3RpY2t5KFxuICAgICAgICAgICAgZWwsXG4gICAgICAgICAgICBcInRvZ2dsZVwiLFxuICAgICAgICAgICAgKGN1cnJlbnRFbCkgPT4gKGN1cnJlbnRFbC5zdHlsZS5kaXNwbGF5ID0gXCJub25lXCIpLFxuICAgICAgICAgICk7XG4gICAgICAgICAgZWwuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoXCJwaHg6aGlkZS1lbmRcIikpO1xuICAgICAgICB9KTtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwicGh4OnNob3ctc3RhcnRcIikpO1xuICAgICAgICAgIGNvbnN0IHN0aWNreURpc3BsYXkgPSBkaXNwbGF5IHx8IHRoaXMuZGVmYXVsdERpc3BsYXkoZWwpO1xuICAgICAgICAgIERPTS5wdXRTdGlja3koXG4gICAgICAgICAgICBlbCxcbiAgICAgICAgICAgIFwidG9nZ2xlXCIsXG4gICAgICAgICAgICAoY3VycmVudEVsKSA9PiAoY3VycmVudEVsLnN0eWxlLmRpc3BsYXkgPSBzdGlja3lEaXNwbGF5KSxcbiAgICAgICAgICApO1xuICAgICAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwicGh4OnNob3ctZW5kXCIpKTtcbiAgICAgICAgfSk7XG4gICAgICB9XG4gICAgfVxuICB9LFxuXG4gIHRvZ2dsZUNsYXNzZXMoZWwsIGNsYXNzZXMsIHRyYW5zaXRpb24sIHRpbWUsIHZpZXcsIGJsb2NraW5nKSB7XG4gICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICBjb25zdCBbcHJldkFkZHMsIHByZXZSZW1vdmVzXSA9IERPTS5nZXRTdGlja3koZWwsIFwiY2xhc3Nlc1wiLCBbW10sIFtdXSk7XG4gICAgICBjb25zdCBuZXdBZGRzID0gY2xhc3Nlcy5maWx0ZXIoXG4gICAgICAgIChuYW1lKSA9PiBwcmV2QWRkcy5pbmRleE9mKG5hbWUpIDwgMCAmJiAhZWwuY2xhc3NMaXN0LmNvbnRhaW5zKG5hbWUpLFxuICAgICAgKTtcbiAgICAgIGNvbnN0IG5ld1JlbW92ZXMgPSBjbGFzc2VzLmZpbHRlcihcbiAgICAgICAgKG5hbWUpID0+IHByZXZSZW1vdmVzLmluZGV4T2YobmFtZSkgPCAwICYmIGVsLmNsYXNzTGlzdC5jb250YWlucyhuYW1lKSxcbiAgICAgICk7XG4gICAgICB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhcbiAgICAgICAgZWwsXG4gICAgICAgIG5ld0FkZHMsXG4gICAgICAgIG5ld1JlbW92ZXMsXG4gICAgICAgIHRyYW5zaXRpb24sXG4gICAgICAgIHRpbWUsXG4gICAgICAgIHZpZXcsXG4gICAgICAgIGJsb2NraW5nLFxuICAgICAgKTtcbiAgICB9KTtcbiAgfSxcblxuICB0b2dnbGVBdHRyKGVsLCBhdHRyLCB2YWwxLCB2YWwyKSB7XG4gICAgaWYgKGVsLmhhc0F0dHJpYnV0ZShhdHRyKSkge1xuICAgICAgaWYgKHZhbDIgIT09IHVuZGVmaW5lZCkge1xuICAgICAgICAvLyB0b2dnbGUgYmV0d2VlbiB2YWwxIGFuZCB2YWwyXG4gICAgICAgIGlmIChlbC5nZXRBdHRyaWJ1dGUoYXR0cikgPT09IHZhbDEpIHtcbiAgICAgICAgICB0aGlzLnNldE9yUmVtb3ZlQXR0cnMoZWwsIFtbYXR0ciwgdmFsMl1dLCBbXSk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgdGhpcy5zZXRPclJlbW92ZUF0dHJzKGVsLCBbW2F0dHIsIHZhbDFdXSwgW10pO1xuICAgICAgICB9XG4gICAgICB9IGVsc2Uge1xuICAgICAgICAvLyByZW1vdmUgYXR0clxuICAgICAgICB0aGlzLnNldE9yUmVtb3ZlQXR0cnMoZWwsIFtdLCBbYXR0cl0pO1xuICAgICAgfVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLnNldE9yUmVtb3ZlQXR0cnMoZWwsIFtbYXR0ciwgdmFsMV1dLCBbXSk7XG4gICAgfVxuICB9LFxuXG4gIGFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgYWRkcywgcmVtb3ZlcywgdHJhbnNpdGlvbiwgdGltZSwgdmlldywgYmxvY2tpbmcpIHtcbiAgICB0aW1lID0gdGltZSB8fCBkZWZhdWx0X3RyYW5zaXRpb25fdGltZTtcbiAgICBjb25zdCBbdHJhbnNpdGlvblJ1biwgdHJhbnNpdGlvblN0YXJ0LCB0cmFuc2l0aW9uRW5kXSA9IHRyYW5zaXRpb24gfHwgW1xuICAgICAgW10sXG4gICAgICBbXSxcbiAgICAgIFtdLFxuICAgIF07XG4gICAgaWYgKHRyYW5zaXRpb25SdW4ubGVuZ3RoID4gMCkge1xuICAgICAgY29uc3Qgb25TdGFydCA9ICgpID0+IHtcbiAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoXG4gICAgICAgICAgZWwsXG4gICAgICAgICAgdHJhbnNpdGlvblN0YXJ0LFxuICAgICAgICAgIFtdLmNvbmNhdCh0cmFuc2l0aW9uUnVuKS5jb25jYXQodHJhbnNpdGlvbkVuZCksXG4gICAgICAgICk7XG4gICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCB0cmFuc2l0aW9uUnVuLCBbXSk7XG4gICAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PlxuICAgICAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIHRyYW5zaXRpb25FbmQsIHRyYW5zaXRpb25TdGFydCksXG4gICAgICAgICAgKTtcbiAgICAgICAgfSk7XG4gICAgICB9O1xuICAgICAgY29uc3Qgb25Eb25lID0gKCkgPT5cbiAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoXG4gICAgICAgICAgZWwsXG4gICAgICAgICAgYWRkcy5jb25jYXQodHJhbnNpdGlvbkVuZCksXG4gICAgICAgICAgcmVtb3Zlcy5jb25jYXQodHJhbnNpdGlvblJ1bikuY29uY2F0KHRyYW5zaXRpb25TdGFydCksXG4gICAgICAgICk7XG4gICAgICBpZiAoYmxvY2tpbmcgPT09IGZhbHNlKSB7XG4gICAgICAgIG9uU3RhcnQoKTtcbiAgICAgICAgc2V0VGltZW91dChvbkRvbmUsIHRpbWUpO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdmlldy50cmFuc2l0aW9uKHRpbWUsIG9uU3RhcnQsIG9uRG9uZSk7XG4gICAgICB9XG4gICAgICByZXR1cm47XG4gICAgfVxuXG4gICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICBjb25zdCBbcHJldkFkZHMsIHByZXZSZW1vdmVzXSA9IERPTS5nZXRTdGlja3koZWwsIFwiY2xhc3Nlc1wiLCBbW10sIFtdXSk7XG4gICAgICBjb25zdCBrZWVwQWRkcyA9IGFkZHMuZmlsdGVyKFxuICAgICAgICAobmFtZSkgPT4gcHJldkFkZHMuaW5kZXhPZihuYW1lKSA8IDAgJiYgIWVsLmNsYXNzTGlzdC5jb250YWlucyhuYW1lKSxcbiAgICAgICk7XG4gICAgICBjb25zdCBrZWVwUmVtb3ZlcyA9IHJlbW92ZXMuZmlsdGVyKFxuICAgICAgICAobmFtZSkgPT4gcHJldlJlbW92ZXMuaW5kZXhPZihuYW1lKSA8IDAgJiYgZWwuY2xhc3NMaXN0LmNvbnRhaW5zKG5hbWUpLFxuICAgICAgKTtcbiAgICAgIGNvbnN0IG5ld0FkZHMgPSBwcmV2QWRkc1xuICAgICAgICAuZmlsdGVyKChuYW1lKSA9PiByZW1vdmVzLmluZGV4T2YobmFtZSkgPCAwKVxuICAgICAgICAuY29uY2F0KGtlZXBBZGRzKTtcbiAgICAgIGNvbnN0IG5ld1JlbW92ZXMgPSBwcmV2UmVtb3Zlc1xuICAgICAgICAuZmlsdGVyKChuYW1lKSA9PiBhZGRzLmluZGV4T2YobmFtZSkgPCAwKVxuICAgICAgICAuY29uY2F0KGtlZXBSZW1vdmVzKTtcblxuICAgICAgRE9NLnB1dFN0aWNreShlbCwgXCJjbGFzc2VzXCIsIChjdXJyZW50RWwpID0+IHtcbiAgICAgICAgY3VycmVudEVsLmNsYXNzTGlzdC5yZW1vdmUoLi4ubmV3UmVtb3Zlcyk7XG4gICAgICAgIGN1cnJlbnRFbC5jbGFzc0xpc3QuYWRkKC4uLm5ld0FkZHMpO1xuICAgICAgICByZXR1cm4gW25ld0FkZHMsIG5ld1JlbW92ZXNdO1xuICAgICAgfSk7XG4gICAgfSk7XG4gIH0sXG5cbiAgc2V0T3JSZW1vdmVBdHRycyhlbCwgc2V0cywgcmVtb3Zlcykge1xuICAgIGNvbnN0IFtwcmV2U2V0cywgcHJldlJlbW92ZXNdID0gRE9NLmdldFN0aWNreShlbCwgXCJhdHRyc1wiLCBbW10sIFtdXSk7XG5cbiAgICBjb25zdCBhbHRlcmVkQXR0cnMgPSBzZXRzLm1hcCgoW2F0dHIsIF92YWxdKSA9PiBhdHRyKS5jb25jYXQocmVtb3Zlcyk7XG4gICAgY29uc3QgbmV3U2V0cyA9IHByZXZTZXRzXG4gICAgICAuZmlsdGVyKChbYXR0ciwgX3ZhbF0pID0+ICFhbHRlcmVkQXR0cnMuaW5jbHVkZXMoYXR0cikpXG4gICAgICAuY29uY2F0KHNldHMpO1xuICAgIGNvbnN0IG5ld1JlbW92ZXMgPSBwcmV2UmVtb3Zlc1xuICAgICAgLmZpbHRlcigoYXR0cikgPT4gIWFsdGVyZWRBdHRycy5pbmNsdWRlcyhhdHRyKSlcbiAgICAgIC5jb25jYXQocmVtb3Zlcyk7XG5cbiAgICBET00ucHV0U3RpY2t5KGVsLCBcImF0dHJzXCIsIChjdXJyZW50RWwpID0+IHtcbiAgICAgIG5ld1JlbW92ZXMuZm9yRWFjaCgoYXR0cikgPT4gY3VycmVudEVsLnJlbW92ZUF0dHJpYnV0ZShhdHRyKSk7XG4gICAgICBuZXdTZXRzLmZvckVhY2goKFthdHRyLCB2YWxdKSA9PiBjdXJyZW50RWwuc2V0QXR0cmlidXRlKGF0dHIsIHZhbCkpO1xuICAgICAgcmV0dXJuIFtuZXdTZXRzLCBuZXdSZW1vdmVzXTtcbiAgICB9KTtcbiAgfSxcblxuICBoYXNBbGxDbGFzc2VzKGVsLCBjbGFzc2VzKSB7XG4gICAgcmV0dXJuIGNsYXNzZXMuZXZlcnkoKG5hbWUpID0+IGVsLmNsYXNzTGlzdC5jb250YWlucyhuYW1lKSk7XG4gIH0sXG5cbiAgaXNUb2dnbGVkT3V0KGVsLCBvdXRDbGFzc2VzKSB7XG4gICAgcmV0dXJuICF0aGlzLmlzVmlzaWJsZShlbCkgfHwgdGhpcy5oYXNBbGxDbGFzc2VzKGVsLCBvdXRDbGFzc2VzKTtcbiAgfSxcblxuICBmaWx0ZXJUb0VscyhsaXZlU29ja2V0LCBzb3VyY2VFbCwgeyB0byB9KSB7XG4gICAgY29uc3QgZGVmYXVsdFF1ZXJ5ID0gKCkgPT4ge1xuICAgICAgaWYgKHR5cGVvZiB0byA9PT0gXCJzdHJpbmdcIikge1xuICAgICAgICByZXR1cm4gZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCh0byk7XG4gICAgICB9IGVsc2UgaWYgKHRvLmNsb3Nlc3QpIHtcbiAgICAgICAgY29uc3QgdG9FbCA9IHNvdXJjZUVsLmNsb3Nlc3QodG8uY2xvc2VzdCk7XG4gICAgICAgIHJldHVybiB0b0VsID8gW3RvRWxdIDogW107XG4gICAgICB9IGVsc2UgaWYgKHRvLmlubmVyKSB7XG4gICAgICAgIHJldHVybiBzb3VyY2VFbC5xdWVyeVNlbGVjdG9yQWxsKHRvLmlubmVyKTtcbiAgICAgIH1cbiAgICB9O1xuICAgIHJldHVybiB0b1xuICAgICAgPyBsaXZlU29ja2V0LmpzUXVlcnlTZWxlY3RvckFsbChzb3VyY2VFbCwgdG8sIGRlZmF1bHRRdWVyeSlcbiAgICAgIDogW3NvdXJjZUVsXTtcbiAgfSxcblxuICBkZWZhdWx0RGlzcGxheShlbCkge1xuICAgIHJldHVybiAoXG4gICAgICB7IHRyOiBcInRhYmxlLXJvd1wiLCB0ZDogXCJ0YWJsZS1jZWxsXCIgfVtlbC50YWdOYW1lLnRvTG93ZXJDYXNlKCldIHx8IFwiYmxvY2tcIlxuICAgICk7XG4gIH0sXG5cbiAgdHJhbnNpdGlvbkNsYXNzZXModmFsKSB7XG4gICAgaWYgKCF2YWwpIHtcbiAgICAgIHJldHVybiBudWxsO1xuICAgIH1cblxuICAgIGxldCBbdHJhbnMsIHRTdGFydCwgdEVuZF0gPSBBcnJheS5pc0FycmF5KHZhbClcbiAgICAgID8gdmFsXG4gICAgICA6IFt2YWwuc3BsaXQoXCIgXCIpLCBbXSwgW11dO1xuICAgIHRyYW5zID0gQXJyYXkuaXNBcnJheSh0cmFucykgPyB0cmFucyA6IHRyYW5zLnNwbGl0KFwiIFwiKTtcbiAgICB0U3RhcnQgPSBBcnJheS5pc0FycmF5KHRTdGFydCkgPyB0U3RhcnQgOiB0U3RhcnQuc3BsaXQoXCIgXCIpO1xuICAgIHRFbmQgPSBBcnJheS5pc0FycmF5KHRFbmQpID8gdEVuZCA6IHRFbmQuc3BsaXQoXCIgXCIpO1xuICAgIHJldHVybiBbdHJhbnMsIHRTdGFydCwgdEVuZF07XG4gIH0sXG59O1xuXG5leHBvcnQgZGVmYXVsdCBKUztcbiIsICJpbXBvcnQgSlMgZnJvbSBcIi4vanNcIjtcbmltcG9ydCBMaXZlU29ja2V0IGZyb20gXCIuL2xpdmVfc29ja2V0XCI7XG5cbnR5cGUgVHJhbnNpdGlvbiA9IHN0cmluZyB8IHN0cmluZ1tdO1xuXG4vLyBCYXNlIG9wdGlvbnMgZm9yIGNvbW1hbmRzIGludm9sdmluZyB0cmFuc2l0aW9ucyBhbmQgdGltaW5nXG50eXBlIEJhc2VPcHRzID0ge1xuICAvKipcbiAgICogVGhlIENTUyB0cmFuc2l0aW9uIGNsYXNzZXMgdG8gc2V0LlxuICAgKiBBY2NlcHRzIGEgc3RyaW5nIG9mIGNsYXNzZXMgb3IgYSAzLXR1cGxlIGxpa2U6XG4gICAqIGBbXCJlYXNlLW91dCBkdXJhdGlvbi0zMDBcIiwgXCJvcGFjaXR5LTBcIiwgXCJvcGFjaXR5LTEwMFwiXWBcbiAgICovXG4gIHRyYW5zaXRpb24/OiBUcmFuc2l0aW9uO1xuICAvKiogVGhlIHRyYW5zaXRpb24gZHVyYXRpb24gaW4gbWlsbGlzZWNvbmRzLiBEZWZhdWx0cyAyMDAuICovXG4gIHRpbWU/OiBudW1iZXI7XG4gIC8qKiBXaGV0aGVyIHRvIGJsb2NrIFVJIGR1cmluZyB0cmFuc2l0aW9uLiBEZWZhdWx0cyBgdHJ1ZWAuICovXG4gIGJsb2NraW5nPzogYm9vbGVhbjtcbn07XG5cbnR5cGUgU2hvd09wdHMgPSBCYXNlT3B0cyAmIHtcbiAgLyoqIFRoZSBDU1MgZGlzcGxheSB2YWx1ZSB0byBzZXQuIERlZmF1bHRzIFwiYmxvY2tcIi4gKi9cbiAgZGlzcGxheT86IHN0cmluZztcbn07XG5cbnR5cGUgVG9nZ2xlT3B0cyA9IHtcbiAgLyoqIFRoZSBDU1MgZGlzcGxheSB2YWx1ZSB0byBzZXQuIERlZmF1bHRzIFwiYmxvY2tcIi4gKi9cbiAgZGlzcGxheT86IHN0cmluZztcbiAgLyoqXG4gICAqIFRoZSBDU1MgdHJhbnNpdGlvbiBjbGFzc2VzIGZvciBzaG93aW5nLlxuICAgKiBBY2NlcHRzIGVpdGhlciB0aGUgc3RyaW5nIG9mIGNsYXNzZXMgdG8gYXBwbHkgd2hlbiB0b2dnbGluZyBpbiwgb3JcbiAgICogYSAzLXR1cGxlIGNvbnRhaW5pbmcgdGhlIHRyYW5zaXRpb24gY2xhc3MsIHRoZSBjbGFzcyB0byBhcHBseVxuICAgKiB0byBzdGFydCB0aGUgdHJhbnNpdGlvbiwgYW5kIHRoZSBlbmRpbmcgdHJhbnNpdGlvbiBjbGFzcywgc3VjaCBhczpcbiAgICogYFtcImVhc2Utb3V0IGR1cmF0aW9uLTMwMFwiLCBcIm9wYWNpdHktMFwiLCBcIm9wYWNpdHktMTAwXCJdYFxuICAgKi9cbiAgaW4/OiBUcmFuc2l0aW9uO1xuICAvKipcbiAgICogVGhlIENTUyB0cmFuc2l0aW9uIGNsYXNzZXMgZm9yIGhpZGluZy5cbiAgICogQWNjZXB0cyBlaXRoZXIgc3RyaW5nIG9mIGNsYXNzZXMgdG8gYXBwbHkgd2hlbiB0b2dnbGluZyBvdXQsIG9yXG4gICAqIGEgMy10dXBsZSBjb250YWluaW5nIHRoZSB0cmFuc2l0aW9uIGNsYXNzLCB0aGUgY2xhc3MgdG8gYXBwbHlcbiAgICogdG8gc3RhcnQgdGhlIHRyYW5zaXRpb24sIGFuZCB0aGUgZW5kaW5nIHRyYW5zaXRpb24gY2xhc3MsIHN1Y2ggYXM6XG4gICAqIGBbXCJlYXNlLW91dCBkdXJhdGlvbi0zMDBcIiwgXCJvcGFjaXR5LTEwMFwiLCBcIm9wYWNpdHktMFwiXWBcbiAgICovXG4gIG91dD86IFRyYW5zaXRpb247XG4gIC8qKiBUaGUgdHJhbnNpdGlvbiBkdXJhdGlvbiBpbiBtaWxsaXNlY29uZHMuICovXG4gIHRpbWU/OiBudW1iZXI7XG4gIC8qKiBXaGV0aGVyIHRvIGJsb2NrIFVJIGR1cmluZyB0cmFuc2l0aW9uLiBEZWZhdWx0cyBgdHJ1ZWAuICovXG4gIGJsb2NraW5nPzogYm9vbGVhbjtcbn07XG5cbi8vIE9wdGlvbnMgc3BlY2lmaWMgdG8gdGhlICd0cmFuc2l0aW9uJyBjb21tYW5kXG50eXBlIFRyYW5zaXRpb25Db21tYW5kT3B0cyA9IHtcbiAgLyoqIFRoZSB0cmFuc2l0aW9uIGR1cmF0aW9uIGluIG1pbGxpc2Vjb25kcy4gKi9cbiAgdGltZT86IG51bWJlcjtcbiAgLyoqIFdoZXRoZXIgdG8gYmxvY2sgVUkgZHVyaW5nIHRyYW5zaXRpb24uIERlZmF1bHRzIGB0cnVlYC4gKi9cbiAgYmxvY2tpbmc/OiBib29sZWFuO1xufTtcblxudHlwZSBQdXNoT3B0cyA9IHtcbiAgLyoqIERhdGEgdG8gYmUgbWVyZ2VkIGludG8gdGhlIGV2ZW50IHBheWxvYWQuICovXG4gIHZhbHVlPzogYW55O1xuICAvKiogRm9yIHRhcmdldGluZyBhIExpdmVDb21wb25lbnQgYnkgaXRzIElELCBhIGNvbXBvbmVudCBJRCAobnVtYmVyKSwgb3IgYSBDU1Mgc2VsZWN0b3Igc3RyaW5nLiAqL1xuICB0YXJnZXQ/OiBIVE1MRWxlbWVudCB8IG51bWJlciB8IHN0cmluZztcbiAgLyoqIEluZGljYXRlcyBpZiBhIHBhZ2UgbG9hZGluZyBzdGF0ZSBzaG91bGQgYmUgc2hvd24uICovXG4gIHBhZ2VfbG9hZGluZz86IGJvb2xlYW47XG4gIFtrZXk6IHN0cmluZ106IGFueTsgLy8gQWxsb3cgb3RoZXIgcHJvcGVydGllcyBsaWtlICdjaWQnLCAncmVkaXJlY3QnLCBldGMuXG59O1xuXG50eXBlIE5hdmlnYXRpb25PcHRzID0ge1xuICAvKiogV2hldGhlciB0byByZXBsYWNlIHRoZSBjdXJyZW50IGhpc3RvcnkgZW50cnkgaW5zdGVhZCBvZiBwdXNoaW5nIGEgbmV3IG9uZS4gKi9cbiAgcmVwbGFjZT86IGJvb2xlYW47XG59O1xuXG4vKipcbiAqIFJlcHJlc2VudHMgYWxsIHBvc3NpYmxlIEpTIGNvbW1hbmRzIHRoYXQgY2FuIGJlIGdlbmVyYXRlZCBieSB0aGUgZmFjdG9yeS5cbiAqIFRoaXMgaXMgdXNlZCBhcyBhIGJhc2UgZm9yIExpdmVTb2NrZXRKU0NvbW1hbmRzIGFuZCBIb29rSlNDb21tYW5kcy5cbiAqL1xuaW50ZXJmYWNlIEFsbEpTQ29tbWFuZHMge1xuICAvKipcbiAgICogRXhlY3V0ZXMgZW5jb2RlZCBKYXZhU2NyaXB0IGluIHRoZSBjb250ZXh0IG9mIHRoZSBlbGVtZW50LlxuICAgKiBUaGlzIHZlcnNpb24gaXMgZm9yIGdlbmVyYWwgdXNlIHZpYSBsaXZlU29ja2V0LmpzKCkuXG4gICAqXG4gICAqIEBwYXJhbSBlbCAtIFRoZSBlbGVtZW50IGluIHdob3NlIGNvbnRleHQgdG8gZXhlY3V0ZSB0aGUgSmF2YVNjcmlwdC5cbiAgICogQHBhcmFtIGVuY29kZWRKUyAtIFRoZSBlbmNvZGVkIEphdmFTY3JpcHQgc3RyaW5nIHRvIGV4ZWN1dGUuXG4gICAqL1xuICBleGVjKGVsOiBIVE1MRWxlbWVudCwgZW5jb2RlZEpTOiBzdHJpbmcpOiB2b2lkO1xuXG4gIC8qKlxuICAgKiBTaG93cyBhbiBlbGVtZW50LlxuICAgKlxuICAgKiBAcGFyYW0gZWwgLSBUaGUgZWxlbWVudCB0byBzaG93LlxuICAgKiBAcGFyYW0ge1Nob3dPcHRzfSBbb3B0cz17fV0gLSBPcHRpb25hbCBzZXR0aW5ncy5cbiAgICogICBBY2NlcHRzOiBgZGlzcGxheWAsIGB0cmFuc2l0aW9uYCwgYHRpbWVgLCBhbmQgYGJsb2NraW5nYC5cbiAgICovXG4gIHNob3coZWw6IEhUTUxFbGVtZW50LCBvcHRzPzogU2hvd09wdHMpOiB2b2lkO1xuXG4gIC8qKlxuICAgKiBIaWRlcyBhbiBlbGVtZW50LlxuICAgKlxuICAgKiBAcGFyYW0gZWwgLSBUaGUgZWxlbWVudCB0byBoaWRlLlxuICAgKiBAcGFyYW0gW29wdHM9e31dIC0gT3B0aW9uYWwgc2V0dGluZ3MuXG4gICAqICAgQWNjZXB0czogYHRyYW5zaXRpb25gLCBgdGltZWAsIGFuZCBgYmxvY2tpbmdgLlxuICAgKi9cbiAgaGlkZShlbDogSFRNTEVsZW1lbnQsIG9wdHM/OiBCYXNlT3B0cyk6IHZvaWQ7XG5cbiAgLyoqXG4gICAqIFRvZ2dsZXMgdGhlIHZpc2liaWxpdHkgb2YgYW4gZWxlbWVudC5cbiAgICpcbiAgICogQHBhcmFtIGVsIC0gVGhlIGVsZW1lbnQgdG8gdG9nZ2xlLlxuICAgKiBAcGFyYW0gW29wdHM9e31dIC0gT3B0aW9uYWwgc2V0dGluZ3MuXG4gICAqICAgQWNjZXB0czogYGRpc3BsYXlgLCBgaW5gLCBgb3V0YCwgYHRpbWVgLCBhbmQgYGJsb2NraW5nYC5cbiAgICovXG4gIHRvZ2dsZShlbDogSFRNTEVsZW1lbnQsIG9wdHM/OiBUb2dnbGVPcHRzKTogdm9pZDtcblxuICAvKipcbiAgICogQWRkcyBDU1MgY2xhc3NlcyB0byBhbiBlbGVtZW50LlxuICAgKlxuICAgKiBAcGFyYW0gZWwgLSBUaGUgZWxlbWVudCB0byBhZGQgY2xhc3NlcyB0by5cbiAgICogQHBhcmFtIG5hbWVzIC0gVGhlIGNsYXNzIG5hbWUocykgdG8gYWRkLlxuICAgKiBAcGFyYW0gW29wdHM9e31dIC0gT3B0aW9uYWwgc2V0dGluZ3MuXG4gICAqICAgQWNjZXB0czogYHRyYW5zaXRpb25gLCBgdGltZWAsIGFuZCBgYmxvY2tpbmdgLlxuICAgKi9cbiAgYWRkQ2xhc3MoZWw6IEhUTUxFbGVtZW50LCBuYW1lczogc3RyaW5nIHwgc3RyaW5nW10sIG9wdHM/OiBCYXNlT3B0cyk6IHZvaWQ7XG5cbiAgLyoqXG4gICAqIFJlbW92ZXMgQ1NTIGNsYXNzZXMgZnJvbSBhbiBlbGVtZW50LlxuICAgKlxuICAgKiBAcGFyYW0gZWwgLSBUaGUgZWxlbWVudCB0byByZW1vdmUgY2xhc3NlcyBmcm9tLlxuICAgKiBAcGFyYW0gbmFtZXMgLSBUaGUgY2xhc3MgbmFtZShzKSB0byByZW1vdmUuXG4gICAqIEBwYXJhbSBbb3B0cz17fV0gLSBPcHRpb25hbCBzZXR0aW5ncy5cbiAgICogICBBY2NlcHRzOiBgdHJhbnNpdGlvbmAsIGB0aW1lYCwgYW5kIGBibG9ja2luZ2AuXG4gICAqL1xuICByZW1vdmVDbGFzcyhlbDogSFRNTEVsZW1lbnQsIG5hbWVzOiBzdHJpbmcgfCBzdHJpbmdbXSwgb3B0cz86IEJhc2VPcHRzKTogdm9pZDtcblxuICAvKipcbiAgICogVG9nZ2xlcyBDU1MgY2xhc3NlcyBvbiBhbiBlbGVtZW50LlxuICAgKlxuICAgKiBAcGFyYW0gZWwgLSBUaGUgZWxlbWVudCB0byB0b2dnbGUgY2xhc3NlcyBvbi5cbiAgICogQHBhcmFtIG5hbWVzIC0gVGhlIGNsYXNzIG5hbWUocykgdG8gdG9nZ2xlLlxuICAgKiBAcGFyYW0gW29wdHM9e31dIC0gT3B0aW9uYWwgc2V0dGluZ3MuXG4gICAqICAgQWNjZXB0czogYHRyYW5zaXRpb25gLCBgdGltZWAsIGFuZCBgYmxvY2tpbmdgLlxuICAgKi9cbiAgdG9nZ2xlQ2xhc3MoZWw6IEhUTUxFbGVtZW50LCBuYW1lczogc3RyaW5nIHwgc3RyaW5nW10sIG9wdHM/OiBCYXNlT3B0cyk6IHZvaWQ7XG5cbiAgLyoqXG4gICAqIEFwcGxpZXMgYSBDU1MgdHJhbnNpdGlvbiB0byBhbiBlbGVtZW50LlxuICAgKlxuICAgKiBAcGFyYW0gZWwgLSBUaGUgZWxlbWVudCB0byBhcHBseSB0aGUgdHJhbnNpdGlvbiB0by5cbiAgICogQHBhcmFtIHRyYW5zaXRpb24gLSBUaGUgdHJhbnNpdGlvbiBjbGFzcyhlcykgdG8gYXBwbHkuXG4gICAqICAgQWNjZXB0cyBhIHN0cmluZyBvZiBjbGFzc2VzIHRvIGFwcGx5IHdoZW4gdHJhbnNpdGlvbmluZyBvclxuICAgKiAgIGEgMy10dXBsZSBjb250YWluaW5nIHRoZSB0cmFuc2l0aW9uIGNsYXNzLCB0aGUgY2xhc3MgdG8gYXBwbHlcbiAgICogICB0byBzdGFydCB0aGUgdHJhbnNpdGlvbiwgYW5kIHRoZSBlbmRpbmcgdHJhbnNpdGlvbiBjbGFzcywgc3VjaCBhczpcbiAgICpcbiAgICogICAgICAgW1wiZWFzZS1vdXQgZHVyYXRpb24tMzAwXCIsIFwib3BhY2l0eS0xMDBcIiwgXCJvcGFjaXR5LTBcIl1cbiAgICpcbiAgICogQHBhcmFtIFtvcHRzPXt9XSAtIE9wdGlvbmFsIHNldHRpbmdzIGZvciB0aW1pbmcgYW5kIGJsb2NraW5nIGJlaGF2aW9yLlxuICAgKiAgIEFjY2VwdHM6IGB0aW1lYCBhbmQgYGJsb2NraW5nYC5cbiAgICovXG4gIHRyYW5zaXRpb24oXG4gICAgZWw6IEhUTUxFbGVtZW50LFxuICAgIHRyYW5zaXRpb246IHN0cmluZyB8IHN0cmluZ1tdLFxuICAgIG9wdHM/OiBUcmFuc2l0aW9uQ29tbWFuZE9wdHMsXG4gICk6IHZvaWQ7XG5cbiAgLyoqXG4gICAqIFNldHMgYW4gYXR0cmlidXRlIG9uIGFuIGVsZW1lbnQuXG4gICAqXG4gICAqIEBwYXJhbSBlbCAtIFRoZSBlbGVtZW50IHRvIHNldCB0aGUgYXR0cmlidXRlIG9uLlxuICAgKiBAcGFyYW0gYXR0ciAtIFRoZSBhdHRyaWJ1dGUgbmFtZSB0byBzZXQuXG4gICAqIEBwYXJhbSB2YWwgLSBUaGUgdmFsdWUgdG8gc2V0IGZvciB0aGUgYXR0cmlidXRlLlxuICAgKi9cbiAgc2V0QXR0cmlidXRlKGVsOiBIVE1MRWxlbWVudCwgYXR0cjogc3RyaW5nLCB2YWw6IHN0cmluZyk6IHZvaWQ7XG5cbiAgLyoqXG4gICAqIFJlbW92ZXMgYW4gYXR0cmlidXRlIGZyb20gYW4gZWxlbWVudC5cbiAgICpcbiAgICogQHBhcmFtIGVsIC0gVGhlIGVsZW1lbnQgdG8gcmVtb3ZlIHRoZSBhdHRyaWJ1dGUgZnJvbS5cbiAgICogQHBhcmFtIGF0dHIgLSBUaGUgYXR0cmlidXRlIG5hbWUgdG8gcmVtb3ZlLlxuICAgKi9cbiAgcmVtb3ZlQXR0cmlidXRlKGVsOiBIVE1MRWxlbWVudCwgYXR0cjogc3RyaW5nKTogdm9pZDtcblxuICAvKipcbiAgICogVG9nZ2xlcyBhbiBhdHRyaWJ1dGUgb24gYW4gZWxlbWVudCBiZXR3ZWVuIHR3byB2YWx1ZXMuXG4gICAqXG4gICAqIEBwYXJhbSBlbCAtIFRoZSBlbGVtZW50IHRvIHRvZ2dsZSB0aGUgYXR0cmlidXRlIG9uLlxuICAgKiBAcGFyYW0gYXR0ciAtIFRoZSBhdHRyaWJ1dGUgbmFtZSB0byB0b2dnbGUuXG4gICAqIEBwYXJhbSB2YWwxIC0gVGhlIGZpcnN0IHZhbHVlIHRvIHRvZ2dsZSBiZXR3ZWVuLlxuICAgKiBAcGFyYW0gdmFsMiAtIFRoZSBzZWNvbmQgdmFsdWUgdG8gdG9nZ2xlIGJldHdlZW4uXG4gICAqL1xuICB0b2dnbGVBdHRyaWJ1dGUoXG4gICAgZWw6IEhUTUxFbGVtZW50LFxuICAgIGF0dHI6IHN0cmluZyxcbiAgICB2YWwxOiBzdHJpbmcsXG4gICAgdmFsMjogc3RyaW5nLFxuICApOiB2b2lkO1xuXG4gIC8qKlxuICAgKiBQdXNoZXMgYW4gZXZlbnQgdG8gdGhlIHNlcnZlci5cbiAgICpcbiAgICogQHBhcmFtIGVsIC0gQW4gZWxlbWVudCB0aGF0IGJlbG9uZ3MgdG8gdGhlIHRhcmdldCBMaXZlVmlldyAvIExpdmVDb21wb25lbnQgb3IgYSBjb21wb25lbnQgSUQuXG4gICAqICAgVG8gdGFyZ2V0IGEgTGl2ZUNvbXBvbmVudCBieSBpdHMgSUQsIHBhc3MgYSBzZXBhcmF0ZSBgdGFyZ2V0YCBpbiB0aGUgb3B0aW9ucy5cbiAgICogQHBhcmFtIHR5cGUgLSBUaGUgZXZlbnQgbmFtZSB0byBwdXNoLlxuICAgKiBAcGFyYW0gW29wdHM9e31dIC0gT3B0aW9uYWwgc2V0dGluZ3MuXG4gICAqICAgQWNjZXB0czogYHZhbHVlYCwgYHRhcmdldGAsIGBwYWdlX2xvYWRpbmdgLlxuICAgKi9cbiAgcHVzaChlbDogSFRNTEVsZW1lbnQsIHR5cGU6IHN0cmluZywgb3B0cz86IFB1c2hPcHRzKTogdm9pZDtcblxuICAvKipcbiAgICogU2VuZHMgYSBuYXZpZ2F0aW9uIGV2ZW50IHRvIHRoZSBzZXJ2ZXIgYW5kIHVwZGF0ZXMgdGhlIGJyb3dzZXIncyBwdXNoU3RhdGUgaGlzdG9yeS5cbiAgICpcbiAgICogQHBhcmFtIGhyZWYgLSBUaGUgVVJMIHRvIG5hdmlnYXRlIHRvLlxuICAgKiBAcGFyYW0gW29wdHM9e31dIC0gT3B0aW9uYWwgc2V0dGluZ3MuXG4gICAqICAgQWNjZXB0czogYHJlcGxhY2VgLlxuICAgKi9cbiAgbmF2aWdhdGUoaHJlZjogc3RyaW5nLCBvcHRzPzogTmF2aWdhdGlvbk9wdHMpOiB2b2lkO1xuXG4gIC8qKlxuICAgKiBTZW5kcyBhIHBhdGNoIGV2ZW50IHRvIHRoZSBzZXJ2ZXIgYW5kIHVwZGF0ZXMgdGhlIGJyb3dzZXIncyBwdXNoU3RhdGUgaGlzdG9yeS5cbiAgICpcbiAgICogQHBhcmFtIGhyZWYgLSBUaGUgVVJMIHRvIHBhdGNoIHRvLlxuICAgKiBAcGFyYW0gW29wdHM9e31dIC0gT3B0aW9uYWwgc2V0dGluZ3MuXG4gICAqICAgQWNjZXB0czogYHJlcGxhY2VgLlxuICAgKi9cbiAgcGF0Y2goaHJlZjogc3RyaW5nLCBvcHRzPzogTmF2aWdhdGlvbk9wdHMpOiB2b2lkO1xuXG4gIC8qKlxuICAgKiBNYXJrIGF0dHJpYnV0ZXMgYXMgaWdub3JlZCwgc2tpcHBpbmcgdGhlbSB3aGVuIHBhdGNoaW5nIHRoZSBET00uXG4gICAqXG4gICAqIEBwYXJhbSBlbCAtIFRoZSBlbGVtZW50IHRvIGlnbm9yZSBhdHRyaWJ1dGVzIG9uLlxuICAgKiBAcGFyYW0gYXR0cnMgLSBUaGUgYXR0cmlidXRlIG5hbWUgb3IgbmFtZXMgdG8gaWdub3JlLlxuICAgKi9cbiAgaWdub3JlQXR0cmlidXRlcyhlbDogSFRNTEVsZW1lbnQsIGF0dHJzOiBzdHJpbmcgfCBzdHJpbmdbXSk6IHZvaWQ7XG59XG5cbmV4cG9ydCBkZWZhdWx0IChcbiAgbGl2ZVNvY2tldDogTGl2ZVNvY2tldCxcbiAgZXZlbnRUeXBlOiBzdHJpbmcgfCBudWxsLFxuKTogQWxsSlNDb21tYW5kcyA9PiB7XG4gIHJldHVybiB7XG4gICAgZXhlYyhlbCwgZW5jb2RlZEpTKSB7XG4gICAgICBsaXZlU29ja2V0LmV4ZWNKUyhlbCwgZW5jb2RlZEpTLCBldmVudFR5cGUpO1xuICAgIH0sXG4gICAgc2hvdyhlbCwgb3B0cyA9IHt9KSB7XG4gICAgICBjb25zdCBvd25lciA9IGxpdmVTb2NrZXQub3duZXIoZWwpO1xuICAgICAgSlMuc2hvdyhcbiAgICAgICAgZXZlbnRUeXBlLFxuICAgICAgICBvd25lcixcbiAgICAgICAgZWwsXG4gICAgICAgIG9wdHMuZGlzcGxheSxcbiAgICAgICAgSlMudHJhbnNpdGlvbkNsYXNzZXMob3B0cy50cmFuc2l0aW9uKSxcbiAgICAgICAgb3B0cy50aW1lLFxuICAgICAgICBvcHRzLmJsb2NraW5nLFxuICAgICAgKTtcbiAgICB9LFxuICAgIGhpZGUoZWwsIG9wdHMgPSB7fSkge1xuICAgICAgY29uc3Qgb3duZXIgPSBsaXZlU29ja2V0Lm93bmVyKGVsKTtcbiAgICAgIEpTLmhpZGUoXG4gICAgICAgIGV2ZW50VHlwZSxcbiAgICAgICAgb3duZXIsXG4gICAgICAgIGVsLFxuICAgICAgICBudWxsLFxuICAgICAgICBKUy50cmFuc2l0aW9uQ2xhc3NlcyhvcHRzLnRyYW5zaXRpb24pLFxuICAgICAgICBvcHRzLnRpbWUsXG4gICAgICAgIG9wdHMuYmxvY2tpbmcsXG4gICAgICApO1xuICAgIH0sXG4gICAgdG9nZ2xlKGVsLCBvcHRzID0ge30pIHtcbiAgICAgIGNvbnN0IG93bmVyID0gbGl2ZVNvY2tldC5vd25lcihlbCk7XG4gICAgICBjb25zdCBpblRyYW5zaXRpb24gPSBKUy50cmFuc2l0aW9uQ2xhc3NlcyhvcHRzLmluKTtcbiAgICAgIGNvbnN0IG91dFRyYW5zaXRpb24gPSBKUy50cmFuc2l0aW9uQ2xhc3NlcyhvcHRzLm91dCk7XG4gICAgICBKUy50b2dnbGUoXG4gICAgICAgIGV2ZW50VHlwZSxcbiAgICAgICAgb3duZXIsXG4gICAgICAgIGVsLFxuICAgICAgICBvcHRzLmRpc3BsYXksXG4gICAgICAgIGluVHJhbnNpdGlvbixcbiAgICAgICAgb3V0VHJhbnNpdGlvbixcbiAgICAgICAgb3B0cy50aW1lLFxuICAgICAgICBvcHRzLmJsb2NraW5nLFxuICAgICAgKTtcbiAgICB9LFxuICAgIGFkZENsYXNzKGVsLCBuYW1lcywgb3B0cyA9IHt9KSB7XG4gICAgICBjb25zdCBjbGFzc05hbWVzID0gQXJyYXkuaXNBcnJheShuYW1lcykgPyBuYW1lcyA6IG5hbWVzLnNwbGl0KFwiIFwiKTtcbiAgICAgIGNvbnN0IG93bmVyID0gbGl2ZVNvY2tldC5vd25lcihlbCk7XG4gICAgICBKUy5hZGRPclJlbW92ZUNsYXNzZXMoXG4gICAgICAgIGVsLFxuICAgICAgICBjbGFzc05hbWVzLFxuICAgICAgICBbXSxcbiAgICAgICAgSlMudHJhbnNpdGlvbkNsYXNzZXMob3B0cy50cmFuc2l0aW9uKSxcbiAgICAgICAgb3B0cy50aW1lLFxuICAgICAgICBvd25lcixcbiAgICAgICAgb3B0cy5ibG9ja2luZyxcbiAgICAgICk7XG4gICAgfSxcbiAgICByZW1vdmVDbGFzcyhlbCwgbmFtZXMsIG9wdHMgPSB7fSkge1xuICAgICAgY29uc3QgY2xhc3NOYW1lcyA9IEFycmF5LmlzQXJyYXkobmFtZXMpID8gbmFtZXMgOiBuYW1lcy5zcGxpdChcIiBcIik7XG4gICAgICBjb25zdCBvd25lciA9IGxpdmVTb2NrZXQub3duZXIoZWwpO1xuICAgICAgSlMuYWRkT3JSZW1vdmVDbGFzc2VzKFxuICAgICAgICBlbCxcbiAgICAgICAgW10sXG4gICAgICAgIGNsYXNzTmFtZXMsXG4gICAgICAgIEpTLnRyYW5zaXRpb25DbGFzc2VzKG9wdHMudHJhbnNpdGlvbiksXG4gICAgICAgIG9wdHMudGltZSxcbiAgICAgICAgb3duZXIsXG4gICAgICAgIG9wdHMuYmxvY2tpbmcsXG4gICAgICApO1xuICAgIH0sXG4gICAgdG9nZ2xlQ2xhc3MoZWwsIG5hbWVzLCBvcHRzID0ge30pIHtcbiAgICAgIGNvbnN0IGNsYXNzTmFtZXMgPSBBcnJheS5pc0FycmF5KG5hbWVzKSA/IG5hbWVzIDogbmFtZXMuc3BsaXQoXCIgXCIpO1xuICAgICAgY29uc3Qgb3duZXIgPSBsaXZlU29ja2V0Lm93bmVyKGVsKTtcbiAgICAgIEpTLnRvZ2dsZUNsYXNzZXMoXG4gICAgICAgIGVsLFxuICAgICAgICBjbGFzc05hbWVzLFxuICAgICAgICBKUy50cmFuc2l0aW9uQ2xhc3NlcyhvcHRzLnRyYW5zaXRpb24pLFxuICAgICAgICBvcHRzLnRpbWUsXG4gICAgICAgIG93bmVyLFxuICAgICAgICBvcHRzLmJsb2NraW5nLFxuICAgICAgKTtcbiAgICB9LFxuICAgIHRyYW5zaXRpb24oZWwsIHRyYW5zaXRpb24sIG9wdHMgPSB7fSkge1xuICAgICAgY29uc3Qgb3duZXIgPSBsaXZlU29ja2V0Lm93bmVyKGVsKTtcbiAgICAgIEpTLmFkZE9yUmVtb3ZlQ2xhc3NlcyhcbiAgICAgICAgZWwsXG4gICAgICAgIFtdLFxuICAgICAgICBbXSxcbiAgICAgICAgSlMudHJhbnNpdGlvbkNsYXNzZXModHJhbnNpdGlvbiksXG4gICAgICAgIG9wdHMudGltZSxcbiAgICAgICAgb3duZXIsXG4gICAgICAgIG9wdHMuYmxvY2tpbmcsXG4gICAgICApO1xuICAgIH0sXG4gICAgc2V0QXR0cmlidXRlKGVsLCBhdHRyLCB2YWwpIHtcbiAgICAgIEpTLnNldE9yUmVtb3ZlQXR0cnMoZWwsIFtbYXR0ciwgdmFsXV0sIFtdKTtcbiAgICB9LFxuICAgIHJlbW92ZUF0dHJpYnV0ZShlbCwgYXR0cikge1xuICAgICAgSlMuc2V0T3JSZW1vdmVBdHRycyhlbCwgW10sIFthdHRyXSk7XG4gICAgfSxcbiAgICB0b2dnbGVBdHRyaWJ1dGUoZWwsIGF0dHIsIHZhbDEsIHZhbDIpIHtcbiAgICAgIEpTLnRvZ2dsZUF0dHIoZWwsIGF0dHIsIHZhbDEsIHZhbDIpO1xuICAgIH0sXG4gICAgcHVzaChlbCwgdHlwZSwgb3B0cyA9IHt9KSB7XG4gICAgICBsaXZlU29ja2V0LndpdGhpbk93bmVycyhlbCwgKHZpZXcpID0+IHtcbiAgICAgICAgY29uc3QgZGF0YSA9IG9wdHMudmFsdWUgfHwge307XG4gICAgICAgIGRlbGV0ZSBvcHRzLnZhbHVlO1xuICAgICAgICBsZXQgZSA9IG5ldyBDdXN0b21FdmVudChcInBoeDpleGVjXCIsIHsgZGV0YWlsOiB7IHNvdXJjZUVsZW1lbnQ6IGVsIH0gfSk7XG4gICAgICAgIEpTLmV4ZWMoZSwgZXZlbnRUeXBlLCB0eXBlLCB2aWV3LCBlbCwgW1wicHVzaFwiLCB7IGRhdGEsIC4uLm9wdHMgfV0pO1xuICAgICAgfSk7XG4gICAgfSxcbiAgICBuYXZpZ2F0ZShocmVmLCBvcHRzID0ge30pIHtcbiAgICAgIGNvbnN0IGN1c3RvbUV2ZW50ID0gbmV3IEN1c3RvbUV2ZW50KFwicGh4OmV4ZWNcIik7XG4gICAgICBsaXZlU29ja2V0Lmhpc3RvcnlSZWRpcmVjdChcbiAgICAgICAgY3VzdG9tRXZlbnQsXG4gICAgICAgIGhyZWYsXG4gICAgICAgIG9wdHMucmVwbGFjZSA/IFwicmVwbGFjZVwiIDogXCJwdXNoXCIsXG4gICAgICAgIG51bGwsXG4gICAgICAgIG51bGwsXG4gICAgICApO1xuICAgIH0sXG4gICAgcGF0Y2goaHJlZiwgb3B0cyA9IHt9KSB7XG4gICAgICBjb25zdCBjdXN0b21FdmVudCA9IG5ldyBDdXN0b21FdmVudChcInBoeDpleGVjXCIpO1xuICAgICAgbGl2ZVNvY2tldC5wdXNoSGlzdG9yeVBhdGNoKFxuICAgICAgICBjdXN0b21FdmVudCxcbiAgICAgICAgaHJlZixcbiAgICAgICAgb3B0cy5yZXBsYWNlID8gXCJyZXBsYWNlXCIgOiBcInB1c2hcIixcbiAgICAgICAgbnVsbCxcbiAgICAgICk7XG4gICAgfSxcbiAgICBpZ25vcmVBdHRyaWJ1dGVzKGVsLCBhdHRycykge1xuICAgICAgSlMuaWdub3JlQXR0cnMoZWwsIEFycmF5LmlzQXJyYXkoYXR0cnMpID8gYXR0cnMgOiBbYXR0cnNdKTtcbiAgICB9LFxuICB9O1xufTtcblxuLyoqXG4gKiBKU0NvbW1hbmRzIGZvciB1c2Ugd2l0aCBgbGl2ZVNvY2tldC5qcygpYC5cbiAqIEluY2x1ZGVzIHRoZSBnZW5lcmFsIGBleGVjYCBjb21tYW5kIHRoYXQgcmVxdWlyZXMgYW4gZWxlbWVudC5cbiAqL1xuZXhwb3J0IHR5cGUgTGl2ZVNvY2tldEpTQ29tbWFuZHMgPSBBbGxKU0NvbW1hbmRzO1xuXG4vKipcbiAqIEpTQ29tbWFuZHMgZm9yIHVzZSB3aXRoaW4gYSBIb29rLlxuICogVGhlIGBleGVjYCBjb21tYW5kIGlzIHRhaWxvcmVkIGZvciBob29rcywgbm90IHJlcXVpcmluZyBhbiBleHBsaWNpdCBlbGVtZW50LlxuICovXG5leHBvcnQgaW50ZXJmYWNlIEhvb2tKU0NvbW1hbmRzIGV4dGVuZHMgT21pdDxBbGxKU0NvbW1hbmRzLCBcImV4ZWNcIj4ge1xuICAvKipcbiAgICogRXhlY3V0ZXMgZW5jb2RlZCBKYXZhU2NyaXB0IGluIHRoZSBjb250ZXh0IG9mIHRoZSBob29rJ3MgZWxlbWVudC5cbiAgICpcbiAgICogQHBhcmFtIHtzdHJpbmd9IGVuY29kZWRKUyAtIFRoZSBlbmNvZGVkIEphdmFTY3JpcHQgc3RyaW5nIHRvIGV4ZWN1dGUuXG4gICAqL1xuICBleGVjKGVuY29kZWRKUzogc3RyaW5nKTogdm9pZDtcbn1cbiIsICJpbXBvcnQganNDb21tYW5kcywgeyBIb29rSlNDb21tYW5kcyB9IGZyb20gXCIuL2pzX2NvbW1hbmRzXCI7XG5pbXBvcnQgRE9NIGZyb20gXCIuL2RvbVwiO1xuaW1wb3J0IExpdmVTb2NrZXQgZnJvbSBcIi4vbGl2ZV9zb2NrZXRcIjtcbmltcG9ydCBWaWV3IGZyb20gXCIuL3ZpZXdcIjtcblxuY29uc3QgSE9PS19JRCA9IFwiaG9va0lkXCI7XG5sZXQgdmlld0hvb2tJRCA9IDE7XG5cbmV4cG9ydCB0eXBlIE9uUmVwbHkgPSAocmVwbHk6IGFueSwgcmVmOiBudW1iZXIpID0+IGFueTtcbmV4cG9ydCB0eXBlIENhbGxiYWNrUmVmID0geyBldmVudDogc3RyaW5nOyBjYWxsYmFjazogKHBheWxvYWQ6IGFueSkgPT4gYW55IH07XG5cbmV4cG9ydCB0eXBlIFBoeFRhcmdldCA9IHN0cmluZyB8IG51bWJlciB8IEhUTUxFbGVtZW50O1xuXG5leHBvcnQgaW50ZXJmYWNlIEhvb2tJbnRlcmZhY2Uge1xuICAvKipcbiAgICogVGhlIERPTSBlbGVtZW50IHRoYXQgdGhlIGhvb2sgaXMgYXR0YWNoZWQgdG8uXG4gICAqL1xuICBlbDogSFRNTEVsZW1lbnQ7XG5cbiAgLyoqXG4gICAqIFRoZSBMaXZlU29ja2V0IGluc3RhbmNlIHRoYXQgdGhlIGhvb2sgaXMgYXR0YWNoZWQgdG8uXG4gICAqL1xuICBsaXZlU29ja2V0OiBMaXZlU29ja2V0O1xuXG4gIC8qKlxuICAgKiBUaGUgbW91bnRlZCBjYWxsYmFjay5cbiAgICpcbiAgICogQ2FsbGVkIHdoZW4gdGhlIGVsZW1lbnQgaGFzIGJlZW4gYWRkZWQgdG8gdGhlIERPTSBhbmQgaXRzIHNlcnZlciBMaXZlVmlldyBoYXMgZmluaXNoZWQgbW91bnRpbmcuXG4gICAqL1xuICBtb3VudGVkPzogKCkgPT4gdm9pZDtcblxuICAvKipcbiAgICogVGhlIGJlZm9yZVVwZGF0ZSBjYWxsYmFjay5cbiAgICpcbiAgICogQ2FsbGVkIHdoZW4gdGhlIGVsZW1lbnQgaXMgYWJvdXQgdG8gYmUgdXBkYXRlZCBpbiB0aGUgRE9NLlxuICAgKiBOb3RlOiBhbnkgY2FsbCBoZXJlIG11c3QgYmUgc3luY2hyb25vdXMgYXMgdGhlIG9wZXJhdGlvbiBjYW5ub3QgYmUgZGVmZXJyZWQgb3IgY2FuY2VsbGVkLlxuICAgKi9cbiAgYmVmb3JlVXBkYXRlPzogKCkgPT4gdm9pZDtcblxuICAvKipcbiAgICogVGhlIHVwZGF0ZWQgY2FsbGJhY2suXG4gICAqXG4gICAqIENhbGxlZCB3aGVuIHRoZSBlbGVtZW50IGhhcyBiZWVuIHVwZGF0ZWQgaW4gdGhlIERPTSBieSB0aGUgc2VydmVyXG4gICAqL1xuICB1cGRhdGVkPzogKCkgPT4gdm9pZDtcblxuICAvKipcbiAgICogVGhlIGRlc3Ryb3llZCBjYWxsYmFjay5cbiAgICpcbiAgICogQ2FsbGVkIHdoZW4gdGhlIGVsZW1lbnQgaGFzIGJlZW4gcmVtb3ZlZCBmcm9tIHRoZSBwYWdlLCBlaXRoZXIgYnkgYSBwYXJlbnQgdXBkYXRlLCBvciBieSB0aGUgcGFyZW50IGJlaW5nIHJlbW92ZWQgZW50aXJlbHlcbiAgICovXG4gIGRlc3Ryb3llZD86ICgpID0+IHZvaWQ7XG5cbiAgLyoqXG4gICAqIFRoZSBkaXNjb25uZWN0ZWQgY2FsbGJhY2suXG4gICAqXG4gICAqIENhbGxlZCB3aGVuIHRoZSBlbGVtZW50J3MgcGFyZW50IExpdmVWaWV3IGhhcyBkaXNjb25uZWN0ZWQgZnJvbSB0aGUgc2VydmVyLlxuICAgKi9cbiAgZGlzY29ubmVjdGVkPzogKCkgPT4gdm9pZDtcblxuICAvKipcbiAgICogVGhlIHJlY29ubmVjdGVkIGNhbGxiYWNrLlxuICAgKlxuICAgKiBDYWxsZWQgd2hlbiB0aGUgZWxlbWVudCdzIHBhcmVudCBMaXZlVmlldyBoYXMgcmVjb25uZWN0ZWQgdG8gdGhlIHNlcnZlci5cbiAgICovXG4gIHJlY29ubmVjdGVkPzogKCkgPT4gdm9pZDtcblxuICAvKipcbiAgICogUmV0dXJucyBhbiBvYmplY3Qgd2l0aCBtZXRob2RzIHRvIG1hbmlwbHVhdGUgdGhlIERPTSBhbmQgZXhlY3V0ZSBKYXZhU2NyaXB0LlxuICAgKiBUaGUgYXBwbGllZCBjaGFuZ2VzIGludGVncmF0ZSB3aXRoIHNlcnZlciBET00gcGF0Y2hpbmcuXG4gICAqL1xuICBqcygpOiBIb29rSlNDb21tYW5kcztcblxuICAvKipcbiAgICogUHVzaGVzIGFuIGV2ZW50IHRvIHRoZSBzZXJ2ZXIuXG4gICAqXG4gICAqIEBwYXJhbSBldmVudCAtIFRoZSBldmVudCBuYW1lLlxuICAgKiBAcGFyYW0gW3BheWxvYWRdIC0gVGhlIHBheWxvYWQgdG8gc2VuZCB0byB0aGUgc2VydmVyLiBEZWZhdWx0cyB0byBhbiBlbXB0eSBvYmplY3QuXG4gICAqIEBwYXJhbSBbb25SZXBseV0gLSBBIGNhbGxiYWNrIHRvIGhhbmRsZSB0aGUgc2VydmVyJ3MgcmVwbHkuXG4gICAqXG4gICAqIFdoZW4gb25SZXBseSBpcyBub3QgcHJvdmlkZWQsIHRoZSBtZXRob2QgcmV0dXJucyBhIFByb21pc2UgdGhhdFxuICAgKiBXaGVuIG9uUmVwbHkgaXMgcHJvdmlkZWQsIHRoZSBtZXRob2QgcmV0dXJucyB2b2lkLlxuICAgKi9cbiAgcHVzaEV2ZW50KGV2ZW50OiBzdHJpbmcsIHBheWxvYWQ6IGFueSwgb25SZXBseTogT25SZXBseSk6IHZvaWQ7XG4gIHB1c2hFdmVudChldmVudDogc3RyaW5nLCBwYXlsb2FkPzogYW55KTogUHJvbWlzZTxhbnk+O1xuXG4gIC8qKlxuICAgKiBQdXNoZWQgYSB0YXJnZXRlZCBldmVudCB0byB0aGUgc2VydmVyLlxuICAgKlxuICAgKiBJdCBzZW5kcyB0aGUgZXZlbnQgdG8gdGhlIExpdmVDb21wb25lbnQgb3IgTGl2ZVZpZXcgdGhlIGBzZWxlY3Rvck9yVGFyZ2V0YCBpcyBkZWZpbmVkIGluLFxuICAgKiB3aGVyZSBpdHMgdmFsdWUgY2FuIGJlIGVpdGhlciBhIHF1ZXJ5IHNlbGVjdG9yLCBhbiBhY3R1YWwgRE9NIGVsZW1lbnQsIG9yIGEgQ0lEIChjb21wb25lbnQgaWQpXG4gICAqIHJldHVybmVkIGJ5IHRoZSBgQG15c2VsZmAgYXNzaWduLlxuICAgKlxuICAgKiBJZiB0aGUgcXVlcnkgc2VsZWN0b3IgcmV0dXJucyBtb3JlIHRoYW4gb25lIGVsZW1lbnQgaXQgd2lsbCBzZW5kIHRoZSBldmVudCB0byBhbGwgb2YgdGhlbSxcbiAgICogZXZlbiBpZiBhbGwgdGhlIGVsZW1lbnRzIGFyZSBpbiB0aGUgc2FtZSBMaXZlQ29tcG9uZW50IG9yIExpdmVWaWV3LiBCZWNhdXNlIG9mIHRoaXMsXG4gICAqIGlmIG5vIGNhbGxiYWNrIGlzIHBhc3NlZCwgYSBwcm9taXNlIGlzIHJldHVybmVkIHRoYXQgbWF0Y2hlcyB0aGUgcmV0dXJuIHZhbHVlIG9mXG4gICAqIFtgUHJvbWlzZS5hbGxTZXR0bGVkKClgXShodHRwczovL2RldmVsb3Blci5tb3ppbGxhLm9yZy9lbi1VUy9kb2NzL1dlYi9KYXZhU2NyaXB0L1JlZmVyZW5jZS9HbG9iYWxfT2JqZWN0cy9Qcm9taXNlL2FsbFNldHRsZWQjcmV0dXJuX3ZhbHVlKS5cbiAgICogSW5kaXZpZHVhbCBmdWxmaWxsZWQgdmFsdWVzIGFyZSBvZiB0aGUgZm9ybWF0IGB7IHJlcGx5LCByZWYgfWAsIHdoZXJlIGByZXBseWAgaXMgdGhlIHNlcnZlcidzIHJlcGx5LlxuICAgKlxuICAgKiBAcGFyYW0gc2VsZWN0b3JPclRhcmdldCAtIFRoZSBzZWxlY3RvciwgZWxlbWVudCwgb3IgQ0lEIHRvIHRhcmdldC5cbiAgICogQHBhcmFtIGV2ZW50IC0gVGhlIGV2ZW50IG5hbWUuXG4gICAqIEBwYXJhbSBbcGF5bG9hZF0gLSBUaGUgcGF5bG9hZCB0byBzZW5kIHRvIHRoZSBzZXJ2ZXIuIERlZmF1bHRzIHRvIGFuIGVtcHR5IG9iamVjdC5cbiAgICogQHBhcmFtIFtvblJlcGx5XSAtIEEgY2FsbGJhY2sgdG8gaGFuZGxlIHRoZSBzZXJ2ZXIncyByZXBseS5cbiAgICpcbiAgICogV2hlbiBvblJlcGx5IGlzIG5vdCBwcm92aWRlZCwgdGhlIG1ldGhvZCByZXR1cm5zIGEgUHJvbWlzZS5cbiAgICogV2hlbiBvblJlcGx5IGlzIHByb3ZpZGVkLCB0aGUgbWV0aG9kIHJldHVybnMgdm9pZC5cbiAgICovXG4gIHB1c2hFdmVudFRvKFxuICAgIHNlbGVjdG9yT3JUYXJnZXQ6IFBoeFRhcmdldCxcbiAgICBldmVudDogc3RyaW5nLFxuICAgIHBheWxvYWQ6IG9iamVjdCxcbiAgICBvblJlcGx5OiBPblJlcGx5LFxuICApOiB2b2lkO1xuICBwdXNoRXZlbnRUbyhcbiAgICBzZWxlY3Rvck9yVGFyZ2V0OiBQaHhUYXJnZXQsXG4gICAgZXZlbnQ6IHN0cmluZyxcbiAgICBwYXlsb2FkPzogb2JqZWN0LFxuICApOiBQcm9taXNlPFByb21pc2VTZXR0bGVkUmVzdWx0PHsgcmVwbHk6IGFueTsgcmVmOiBudW1iZXIgfT5bXT47XG5cbiAgLyoqXG4gICAqIEFsbG93cyB0byByZWdpc3RlciBhIGNhbGxiYWNrIHRvIGJlIGNhbGxlZCB3aGVuIGFuIGV2ZW50IGlzIHJlY2VpdmVkIGZyb20gdGhlIHNlcnZlci5cbiAgICpcbiAgICogVGhpcyBpcyB1c2VkIHRvIGhhbmRsZSBgcHVzaEV2ZW50YCBjYWxscyBmcm9tIHRoZSBzZXJ2ZXIuIFRoZSBjYWxsYmFjayBpcyBjYWxsZWQgd2l0aCB0aGUgcGF5bG9hZCBmcm9tIHRoZSBzZXJ2ZXIuXG4gICAqXG4gICAqIEBwYXJhbSBldmVudCAtIFRoZSBldmVudCBuYW1lLlxuICAgKiBAcGFyYW0gY2FsbGJhY2sgLSBUaGUgY2FsbGJhY2sgdG8gY2FsbCB3aGVuIHRoZSBldmVudCBpcyByZWNlaXZlZC5cbiAgICpcbiAgICogQHJldHVybnMgQSByZWZlcmVuY2UgdG8gdGhlIGNhbGxiYWNrLCB3aGljaCBjYW4gYmUgdXNlZCBpbiBgcmVtb3ZlSGFuZGxlRXZlbnRgIHRvIHJlbW92ZSB0aGUgY2FsbGJhY2suXG4gICAqL1xuICBoYW5kbGVFdmVudChldmVudDogc3RyaW5nLCBjYWxsYmFjazogKHBheWxvYWQ6IGFueSkgPT4gYW55KTogQ2FsbGJhY2tSZWY7XG5cbiAgLyoqXG4gICAqIFJlbW92ZXMgYSBjYWxsYmFjayByZWdpc3RlcmVkIHdpdGggYGhhbmRsZUV2ZW50YC5cbiAgICpcbiAgICogQHBhcmFtIGNhbGxiYWNrUmVmIC0gVGhlIHJlZmVyZW5jZSB0byB0aGUgY2FsbGJhY2sgdG8gcmVtb3ZlLlxuICAgKi9cbiAgcmVtb3ZlSGFuZGxlRXZlbnQocmVmOiBDYWxsYmFja1JlZik6IHZvaWQ7XG5cbiAgLyoqXG4gICAqIEFsbG93cyB0byB0cmlnZ2VyIGEgbGl2ZSBmaWxlIHVwbG9hZC5cbiAgICpcbiAgICogQHBhcmFtIG5hbWUgLSBUaGUgdXBsb2FkIG5hbWUgY29ycmVzcG9uZGluZyB0byB0aGUgYFBob2VuaXguTGl2ZVZpZXcuYWxsb3dfdXBsb2FkLzNgIGNhbGwuXG4gICAqIEBwYXJhbSBmaWxlcyAtIFRoZSBmaWxlcyB0byB1cGxvYWQuXG4gICAqL1xuICB1cGxvYWQobmFtZTogYW55LCBmaWxlczogYW55KTogYW55O1xuXG4gIC8qKlxuICAgKiBBbGxvd3MgdG8gdHJpZ2dlciBhIGxpdmUgZmlsZSB1cGxvYWQgdG8gYSBzcGVjaWZpYyB0YXJnZXQuXG4gICAqXG4gICAqIEBwYXJhbSBzZWxlY3Rvck9yVGFyZ2V0IC0gVGhlIHRhcmdldCB0byB1cGxvYWQgdGhlIGZpbGVzIHRvLlxuICAgKiBAcGFyYW0gbmFtZSAtIFRoZSB1cGxvYWQgbmFtZSBjb3JyZXNwb25kaW5nIHRvIHRoZSBgUGhvZW5peC5MaXZlVmlldy5hbGxvd191cGxvYWQvM2AgY2FsbC5cbiAgICogQHBhcmFtIGZpbGVzIC0gVGhlIGZpbGVzIHRvIHVwbG9hZC5cbiAgICovXG4gIHVwbG9hZFRvKHNlbGVjdG9yT3JUYXJnZXQ6IFBoeFRhcmdldCwgbmFtZTogYW55LCBmaWxlczogYW55KTogYW55O1xuXG4gIC8vIGFsbG93IHVua25vd24gbWV0aG9kcywgYXMgcGVvcGxlIGNhbiBkZWZpbmUgdGhlbSBpbiB0aGVpciBob29rc1xuICBba2V5OiBQcm9wZXJ0eUtleV06IGFueTtcbn1cblxuLy8gYmFzZWQgb24gaHR0cHM6Ly9naXRodWIuY29tL0RlZmluaXRlbHlUeXBlZC9EZWZpbml0ZWx5VHlwZWQvYmxvYi9mYWMxYWE3NWFjZGRkYmY0ZjFhOTVlOThlZTIyOTdiNTRjZTRiNGM5L3R5cGVzL3Bob2VuaXhfbGl2ZV92aWV3L2hvb2tzLmQudHMjTDI2XG4vLyBsaWNlbnNlZCB1bmRlciBNSVRcbmV4cG9ydCBpbnRlcmZhY2UgSG9vazxUID0gb2JqZWN0PiB7XG4gIC8qKlxuICAgKiBUaGUgbW91bnRlZCBjYWxsYmFjay5cbiAgICpcbiAgICogQ2FsbGVkIHdoZW4gdGhlIGVsZW1lbnQgaGFzIGJlZW4gYWRkZWQgdG8gdGhlIERPTSBhbmQgaXRzIHNlcnZlciBMaXZlVmlldyBoYXMgZmluaXNoZWQgbW91bnRpbmcuXG4gICAqL1xuICBtb3VudGVkPzogKHRoaXM6IFQgJiBIb29rSW50ZXJmYWNlKSA9PiB2b2lkO1xuXG4gIC8qKlxuICAgKiBUaGUgYmVmb3JlVXBkYXRlIGNhbGxiYWNrLlxuICAgKlxuICAgKiBDYWxsZWQgd2hlbiB0aGUgZWxlbWVudCBpcyBhYm91dCB0byBiZSB1cGRhdGVkIGluIHRoZSBET00uXG4gICAqIE5vdGU6IGFueSBjYWxsIGhlcmUgbXVzdCBiZSBzeW5jaHJvbm91cyBhcyB0aGUgb3BlcmF0aW9uIGNhbm5vdCBiZSBkZWZlcnJlZCBvciBjYW5jZWxsZWQuXG4gICAqL1xuICBiZWZvcmVVcGRhdGU/OiAodGhpczogVCAmIEhvb2tJbnRlcmZhY2UpID0+IHZvaWQ7XG5cbiAgLyoqXG4gICAqIFRoZSB1cGRhdGVkIGNhbGxiYWNrLlxuICAgKlxuICAgKiBDYWxsZWQgd2hlbiB0aGUgZWxlbWVudCBoYXMgYmVlbiB1cGRhdGVkIGluIHRoZSBET00gYnkgdGhlIHNlcnZlclxuICAgKi9cbiAgdXBkYXRlZD86ICh0aGlzOiBUICYgSG9va0ludGVyZmFjZSkgPT4gdm9pZDtcblxuICAvKipcbiAgICogVGhlIGRlc3Ryb3llZCBjYWxsYmFjay5cbiAgICpcbiAgICogQ2FsbGVkIHdoZW4gdGhlIGVsZW1lbnQgaGFzIGJlZW4gcmVtb3ZlZCBmcm9tIHRoZSBwYWdlLCBlaXRoZXIgYnkgYSBwYXJlbnQgdXBkYXRlLCBvciBieSB0aGUgcGFyZW50IGJlaW5nIHJlbW92ZWQgZW50aXJlbHlcbiAgICovXG4gIGRlc3Ryb3llZD86ICh0aGlzOiBUICYgSG9va0ludGVyZmFjZSkgPT4gdm9pZDtcblxuICAvKipcbiAgICogVGhlIGRpc2Nvbm5lY3RlZCBjYWxsYmFjay5cbiAgICpcbiAgICogQ2FsbGVkIHdoZW4gdGhlIGVsZW1lbnQncyBwYXJlbnQgTGl2ZVZpZXcgaGFzIGRpc2Nvbm5lY3RlZCBmcm9tIHRoZSBzZXJ2ZXIuXG4gICAqL1xuICBkaXNjb25uZWN0ZWQ/OiAodGhpczogVCAmIEhvb2tJbnRlcmZhY2UpID0+IHZvaWQ7XG5cbiAgLyoqXG4gICAqIFRoZSByZWNvbm5lY3RlZCBjYWxsYmFjay5cbiAgICpcbiAgICogQ2FsbGVkIHdoZW4gdGhlIGVsZW1lbnQncyBwYXJlbnQgTGl2ZVZpZXcgaGFzIHJlY29ubmVjdGVkIHRvIHRoZSBzZXJ2ZXIuXG4gICAqL1xuICByZWNvbm5lY3RlZD86ICh0aGlzOiBUICYgSG9va0ludGVyZmFjZSkgPT4gdm9pZDtcblxuICAvLyBBbGxvdyBjdXN0b20gbWV0aG9kcyB3aXRoIGFueSBzaWduYXR1cmUgYW5kIGN1c3RvbSBwcm9wZXJ0aWVzXG4gIFtrZXk6IFByb3BlcnR5S2V5XTogYW55O1xufVxuXG4vKipcbiAqIEJhc2UgY2xhc3MgZm9yIExpdmVWaWV3IGhvb2tzLiBVc2VycyBleHRlbmQgdGhpcyBjbGFzcyB0byBkZWZpbmUgdGhlaXIgaG9va3MuXG4gKlxuICogRXhhbXBsZTpcbiAqIGBgYHR5cGVzY3JpcHRcbiAqIGNsYXNzIE15Q3VzdG9tSG9vayBleHRlbmRzIFZpZXdIb29rIHtcbiAqICAgbXlTdGF0ZSA9IFwiaW5pdGlhbFwiO1xuICpcbiAqICAgbW91bnRlZCgpIHtcbiAqICAgICBjb25zb2xlLmxvZyhcIkhvb2sgbW91bnRlZCBvbiBlbGVtZW50OlwiLCB0aGlzLmVsKTtcbiAqICAgICB0aGlzLmVsLmFkZEV2ZW50TGlzdGVuZXIoXCJjbGlja1wiLCAoKSA9PiB7XG4gKiAgICAgICB0aGlzLnB1c2hFdmVudChcImVsZW1lbnQtY2xpY2tlZFwiLCB7IHN0YXRlOiB0aGlzLm15U3RhdGUgfSk7XG4gKiAgICAgfSk7XG4gKiAgIH1cbiAqXG4gKiAgIHVwZGF0ZWQoKSB7XG4gKiAgICAgY29uc29sZS5sb2coXCJIb29rIHVwZGF0ZWRcIiwgdGhpcy5lbC5pZCk7XG4gKiAgIH1cbiAqXG4gKiAgIG15Q3VzdG9tTWV0aG9kKHNvbWVBcmc6IHN0cmluZykge1xuICogICAgIGNvbnNvbGUubG9nKFwibXlDdXN0b21NZXRob2QgY2FsbGVkIHdpdGg6XCIsIHNvbWVBcmcsIFwiQ3VycmVudCBzdGF0ZTpcIiwgdGhpcy5teVN0YXRlKTtcbiAqICAgfVxuICogfVxuICogYGBgXG4gKlxuICogVGhlIGB0aGlzYCBjb250ZXh0IHdpdGhpbiB0aGUgaG9vayBtZXRob2RzIChtb3VudGVkLCB1cGRhdGVkLCBjdXN0b20gbWV0aG9kcywgZXRjLilcbiAqIHdpbGwgcmVmZXIgdG8gdGhlIGhvb2sgaW5zdGFuY2UsIHByb3ZpZGluZyBhY2Nlc3MgdG8gYHRoaXMuZWxgLCBgdGhpcy5saXZlU29ja2V0YCxcbiAqIGB0aGlzLnB1c2hFdmVudCgpYCwgZXRjLiwgYXMgd2VsbCBhcyBhbnkgcHJvcGVydGllcyBvciBtZXRob2RzIGRlZmluZWQgb24gdGhlIHN1YmNsYXNzLlxuICovXG5leHBvcnQgY2xhc3MgVmlld0hvb2sgaW1wbGVtZW50cyBIb29rSW50ZXJmYWNlIHtcbiAgZWw6IEhUTUxFbGVtZW50O1xuICBsaXZlU29ja2V0OiBMaXZlU29ja2V0O1xuXG4gIHByaXZhdGUgX19saXN0ZW5lcnM6IFNldDxDYWxsYmFja1JlZj47XG4gIHByaXZhdGUgX19pc0Rpc2Nvbm5lY3RlZDogYm9vbGVhbjtcbiAgcHJpdmF0ZSBfX3ZpZXc6ICgpID0+IFZpZXc7XG5cbiAgc3RhdGljIG1ha2VJRCgpIHtcbiAgICByZXR1cm4gdmlld0hvb2tJRCsrO1xuICB9XG4gIHN0YXRpYyBlbGVtZW50SUQoZWw6IEhUTUxFbGVtZW50KSB7XG4gICAgcmV0dXJuIERPTS5wcml2YXRlKGVsLCBIT09LX0lEKTtcbiAgfVxuXG4gIGNvbnN0cnVjdG9yKHZpZXc6IFZpZXcgfCBudWxsLCBlbDogSFRNTEVsZW1lbnQsIGNhbGxiYWNrcz86IEhvb2spIHtcbiAgICB0aGlzLmVsID0gZWw7XG4gICAgdGhpcy5fX2F0dGFjaFZpZXcodmlldyk7XG4gICAgdGhpcy5fX2xpc3RlbmVycyA9IG5ldyBTZXQoKTtcbiAgICB0aGlzLl9faXNEaXNjb25uZWN0ZWQgPSBmYWxzZTtcbiAgICBET00ucHV0UHJpdmF0ZSh0aGlzLmVsLCBIT09LX0lELCBWaWV3SG9vay5tYWtlSUQoKSk7XG5cbiAgICBpZiAoY2FsbGJhY2tzKSB7XG4gICAgICAvLyBUaGlzIGluc3RhbmNlIGlzIGZvciBhbiBvYmplY3QtbGl0ZXJhbCBob29rLiBDb3B5IG1ldGhvZHMvcHJvcGVydGllcy5cbiAgICAgIC8vIFRoZXNlIGFyZSBwcm9wZXJ0aWVzIHRoYXQgc2hvdWxkIE5PVCBiZSBvdmVycmlkZGVuIGJ5IHRoZSBjYWxsYmFja3Mgb2JqZWN0LlxuICAgICAgY29uc3QgcHJvdGVjdGVkUHJvcHMgPSBuZXcgU2V0KFtcbiAgICAgICAgXCJlbFwiLFxuICAgICAgICBcImxpdmVTb2NrZXRcIixcbiAgICAgICAgXCJfX3ZpZXdcIixcbiAgICAgICAgXCJfX2xpc3RlbmVyc1wiLFxuICAgICAgICBcIl9faXNEaXNjb25uZWN0ZWRcIixcbiAgICAgICAgXCJjb25zdHJ1Y3RvclwiLCAvLyBTdGFuZGFyZCBvYmplY3QgcHJvcGVydGllc1xuICAgICAgICAvLyBDb3JlIFZpZXdIb29rIEFQSSBtZXRob2RzXG4gICAgICAgIFwianNcIixcbiAgICAgICAgXCJwdXNoRXZlbnRcIixcbiAgICAgICAgXCJwdXNoRXZlbnRUb1wiLFxuICAgICAgICBcImhhbmRsZUV2ZW50XCIsXG4gICAgICAgIFwicmVtb3ZlSGFuZGxlRXZlbnRcIixcbiAgICAgICAgXCJ1cGxvYWRcIixcbiAgICAgICAgXCJ1cGxvYWRUb1wiLFxuICAgICAgICAvLyBJbnRlcm5hbCBsaWZlY3ljbGUgY2FsbGVyc1xuICAgICAgICBcIl9fbW91bnRlZFwiLFxuICAgICAgICBcIl9fdXBkYXRlZFwiLFxuICAgICAgICBcIl9fYmVmb3JlVXBkYXRlXCIsXG4gICAgICAgIFwiX19kZXN0cm95ZWRcIixcbiAgICAgICAgXCJfX3JlY29ubmVjdGVkXCIsXG4gICAgICAgIFwiX19kaXNjb25uZWN0ZWRcIixcbiAgICAgICAgXCJfX2NsZWFudXBfX1wiLFxuICAgICAgXSk7XG5cbiAgICAgIGZvciAoY29uc3Qga2V5IGluIGNhbGxiYWNrcykge1xuICAgICAgICBpZiAoT2JqZWN0LnByb3RvdHlwZS5oYXNPd25Qcm9wZXJ0eS5jYWxsKGNhbGxiYWNrcywga2V5KSkge1xuICAgICAgICAgICh0aGlzIGFzIGFueSlba2V5XSA9IGNhbGxiYWNrc1trZXldO1xuICAgICAgICAgIC8vIGZvciBiYWNrd2FyZHMgY29tcGF0aWJpbGl0eSwgd2UgYWxsb3cgdGhlIG92ZXJ3cml0ZSwgYnV0IHdlIGxvZyBhIHdhcm5pbmdcbiAgICAgICAgICBpZiAocHJvdGVjdGVkUHJvcHMuaGFzKGtleSkpIHtcbiAgICAgICAgICAgIGNvbnNvbGUud2FybihcbiAgICAgICAgICAgICAgYEhvb2sgb2JqZWN0IGZvciBlbGVtZW50ICMke2VsLmlkfSBvdmVyd3JpdGVzIGNvcmUgcHJvcGVydHkgJyR7a2V5fSchYCxcbiAgICAgICAgICAgICk7XG4gICAgICAgICAgfVxuICAgICAgICB9XG4gICAgICB9XG5cbiAgICAgIGNvbnN0IGxpZmVjeWNsZU1ldGhvZHM6IChrZXlvZiBIb29rKVtdID0gW1xuICAgICAgICBcIm1vdW50ZWRcIixcbiAgICAgICAgXCJiZWZvcmVVcGRhdGVcIixcbiAgICAgICAgXCJ1cGRhdGVkXCIsXG4gICAgICAgIFwiZGVzdHJveWVkXCIsXG4gICAgICAgIFwiZGlzY29ubmVjdGVkXCIsXG4gICAgICAgIFwicmVjb25uZWN0ZWRcIixcbiAgICAgIF07XG4gICAgICBsaWZlY3ljbGVNZXRob2RzLmZvckVhY2goKG1ldGhvZE5hbWUpID0+IHtcbiAgICAgICAgaWYgKFxuICAgICAgICAgIGNhbGxiYWNrc1ttZXRob2ROYW1lXSAmJlxuICAgICAgICAgIHR5cGVvZiBjYWxsYmFja3NbbWV0aG9kTmFtZV0gPT09IFwiZnVuY3Rpb25cIlxuICAgICAgICApIHtcbiAgICAgICAgICAodGhpcyBhcyBhbnkpW21ldGhvZE5hbWVdID0gY2FsbGJhY2tzW21ldGhvZE5hbWVdO1xuICAgICAgICB9XG4gICAgICB9KTtcbiAgICB9XG4gICAgLy8gSWYgJ2NhbGxiYWNrcycgaXMgbm90IHByb3ZpZGVkLCB0aGlzIGlzIGFuIGluc3RhbmNlIG9mIGEgdXNlci1kZWZpbmVkIGNsYXNzIChlLmcuLCBNeUhvb2spLlxuICAgIC8vIEl0cyBtZXRob2RzIChtb3VudGVkLCB1cGRhdGVkLCBjdXN0b20pIGFyZSBhbHJlYWR5IHBhcnQgb2YgaXRzIHByb3RvdHlwZSBvciBpbnN0YW5jZSxcbiAgICAvLyBhbmQgd2lsbCBjb3JyZWN0bHkgb3ZlcnJpZGUgdGhlIGRlZmF1bHRzIGZyb20gVmlld0hvb2sucHJvdG90eXBlLlxuICB9XG5cbiAgLyoqIEBpbnRlcm5hbCAqL1xuICBfX2F0dGFjaFZpZXcodmlldzogVmlldyB8IG51bGwpIHtcbiAgICBpZiAodmlldykge1xuICAgICAgdGhpcy5fX3ZpZXcgPSAoKSA9PiB2aWV3O1xuICAgICAgdGhpcy5saXZlU29ja2V0ID0gdmlldy5saXZlU29ja2V0O1xuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLl9fdmlldyA9ICgpID0+IHtcbiAgICAgICAgdGhyb3cgbmV3IEVycm9yKFxuICAgICAgICAgIGBob29rIG5vdCB5ZXQgYXR0YWNoZWQgdG8gYSBsaXZlIHZpZXc6ICR7dGhpcy5lbC5vdXRlckhUTUx9YCxcbiAgICAgICAgKTtcbiAgICAgIH07XG4gICAgICB0aGlzLmxpdmVTb2NrZXQgPSBudWxsO1xuICAgIH1cbiAgfVxuXG4gIC8vIERlZmF1bHQgbGlmZWN5Y2xlIG1ldGhvZHNcbiAgbW91bnRlZCgpOiB2b2lkIHt9XG4gIGJlZm9yZVVwZGF0ZSgpOiB2b2lkIHt9XG4gIHVwZGF0ZWQoKTogdm9pZCB7fVxuICBkZXN0cm95ZWQoKTogdm9pZCB7fVxuICBkaXNjb25uZWN0ZWQoKTogdm9pZCB7fVxuICByZWNvbm5lY3RlZCgpOiB2b2lkIHt9XG5cbiAgLy8gSW50ZXJuYWwgbGlmZWN5Y2xlIGNhbGxlcnMgLSBjYWxsZWQgYnkgdGhlIFZpZXdcblxuICAvKiogQGludGVybmFsICovXG4gIF9fbW91bnRlZCgpIHtcbiAgICB0aGlzLm1vdW50ZWQoKTtcbiAgfVxuICAvKiogQGludGVybmFsICovXG4gIF9fdXBkYXRlZCgpIHtcbiAgICB0aGlzLnVwZGF0ZWQoKTtcbiAgfVxuICAvKiogQGludGVybmFsICovXG4gIF9fYmVmb3JlVXBkYXRlKCkge1xuICAgIHRoaXMuYmVmb3JlVXBkYXRlKCk7XG4gIH1cbiAgLyoqIEBpbnRlcm5hbCAqL1xuICBfX2Rlc3Ryb3llZCgpIHtcbiAgICB0aGlzLmRlc3Ryb3llZCgpO1xuICAgIERPTS5kZWxldGVQcml2YXRlKHRoaXMuZWwsIEhPT0tfSUQpOyAvLyBodHRwczovL2dpdGh1Yi5jb20vcGhvZW5peGZyYW1ld29yay9waG9lbml4X2xpdmVfdmlldy9pc3N1ZXMvMzQ5NlxuICB9XG4gIC8qKiBAaW50ZXJuYWwgKi9cbiAgX19yZWNvbm5lY3RlZCgpIHtcbiAgICBpZiAodGhpcy5fX2lzRGlzY29ubmVjdGVkKSB7XG4gICAgICB0aGlzLl9faXNEaXNjb25uZWN0ZWQgPSBmYWxzZTtcbiAgICAgIHRoaXMucmVjb25uZWN0ZWQoKTtcbiAgICB9XG4gIH1cbiAgLyoqIEBpbnRlcm5hbCAqL1xuICBfX2Rpc2Nvbm5lY3RlZCgpIHtcbiAgICB0aGlzLl9faXNEaXNjb25uZWN0ZWQgPSB0cnVlO1xuICAgIHRoaXMuZGlzY29ubmVjdGVkKCk7XG4gIH1cblxuICBqcygpOiBIb29rSlNDb21tYW5kcyB7XG4gICAgcmV0dXJuIHtcbiAgICAgIC4uLmpzQ29tbWFuZHModGhpcy5fX3ZpZXcoKS5saXZlU29ja2V0LCBcImhvb2tcIiksXG4gICAgICBleGVjOiAoZW5jb2RlZEpTOiBzdHJpbmcpID0+IHtcbiAgICAgICAgdGhpcy5fX3ZpZXcoKS5saXZlU29ja2V0LmV4ZWNKUyh0aGlzLmVsLCBlbmNvZGVkSlMsIFwiaG9va1wiKTtcbiAgICAgIH0sXG4gICAgfTtcbiAgfVxuXG4gIHB1c2hFdmVudChldmVudDogc3RyaW5nLCBwYXlsb2FkPzogYW55LCBvblJlcGx5PzogT25SZXBseSkge1xuICAgIGNvbnN0IHByb21pc2UgPSB0aGlzLl9fdmlldygpLnB1c2hIb29rRXZlbnQoXG4gICAgICB0aGlzLmVsLFxuICAgICAgbnVsbCxcbiAgICAgIGV2ZW50LFxuICAgICAgcGF5bG9hZCB8fCB7fSxcbiAgICApO1xuICAgIGlmIChvblJlcGx5ID09PSB1bmRlZmluZWQpIHtcbiAgICAgIHJldHVybiBwcm9taXNlLnRoZW4oKHsgcmVwbHkgfSkgPT4gcmVwbHkpO1xuICAgIH1cbiAgICBwcm9taXNlLnRoZW4oKHsgcmVwbHksIHJlZiB9KSA9PiBvblJlcGx5KHJlcGx5LCByZWYpKS5jYXRjaCgoKSA9PiB7fSk7XG4gICAgcmV0dXJuO1xuICB9XG5cbiAgcHVzaEV2ZW50VG8oXG4gICAgc2VsZWN0b3JPclRhcmdldDogUGh4VGFyZ2V0LFxuICAgIGV2ZW50OiBzdHJpbmcsXG4gICAgcGF5bG9hZD86IG9iamVjdCxcbiAgICBvblJlcGx5PzogT25SZXBseSxcbiAgKSB7XG4gICAgaWYgKG9uUmVwbHkgPT09IHVuZGVmaW5lZCkge1xuICAgICAgY29uc3QgdGFyZ2V0UGFpcjogeyB2aWV3OiBWaWV3OyB0YXJnZXRDdHg6IGFueSB9W10gPSBbXTtcbiAgICAgIHRoaXMuX192aWV3KCkud2l0aGluVGFyZ2V0cyhzZWxlY3Rvck9yVGFyZ2V0LCAodmlldywgdGFyZ2V0Q3R4KSA9PiB7XG4gICAgICAgIHRhcmdldFBhaXIucHVzaCh7IHZpZXcsIHRhcmdldEN0eCB9KTtcbiAgICAgIH0pO1xuICAgICAgY29uc3QgcHJvbWlzZXMgPSB0YXJnZXRQYWlyLm1hcCgoeyB2aWV3LCB0YXJnZXRDdHggfSkgPT4ge1xuICAgICAgICByZXR1cm4gdmlldy5wdXNoSG9va0V2ZW50KHRoaXMuZWwsIHRhcmdldEN0eCwgZXZlbnQsIHBheWxvYWQgfHwge30pO1xuICAgICAgfSk7XG4gICAgICByZXR1cm4gUHJvbWlzZS5hbGxTZXR0bGVkKHByb21pc2VzKTtcbiAgICB9XG4gICAgdGhpcy5fX3ZpZXcoKS53aXRoaW5UYXJnZXRzKHNlbGVjdG9yT3JUYXJnZXQsICh2aWV3LCB0YXJnZXRDdHgpID0+IHtcbiAgICAgIHZpZXdcbiAgICAgICAgLnB1c2hIb29rRXZlbnQodGhpcy5lbCwgdGFyZ2V0Q3R4LCBldmVudCwgcGF5bG9hZCB8fCB7fSlcbiAgICAgICAgLnRoZW4oKHsgcmVwbHksIHJlZiB9KSA9PiBvblJlcGx5KHJlcGx5LCByZWYpKVxuICAgICAgICAuY2F0Y2goKCkgPT4ge30pO1xuICAgIH0pO1xuICAgIHJldHVybjtcbiAgfVxuXG4gIGhhbmRsZUV2ZW50KGV2ZW50OiBzdHJpbmcsIGNhbGxiYWNrOiAocGF5bG9hZDogYW55KSA9PiBhbnkpOiBDYWxsYmFja1JlZiB7XG4gICAgY29uc3QgY2FsbGJhY2tSZWY6IENhbGxiYWNrUmVmID0ge1xuICAgICAgZXZlbnQsXG4gICAgICBjYWxsYmFjazogKGN1c3RvbUV2ZW50OiBDdXN0b21FdmVudCkgPT4gY2FsbGJhY2soY3VzdG9tRXZlbnQuZGV0YWlsKSxcbiAgICB9O1xuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFxuICAgICAgYHBoeDoke2V2ZW50fWAsXG4gICAgICBjYWxsYmFja1JlZi5jYWxsYmFjayBhcyBFdmVudExpc3RlbmVyLFxuICAgICk7XG4gICAgdGhpcy5fX2xpc3RlbmVycy5hZGQoY2FsbGJhY2tSZWYpO1xuICAgIHJldHVybiBjYWxsYmFja1JlZjtcbiAgfVxuXG4gIHJlbW92ZUhhbmRsZUV2ZW50KHJlZjogQ2FsbGJhY2tSZWYpOiB2b2lkIHtcbiAgICB3aW5kb3cucmVtb3ZlRXZlbnRMaXN0ZW5lcihcbiAgICAgIGBwaHg6JHtyZWYuZXZlbnR9YCxcbiAgICAgIHJlZi5jYWxsYmFjayBhcyBFdmVudExpc3RlbmVyLFxuICAgICk7XG4gICAgdGhpcy5fX2xpc3RlbmVycy5kZWxldGUocmVmKTtcbiAgfVxuXG4gIHVwbG9hZChuYW1lOiBzdHJpbmcsIGZpbGVzOiBGaWxlTGlzdCk6IGFueSB7XG4gICAgcmV0dXJuIHRoaXMuX192aWV3KCkuZGlzcGF0Y2hVcGxvYWRzKG51bGwsIG5hbWUsIGZpbGVzKTtcbiAgfVxuXG4gIHVwbG9hZFRvKHNlbGVjdG9yT3JUYXJnZXQ6IFBoeFRhcmdldCwgbmFtZTogc3RyaW5nLCBmaWxlczogRmlsZUxpc3QpOiBhbnkge1xuICAgIHJldHVybiB0aGlzLl9fdmlldygpLndpdGhpblRhcmdldHMoc2VsZWN0b3JPclRhcmdldCwgKHZpZXcsIHRhcmdldEN0eCkgPT4ge1xuICAgICAgdmlldy5kaXNwYXRjaFVwbG9hZHModGFyZ2V0Q3R4LCBuYW1lLCBmaWxlcyk7XG4gICAgfSk7XG4gIH1cblxuICAvKiogQGludGVybmFsICovXG4gIF9fY2xlYW51cF9fKCkge1xuICAgIHRoaXMuX19saXN0ZW5lcnMuZm9yRWFjaCgoY2FsbGJhY2tSZWYpID0+XG4gICAgICB0aGlzLnJlbW92ZUhhbmRsZUV2ZW50KGNhbGxiYWNrUmVmKSxcbiAgICApO1xuICB9XG59XG5cbmV4cG9ydCB0eXBlIEhvb2tzT3B0aW9ucyA9IFJlY29yZDxzdHJpbmcsIHR5cGVvZiBWaWV3SG9vayB8IEhvb2s+O1xuXG5leHBvcnQgZGVmYXVsdCBWaWV3SG9vaztcbiIsICJpbXBvcnQge1xuICBCRUZPUkVfVU5MT0FEX0xPQURFUl9USU1FT1VULFxuICBDSEVDS0FCTEVfSU5QVVRTLFxuICBDT05TRUNVVElWRV9SRUxPQURTLFxuICBQSFhfQVVUT19SRUNPVkVSLFxuICBQSFhfQ09NUE9ORU5ULFxuICBQSFhfQ09OTkVDVEVEX0NMQVNTLFxuICBQSFhfRElTQUJMRV9XSVRILFxuICBQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUsXG4gIFBIWF9ESVNBQkxFRCxcbiAgUEhYX0xPQURJTkdfQ0xBU1MsXG4gIFBIWF9FUlJPUl9DTEFTUyxcbiAgUEhYX0NMSUVOVF9FUlJPUl9DTEFTUyxcbiAgUEhYX1NFUlZFUl9FUlJPUl9DTEFTUyxcbiAgUEhYX0hBU19GT0NVU0VELFxuICBQSFhfSEFTX1NVQk1JVFRFRCxcbiAgUEhYX0hPT0ssXG4gIFBIWF9QQVJFTlRfSUQsXG4gIFBIWF9QUk9HUkVTUyxcbiAgUEhYX1JFQURPTkxZLFxuICBQSFhfUkVGX0xPQURJTkcsXG4gIFBIWF9SRUZfU1JDLFxuICBQSFhfUkVGX0xPQ0ssXG4gIFBIWF9ST09UX0lELFxuICBQSFhfU0VTU0lPTixcbiAgUEhYX1NUQVRJQyxcbiAgUEhYX1NUSUNLWSxcbiAgUEhYX1RSQUNLX1NUQVRJQyxcbiAgUEhYX1RSQUNLX1VQTE9BRFMsXG4gIFBIWF9VUERBVEUsXG4gIFBIWF9VUExPQURfUkVGLFxuICBQSFhfVklFV19TRUxFQ1RPUixcbiAgUEhYX01BSU4sXG4gIFBIWF9NT1VOVEVELFxuICBQVVNIX1RJTUVPVVQsXG4gIFBIWF9WSUVXUE9SVF9UT1AsXG4gIFBIWF9WSUVXUE9SVF9CT1RUT00sXG4gIE1BWF9DSElMRF9KT0lOX0FUVEVNUFRTLFxuICBQSFhfTFZfUElELFxufSBmcm9tIFwiLi9jb25zdGFudHNcIjtcblxuaW1wb3J0IHtcbiAgY2xvbmUsXG4gIGNsb3Nlc3RQaHhCaW5kaW5nLFxuICBpc0VtcHR5LFxuICBpc0VxdWFsT2JqLFxuICBsb2dFcnJvcixcbiAgbWF5YmUsXG4gIGlzQ2lkLFxufSBmcm9tIFwiLi91dGlsc1wiO1xuXG5pbXBvcnQgQnJvd3NlciBmcm9tIFwiLi9icm93c2VyXCI7XG5pbXBvcnQgRE9NIGZyb20gXCIuL2RvbVwiO1xuaW1wb3J0IEVsZW1lbnRSZWYgZnJvbSBcIi4vZWxlbWVudF9yZWZcIjtcbmltcG9ydCBET01QYXRjaCBmcm9tIFwiLi9kb21fcGF0Y2hcIjtcbmltcG9ydCBMaXZlVXBsb2FkZXIgZnJvbSBcIi4vbGl2ZV91cGxvYWRlclwiO1xuaW1wb3J0IFJlbmRlcmVkIGZyb20gXCIuL3JlbmRlcmVkXCI7XG5pbXBvcnQgeyBWaWV3SG9vayB9IGZyb20gXCIuL3ZpZXdfaG9va1wiO1xuaW1wb3J0IEpTIGZyb20gXCIuL2pzXCI7XG5cbmltcG9ydCBtb3JwaGRvbSBmcm9tIFwibW9ycGhkb21cIjtcblxuZXhwb3J0IGNvbnN0IHByZXBlbmRGb3JtRGF0YUtleSA9IChrZXksIHByZWZpeCkgPT4ge1xuICBjb25zdCBpc0FycmF5ID0ga2V5LmVuZHNXaXRoKFwiW11cIik7XG4gIC8vIFJlbW92ZSB0aGUgXCJbXVwiIGlmIGl0J3MgYW4gYXJyYXlcbiAgbGV0IGJhc2VLZXkgPSBpc0FycmF5ID8ga2V5LnNsaWNlKDAsIC0yKSA6IGtleTtcbiAgLy8gUmVwbGFjZSBsYXN0IG9jY3VycmVuY2Ugb2Yga2V5IGJlZm9yZSBhIGNsb3NpbmcgYnJhY2tldCBvciB0aGUgZW5kIHdpdGgga2V5IHBsdXMgc3VmZml4XG4gIGJhc2VLZXkgPSBiYXNlS2V5LnJlcGxhY2UoLyhbXlxcW1xcXV0rKShcXF0/JCkvLCBgJHtwcmVmaXh9JDEkMmApO1xuICAvLyBBZGQgYmFjayB0aGUgXCJbXVwiIGlmIGl0IHdhcyBhbiBhcnJheVxuICBpZiAoaXNBcnJheSkge1xuICAgIGJhc2VLZXkgKz0gXCJbXVwiO1xuICB9XG4gIHJldHVybiBiYXNlS2V5O1xufTtcblxuY29uc3Qgc2VyaWFsaXplRm9ybSA9IChmb3JtLCBvcHRzLCBvbmx5TmFtZXMgPSBbXSkgPT4ge1xuICBjb25zdCB7IHN1Ym1pdHRlciB9ID0gb3B0cztcblxuICAvLyBXZSBtdXN0IGluamVjdCB0aGUgc3VibWl0dGVyIGluIHRoZSBvcmRlciB0aGF0IGl0IGV4aXN0cyBpbiB0aGUgRE9NXG4gIC8vIHJlbGF0aXZlIHRvIG90aGVyIGlucHV0cy4gRm9yIGV4YW1wbGUsIGZvciBjaGVja2JveCBncm91cHMsIHRoZSBvcmRlciBtdXN0IGJlIG1haW50YWluZWQuXG4gIGxldCBpbmplY3RlZEVsZW1lbnQ7XG4gIGlmIChzdWJtaXR0ZXIgJiYgc3VibWl0dGVyLm5hbWUpIHtcbiAgICBjb25zdCBpbnB1dCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJpbnB1dFwiKTtcbiAgICBpbnB1dC50eXBlID0gXCJoaWRkZW5cIjtcbiAgICAvLyBzZXQgdGhlIGZvcm0gYXR0cmlidXRlIGlmIHRoZSBzdWJtaXR0ZXIgaGFzIG9uZTtcbiAgICAvLyB0aGlzIGNhbiBoYXBwZW4gaWYgdGhlIGVsZW1lbnQgaXMgb3V0c2lkZSB0aGUgYWN0dWFsIGZvcm0gZWxlbWVudFxuICAgIGNvbnN0IGZvcm1JZCA9IHN1Ym1pdHRlci5nZXRBdHRyaWJ1dGUoXCJmb3JtXCIpO1xuICAgIGlmIChmb3JtSWQpIHtcbiAgICAgIGlucHV0LnNldEF0dHJpYnV0ZShcImZvcm1cIiwgZm9ybUlkKTtcbiAgICB9XG4gICAgaW5wdXQubmFtZSA9IHN1Ym1pdHRlci5uYW1lO1xuICAgIGlucHV0LnZhbHVlID0gc3VibWl0dGVyLnZhbHVlO1xuICAgIHN1Ym1pdHRlci5wYXJlbnRFbGVtZW50Lmluc2VydEJlZm9yZShpbnB1dCwgc3VibWl0dGVyKTtcbiAgICBpbmplY3RlZEVsZW1lbnQgPSBpbnB1dDtcbiAgfVxuXG4gIGNvbnN0IGZvcm1EYXRhID0gbmV3IEZvcm1EYXRhKGZvcm0pO1xuICBjb25zdCB0b1JlbW92ZSA9IFtdO1xuXG4gIGZvcm1EYXRhLmZvckVhY2goKHZhbCwga2V5LCBfaW5kZXgpID0+IHtcbiAgICBpZiAodmFsIGluc3RhbmNlb2YgRmlsZSkge1xuICAgICAgdG9SZW1vdmUucHVzaChrZXkpO1xuICAgIH1cbiAgfSk7XG5cbiAgLy8gQ2xlYW51cCBhZnRlciBidWlsZGluZyBmaWxlRGF0YVxuICB0b1JlbW92ZS5mb3JFYWNoKChrZXkpID0+IGZvcm1EYXRhLmRlbGV0ZShrZXkpKTtcblxuICBjb25zdCBwYXJhbXMgPSBuZXcgVVJMU2VhcmNoUGFyYW1zKCk7XG5cbiAgY29uc3QgeyBpbnB1dHNVbnVzZWQsIG9ubHlIaWRkZW5JbnB1dHMgfSA9IEFycmF5LmZyb20oZm9ybS5lbGVtZW50cykucmVkdWNlKFxuICAgIChhY2MsIGlucHV0KSA9PiB7XG4gICAgICBjb25zdCB7IGlucHV0c1VudXNlZCwgb25seUhpZGRlbklucHV0cyB9ID0gYWNjO1xuICAgICAgY29uc3Qga2V5ID0gaW5wdXQubmFtZTtcbiAgICAgIGlmICgha2V5KSB7XG4gICAgICAgIHJldHVybiBhY2M7XG4gICAgICB9XG5cbiAgICAgIGlmIChpbnB1dHNVbnVzZWRba2V5XSA9PT0gdW5kZWZpbmVkKSB7XG4gICAgICAgIGlucHV0c1VudXNlZFtrZXldID0gdHJ1ZTtcbiAgICAgIH1cbiAgICAgIGlmIChvbmx5SGlkZGVuSW5wdXRzW2tleV0gPT09IHVuZGVmaW5lZCkge1xuICAgICAgICBvbmx5SGlkZGVuSW5wdXRzW2tleV0gPSB0cnVlO1xuICAgICAgfVxuXG4gICAgICBjb25zdCBpc1VzZWQgPVxuICAgICAgICBET00ucHJpdmF0ZShpbnB1dCwgUEhYX0hBU19GT0NVU0VEKSB8fFxuICAgICAgICBET00ucHJpdmF0ZShpbnB1dCwgUEhYX0hBU19TVUJNSVRURUQpO1xuICAgICAgY29uc3QgaXNIaWRkZW4gPSBpbnB1dC50eXBlID09PSBcImhpZGRlblwiO1xuICAgICAgaW5wdXRzVW51c2VkW2tleV0gPSBpbnB1dHNVbnVzZWRba2V5XSAmJiAhaXNVc2VkO1xuICAgICAgb25seUhpZGRlbklucHV0c1trZXldID0gb25seUhpZGRlbklucHV0c1trZXldICYmIGlzSGlkZGVuO1xuXG4gICAgICByZXR1cm4gYWNjO1xuICAgIH0sXG4gICAgeyBpbnB1dHNVbnVzZWQ6IHt9LCBvbmx5SGlkZGVuSW5wdXRzOiB7fSB9LFxuICApO1xuXG4gIGZvciAoY29uc3QgW2tleSwgdmFsXSBvZiBmb3JtRGF0YS5lbnRyaWVzKCkpIHtcbiAgICBpZiAob25seU5hbWVzLmxlbmd0aCA9PT0gMCB8fCBvbmx5TmFtZXMuaW5kZXhPZihrZXkpID49IDApIHtcbiAgICAgIGNvbnN0IGlzVW51c2VkID0gaW5wdXRzVW51c2VkW2tleV07XG4gICAgICBjb25zdCBoaWRkZW4gPSBvbmx5SGlkZGVuSW5wdXRzW2tleV07XG4gICAgICBpZiAoaXNVbnVzZWQgJiYgIShzdWJtaXR0ZXIgJiYgc3VibWl0dGVyLm5hbWUgPT0ga2V5KSAmJiAhaGlkZGVuKSB7XG4gICAgICAgIHBhcmFtcy5hcHBlbmQocHJlcGVuZEZvcm1EYXRhS2V5KGtleSwgXCJfdW51c2VkX1wiKSwgXCJcIik7XG4gICAgICB9XG4gICAgICBpZiAodHlwZW9mIHZhbCA9PT0gXCJzdHJpbmdcIikge1xuICAgICAgICBwYXJhbXMuYXBwZW5kKGtleSwgdmFsKTtcbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICAvLyByZW1vdmUgdGhlIGluamVjdGVkIGVsZW1lbnQgYWdhaW5cbiAgLy8gKGl0IHdvdWxkIGJlIHJlbW92ZWQgYnkgdGhlIG5leHQgZG9tIHBhdGNoIGFueXdheSwgYnV0IHRoaXMgaXMgY2xlYW5lcilcbiAgaWYgKHN1Ym1pdHRlciAmJiBpbmplY3RlZEVsZW1lbnQpIHtcbiAgICBzdWJtaXR0ZXIucGFyZW50RWxlbWVudC5yZW1vdmVDaGlsZChpbmplY3RlZEVsZW1lbnQpO1xuICB9XG5cbiAgcmV0dXJuIHBhcmFtcy50b1N0cmluZygpO1xufTtcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgVmlldyB7XG4gIHN0YXRpYyBjbG9zZXN0VmlldyhlbCkge1xuICAgIGNvbnN0IGxpdmVWaWV3RWwgPSBlbC5jbG9zZXN0KFBIWF9WSUVXX1NFTEVDVE9SKTtcbiAgICByZXR1cm4gbGl2ZVZpZXdFbCA/IERPTS5wcml2YXRlKGxpdmVWaWV3RWwsIFwidmlld1wiKSA6IG51bGw7XG4gIH1cblxuICBjb25zdHJ1Y3RvcihlbCwgbGl2ZVNvY2tldCwgcGFyZW50VmlldywgZmxhc2gsIGxpdmVSZWZlcmVyKSB7XG4gICAgdGhpcy5pc0RlYWQgPSBmYWxzZTtcbiAgICB0aGlzLmxpdmVTb2NrZXQgPSBsaXZlU29ja2V0O1xuICAgIHRoaXMuZmxhc2ggPSBmbGFzaDtcbiAgICB0aGlzLnBhcmVudCA9IHBhcmVudFZpZXc7XG4gICAgdGhpcy5yb290ID0gcGFyZW50VmlldyA/IHBhcmVudFZpZXcucm9vdCA6IHRoaXM7XG4gICAgdGhpcy5lbCA9IGVsO1xuICAgIC8vIHNlZSBodHRwczovL2dpdGh1Yi5jb20vcGhvZW5peGZyYW1ld29yay9waG9lbml4X2xpdmVfdmlldy9wdWxsLzM3MjFcbiAgICAvLyBjaGVjayBpZiB0aGUgZWxlbWVudCBpcyBhbHJlYWR5IGJvdW5kIHRvIGEgdmlld1xuICAgIGNvbnN0IGJvdW5kVmlldyA9IERPTS5wcml2YXRlKHRoaXMuZWwsIFwidmlld1wiKTtcbiAgICBpZiAoYm91bmRWaWV3ICE9PSB1bmRlZmluZWQgJiYgYm91bmRWaWV3LmlzRGVhZCAhPT0gdHJ1ZSkge1xuICAgICAgbG9nRXJyb3IoXG4gICAgICAgIGBUaGUgRE9NIGVsZW1lbnQgZm9yIHRoaXMgdmlldyBoYXMgYWxyZWFkeSBiZWVuIGJvdW5kIHRvIGEgdmlldy5cblxuICAgICAgICBBbiBlbGVtZW50IGNhbiBvbmx5IGV2ZXIgYmUgYXNzb2NpYXRlZCB3aXRoIGEgc2luZ2xlIHZpZXchXG4gICAgICAgIFBsZWFzZSBlbnN1cmUgdGhhdCB5b3UgYXJlIG5vdCB0cnlpbmcgdG8gaW5pdGlhbGl6ZSBtdWx0aXBsZSBMaXZlU29ja2V0cyBvbiB0aGUgc2FtZSBwYWdlLlxuICAgICAgICBUaGlzIGNvdWxkIGhhcHBlbiBpZiB5b3UncmUgYWNjaWRlbnRhbGx5IHRyeWluZyB0byByZW5kZXIgeW91ciByb290IGxheW91dCBtb3JlIHRoYW4gb25jZS5cbiAgICAgICAgRW5zdXJlIHRoYXQgdGhlIHRlbXBsYXRlIHNldCBvbiB0aGUgTGl2ZVZpZXcgaXMgZGlmZmVyZW50IHRoYW4gdGhlIHJvb3QgbGF5b3V0LlxuICAgICAgYCxcbiAgICAgICAgeyB2aWV3OiBib3VuZFZpZXcgfSxcbiAgICAgICk7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoXCJDYW5ub3QgYmluZCBtdWx0aXBsZSB2aWV3cyB0byB0aGUgc2FtZSBET00gZWxlbWVudC5cIik7XG4gICAgfVxuICAgIC8vIGJpbmQgdGhlIHZpZXcgdG8gdGhlIGVsZW1lbnRcbiAgICBET00ucHV0UHJpdmF0ZSh0aGlzLmVsLCBcInZpZXdcIiwgdGhpcyk7XG4gICAgdGhpcy5pZCA9IHRoaXMuZWwuaWQ7XG4gICAgdGhpcy5yZWYgPSAwO1xuICAgIHRoaXMubGFzdEFja1JlZiA9IG51bGw7XG4gICAgdGhpcy5jaGlsZEpvaW5zID0gMDtcbiAgICAvKipcbiAgICAgKiBAdHlwZSB7UmV0dXJuVHlwZTx0eXBlb2Ygc2V0VGltZW91dD4gfCBudWxsfVxuICAgICAqL1xuICAgIHRoaXMubG9hZGVyVGltZXIgPSBudWxsO1xuICAgIC8qKlxuICAgICAqIEB0eXBlIHtSZXR1cm5UeXBlPHR5cGVvZiBzZXRUaW1lb3V0PiB8IG51bGx9XG4gICAgICovXG4gICAgdGhpcy5kaXNjb25uZWN0ZWRUaW1lciA9IG51bGw7XG4gICAgdGhpcy5wZW5kaW5nRGlmZnMgPSBbXTtcbiAgICB0aGlzLnBlbmRpbmdGb3JtcyA9IG5ldyBTZXQoKTtcbiAgICB0aGlzLnJlZGlyZWN0ID0gZmFsc2U7XG4gICAgdGhpcy5ocmVmID0gbnVsbDtcbiAgICB0aGlzLmpvaW5Db3VudCA9IHRoaXMucGFyZW50ID8gdGhpcy5wYXJlbnQuam9pbkNvdW50IC0gMSA6IDA7XG4gICAgdGhpcy5qb2luQXR0ZW1wdHMgPSAwO1xuICAgIHRoaXMuam9pblBlbmRpbmcgPSB0cnVlO1xuICAgIHRoaXMuZGVzdHJveWVkID0gZmFsc2U7XG4gICAgdGhpcy5qb2luQ2FsbGJhY2sgPSBmdW5jdGlvbiAob25Eb25lKSB7XG4gICAgICBvbkRvbmUgJiYgb25Eb25lKCk7XG4gICAgfTtcbiAgICB0aGlzLnN0b3BDYWxsYmFjayA9IGZ1bmN0aW9uICgpIHt9O1xuICAgIHRoaXMucGVuZGluZ0pvaW5PcHMgPSB0aGlzLnBhcmVudCA/IG51bGwgOiBbXTtcbiAgICB0aGlzLnZpZXdIb29rcyA9IHt9O1xuICAgIHRoaXMuZm9ybVN1Ym1pdHMgPSBbXTtcbiAgICB0aGlzLmNoaWxkcmVuID0gdGhpcy5wYXJlbnQgPyBudWxsIDoge307XG4gICAgdGhpcy5yb290LmNoaWxkcmVuW3RoaXMuaWRdID0ge307XG4gICAgdGhpcy5mb3Jtc0ZvclJlY292ZXJ5ID0ge307XG4gICAgdGhpcy5jaGFubmVsID0gdGhpcy5saXZlU29ja2V0LmNoYW5uZWwoYGx2OiR7dGhpcy5pZH1gLCAoKSA9PiB7XG4gICAgICBjb25zdCB1cmwgPSB0aGlzLmhyZWYgJiYgdGhpcy5leHBhbmRVUkwodGhpcy5ocmVmKTtcbiAgICAgIHJldHVybiB7XG4gICAgICAgIHJlZGlyZWN0OiB0aGlzLnJlZGlyZWN0ID8gdXJsIDogdW5kZWZpbmVkLFxuICAgICAgICB1cmw6IHRoaXMucmVkaXJlY3QgPyB1bmRlZmluZWQgOiB1cmwgfHwgdW5kZWZpbmVkLFxuICAgICAgICBwYXJhbXM6IHRoaXMuY29ubmVjdFBhcmFtcyhsaXZlUmVmZXJlciksXG4gICAgICAgIHNlc3Npb246IHRoaXMuZ2V0U2Vzc2lvbigpLFxuICAgICAgICBzdGF0aWM6IHRoaXMuZ2V0U3RhdGljKCksXG4gICAgICAgIGZsYXNoOiB0aGlzLmZsYXNoLFxuICAgICAgICBzdGlja3k6IHRoaXMuZWwuaGFzQXR0cmlidXRlKFBIWF9TVElDS1kpLFxuICAgICAgfTtcbiAgICB9KTtcbiAgICB0aGlzLnBvcnRhbEVsZW1lbnRJZHMgPSBuZXcgU2V0KCk7XG4gIH1cblxuICBzZXRIcmVmKGhyZWYpIHtcbiAgICB0aGlzLmhyZWYgPSBocmVmO1xuICB9XG5cbiAgc2V0UmVkaXJlY3QoaHJlZikge1xuICAgIHRoaXMucmVkaXJlY3QgPSB0cnVlO1xuICAgIHRoaXMuaHJlZiA9IGhyZWY7XG4gIH1cblxuICBpc01haW4oKSB7XG4gICAgcmV0dXJuIHRoaXMuZWwuaGFzQXR0cmlidXRlKFBIWF9NQUlOKTtcbiAgfVxuXG4gIGNvbm5lY3RQYXJhbXMobGl2ZVJlZmVyZXIpIHtcbiAgICBjb25zdCBwYXJhbXMgPSB0aGlzLmxpdmVTb2NrZXQucGFyYW1zKHRoaXMuZWwpO1xuICAgIGNvbnN0IG1hbmlmZXN0ID0gRE9NLmFsbChkb2N1bWVudCwgYFske3RoaXMuYmluZGluZyhQSFhfVFJBQ0tfU1RBVElDKX1dYClcbiAgICAgIC5tYXAoKG5vZGUpID0+IG5vZGUuc3JjIHx8IG5vZGUuaHJlZilcbiAgICAgIC5maWx0ZXIoKHVybCkgPT4gdHlwZW9mIHVybCA9PT0gXCJzdHJpbmdcIik7XG5cbiAgICBpZiAobWFuaWZlc3QubGVuZ3RoID4gMCkge1xuICAgICAgcGFyYW1zW1wiX3RyYWNrX3N0YXRpY1wiXSA9IG1hbmlmZXN0O1xuICAgIH1cbiAgICBwYXJhbXNbXCJfbW91bnRzXCJdID0gdGhpcy5qb2luQ291bnQ7XG4gICAgcGFyYW1zW1wiX21vdW50X2F0dGVtcHRzXCJdID0gdGhpcy5qb2luQXR0ZW1wdHM7XG4gICAgcGFyYW1zW1wiX2xpdmVfcmVmZXJlclwiXSA9IGxpdmVSZWZlcmVyO1xuICAgIHRoaXMuam9pbkF0dGVtcHRzKys7XG5cbiAgICByZXR1cm4gcGFyYW1zO1xuICB9XG5cbiAgaXNDb25uZWN0ZWQoKSB7XG4gICAgcmV0dXJuIHRoaXMuY2hhbm5lbC5jYW5QdXNoKCk7XG4gIH1cblxuICBnZXRTZXNzaW9uKCkge1xuICAgIHJldHVybiB0aGlzLmVsLmdldEF0dHJpYnV0ZShQSFhfU0VTU0lPTik7XG4gIH1cblxuICBnZXRTdGF0aWMoKSB7XG4gICAgY29uc3QgdmFsID0gdGhpcy5lbC5nZXRBdHRyaWJ1dGUoUEhYX1NUQVRJQyk7XG4gICAgcmV0dXJuIHZhbCA9PT0gXCJcIiA/IG51bGwgOiB2YWw7XG4gIH1cblxuICBkZXN0cm95KGNhbGxiYWNrID0gZnVuY3Rpb24gKCkge30pIHtcbiAgICB0aGlzLmRlc3Ryb3lBbGxDaGlsZHJlbigpO1xuICAgIHRoaXMuZGVzdHJveVBvcnRhbEVsZW1lbnRzKCk7XG4gICAgdGhpcy5kZXN0cm95ZWQgPSB0cnVlO1xuICAgIERPTS5kZWxldGVQcml2YXRlKHRoaXMuZWwsIFwidmlld1wiKTtcbiAgICBkZWxldGUgdGhpcy5yb290LmNoaWxkcmVuW3RoaXMuaWRdO1xuICAgIGlmICh0aGlzLnBhcmVudCkge1xuICAgICAgZGVsZXRlIHRoaXMucm9vdC5jaGlsZHJlblt0aGlzLnBhcmVudC5pZF1bdGhpcy5pZF07XG4gICAgfVxuICAgIGNsZWFyVGltZW91dCh0aGlzLmxvYWRlclRpbWVyKTtcbiAgICBjb25zdCBvbkZpbmlzaGVkID0gKCkgPT4ge1xuICAgICAgY2FsbGJhY2soKTtcbiAgICAgIGZvciAoY29uc3QgaWQgaW4gdGhpcy52aWV3SG9va3MpIHtcbiAgICAgICAgdGhpcy5kZXN0cm95SG9vayh0aGlzLnZpZXdIb29rc1tpZF0pO1xuICAgICAgfVxuICAgIH07XG5cbiAgICBET00ubWFya1BoeENoaWxkRGVzdHJveWVkKHRoaXMuZWwpO1xuXG4gICAgdGhpcy5sb2coXCJkZXN0cm95ZWRcIiwgKCkgPT4gW1widGhlIGNoaWxkIGhhcyBiZWVuIHJlbW92ZWQgZnJvbSB0aGUgcGFyZW50XCJdKTtcbiAgICB0aGlzLmNoYW5uZWxcbiAgICAgIC5sZWF2ZSgpXG4gICAgICAucmVjZWl2ZShcIm9rXCIsIG9uRmluaXNoZWQpXG4gICAgICAucmVjZWl2ZShcImVycm9yXCIsIG9uRmluaXNoZWQpXG4gICAgICAucmVjZWl2ZShcInRpbWVvdXRcIiwgb25GaW5pc2hlZCk7XG4gIH1cblxuICBzZXRDb250YWluZXJDbGFzc2VzKC4uLmNsYXNzZXMpIHtcbiAgICB0aGlzLmVsLmNsYXNzTGlzdC5yZW1vdmUoXG4gICAgICBQSFhfQ09OTkVDVEVEX0NMQVNTLFxuICAgICAgUEhYX0xPQURJTkdfQ0xBU1MsXG4gICAgICBQSFhfRVJST1JfQ0xBU1MsXG4gICAgICBQSFhfQ0xJRU5UX0VSUk9SX0NMQVNTLFxuICAgICAgUEhYX1NFUlZFUl9FUlJPUl9DTEFTUyxcbiAgICApO1xuICAgIHRoaXMuZWwuY2xhc3NMaXN0LmFkZCguLi5jbGFzc2VzKTtcbiAgfVxuXG4gIHNob3dMb2FkZXIodGltZW91dCkge1xuICAgIGNsZWFyVGltZW91dCh0aGlzLmxvYWRlclRpbWVyKTtcbiAgICBpZiAodGltZW91dCkge1xuICAgICAgdGhpcy5sb2FkZXJUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gdGhpcy5zaG93TG9hZGVyKCksIHRpbWVvdXQpO1xuICAgIH0gZWxzZSB7XG4gICAgICBmb3IgKGNvbnN0IGlkIGluIHRoaXMudmlld0hvb2tzKSB7XG4gICAgICAgIHRoaXMudmlld0hvb2tzW2lkXS5fX2Rpc2Nvbm5lY3RlZCgpO1xuICAgICAgfVxuICAgICAgdGhpcy5zZXRDb250YWluZXJDbGFzc2VzKFBIWF9MT0FESU5HX0NMQVNTKTtcbiAgICB9XG4gIH1cblxuICBleGVjQWxsKGJpbmRpbmcpIHtcbiAgICBET00uYWxsKHRoaXMuZWwsIGBbJHtiaW5kaW5nfV1gLCAoZWwpID0+XG4gICAgICB0aGlzLmxpdmVTb2NrZXQuZXhlY0pTKGVsLCBlbC5nZXRBdHRyaWJ1dGUoYmluZGluZykpLFxuICAgICk7XG4gIH1cblxuICBoaWRlTG9hZGVyKCkge1xuICAgIGNsZWFyVGltZW91dCh0aGlzLmxvYWRlclRpbWVyKTtcbiAgICBjbGVhclRpbWVvdXQodGhpcy5kaXNjb25uZWN0ZWRUaW1lcik7XG4gICAgdGhpcy5zZXRDb250YWluZXJDbGFzc2VzKFBIWF9DT05ORUNURURfQ0xBU1MpO1xuICAgIHRoaXMuZXhlY0FsbCh0aGlzLmJpbmRpbmcoXCJjb25uZWN0ZWRcIikpO1xuICB9XG5cbiAgdHJpZ2dlclJlY29ubmVjdGVkKCkge1xuICAgIGZvciAoY29uc3QgaWQgaW4gdGhpcy52aWV3SG9va3MpIHtcbiAgICAgIHRoaXMudmlld0hvb2tzW2lkXS5fX3JlY29ubmVjdGVkKCk7XG4gICAgfVxuICB9XG5cbiAgbG9nKGtpbmQsIG1zZ0NhbGxiYWNrKSB7XG4gICAgdGhpcy5saXZlU29ja2V0LmxvZyh0aGlzLCBraW5kLCBtc2dDYWxsYmFjayk7XG4gIH1cblxuICB0cmFuc2l0aW9uKHRpbWUsIG9uU3RhcnQsIG9uRG9uZSA9IGZ1bmN0aW9uICgpIHt9KSB7XG4gICAgdGhpcy5saXZlU29ja2V0LnRyYW5zaXRpb24odGltZSwgb25TdGFydCwgb25Eb25lKTtcbiAgfVxuXG4gIC8vIGNhbGxzIHRoZSBjYWxsYmFjayB3aXRoIHRoZSB2aWV3IGFuZCB0YXJnZXQgZWxlbWVudCBmb3IgdGhlIGdpdmVuIHBoeFRhcmdldFxuICAvLyB0YXJnZXRzIGNhbiBiZTpcbiAgLy8gICogYW4gZWxlbWVudCBpdHNlbGYsIHRoZW4gaXQgaXMgc2ltcGx5IHBhc3NlZCB0byBsaXZlU29ja2V0Lm93bmVyO1xuICAvLyAgKiBhIENJRCAoQ29tcG9uZW50IElEKSwgdGhlbiB3ZSBmaXJzdCBzZWFyY2ggdGhlIGNvbXBvbmVudCdzIGVsZW1lbnQgaW4gdGhlIERPTVxuICAvLyAgKiBhIHNlbGVjdG9yLCB0aGVuIHdlIHNlYXJjaCB0aGUgc2VsZWN0b3IgaW4gdGhlIERPTSBhbmQgY2FsbCB0aGUgY2FsbGJhY2tcbiAgLy8gICAgZm9yIGVhY2ggZWxlbWVudCBmb3VuZCB3aXRoIHRoZSBjb3JyZXNwb25kaW5nIG93bmVyIHZpZXdcbiAgd2l0aGluVGFyZ2V0cyhwaHhUYXJnZXQsIGNhbGxiYWNrLCBkb20gPSBkb2N1bWVudCkge1xuICAgIC8vIGluIHRoZSBmb3JtIHJlY292ZXJ5IGNhc2Ugd2Ugc2VhcmNoIGluIGEgdGVtcGxhdGUgZnJhZ21lbnQgaW5zdGVhZCBvZlxuICAgIC8vIHRoZSByZWFsIGRvbSwgdGhlcmVmb3JlIHdlIG9wdGlvbmFsbHkgcGFzcyBkb20gYW5kIHZpZXdFbFxuXG4gICAgaWYgKHBoeFRhcmdldCBpbnN0YW5jZW9mIEhUTUxFbGVtZW50IHx8IHBoeFRhcmdldCBpbnN0YW5jZW9mIFNWR0VsZW1lbnQpIHtcbiAgICAgIHJldHVybiB0aGlzLmxpdmVTb2NrZXQub3duZXIocGh4VGFyZ2V0LCAodmlldykgPT5cbiAgICAgICAgY2FsbGJhY2sodmlldywgcGh4VGFyZ2V0KSxcbiAgICAgICk7XG4gICAgfVxuXG4gICAgaWYgKGlzQ2lkKHBoeFRhcmdldCkpIHtcbiAgICAgIGNvbnN0IHRhcmdldHMgPSBET00uZmluZENvbXBvbmVudE5vZGVMaXN0KHRoaXMuaWQsIHBoeFRhcmdldCwgZG9tKTtcbiAgICAgIGlmICh0YXJnZXRzLmxlbmd0aCA9PT0gMCkge1xuICAgICAgICBsb2dFcnJvcihgbm8gY29tcG9uZW50IGZvdW5kIG1hdGNoaW5nIHBoeC10YXJnZXQgb2YgJHtwaHhUYXJnZXR9YCk7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICBjYWxsYmFjayh0aGlzLCBwYXJzZUludChwaHhUYXJnZXQpKTtcbiAgICAgIH1cbiAgICB9IGVsc2Uge1xuICAgICAgY29uc3QgdGFyZ2V0cyA9IEFycmF5LmZyb20oZG9tLnF1ZXJ5U2VsZWN0b3JBbGwocGh4VGFyZ2V0KSk7XG4gICAgICBpZiAodGFyZ2V0cy5sZW5ndGggPT09IDApIHtcbiAgICAgICAgbG9nRXJyb3IoXG4gICAgICAgICAgYG5vdGhpbmcgZm91bmQgbWF0Y2hpbmcgdGhlIHBoeC10YXJnZXQgc2VsZWN0b3IgXCIke3BoeFRhcmdldH1cImAsXG4gICAgICAgICk7XG4gICAgICB9XG4gICAgICB0YXJnZXRzLmZvckVhY2goKHRhcmdldCkgPT5cbiAgICAgICAgdGhpcy5saXZlU29ja2V0Lm93bmVyKHRhcmdldCwgKHZpZXcpID0+IGNhbGxiYWNrKHZpZXcsIHRhcmdldCkpLFxuICAgICAgKTtcbiAgICB9XG4gIH1cblxuICBhcHBseURpZmYodHlwZSwgcmF3RGlmZiwgY2FsbGJhY2spIHtcbiAgICB0aGlzLmxvZyh0eXBlLCAoKSA9PiBbXCJcIiwgY2xvbmUocmF3RGlmZildKTtcbiAgICBjb25zdCB7IGRpZmYsIHJlcGx5LCBldmVudHMsIHRpdGxlIH0gPSBSZW5kZXJlZC5leHRyYWN0KHJhd0RpZmYpO1xuICAgIGNhbGxiYWNrKHsgZGlmZiwgcmVwbHksIGV2ZW50cyB9KTtcbiAgICBpZiAodHlwZW9mIHRpdGxlID09PSBcInN0cmluZ1wiIHx8IHR5cGUgPT0gXCJtb3VudFwiKSB7XG4gICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IERPTS5wdXRUaXRsZSh0aXRsZSkpO1xuICAgIH1cbiAgfVxuXG4gIG9uSm9pbihyZXNwKSB7XG4gICAgY29uc3QgeyByZW5kZXJlZCwgY29udGFpbmVyLCBsaXZldmlld192ZXJzaW9uLCBwaWQgfSA9IHJlc3A7XG4gICAgaWYgKGNvbnRhaW5lcikge1xuICAgICAgY29uc3QgW3RhZywgYXR0cnNdID0gY29udGFpbmVyO1xuICAgICAgdGhpcy5lbCA9IERPTS5yZXBsYWNlUm9vdENvbnRhaW5lcih0aGlzLmVsLCB0YWcsIGF0dHJzKTtcbiAgICB9XG4gICAgdGhpcy5jaGlsZEpvaW5zID0gMDtcbiAgICB0aGlzLmpvaW5QZW5kaW5nID0gdHJ1ZTtcbiAgICB0aGlzLmZsYXNoID0gbnVsbDtcbiAgICBpZiAodGhpcy5yb290ID09PSB0aGlzKSB7XG4gICAgICB0aGlzLmZvcm1zRm9yUmVjb3ZlcnkgPSB0aGlzLmdldEZvcm1zRm9yUmVjb3ZlcnkoKTtcbiAgICB9XG4gICAgaWYgKHRoaXMuaXNNYWluKCkgJiYgd2luZG93Lmhpc3Rvcnkuc3RhdGUgPT09IG51bGwpIHtcbiAgICAgIC8vIHNldCBpbml0aWFsIGhpc3RvcnkgZW50cnkgaWYgdGhpcyBpcyB0aGUgZmlyc3QgcGFnZSBsb2FkIChubyBoaXN0b3J5KVxuICAgICAgQnJvd3Nlci5wdXNoU3RhdGUoXCJyZXBsYWNlXCIsIHtcbiAgICAgICAgdHlwZTogXCJwYXRjaFwiLFxuICAgICAgICBpZDogdGhpcy5pZCxcbiAgICAgICAgcG9zaXRpb246IHRoaXMubGl2ZVNvY2tldC5jdXJyZW50SGlzdG9yeVBvc2l0aW9uLFxuICAgICAgfSk7XG4gICAgfVxuXG4gICAgaWYgKGxpdmV2aWV3X3ZlcnNpb24gIT09IHRoaXMubGl2ZVNvY2tldC52ZXJzaW9uKCkpIHtcbiAgICAgIGNvbnNvbGUuZXJyb3IoXG4gICAgICAgIGBMaXZlVmlldyBhc3NldCB2ZXJzaW9uIG1pc21hdGNoLiBKYXZhU2NyaXB0IHZlcnNpb24gJHt0aGlzLmxpdmVTb2NrZXQudmVyc2lvbigpfSB2cy4gc2VydmVyICR7bGl2ZXZpZXdfdmVyc2lvbn0uIFRvIGF2b2lkIGlzc3VlcywgcGxlYXNlIGVuc3VyZSB0aGF0IHlvdXIgYXNzZXRzIHVzZSB0aGUgc2FtZSB2ZXJzaW9uIGFzIHRoZSBzZXJ2ZXIuYCxcbiAgICAgICk7XG4gICAgfVxuXG4gICAgLy8gVGhlIHBpZCBpcyBvbmx5IHNlbnQgaWZcbiAgICAvL1xuICAgIC8vICAgIGNvbmZpZyA6cGhvZW5peF9saXZlX3ZpZXcsIDpkZWJ1Z19hdHRyaWJ1dGVzXG4gICAgLy9cbiAgICAvLyBpZiBzZXQgdG8gdHJ1ZS4gSXQgaXMgdG8gaGVscCBkZWJ1Z2dpbmcgaW4gZGV2ZWxvcG1lbnQuXG4gICAgaWYgKHBpZCkge1xuICAgICAgdGhpcy5lbC5zZXRBdHRyaWJ1dGUoUEhYX0xWX1BJRCwgcGlkKTtcbiAgICB9XG5cbiAgICBCcm93c2VyLmRyb3BMb2NhbChcbiAgICAgIHRoaXMubGl2ZVNvY2tldC5sb2NhbFN0b3JhZ2UsXG4gICAgICB3aW5kb3cubG9jYXRpb24ucGF0aG5hbWUsXG4gICAgICBDT05TRUNVVElWRV9SRUxPQURTLFxuICAgICk7XG4gICAgdGhpcy5hcHBseURpZmYoXCJtb3VudFwiLCByZW5kZXJlZCwgKHsgZGlmZiwgZXZlbnRzIH0pID0+IHtcbiAgICAgIHRoaXMucmVuZGVyZWQgPSBuZXcgUmVuZGVyZWQodGhpcy5pZCwgZGlmZik7XG4gICAgICBjb25zdCBbaHRtbCwgc3RyZWFtc10gPSB0aGlzLnJlbmRlckNvbnRhaW5lcihudWxsLCBcImpvaW5cIik7XG4gICAgICB0aGlzLmRyb3BQZW5kaW5nUmVmcygpO1xuICAgICAgdGhpcy5qb2luQ291bnQrKztcbiAgICAgIHRoaXMuam9pbkF0dGVtcHRzID0gMDtcblxuICAgICAgdGhpcy5tYXliZVJlY292ZXJGb3JtcyhodG1sLCAoKSA9PiB7XG4gICAgICAgIHRoaXMub25Kb2luQ29tcGxldGUocmVzcCwgaHRtbCwgc3RyZWFtcywgZXZlbnRzKTtcbiAgICAgIH0pO1xuICAgIH0pO1xuICB9XG5cbiAgZHJvcFBlbmRpbmdSZWZzKCkge1xuICAgIERPTS5hbGwoZG9jdW1lbnQsIGBbJHtQSFhfUkVGX1NSQ309XCIke3RoaXMucmVmU3JjKCl9XCJdYCwgKGVsKSA9PiB7XG4gICAgICBlbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1JFRl9MT0FESU5HKTtcbiAgICAgIGVsLnJlbW92ZUF0dHJpYnV0ZShQSFhfUkVGX1NSQyk7XG4gICAgICBlbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1JFRl9MT0NLKTtcbiAgICB9KTtcbiAgfVxuXG4gIG9uSm9pbkNvbXBsZXRlKHsgbGl2ZV9wYXRjaCB9LCBodG1sLCBzdHJlYW1zLCBldmVudHMpIHtcbiAgICAvLyBJbiBvcmRlciB0byBwcm92aWRlIGEgYmV0dGVyIGV4cGVyaWVuY2UsIHdlIHdhbnQgdG8gam9pblxuICAgIC8vIGFsbCBMaXZlVmlld3MgZmlyc3QgYW5kIG9ubHkgdGhlbiBhcHBseSB0aGVpciBwYXRjaGVzLlxuICAgIGlmICh0aGlzLmpvaW5Db3VudCA+IDEgfHwgKHRoaXMucGFyZW50ICYmICF0aGlzLnBhcmVudC5pc0pvaW5QZW5kaW5nKCkpKSB7XG4gICAgICByZXR1cm4gdGhpcy5hcHBseUpvaW5QYXRjaChsaXZlX3BhdGNoLCBodG1sLCBzdHJlYW1zLCBldmVudHMpO1xuICAgIH1cblxuICAgIC8vIE9uZSBkb3duc2lkZSBvZiB0aGlzIGFwcHJvYWNoIGlzIHRoYXQgd2UgbmVlZCB0byBmaW5kIHBoeENoaWxkcmVuXG4gICAgLy8gaW4gdGhlIGh0bWwgZnJhZ21lbnQsIGluc3RlYWQgb2YgZGlyZWN0bHkgb24gdGhlIERPTS4gVGhlIGZyYWdtZW50XG4gICAgLy8gYWxzbyBkb2VzIG5vdCBpbmNsdWRlIFBIWF9TVEFUSUMsIHNvIHdlIG5lZWQgdG8gY29weSBpdCBvdmVyIGZyb21cbiAgICAvLyB0aGUgRE9NLlxuICAgIGNvbnN0IG5ld0NoaWxkcmVuID0gRE9NLmZpbmRQaHhDaGlsZHJlbkluRnJhZ21lbnQoaHRtbCwgdGhpcy5pZCkuZmlsdGVyKFxuICAgICAgKHRvRWwpID0+IHtcbiAgICAgICAgY29uc3QgZnJvbUVsID0gdG9FbC5pZCAmJiB0aGlzLmVsLnF1ZXJ5U2VsZWN0b3IoYFtpZD1cIiR7dG9FbC5pZH1cIl1gKTtcbiAgICAgICAgY29uc3QgcGh4U3RhdGljID0gZnJvbUVsICYmIGZyb21FbC5nZXRBdHRyaWJ1dGUoUEhYX1NUQVRJQyk7XG4gICAgICAgIGlmIChwaHhTdGF0aWMpIHtcbiAgICAgICAgICB0b0VsLnNldEF0dHJpYnV0ZShQSFhfU1RBVElDLCBwaHhTdGF0aWMpO1xuICAgICAgICB9XG4gICAgICAgIC8vIHNldCBQSFhfUk9PVF9JRCB0byBwcmV2ZW50IGV2ZW50cyBmcm9tIGJlaW5nIGRpc3BhdGNoZWQgdG8gdGhlIHJvb3Qgdmlld1xuICAgICAgICAvLyB3aGlsZSB0aGUgY2hpbGQgam9pbiBpcyBzdGlsbCBwZW5kaW5nXG4gICAgICAgIGlmIChmcm9tRWwpIHtcbiAgICAgICAgICBmcm9tRWwuc2V0QXR0cmlidXRlKFBIWF9ST09UX0lELCB0aGlzLnJvb3QuaWQpO1xuICAgICAgICB9XG4gICAgICAgIHJldHVybiB0aGlzLmpvaW5DaGlsZCh0b0VsKTtcbiAgICAgIH0sXG4gICAgKTtcblxuICAgIGlmIChuZXdDaGlsZHJlbi5sZW5ndGggPT09IDApIHtcbiAgICAgIGlmICh0aGlzLnBhcmVudCkge1xuICAgICAgICB0aGlzLnJvb3QucGVuZGluZ0pvaW5PcHMucHVzaChbXG4gICAgICAgICAgdGhpcyxcbiAgICAgICAgICAoKSA9PiB0aGlzLmFwcGx5Sm9pblBhdGNoKGxpdmVfcGF0Y2gsIGh0bWwsIHN0cmVhbXMsIGV2ZW50cyksXG4gICAgICAgIF0pO1xuICAgICAgICB0aGlzLnBhcmVudC5hY2tKb2luKHRoaXMpO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdGhpcy5vbkFsbENoaWxkSm9pbnNDb21wbGV0ZSgpO1xuICAgICAgICB0aGlzLmFwcGx5Sm9pblBhdGNoKGxpdmVfcGF0Y2gsIGh0bWwsIHN0cmVhbXMsIGV2ZW50cyk7XG4gICAgICB9XG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMucm9vdC5wZW5kaW5nSm9pbk9wcy5wdXNoKFtcbiAgICAgICAgdGhpcyxcbiAgICAgICAgKCkgPT4gdGhpcy5hcHBseUpvaW5QYXRjaChsaXZlX3BhdGNoLCBodG1sLCBzdHJlYW1zLCBldmVudHMpLFxuICAgICAgXSk7XG4gICAgfVxuICB9XG5cbiAgYXR0YWNoVHJ1ZURvY0VsKCkge1xuICAgIHRoaXMuZWwgPSBET00uYnlJZCh0aGlzLmlkKTtcbiAgICB0aGlzLmVsLnNldEF0dHJpYnV0ZShQSFhfUk9PVF9JRCwgdGhpcy5yb290LmlkKTtcbiAgfVxuXG4gIC8vIHRoaXMgaXMgaW52b2tlZCBmb3IgZGVhZCBhbmQgbGl2ZSB2aWV3cywgc28gd2UgbXVzdCBmaWx0ZXIgYnlcbiAgLy8gYnkgb3duZXIgdG8gZW5zdXJlIHdlIGFyZW4ndCBkdXBsaWNhdGluZyBob29rcyBhY3Jvc3MgZGlzY29ubmVjdFxuICAvLyBhbmQgY29ubmVjdGVkIHN0YXRlcy4gVGhpcyBhbHNvIGhhbmRsZXMgY2FzZXMgd2hlcmUgaG9va3MgZXhpc3RcbiAgLy8gaW4gYSByb290IGxheW91dCB3aXRoIGEgTFYgaW4gdGhlIGJvZHlcbiAgZXhlY05ld01vdW50ZWQocGFyZW50ID0gZG9jdW1lbnQpIHtcbiAgICBsZXQgcGh4Vmlld3BvcnRUb3AgPSB0aGlzLmJpbmRpbmcoUEhYX1ZJRVdQT1JUX1RPUCk7XG4gICAgbGV0IHBoeFZpZXdwb3J0Qm90dG9tID0gdGhpcy5iaW5kaW5nKFBIWF9WSUVXUE9SVF9CT1RUT00pO1xuICAgIHRoaXMuYWxsKFxuICAgICAgcGFyZW50LFxuICAgICAgYFske3BoeFZpZXdwb3J0VG9wfV0sIFske3BoeFZpZXdwb3J0Qm90dG9tfV1gLFxuICAgICAgKGhvb2tFbCkgPT4ge1xuICAgICAgICBET00ubWFpbnRhaW5Qcml2YXRlSG9va3MoXG4gICAgICAgICAgaG9va0VsLFxuICAgICAgICAgIGhvb2tFbCxcbiAgICAgICAgICBwaHhWaWV3cG9ydFRvcCxcbiAgICAgICAgICBwaHhWaWV3cG9ydEJvdHRvbSxcbiAgICAgICAgKTtcbiAgICAgICAgdGhpcy5tYXliZUFkZE5ld0hvb2soaG9va0VsKTtcbiAgICAgIH0sXG4gICAgKTtcbiAgICB0aGlzLmFsbChcbiAgICAgIHBhcmVudCxcbiAgICAgIGBbJHt0aGlzLmJpbmRpbmcoUEhYX0hPT0spfV0sIFtkYXRhLXBoeC0ke1BIWF9IT09LfV1gLFxuICAgICAgKGhvb2tFbCkgPT4ge1xuICAgICAgICB0aGlzLm1heWJlQWRkTmV3SG9vayhob29rRWwpO1xuICAgICAgfSxcbiAgICApO1xuICAgIHRoaXMuYWxsKHBhcmVudCwgYFske3RoaXMuYmluZGluZyhQSFhfTU9VTlRFRCl9XWAsIChlbCkgPT4ge1xuICAgICAgdGhpcy5tYXliZU1vdW50ZWQoZWwpO1xuICAgIH0pO1xuICB9XG5cbiAgYWxsKHBhcmVudCwgc2VsZWN0b3IsIGNhbGxiYWNrKSB7XG4gICAgRE9NLmFsbChwYXJlbnQsIHNlbGVjdG9yLCAoZWwpID0+IHtcbiAgICAgIGlmICh0aGlzLm93bnNFbGVtZW50KGVsKSkge1xuICAgICAgICBjYWxsYmFjayhlbCk7XG4gICAgICB9XG4gICAgfSk7XG4gIH1cblxuICBhcHBseUpvaW5QYXRjaChsaXZlX3BhdGNoLCBodG1sLCBzdHJlYW1zLCBldmVudHMpIHtcbiAgICB0aGlzLmF0dGFjaFRydWVEb2NFbCgpO1xuICAgIGNvbnN0IHBhdGNoID0gbmV3IERPTVBhdGNoKHRoaXMsIHRoaXMuZWwsIHRoaXMuaWQsIGh0bWwsIHN0cmVhbXMsIG51bGwpO1xuICAgIHBhdGNoLm1hcmtQcnVuYWJsZUNvbnRlbnRGb3JSZW1vdmFsKCk7XG4gICAgdGhpcy5wZXJmb3JtUGF0Y2gocGF0Y2gsIGZhbHNlLCB0cnVlKTtcbiAgICB0aGlzLmpvaW5OZXdDaGlsZHJlbigpO1xuICAgIHRoaXMuZXhlY05ld01vdW50ZWQoKTtcblxuICAgIHRoaXMuam9pblBlbmRpbmcgPSBmYWxzZTtcbiAgICB0aGlzLmxpdmVTb2NrZXQuZGlzcGF0Y2hFdmVudHMoZXZlbnRzKTtcbiAgICB0aGlzLmFwcGx5UGVuZGluZ1VwZGF0ZXMoKTtcblxuICAgIGlmIChsaXZlX3BhdGNoKSB7XG4gICAgICBjb25zdCB7IGtpbmQsIHRvIH0gPSBsaXZlX3BhdGNoO1xuICAgICAgdGhpcy5saXZlU29ja2V0Lmhpc3RvcnlQYXRjaCh0bywga2luZCk7XG4gICAgfVxuICAgIHRoaXMuaGlkZUxvYWRlcigpO1xuICAgIGlmICh0aGlzLmpvaW5Db3VudCA+IDEpIHtcbiAgICAgIHRoaXMudHJpZ2dlclJlY29ubmVjdGVkKCk7XG4gICAgfVxuICAgIHRoaXMuc3RvcENhbGxiYWNrKCk7XG4gIH1cblxuICB0cmlnZ2VyQmVmb3JlVXBkYXRlSG9vayhmcm9tRWwsIHRvRWwpIHtcbiAgICB0aGlzLmxpdmVTb2NrZXQudHJpZ2dlckRPTShcIm9uQmVmb3JlRWxVcGRhdGVkXCIsIFtmcm9tRWwsIHRvRWxdKTtcbiAgICBjb25zdCBob29rID0gdGhpcy5nZXRIb29rKGZyb21FbCk7XG4gICAgY29uc3QgaXNJZ25vcmVkID0gaG9vayAmJiBET00uaXNJZ25vcmVkKGZyb21FbCwgdGhpcy5iaW5kaW5nKFBIWF9VUERBVEUpKTtcbiAgICBpZiAoXG4gICAgICBob29rICYmXG4gICAgICAhZnJvbUVsLmlzRXF1YWxOb2RlKHRvRWwpICYmXG4gICAgICAhKGlzSWdub3JlZCAmJiBpc0VxdWFsT2JqKGZyb21FbC5kYXRhc2V0LCB0b0VsLmRhdGFzZXQpKVxuICAgICkge1xuICAgICAgaG9vay5fX2JlZm9yZVVwZGF0ZSgpO1xuICAgICAgcmV0dXJuIGhvb2s7XG4gICAgfVxuICB9XG5cbiAgbWF5YmVNb3VudGVkKGVsKSB7XG4gICAgY29uc3QgcGh4TW91bnRlZCA9IGVsLmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoUEhYX01PVU5URUQpKTtcbiAgICBjb25zdCBoYXNCZWVuSW52b2tlZCA9IHBoeE1vdW50ZWQgJiYgRE9NLnByaXZhdGUoZWwsIFwibW91bnRlZFwiKTtcbiAgICBpZiAocGh4TW91bnRlZCAmJiAhaGFzQmVlbkludm9rZWQpIHtcbiAgICAgIHRoaXMubGl2ZVNvY2tldC5leGVjSlMoZWwsIHBoeE1vdW50ZWQpO1xuICAgICAgRE9NLnB1dFByaXZhdGUoZWwsIFwibW91bnRlZFwiLCB0cnVlKTtcbiAgICB9XG4gIH1cblxuICBtYXliZUFkZE5ld0hvb2soZWwpIHtcbiAgICBjb25zdCBuZXdIb29rID0gdGhpcy5hZGRIb29rKGVsKTtcbiAgICBpZiAobmV3SG9vaykge1xuICAgICAgbmV3SG9vay5fX21vdW50ZWQoKTtcbiAgICB9XG4gIH1cblxuICBwZXJmb3JtUGF0Y2gocGF0Y2gsIHBydW5lQ2lkcywgaXNKb2luUGF0Y2ggPSBmYWxzZSkge1xuICAgIGNvbnN0IHJlbW92ZWRFbHMgPSBbXTtcbiAgICBsZXQgcGh4Q2hpbGRyZW5BZGRlZCA9IGZhbHNlO1xuICAgIGNvbnN0IHVwZGF0ZWRIb29rSWRzID0gbmV3IFNldCgpO1xuXG4gICAgdGhpcy5saXZlU29ja2V0LnRyaWdnZXJET00oXCJvblBhdGNoU3RhcnRcIiwgW3BhdGNoLnRhcmdldENvbnRhaW5lcl0pO1xuXG4gICAgcGF0Y2guYWZ0ZXIoXCJhZGRlZFwiLCAoZWwpID0+IHtcbiAgICAgIHRoaXMubGl2ZVNvY2tldC50cmlnZ2VyRE9NKFwib25Ob2RlQWRkZWRcIiwgW2VsXSk7XG4gICAgICBjb25zdCBwaHhWaWV3cG9ydFRvcCA9IHRoaXMuYmluZGluZyhQSFhfVklFV1BPUlRfVE9QKTtcbiAgICAgIGNvbnN0IHBoeFZpZXdwb3J0Qm90dG9tID0gdGhpcy5iaW5kaW5nKFBIWF9WSUVXUE9SVF9CT1RUT00pO1xuICAgICAgRE9NLm1haW50YWluUHJpdmF0ZUhvb2tzKGVsLCBlbCwgcGh4Vmlld3BvcnRUb3AsIHBoeFZpZXdwb3J0Qm90dG9tKTtcbiAgICAgIHRoaXMubWF5YmVBZGROZXdIb29rKGVsKTtcbiAgICAgIGlmIChlbC5nZXRBdHRyaWJ1dGUpIHtcbiAgICAgICAgdGhpcy5tYXliZU1vdW50ZWQoZWwpO1xuICAgICAgfVxuICAgIH0pO1xuXG4gICAgcGF0Y2guYWZ0ZXIoXCJwaHhDaGlsZEFkZGVkXCIsIChlbCkgPT4ge1xuICAgICAgaWYgKERPTS5pc1BoeFN0aWNreShlbCkpIHtcbiAgICAgICAgdGhpcy5saXZlU29ja2V0LmpvaW5Sb290Vmlld3MoKTtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHBoeENoaWxkcmVuQWRkZWQgPSB0cnVlO1xuICAgICAgfVxuICAgIH0pO1xuXG4gICAgcGF0Y2guYmVmb3JlKFwidXBkYXRlZFwiLCAoZnJvbUVsLCB0b0VsKSA9PiB7XG4gICAgICBjb25zdCBob29rID0gdGhpcy50cmlnZ2VyQmVmb3JlVXBkYXRlSG9vayhmcm9tRWwsIHRvRWwpO1xuICAgICAgaWYgKGhvb2spIHtcbiAgICAgICAgdXBkYXRlZEhvb2tJZHMuYWRkKGZyb21FbC5pZCk7XG4gICAgICB9XG4gICAgICAvLyB0cmlnZ2VyIEpTIHNwZWNpZmljIHVwZGF0ZSBsb2dpYyAoZm9yIGV4YW1wbGUgZm9yIEpTLmlnbm9yZV9hdHRyaWJ1dGVzKVxuICAgICAgSlMub25CZWZvcmVFbFVwZGF0ZWQoZnJvbUVsLCB0b0VsKTtcbiAgICB9KTtcblxuICAgIHBhdGNoLmFmdGVyKFwidXBkYXRlZFwiLCAoZWwpID0+IHtcbiAgICAgIGlmICh1cGRhdGVkSG9va0lkcy5oYXMoZWwuaWQpKSB7XG4gICAgICAgIHRoaXMuZ2V0SG9vayhlbCkuX191cGRhdGVkKCk7XG4gICAgICB9XG4gICAgfSk7XG5cbiAgICBwYXRjaC5hZnRlcihcImRpc2NhcmRlZFwiLCAoZWwpID0+IHtcbiAgICAgIGlmIChlbC5ub2RlVHlwZSA9PT0gTm9kZS5FTEVNRU5UX05PREUpIHtcbiAgICAgICAgcmVtb3ZlZEVscy5wdXNoKGVsKTtcbiAgICAgIH1cbiAgICB9KTtcblxuICAgIHBhdGNoLmFmdGVyKFwidHJhbnNpdGlvbnNEaXNjYXJkZWRcIiwgKGVscykgPT5cbiAgICAgIHRoaXMuYWZ0ZXJFbGVtZW50c1JlbW92ZWQoZWxzLCBwcnVuZUNpZHMpLFxuICAgICk7XG4gICAgcGF0Y2gucGVyZm9ybShpc0pvaW5QYXRjaCk7XG4gICAgdGhpcy5hZnRlckVsZW1lbnRzUmVtb3ZlZChyZW1vdmVkRWxzLCBwcnVuZUNpZHMpO1xuXG4gICAgdGhpcy5saXZlU29ja2V0LnRyaWdnZXJET00oXCJvblBhdGNoRW5kXCIsIFtwYXRjaC50YXJnZXRDb250YWluZXJdKTtcbiAgICByZXR1cm4gcGh4Q2hpbGRyZW5BZGRlZDtcbiAgfVxuXG4gIGFmdGVyRWxlbWVudHNSZW1vdmVkKGVsZW1lbnRzLCBwcnVuZUNpZHMpIHtcbiAgICBjb25zdCBkZXN0cm95ZWRDSURzID0gW107XG4gICAgZWxlbWVudHMuZm9yRWFjaCgocGFyZW50KSA9PiB7XG4gICAgICBjb25zdCBjb21wb25lbnRzID0gRE9NLmFsbChwYXJlbnQsIGBbJHtQSFhfQ09NUE9ORU5UfV1gKTtcbiAgICAgIGNvbnN0IGhvb2tzID0gRE9NLmFsbChcbiAgICAgICAgcGFyZW50LFxuICAgICAgICBgWyR7dGhpcy5iaW5kaW5nKFBIWF9IT09LKX1dLCBbZGF0YS1waHgtaG9va11gLFxuICAgICAgKTtcbiAgICAgIGNvbXBvbmVudHMuY29uY2F0KHBhcmVudCkuZm9yRWFjaCgoZWwpID0+IHtcbiAgICAgICAgY29uc3QgY2lkID0gdGhpcy5jb21wb25lbnRJRChlbCk7XG4gICAgICAgIGlmIChpc0NpZChjaWQpICYmIGRlc3Ryb3llZENJRHMuaW5kZXhPZihjaWQpID09PSAtMSkge1xuICAgICAgICAgIGRlc3Ryb3llZENJRHMucHVzaChjaWQpO1xuICAgICAgICB9XG4gICAgICB9KTtcbiAgICAgIGhvb2tzLmNvbmNhdChwYXJlbnQpLmZvckVhY2goKGhvb2tFbCkgPT4ge1xuICAgICAgICBjb25zdCBob29rID0gdGhpcy5nZXRIb29rKGhvb2tFbCk7XG4gICAgICAgIGhvb2sgJiYgdGhpcy5kZXN0cm95SG9vayhob29rKTtcbiAgICAgIH0pO1xuICAgIH0pO1xuICAgIC8vIFdlIHNob3VsZCBub3QgcHJ1bmVDaWRzIG9uIGpvaW5zLiBPdGhlcndpc2UsIGluIGNhc2Ugb2ZcbiAgICAvLyByZWpvaW5zLCB3ZSBtYXkgbm90aWZ5IGNpZHMgdGhhdCBubyBsb25nZXIgYmVsb25nIHRvIHRoZVxuICAgIC8vIGN1cnJlbnQgTGl2ZVZpZXcgdG8gYmUgcmVtb3ZlZC5cbiAgICBpZiAocHJ1bmVDaWRzKSB7XG4gICAgICB0aGlzLm1heWJlUHVzaENvbXBvbmVudHNEZXN0cm95ZWQoZGVzdHJveWVkQ0lEcyk7XG4gICAgfVxuICB9XG5cbiAgam9pbk5ld0NoaWxkcmVuKCkge1xuICAgIERPTS5maW5kUGh4Q2hpbGRyZW4oZG9jdW1lbnQsIHRoaXMuaWQpLmZvckVhY2goKGVsKSA9PiB0aGlzLmpvaW5DaGlsZChlbCkpO1xuICB9XG5cbiAgbWF5YmVSZWNvdmVyRm9ybXMoaHRtbCwgY2FsbGJhY2spIHtcbiAgICBjb25zdCBwaHhDaGFuZ2UgPSB0aGlzLmJpbmRpbmcoXCJjaGFuZ2VcIik7XG4gICAgY29uc3Qgb2xkRm9ybXMgPSB0aGlzLnJvb3QuZm9ybXNGb3JSZWNvdmVyeTtcbiAgICAvLyBTbyB3aHkgZG8gd2UgY3JlYXRlIGEgdGVtcGxhdGUgZWxlbWVudCBoZXJlP1xuICAgIC8vIE9uZSB3YXkgdG8gcmVjb3ZlciBmb3JtcyB3b3VsZCBiZSB0byBpbW1lZGlhdGVseSBhcHBseSB0aGUgbW91bnRcbiAgICAvLyBwYXRjaCBhbmQgdGhlbiBhZnRlcndhcmRzIHJlY292ZXIgdGhlIGZvcm1zLiBIb3dldmVyLCB0aGlzIHdvdWxkXG4gICAgLy8gY2F1c2UgYSBmbGlja2VyLCBiZWNhdXNlIHRoZSBtb3VudCBwYXRjaCB3b3VsZCByZW1vdmUgdGhlIGZvcm0gY29udGVudFxuICAgIC8vIHVudGlsIGl0IGlzIHJlc3RvcmVkLiBUaGVyZWZvcmUgTFYgZGVjaWRlZCB0byBkbyBmb3JtIHJlY292ZXJ5IHdpdGggdGhlXG4gICAgLy8gcmF3IEhUTUwgYmVmb3JlIGl0IGlzIGFwcGxpZWQgYW5kIGRlbGF5IHRoZSBtb3VudCBwYXRjaCB1bnRpbCB0aGUgZm9ybVxuICAgIC8vIHJlY292ZXJ5IGV2ZW50cyBhcmUgZG9uZS5cbiAgICBjb25zdCB0ZW1wbGF0ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJ0ZW1wbGF0ZVwiKTtcbiAgICB0ZW1wbGF0ZS5pbm5lckhUTUwgPSBodG1sO1xuICAgIC8vIGJlY2F1c2Ugd2Ugd29yayB3aXRoIGEgdGVtcGxhdGUgZWxlbWVudCwgd2UgbXVzdCBtYW51YWxseSBjb3B5IHRoZSBhdHRyaWJ1dGVzXG4gICAgLy8gb3RoZXJ3aXNlIHRoZSBvd25lciAvIHRhcmdldCBoZWxwZXJzIGRvbid0IHdvcmsgcHJvcGVybHlcbiAgICBjb25zdCByb290RWwgPSB0ZW1wbGF0ZS5jb250ZW50LmZpcnN0RWxlbWVudENoaWxkO1xuICAgIHJvb3RFbC5pZCA9IHRoaXMuaWQ7XG4gICAgcm9vdEVsLnNldEF0dHJpYnV0ZShQSFhfUk9PVF9JRCwgdGhpcy5yb290LmlkKTtcbiAgICByb290RWwuc2V0QXR0cmlidXRlKFBIWF9TRVNTSU9OLCB0aGlzLmdldFNlc3Npb24oKSk7XG4gICAgcm9vdEVsLnNldEF0dHJpYnV0ZShQSFhfU1RBVElDLCB0aGlzLmdldFN0YXRpYygpKTtcbiAgICByb290RWwuc2V0QXR0cmlidXRlKFBIWF9QQVJFTlRfSUQsIHRoaXMucGFyZW50ID8gdGhpcy5wYXJlbnQuaWQgOiBudWxsKTtcblxuICAgIC8vIHdlIGdvIG92ZXIgYWxsIGZvcm0gZWxlbWVudHMgaW4gdGhlIG5ldyBIVE1MIGZvciB0aGUgTFZcbiAgICAvLyBhbmQgbG9vayBmb3Igb2xkIGZvcm1zIGluIHRoZSBgZm9ybXNGb3JSZWNvdmVyeWAgb2JqZWN0O1xuICAgIC8vIHRoZSBmb3Jtc0ZvclJlY292ZXJ5IGNhbiBhbHNvIGNvbnRhaW4gZm9ybXMgZnJvbSBjaGlsZCB2aWV3c1xuICAgIGNvbnN0IGZvcm1zVG9SZWNvdmVyID1cbiAgICAgIC8vIHdlIGdvIG92ZXIgYWxsIGZvcm1zIGluIHRoZSBuZXcgRE9NOyBiZWNhdXNlIHRoaXMgaXMgb25seSB0aGUgSFRNTCBmb3IgdGhlIGN1cnJlbnRcbiAgICAgIC8vIHZpZXcsIHdlIGNhbiBiZSBzdXJlIHRoYXQgYWxsIGZvcm1zIGFyZSBvd25lZCBieSB0aGlzIHZpZXc6XG4gICAgICBET00uYWxsKHRlbXBsYXRlLmNvbnRlbnQsIFwiZm9ybVwiKVxuICAgICAgICAvLyBvbmx5IHJlY292ZXIgZm9ybXMgdGhhdCBoYXZlIGFuIGlkIGFuZCBhcmUgaW4gdGhlIG9sZCBET01cbiAgICAgICAgLmZpbHRlcigobmV3Rm9ybSkgPT4gbmV3Rm9ybS5pZCAmJiBvbGRGb3Jtc1tuZXdGb3JtLmlkXSlcbiAgICAgICAgLy8gYWJhbmRvbiBmb3JtcyB3ZSBhbHJlYWR5IHRyaWVkIHRvIHJlY292ZXIgdG8gcHJldmVudCBsb29waW5nIGEgZmFpbGVkIHN0YXRlXG4gICAgICAgIC5maWx0ZXIoKG5ld0Zvcm0pID0+ICF0aGlzLnBlbmRpbmdGb3Jtcy5oYXMobmV3Rm9ybS5pZCkpXG4gICAgICAgIC8vIG9ubHkgcmVjb3ZlciBpZiB0aGUgZm9ybSBoYXMgdGhlIHNhbWUgcGh4LWNoYW5nZSB2YWx1ZVxuICAgICAgICAuZmlsdGVyKFxuICAgICAgICAgIChuZXdGb3JtKSA9PlxuICAgICAgICAgICAgb2xkRm9ybXNbbmV3Rm9ybS5pZF0uZ2V0QXR0cmlidXRlKHBoeENoYW5nZSkgPT09XG4gICAgICAgICAgICBuZXdGb3JtLmdldEF0dHJpYnV0ZShwaHhDaGFuZ2UpLFxuICAgICAgICApXG4gICAgICAgIC5tYXAoKG5ld0Zvcm0pID0+IHtcbiAgICAgICAgICByZXR1cm4gW29sZEZvcm1zW25ld0Zvcm0uaWRdLCBuZXdGb3JtXTtcbiAgICAgICAgfSk7XG5cbiAgICBpZiAoZm9ybXNUb1JlY292ZXIubGVuZ3RoID09PSAwKSB7XG4gICAgICByZXR1cm4gY2FsbGJhY2soKTtcbiAgICB9XG5cbiAgICBmb3Jtc1RvUmVjb3Zlci5mb3JFYWNoKChbb2xkRm9ybSwgbmV3Rm9ybV0sIGkpID0+IHtcbiAgICAgIHRoaXMucGVuZGluZ0Zvcm1zLmFkZChuZXdGb3JtLmlkKTtcbiAgICAgIC8vIGl0IGlzIGltcG9ydGFudCB0byB1c2UgdGhlIGZpcnN0RWxlbWVudENoaWxkIG9mIHRoZSB0ZW1wbGF0ZSBjb250ZW50XG4gICAgICAvLyBiZWNhdXNlIHdoZW4gdHJhdmVyc2luZyBhIGRvY3VtZW50RnJhZ21lbnQgdXNpbmcgcGFyZW50Tm9kZSwgd2Ugd29uJ3QgZXZlciBhcnJpdmUgYXRcbiAgICAgIC8vIHRoZSBmcmFnbWVudDsgYXMgdGhlIHRlbXBsYXRlIGlzIGFsd2F5cyBhIExpdmVWaWV3LCB3ZSBjYW4gYmUgc3VyZSB0aGF0IHRoZXJlIGlzIG9ubHlcbiAgICAgIC8vIG9uZSBjaGlsZCBvbiB0aGUgcm9vdCBsZXZlbFxuICAgICAgdGhpcy5wdXNoRm9ybVJlY292ZXJ5KFxuICAgICAgICBvbGRGb3JtLFxuICAgICAgICBuZXdGb3JtLFxuICAgICAgICB0ZW1wbGF0ZS5jb250ZW50LmZpcnN0RWxlbWVudENoaWxkLFxuICAgICAgICAoKSA9PiB7XG4gICAgICAgICAgdGhpcy5wZW5kaW5nRm9ybXMuZGVsZXRlKG5ld0Zvcm0uaWQpO1xuICAgICAgICAgIC8vIHdlIG9ubHkgY2FsbCB0aGUgY2FsbGJhY2sgb25jZSBhbGwgZm9ybXMgaGF2ZSBiZWVuIHJlY292ZXJlZFxuICAgICAgICAgIGlmIChpID09PSBmb3Jtc1RvUmVjb3Zlci5sZW5ndGggLSAxKSB7XG4gICAgICAgICAgICBjYWxsYmFjaygpO1xuICAgICAgICAgIH1cbiAgICAgICAgfSxcbiAgICAgICk7XG4gICAgfSk7XG4gIH1cblxuICBnZXRDaGlsZEJ5SWQoaWQpIHtcbiAgICByZXR1cm4gdGhpcy5yb290LmNoaWxkcmVuW3RoaXMuaWRdW2lkXTtcbiAgfVxuXG4gIGdldERlc2NlbmRlbnRCeUVsKGVsKSB7XG4gICAgaWYgKGVsLmlkID09PSB0aGlzLmlkKSB7XG4gICAgICByZXR1cm4gdGhpcztcbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuIHRoaXMuY2hpbGRyZW5bZWwuZ2V0QXR0cmlidXRlKFBIWF9QQVJFTlRfSUQpXT8uW2VsLmlkXTtcbiAgICB9XG4gIH1cblxuICBkZXN0cm95RGVzY2VuZGVudChpZCkge1xuICAgIGZvciAoY29uc3QgcGFyZW50SWQgaW4gdGhpcy5yb290LmNoaWxkcmVuKSB7XG4gICAgICBmb3IgKGNvbnN0IGNoaWxkSWQgaW4gdGhpcy5yb290LmNoaWxkcmVuW3BhcmVudElkXSkge1xuICAgICAgICBpZiAoY2hpbGRJZCA9PT0gaWQpIHtcbiAgICAgICAgICByZXR1cm4gdGhpcy5yb290LmNoaWxkcmVuW3BhcmVudElkXVtjaGlsZElkXS5kZXN0cm95KCk7XG4gICAgICAgIH1cbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICBqb2luQ2hpbGQoZWwpIHtcbiAgICBjb25zdCBjaGlsZCA9IHRoaXMuZ2V0Q2hpbGRCeUlkKGVsLmlkKTtcbiAgICBpZiAoIWNoaWxkKSB7XG4gICAgICBjb25zdCB2aWV3ID0gbmV3IFZpZXcoZWwsIHRoaXMubGl2ZVNvY2tldCwgdGhpcyk7XG4gICAgICB0aGlzLnJvb3QuY2hpbGRyZW5bdGhpcy5pZF1bdmlldy5pZF0gPSB2aWV3O1xuICAgICAgdmlldy5qb2luKCk7XG4gICAgICB0aGlzLmNoaWxkSm9pbnMrKztcbiAgICAgIHJldHVybiB0cnVlO1xuICAgIH1cbiAgfVxuXG4gIGlzSm9pblBlbmRpbmcoKSB7XG4gICAgcmV0dXJuIHRoaXMuam9pblBlbmRpbmc7XG4gIH1cblxuICBhY2tKb2luKF9jaGlsZCkge1xuICAgIHRoaXMuY2hpbGRKb2lucy0tO1xuXG4gICAgaWYgKHRoaXMuY2hpbGRKb2lucyA9PT0gMCkge1xuICAgICAgaWYgKHRoaXMucGFyZW50KSB7XG4gICAgICAgIHRoaXMucGFyZW50LmFja0pvaW4odGhpcyk7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICB0aGlzLm9uQWxsQ2hpbGRKb2luc0NvbXBsZXRlKCk7XG4gICAgICB9XG4gICAgfVxuICB9XG5cbiAgb25BbGxDaGlsZEpvaW5zQ29tcGxldGUoKSB7XG4gICAgLy8gd2UgY2FuIGNsZWFyIHBlbmRpbmcgZm9ybSByZWNvdmVyaWVzIG5vdyB0aGF0IHdlJ3ZlIGpvaW5lZC5cbiAgICAvLyBUaGV5IGVpdGhlciBhbGwgcmVzb2x2ZWQgb3Igd2VyZSBhYmFuZG9uZWRcbiAgICB0aGlzLnBlbmRpbmdGb3Jtcy5jbGVhcigpO1xuICAgIC8vIHdlIGNhbiBhbHNvIGNsZWFyIHRoZSBmb3Jtc0ZvclJlY292ZXJ5IG9iamVjdCB0byBub3Qga2VlcCBvbGQgZm9ybSBlbGVtZW50cyBhcm91bmRcbiAgICB0aGlzLmZvcm1zRm9yUmVjb3ZlcnkgPSB7fTtcbiAgICB0aGlzLmpvaW5DYWxsYmFjaygoKSA9PiB7XG4gICAgICB0aGlzLnBlbmRpbmdKb2luT3BzLmZvckVhY2goKFt2aWV3LCBvcF0pID0+IHtcbiAgICAgICAgaWYgKCF2aWV3LmlzRGVzdHJveWVkKCkpIHtcbiAgICAgICAgICBvcCgpO1xuICAgICAgICB9XG4gICAgICB9KTtcbiAgICAgIHRoaXMucGVuZGluZ0pvaW5PcHMgPSBbXTtcbiAgICB9KTtcbiAgfVxuXG4gIHVwZGF0ZShkaWZmLCBldmVudHMpIHtcbiAgICBpZiAoXG4gICAgICB0aGlzLmlzSm9pblBlbmRpbmcoKSB8fFxuICAgICAgKHRoaXMubGl2ZVNvY2tldC5oYXNQZW5kaW5nTGluaygpICYmIHRoaXMucm9vdC5pc01haW4oKSlcbiAgICApIHtcbiAgICAgIHJldHVybiB0aGlzLnBlbmRpbmdEaWZmcy5wdXNoKHsgZGlmZiwgZXZlbnRzIH0pO1xuICAgIH1cblxuICAgIHRoaXMucmVuZGVyZWQubWVyZ2VEaWZmKGRpZmYpO1xuICAgIGxldCBwaHhDaGlsZHJlbkFkZGVkID0gZmFsc2U7XG5cbiAgICAvLyBXaGVuIHRoZSBkaWZmIG9ubHkgY29udGFpbnMgY29tcG9uZW50IGRpZmZzLCB0aGVuIHdhbGsgY29tcG9uZW50c1xuICAgIC8vIGFuZCBwYXRjaCBvbmx5IHRoZSBwYXJlbnQgY29tcG9uZW50IGNvbnRhaW5lcnMgZm91bmQgaW4gdGhlIGRpZmYuXG4gICAgLy8gT3RoZXJ3aXNlLCBwYXRjaCBlbnRpcmUgTFYgY29udGFpbmVyLlxuICAgIGlmICh0aGlzLnJlbmRlcmVkLmlzQ29tcG9uZW50T25seURpZmYoZGlmZikpIHtcbiAgICAgIHRoaXMubGl2ZVNvY2tldC50aW1lKFwiY29tcG9uZW50IHBhdGNoIGNvbXBsZXRlXCIsICgpID0+IHtcbiAgICAgICAgY29uc3QgcGFyZW50Q2lkcyA9IERPTS5maW5kRXhpc3RpbmdQYXJlbnRDSURzKFxuICAgICAgICAgIHRoaXMuaWQsXG4gICAgICAgICAgdGhpcy5yZW5kZXJlZC5jb21wb25lbnRDSURzKGRpZmYpLFxuICAgICAgICApO1xuICAgICAgICBwYXJlbnRDaWRzLmZvckVhY2goKHBhcmVudENJRCkgPT4ge1xuICAgICAgICAgIGlmIChcbiAgICAgICAgICAgIHRoaXMuY29tcG9uZW50UGF0Y2goXG4gICAgICAgICAgICAgIHRoaXMucmVuZGVyZWQuZ2V0Q29tcG9uZW50KGRpZmYsIHBhcmVudENJRCksXG4gICAgICAgICAgICAgIHBhcmVudENJRCxcbiAgICAgICAgICAgIClcbiAgICAgICAgICApIHtcbiAgICAgICAgICAgIHBoeENoaWxkcmVuQWRkZWQgPSB0cnVlO1xuICAgICAgICAgIH1cbiAgICAgICAgfSk7XG4gICAgICB9KTtcbiAgICB9IGVsc2UgaWYgKCFpc0VtcHR5KGRpZmYpKSB7XG4gICAgICB0aGlzLmxpdmVTb2NrZXQudGltZShcImZ1bGwgcGF0Y2ggY29tcGxldGVcIiwgKCkgPT4ge1xuICAgICAgICBjb25zdCBbaHRtbCwgc3RyZWFtc10gPSB0aGlzLnJlbmRlckNvbnRhaW5lcihkaWZmLCBcInVwZGF0ZVwiKTtcbiAgICAgICAgY29uc3QgcGF0Y2ggPSBuZXcgRE9NUGF0Y2godGhpcywgdGhpcy5lbCwgdGhpcy5pZCwgaHRtbCwgc3RyZWFtcywgbnVsbCk7XG4gICAgICAgIHBoeENoaWxkcmVuQWRkZWQgPSB0aGlzLnBlcmZvcm1QYXRjaChwYXRjaCwgdHJ1ZSk7XG4gICAgICB9KTtcbiAgICB9XG5cbiAgICB0aGlzLmxpdmVTb2NrZXQuZGlzcGF0Y2hFdmVudHMoZXZlbnRzKTtcbiAgICBpZiAocGh4Q2hpbGRyZW5BZGRlZCkge1xuICAgICAgdGhpcy5qb2luTmV3Q2hpbGRyZW4oKTtcbiAgICB9XG4gIH1cblxuICByZW5kZXJDb250YWluZXIoZGlmZiwga2luZCkge1xuICAgIHJldHVybiB0aGlzLmxpdmVTb2NrZXQudGltZShgdG9TdHJpbmcgZGlmZiAoJHtraW5kfSlgLCAoKSA9PiB7XG4gICAgICBjb25zdCB0YWcgPSB0aGlzLmVsLnRhZ05hbWU7XG4gICAgICAvLyBEb24ndCBza2lwIGFueSBjb21wb25lbnQgaW4gdGhlIGRpZmYgbm9yIGFueSBtYXJrZWQgYXMgcHJ1bmVkXG4gICAgICAvLyAoYXMgdGhleSBtYXkgaGF2ZSBiZWVuIGFkZGVkIGJhY2spXG4gICAgICBjb25zdCBjaWRzID0gZGlmZiA/IHRoaXMucmVuZGVyZWQuY29tcG9uZW50Q0lEcyhkaWZmKSA6IG51bGw7XG4gICAgICBjb25zdCB7IGJ1ZmZlcjogaHRtbCwgc3RyZWFtcyB9ID0gdGhpcy5yZW5kZXJlZC50b1N0cmluZyhjaWRzKTtcbiAgICAgIHJldHVybiBbYDwke3RhZ30+JHtodG1sfTwvJHt0YWd9PmAsIHN0cmVhbXNdO1xuICAgIH0pO1xuICB9XG5cbiAgY29tcG9uZW50UGF0Y2goZGlmZiwgY2lkKSB7XG4gICAgaWYgKGlzRW1wdHkoZGlmZikpIHJldHVybiBmYWxzZTtcbiAgICBjb25zdCB7IGJ1ZmZlcjogaHRtbCwgc3RyZWFtcyB9ID0gdGhpcy5yZW5kZXJlZC5jb21wb25lbnRUb1N0cmluZyhjaWQpO1xuICAgIGNvbnN0IHBhdGNoID0gbmV3IERPTVBhdGNoKHRoaXMsIHRoaXMuZWwsIHRoaXMuaWQsIGh0bWwsIHN0cmVhbXMsIGNpZCk7XG4gICAgY29uc3QgY2hpbGRyZW5BZGRlZCA9IHRoaXMucGVyZm9ybVBhdGNoKHBhdGNoLCB0cnVlKTtcbiAgICByZXR1cm4gY2hpbGRyZW5BZGRlZDtcbiAgfVxuXG4gIGdldEhvb2soZWwpIHtcbiAgICByZXR1cm4gdGhpcy52aWV3SG9va3NbVmlld0hvb2suZWxlbWVudElEKGVsKV07XG4gIH1cblxuICBhZGRIb29rKGVsKSB7XG4gICAgY29uc3QgaG9va0VsSWQgPSBWaWV3SG9vay5lbGVtZW50SUQoZWwpO1xuXG4gICAgLy8gb25seSBldmVyIHRyeSB0byBhZGQgaG9va3MgdG8gZWxlbWVudHMgb3duZWQgYnkgdGhpcyB2aWV3XG4gICAgaWYgKGVsLmdldEF0dHJpYnV0ZSAmJiAhdGhpcy5vd25zRWxlbWVudChlbCkpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG5cbiAgICBpZiAoaG9va0VsSWQgJiYgIXRoaXMudmlld0hvb2tzW2hvb2tFbElkXSkge1xuICAgICAgLy8gaG9vayBjcmVhdGVkLCBidXQgbm90IGF0dGFjaGVkIChjcmVhdGVIb29rIGZvciB3ZWIgY29tcG9uZW50KVxuICAgICAgY29uc3QgaG9vayA9XG4gICAgICAgIERPTS5nZXRDdXN0b21FbEhvb2soZWwpIHx8XG4gICAgICAgIGxvZ0Vycm9yKGBubyBob29rIGZvdW5kIGZvciBjdXN0b20gZWxlbWVudDogJHtlbC5pZH1gKTtcbiAgICAgIHRoaXMudmlld0hvb2tzW2hvb2tFbElkXSA9IGhvb2s7XG4gICAgICBob29rLl9fYXR0YWNoVmlldyh0aGlzKTtcbiAgICAgIHJldHVybiBob29rO1xuICAgIH0gZWxzZSBpZiAoaG9va0VsSWQgfHwgIWVsLmdldEF0dHJpYnV0ZSkge1xuICAgICAgLy8gbm8gaG9vayBmb3VuZFxuICAgICAgcmV0dXJuO1xuICAgIH0gZWxzZSB7XG4gICAgICAvLyBuZXcgaG9vayBmb3VuZCB3aXRoIHBoeC1ob29rIGF0dHJpYnV0ZVxuICAgICAgY29uc3QgaG9va05hbWUgPVxuICAgICAgICBlbC5nZXRBdHRyaWJ1dGUoYGRhdGEtcGh4LSR7UEhYX0hPT0t9YCkgfHxcbiAgICAgICAgZWwuZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhQSFhfSE9PSykpO1xuXG4gICAgICBpZiAoIWhvb2tOYW1lKSB7XG4gICAgICAgIHJldHVybjtcbiAgICAgIH1cblxuICAgICAgY29uc3QgaG9va0RlZmluaXRpb24gPSB0aGlzLmxpdmVTb2NrZXQuZ2V0SG9va0RlZmluaXRpb24oaG9va05hbWUpO1xuXG4gICAgICBpZiAoaG9va0RlZmluaXRpb24pIHtcbiAgICAgICAgaWYgKCFlbC5pZCkge1xuICAgICAgICAgIGxvZ0Vycm9yKFxuICAgICAgICAgICAgYG5vIERPTSBJRCBmb3IgaG9vayBcIiR7aG9va05hbWV9XCIuIEhvb2tzIHJlcXVpcmUgYSB1bmlxdWUgSUQgb24gZWFjaCBlbGVtZW50LmAsXG4gICAgICAgICAgICBlbCxcbiAgICAgICAgICApO1xuICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIGxldCBob29rSW5zdGFuY2U7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgaWYgKFxuICAgICAgICAgICAgdHlwZW9mIGhvb2tEZWZpbml0aW9uID09PSBcImZ1bmN0aW9uXCIgJiZcbiAgICAgICAgICAgIGhvb2tEZWZpbml0aW9uLnByb3RvdHlwZSBpbnN0YW5jZW9mIFZpZXdIb29rXG4gICAgICAgICAgKSB7XG4gICAgICAgICAgICAvLyBJdCdzIGEgY2xhc3MgY29uc3RydWN0b3IgKHN1YmNsYXNzIG9mIFZpZXdIb29rKVxuICAgICAgICAgICAgaG9va0luc3RhbmNlID0gbmV3IGhvb2tEZWZpbml0aW9uKHRoaXMsIGVsKTsgLy8gYHRoaXNgIGlzIHRoZSBWaWV3IGluc3RhbmNlXG4gICAgICAgICAgfSBlbHNlIGlmIChcbiAgICAgICAgICAgIHR5cGVvZiBob29rRGVmaW5pdGlvbiA9PT0gXCJvYmplY3RcIiAmJlxuICAgICAgICAgICAgaG9va0RlZmluaXRpb24gIT09IG51bGxcbiAgICAgICAgICApIHtcbiAgICAgICAgICAgIC8vIEl0J3MgYW4gb2JqZWN0IGxpdGVyYWwsIHBhc3MgaXQgdG8gdGhlIFZpZXdIb29rIGNvbnN0cnVjdG9yIGZvciB3cmFwcGluZ1xuICAgICAgICAgICAgaG9va0luc3RhbmNlID0gbmV3IFZpZXdIb29rKHRoaXMsIGVsLCBob29rRGVmaW5pdGlvbik7XG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGxvZ0Vycm9yKFxuICAgICAgICAgICAgICBgSW52YWxpZCBob29rIGRlZmluaXRpb24gZm9yIFwiJHtob29rTmFtZX1cIi4gRXhwZWN0ZWQgYSBjbGFzcyBleHRlbmRpbmcgVmlld0hvb2sgb3IgYW4gb2JqZWN0IGRlZmluaXRpb24uYCxcbiAgICAgICAgICAgICAgZWwsXG4gICAgICAgICAgICApO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICAgIH1cbiAgICAgICAgfSBjYXRjaCAoZSkge1xuICAgICAgICAgIGNvbnN0IGVycm9yTWVzc2FnZSA9IGUgaW5zdGFuY2VvZiBFcnJvciA/IGUubWVzc2FnZSA6IFN0cmluZyhlKTtcbiAgICAgICAgICBsb2dFcnJvcihgRmFpbGVkIHRvIGNyZWF0ZSBob29rIFwiJHtob29rTmFtZX1cIjogJHtlcnJvck1lc3NhZ2V9YCwgZWwpO1xuICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMudmlld0hvb2tzW1ZpZXdIb29rLmVsZW1lbnRJRChob29rSW5zdGFuY2UuZWwpXSA9IGhvb2tJbnN0YW5jZTtcbiAgICAgICAgcmV0dXJuIGhvb2tJbnN0YW5jZTtcbiAgICAgIH0gZWxzZSBpZiAoaG9va05hbWUgIT09IG51bGwpIHtcbiAgICAgICAgbG9nRXJyb3IoYHVua25vd24gaG9vayBmb3VuZCBmb3IgXCIke2hvb2tOYW1lfVwiYCwgZWwpO1xuICAgICAgfVxuICAgIH1cbiAgfVxuXG4gIGRlc3Ryb3lIb29rKGhvb2spIHtcbiAgICAvLyBfX2Rlc3Ryb3llZCBjbGVhcnMgdGhlIGVsZW1lbnRJRCBmcm9tIHRoZSBob29rLCB0aGVyZWZvcmVcbiAgICAvLyB3ZSBuZWVkIHRvIGdldCBpdCBiZWZvcmUgY2FsbGluZyBfX2Rlc3Ryb3llZFxuICAgIGNvbnN0IGhvb2tJZCA9IFZpZXdIb29rLmVsZW1lbnRJRChob29rLmVsKTtcbiAgICBob29rLl9fZGVzdHJveWVkKCk7XG4gICAgaG9vay5fX2NsZWFudXBfXygpO1xuICAgIGRlbGV0ZSB0aGlzLnZpZXdIb29rc1tob29rSWRdO1xuICB9XG5cbiAgYXBwbHlQZW5kaW5nVXBkYXRlcygpIHtcbiAgICAvLyBwcmV2ZW50IHJhY2UgY29uZGl0aW9ucyB3aGVyZSB3ZSBtaWdodCBzdGlsbCBiZSBwZW5kaW5nIGEgbmV3XG4gICAgLy8gbmF2aWdhdGlvbiBhZnRlciBhcHBseWluZyB0aGUgY3VycmVudCBvbmU7XG4gICAgLy8gaWYgd2UgY2FsbCB1cGRhdGUgYW5kIGEgcGVuZGluZ0RpZmYgaXMgbm90IGFwcGxpZWQsIGl0IHdvdWxkXG4gICAgLy8gYmUgc2lsZW50bHkgZHJvcHBlZCBvdGhlcndpc2UsIGFzIHVwZGF0ZSB3b3VsZCBwdXNoIGl0IGJhY2sgdG9cbiAgICAvLyBwZW5kaW5nRGlmZnMsIGJ1dCB3ZSBjbGVhciBpdCBpbW1lZGlhdGVseSBhZnRlclxuICAgIGlmICh0aGlzLmxpdmVTb2NrZXQuaGFzUGVuZGluZ0xpbmsoKSAmJiB0aGlzLnJvb3QuaXNNYWluKCkpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgdGhpcy5wZW5kaW5nRGlmZnMuZm9yRWFjaCgoeyBkaWZmLCBldmVudHMgfSkgPT4gdGhpcy51cGRhdGUoZGlmZiwgZXZlbnRzKSk7XG4gICAgdGhpcy5wZW5kaW5nRGlmZnMgPSBbXTtcbiAgICB0aGlzLmVhY2hDaGlsZCgoY2hpbGQpID0+IGNoaWxkLmFwcGx5UGVuZGluZ1VwZGF0ZXMoKSk7XG4gIH1cblxuICBlYWNoQ2hpbGQoY2FsbGJhY2spIHtcbiAgICBjb25zdCBjaGlsZHJlbiA9IHRoaXMucm9vdC5jaGlsZHJlblt0aGlzLmlkXSB8fCB7fTtcbiAgICBmb3IgKGNvbnN0IGlkIGluIGNoaWxkcmVuKSB7XG4gICAgICBjYWxsYmFjayh0aGlzLmdldENoaWxkQnlJZChpZCkpO1xuICAgIH1cbiAgfVxuXG4gIG9uQ2hhbm5lbChldmVudCwgY2IpIHtcbiAgICB0aGlzLmxpdmVTb2NrZXQub25DaGFubmVsKHRoaXMuY2hhbm5lbCwgZXZlbnQsIChyZXNwKSA9PiB7XG4gICAgICBpZiAodGhpcy5pc0pvaW5QZW5kaW5nKCkpIHtcbiAgICAgICAgdGhpcy5yb290LnBlbmRpbmdKb2luT3BzLnB1c2goW3RoaXMsICgpID0+IGNiKHJlc3ApXSk7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICB0aGlzLmxpdmVTb2NrZXQucmVxdWVzdERPTVVwZGF0ZSgoKSA9PiBjYihyZXNwKSk7XG4gICAgICB9XG4gICAgfSk7XG4gIH1cblxuICBiaW5kQ2hhbm5lbCgpIHtcbiAgICAvLyBUaGUgZGlmZiBldmVudCBzaG91bGQgYmUgaGFuZGxlZCBieSB0aGUgcmVndWxhciB1cGRhdGUgb3BlcmF0aW9ucy5cbiAgICAvLyBBbGwgb3RoZXIgb3BlcmF0aW9ucyBhcmUgcXVldWVkIHRvIGJlIGFwcGxpZWQgb25seSBhZnRlciBqb2luLlxuICAgIHRoaXMubGl2ZVNvY2tldC5vbkNoYW5uZWwodGhpcy5jaGFubmVsLCBcImRpZmZcIiwgKHJhd0RpZmYpID0+IHtcbiAgICAgIHRoaXMubGl2ZVNvY2tldC5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgdGhpcy5hcHBseURpZmYoXCJ1cGRhdGVcIiwgcmF3RGlmZiwgKHsgZGlmZiwgZXZlbnRzIH0pID0+XG4gICAgICAgICAgdGhpcy51cGRhdGUoZGlmZiwgZXZlbnRzKSxcbiAgICAgICAgKTtcbiAgICAgIH0pO1xuICAgIH0pO1xuICAgIHRoaXMub25DaGFubmVsKFwicmVkaXJlY3RcIiwgKHsgdG8sIGZsYXNoIH0pID0+XG4gICAgICB0aGlzLm9uUmVkaXJlY3QoeyB0bywgZmxhc2ggfSksXG4gICAgKTtcbiAgICB0aGlzLm9uQ2hhbm5lbChcImxpdmVfcGF0Y2hcIiwgKHJlZGlyKSA9PiB0aGlzLm9uTGl2ZVBhdGNoKHJlZGlyKSk7XG4gICAgdGhpcy5vbkNoYW5uZWwoXCJsaXZlX3JlZGlyZWN0XCIsIChyZWRpcikgPT4gdGhpcy5vbkxpdmVSZWRpcmVjdChyZWRpcikpO1xuICAgIHRoaXMuY2hhbm5lbC5vbkVycm9yKChyZWFzb24pID0+IHRoaXMub25FcnJvcihyZWFzb24pKTtcbiAgICB0aGlzLmNoYW5uZWwub25DbG9zZSgocmVhc29uKSA9PiB0aGlzLm9uQ2xvc2UocmVhc29uKSk7XG4gIH1cblxuICBkZXN0cm95QWxsQ2hpbGRyZW4oKSB7XG4gICAgdGhpcy5lYWNoQ2hpbGQoKGNoaWxkKSA9PiBjaGlsZC5kZXN0cm95KCkpO1xuICB9XG5cbiAgb25MaXZlUmVkaXJlY3QocmVkaXIpIHtcbiAgICBjb25zdCB7IHRvLCBraW5kLCBmbGFzaCB9ID0gcmVkaXI7XG4gICAgY29uc3QgdXJsID0gdGhpcy5leHBhbmRVUkwodG8pO1xuICAgIGNvbnN0IGUgPSBuZXcgQ3VzdG9tRXZlbnQoXCJwaHg6c2VydmVyLW5hdmlnYXRlXCIsIHtcbiAgICAgIGRldGFpbDogeyB0bywga2luZCwgZmxhc2ggfSxcbiAgICB9KTtcbiAgICB0aGlzLmxpdmVTb2NrZXQuaGlzdG9yeVJlZGlyZWN0KGUsIHVybCwga2luZCwgZmxhc2gpO1xuICB9XG5cbiAgb25MaXZlUGF0Y2gocmVkaXIpIHtcbiAgICBjb25zdCB7IHRvLCBraW5kIH0gPSByZWRpcjtcbiAgICB0aGlzLmhyZWYgPSB0aGlzLmV4cGFuZFVSTCh0byk7XG4gICAgdGhpcy5saXZlU29ja2V0Lmhpc3RvcnlQYXRjaCh0bywga2luZCk7XG4gIH1cblxuICBleHBhbmRVUkwodG8pIHtcbiAgICByZXR1cm4gdG8uc3RhcnRzV2l0aChcIi9cIilcbiAgICAgID8gYCR7d2luZG93LmxvY2F0aW9uLnByb3RvY29sfS8vJHt3aW5kb3cubG9jYXRpb24uaG9zdH0ke3RvfWBcbiAgICAgIDogdG87XG4gIH1cblxuICAvKipcbiAgICogQHBhcmFtIHt7dG86IHN0cmluZywgZmxhc2g/OiBzdHJpbmcsIHJlbG9hZFRva2VuPzogc3RyaW5nfX0gcmVkaXJlY3RcbiAgICovXG4gIG9uUmVkaXJlY3QoeyB0bywgZmxhc2gsIHJlbG9hZFRva2VuIH0pIHtcbiAgICB0aGlzLmxpdmVTb2NrZXQucmVkaXJlY3QodG8sIGZsYXNoLCByZWxvYWRUb2tlbik7XG4gIH1cblxuICBpc0Rlc3Ryb3llZCgpIHtcbiAgICByZXR1cm4gdGhpcy5kZXN0cm95ZWQ7XG4gIH1cblxuICBqb2luRGVhZCgpIHtcbiAgICB0aGlzLmlzRGVhZCA9IHRydWU7XG4gIH1cblxuICBqb2luUHVzaCgpIHtcbiAgICB0aGlzLmpvaW5QdXNoID0gdGhpcy5qb2luUHVzaCB8fCB0aGlzLmNoYW5uZWwuam9pbigpO1xuICAgIHJldHVybiB0aGlzLmpvaW5QdXNoO1xuICB9XG5cbiAgam9pbihjYWxsYmFjaykge1xuICAgIHRoaXMuc2hvd0xvYWRlcih0aGlzLmxpdmVTb2NrZXQubG9hZGVyVGltZW91dCk7XG4gICAgdGhpcy5iaW5kQ2hhbm5lbCgpO1xuICAgIGlmICh0aGlzLmlzTWFpbigpKSB7XG4gICAgICB0aGlzLnN0b3BDYWxsYmFjayA9IHRoaXMubGl2ZVNvY2tldC53aXRoUGFnZUxvYWRpbmcoe1xuICAgICAgICB0bzogdGhpcy5ocmVmLFxuICAgICAgICBraW5kOiBcImluaXRpYWxcIixcbiAgICAgIH0pO1xuICAgIH1cbiAgICB0aGlzLmpvaW5DYWxsYmFjayA9IChvbkRvbmUpID0+IHtcbiAgICAgIG9uRG9uZSA9IG9uRG9uZSB8fCBmdW5jdGlvbiAoKSB7fTtcbiAgICAgIGNhbGxiYWNrID8gY2FsbGJhY2sodGhpcy5qb2luQ291bnQsIG9uRG9uZSkgOiBvbkRvbmUoKTtcbiAgICB9O1xuXG4gICAgdGhpcy53cmFwUHVzaCgoKSA9PiB0aGlzLmNoYW5uZWwuam9pbigpLCB7XG4gICAgICBvazogKHJlc3ApID0+IHRoaXMubGl2ZVNvY2tldC5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHRoaXMub25Kb2luKHJlc3ApKSxcbiAgICAgIGVycm9yOiAoZXJyb3IpID0+IHRoaXMub25Kb2luRXJyb3IoZXJyb3IpLFxuICAgICAgdGltZW91dDogKCkgPT4gdGhpcy5vbkpvaW5FcnJvcih7IHJlYXNvbjogXCJ0aW1lb3V0XCIgfSksXG4gICAgfSk7XG4gIH1cblxuICBvbkpvaW5FcnJvcihyZXNwKSB7XG4gICAgaWYgKHJlc3AucmVhc29uID09PSBcInJlbG9hZFwiKSB7XG4gICAgICB0aGlzLmxvZyhcImVycm9yXCIsICgpID0+IFtcbiAgICAgICAgYGZhaWxlZCBtb3VudCB3aXRoICR7cmVzcC5zdGF0dXN9LiBGYWxsaW5nIGJhY2sgdG8gcGFnZSByZWxvYWRgLFxuICAgICAgICByZXNwLFxuICAgICAgXSk7XG4gICAgICB0aGlzLm9uUmVkaXJlY3QoeyB0bzogdGhpcy5yb290LmhyZWYsIHJlbG9hZFRva2VuOiByZXNwLnRva2VuIH0pO1xuICAgICAgcmV0dXJuO1xuICAgIH0gZWxzZSBpZiAocmVzcC5yZWFzb24gPT09IFwidW5hdXRob3JpemVkXCIgfHwgcmVzcC5yZWFzb24gPT09IFwic3RhbGVcIikge1xuICAgICAgdGhpcy5sb2coXCJlcnJvclwiLCAoKSA9PiBbXG4gICAgICAgIFwidW5hdXRob3JpemVkIGxpdmVfcmVkaXJlY3QuIEZhbGxpbmcgYmFjayB0byBwYWdlIHJlcXVlc3RcIixcbiAgICAgICAgcmVzcCxcbiAgICAgIF0pO1xuICAgICAgdGhpcy5vblJlZGlyZWN0KHsgdG86IHRoaXMucm9vdC5ocmVmLCBmbGFzaDogdGhpcy5mbGFzaCB9KTtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgaWYgKHJlc3AucmVkaXJlY3QgfHwgcmVzcC5saXZlX3JlZGlyZWN0KSB7XG4gICAgICB0aGlzLmpvaW5QZW5kaW5nID0gZmFsc2U7XG4gICAgICB0aGlzLmNoYW5uZWwubGVhdmUoKTtcbiAgICB9XG4gICAgaWYgKHJlc3AucmVkaXJlY3QpIHtcbiAgICAgIHJldHVybiB0aGlzLm9uUmVkaXJlY3QocmVzcC5yZWRpcmVjdCk7XG4gICAgfVxuICAgIGlmIChyZXNwLmxpdmVfcmVkaXJlY3QpIHtcbiAgICAgIHJldHVybiB0aGlzLm9uTGl2ZVJlZGlyZWN0KHJlc3AubGl2ZV9yZWRpcmVjdCk7XG4gICAgfVxuICAgIHRoaXMubG9nKFwiZXJyb3JcIiwgKCkgPT4gW1widW5hYmxlIHRvIGpvaW5cIiwgcmVzcF0pO1xuICAgIGlmICh0aGlzLmlzTWFpbigpKSB7XG4gICAgICB0aGlzLmRpc3BsYXlFcnJvcihbXG4gICAgICAgIFBIWF9MT0FESU5HX0NMQVNTLFxuICAgICAgICBQSFhfRVJST1JfQ0xBU1MsXG4gICAgICAgIFBIWF9TRVJWRVJfRVJST1JfQ0xBU1MsXG4gICAgICBdKTtcbiAgICAgIGlmICh0aGlzLmxpdmVTb2NrZXQuaXNDb25uZWN0ZWQoKSkge1xuICAgICAgICB0aGlzLmxpdmVTb2NrZXQucmVsb2FkV2l0aEppdHRlcih0aGlzKTtcbiAgICAgIH1cbiAgICB9IGVsc2Uge1xuICAgICAgaWYgKHRoaXMuam9pbkF0dGVtcHRzID49IE1BWF9DSElMRF9KT0lOX0FUVEVNUFRTKSB7XG4gICAgICAgIC8vIHB1dCB0aGUgcm9vdCByZXZpZXcgaW50byBwZXJtYW5lbnQgZXJyb3Igc3RhdGUsIGJ1dCBkb24ndCBkZXN0cm95IGl0IGFzIGl0IGNhbiByZW1haW4gYWN0aXZlXG4gICAgICAgIHRoaXMucm9vdC5kaXNwbGF5RXJyb3IoW1xuICAgICAgICAgIFBIWF9MT0FESU5HX0NMQVNTLFxuICAgICAgICAgIFBIWF9FUlJPUl9DTEFTUyxcbiAgICAgICAgICBQSFhfU0VSVkVSX0VSUk9SX0NMQVNTLFxuICAgICAgICBdKTtcbiAgICAgICAgdGhpcy5sb2coXCJlcnJvclwiLCAoKSA9PiBbXG4gICAgICAgICAgYGdpdmluZyB1cCB0cnlpbmcgdG8gbW91bnQgYWZ0ZXIgJHtNQVhfQ0hJTERfSk9JTl9BVFRFTVBUU30gdHJpZXNgLFxuICAgICAgICAgIHJlc3AsXG4gICAgICAgIF0pO1xuICAgICAgICB0aGlzLmRlc3Ryb3koKTtcbiAgICAgIH1cbiAgICAgIGNvbnN0IHRydWVDaGlsZEVsID0gRE9NLmJ5SWQodGhpcy5lbC5pZCk7XG4gICAgICBpZiAodHJ1ZUNoaWxkRWwpIHtcbiAgICAgICAgRE9NLm1lcmdlQXR0cnModHJ1ZUNoaWxkRWwsIHRoaXMuZWwpO1xuICAgICAgICB0aGlzLmRpc3BsYXlFcnJvcihbXG4gICAgICAgICAgUEhYX0xPQURJTkdfQ0xBU1MsXG4gICAgICAgICAgUEhYX0VSUk9SX0NMQVNTLFxuICAgICAgICAgIFBIWF9TRVJWRVJfRVJST1JfQ0xBU1MsXG4gICAgICAgIF0pO1xuICAgICAgICB0aGlzLmVsID0gdHJ1ZUNoaWxkRWw7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICB0aGlzLmRlc3Ryb3koKTtcbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICBvbkNsb3NlKHJlYXNvbikge1xuICAgIGlmICh0aGlzLmlzRGVzdHJveWVkKCkpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgaWYgKFxuICAgICAgdGhpcy5pc01haW4oKSAmJlxuICAgICAgdGhpcy5saXZlU29ja2V0Lmhhc1BlbmRpbmdMaW5rKCkgJiZcbiAgICAgIHJlYXNvbiAhPT0gXCJsZWF2ZVwiXG4gICAgKSB7XG4gICAgICByZXR1cm4gdGhpcy5saXZlU29ja2V0LnJlbG9hZFdpdGhKaXR0ZXIodGhpcyk7XG4gICAgfVxuICAgIHRoaXMuZGVzdHJveUFsbENoaWxkcmVuKCk7XG4gICAgdGhpcy5saXZlU29ja2V0LmRyb3BBY3RpdmVFbGVtZW50KHRoaXMpO1xuICAgIGlmICh0aGlzLmxpdmVTb2NrZXQuaXNVbmxvYWRlZCgpKSB7XG4gICAgICB0aGlzLnNob3dMb2FkZXIoQkVGT1JFX1VOTE9BRF9MT0FERVJfVElNRU9VVCk7XG4gICAgfVxuICB9XG5cbiAgb25FcnJvcihyZWFzb24pIHtcbiAgICB0aGlzLm9uQ2xvc2UocmVhc29uKTtcbiAgICBpZiAodGhpcy5saXZlU29ja2V0LmlzQ29ubmVjdGVkKCkpIHtcbiAgICAgIHRoaXMubG9nKFwiZXJyb3JcIiwgKCkgPT4gW1widmlldyBjcmFzaGVkXCIsIHJlYXNvbl0pO1xuICAgIH1cbiAgICBpZiAoIXRoaXMubGl2ZVNvY2tldC5pc1VubG9hZGVkKCkpIHtcbiAgICAgIGlmICh0aGlzLmxpdmVTb2NrZXQuaXNDb25uZWN0ZWQoKSkge1xuICAgICAgICB0aGlzLmRpc3BsYXlFcnJvcihbXG4gICAgICAgICAgUEhYX0xPQURJTkdfQ0xBU1MsXG4gICAgICAgICAgUEhYX0VSUk9SX0NMQVNTLFxuICAgICAgICAgIFBIWF9TRVJWRVJfRVJST1JfQ0xBU1MsXG4gICAgICAgIF0pO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdGhpcy5kaXNwbGF5RXJyb3IoW1xuICAgICAgICAgIFBIWF9MT0FESU5HX0NMQVNTLFxuICAgICAgICAgIFBIWF9FUlJPUl9DTEFTUyxcbiAgICAgICAgICBQSFhfQ0xJRU5UX0VSUk9SX0NMQVNTLFxuICAgICAgICBdKTtcbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICBkaXNwbGF5RXJyb3IoY2xhc3Nlcykge1xuICAgIGlmICh0aGlzLmlzTWFpbigpKSB7XG4gICAgICBET00uZGlzcGF0Y2hFdmVudCh3aW5kb3csIFwicGh4OnBhZ2UtbG9hZGluZy1zdGFydFwiLCB7XG4gICAgICAgIGRldGFpbDogeyB0bzogdGhpcy5ocmVmLCBraW5kOiBcImVycm9yXCIgfSxcbiAgICAgIH0pO1xuICAgIH1cbiAgICB0aGlzLnNob3dMb2FkZXIoKTtcbiAgICB0aGlzLnNldENvbnRhaW5lckNsYXNzZXMoLi4uY2xhc3Nlcyk7XG4gICAgdGhpcy5kZWxheWVkRGlzY29ubmVjdGVkKCk7XG4gIH1cblxuICBkZWxheWVkRGlzY29ubmVjdGVkKCkge1xuICAgIHRoaXMuZGlzY29ubmVjdGVkVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgIHRoaXMuZXhlY0FsbCh0aGlzLmJpbmRpbmcoXCJkaXNjb25uZWN0ZWRcIikpO1xuICAgIH0sIHRoaXMubGl2ZVNvY2tldC5kaXNjb25uZWN0ZWRUaW1lb3V0KTtcbiAgfVxuXG4gIHdyYXBQdXNoKGNhbGxlclB1c2gsIHJlY2VpdmVzKSB7XG4gICAgY29uc3QgbGF0ZW5jeSA9IHRoaXMubGl2ZVNvY2tldC5nZXRMYXRlbmN5U2ltKCk7XG4gICAgY29uc3Qgd2l0aExhdGVuY3kgPSBsYXRlbmN5XG4gICAgICA/IChjYikgPT4gc2V0VGltZW91dCgoKSA9PiAhdGhpcy5pc0Rlc3Ryb3llZCgpICYmIGNiKCksIGxhdGVuY3kpXG4gICAgICA6IChjYikgPT4gIXRoaXMuaXNEZXN0cm95ZWQoKSAmJiBjYigpO1xuXG4gICAgd2l0aExhdGVuY3koKCkgPT4ge1xuICAgICAgY2FsbGVyUHVzaCgpXG4gICAgICAgIC5yZWNlaXZlKFwib2tcIiwgKHJlc3ApID0+XG4gICAgICAgICAgd2l0aExhdGVuY3koKCkgPT4gcmVjZWl2ZXMub2sgJiYgcmVjZWl2ZXMub2socmVzcCkpLFxuICAgICAgICApXG4gICAgICAgIC5yZWNlaXZlKFwiZXJyb3JcIiwgKHJlYXNvbikgPT5cbiAgICAgICAgICB3aXRoTGF0ZW5jeSgoKSA9PiByZWNlaXZlcy5lcnJvciAmJiByZWNlaXZlcy5lcnJvcihyZWFzb24pKSxcbiAgICAgICAgKVxuICAgICAgICAucmVjZWl2ZShcInRpbWVvdXRcIiwgKCkgPT5cbiAgICAgICAgICB3aXRoTGF0ZW5jeSgoKSA9PiByZWNlaXZlcy50aW1lb3V0ICYmIHJlY2VpdmVzLnRpbWVvdXQoKSksXG4gICAgICAgICk7XG4gICAgfSk7XG4gIH1cblxuICBwdXNoV2l0aFJlcGx5KHJlZkdlbmVyYXRvciwgZXZlbnQsIHBheWxvYWQpIHtcbiAgICBpZiAoIXRoaXMuaXNDb25uZWN0ZWQoKSkge1xuICAgICAgcmV0dXJuIFByb21pc2UucmVqZWN0KG5ldyBFcnJvcihcIm5vIGNvbm5lY3Rpb25cIikpO1xuICAgIH1cblxuICAgIGNvbnN0IFtyZWYsIFtlbF0sIG9wdHNdID0gcmVmR2VuZXJhdG9yXG4gICAgICA/IHJlZkdlbmVyYXRvcih7IHBheWxvYWQgfSlcbiAgICAgIDogW251bGwsIFtdLCB7fV07XG4gICAgY29uc3Qgb2xkSm9pbkNvdW50ID0gdGhpcy5qb2luQ291bnQ7XG4gICAgbGV0IG9uTG9hZGluZ0RvbmUgPSBmdW5jdGlvbiAoKSB7fTtcbiAgICBpZiAob3B0cy5wYWdlX2xvYWRpbmcpIHtcbiAgICAgIG9uTG9hZGluZ0RvbmUgPSB0aGlzLmxpdmVTb2NrZXQud2l0aFBhZ2VMb2FkaW5nKHtcbiAgICAgICAga2luZDogXCJlbGVtZW50XCIsXG4gICAgICAgIHRhcmdldDogZWwsXG4gICAgICB9KTtcbiAgICB9XG5cbiAgICBpZiAodHlwZW9mIHBheWxvYWQuY2lkICE9PSBcIm51bWJlclwiKSB7XG4gICAgICBkZWxldGUgcGF5bG9hZC5jaWQ7XG4gICAgfVxuXG4gICAgcmV0dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlLCByZWplY3QpID0+IHtcbiAgICAgIHRoaXMud3JhcFB1c2goKCkgPT4gdGhpcy5jaGFubmVsLnB1c2goZXZlbnQsIHBheWxvYWQsIFBVU0hfVElNRU9VVCksIHtcbiAgICAgICAgb2s6IChyZXNwKSA9PiB7XG4gICAgICAgICAgaWYgKHJlZiAhPT0gbnVsbCkge1xuICAgICAgICAgICAgdGhpcy5sYXN0QWNrUmVmID0gcmVmO1xuICAgICAgICAgIH1cbiAgICAgICAgICBjb25zdCBmaW5pc2ggPSAoaG9va1JlcGx5KSA9PiB7XG4gICAgICAgICAgICBpZiAocmVzcC5yZWRpcmVjdCkge1xuICAgICAgICAgICAgICB0aGlzLm9uUmVkaXJlY3QocmVzcC5yZWRpcmVjdCk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICBpZiAocmVzcC5saXZlX3BhdGNoKSB7XG4gICAgICAgICAgICAgIHRoaXMub25MaXZlUGF0Y2gocmVzcC5saXZlX3BhdGNoKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgICAgIGlmIChyZXNwLmxpdmVfcmVkaXJlY3QpIHtcbiAgICAgICAgICAgICAgdGhpcy5vbkxpdmVSZWRpcmVjdChyZXNwLmxpdmVfcmVkaXJlY3QpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgb25Mb2FkaW5nRG9uZSgpO1xuICAgICAgICAgICAgcmVzb2x2ZSh7IHJlc3A6IHJlc3AsIHJlcGx5OiBob29rUmVwbHksIHJlZiB9KTtcbiAgICAgICAgICB9O1xuICAgICAgICAgIGlmIChyZXNwLmRpZmYpIHtcbiAgICAgICAgICAgIHRoaXMubGl2ZVNvY2tldC5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgICAgICAgdGhpcy5hcHBseURpZmYoXCJ1cGRhdGVcIiwgcmVzcC5kaWZmLCAoeyBkaWZmLCByZXBseSwgZXZlbnRzIH0pID0+IHtcbiAgICAgICAgICAgICAgICBpZiAocmVmICE9PSBudWxsKSB7XG4gICAgICAgICAgICAgICAgICB0aGlzLnVuZG9SZWZzKHJlZiwgcGF5bG9hZC5ldmVudCk7XG4gICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIHRoaXMudXBkYXRlKGRpZmYsIGV2ZW50cyk7XG4gICAgICAgICAgICAgICAgZmluaXNoKHJlcGx5KTtcbiAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICB9KTtcbiAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgaWYgKHJlZiAhPT0gbnVsbCkge1xuICAgICAgICAgICAgICB0aGlzLnVuZG9SZWZzKHJlZiwgcGF5bG9hZC5ldmVudCk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICBmaW5pc2gobnVsbCk7XG4gICAgICAgICAgfVxuICAgICAgICB9LFxuICAgICAgICBlcnJvcjogKHJlYXNvbikgPT4gcmVqZWN0KG5ldyBFcnJvcihgZmFpbGVkIHdpdGggcmVhc29uOiAke3JlYXNvbn1gKSksXG4gICAgICAgIHRpbWVvdXQ6ICgpID0+IHtcbiAgICAgICAgICByZWplY3QobmV3IEVycm9yKFwidGltZW91dFwiKSk7XG4gICAgICAgICAgaWYgKHRoaXMuam9pbkNvdW50ID09PSBvbGRKb2luQ291bnQpIHtcbiAgICAgICAgICAgIHRoaXMubGl2ZVNvY2tldC5yZWxvYWRXaXRoSml0dGVyKHRoaXMsICgpID0+IHtcbiAgICAgICAgICAgICAgdGhpcy5sb2coXCJ0aW1lb3V0XCIsICgpID0+IFtcbiAgICAgICAgICAgICAgICBcInJlY2VpdmVkIHRpbWVvdXQgd2hpbGUgY29tbXVuaWNhdGluZyB3aXRoIHNlcnZlci4gRmFsbGluZyBiYWNrIHRvIGhhcmQgcmVmcmVzaCBmb3IgcmVjb3ZlcnlcIixcbiAgICAgICAgICAgICAgXSk7XG4gICAgICAgICAgICB9KTtcbiAgICAgICAgICB9XG4gICAgICAgIH0sXG4gICAgICB9KTtcbiAgICB9KTtcbiAgfVxuXG4gIHVuZG9SZWZzKHJlZiwgcGh4RXZlbnQsIG9ubHlFbHMpIHtcbiAgICBpZiAoIXRoaXMuaXNDb25uZWN0ZWQoKSkge1xuICAgICAgcmV0dXJuO1xuICAgIH0gLy8gZXhpdCBpZiBleHRlcm5hbCBmb3JtIHRyaWdnZXJlZFxuICAgIGNvbnN0IHNlbGVjdG9yID0gYFske1BIWF9SRUZfU1JDfT1cIiR7dGhpcy5yZWZTcmMoKX1cIl1gO1xuXG4gICAgaWYgKG9ubHlFbHMpIHtcbiAgICAgIG9ubHlFbHMgPSBuZXcgU2V0KG9ubHlFbHMpO1xuICAgICAgRE9NLmFsbChkb2N1bWVudCwgc2VsZWN0b3IsIChwYXJlbnQpID0+IHtcbiAgICAgICAgaWYgKG9ubHlFbHMgJiYgIW9ubHlFbHMuaGFzKHBhcmVudCkpIHtcbiAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cbiAgICAgICAgLy8gdW5kbyBhbnkgY2hpbGQgcmVmcyB3aXRoaW4gcGFyZW50IGZpcnN0XG4gICAgICAgIERPTS5hbGwocGFyZW50LCBzZWxlY3RvciwgKGNoaWxkKSA9PlxuICAgICAgICAgIHRoaXMudW5kb0VsUmVmKGNoaWxkLCByZWYsIHBoeEV2ZW50KSxcbiAgICAgICAgKTtcbiAgICAgICAgdGhpcy51bmRvRWxSZWYocGFyZW50LCByZWYsIHBoeEV2ZW50KTtcbiAgICAgIH0pO1xuICAgIH0gZWxzZSB7XG4gICAgICBET00uYWxsKGRvY3VtZW50LCBzZWxlY3RvciwgKGVsKSA9PiB0aGlzLnVuZG9FbFJlZihlbCwgcmVmLCBwaHhFdmVudCkpO1xuICAgIH1cbiAgfVxuXG4gIHVuZG9FbFJlZihlbCwgcmVmLCBwaHhFdmVudCkge1xuICAgIGNvbnN0IGVsUmVmID0gbmV3IEVsZW1lbnRSZWYoZWwpO1xuXG4gICAgZWxSZWYubWF5YmVVbmRvKHJlZiwgcGh4RXZlbnQsIChjbG9uZWRUcmVlKSA9PiB7XG4gICAgICAvLyB3ZSBuZWVkIHRvIHBlcmZvcm0gYSBmdWxsIHBhdGNoIG9uIHVubG9ja2VkIGVsZW1lbnRzXG4gICAgICAvLyB0byBwZXJmb3JtIGFsbCB0aGUgbmVjZXNzYXJ5IGxvZ2ljIChsaWtlIGNhbGxpbmcgdXBkYXRlZCBmb3IgaG9va3MsIGV0Yy4pXG4gICAgICBjb25zdCBwYXRjaCA9IG5ldyBET01QYXRjaCh0aGlzLCBlbCwgdGhpcy5pZCwgY2xvbmVkVHJlZSwgW10sIG51bGwsIHtcbiAgICAgICAgdW5kb1JlZjogcmVmLFxuICAgICAgfSk7XG4gICAgICBjb25zdCBwaHhDaGlsZHJlbkFkZGVkID0gdGhpcy5wZXJmb3JtUGF0Y2gocGF0Y2gsIHRydWUpO1xuICAgICAgRE9NLmFsbChlbCwgYFske1BIWF9SRUZfU1JDfT1cIiR7dGhpcy5yZWZTcmMoKX1cIl1gLCAoY2hpbGQpID0+XG4gICAgICAgIHRoaXMudW5kb0VsUmVmKGNoaWxkLCByZWYsIHBoeEV2ZW50KSxcbiAgICAgICk7XG4gICAgICBpZiAocGh4Q2hpbGRyZW5BZGRlZCkge1xuICAgICAgICB0aGlzLmpvaW5OZXdDaGlsZHJlbigpO1xuICAgICAgfVxuICAgIH0pO1xuICB9XG5cbiAgcmVmU3JjKCkge1xuICAgIHJldHVybiB0aGlzLmVsLmlkO1xuICB9XG5cbiAgcHV0UmVmKGVsZW1lbnRzLCBwaHhFdmVudCwgZXZlbnRUeXBlLCBvcHRzID0ge30pIHtcbiAgICBjb25zdCBuZXdSZWYgPSB0aGlzLnJlZisrO1xuICAgIGNvbnN0IGRpc2FibGVXaXRoID0gdGhpcy5iaW5kaW5nKFBIWF9ESVNBQkxFX1dJVEgpO1xuICAgIGlmIChvcHRzLmxvYWRpbmcpIHtcbiAgICAgIGNvbnN0IGxvYWRpbmdFbHMgPSBET00uYWxsKGRvY3VtZW50LCBvcHRzLmxvYWRpbmcpLm1hcCgoZWwpID0+IHtcbiAgICAgICAgcmV0dXJuIHsgZWwsIGxvY2s6IHRydWUsIGxvYWRpbmc6IHRydWUgfTtcbiAgICAgIH0pO1xuICAgICAgZWxlbWVudHMgPSBlbGVtZW50cy5jb25jYXQobG9hZGluZ0Vscyk7XG4gICAgfVxuXG4gICAgZm9yIChjb25zdCB7IGVsLCBsb2NrLCBsb2FkaW5nIH0gb2YgZWxlbWVudHMpIHtcbiAgICAgIGlmICghbG9jayAmJiAhbG9hZGluZykge1xuICAgICAgICB0aHJvdyBuZXcgRXJyb3IoXCJwdXRSZWYgcmVxdWlyZXMgbG9jayBvciBsb2FkaW5nXCIpO1xuICAgICAgfVxuICAgICAgZWwuc2V0QXR0cmlidXRlKFBIWF9SRUZfU1JDLCB0aGlzLnJlZlNyYygpKTtcbiAgICAgIGlmIChsb2FkaW5nKSB7XG4gICAgICAgIGVsLnNldEF0dHJpYnV0ZShQSFhfUkVGX0xPQURJTkcsIG5ld1JlZik7XG4gICAgICB9XG4gICAgICBpZiAobG9jaykge1xuICAgICAgICBlbC5zZXRBdHRyaWJ1dGUoUEhYX1JFRl9MT0NLLCBuZXdSZWYpO1xuICAgICAgfVxuXG4gICAgICBpZiAoXG4gICAgICAgICFsb2FkaW5nIHx8XG4gICAgICAgIChvcHRzLnN1Ym1pdHRlciAmJiAhKGVsID09PSBvcHRzLnN1Ym1pdHRlciB8fCBlbCA9PT0gb3B0cy5mb3JtKSlcbiAgICAgICkge1xuICAgICAgICBjb250aW51ZTtcbiAgICAgIH1cblxuICAgICAgY29uc3QgbG9ja0NvbXBsZXRlUHJvbWlzZSA9IG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiB7XG4gICAgICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoYHBoeDp1bmRvLWxvY2s6JHtuZXdSZWZ9YCwgKCkgPT4gcmVzb2x2ZShkZXRhaWwpLCB7XG4gICAgICAgICAgb25jZTogdHJ1ZSxcbiAgICAgICAgfSk7XG4gICAgICB9KTtcblxuICAgICAgY29uc3QgbG9hZGluZ0NvbXBsZXRlUHJvbWlzZSA9IG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiB7XG4gICAgICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoXG4gICAgICAgICAgYHBoeDp1bmRvLWxvYWRpbmc6JHtuZXdSZWZ9YCxcbiAgICAgICAgICAoKSA9PiByZXNvbHZlKGRldGFpbCksXG4gICAgICAgICAgeyBvbmNlOiB0cnVlIH0sXG4gICAgICAgICk7XG4gICAgICB9KTtcblxuICAgICAgZWwuY2xhc3NMaXN0LmFkZChgcGh4LSR7ZXZlbnRUeXBlfS1sb2FkaW5nYCk7XG4gICAgICBjb25zdCBkaXNhYmxlVGV4dCA9IGVsLmdldEF0dHJpYnV0ZShkaXNhYmxlV2l0aCk7XG4gICAgICBpZiAoZGlzYWJsZVRleHQgIT09IG51bGwpIHtcbiAgICAgICAgaWYgKCFlbC5nZXRBdHRyaWJ1dGUoUEhYX0RJU0FCTEVfV0lUSF9SRVNUT1JFKSkge1xuICAgICAgICAgIGVsLnNldEF0dHJpYnV0ZShQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUsIGVsLmlubmVyVGV4dCk7XG4gICAgICAgIH1cbiAgICAgICAgaWYgKGRpc2FibGVUZXh0ICE9PSBcIlwiKSB7XG4gICAgICAgICAgZWwuaW5uZXJUZXh0ID0gZGlzYWJsZVRleHQ7XG4gICAgICAgIH1cbiAgICAgICAgLy8gUEhYX0RJU0FCTEVEIGNvdWxkIGhhdmUgYWxyZWFkeSBiZWVuIHNldCBpbiBkaXNhYmxlRm9ybVxuICAgICAgICBlbC5zZXRBdHRyaWJ1dGUoXG4gICAgICAgICAgUEhYX0RJU0FCTEVELFxuICAgICAgICAgIGVsLmdldEF0dHJpYnV0ZShQSFhfRElTQUJMRUQpIHx8IGVsLmRpc2FibGVkLFxuICAgICAgICApO1xuICAgICAgICBlbC5zZXRBdHRyaWJ1dGUoXCJkaXNhYmxlZFwiLCBcIlwiKTtcbiAgICAgIH1cblxuICAgICAgY29uc3QgZGV0YWlsID0ge1xuICAgICAgICBldmVudDogcGh4RXZlbnQsXG4gICAgICAgIGV2ZW50VHlwZTogZXZlbnRUeXBlLFxuICAgICAgICByZWY6IG5ld1JlZixcbiAgICAgICAgaXNMb2FkaW5nOiBsb2FkaW5nLFxuICAgICAgICBpc0xvY2tlZDogbG9jayxcbiAgICAgICAgbG9ja0VsZW1lbnRzOiBlbGVtZW50cy5maWx0ZXIoKHsgbG9jayB9KSA9PiBsb2NrKS5tYXAoKHsgZWwgfSkgPT4gZWwpLFxuICAgICAgICBsb2FkaW5nRWxlbWVudHM6IGVsZW1lbnRzXG4gICAgICAgICAgLmZpbHRlcigoeyBsb2FkaW5nIH0pID0+IGxvYWRpbmcpXG4gICAgICAgICAgLm1hcCgoeyBlbCB9KSA9PiBlbCksXG4gICAgICAgIHVubG9jazogKGVscykgPT4ge1xuICAgICAgICAgIGVscyA9IEFycmF5LmlzQXJyYXkoZWxzKSA/IGVscyA6IFtlbHNdO1xuICAgICAgICAgIHRoaXMudW5kb1JlZnMobmV3UmVmLCBwaHhFdmVudCwgZWxzKTtcbiAgICAgICAgfSxcbiAgICAgICAgbG9ja0NvbXBsZXRlOiBsb2NrQ29tcGxldGVQcm9taXNlLFxuICAgICAgICBsb2FkaW5nQ29tcGxldGU6IGxvYWRpbmdDb21wbGV0ZVByb21pc2UsXG4gICAgICAgIGxvY2s6IChsb2NrRWwpID0+IHtcbiAgICAgICAgICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUpID0+IHtcbiAgICAgICAgICAgIGlmICh0aGlzLmlzQWNrZWQobmV3UmVmKSkge1xuICAgICAgICAgICAgICByZXR1cm4gcmVzb2x2ZShkZXRhaWwpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgbG9ja0VsLnNldEF0dHJpYnV0ZShQSFhfUkVGX0xPQ0ssIG5ld1JlZik7XG4gICAgICAgICAgICBsb2NrRWwuc2V0QXR0cmlidXRlKFBIWF9SRUZfU1JDLCB0aGlzLnJlZlNyYygpKTtcbiAgICAgICAgICAgIGxvY2tFbC5hZGRFdmVudExpc3RlbmVyKFxuICAgICAgICAgICAgICBgcGh4OmxvY2stc3RvcDoke25ld1JlZn1gLFxuICAgICAgICAgICAgICAoKSA9PiByZXNvbHZlKGRldGFpbCksXG4gICAgICAgICAgICAgIHsgb25jZTogdHJ1ZSB9LFxuICAgICAgICAgICAgKTtcbiAgICAgICAgICB9KTtcbiAgICAgICAgfSxcbiAgICAgIH07XG4gICAgICBpZiAob3B0cy5wYXlsb2FkKSB7XG4gICAgICAgIGRldGFpbFtcInBheWxvYWRcIl0gPSBvcHRzLnBheWxvYWQ7XG4gICAgICB9XG4gICAgICBpZiAob3B0cy50YXJnZXQpIHtcbiAgICAgICAgZGV0YWlsW1widGFyZ2V0XCJdID0gb3B0cy50YXJnZXQ7XG4gICAgICB9XG4gICAgICBpZiAob3B0cy5vcmlnaW5hbEV2ZW50KSB7XG4gICAgICAgIGRldGFpbFtcIm9yaWdpbmFsRXZlbnRcIl0gPSBvcHRzLm9yaWdpbmFsRXZlbnQ7XG4gICAgICB9XG4gICAgICBlbC5kaXNwYXRjaEV2ZW50KFxuICAgICAgICBuZXcgQ3VzdG9tRXZlbnQoXCJwaHg6cHVzaFwiLCB7XG4gICAgICAgICAgZGV0YWlsOiBkZXRhaWwsXG4gICAgICAgICAgYnViYmxlczogdHJ1ZSxcbiAgICAgICAgICBjYW5jZWxhYmxlOiBmYWxzZSxcbiAgICAgICAgfSksXG4gICAgICApO1xuICAgICAgaWYgKHBoeEV2ZW50KSB7XG4gICAgICAgIGVsLmRpc3BhdGNoRXZlbnQoXG4gICAgICAgICAgbmV3IEN1c3RvbUV2ZW50KGBwaHg6cHVzaDoke3BoeEV2ZW50fWAsIHtcbiAgICAgICAgICAgIGRldGFpbDogZGV0YWlsLFxuICAgICAgICAgICAgYnViYmxlczogdHJ1ZSxcbiAgICAgICAgICAgIGNhbmNlbGFibGU6IGZhbHNlLFxuICAgICAgICAgIH0pLFxuICAgICAgICApO1xuICAgICAgfVxuICAgIH1cbiAgICByZXR1cm4gW25ld1JlZiwgZWxlbWVudHMubWFwKCh7IGVsIH0pID0+IGVsKSwgb3B0c107XG4gIH1cblxuICBpc0Fja2VkKHJlZikge1xuICAgIHJldHVybiB0aGlzLmxhc3RBY2tSZWYgIT09IG51bGwgJiYgdGhpcy5sYXN0QWNrUmVmID49IHJlZjtcbiAgfVxuXG4gIGNvbXBvbmVudElEKGVsKSB7XG4gICAgY29uc3QgY2lkID0gZWwuZ2V0QXR0cmlidXRlICYmIGVsLmdldEF0dHJpYnV0ZShQSFhfQ09NUE9ORU5UKTtcbiAgICByZXR1cm4gY2lkID8gcGFyc2VJbnQoY2lkKSA6IG51bGw7XG4gIH1cblxuICB0YXJnZXRDb21wb25lbnRJRCh0YXJnZXQsIHRhcmdldEN0eCwgb3B0cyA9IHt9KSB7XG4gICAgaWYgKGlzQ2lkKHRhcmdldEN0eCkpIHtcbiAgICAgIHJldHVybiB0YXJnZXRDdHg7XG4gICAgfVxuXG4gICAgY29uc3QgY2lkT3JTZWxlY3RvciA9XG4gICAgICBvcHRzLnRhcmdldCB8fCB0YXJnZXQuZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhcInRhcmdldFwiKSk7XG4gICAgaWYgKGlzQ2lkKGNpZE9yU2VsZWN0b3IpKSB7XG4gICAgICByZXR1cm4gcGFyc2VJbnQoY2lkT3JTZWxlY3Rvcik7XG4gICAgfSBlbHNlIGlmICh0YXJnZXRDdHggJiYgKGNpZE9yU2VsZWN0b3IgIT09IG51bGwgfHwgb3B0cy50YXJnZXQpKSB7XG4gICAgICByZXR1cm4gdGhpcy5jbG9zZXN0Q29tcG9uZW50SUQodGFyZ2V0Q3R4KTtcbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuIG51bGw7XG4gICAgfVxuICB9XG5cbiAgY2xvc2VzdENvbXBvbmVudElEKHRhcmdldEN0eCkge1xuICAgIGlmIChpc0NpZCh0YXJnZXRDdHgpKSB7XG4gICAgICByZXR1cm4gdGFyZ2V0Q3R4O1xuICAgIH0gZWxzZSBpZiAodGFyZ2V0Q3R4KSB7XG4gICAgICByZXR1cm4gbWF5YmUoXG4gICAgICAgIHRhcmdldEN0eC5jbG9zZXN0KGBbJHtQSFhfQ09NUE9ORU5UfV1gKSxcbiAgICAgICAgKGVsKSA9PiB0aGlzLm93bnNFbGVtZW50KGVsKSAmJiB0aGlzLmNvbXBvbmVudElEKGVsKSxcbiAgICAgICk7XG4gICAgfSBlbHNlIHtcbiAgICAgIHJldHVybiBudWxsO1xuICAgIH1cbiAgfVxuXG4gIHB1c2hIb29rRXZlbnQoZWwsIHRhcmdldEN0eCwgZXZlbnQsIHBheWxvYWQpIHtcbiAgICBpZiAoIXRoaXMuaXNDb25uZWN0ZWQoKSkge1xuICAgICAgdGhpcy5sb2coXCJob29rXCIsICgpID0+IFtcbiAgICAgICAgXCJ1bmFibGUgdG8gcHVzaCBob29rIGV2ZW50LiBMaXZlVmlldyBub3QgY29ubmVjdGVkXCIsXG4gICAgICAgIGV2ZW50LFxuICAgICAgICBwYXlsb2FkLFxuICAgICAgXSk7XG4gICAgICByZXR1cm4gUHJvbWlzZS5yZWplY3QoXG4gICAgICAgIG5ldyBFcnJvcihcInVuYWJsZSB0byBwdXNoIGhvb2sgZXZlbnQuIExpdmVWaWV3IG5vdCBjb25uZWN0ZWRcIiksXG4gICAgICApO1xuICAgIH1cblxuICAgIGNvbnN0IHJlZkdlbmVyYXRvciA9ICgpID0+XG4gICAgICB0aGlzLnB1dFJlZihbeyBlbCwgbG9hZGluZzogdHJ1ZSwgbG9jazogdHJ1ZSB9XSwgZXZlbnQsIFwiaG9va1wiLCB7XG4gICAgICAgIHBheWxvYWQsXG4gICAgICAgIHRhcmdldDogdGFyZ2V0Q3R4LFxuICAgICAgfSk7XG5cbiAgICByZXR1cm4gdGhpcy5wdXNoV2l0aFJlcGx5KHJlZkdlbmVyYXRvciwgXCJldmVudFwiLCB7XG4gICAgICB0eXBlOiBcImhvb2tcIixcbiAgICAgIGV2ZW50OiBldmVudCxcbiAgICAgIHZhbHVlOiBwYXlsb2FkLFxuICAgICAgY2lkOiB0aGlzLmNsb3Nlc3RDb21wb25lbnRJRCh0YXJnZXRDdHgpLFxuICAgIH0pLnRoZW4oKHsgcmVzcDogX3Jlc3AsIHJlcGx5LCByZWYgfSkgPT4gKHsgcmVwbHksIHJlZiB9KSk7XG4gIH1cblxuICBleHRyYWN0TWV0YShlbCwgbWV0YSwgdmFsdWUpIHtcbiAgICBjb25zdCBwcmVmaXggPSB0aGlzLmJpbmRpbmcoXCJ2YWx1ZS1cIik7XG4gICAgZm9yIChsZXQgaSA9IDA7IGkgPCBlbC5hdHRyaWJ1dGVzLmxlbmd0aDsgaSsrKSB7XG4gICAgICBpZiAoIW1ldGEpIHtcbiAgICAgICAgbWV0YSA9IHt9O1xuICAgICAgfVxuICAgICAgY29uc3QgbmFtZSA9IGVsLmF0dHJpYnV0ZXNbaV0ubmFtZTtcbiAgICAgIGlmIChuYW1lLnN0YXJ0c1dpdGgocHJlZml4KSkge1xuICAgICAgICBtZXRhW25hbWUucmVwbGFjZShwcmVmaXgsIFwiXCIpXSA9IGVsLmdldEF0dHJpYnV0ZShuYW1lKTtcbiAgICAgIH1cbiAgICB9XG4gICAgaWYgKGVsLnZhbHVlICE9PSB1bmRlZmluZWQgJiYgIShlbCBpbnN0YW5jZW9mIEhUTUxGb3JtRWxlbWVudCkpIHtcbiAgICAgIGlmICghbWV0YSkge1xuICAgICAgICBtZXRhID0ge307XG4gICAgICB9XG4gICAgICBtZXRhLnZhbHVlID0gZWwudmFsdWU7XG5cbiAgICAgIGlmIChcbiAgICAgICAgZWwudGFnTmFtZSA9PT0gXCJJTlBVVFwiICYmXG4gICAgICAgIENIRUNLQUJMRV9JTlBVVFMuaW5kZXhPZihlbC50eXBlKSA+PSAwICYmXG4gICAgICAgICFlbC5jaGVja2VkXG4gICAgICApIHtcbiAgICAgICAgZGVsZXRlIG1ldGEudmFsdWU7XG4gICAgICB9XG4gICAgfVxuICAgIGlmICh2YWx1ZSkge1xuICAgICAgaWYgKCFtZXRhKSB7XG4gICAgICAgIG1ldGEgPSB7fTtcbiAgICAgIH1cbiAgICAgIGZvciAoY29uc3Qga2V5IGluIHZhbHVlKSB7XG4gICAgICAgIG1ldGFba2V5XSA9IHZhbHVlW2tleV07XG4gICAgICB9XG4gICAgfVxuICAgIHJldHVybiBtZXRhO1xuICB9XG5cbiAgcHVzaEV2ZW50KHR5cGUsIGVsLCB0YXJnZXRDdHgsIHBoeEV2ZW50LCBtZXRhLCBvcHRzID0ge30sIG9uUmVwbHkpIHtcbiAgICB0aGlzLnB1c2hXaXRoUmVwbHkoXG4gICAgICAobWF5YmVQYXlsb2FkKSA9PlxuICAgICAgICB0aGlzLnB1dFJlZihbeyBlbCwgbG9hZGluZzogdHJ1ZSwgbG9jazogdHJ1ZSB9XSwgcGh4RXZlbnQsIHR5cGUsIHtcbiAgICAgICAgICAuLi5vcHRzLFxuICAgICAgICAgIHBheWxvYWQ6IG1heWJlUGF5bG9hZD8ucGF5bG9hZCxcbiAgICAgICAgfSksXG4gICAgICBcImV2ZW50XCIsXG4gICAgICB7XG4gICAgICAgIHR5cGU6IHR5cGUsXG4gICAgICAgIGV2ZW50OiBwaHhFdmVudCxcbiAgICAgICAgdmFsdWU6IHRoaXMuZXh0cmFjdE1ldGEoZWwsIG1ldGEsIG9wdHMudmFsdWUpLFxuICAgICAgICBjaWQ6IHRoaXMudGFyZ2V0Q29tcG9uZW50SUQoZWwsIHRhcmdldEN0eCwgb3B0cyksXG4gICAgICB9LFxuICAgIClcbiAgICAgIC50aGVuKCh7IHJlcGx5IH0pID0+IG9uUmVwbHkgJiYgb25SZXBseShyZXBseSkpXG4gICAgICAuY2F0Y2goKGVycm9yKSA9PiBsb2dFcnJvcihcIkZhaWxlZCB0byBwdXNoIGV2ZW50XCIsIGVycm9yKSk7XG4gIH1cblxuICBwdXNoRmlsZVByb2dyZXNzKGZpbGVFbCwgZW50cnlSZWYsIHByb2dyZXNzLCBvblJlcGx5ID0gZnVuY3Rpb24gKCkge30pIHtcbiAgICB0aGlzLmxpdmVTb2NrZXQud2l0aGluT3duZXJzKGZpbGVFbC5mb3JtLCAodmlldywgdGFyZ2V0Q3R4KSA9PiB7XG4gICAgICB2aWV3XG4gICAgICAgIC5wdXNoV2l0aFJlcGx5KG51bGwsIFwicHJvZ3Jlc3NcIiwge1xuICAgICAgICAgIGV2ZW50OiBmaWxlRWwuZ2V0QXR0cmlidXRlKHZpZXcuYmluZGluZyhQSFhfUFJPR1JFU1MpKSxcbiAgICAgICAgICByZWY6IGZpbGVFbC5nZXRBdHRyaWJ1dGUoUEhYX1VQTE9BRF9SRUYpLFxuICAgICAgICAgIGVudHJ5X3JlZjogZW50cnlSZWYsXG4gICAgICAgICAgcHJvZ3Jlc3M6IHByb2dyZXNzLFxuICAgICAgICAgIGNpZDogdmlldy50YXJnZXRDb21wb25lbnRJRChmaWxlRWwuZm9ybSwgdGFyZ2V0Q3R4KSxcbiAgICAgICAgfSlcbiAgICAgICAgLnRoZW4oKCkgPT4gb25SZXBseSgpKVxuICAgICAgICAuY2F0Y2goKGVycm9yKSA9PiBsb2dFcnJvcihcIkZhaWxlZCB0byBwdXNoIGZpbGUgcHJvZ3Jlc3NcIiwgZXJyb3IpKTtcbiAgICB9KTtcbiAgfVxuXG4gIHB1c2hJbnB1dChpbnB1dEVsLCB0YXJnZXRDdHgsIGZvcmNlQ2lkLCBwaHhFdmVudCwgb3B0cywgY2FsbGJhY2spIHtcbiAgICBpZiAoIWlucHV0RWwuZm9ybSkge1xuICAgICAgdGhyb3cgbmV3IEVycm9yKFwiZm9ybSBldmVudHMgcmVxdWlyZSB0aGUgaW5wdXQgdG8gYmUgaW5zaWRlIGEgZm9ybVwiKTtcbiAgICB9XG5cbiAgICBsZXQgdXBsb2FkcztcbiAgICBjb25zdCBjaWQgPSBpc0NpZChmb3JjZUNpZClcbiAgICAgID8gZm9yY2VDaWRcbiAgICAgIDogdGhpcy50YXJnZXRDb21wb25lbnRJRChpbnB1dEVsLmZvcm0sIHRhcmdldEN0eCwgb3B0cyk7XG4gICAgY29uc3QgcmVmR2VuZXJhdG9yID0gKG1heWJlUGF5bG9hZCkgPT4ge1xuICAgICAgcmV0dXJuIHRoaXMucHV0UmVmKFxuICAgICAgICBbXG4gICAgICAgICAgeyBlbDogaW5wdXRFbCwgbG9hZGluZzogdHJ1ZSwgbG9jazogdHJ1ZSB9LFxuICAgICAgICAgIHsgZWw6IGlucHV0RWwuZm9ybSwgbG9hZGluZzogdHJ1ZSwgbG9jazogdHJ1ZSB9LFxuICAgICAgICBdLFxuICAgICAgICBwaHhFdmVudCxcbiAgICAgICAgXCJjaGFuZ2VcIixcbiAgICAgICAgeyAuLi5vcHRzLCBwYXlsb2FkOiBtYXliZVBheWxvYWQ/LnBheWxvYWQgfSxcbiAgICAgICk7XG4gICAgfTtcbiAgICBsZXQgZm9ybURhdGE7XG4gICAgY29uc3QgbWV0YSA9IHRoaXMuZXh0cmFjdE1ldGEoaW5wdXRFbC5mb3JtLCB7fSwgb3B0cy52YWx1ZSk7XG4gICAgY29uc3Qgc2VyaWFsaXplT3B0cyA9IHt9O1xuICAgIGlmIChpbnB1dEVsIGluc3RhbmNlb2YgSFRNTEJ1dHRvbkVsZW1lbnQpIHtcbiAgICAgIHNlcmlhbGl6ZU9wdHMuc3VibWl0dGVyID0gaW5wdXRFbDtcbiAgICB9XG4gICAgaWYgKGlucHV0RWwuZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhcImNoYW5nZVwiKSkpIHtcbiAgICAgIGZvcm1EYXRhID0gc2VyaWFsaXplRm9ybShpbnB1dEVsLmZvcm0sIHNlcmlhbGl6ZU9wdHMsIFtpbnB1dEVsLm5hbWVdKTtcbiAgICB9IGVsc2Uge1xuICAgICAgZm9ybURhdGEgPSBzZXJpYWxpemVGb3JtKGlucHV0RWwuZm9ybSwgc2VyaWFsaXplT3B0cyk7XG4gICAgfVxuICAgIGlmIChcbiAgICAgIERPTS5pc1VwbG9hZElucHV0KGlucHV0RWwpICYmXG4gICAgICBpbnB1dEVsLmZpbGVzICYmXG4gICAgICBpbnB1dEVsLmZpbGVzLmxlbmd0aCA+IDBcbiAgICApIHtcbiAgICAgIExpdmVVcGxvYWRlci50cmFja0ZpbGVzKGlucHV0RWwsIEFycmF5LmZyb20oaW5wdXRFbC5maWxlcykpO1xuICAgIH1cbiAgICB1cGxvYWRzID0gTGl2ZVVwbG9hZGVyLnNlcmlhbGl6ZVVwbG9hZHMoaW5wdXRFbCk7XG5cbiAgICBjb25zdCBldmVudCA9IHtcbiAgICAgIHR5cGU6IFwiZm9ybVwiLFxuICAgICAgZXZlbnQ6IHBoeEV2ZW50LFxuICAgICAgdmFsdWU6IGZvcm1EYXRhLFxuICAgICAgbWV0YToge1xuICAgICAgICAvLyBubyB0YXJnZXQgd2FzIGltcGxpY2l0bHkgc2VudCBhcyBcInVuZGVmaW5lZFwiIGluIExWIDw9IDEuMC41LCB0aGVyZWZvcmVcbiAgICAgICAgLy8gd2UgaGF2ZSB0byBrZWVwIGl0LiBJbiAxLjAuNiB3ZSBzd2l0Y2hlZCBmcm9tIHBhc3NpbmcgbWV0YSBhcyBVUkwgZW5jb2RlZCBkYXRhXG4gICAgICAgIC8vIHRvIHBhc3NpbmcgaXQgZGlyZWN0bHkgaW4gdGhlIGV2ZW50LCBidXQgdGhlIEpTT04gZW5jb2RlIHdvdWxkIGRyb3Aga2V5cyB3aXRoXG4gICAgICAgIC8vIHVuZGVmaW5lZCB2YWx1ZXMuXG4gICAgICAgIF90YXJnZXQ6IG9wdHMuX3RhcmdldCB8fCBcInVuZGVmaW5lZFwiLFxuICAgICAgICAuLi5tZXRhLFxuICAgICAgfSxcbiAgICAgIHVwbG9hZHM6IHVwbG9hZHMsXG4gICAgICBjaWQ6IGNpZCxcbiAgICB9O1xuICAgIHRoaXMucHVzaFdpdGhSZXBseShyZWZHZW5lcmF0b3IsIFwiZXZlbnRcIiwgZXZlbnQpXG4gICAgICAudGhlbigoeyByZXNwIH0pID0+IHtcbiAgICAgICAgaWYgKERPTS5pc1VwbG9hZElucHV0KGlucHV0RWwpICYmIERPTS5pc0F1dG9VcGxvYWQoaW5wdXRFbCkpIHtcbiAgICAgICAgICAvLyB0aGUgZWxlbWVudCBjb3VsZCBiZSBpbnNpZGUgYSBsb2NrZWQgcGFyZW50IGZvciBvdGhlciB1bnJlbGF0ZWQgY2hhbmdlcztcbiAgICAgICAgICAvLyB3ZSBjYW4gb25seSBzdGFydCB1cGxvYWRzIHdoZW4gdGhlIHRyZWUgaXMgdW5sb2NrZWQgYW5kIHRoZVxuICAgICAgICAgIC8vIG5lY2Vzc2FyeSBkYXRhIGF0dHJpYnV0ZXMgYXJlIHNldCBpbiB0aGUgcmVhbCBET01cbiAgICAgICAgICBFbGVtZW50UmVmLm9uVW5sb2NrKGlucHV0RWwsICgpID0+IHtcbiAgICAgICAgICAgIGlmIChMaXZlVXBsb2FkZXIuZmlsZXNBd2FpdGluZ1ByZWZsaWdodChpbnB1dEVsKS5sZW5ndGggPiAwKSB7XG4gICAgICAgICAgICAgIGNvbnN0IFtyZWYsIF9lbHNdID0gcmVmR2VuZXJhdG9yKCk7XG4gICAgICAgICAgICAgIHRoaXMudW5kb1JlZnMocmVmLCBwaHhFdmVudCwgW2lucHV0RWwuZm9ybV0pO1xuICAgICAgICAgICAgICB0aGlzLnVwbG9hZEZpbGVzKFxuICAgICAgICAgICAgICAgIGlucHV0RWwuZm9ybSxcbiAgICAgICAgICAgICAgICBwaHhFdmVudCxcbiAgICAgICAgICAgICAgICB0YXJnZXRDdHgsXG4gICAgICAgICAgICAgICAgcmVmLFxuICAgICAgICAgICAgICAgIGNpZCxcbiAgICAgICAgICAgICAgICAoX3VwbG9hZHMpID0+IHtcbiAgICAgICAgICAgICAgICAgIGNhbGxiYWNrICYmIGNhbGxiYWNrKHJlc3ApO1xuICAgICAgICAgICAgICAgICAgdGhpcy50cmlnZ2VyQXdhaXRpbmdTdWJtaXQoaW5wdXRFbC5mb3JtLCBwaHhFdmVudCk7XG4gICAgICAgICAgICAgICAgICB0aGlzLnVuZG9SZWZzKHJlZiwgcGh4RXZlbnQpO1xuICAgICAgICAgICAgICAgIH0sXG4gICAgICAgICAgICAgICk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgfSk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgY2FsbGJhY2sgJiYgY2FsbGJhY2socmVzcCk7XG4gICAgICAgIH1cbiAgICAgIH0pXG4gICAgICAuY2F0Y2goKGVycm9yKSA9PiBsb2dFcnJvcihcIkZhaWxlZCB0byBwdXNoIGlucHV0IGV2ZW50XCIsIGVycm9yKSk7XG4gIH1cblxuICB0cmlnZ2VyQXdhaXRpbmdTdWJtaXQoZm9ybUVsLCBwaHhFdmVudCkge1xuICAgIGNvbnN0IGF3YWl0aW5nU3VibWl0ID0gdGhpcy5nZXRTY2hlZHVsZWRTdWJtaXQoZm9ybUVsKTtcbiAgICBpZiAoYXdhaXRpbmdTdWJtaXQpIHtcbiAgICAgIGNvbnN0IFtfZWwsIF9yZWYsIF9vcHRzLCBjYWxsYmFja10gPSBhd2FpdGluZ1N1Ym1pdDtcbiAgICAgIHRoaXMuY2FuY2VsU3VibWl0KGZvcm1FbCwgcGh4RXZlbnQpO1xuICAgICAgY2FsbGJhY2soKTtcbiAgICB9XG4gIH1cblxuICBnZXRTY2hlZHVsZWRTdWJtaXQoZm9ybUVsKSB7XG4gICAgcmV0dXJuIHRoaXMuZm9ybVN1Ym1pdHMuZmluZCgoW2VsLCBfcmVmLCBfb3B0cywgX2NhbGxiYWNrXSkgPT5cbiAgICAgIGVsLmlzU2FtZU5vZGUoZm9ybUVsKSxcbiAgICApO1xuICB9XG5cbiAgc2NoZWR1bGVTdWJtaXQoZm9ybUVsLCByZWYsIG9wdHMsIGNhbGxiYWNrKSB7XG4gICAgaWYgKHRoaXMuZ2V0U2NoZWR1bGVkU3VibWl0KGZvcm1FbCkpIHtcbiAgICAgIHJldHVybiB0cnVlO1xuICAgIH1cbiAgICB0aGlzLmZvcm1TdWJtaXRzLnB1c2goW2Zvcm1FbCwgcmVmLCBvcHRzLCBjYWxsYmFja10pO1xuICB9XG5cbiAgY2FuY2VsU3VibWl0KGZvcm1FbCwgcGh4RXZlbnQpIHtcbiAgICB0aGlzLmZvcm1TdWJtaXRzID0gdGhpcy5mb3JtU3VibWl0cy5maWx0ZXIoXG4gICAgICAoW2VsLCByZWYsIF9vcHRzLCBfY2FsbGJhY2tdKSA9PiB7XG4gICAgICAgIGlmIChlbC5pc1NhbWVOb2RlKGZvcm1FbCkpIHtcbiAgICAgICAgICB0aGlzLnVuZG9SZWZzKHJlZiwgcGh4RXZlbnQpO1xuICAgICAgICAgIHJldHVybiBmYWxzZTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICByZXR1cm4gdHJ1ZTtcbiAgICAgICAgfVxuICAgICAgfSxcbiAgICApO1xuICB9XG5cbiAgZGlzYWJsZUZvcm0oZm9ybUVsLCBwaHhFdmVudCwgb3B0cyA9IHt9KSB7XG4gICAgY29uc3QgZmlsdGVySWdub3JlZCA9IChlbCkgPT4ge1xuICAgICAgY29uc3QgdXNlcklnbm9yZWQgPSBjbG9zZXN0UGh4QmluZGluZyhcbiAgICAgICAgZWwsXG4gICAgICAgIGAke3RoaXMuYmluZGluZyhQSFhfVVBEQVRFKX09aWdub3JlYCxcbiAgICAgICAgZWwuZm9ybSxcbiAgICAgICk7XG4gICAgICByZXR1cm4gIShcbiAgICAgICAgdXNlcklnbm9yZWQgfHwgY2xvc2VzdFBoeEJpbmRpbmcoZWwsIFwiZGF0YS1waHgtdXBkYXRlPWlnbm9yZVwiLCBlbC5mb3JtKVxuICAgICAgKTtcbiAgICB9O1xuICAgIGNvbnN0IGZpbHRlckRpc2FibGVzID0gKGVsKSA9PiB7XG4gICAgICByZXR1cm4gZWwuaGFzQXR0cmlidXRlKHRoaXMuYmluZGluZyhQSFhfRElTQUJMRV9XSVRIKSk7XG4gICAgfTtcbiAgICBjb25zdCBmaWx0ZXJCdXR0b24gPSAoZWwpID0+IGVsLnRhZ05hbWUgPT0gXCJCVVRUT05cIjtcblxuICAgIGNvbnN0IGZpbHRlcklucHV0ID0gKGVsKSA9PlxuICAgICAgW1wiSU5QVVRcIiwgXCJURVhUQVJFQVwiLCBcIlNFTEVDVFwiXS5pbmNsdWRlcyhlbC50YWdOYW1lKTtcblxuICAgIGNvbnN0IGZvcm1FbGVtZW50cyA9IEFycmF5LmZyb20oZm9ybUVsLmVsZW1lbnRzKTtcbiAgICBjb25zdCBkaXNhYmxlcyA9IGZvcm1FbGVtZW50cy5maWx0ZXIoZmlsdGVyRGlzYWJsZXMpO1xuICAgIGNvbnN0IGJ1dHRvbnMgPSBmb3JtRWxlbWVudHMuZmlsdGVyKGZpbHRlckJ1dHRvbikuZmlsdGVyKGZpbHRlcklnbm9yZWQpO1xuICAgIGNvbnN0IGlucHV0cyA9IGZvcm1FbGVtZW50cy5maWx0ZXIoZmlsdGVySW5wdXQpLmZpbHRlcihmaWx0ZXJJZ25vcmVkKTtcblxuICAgIGJ1dHRvbnMuZm9yRWFjaCgoYnV0dG9uKSA9PiB7XG4gICAgICBidXR0b24uc2V0QXR0cmlidXRlKFBIWF9ESVNBQkxFRCwgYnV0dG9uLmRpc2FibGVkKTtcbiAgICAgIGJ1dHRvbi5kaXNhYmxlZCA9IHRydWU7XG4gICAgfSk7XG4gICAgaW5wdXRzLmZvckVhY2goKGlucHV0KSA9PiB7XG4gICAgICBpbnB1dC5zZXRBdHRyaWJ1dGUoUEhYX1JFQURPTkxZLCBpbnB1dC5yZWFkT25seSk7XG4gICAgICBpbnB1dC5yZWFkT25seSA9IHRydWU7XG4gICAgICBpZiAoaW5wdXQuZmlsZXMpIHtcbiAgICAgICAgaW5wdXQuc2V0QXR0cmlidXRlKFBIWF9ESVNBQkxFRCwgaW5wdXQuZGlzYWJsZWQpO1xuICAgICAgICBpbnB1dC5kaXNhYmxlZCA9IHRydWU7XG4gICAgICB9XG4gICAgfSk7XG4gICAgY29uc3QgZm9ybUVscyA9IGRpc2FibGVzXG4gICAgICAuY29uY2F0KGJ1dHRvbnMpXG4gICAgICAuY29uY2F0KGlucHV0cylcbiAgICAgIC5tYXAoKGVsKSA9PiB7XG4gICAgICAgIHJldHVybiB7IGVsLCBsb2FkaW5nOiB0cnVlLCBsb2NrOiB0cnVlIH07XG4gICAgICB9KTtcblxuICAgIC8vIHdlIHJldmVyc2UgdGhlIG9yZGVyIHNvIGZvcm0gY2hpbGRyZW4gYXJlIGFscmVhZHkgbG9ja2VkIGJ5IHRoZSB0aW1lXG4gICAgLy8gdGhlIGZvcm0gaXMgbG9ja2VkXG4gICAgY29uc3QgZWxzID0gW3sgZWw6IGZvcm1FbCwgbG9hZGluZzogdHJ1ZSwgbG9jazogZmFsc2UgfV1cbiAgICAgIC5jb25jYXQoZm9ybUVscylcbiAgICAgIC5yZXZlcnNlKCk7XG4gICAgcmV0dXJuIHRoaXMucHV0UmVmKGVscywgcGh4RXZlbnQsIFwic3VibWl0XCIsIG9wdHMpO1xuICB9XG5cbiAgcHVzaEZvcm1TdWJtaXQoZm9ybUVsLCB0YXJnZXRDdHgsIHBoeEV2ZW50LCBzdWJtaXR0ZXIsIG9wdHMsIG9uUmVwbHkpIHtcbiAgICBjb25zdCByZWZHZW5lcmF0b3IgPSAobWF5YmVQYXlsb2FkKSA9PlxuICAgICAgdGhpcy5kaXNhYmxlRm9ybShmb3JtRWwsIHBoeEV2ZW50LCB7XG4gICAgICAgIC4uLm9wdHMsXG4gICAgICAgIGZvcm06IGZvcm1FbCxcbiAgICAgICAgcGF5bG9hZDogbWF5YmVQYXlsb2FkPy5wYXlsb2FkLFxuICAgICAgICBzdWJtaXR0ZXI6IHN1Ym1pdHRlcixcbiAgICAgIH0pO1xuICAgIC8vIHN0b3JlIHRoZSBzdWJtaXR0ZXIgaW4gdGhlIGZvcm0gZWxlbWVudCBpbiBvcmRlciB0byB0cmlnZ2VyIGl0XG4gICAgLy8gZm9yIHBoeC10cmlnZ2VyLWFjdGlvblxuICAgIERPTS5wdXRQcml2YXRlKGZvcm1FbCwgXCJzdWJtaXR0ZXJcIiwgc3VibWl0dGVyKTtcbiAgICBjb25zdCBjaWQgPSB0aGlzLnRhcmdldENvbXBvbmVudElEKGZvcm1FbCwgdGFyZ2V0Q3R4KTtcbiAgICBpZiAoTGl2ZVVwbG9hZGVyLmhhc1VwbG9hZHNJblByb2dyZXNzKGZvcm1FbCkpIHtcbiAgICAgIGNvbnN0IFtyZWYsIF9lbHNdID0gcmVmR2VuZXJhdG9yKCk7XG4gICAgICBjb25zdCBwdXNoID0gKCkgPT5cbiAgICAgICAgdGhpcy5wdXNoRm9ybVN1Ym1pdChcbiAgICAgICAgICBmb3JtRWwsXG4gICAgICAgICAgdGFyZ2V0Q3R4LFxuICAgICAgICAgIHBoeEV2ZW50LFxuICAgICAgICAgIHN1Ym1pdHRlcixcbiAgICAgICAgICBvcHRzLFxuICAgICAgICAgIG9uUmVwbHksXG4gICAgICAgICk7XG4gICAgICByZXR1cm4gdGhpcy5zY2hlZHVsZVN1Ym1pdChmb3JtRWwsIHJlZiwgb3B0cywgcHVzaCk7XG4gICAgfSBlbHNlIGlmIChMaXZlVXBsb2FkZXIuaW5wdXRzQXdhaXRpbmdQcmVmbGlnaHQoZm9ybUVsKS5sZW5ndGggPiAwKSB7XG4gICAgICBjb25zdCBbcmVmLCBlbHNdID0gcmVmR2VuZXJhdG9yKCk7XG4gICAgICBjb25zdCBwcm94eVJlZkdlbiA9ICgpID0+IFtyZWYsIGVscywgb3B0c107XG4gICAgICB0aGlzLnVwbG9hZEZpbGVzKGZvcm1FbCwgcGh4RXZlbnQsIHRhcmdldEN0eCwgcmVmLCBjaWQsIChfdXBsb2FkcykgPT4ge1xuICAgICAgICAvLyBpZiB3ZSBzdGlsbCBoYXZpbmcgcGVuZGluZyBwcmVmbGlnaHRzIGl0IG1lYW5zIHdlIGhhdmUgaW52YWxpZCBlbnRyaWVzXG4gICAgICAgIC8vIGFuZCB0aGUgcGh4LXN1Ym1pdCBjYW5ub3QgYmUgY29tcGxldGVkXG4gICAgICAgIGlmIChMaXZlVXBsb2FkZXIuaW5wdXRzQXdhaXRpbmdQcmVmbGlnaHQoZm9ybUVsKS5sZW5ndGggPiAwKSB7XG4gICAgICAgICAgcmV0dXJuIHRoaXMudW5kb1JlZnMocmVmLCBwaHhFdmVudCk7XG4gICAgICAgIH1cbiAgICAgICAgY29uc3QgbWV0YSA9IHRoaXMuZXh0cmFjdE1ldGEoZm9ybUVsLCB7fSwgb3B0cy52YWx1ZSk7XG4gICAgICAgIGNvbnN0IGZvcm1EYXRhID0gc2VyaWFsaXplRm9ybShmb3JtRWwsIHsgc3VibWl0dGVyIH0pO1xuICAgICAgICB0aGlzLnB1c2hXaXRoUmVwbHkocHJveHlSZWZHZW4sIFwiZXZlbnRcIiwge1xuICAgICAgICAgIHR5cGU6IFwiZm9ybVwiLFxuICAgICAgICAgIGV2ZW50OiBwaHhFdmVudCxcbiAgICAgICAgICB2YWx1ZTogZm9ybURhdGEsXG4gICAgICAgICAgbWV0YTogbWV0YSxcbiAgICAgICAgICBjaWQ6IGNpZCxcbiAgICAgICAgfSlcbiAgICAgICAgICAudGhlbigoeyByZXNwIH0pID0+IG9uUmVwbHkocmVzcCkpXG4gICAgICAgICAgLmNhdGNoKChlcnJvcikgPT4gbG9nRXJyb3IoXCJGYWlsZWQgdG8gcHVzaCBmb3JtIHN1Ym1pdFwiLCBlcnJvcikpO1xuICAgICAgfSk7XG4gICAgfSBlbHNlIGlmIChcbiAgICAgICEoXG4gICAgICAgIGZvcm1FbC5oYXNBdHRyaWJ1dGUoUEhYX1JFRl9TUkMpICYmXG4gICAgICAgIGZvcm1FbC5jbGFzc0xpc3QuY29udGFpbnMoXCJwaHgtc3VibWl0LWxvYWRpbmdcIilcbiAgICAgIClcbiAgICApIHtcbiAgICAgIGNvbnN0IG1ldGEgPSB0aGlzLmV4dHJhY3RNZXRhKGZvcm1FbCwge30sIG9wdHMudmFsdWUpO1xuICAgICAgY29uc3QgZm9ybURhdGEgPSBzZXJpYWxpemVGb3JtKGZvcm1FbCwgeyBzdWJtaXR0ZXIgfSk7XG4gICAgICB0aGlzLnB1c2hXaXRoUmVwbHkocmVmR2VuZXJhdG9yLCBcImV2ZW50XCIsIHtcbiAgICAgICAgdHlwZTogXCJmb3JtXCIsXG4gICAgICAgIGV2ZW50OiBwaHhFdmVudCxcbiAgICAgICAgdmFsdWU6IGZvcm1EYXRhLFxuICAgICAgICBtZXRhOiBtZXRhLFxuICAgICAgICBjaWQ6IGNpZCxcbiAgICAgIH0pXG4gICAgICAgIC50aGVuKCh7IHJlc3AgfSkgPT4gb25SZXBseShyZXNwKSlcbiAgICAgICAgLmNhdGNoKChlcnJvcikgPT4gbG9nRXJyb3IoXCJGYWlsZWQgdG8gcHVzaCBmb3JtIHN1Ym1pdFwiLCBlcnJvcikpO1xuICAgIH1cbiAgfVxuXG4gIHVwbG9hZEZpbGVzKGZvcm1FbCwgcGh4RXZlbnQsIHRhcmdldEN0eCwgcmVmLCBjaWQsIG9uQ29tcGxldGUpIHtcbiAgICBjb25zdCBqb2luQ291bnRBdFVwbG9hZCA9IHRoaXMuam9pbkNvdW50O1xuICAgIGNvbnN0IGlucHV0RWxzID0gTGl2ZVVwbG9hZGVyLmFjdGl2ZUZpbGVJbnB1dHMoZm9ybUVsKTtcbiAgICBsZXQgbnVtRmlsZUlucHV0c0luUHJvZ3Jlc3MgPSBpbnB1dEVscy5sZW5ndGg7XG5cbiAgICAvLyBnZXQgZWFjaCBmaWxlIGlucHV0XG4gICAgaW5wdXRFbHMuZm9yRWFjaCgoaW5wdXRFbCkgPT4ge1xuICAgICAgY29uc3QgdXBsb2FkZXIgPSBuZXcgTGl2ZVVwbG9hZGVyKGlucHV0RWwsIHRoaXMsICgpID0+IHtcbiAgICAgICAgbnVtRmlsZUlucHV0c0luUHJvZ3Jlc3MtLTtcbiAgICAgICAgaWYgKG51bUZpbGVJbnB1dHNJblByb2dyZXNzID09PSAwKSB7XG4gICAgICAgICAgb25Db21wbGV0ZSgpO1xuICAgICAgICB9XG4gICAgICB9KTtcblxuICAgICAgY29uc3QgZW50cmllcyA9IHVwbG9hZGVyXG4gICAgICAgIC5lbnRyaWVzKClcbiAgICAgICAgLm1hcCgoZW50cnkpID0+IGVudHJ5LnRvUHJlZmxpZ2h0UGF5bG9hZCgpKTtcblxuICAgICAgaWYgKGVudHJpZXMubGVuZ3RoID09PSAwKSB7XG4gICAgICAgIG51bUZpbGVJbnB1dHNJblByb2dyZXNzLS07XG4gICAgICAgIHJldHVybjtcbiAgICAgIH1cblxuICAgICAgY29uc3QgcGF5bG9hZCA9IHtcbiAgICAgICAgcmVmOiBpbnB1dEVsLmdldEF0dHJpYnV0ZShQSFhfVVBMT0FEX1JFRiksXG4gICAgICAgIGVudHJpZXM6IGVudHJpZXMsXG4gICAgICAgIGNpZDogdGhpcy50YXJnZXRDb21wb25lbnRJRChpbnB1dEVsLmZvcm0sIHRhcmdldEN0eCksXG4gICAgICB9O1xuXG4gICAgICB0aGlzLmxvZyhcInVwbG9hZFwiLCAoKSA9PiBbXCJzZW5kaW5nIHByZWZsaWdodCByZXF1ZXN0XCIsIHBheWxvYWRdKTtcblxuICAgICAgdGhpcy5wdXNoV2l0aFJlcGx5KG51bGwsIFwiYWxsb3dfdXBsb2FkXCIsIHBheWxvYWQpXG4gICAgICAgIC50aGVuKCh7IHJlc3AgfSkgPT4ge1xuICAgICAgICAgIHRoaXMubG9nKFwidXBsb2FkXCIsICgpID0+IFtcImdvdCBwcmVmbGlnaHQgcmVzcG9uc2VcIiwgcmVzcF0pO1xuICAgICAgICAgIC8vIHRoZSBwcmVmbGlnaHQgd2lsbCByZWplY3QgZW50cmllcyBiZXlvbmQgdGhlIG1heCBlbnRyaWVzXG4gICAgICAgICAgLy8gc28gd2UgZXJyb3IgYW5kIGNhbmNlbCBlbnRyaWVzIG9uIHRoZSBjbGllbnQgdGhhdCBhcmUgbWlzc2luZyBmcm9tIHRoZSByZXNwb25zZVxuICAgICAgICAgIHVwbG9hZGVyLmVudHJpZXMoKS5mb3JFYWNoKChlbnRyeSkgPT4ge1xuICAgICAgICAgICAgaWYgKHJlc3AuZW50cmllcyAmJiAhcmVzcC5lbnRyaWVzW2VudHJ5LnJlZl0pIHtcbiAgICAgICAgICAgICAgdGhpcy5oYW5kbGVGYWlsZWRFbnRyeVByZWZsaWdodChcbiAgICAgICAgICAgICAgICBlbnRyeS5yZWYsXG4gICAgICAgICAgICAgICAgXCJmYWlsZWQgcHJlZmxpZ2h0XCIsXG4gICAgICAgICAgICAgICAgdXBsb2FkZXIsXG4gICAgICAgICAgICAgICk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgfSk7XG4gICAgICAgICAgLy8gZm9yIGF1dG8gdXBsb2Fkcywgd2UgbWF5IGhhdmUgYW4gZW1wdHkgZW50cmllcyByZXNwb25zZSBmcm9tIHRoZSBzZXJ2ZXJcbiAgICAgICAgICAvLyBmb3IgZm9ybSBzdWJtaXRzIHRoYXQgY29udGFpbiBpbnZhbGlkIGVudHJpZXNcbiAgICAgICAgICBpZiAocmVzcC5lcnJvciB8fCBPYmplY3Qua2V5cyhyZXNwLmVudHJpZXMpLmxlbmd0aCA9PT0gMCkge1xuICAgICAgICAgICAgdGhpcy51bmRvUmVmcyhyZWYsIHBoeEV2ZW50KTtcbiAgICAgICAgICAgIGNvbnN0IGVycm9ycyA9IHJlc3AuZXJyb3IgfHwgW107XG4gICAgICAgICAgICBlcnJvcnMubWFwKChbZW50cnlfcmVmLCByZWFzb25dKSA9PiB7XG4gICAgICAgICAgICAgIHRoaXMuaGFuZGxlRmFpbGVkRW50cnlQcmVmbGlnaHQoZW50cnlfcmVmLCByZWFzb24sIHVwbG9hZGVyKTtcbiAgICAgICAgICAgIH0pO1xuICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBjb25zdCBvbkVycm9yID0gKGNhbGxiYWNrKSA9PiB7XG4gICAgICAgICAgICAgIHRoaXMuY2hhbm5lbC5vbkVycm9yKCgpID0+IHtcbiAgICAgICAgICAgICAgICBpZiAodGhpcy5qb2luQ291bnQgPT09IGpvaW5Db3VudEF0VXBsb2FkKSB7XG4gICAgICAgICAgICAgICAgICBjYWxsYmFjaygpO1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICB9O1xuICAgICAgICAgICAgdXBsb2FkZXIuaW5pdEFkYXB0ZXJVcGxvYWQocmVzcCwgb25FcnJvciwgdGhpcy5saXZlU29ja2V0KTtcbiAgICAgICAgICB9XG4gICAgICAgIH0pXG4gICAgICAgIC5jYXRjaCgoZXJyb3IpID0+IGxvZ0Vycm9yKFwiRmFpbGVkIHRvIHB1c2ggdXBsb2FkXCIsIGVycm9yKSk7XG4gICAgfSk7XG4gIH1cblxuICBoYW5kbGVGYWlsZWRFbnRyeVByZWZsaWdodCh1cGxvYWRSZWYsIHJlYXNvbiwgdXBsb2FkZXIpIHtcbiAgICBpZiAodXBsb2FkZXIuaXNBdXRvVXBsb2FkKCkpIHtcbiAgICAgIC8vIHVwbG9hZFJlZiBtYXkgYmUgdG9wIGxldmVsIHVwbG9hZCBjb25maWcgcmVmIG9yIGVudHJ5IHJlZlxuICAgICAgY29uc3QgZW50cnkgPSB1cGxvYWRlclxuICAgICAgICAuZW50cmllcygpXG4gICAgICAgIC5maW5kKChlbnRyeSkgPT4gZW50cnkucmVmID09PSB1cGxvYWRSZWYudG9TdHJpbmcoKSk7XG4gICAgICBpZiAoZW50cnkpIHtcbiAgICAgICAgZW50cnkuY2FuY2VsKCk7XG4gICAgICB9XG4gICAgfSBlbHNlIHtcbiAgICAgIHVwbG9hZGVyLmVudHJpZXMoKS5tYXAoKGVudHJ5KSA9PiBlbnRyeS5jYW5jZWwoKSk7XG4gICAgfVxuICAgIHRoaXMubG9nKFwidXBsb2FkXCIsICgpID0+IFtgZXJyb3IgZm9yIGVudHJ5ICR7dXBsb2FkUmVmfWAsIHJlYXNvbl0pO1xuICB9XG5cbiAgZGlzcGF0Y2hVcGxvYWRzKHRhcmdldEN0eCwgbmFtZSwgZmlsZXNPckJsb2JzKSB7XG4gICAgY29uc3QgdGFyZ2V0RWxlbWVudCA9IHRoaXMudGFyZ2V0Q3R4RWxlbWVudCh0YXJnZXRDdHgpIHx8IHRoaXMuZWw7XG4gICAgY29uc3QgaW5wdXRzID0gRE9NLmZpbmRVcGxvYWRJbnB1dHModGFyZ2V0RWxlbWVudCkuZmlsdGVyKFxuICAgICAgKGVsKSA9PiBlbC5uYW1lID09PSBuYW1lLFxuICAgICk7XG4gICAgaWYgKGlucHV0cy5sZW5ndGggPT09IDApIHtcbiAgICAgIGxvZ0Vycm9yKGBubyBsaXZlIGZpbGUgaW5wdXRzIGZvdW5kIG1hdGNoaW5nIHRoZSBuYW1lIFwiJHtuYW1lfVwiYCk7XG4gICAgfSBlbHNlIGlmIChpbnB1dHMubGVuZ3RoID4gMSkge1xuICAgICAgbG9nRXJyb3IoYGR1cGxpY2F0ZSBsaXZlIGZpbGUgaW5wdXRzIGZvdW5kIG1hdGNoaW5nIHRoZSBuYW1lIFwiJHtuYW1lfVwiYCk7XG4gICAgfSBlbHNlIHtcbiAgICAgIERPTS5kaXNwYXRjaEV2ZW50KGlucHV0c1swXSwgUEhYX1RSQUNLX1VQTE9BRFMsIHtcbiAgICAgICAgZGV0YWlsOiB7IGZpbGVzOiBmaWxlc09yQmxvYnMgfSxcbiAgICAgIH0pO1xuICAgIH1cbiAgfVxuXG4gIHRhcmdldEN0eEVsZW1lbnQodGFyZ2V0Q3R4KSB7XG4gICAgaWYgKGlzQ2lkKHRhcmdldEN0eCkpIHtcbiAgICAgIGNvbnN0IFt0YXJnZXRdID0gRE9NLmZpbmRDb21wb25lbnROb2RlTGlzdCh0aGlzLmlkLCB0YXJnZXRDdHgpO1xuICAgICAgcmV0dXJuIHRhcmdldDtcbiAgICB9IGVsc2UgaWYgKHRhcmdldEN0eCkge1xuICAgICAgcmV0dXJuIHRhcmdldEN0eDtcbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuIG51bGw7XG4gICAgfVxuICB9XG5cbiAgcHVzaEZvcm1SZWNvdmVyeShvbGRGb3JtLCBuZXdGb3JtLCB0ZW1wbGF0ZURvbSwgY2FsbGJhY2spIHtcbiAgICAvLyB3ZSBhcmUgb25seSByZWNvdmVyaW5nIGZvcm1zIGluc2lkZSB0aGUgY3VycmVudCB2aWV3LCB0aGVyZWZvcmUgaXQgaXMgc2FmZSB0b1xuICAgIC8vIHNraXAgd2l0aGluT3duZXJzIGhlcmUgYW5kIGFsd2F5cyB1c2UgdGhpcyB3aGVuIHJlZmVycmluZyB0byB0aGUgdmlld1xuICAgIGNvbnN0IHBoeENoYW5nZSA9IHRoaXMuYmluZGluZyhcImNoYW5nZVwiKTtcbiAgICBjb25zdCBwaHhUYXJnZXQgPSBuZXdGb3JtLmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoXCJ0YXJnZXRcIikpIHx8IG5ld0Zvcm07XG4gICAgY29uc3QgcGh4RXZlbnQgPVxuICAgICAgbmV3Rm9ybS5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9BVVRPX1JFQ09WRVIpKSB8fFxuICAgICAgbmV3Rm9ybS5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFwiY2hhbmdlXCIpKTtcbiAgICBjb25zdCBpbnB1dHMgPSBBcnJheS5mcm9tKG9sZEZvcm0uZWxlbWVudHMpLmZpbHRlcihcbiAgICAgIChlbCkgPT4gRE9NLmlzRm9ybUlucHV0KGVsKSAmJiBlbC5uYW1lICYmICFlbC5oYXNBdHRyaWJ1dGUocGh4Q2hhbmdlKSxcbiAgICApO1xuICAgIGlmIChpbnB1dHMubGVuZ3RoID09PSAwKSB7XG4gICAgICBjYWxsYmFjaygpO1xuICAgICAgcmV0dXJuO1xuICAgIH1cblxuICAgIC8vIHdlIG11c3QgY2xlYXIgdHJhY2tlZCB1cGxvYWRzIGJlZm9yZSByZWNvdmVyeSBhcyB0aGV5IG5vIGxvbmdlciBoYXZlIHZhbGlkIHJlZnNcbiAgICBpbnB1dHMuZm9yRWFjaChcbiAgICAgIChpbnB1dCkgPT5cbiAgICAgICAgaW5wdXQuaGFzQXR0cmlidXRlKFBIWF9VUExPQURfUkVGKSAmJiBMaXZlVXBsb2FkZXIuY2xlYXJGaWxlcyhpbnB1dCksXG4gICAgKTtcbiAgICAvLyBwdXNoSW5wdXQgYXNzdW1lcyB0aGF0IHRoZXJlIGlzIGEgc291cmNlIGVsZW1lbnQgdGhhdCBpbml0aWF0ZWQgdGhlIGNoYW5nZTtcbiAgICAvLyBiZWNhdXNlIHRoaXMgaXMgbm90IHRoZSBjYXNlIHdoZW4gd2UgcmVjb3ZlciBmb3Jtcywgd2UgcHJvdmlkZSB0aGUgZmlyc3QgaW5wdXQgd2UgZmluZFxuICAgIGNvbnN0IGlucHV0ID0gaW5wdXRzLmZpbmQoKGVsKSA9PiBlbC50eXBlICE9PSBcImhpZGRlblwiKSB8fCBpbnB1dHNbMF07XG5cbiAgICAvLyBpbiB0aGUgY2FzZSB0aGF0IHRoZXJlIGFyZSBtdWx0aXBsZSB0YXJnZXRzLCB3ZSBjb3VudCB0aGUgbnVtYmVyIG9mIHBlbmRpbmcgcmVjb3ZlcnkgZXZlbnRzXG4gICAgLy8gYW5kIG9ubHkgY2FsbCB0aGUgY2FsbGJhY2sgb25jZSBhbGwgZXZlbnRzIGhhdmUgYmVlbiBwcm9jZXNzZWRcbiAgICBsZXQgcGVuZGluZyA9IDA7XG4gICAgLy8gd2l0aGluVGFyZ2V0cyhwaHhUYXJnZXQsIGNhbGxiYWNrLCBkb20sIHZpZXdFbClcbiAgICB0aGlzLndpdGhpblRhcmdldHMoXG4gICAgICBwaHhUYXJnZXQsXG4gICAgICAodGFyZ2V0VmlldywgdGFyZ2V0Q3R4KSA9PiB7XG4gICAgICAgIGNvbnN0IGNpZCA9IHRoaXMudGFyZ2V0Q29tcG9uZW50SUQobmV3Rm9ybSwgdGFyZ2V0Q3R4KTtcbiAgICAgICAgcGVuZGluZysrO1xuICAgICAgICBsZXQgZSA9IG5ldyBDdXN0b21FdmVudChcInBoeDpmb3JtLXJlY292ZXJ5XCIsIHtcbiAgICAgICAgICBkZXRhaWw6IHsgc291cmNlRWxlbWVudDogb2xkRm9ybSB9LFxuICAgICAgICB9KTtcbiAgICAgICAgSlMuZXhlYyhlLCBcImNoYW5nZVwiLCBwaHhFdmVudCwgdGhpcywgaW5wdXQsIFtcbiAgICAgICAgICBcInB1c2hcIixcbiAgICAgICAgICB7XG4gICAgICAgICAgICBfdGFyZ2V0OiBpbnB1dC5uYW1lLFxuICAgICAgICAgICAgdGFyZ2V0VmlldyxcbiAgICAgICAgICAgIHRhcmdldEN0eCxcbiAgICAgICAgICAgIG5ld0NpZDogY2lkLFxuICAgICAgICAgICAgY2FsbGJhY2s6ICgpID0+IHtcbiAgICAgICAgICAgICAgcGVuZGluZy0tO1xuICAgICAgICAgICAgICBpZiAocGVuZGluZyA9PT0gMCkge1xuICAgICAgICAgICAgICAgIGNhbGxiYWNrKCk7XG4gICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgfSxcbiAgICAgICAgXSk7XG4gICAgICB9LFxuICAgICAgdGVtcGxhdGVEb20sXG4gICAgKTtcbiAgfVxuXG4gIHB1c2hMaW5rUGF0Y2goZSwgaHJlZiwgdGFyZ2V0RWwsIGNhbGxiYWNrKSB7XG4gICAgY29uc3QgbGlua1JlZiA9IHRoaXMubGl2ZVNvY2tldC5zZXRQZW5kaW5nTGluayhocmVmKTtcbiAgICAvLyBvbmx5IGFkZCBsb2FkaW5nIHN0YXRlcyBpZiBldmVudCBpcyB0cnVzdGVkIChpdCB3YXMgdHJpZ2dlcmVkIGJ5IHVzZXIsIHN1Y2ggYXMgY2xpY2spIGFuZFxuICAgIC8vIGl0J3Mgbm90IGEgZm9yd2FyZC9iYWNrIG5hdmlnYXRpb24gZnJvbSBwb3BzdGF0ZVxuICAgIGNvbnN0IGxvYWRpbmcgPSBlLmlzVHJ1c3RlZCAmJiBlLnR5cGUgIT09IFwicG9wc3RhdGVcIjtcbiAgICBjb25zdCByZWZHZW4gPSB0YXJnZXRFbFxuICAgICAgPyAoKSA9PlxuICAgICAgICAgIHRoaXMucHV0UmVmKFxuICAgICAgICAgICAgW3sgZWw6IHRhcmdldEVsLCBsb2FkaW5nOiBsb2FkaW5nLCBsb2NrOiB0cnVlIH1dLFxuICAgICAgICAgICAgbnVsbCxcbiAgICAgICAgICAgIFwiY2xpY2tcIixcbiAgICAgICAgICApXG4gICAgICA6IG51bGw7XG4gICAgY29uc3QgZmFsbGJhY2sgPSAoKSA9PiB0aGlzLmxpdmVTb2NrZXQucmVkaXJlY3Qod2luZG93LmxvY2F0aW9uLmhyZWYpO1xuICAgIGNvbnN0IHVybCA9IGhyZWYuc3RhcnRzV2l0aChcIi9cIilcbiAgICAgID8gYCR7bG9jYXRpb24ucHJvdG9jb2x9Ly8ke2xvY2F0aW9uLmhvc3R9JHtocmVmfWBcbiAgICAgIDogaHJlZjtcblxuICAgIHRoaXMucHVzaFdpdGhSZXBseShyZWZHZW4sIFwibGl2ZV9wYXRjaFwiLCB7IHVybCB9KS50aGVuKFxuICAgICAgKHsgcmVzcCB9KSA9PiB7XG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgICBpZiAocmVzcC5saW5rX3JlZGlyZWN0KSB7XG4gICAgICAgICAgICB0aGlzLmxpdmVTb2NrZXQucmVwbGFjZU1haW4oaHJlZiwgbnVsbCwgY2FsbGJhY2ssIGxpbmtSZWYpO1xuICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBpZiAodGhpcy5saXZlU29ja2V0LmNvbW1pdFBlbmRpbmdMaW5rKGxpbmtSZWYpKSB7XG4gICAgICAgICAgICAgIHRoaXMuaHJlZiA9IGhyZWY7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICB0aGlzLmFwcGx5UGVuZGluZ1VwZGF0ZXMoKTtcbiAgICAgICAgICAgIGNhbGxiYWNrICYmIGNhbGxiYWNrKGxpbmtSZWYpO1xuICAgICAgICAgIH1cbiAgICAgICAgfSk7XG4gICAgICB9LFxuICAgICAgKHsgZXJyb3I6IF9lcnJvciwgdGltZW91dDogX3RpbWVvdXQgfSkgPT4gZmFsbGJhY2soKSxcbiAgICApO1xuICB9XG5cbiAgZ2V0Rm9ybXNGb3JSZWNvdmVyeSgpIHtcbiAgICAvLyBGb3JtIHJlY292ZXJ5IGlzIGNvbXBsZXggaW4gTGl2ZVZpZXc6XG4gICAgLy8gV2Ugd2FudCB0byBzdXBwb3J0IG5lc3RlZCBMaXZlVmlld3MgYW5kIGFsc28gcHJvdmlkZSBhIGdvb2QgdXNlciBleHBlcmllbmNlLlxuICAgIC8vIFRoZXJlZm9yZSwgd2hlbiB0aGUgY2hhbm5lbCByZWpvaW5zLCB3ZSBjb3B5IGFsbCBmb3JtcyB0aGF0IGFyZSBlbGlnaWJsZSBmb3JcbiAgICAvLyByZWNvdmVyeSB0byBiZSBhYmxlIHRvIGFjY2VzcyB0aGVtIGxhdGVyLlxuICAgIC8vIFdoeSBkbyB3ZSBuZWVkIHRvIGNvcHkgdGhlbT8gQmVjYXVzZSB3aGVuIHRoZSBtYWluIExpdmVWaWV3IGpvaW5zLCBhbnkgZm9ybXNcbiAgICAvLyBpbiBuZXN0ZWQgTGl2ZVZpZXdzIHdvdWxkIGJlIGxvc3QuXG4gICAgLy9cbiAgICAvLyBXZSBzaG91bGQgcmV3b3JrIHRoaXMgaW4gdGhlIGZ1dHVyZSB0byBzZXJpYWxpemUgdGhlIGZvcm0gcGF5bG9hZCBoZXJlXG4gICAgLy8gaW5zdGVhZCBvZiBjbG9uaW5nIHRoZSBET00gbm9kZXMsIGJ1dCBtYWtpbmcgdGhpcyB3b3JrIGNvcnJlY3RseSBpcyB0ZWRpb3VzLFxuICAgIC8vIGFzIHNlbmRpbmcgdGhlIGNvcnJlY3QgZm9ybSBwYXlsb2FkIHJlbGllcyBvbiBKUy5wdXNoIHRvIGV4dHJhY3QgdmFsdWVzXG4gICAgLy8gZnJvbSBKUyBjb21tYW5kcyAocGh4LWNoYW5nZT17SlMucHVzaChcImV2ZW50XCIsIHZhbHVlOiAuLi4sIHRhcmdldDogLi4uKX0pLFxuICAgIC8vIGFzIHdlbGwgYXMgdmlldy5wdXNoSW5wdXQsIHdoaWNoIGV4cGVjdHMgRE9NIGVsZW1lbnRzLlxuXG4gICAgaWYgKHRoaXMuam9pbkNvdW50ID09PSAwKSB7XG4gICAgICByZXR1cm4ge307XG4gICAgfVxuXG4gICAgY29uc3QgcGh4Q2hhbmdlID0gdGhpcy5iaW5kaW5nKFwiY2hhbmdlXCIpO1xuXG4gICAgcmV0dXJuIERPTS5hbGwodGhpcy5lbCwgYGZvcm1bJHtwaHhDaGFuZ2V9XWApXG4gICAgICAuZmlsdGVyKChmb3JtKSA9PiBmb3JtLmlkKVxuICAgICAgLmZpbHRlcigoZm9ybSkgPT4gZm9ybS5lbGVtZW50cy5sZW5ndGggPiAwKVxuICAgICAgLmZpbHRlcihcbiAgICAgICAgKGZvcm0pID0+XG4gICAgICAgICAgZm9ybS5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9BVVRPX1JFQ09WRVIpKSAhPT0gXCJpZ25vcmVcIixcbiAgICAgIClcbiAgICAgIC5tYXAoKGZvcm0pID0+IHtcbiAgICAgICAgLy8gV2UgbmVlZCB0byBjbG9uZSB0aGUgd2hvbGUgZm9ybSwgYXMgcmVseWluZyBvbiBmb3JtLmVsZW1lbnRzIGNhbiBsZWFkIHRvXG4gICAgICAgIC8vIHNpdHVhdGlvbnMgd2hlcmUgd2UgaGF2ZVxuICAgICAgICAvL1xuICAgICAgICAvLyAgIDxmb3JtPjxmaWVsZHNldCBkaXNhYmxlZD48aW5wdXQgbmFtZT1cImZvb1wiIHZhbHVlPVwiYmFyXCI+PC9maWVsZHNldD48L2Zvcm0+XG4gICAgICAgIC8vXG4gICAgICAgIC8vIGFuZCBmb3JtLmVsZW1lbnRzIHJldHVybnMgYm90aCB0aGUgZmllbGRzZXQgYW5kIHRoZSBpbnB1dCBzZXBhcmF0ZWx5LlxuICAgICAgICAvLyBCZWNhdXNlIHRoZSBmaWVsZHNldCBpcyBkaXNhYmxlZCwgdGhlIGlucHV0IHNob3VsZCBOT1QgYmUgc2VudCB0aG91Z2guXG4gICAgICAgIC8vIFdlIGNhbiBvbmx5IHJlbGlhYmx5IHNlcmlhbGl6ZSB0aGUgZm9ybSBieSBjbG9uaW5nIGl0IGZ1bGx5LlxuICAgICAgICBjb25zdCBjbG9uZWRGb3JtID0gZm9ybS5jbG9uZU5vZGUodHJ1ZSk7XG4gICAgICAgIC8vIHdlIGNhbGwgbW9ycGhkb20gdG8gY29weSBhbnkgc3BlY2lhbCBzdGF0ZVxuICAgICAgICAvLyBsaWtlIHRoZSBzZWxlY3RlZCBvcHRpb24gb2YgYSA8c2VsZWN0PiBlbGVtZW50O1xuICAgICAgICAvLyBhbnkgYWxzbyBjb3B5IG92ZXIgcHJpdmF0ZXMgKHdoaWNoIGNvbnRhaW4gaW5mb3JtYXRpb24gYWJvdXQgdG91Y2hlZCBmaWVsZHMpXG4gICAgICAgIG1vcnBoZG9tKGNsb25lZEZvcm0sIGZvcm0sIHtcbiAgICAgICAgICBvbkJlZm9yZUVsVXBkYXRlZDogKGZyb21FbCwgdG9FbCkgPT4ge1xuICAgICAgICAgICAgRE9NLmNvcHlQcml2YXRlcyhmcm9tRWwsIHRvRWwpO1xuICAgICAgICAgICAgcmV0dXJuIHRydWU7XG4gICAgICAgICAgfSxcbiAgICAgICAgfSk7XG4gICAgICAgIC8vIG5leHQgdXAsIHdlIGFsc28gbmVlZCB0byBjbG9uZSBhbnkgZWxlbWVudHMgd2l0aCBmb3JtPVwiaWRcIiBwYXJhbWV0ZXJcbiAgICAgICAgY29uc3QgZXh0ZXJuYWxFbGVtZW50cyA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoXG4gICAgICAgICAgYFtmb3JtPVwiJHtmb3JtLmlkfVwiXWAsXG4gICAgICAgICk7XG4gICAgICAgIEFycmF5LmZyb20oZXh0ZXJuYWxFbGVtZW50cykuZm9yRWFjaCgoZWwpID0+IHtcbiAgICAgICAgICBpZiAoZm9ybS5jb250YWlucyhlbCkpIHtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgICB9XG4gICAgICAgICAgY29uc3QgY2xvbmVkRWwgPSBlbC5jbG9uZU5vZGUodHJ1ZSk7XG4gICAgICAgICAgbW9ycGhkb20oY2xvbmVkRWwsIGVsKTtcbiAgICAgICAgICBET00uY29weVByaXZhdGVzKGNsb25lZEVsLCBlbCk7XG4gICAgICAgICAgY2xvbmVkRm9ybS5hcHBlbmRDaGlsZChjbG9uZWRFbCk7XG4gICAgICAgIH0pO1xuICAgICAgICByZXR1cm4gY2xvbmVkRm9ybTtcbiAgICAgIH0pXG4gICAgICAucmVkdWNlKChhY2MsIGZvcm0pID0+IHtcbiAgICAgICAgYWNjW2Zvcm0uaWRdID0gZm9ybTtcbiAgICAgICAgcmV0dXJuIGFjYztcbiAgICAgIH0sIHt9KTtcbiAgfVxuXG4gIG1heWJlUHVzaENvbXBvbmVudHNEZXN0cm95ZWQoZGVzdHJveWVkQ0lEcykge1xuICAgIGxldCB3aWxsRGVzdHJveUNJRHMgPSBkZXN0cm95ZWRDSURzLmZpbHRlcigoY2lkKSA9PiB7XG4gICAgICByZXR1cm4gRE9NLmZpbmRDb21wb25lbnROb2RlTGlzdCh0aGlzLmVsLCBjaWQpLmxlbmd0aCA9PT0gMDtcbiAgICB9KTtcblxuICAgIGNvbnN0IG9uRXJyb3IgPSAoZXJyb3IpID0+IHtcbiAgICAgIGlmICghdGhpcy5pc0Rlc3Ryb3llZCgpKSB7XG4gICAgICAgIGxvZ0Vycm9yKFwiRmFpbGVkIHRvIHB1c2ggY29tcG9uZW50cyBkZXN0cm95ZWRcIiwgZXJyb3IpO1xuICAgICAgfVxuICAgIH07XG5cbiAgICBpZiAod2lsbERlc3Ryb3lDSURzLmxlbmd0aCA+IDApIHtcbiAgICAgIC8vIHdlIG11c3QgcmVzZXQgdGhlIHJlbmRlciBjaGFuZ2UgdHJhY2tpbmcgZm9yIGNpZHMgdGhhdFxuICAgICAgLy8gY291bGQgYmUgYWRkZWQgYmFjayBmcm9tIHRoZSBzZXJ2ZXIgc28gd2UgZG9uJ3Qgc2tpcCB0aGVtXG4gICAgICB3aWxsRGVzdHJveUNJRHMuZm9yRWFjaCgoY2lkKSA9PiB0aGlzLnJlbmRlcmVkLnJlc2V0UmVuZGVyKGNpZCkpO1xuXG4gICAgICB0aGlzLnB1c2hXaXRoUmVwbHkobnVsbCwgXCJjaWRzX3dpbGxfZGVzdHJveVwiLCB7IGNpZHM6IHdpbGxEZXN0cm95Q0lEcyB9KVxuICAgICAgICAudGhlbigoKSA9PiB7XG4gICAgICAgICAgLy8gd2UgbXVzdCB3YWl0IGZvciBwZW5kaW5nIHRyYW5zaXRpb25zIHRvIGNvbXBsZXRlIGJlZm9yZSBkZXRlcm1pbmluZ1xuICAgICAgICAgIC8vIGlmIHRoZSBjaWRzIHdlcmUgYWRkZWQgYmFjayB0byB0aGUgRE9NIGluIHRoZSBtZWFudGltZSAoIzMxMzkpXG4gICAgICAgICAgdGhpcy5saXZlU29ja2V0LnJlcXVlc3RET01VcGRhdGUoKCkgPT4ge1xuICAgICAgICAgICAgLy8gU2VlIGlmIGFueSBvZiB0aGUgY2lkcyB3ZSB3YW50ZWQgdG8gZGVzdHJveSB3ZXJlIGFkZGVkIGJhY2ssXG4gICAgICAgICAgICAvLyBpZiB0aGV5IHdlcmUgYWRkZWQgYmFjaywgd2UgZG9uJ3QgYWN0dWFsbHkgZGVzdHJveSB0aGVtLlxuICAgICAgICAgICAgbGV0IGNvbXBsZXRlbHlEZXN0cm95Q0lEcyA9IHdpbGxEZXN0cm95Q0lEcy5maWx0ZXIoKGNpZCkgPT4ge1xuICAgICAgICAgICAgICByZXR1cm4gRE9NLmZpbmRDb21wb25lbnROb2RlTGlzdCh0aGlzLmVsLCBjaWQpLmxlbmd0aCA9PT0gMDtcbiAgICAgICAgICAgIH0pO1xuXG4gICAgICAgICAgICBpZiAoY29tcGxldGVseURlc3Ryb3lDSURzLmxlbmd0aCA+IDApIHtcbiAgICAgICAgICAgICAgdGhpcy5wdXNoV2l0aFJlcGx5KG51bGwsIFwiY2lkc19kZXN0cm95ZWRcIiwge1xuICAgICAgICAgICAgICAgIGNpZHM6IGNvbXBsZXRlbHlEZXN0cm95Q0lEcyxcbiAgICAgICAgICAgICAgfSlcbiAgICAgICAgICAgICAgICAudGhlbigoeyByZXNwIH0pID0+IHtcbiAgICAgICAgICAgICAgICAgIHRoaXMucmVuZGVyZWQucHJ1bmVDSURzKHJlc3AuY2lkcyk7XG4gICAgICAgICAgICAgICAgfSlcbiAgICAgICAgICAgICAgICAuY2F0Y2gob25FcnJvcik7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgfSk7XG4gICAgICAgIH0pXG4gICAgICAgIC5jYXRjaChvbkVycm9yKTtcbiAgICB9XG4gIH1cblxuICBvd25zRWxlbWVudChlbCkge1xuICAgIGxldCBwYXJlbnRWaWV3RWwgPSBlbC5jbG9zZXN0KFBIWF9WSUVXX1NFTEVDVE9SKTtcbiAgICByZXR1cm4gKFxuICAgICAgZWwuZ2V0QXR0cmlidXRlKFBIWF9QQVJFTlRfSUQpID09PSB0aGlzLmlkIHx8XG4gICAgICAocGFyZW50Vmlld0VsICYmIHBhcmVudFZpZXdFbC5pZCA9PT0gdGhpcy5pZCkgfHxcbiAgICAgICghcGFyZW50Vmlld0VsICYmIHRoaXMuaXNEZWFkKVxuICAgICk7XG4gIH1cblxuICBzdWJtaXRGb3JtKGZvcm0sIHRhcmdldEN0eCwgcGh4RXZlbnQsIHN1Ym1pdHRlciwgb3B0cyA9IHt9KSB7XG4gICAgRE9NLnB1dFByaXZhdGUoZm9ybSwgUEhYX0hBU19TVUJNSVRURUQsIHRydWUpO1xuICAgIGNvbnN0IGlucHV0cyA9IEFycmF5LmZyb20oZm9ybS5lbGVtZW50cyk7XG4gICAgaW5wdXRzLmZvckVhY2goKGlucHV0KSA9PiBET00ucHV0UHJpdmF0ZShpbnB1dCwgUEhYX0hBU19TVUJNSVRURUQsIHRydWUpKTtcbiAgICB0aGlzLmxpdmVTb2NrZXQuYmx1ckFjdGl2ZUVsZW1lbnQodGhpcyk7XG4gICAgdGhpcy5wdXNoRm9ybVN1Ym1pdChmb3JtLCB0YXJnZXRDdHgsIHBoeEV2ZW50LCBzdWJtaXR0ZXIsIG9wdHMsICgpID0+IHtcbiAgICAgIHRoaXMubGl2ZVNvY2tldC5yZXN0b3JlUHJldmlvdXNseUFjdGl2ZUZvY3VzKCk7XG4gICAgfSk7XG4gIH1cblxuICBiaW5kaW5nKGtpbmQpIHtcbiAgICByZXR1cm4gdGhpcy5saXZlU29ja2V0LmJpbmRpbmcoa2luZCk7XG4gIH1cblxuICAvLyBwaHgtcG9ydGFsXG4gIHB1c2hQb3J0YWxFbGVtZW50SWQoaWQpIHtcbiAgICB0aGlzLnBvcnRhbEVsZW1lbnRJZHMuYWRkKGlkKTtcbiAgfVxuXG4gIGRyb3BQb3J0YWxFbGVtZW50SWQoaWQpIHtcbiAgICB0aGlzLnBvcnRhbEVsZW1lbnRJZHMuZGVsZXRlKGlkKTtcbiAgfVxuXG4gIGRlc3Ryb3lQb3J0YWxFbGVtZW50cygpIHtcbiAgICB0aGlzLnBvcnRhbEVsZW1lbnRJZHMuZm9yRWFjaCgoaWQpID0+IHtcbiAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpO1xuICAgICAgaWYgKGVsKSB7XG4gICAgICAgIGVsLnJlbW92ZSgpO1xuICAgICAgfVxuICAgIH0pO1xuICB9XG59XG4iLCAiaW1wb3J0IHtcbiAgQklORElOR19QUkVGSVgsXG4gIENPTlNFQ1VUSVZFX1JFTE9BRFMsXG4gIERFRkFVTFRTLFxuICBGQUlMU0FGRV9KSVRURVIsXG4gIExPQURFUl9USU1FT1VULFxuICBESVNDT05ORUNURURfVElNRU9VVCxcbiAgTUFYX1JFTE9BRFMsXG4gIFBIWF9ERUJPVU5DRSxcbiAgUEhYX0RST1BfVEFSR0VULFxuICBQSFhfSEFTX0ZPQ1VTRUQsXG4gIFBIWF9LRVksXG4gIFBIWF9MSU5LX1NUQVRFLFxuICBQSFhfTElWRV9MSU5LLFxuICBQSFhfTFZfREVCVUcsXG4gIFBIWF9MVl9MQVRFTkNZX1NJTSxcbiAgUEhYX0xWX1BST0ZJTEUsXG4gIFBIWF9MVl9ISVNUT1JZX1BPU0lUSU9OLFxuICBQSFhfTUFJTixcbiAgUEhYX1BBUkVOVF9JRCxcbiAgUEhYX1ZJRVdfU0VMRUNUT1IsXG4gIFBIWF9ST09UX0lELFxuICBQSFhfVEhST1RUTEUsXG4gIFBIWF9UUkFDS19VUExPQURTLFxuICBQSFhfU0VTU0lPTixcbiAgUkVMT0FEX0pJVFRFUl9NSU4sXG4gIFJFTE9BRF9KSVRURVJfTUFYLFxuICBQSFhfUkVGX1NSQyxcbiAgUEhYX1JFTE9BRF9TVEFUVVMsXG4gIFBIWF9SVU5USU1FX0hPT0ssXG59IGZyb20gXCIuL2NvbnN0YW50c1wiO1xuXG5pbXBvcnQge1xuICBjbG9uZSxcbiAgY2xvc2VzdFBoeEJpbmRpbmcsXG4gIGNsb3N1cmUsXG4gIGRlYnVnLFxuICBtYXliZSxcbiAgbG9nRXJyb3IsXG59IGZyb20gXCIuL3V0aWxzXCI7XG5cbmltcG9ydCBCcm93c2VyIGZyb20gXCIuL2Jyb3dzZXJcIjtcbmltcG9ydCBET00gZnJvbSBcIi4vZG9tXCI7XG5pbXBvcnQgSG9va3MgZnJvbSBcIi4vaG9va3NcIjtcbmltcG9ydCBMaXZlVXBsb2FkZXIgZnJvbSBcIi4vbGl2ZV91cGxvYWRlclwiO1xuaW1wb3J0IFZpZXcgZnJvbSBcIi4vdmlld1wiO1xuaW1wb3J0IEpTIGZyb20gXCIuL2pzXCI7XG5pbXBvcnQganNDb21tYW5kcyBmcm9tIFwiLi9qc19jb21tYW5kc1wiO1xuXG5leHBvcnQgY29uc3QgaXNVc2VkSW5wdXQgPSAoZWwpID0+IERPTS5pc1VzZWRJbnB1dChlbCk7XG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIExpdmVTb2NrZXQge1xuICBjb25zdHJ1Y3Rvcih1cmwsIHBoeFNvY2tldCwgb3B0cyA9IHt9KSB7XG4gICAgdGhpcy51bmxvYWRlZCA9IGZhbHNlO1xuICAgIGlmICghcGh4U29ja2V0IHx8IHBoeFNvY2tldC5jb25zdHJ1Y3Rvci5uYW1lID09PSBcIk9iamVjdFwiKSB7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoYFxuICAgICAgYSBwaG9lbml4IFNvY2tldCBtdXN0IGJlIHByb3ZpZGVkIGFzIHRoZSBzZWNvbmQgYXJndW1lbnQgdG8gdGhlIExpdmVTb2NrZXQgY29uc3RydWN0b3IuIEZvciBleGFtcGxlOlxuXG4gICAgICAgICAgaW1wb3J0IHtTb2NrZXR9IGZyb20gXCJwaG9lbml4XCJcbiAgICAgICAgICBpbXBvcnQge0xpdmVTb2NrZXR9IGZyb20gXCJwaG9lbml4X2xpdmVfdmlld1wiXG4gICAgICAgICAgbGV0IGxpdmVTb2NrZXQgPSBuZXcgTGl2ZVNvY2tldChcIi9saXZlXCIsIFNvY2tldCwgey4uLn0pXG4gICAgICBgKTtcbiAgICB9XG4gICAgdGhpcy5zb2NrZXQgPSBuZXcgcGh4U29ja2V0KHVybCwgb3B0cyk7XG4gICAgdGhpcy5iaW5kaW5nUHJlZml4ID0gb3B0cy5iaW5kaW5nUHJlZml4IHx8IEJJTkRJTkdfUFJFRklYO1xuICAgIHRoaXMub3B0cyA9IG9wdHM7XG4gICAgdGhpcy5wYXJhbXMgPSBjbG9zdXJlKG9wdHMucGFyYW1zIHx8IHt9KTtcbiAgICB0aGlzLnZpZXdMb2dnZXIgPSBvcHRzLnZpZXdMb2dnZXI7XG4gICAgdGhpcy5tZXRhZGF0YUNhbGxiYWNrcyA9IG9wdHMubWV0YWRhdGEgfHwge307XG4gICAgdGhpcy5kZWZhdWx0cyA9IE9iamVjdC5hc3NpZ24oY2xvbmUoREVGQVVMVFMpLCBvcHRzLmRlZmF1bHRzIHx8IHt9KTtcbiAgICB0aGlzLnByZXZBY3RpdmUgPSBudWxsO1xuICAgIHRoaXMuc2lsZW5jZWQgPSBmYWxzZTtcbiAgICB0aGlzLm1haW4gPSBudWxsO1xuICAgIHRoaXMub3V0Z29pbmdNYWluRWwgPSBudWxsO1xuICAgIHRoaXMuY2xpY2tTdGFydGVkQXRUYXJnZXQgPSBudWxsO1xuICAgIHRoaXMubGlua1JlZiA9IDE7XG4gICAgdGhpcy5yb290cyA9IHt9O1xuICAgIHRoaXMuaHJlZiA9IHdpbmRvdy5sb2NhdGlvbi5ocmVmO1xuICAgIHRoaXMucGVuZGluZ0xpbmsgPSBudWxsO1xuICAgIHRoaXMuY3VycmVudExvY2F0aW9uID0gY2xvbmUod2luZG93LmxvY2F0aW9uKTtcbiAgICB0aGlzLmhvb2tzID0gb3B0cy5ob29rcyB8fCB7fTtcbiAgICB0aGlzLnVwbG9hZGVycyA9IG9wdHMudXBsb2FkZXJzIHx8IHt9O1xuICAgIHRoaXMubG9hZGVyVGltZW91dCA9IG9wdHMubG9hZGVyVGltZW91dCB8fCBMT0FERVJfVElNRU9VVDtcbiAgICB0aGlzLmRpc2Nvbm5lY3RlZFRpbWVvdXQgPSBvcHRzLmRpc2Nvbm5lY3RlZFRpbWVvdXQgfHwgRElTQ09OTkVDVEVEX1RJTUVPVVQ7XG4gICAgLyoqXG4gICAgICogQHR5cGUge1JldHVyblR5cGU8dHlwZW9mIHNldFRpbWVvdXQ+IHwgbnVsbH1cbiAgICAgKi9cbiAgICB0aGlzLnJlbG9hZFdpdGhKaXR0ZXJUaW1lciA9IG51bGw7XG4gICAgdGhpcy5tYXhSZWxvYWRzID0gb3B0cy5tYXhSZWxvYWRzIHx8IE1BWF9SRUxPQURTO1xuICAgIHRoaXMucmVsb2FkSml0dGVyTWluID0gb3B0cy5yZWxvYWRKaXR0ZXJNaW4gfHwgUkVMT0FEX0pJVFRFUl9NSU47XG4gICAgdGhpcy5yZWxvYWRKaXR0ZXJNYXggPSBvcHRzLnJlbG9hZEppdHRlck1heCB8fCBSRUxPQURfSklUVEVSX01BWDtcbiAgICB0aGlzLmZhaWxzYWZlSml0dGVyID0gb3B0cy5mYWlsc2FmZUppdHRlciB8fCBGQUlMU0FGRV9KSVRURVI7XG4gICAgdGhpcy5sb2NhbFN0b3JhZ2UgPSBvcHRzLmxvY2FsU3RvcmFnZSB8fCB3aW5kb3cubG9jYWxTdG9yYWdlO1xuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2UgPSBvcHRzLnNlc3Npb25TdG9yYWdlIHx8IHdpbmRvdy5zZXNzaW9uU3RvcmFnZTtcbiAgICB0aGlzLmJvdW5kVG9wTGV2ZWxFdmVudHMgPSBmYWxzZTtcbiAgICB0aGlzLmJvdW5kRXZlbnROYW1lcyA9IG5ldyBTZXQoKTtcbiAgICB0aGlzLmJsb2NrUGh4Q2hhbmdlV2hpbGVDb21wb3NpbmcgPVxuICAgICAgb3B0cy5ibG9ja1BoeENoYW5nZVdoaWxlQ29tcG9zaW5nIHx8IGZhbHNlO1xuICAgIHRoaXMuc2VydmVyQ2xvc2VSZWYgPSBudWxsO1xuICAgIHRoaXMuZG9tQ2FsbGJhY2tzID0gT2JqZWN0LmFzc2lnbihcbiAgICAgIHtcbiAgICAgICAganNRdWVyeVNlbGVjdG9yQWxsOiBudWxsLFxuICAgICAgICBvblBhdGNoU3RhcnQ6IGNsb3N1cmUoKSxcbiAgICAgICAgb25QYXRjaEVuZDogY2xvc3VyZSgpLFxuICAgICAgICBvbk5vZGVBZGRlZDogY2xvc3VyZSgpLFxuICAgICAgICBvbkJlZm9yZUVsVXBkYXRlZDogY2xvc3VyZSgpLFxuICAgICAgfSxcbiAgICAgIG9wdHMuZG9tIHx8IHt9LFxuICAgICk7XG4gICAgdGhpcy50cmFuc2l0aW9ucyA9IG5ldyBUcmFuc2l0aW9uU2V0KCk7XG4gICAgdGhpcy5jdXJyZW50SGlzdG9yeVBvc2l0aW9uID1cbiAgICAgIHBhcnNlSW50KHRoaXMuc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShQSFhfTFZfSElTVE9SWV9QT1NJVElPTikpIHx8IDA7XG4gICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoXCJwYWdlaGlkZVwiLCAoX2UpID0+IHtcbiAgICAgIHRoaXMudW5sb2FkZWQgPSB0cnVlO1xuICAgIH0pO1xuICAgIHRoaXMuc29ja2V0Lm9uT3BlbigoKSA9PiB7XG4gICAgICBpZiAodGhpcy5pc1VubG9hZGVkKCkpIHtcbiAgICAgICAgLy8gcmVsb2FkIHBhZ2UgaWYgYmVpbmcgcmVzdG9yZWQgZnJvbSBiYWNrL2ZvcndhcmQgY2FjaGUgYW5kIGJyb3dzZXIgZG9lcyBub3QgZW1pdCBcInBhZ2VzaG93XCJcbiAgICAgICAgd2luZG93LmxvY2F0aW9uLnJlbG9hZCgpO1xuICAgICAgfVxuICAgIH0pO1xuICB9XG5cbiAgLy8gcHVibGljXG5cbiAgdmVyc2lvbigpIHtcbiAgICByZXR1cm4gTFZfVlNOO1xuICB9XG5cbiAgaXNQcm9maWxlRW5hYmxlZCgpIHtcbiAgICByZXR1cm4gdGhpcy5zZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFBIWF9MVl9QUk9GSUxFKSA9PT0gXCJ0cnVlXCI7XG4gIH1cblxuICBpc0RlYnVnRW5hYmxlZCgpIHtcbiAgICByZXR1cm4gdGhpcy5zZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFBIWF9MVl9ERUJVRykgPT09IFwidHJ1ZVwiO1xuICB9XG5cbiAgaXNEZWJ1Z0Rpc2FibGVkKCkge1xuICAgIHJldHVybiB0aGlzLnNlc3Npb25TdG9yYWdlLmdldEl0ZW0oUEhYX0xWX0RFQlVHKSA9PT0gXCJmYWxzZVwiO1xuICB9XG5cbiAgZW5hYmxlRGVidWcoKSB7XG4gICAgdGhpcy5zZXNzaW9uU3RvcmFnZS5zZXRJdGVtKFBIWF9MVl9ERUJVRywgXCJ0cnVlXCIpO1xuICB9XG5cbiAgZW5hYmxlUHJvZmlsaW5nKCkge1xuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2Uuc2V0SXRlbShQSFhfTFZfUFJPRklMRSwgXCJ0cnVlXCIpO1xuICB9XG5cbiAgZGlzYWJsZURlYnVnKCkge1xuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2Uuc2V0SXRlbShQSFhfTFZfREVCVUcsIFwiZmFsc2VcIik7XG4gIH1cblxuICBkaXNhYmxlUHJvZmlsaW5nKCkge1xuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShQSFhfTFZfUFJPRklMRSk7XG4gIH1cblxuICBlbmFibGVMYXRlbmN5U2ltKHVwcGVyQm91bmRNcykge1xuICAgIHRoaXMuZW5hYmxlRGVidWcoKTtcbiAgICBjb25zb2xlLmxvZyhcbiAgICAgIFwibGF0ZW5jeSBzaW11bGF0b3IgZW5hYmxlZCBmb3IgdGhlIGR1cmF0aW9uIG9mIHRoaXMgYnJvd3NlciBzZXNzaW9uLiBDYWxsIGRpc2FibGVMYXRlbmN5U2ltKCkgdG8gZGlzYWJsZVwiLFxuICAgICk7XG4gICAgdGhpcy5zZXNzaW9uU3RvcmFnZS5zZXRJdGVtKFBIWF9MVl9MQVRFTkNZX1NJTSwgdXBwZXJCb3VuZE1zKTtcbiAgfVxuXG4gIGRpc2FibGVMYXRlbmN5U2ltKCkge1xuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShQSFhfTFZfTEFURU5DWV9TSU0pO1xuICB9XG5cbiAgZ2V0TGF0ZW5jeVNpbSgpIHtcbiAgICBjb25zdCBzdHIgPSB0aGlzLnNlc3Npb25TdG9yYWdlLmdldEl0ZW0oUEhYX0xWX0xBVEVOQ1lfU0lNKTtcbiAgICByZXR1cm4gc3RyID8gcGFyc2VJbnQoc3RyKSA6IG51bGw7XG4gIH1cblxuICBnZXRTb2NrZXQoKSB7XG4gICAgcmV0dXJuIHRoaXMuc29ja2V0O1xuICB9XG5cbiAgY29ubmVjdCgpIHtcbiAgICAvLyBlbmFibGUgZGVidWcgYnkgZGVmYXVsdCBpZiBvbiBsb2NhbGhvc3QgYW5kIG5vdCBleHBsaWNpdGx5IGRpc2FibGVkXG4gICAgaWYgKHdpbmRvdy5sb2NhdGlvbi5ob3N0bmFtZSA9PT0gXCJsb2NhbGhvc3RcIiAmJiAhdGhpcy5pc0RlYnVnRGlzYWJsZWQoKSkge1xuICAgICAgdGhpcy5lbmFibGVEZWJ1ZygpO1xuICAgIH1cbiAgICBjb25zdCBkb0Nvbm5lY3QgPSAoKSA9PiB7XG4gICAgICB0aGlzLnJlc2V0UmVsb2FkU3RhdHVzKCk7XG4gICAgICBpZiAodGhpcy5qb2luUm9vdFZpZXdzKCkpIHtcbiAgICAgICAgdGhpcy5iaW5kVG9wTGV2ZWxFdmVudHMoKTtcbiAgICAgICAgdGhpcy5zb2NrZXQuY29ubmVjdCgpO1xuICAgICAgfSBlbHNlIGlmICh0aGlzLm1haW4pIHtcbiAgICAgICAgdGhpcy5zb2NrZXQuY29ubmVjdCgpO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdGhpcy5iaW5kVG9wTGV2ZWxFdmVudHMoeyBkZWFkOiB0cnVlIH0pO1xuICAgICAgfVxuICAgICAgdGhpcy5qb2luRGVhZFZpZXcoKTtcbiAgICB9O1xuICAgIGlmIChcbiAgICAgIFtcImNvbXBsZXRlXCIsIFwibG9hZGVkXCIsIFwiaW50ZXJhY3RpdmVcIl0uaW5kZXhPZihkb2N1bWVudC5yZWFkeVN0YXRlKSA+PSAwXG4gICAgKSB7XG4gICAgICBkb0Nvbm5lY3QoKTtcbiAgICB9IGVsc2Uge1xuICAgICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcihcIkRPTUNvbnRlbnRMb2FkZWRcIiwgKCkgPT4gZG9Db25uZWN0KCkpO1xuICAgIH1cbiAgfVxuXG4gIGRpc2Nvbm5lY3QoY2FsbGJhY2spIHtcbiAgICBjbGVhclRpbWVvdXQodGhpcy5yZWxvYWRXaXRoSml0dGVyVGltZXIpO1xuICAgIC8vIHJlbW92ZSB0aGUgc29ja2V0IGNsb3NlIGxpc3RlbmVyIHRvIGF2b2lkIHRyeWluZyB0byBoYW5kbGVcbiAgICAvLyBhIHNlcnZlciBjbG9zZSBldmVudCB3aGVuIGl0IGlzIGFjdHVhbGx5IGNhdXNlZCBieSB1cyBkaXNjb25uZWN0aW5nXG4gICAgaWYgKHRoaXMuc2VydmVyQ2xvc2VSZWYpIHtcbiAgICAgIHRoaXMuc29ja2V0Lm9mZih0aGlzLnNlcnZlckNsb3NlUmVmKTtcbiAgICAgIHRoaXMuc2VydmVyQ2xvc2VSZWYgPSBudWxsO1xuICAgIH1cbiAgICB0aGlzLnNvY2tldC5kaXNjb25uZWN0KGNhbGxiYWNrKTtcbiAgfVxuXG4gIHJlcGxhY2VUcmFuc3BvcnQodHJhbnNwb3J0KSB7XG4gICAgY2xlYXJUaW1lb3V0KHRoaXMucmVsb2FkV2l0aEppdHRlclRpbWVyKTtcbiAgICB0aGlzLnNvY2tldC5yZXBsYWNlVHJhbnNwb3J0KHRyYW5zcG9ydCk7XG4gICAgdGhpcy5jb25uZWN0KCk7XG4gIH1cblxuICBleGVjSlMoZWwsIGVuY29kZWRKUywgZXZlbnRUeXBlID0gbnVsbCkge1xuICAgIGNvbnN0IGUgPSBuZXcgQ3VzdG9tRXZlbnQoXCJwaHg6ZXhlY1wiLCB7IGRldGFpbDogeyBzb3VyY2VFbGVtZW50OiBlbCB9IH0pO1xuICAgIHRoaXMub3duZXIoZWwsICh2aWV3KSA9PiBKUy5leGVjKGUsIGV2ZW50VHlwZSwgZW5jb2RlZEpTLCB2aWV3LCBlbCkpO1xuICB9XG5cbiAgLyoqXG4gICAqIFJldHVybnMgYW4gb2JqZWN0IHdpdGggbWV0aG9kcyB0byBtYW5pcGx1YXRlIHRoZSBET00gYW5kIGV4ZWN1dGUgSmF2YVNjcmlwdC5cbiAgICogVGhlIGFwcGxpZWQgY2hhbmdlcyBpbnRlZ3JhdGUgd2l0aCBzZXJ2ZXIgRE9NIHBhdGNoaW5nLlxuICAgKlxuICAgKiBAcmV0dXJucyB7aW1wb3J0KFwiLi9qc19jb21tYW5kc1wiKS5MaXZlU29ja2V0SlNDb21tYW5kc31cbiAgICovXG4gIGpzKCkge1xuICAgIHJldHVybiBqc0NvbW1hbmRzKHRoaXMsIFwianNcIik7XG4gIH1cblxuICAvLyBwcml2YXRlXG5cbiAgdW5sb2FkKCkge1xuICAgIGlmICh0aGlzLnVubG9hZGVkKSB7XG4gICAgICByZXR1cm47XG4gICAgfVxuICAgIGlmICh0aGlzLm1haW4gJiYgdGhpcy5pc0Nvbm5lY3RlZCgpKSB7XG4gICAgICB0aGlzLmxvZyh0aGlzLm1haW4sIFwic29ja2V0XCIsICgpID0+IFtcImRpc2Nvbm5lY3QgZm9yIHBhZ2UgbmF2XCJdKTtcbiAgICB9XG4gICAgdGhpcy51bmxvYWRlZCA9IHRydWU7XG4gICAgdGhpcy5kZXN0cm95QWxsVmlld3MoKTtcbiAgICB0aGlzLmRpc2Nvbm5lY3QoKTtcbiAgfVxuXG4gIHRyaWdnZXJET00oa2luZCwgYXJncykge1xuICAgIHRoaXMuZG9tQ2FsbGJhY2tzW2tpbmRdKC4uLmFyZ3MpO1xuICB9XG5cbiAgdGltZShuYW1lLCBmdW5jKSB7XG4gICAgaWYgKCF0aGlzLmlzUHJvZmlsZUVuYWJsZWQoKSB8fCAhY29uc29sZS50aW1lKSB7XG4gICAgICByZXR1cm4gZnVuYygpO1xuICAgIH1cbiAgICBjb25zb2xlLnRpbWUobmFtZSk7XG4gICAgY29uc3QgcmVzdWx0ID0gZnVuYygpO1xuICAgIGNvbnNvbGUudGltZUVuZChuYW1lKTtcbiAgICByZXR1cm4gcmVzdWx0O1xuICB9XG5cbiAgbG9nKHZpZXcsIGtpbmQsIG1zZ0NhbGxiYWNrKSB7XG4gICAgaWYgKHRoaXMudmlld0xvZ2dlcikge1xuICAgICAgY29uc3QgW21zZywgb2JqXSA9IG1zZ0NhbGxiYWNrKCk7XG4gICAgICB0aGlzLnZpZXdMb2dnZXIodmlldywga2luZCwgbXNnLCBvYmopO1xuICAgIH0gZWxzZSBpZiAodGhpcy5pc0RlYnVnRW5hYmxlZCgpKSB7XG4gICAgICBjb25zdCBbbXNnLCBvYmpdID0gbXNnQ2FsbGJhY2soKTtcbiAgICAgIGRlYnVnKHZpZXcsIGtpbmQsIG1zZywgb2JqKTtcbiAgICB9XG4gIH1cblxuICByZXF1ZXN0RE9NVXBkYXRlKGNhbGxiYWNrKSB7XG4gICAgdGhpcy50cmFuc2l0aW9ucy5hZnRlcihjYWxsYmFjayk7XG4gIH1cblxuICBhc3luY1RyYW5zaXRpb24ocHJvbWlzZSkge1xuICAgIHRoaXMudHJhbnNpdGlvbnMuYWRkQXN5bmNUcmFuc2l0aW9uKHByb21pc2UpO1xuICB9XG5cbiAgdHJhbnNpdGlvbih0aW1lLCBvblN0YXJ0LCBvbkRvbmUgPSBmdW5jdGlvbiAoKSB7fSkge1xuICAgIHRoaXMudHJhbnNpdGlvbnMuYWRkVHJhbnNpdGlvbih0aW1lLCBvblN0YXJ0LCBvbkRvbmUpO1xuICB9XG5cbiAgb25DaGFubmVsKGNoYW5uZWwsIGV2ZW50LCBjYikge1xuICAgIGNoYW5uZWwub24oZXZlbnQsIChkYXRhKSA9PiB7XG4gICAgICBjb25zdCBsYXRlbmN5ID0gdGhpcy5nZXRMYXRlbmN5U2ltKCk7XG4gICAgICBpZiAoIWxhdGVuY3kpIHtcbiAgICAgICAgY2IoZGF0YSk7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICBzZXRUaW1lb3V0KCgpID0+IGNiKGRhdGEpLCBsYXRlbmN5KTtcbiAgICAgIH1cbiAgICB9KTtcbiAgfVxuXG4gIHJlbG9hZFdpdGhKaXR0ZXIodmlldywgbG9nKSB7XG4gICAgY2xlYXJUaW1lb3V0KHRoaXMucmVsb2FkV2l0aEppdHRlclRpbWVyKTtcbiAgICB0aGlzLmRpc2Nvbm5lY3QoKTtcbiAgICBjb25zdCBtaW5NcyA9IHRoaXMucmVsb2FkSml0dGVyTWluO1xuICAgIGNvbnN0IG1heE1zID0gdGhpcy5yZWxvYWRKaXR0ZXJNYXg7XG4gICAgbGV0IGFmdGVyTXMgPSBNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkgKiAobWF4TXMgLSBtaW5NcyArIDEpKSArIG1pbk1zO1xuICAgIGNvbnN0IHRyaWVzID0gQnJvd3Nlci51cGRhdGVMb2NhbChcbiAgICAgIHRoaXMubG9jYWxTdG9yYWdlLFxuICAgICAgd2luZG93LmxvY2F0aW9uLnBhdGhuYW1lLFxuICAgICAgQ09OU0VDVVRJVkVfUkVMT0FEUyxcbiAgICAgIDAsXG4gICAgICAoY291bnQpID0+IGNvdW50ICsgMSxcbiAgICApO1xuICAgIGlmICh0cmllcyA+PSB0aGlzLm1heFJlbG9hZHMpIHtcbiAgICAgIGFmdGVyTXMgPSB0aGlzLmZhaWxzYWZlSml0dGVyO1xuICAgIH1cbiAgICB0aGlzLnJlbG9hZFdpdGhKaXR0ZXJUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgLy8gaWYgdmlldyBoYXMgcmVjb3ZlcmVkLCBzdWNoIGFzIHRyYW5zcG9ydCByZXBsYWNlZCwgdGhlbiBjYW5jZWxcbiAgICAgIGlmICh2aWV3LmlzRGVzdHJveWVkKCkgfHwgdmlldy5pc0Nvbm5lY3RlZCgpKSB7XG4gICAgICAgIHJldHVybjtcbiAgICAgIH1cbiAgICAgIHZpZXcuZGVzdHJveSgpO1xuICAgICAgbG9nXG4gICAgICAgID8gbG9nKClcbiAgICAgICAgOiB0aGlzLmxvZyh2aWV3LCBcImpvaW5cIiwgKCkgPT4gW1xuICAgICAgICAgICAgYGVuY291bnRlcmVkICR7dHJpZXN9IGNvbnNlY3V0aXZlIHJlbG9hZHNgLFxuICAgICAgICAgIF0pO1xuICAgICAgaWYgKHRyaWVzID49IHRoaXMubWF4UmVsb2Fkcykge1xuICAgICAgICB0aGlzLmxvZyh2aWV3LCBcImpvaW5cIiwgKCkgPT4gW1xuICAgICAgICAgIGBleGNlZWRlZCAke3RoaXMubWF4UmVsb2Fkc30gY29uc2VjdXRpdmUgcmVsb2Fkcy4gRW50ZXJpbmcgZmFpbHNhZmUgbW9kZWAsXG4gICAgICAgIF0pO1xuICAgICAgfVxuICAgICAgaWYgKHRoaXMuaGFzUGVuZGluZ0xpbmsoKSkge1xuICAgICAgICB3aW5kb3cubG9jYXRpb24gPSB0aGlzLnBlbmRpbmdMaW5rO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgd2luZG93LmxvY2F0aW9uLnJlbG9hZCgpO1xuICAgICAgfVxuICAgIH0sIGFmdGVyTXMpO1xuICB9XG5cbiAgZ2V0SG9va0RlZmluaXRpb24obmFtZSkge1xuICAgIGlmICghbmFtZSkge1xuICAgICAgcmV0dXJuO1xuICAgIH1cbiAgICByZXR1cm4gKFxuICAgICAgdGhpcy5tYXliZUludGVybmFsSG9vayhuYW1lKSB8fFxuICAgICAgdGhpcy5ob29rc1tuYW1lXSB8fFxuICAgICAgdGhpcy5tYXliZVJ1bnRpbWVIb29rKG5hbWUpXG4gICAgKTtcbiAgfVxuXG4gIG1heWJlSW50ZXJuYWxIb29rKG5hbWUpIHtcbiAgICByZXR1cm4gbmFtZSAmJiBuYW1lLnN0YXJ0c1dpdGgoXCJQaG9lbml4LlwiKSAmJiBIb29rc1tuYW1lLnNwbGl0KFwiLlwiKVsxXV07XG4gIH1cblxuICBtYXliZVJ1bnRpbWVIb29rKG5hbWUpIHtcbiAgICBjb25zdCBydW50aW1lSG9vayA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoXG4gICAgICBgc2NyaXB0WyR7UEhYX1JVTlRJTUVfSE9PS309XCIke0NTUy5lc2NhcGUobmFtZSl9XCJdYCxcbiAgICApO1xuICAgIGlmICghcnVudGltZUhvb2spIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgbGV0IGNhbGxiYWNrcyA9IHdpbmRvd1tgcGh4X2hvb2tfJHtuYW1lfWBdO1xuICAgIGlmICghY2FsbGJhY2tzIHx8IHR5cGVvZiBjYWxsYmFja3MgIT09IFwiZnVuY3Rpb25cIikge1xuICAgICAgbG9nRXJyb3IoXCJhIHJ1bnRpbWUgaG9vayBtdXN0IGJlIGEgZnVuY3Rpb25cIiwgcnVudGltZUhvb2spO1xuICAgICAgcmV0dXJuO1xuICAgIH1cbiAgICBjb25zdCBob29rRGVmaW5pdG9uID0gY2FsbGJhY2tzKCk7XG4gICAgaWYgKFxuICAgICAgaG9va0RlZmluaXRvbiAmJlxuICAgICAgKHR5cGVvZiBob29rRGVmaW5pdG9uID09PSBcIm9iamVjdFwiIHx8IHR5cGVvZiBob29rRGVmaW5pdG9uID09PSBcImZ1bmN0aW9uXCIpXG4gICAgKSB7XG4gICAgICByZXR1cm4gaG9va0RlZmluaXRvbjtcbiAgICB9XG4gICAgbG9nRXJyb3IoXG4gICAgICBcInJ1bnRpbWUgaG9vayBtdXN0IHJldHVybiBhbiBvYmplY3Qgd2l0aCBob29rIGNhbGxiYWNrcyBvciBhbiBpbnN0YW5jZSBvZiBWaWV3SG9va1wiLFxuICAgICAgcnVudGltZUhvb2ssXG4gICAgKTtcbiAgfVxuXG4gIGlzVW5sb2FkZWQoKSB7XG4gICAgcmV0dXJuIHRoaXMudW5sb2FkZWQ7XG4gIH1cblxuICBpc0Nvbm5lY3RlZCgpIHtcbiAgICByZXR1cm4gdGhpcy5zb2NrZXQuaXNDb25uZWN0ZWQoKTtcbiAgfVxuXG4gIGdldEJpbmRpbmdQcmVmaXgoKSB7XG4gICAgcmV0dXJuIHRoaXMuYmluZGluZ1ByZWZpeDtcbiAgfVxuXG4gIGJpbmRpbmcoa2luZCkge1xuICAgIHJldHVybiBgJHt0aGlzLmdldEJpbmRpbmdQcmVmaXgoKX0ke2tpbmR9YDtcbiAgfVxuXG4gIGNoYW5uZWwodG9waWMsIHBhcmFtcykge1xuICAgIHJldHVybiB0aGlzLnNvY2tldC5jaGFubmVsKHRvcGljLCBwYXJhbXMpO1xuICB9XG5cbiAgam9pbkRlYWRWaWV3KCkge1xuICAgIGNvbnN0IGJvZHkgPSBkb2N1bWVudC5ib2R5O1xuICAgIGlmIChcbiAgICAgIGJvZHkgJiZcbiAgICAgICF0aGlzLmlzUGh4Vmlldyhib2R5KSAmJlxuICAgICAgIXRoaXMuaXNQaHhWaWV3KGRvY3VtZW50LmZpcnN0RWxlbWVudENoaWxkKVxuICAgICkge1xuICAgICAgY29uc3QgdmlldyA9IHRoaXMubmV3Um9vdFZpZXcoYm9keSk7XG4gICAgICB2aWV3LnNldEhyZWYodGhpcy5nZXRIcmVmKCkpO1xuICAgICAgdmlldy5qb2luRGVhZCgpO1xuICAgICAgaWYgKCF0aGlzLm1haW4pIHtcbiAgICAgICAgdGhpcy5tYWluID0gdmlldztcbiAgICAgIH1cbiAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICB2aWV3LmV4ZWNOZXdNb3VudGVkKCk7XG4gICAgICAgIC8vIHJlc3RvcmUgc2Nyb2xsIHBvc2l0aW9uIHdoZW4gbmF2aWdhdGluZyBmcm9tIGFuIGV4dGVybmFsIC8gbm9uLWxpdmUgcGFnZVxuICAgICAgICB0aGlzLm1heWJlU2Nyb2xsKGhpc3Rvcnkuc3RhdGU/LnNjcm9sbCk7XG4gICAgICB9KTtcbiAgICB9XG4gIH1cblxuICBqb2luUm9vdFZpZXdzKCkge1xuICAgIGxldCByb290c0ZvdW5kID0gZmFsc2U7XG4gICAgRE9NLmFsbChcbiAgICAgIGRvY3VtZW50LFxuICAgICAgYCR7UEhYX1ZJRVdfU0VMRUNUT1J9Om5vdChbJHtQSFhfUEFSRU5UX0lEfV0pYCxcbiAgICAgIChyb290RWwpID0+IHtcbiAgICAgICAgaWYgKCF0aGlzLmdldFJvb3RCeUlkKHJvb3RFbC5pZCkpIHtcbiAgICAgICAgICBjb25zdCB2aWV3ID0gdGhpcy5uZXdSb290Vmlldyhyb290RWwpO1xuICAgICAgICAgIC8vIHN0aWNraWVzIGNhbm5vdCBiZSBtb3VudGVkIGF0IHRoZSByb3V0ZXIgYW5kIHRoZXJlZm9yZSBzaG91bGQgbm90XG4gICAgICAgICAgLy8gZ2V0IGEgaHJlZiBzZXQgb24gdGhlbVxuICAgICAgICAgIGlmICghRE9NLmlzUGh4U3RpY2t5KHJvb3RFbCkpIHtcbiAgICAgICAgICAgIHZpZXcuc2V0SHJlZih0aGlzLmdldEhyZWYoKSk7XG4gICAgICAgICAgfVxuICAgICAgICAgIHZpZXcuam9pbigpO1xuICAgICAgICAgIGlmIChyb290RWwuaGFzQXR0cmlidXRlKFBIWF9NQUlOKSkge1xuICAgICAgICAgICAgdGhpcy5tYWluID0gdmlldztcbiAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICAgICAgcm9vdHNGb3VuZCA9IHRydWU7XG4gICAgICB9LFxuICAgICk7XG4gICAgcmV0dXJuIHJvb3RzRm91bmQ7XG4gIH1cblxuICByZWRpcmVjdCh0bywgZmxhc2gsIHJlbG9hZFRva2VuKSB7XG4gICAgaWYgKHJlbG9hZFRva2VuKSB7XG4gICAgICBCcm93c2VyLnNldENvb2tpZShQSFhfUkVMT0FEX1NUQVRVUywgcmVsb2FkVG9rZW4sIDYwKTtcbiAgICB9XG4gICAgdGhpcy51bmxvYWQoKTtcbiAgICBCcm93c2VyLnJlZGlyZWN0KHRvLCBmbGFzaCk7XG4gIH1cblxuICByZXBsYWNlTWFpbihcbiAgICBocmVmLFxuICAgIGZsYXNoLFxuICAgIGNhbGxiYWNrID0gbnVsbCxcbiAgICBsaW5rUmVmID0gdGhpcy5zZXRQZW5kaW5nTGluayhocmVmKSxcbiAgKSB7XG4gICAgY29uc3QgbGl2ZVJlZmVyZXIgPSB0aGlzLmN1cnJlbnRMb2NhdGlvbi5ocmVmO1xuICAgIHRoaXMub3V0Z29pbmdNYWluRWwgPSB0aGlzLm91dGdvaW5nTWFpbkVsIHx8IHRoaXMubWFpbi5lbDtcblxuICAgIGNvbnN0IHN0aWNraWVzID0gRE9NLmZpbmRQaHhTdGlja3koZG9jdW1lbnQpIHx8IFtdO1xuICAgIGNvbnN0IHJlbW92ZUVscyA9IERPTS5hbGwoXG4gICAgICB0aGlzLm91dGdvaW5nTWFpbkVsLFxuICAgICAgYFske3RoaXMuYmluZGluZyhcInJlbW92ZVwiKX1dYCxcbiAgICApLmZpbHRlcigoZWwpID0+ICFET00uaXNDaGlsZE9mQW55KGVsLCBzdGlja2llcykpO1xuXG4gICAgY29uc3QgbmV3TWFpbkVsID0gRE9NLmNsb25lTm9kZSh0aGlzLm91dGdvaW5nTWFpbkVsLCBcIlwiKTtcbiAgICB0aGlzLm1haW4uc2hvd0xvYWRlcih0aGlzLmxvYWRlclRpbWVvdXQpO1xuICAgIHRoaXMubWFpbi5kZXN0cm95KCk7XG5cbiAgICB0aGlzLm1haW4gPSB0aGlzLm5ld1Jvb3RWaWV3KG5ld01haW5FbCwgZmxhc2gsIGxpdmVSZWZlcmVyKTtcbiAgICB0aGlzLm1haW4uc2V0UmVkaXJlY3QoaHJlZik7XG4gICAgdGhpcy50cmFuc2l0aW9uUmVtb3ZlcyhyZW1vdmVFbHMpO1xuICAgIHRoaXMubWFpbi5qb2luKChqb2luQ291bnQsIG9uRG9uZSkgPT4ge1xuICAgICAgaWYgKGpvaW5Db3VudCA9PT0gMSAmJiB0aGlzLmNvbW1pdFBlbmRpbmdMaW5rKGxpbmtSZWYpKSB7XG4gICAgICAgIHRoaXMucmVxdWVzdERPTVVwZGF0ZSgoKSA9PiB7XG4gICAgICAgICAgLy8gcmVtb3ZlIHBoeC1yZW1vdmUgZWxzIHJpZ2h0IGJlZm9yZSB3ZSByZXBsYWNlIHRoZSBtYWluIGVsZW1lbnRcbiAgICAgICAgICByZW1vdmVFbHMuZm9yRWFjaCgoZWwpID0+IGVsLnJlbW92ZSgpKTtcbiAgICAgICAgICBzdGlja2llcy5mb3JFYWNoKChlbCkgPT4gbmV3TWFpbkVsLmFwcGVuZENoaWxkKGVsKSk7XG4gICAgICAgICAgdGhpcy5vdXRnb2luZ01haW5FbC5yZXBsYWNlV2l0aChuZXdNYWluRWwpO1xuICAgICAgICAgIHRoaXMub3V0Z29pbmdNYWluRWwgPSBudWxsO1xuICAgICAgICAgIGNhbGxiYWNrICYmIGNhbGxiYWNrKGxpbmtSZWYpO1xuICAgICAgICAgIG9uRG9uZSgpO1xuICAgICAgICB9KTtcbiAgICAgIH1cbiAgICB9KTtcbiAgfVxuXG4gIHRyYW5zaXRpb25SZW1vdmVzKGVsZW1lbnRzLCBjYWxsYmFjaykge1xuICAgIGNvbnN0IHJlbW92ZUF0dHIgPSB0aGlzLmJpbmRpbmcoXCJyZW1vdmVcIik7XG4gICAgY29uc3Qgc2lsZW5jZUV2ZW50cyA9IChlKSA9PiB7XG4gICAgICBlLnByZXZlbnREZWZhdWx0KCk7XG4gICAgICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpO1xuICAgIH07XG4gICAgZWxlbWVudHMuZm9yRWFjaCgoZWwpID0+IHtcbiAgICAgIC8vIHByZXZlbnQgYWxsIGxpc3RlbmVycyB3ZSBjYXJlIGFib3V0IGZyb20gYnViYmxpbmcgdG8gd2luZG93XG4gICAgICAvLyBzaW5jZSB3ZSBhcmUgcmVtb3ZpbmcgdGhlIGVsZW1lbnRcbiAgICAgIGZvciAoY29uc3QgZXZlbnQgb2YgdGhpcy5ib3VuZEV2ZW50TmFtZXMpIHtcbiAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcihldmVudCwgc2lsZW5jZUV2ZW50cywgdHJ1ZSk7XG4gICAgICB9XG4gICAgICB0aGlzLmV4ZWNKUyhlbCwgZWwuZ2V0QXR0cmlidXRlKHJlbW92ZUF0dHIpLCBcInJlbW92ZVwiKTtcbiAgICB9KTtcbiAgICAvLyByZW1vdmUgdGhlIHNpbGVuY2VkIGxpc3RlbmVycyB3aGVuIHRyYW5zaXRpb25zIGFyZSBkb25lIGluY2FzZSB0aGUgZWxlbWVudCBpcyByZS11c2VkXG4gICAgLy8gYW5kIGNhbGwgY2FsbGVyJ3MgY2FsbGJhY2sgYXMgc29vbiBhcyB3ZSBhcmUgZG9uZSB3aXRoIHRyYW5zaXRpb25zXG4gICAgdGhpcy5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgIGVsZW1lbnRzLmZvckVhY2goKGVsKSA9PiB7XG4gICAgICAgIGZvciAoY29uc3QgZXZlbnQgb2YgdGhpcy5ib3VuZEV2ZW50TmFtZXMpIHtcbiAgICAgICAgICBlbC5yZW1vdmVFdmVudExpc3RlbmVyKGV2ZW50LCBzaWxlbmNlRXZlbnRzLCB0cnVlKTtcbiAgICAgICAgfVxuICAgICAgfSk7XG4gICAgICBjYWxsYmFjayAmJiBjYWxsYmFjaygpO1xuICAgIH0pO1xuICB9XG5cbiAgaXNQaHhWaWV3KGVsKSB7XG4gICAgcmV0dXJuIGVsLmdldEF0dHJpYnV0ZSAmJiBlbC5nZXRBdHRyaWJ1dGUoUEhYX1NFU1NJT04pICE9PSBudWxsO1xuICB9XG5cbiAgbmV3Um9vdFZpZXcoZWwsIGZsYXNoLCBsaXZlUmVmZXJlcikge1xuICAgIGNvbnN0IHZpZXcgPSBuZXcgVmlldyhlbCwgdGhpcywgbnVsbCwgZmxhc2gsIGxpdmVSZWZlcmVyKTtcbiAgICB0aGlzLnJvb3RzW3ZpZXcuaWRdID0gdmlldztcbiAgICByZXR1cm4gdmlldztcbiAgfVxuXG4gIG93bmVyKGNoaWxkRWwsIGNhbGxiYWNrKSB7XG4gICAgbGV0IHZpZXc7XG4gICAgY29uc3Qgdmlld0VsID0gRE9NLmNsb3Nlc3RWaWV3RWwoY2hpbGRFbCk7XG4gICAgaWYgKHZpZXdFbCkge1xuICAgICAgLy8gaXQgY2FuIGhhcHBlbiB0aGF0IHdlIGZpbmQgYSB2aWV3IHRoYXQgaXMgYWxyZWFkeSBkZXN0cm95ZWQ7XG4gICAgICAvLyBpbiB0aGF0IGNhc2Ugd2UgRE8gTk9UIHdhbnQgdG8gZmFsbGJhY2sgdG8gdGhlIG1haW4gZWxlbWVudFxuICAgICAgdmlldyA9IHRoaXMuZ2V0Vmlld0J5RWwodmlld0VsKTtcbiAgICB9IGVsc2Uge1xuICAgICAgdmlldyA9IHRoaXMubWFpbjtcbiAgICB9XG4gICAgcmV0dXJuIHZpZXcgJiYgY2FsbGJhY2sgPyBjYWxsYmFjayh2aWV3KSA6IHZpZXc7XG4gIH1cblxuICB3aXRoaW5Pd25lcnMoY2hpbGRFbCwgY2FsbGJhY2spIHtcbiAgICB0aGlzLm93bmVyKGNoaWxkRWwsICh2aWV3KSA9PiBjYWxsYmFjayh2aWV3LCBjaGlsZEVsKSk7XG4gIH1cblxuICBnZXRWaWV3QnlFbChlbCkge1xuICAgIGNvbnN0IHJvb3RJZCA9IGVsLmdldEF0dHJpYnV0ZShQSFhfUk9PVF9JRCk7XG4gICAgcmV0dXJuIG1heWJlKHRoaXMuZ2V0Um9vdEJ5SWQocm9vdElkKSwgKHJvb3QpID0+XG4gICAgICByb290LmdldERlc2NlbmRlbnRCeUVsKGVsKSxcbiAgICApO1xuICB9XG5cbiAgZ2V0Um9vdEJ5SWQoaWQpIHtcbiAgICByZXR1cm4gdGhpcy5yb290c1tpZF07XG4gIH1cblxuICBkZXN0cm95QWxsVmlld3MoKSB7XG4gICAgZm9yIChjb25zdCBpZCBpbiB0aGlzLnJvb3RzKSB7XG4gICAgICB0aGlzLnJvb3RzW2lkXS5kZXN0cm95KCk7XG4gICAgICBkZWxldGUgdGhpcy5yb290c1tpZF07XG4gICAgfVxuICAgIHRoaXMubWFpbiA9IG51bGw7XG4gIH1cblxuICBkZXN0cm95Vmlld0J5RWwoZWwpIHtcbiAgICBjb25zdCByb290ID0gdGhpcy5nZXRSb290QnlJZChlbC5nZXRBdHRyaWJ1dGUoUEhYX1JPT1RfSUQpKTtcbiAgICBpZiAocm9vdCAmJiByb290LmlkID09PSBlbC5pZCkge1xuICAgICAgcm9vdC5kZXN0cm95KCk7XG4gICAgICBkZWxldGUgdGhpcy5yb290c1tyb290LmlkXTtcbiAgICB9IGVsc2UgaWYgKHJvb3QpIHtcbiAgICAgIHJvb3QuZGVzdHJveURlc2NlbmRlbnQoZWwuaWQpO1xuICAgIH1cbiAgfVxuXG4gIGdldEFjdGl2ZUVsZW1lbnQoKSB7XG4gICAgcmV0dXJuIGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ7XG4gIH1cblxuICBkcm9wQWN0aXZlRWxlbWVudCh2aWV3KSB7XG4gICAgaWYgKHRoaXMucHJldkFjdGl2ZSAmJiB2aWV3Lm93bnNFbGVtZW50KHRoaXMucHJldkFjdGl2ZSkpIHtcbiAgICAgIHRoaXMucHJldkFjdGl2ZSA9IG51bGw7XG4gICAgfVxuICB9XG5cbiAgcmVzdG9yZVByZXZpb3VzbHlBY3RpdmVGb2N1cygpIHtcbiAgICBpZiAoXG4gICAgICB0aGlzLnByZXZBY3RpdmUgJiZcbiAgICAgIHRoaXMucHJldkFjdGl2ZSAhPT0gZG9jdW1lbnQuYm9keSAmJlxuICAgICAgdGhpcy5wcmV2QWN0aXZlIGluc3RhbmNlb2YgSFRNTEVsZW1lbnRcbiAgICApIHtcbiAgICAgIHRoaXMucHJldkFjdGl2ZS5mb2N1cygpO1xuICAgIH1cbiAgfVxuXG4gIGJsdXJBY3RpdmVFbGVtZW50KCkge1xuICAgIHRoaXMucHJldkFjdGl2ZSA9IHRoaXMuZ2V0QWN0aXZlRWxlbWVudCgpO1xuICAgIGlmIChcbiAgICAgIHRoaXMucHJldkFjdGl2ZSAhPT0gZG9jdW1lbnQuYm9keSAmJlxuICAgICAgdGhpcy5wcmV2QWN0aXZlIGluc3RhbmNlb2YgSFRNTEVsZW1lbnRcbiAgICApIHtcbiAgICAgIHRoaXMucHJldkFjdGl2ZS5ibHVyKCk7XG4gICAgfVxuICB9XG5cbiAgLyoqXG4gICAqIEBwYXJhbSB7e2RlYWQ/OiBib29sZWFufX0gW29wdGlvbnM9e31dXG4gICAqL1xuICBiaW5kVG9wTGV2ZWxFdmVudHMoeyBkZWFkIH0gPSB7fSkge1xuICAgIGlmICh0aGlzLmJvdW5kVG9wTGV2ZWxFdmVudHMpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG5cbiAgICB0aGlzLmJvdW5kVG9wTGV2ZWxFdmVudHMgPSB0cnVlO1xuICAgIC8vIGVudGVyIGZhaWxzYWZlIHJlbG9hZCBpZiBzZXJ2ZXIgaGFzIGdvbmUgYXdheSBpbnRlbnRpb25hbGx5LCBzdWNoIGFzIFwiZGlzY29ubmVjdFwiIGJyb2FkY2FzdFxuICAgIHRoaXMuc2VydmVyQ2xvc2VSZWYgPSB0aGlzLnNvY2tldC5vbkNsb3NlKChldmVudCkgPT4ge1xuICAgICAgLy8gZmFpbHNhZmUgcmVsb2FkIGlmIG5vcm1hbCBjbG9zdXJlIGFuZCB3ZSBzdGlsbCBoYXZlIGEgbWFpbiBMVlxuICAgICAgaWYgKGV2ZW50ICYmIGV2ZW50LmNvZGUgPT09IDEwMDAgJiYgdGhpcy5tYWluKSB7XG4gICAgICAgIHJldHVybiB0aGlzLnJlbG9hZFdpdGhKaXR0ZXIodGhpcy5tYWluKTtcbiAgICAgIH1cbiAgICB9KTtcbiAgICBkb2N1bWVudC5ib2R5LmFkZEV2ZW50TGlzdGVuZXIoXCJjbGlja1wiLCBmdW5jdGlvbiAoKSB7fSk7IC8vIGVuc3VyZSBhbGwgY2xpY2sgZXZlbnRzIGJ1YmJsZSBmb3IgbW9iaWxlIFNhZmFyaVxuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFxuICAgICAgXCJwYWdlc2hvd1wiLFxuICAgICAgKGUpID0+IHtcbiAgICAgICAgaWYgKGUucGVyc2lzdGVkKSB7XG4gICAgICAgICAgLy8gcmVsb2FkIHBhZ2UgaWYgYmVpbmcgcmVzdG9yZWQgZnJvbSBiYWNrL2ZvcndhcmQgY2FjaGVcbiAgICAgICAgICB0aGlzLmdldFNvY2tldCgpLmRpc2Nvbm5lY3QoKTtcbiAgICAgICAgICB0aGlzLndpdGhQYWdlTG9hZGluZyh7IHRvOiB3aW5kb3cubG9jYXRpb24uaHJlZiwga2luZDogXCJyZWRpcmVjdFwiIH0pO1xuICAgICAgICAgIHdpbmRvdy5sb2NhdGlvbi5yZWxvYWQoKTtcbiAgICAgICAgfVxuICAgICAgfSxcbiAgICAgIHRydWUsXG4gICAgKTtcbiAgICBpZiAoIWRlYWQpIHtcbiAgICAgIHRoaXMuYmluZE5hdigpO1xuICAgIH1cbiAgICB0aGlzLmJpbmRDbGlja3MoKTtcbiAgICBpZiAoIWRlYWQpIHtcbiAgICAgIHRoaXMuYmluZEZvcm1zKCk7XG4gICAgfVxuICAgIHRoaXMuYmluZChcbiAgICAgIHsga2V5dXA6IFwia2V5dXBcIiwga2V5ZG93bjogXCJrZXlkb3duXCIgfSxcbiAgICAgIChlLCB0eXBlLCB2aWV3LCB0YXJnZXRFbCwgcGh4RXZlbnQsIF9waHhUYXJnZXQpID0+IHtcbiAgICAgICAgY29uc3QgbWF0Y2hLZXkgPSB0YXJnZXRFbC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9LRVkpKTtcbiAgICAgICAgY29uc3QgcHJlc3NlZEtleSA9IGUua2V5ICYmIGUua2V5LnRvTG93ZXJDYXNlKCk7IC8vIGNocm9tZSBjbGlja2VkIGF1dG9jb21wbGV0ZXMgc2VuZCBhIGtleWRvd24gd2l0aG91dCBrZXlcbiAgICAgICAgaWYgKG1hdGNoS2V5ICYmIG1hdGNoS2V5LnRvTG93ZXJDYXNlKCkgIT09IHByZXNzZWRLZXkpIHtcbiAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICBjb25zdCBkYXRhID0geyBrZXk6IGUua2V5LCAuLi50aGlzLmV2ZW50TWV0YSh0eXBlLCBlLCB0YXJnZXRFbCkgfTtcbiAgICAgICAgSlMuZXhlYyhlLCB0eXBlLCBwaHhFdmVudCwgdmlldywgdGFyZ2V0RWwsIFtcInB1c2hcIiwgeyBkYXRhIH1dKTtcbiAgICAgIH0sXG4gICAgKTtcbiAgICB0aGlzLmJpbmQoXG4gICAgICB7IGJsdXI6IFwiZm9jdXNvdXRcIiwgZm9jdXM6IFwiZm9jdXNpblwiIH0sXG4gICAgICAoZSwgdHlwZSwgdmlldywgdGFyZ2V0RWwsIHBoeEV2ZW50LCBwaHhUYXJnZXQpID0+IHtcbiAgICAgICAgaWYgKCFwaHhUYXJnZXQpIHtcbiAgICAgICAgICBjb25zdCBkYXRhID0geyBrZXk6IGUua2V5LCAuLi50aGlzLmV2ZW50TWV0YSh0eXBlLCBlLCB0YXJnZXRFbCkgfTtcbiAgICAgICAgICBKUy5leGVjKGUsIHR5cGUsIHBoeEV2ZW50LCB2aWV3LCB0YXJnZXRFbCwgW1wicHVzaFwiLCB7IGRhdGEgfV0pO1xuICAgICAgICB9XG4gICAgICB9LFxuICAgICk7XG4gICAgdGhpcy5iaW5kKFxuICAgICAgeyBibHVyOiBcImJsdXJcIiwgZm9jdXM6IFwiZm9jdXNcIiB9LFxuICAgICAgKGUsIHR5cGUsIHZpZXcsIHRhcmdldEVsLCBwaHhFdmVudCwgcGh4VGFyZ2V0KSA9PiB7XG4gICAgICAgIC8vIGJsdXIgYW5kIGZvY3VzIGFyZSB0cmlnZ2VyZWQgb24gZG9jdW1lbnQgYW5kIHdpbmRvdy4gRGlzY2FyZCBvbmUgdG8gYXZvaWQgZHVwc1xuICAgICAgICBpZiAocGh4VGFyZ2V0ID09PSBcIndpbmRvd1wiKSB7XG4gICAgICAgICAgY29uc3QgZGF0YSA9IHRoaXMuZXZlbnRNZXRhKHR5cGUsIGUsIHRhcmdldEVsKTtcbiAgICAgICAgICBKUy5leGVjKGUsIHR5cGUsIHBoeEV2ZW50LCB2aWV3LCB0YXJnZXRFbCwgW1wicHVzaFwiLCB7IGRhdGEgfV0pO1xuICAgICAgICB9XG4gICAgICB9LFxuICAgICk7XG4gICAgdGhpcy5vbihcImRyYWdvdmVyXCIsIChlKSA9PiBlLnByZXZlbnREZWZhdWx0KCkpO1xuICAgIHRoaXMub24oXCJkcm9wXCIsIChlKSA9PiB7XG4gICAgICBlLnByZXZlbnREZWZhdWx0KCk7XG4gICAgICBjb25zdCBkcm9wVGFyZ2V0SWQgPSBtYXliZShcbiAgICAgICAgY2xvc2VzdFBoeEJpbmRpbmcoZS50YXJnZXQsIHRoaXMuYmluZGluZyhQSFhfRFJPUF9UQVJHRVQpKSxcbiAgICAgICAgKHRydWVUYXJnZXQpID0+IHtcbiAgICAgICAgICByZXR1cm4gdHJ1ZVRhcmdldC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9EUk9QX1RBUkdFVCkpO1xuICAgICAgICB9LFxuICAgICAgKTtcbiAgICAgIGNvbnN0IGRyb3BUYXJnZXQgPSBkcm9wVGFyZ2V0SWQgJiYgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoZHJvcFRhcmdldElkKTtcbiAgICAgIGNvbnN0IGZpbGVzID0gQXJyYXkuZnJvbShlLmRhdGFUcmFuc2Zlci5maWxlcyB8fCBbXSk7XG4gICAgICBpZiAoXG4gICAgICAgICFkcm9wVGFyZ2V0IHx8XG4gICAgICAgICEoZHJvcFRhcmdldCBpbnN0YW5jZW9mIEhUTUxJbnB1dEVsZW1lbnQpIHx8XG4gICAgICAgIGRyb3BUYXJnZXQuZGlzYWJsZWQgfHxcbiAgICAgICAgZmlsZXMubGVuZ3RoID09PSAwIHx8XG4gICAgICAgICEoZHJvcFRhcmdldC5maWxlcyBpbnN0YW5jZW9mIEZpbGVMaXN0KVxuICAgICAgKSB7XG4gICAgICAgIHJldHVybjtcbiAgICAgIH1cblxuICAgICAgTGl2ZVVwbG9hZGVyLnRyYWNrRmlsZXMoZHJvcFRhcmdldCwgZmlsZXMsIGUuZGF0YVRyYW5zZmVyKTtcbiAgICAgIGRyb3BUYXJnZXQuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoXCJpbnB1dFwiLCB7IGJ1YmJsZXM6IHRydWUgfSkpO1xuICAgIH0pO1xuICAgIHRoaXMub24oUEhYX1RSQUNLX1VQTE9BRFMsIChlKSA9PiB7XG4gICAgICBjb25zdCB1cGxvYWRUYXJnZXQgPSBlLnRhcmdldDtcbiAgICAgIGlmICghRE9NLmlzVXBsb2FkSW5wdXQodXBsb2FkVGFyZ2V0KSkge1xuICAgICAgICByZXR1cm47XG4gICAgICB9XG4gICAgICBjb25zdCBmaWxlcyA9IEFycmF5LmZyb20oZS5kZXRhaWwuZmlsZXMgfHwgW10pLmZpbHRlcihcbiAgICAgICAgKGYpID0+IGYgaW5zdGFuY2VvZiBGaWxlIHx8IGYgaW5zdGFuY2VvZiBCbG9iLFxuICAgICAgKTtcbiAgICAgIExpdmVVcGxvYWRlci50cmFja0ZpbGVzKHVwbG9hZFRhcmdldCwgZmlsZXMpO1xuICAgICAgdXBsb2FkVGFyZ2V0LmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwiaW5wdXRcIiwgeyBidWJibGVzOiB0cnVlIH0pKTtcbiAgICB9KTtcbiAgfVxuXG4gIGV2ZW50TWV0YShldmVudE5hbWUsIGUsIHRhcmdldEVsKSB7XG4gICAgY29uc3QgY2FsbGJhY2sgPSB0aGlzLm1ldGFkYXRhQ2FsbGJhY2tzW2V2ZW50TmFtZV07XG4gICAgcmV0dXJuIGNhbGxiYWNrID8gY2FsbGJhY2soZSwgdGFyZ2V0RWwpIDoge307XG4gIH1cblxuICBzZXRQZW5kaW5nTGluayhocmVmKSB7XG4gICAgdGhpcy5saW5rUmVmKys7XG4gICAgdGhpcy5wZW5kaW5nTGluayA9IGhyZWY7XG4gICAgdGhpcy5yZXNldFJlbG9hZFN0YXR1cygpO1xuICAgIHJldHVybiB0aGlzLmxpbmtSZWY7XG4gIH1cblxuICAvLyBhbnl0aW1lIHdlIGFyZSBuYXZpZ2F0aW5nIG9yIGNvbm5lY3RpbmcsIGRyb3AgcmVsb2FkIGNvb2tpZSBpbiBjYXNlXG4gIC8vIHdlIGlzc3VlIHRoZSBjb29raWUgYnV0IHRoZSBuZXh0IHJlcXVlc3Qgd2FzIGludGVycnVwdGVkIGFuZCB0aGUgc2VydmVyIG5ldmVyIGRyb3BwZWQgaXRcbiAgcmVzZXRSZWxvYWRTdGF0dXMoKSB7XG4gICAgQnJvd3Nlci5kZWxldGVDb29raWUoUEhYX1JFTE9BRF9TVEFUVVMpO1xuICB9XG5cbiAgY29tbWl0UGVuZGluZ0xpbmsobGlua1JlZikge1xuICAgIGlmICh0aGlzLmxpbmtSZWYgIT09IGxpbmtSZWYpIHtcbiAgICAgIHJldHVybiBmYWxzZTtcbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy5ocmVmID0gdGhpcy5wZW5kaW5nTGluaztcbiAgICAgIHRoaXMucGVuZGluZ0xpbmsgPSBudWxsO1xuICAgICAgcmV0dXJuIHRydWU7XG4gICAgfVxuICB9XG5cbiAgZ2V0SHJlZigpIHtcbiAgICByZXR1cm4gdGhpcy5ocmVmO1xuICB9XG5cbiAgaGFzUGVuZGluZ0xpbmsoKSB7XG4gICAgcmV0dXJuICEhdGhpcy5wZW5kaW5nTGluaztcbiAgfVxuXG4gIGJpbmQoZXZlbnRzLCBjYWxsYmFjaykge1xuICAgIGZvciAoY29uc3QgZXZlbnQgaW4gZXZlbnRzKSB7XG4gICAgICBjb25zdCBicm93c2VyRXZlbnROYW1lID0gZXZlbnRzW2V2ZW50XTtcblxuICAgICAgdGhpcy5vbihicm93c2VyRXZlbnROYW1lLCAoZSkgPT4ge1xuICAgICAgICBjb25zdCBiaW5kaW5nID0gdGhpcy5iaW5kaW5nKGV2ZW50KTtcbiAgICAgICAgY29uc3Qgd2luZG93QmluZGluZyA9IHRoaXMuYmluZGluZyhgd2luZG93LSR7ZXZlbnR9YCk7XG4gICAgICAgIGNvbnN0IHRhcmdldFBoeEV2ZW50ID1cbiAgICAgICAgICBlLnRhcmdldC5nZXRBdHRyaWJ1dGUgJiYgZS50YXJnZXQuZ2V0QXR0cmlidXRlKGJpbmRpbmcpO1xuICAgICAgICBpZiAodGFyZ2V0UGh4RXZlbnQpIHtcbiAgICAgICAgICB0aGlzLmRlYm91bmNlKGUudGFyZ2V0LCBlLCBicm93c2VyRXZlbnROYW1lLCAoKSA9PiB7XG4gICAgICAgICAgICB0aGlzLndpdGhpbk93bmVycyhlLnRhcmdldCwgKHZpZXcpID0+IHtcbiAgICAgICAgICAgICAgY2FsbGJhY2soZSwgZXZlbnQsIHZpZXcsIGUudGFyZ2V0LCB0YXJnZXRQaHhFdmVudCwgbnVsbCk7XG4gICAgICAgICAgICB9KTtcbiAgICAgICAgICB9KTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICBET00uYWxsKGRvY3VtZW50LCBgWyR7d2luZG93QmluZGluZ31dYCwgKGVsKSA9PiB7XG4gICAgICAgICAgICBjb25zdCBwaHhFdmVudCA9IGVsLmdldEF0dHJpYnV0ZSh3aW5kb3dCaW5kaW5nKTtcbiAgICAgICAgICAgIHRoaXMuZGVib3VuY2UoZWwsIGUsIGJyb3dzZXJFdmVudE5hbWUsICgpID0+IHtcbiAgICAgICAgICAgICAgdGhpcy53aXRoaW5Pd25lcnMoZWwsICh2aWV3KSA9PiB7XG4gICAgICAgICAgICAgICAgY2FsbGJhY2soZSwgZXZlbnQsIHZpZXcsIGVsLCBwaHhFdmVudCwgXCJ3aW5kb3dcIik7XG4gICAgICAgICAgICAgIH0pO1xuICAgICAgICAgICAgfSk7XG4gICAgICAgICAgfSk7XG4gICAgICAgIH1cbiAgICAgIH0pO1xuICAgIH1cbiAgfVxuXG4gIGJpbmRDbGlja3MoKSB7XG4gICAgdGhpcy5vbihcIm1vdXNlZG93blwiLCAoZSkgPT4gKHRoaXMuY2xpY2tTdGFydGVkQXRUYXJnZXQgPSBlLnRhcmdldCkpO1xuICAgIHRoaXMuYmluZENsaWNrKFwiY2xpY2tcIiwgXCJjbGlja1wiKTtcbiAgfVxuXG4gIGJpbmRDbGljayhldmVudE5hbWUsIGJpbmRpbmdOYW1lKSB7XG4gICAgY29uc3QgY2xpY2sgPSB0aGlzLmJpbmRpbmcoYmluZGluZ05hbWUpO1xuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFxuICAgICAgZXZlbnROYW1lLFxuICAgICAgKGUpID0+IHtcbiAgICAgICAgbGV0IHRhcmdldCA9IG51bGw7XG4gICAgICAgIC8vIGEgc3ludGhldGljIGNsaWNrIGV2ZW50IChkZXRhaWwgMCkgd2lsbCBub3QgaGF2ZSBjYXVzZWQgYSBtb3VzZWRvd24gZXZlbnQsXG4gICAgICAgIC8vIHRoZXJlZm9yZSB0aGUgY2xpY2tTdGFydGVkQXRUYXJnZXQgaXMgc3RhbGVcbiAgICAgICAgaWYgKGUuZGV0YWlsID09PSAwKSB0aGlzLmNsaWNrU3RhcnRlZEF0VGFyZ2V0ID0gZS50YXJnZXQ7XG4gICAgICAgIGNvbnN0IGNsaWNrU3RhcnRlZEF0VGFyZ2V0ID0gdGhpcy5jbGlja1N0YXJ0ZWRBdFRhcmdldCB8fCBlLnRhcmdldDtcbiAgICAgICAgLy8gd2hlbiBzZWFyY2hpbmcgdGhlIHRhcmdldCBmb3IgdGhlIGNsaWNrIGV2ZW50LCB3ZSBhbHdheXMgd2FudCB0b1xuICAgICAgICAvLyB1c2UgdGhlIGFjdHVhbCBldmVudCB0YXJnZXQsIHNlZSAjMzM3MlxuICAgICAgICB0YXJnZXQgPSBjbG9zZXN0UGh4QmluZGluZyhlLnRhcmdldCwgY2xpY2spO1xuICAgICAgICB0aGlzLmRpc3BhdGNoQ2xpY2tBd2F5KGUsIGNsaWNrU3RhcnRlZEF0VGFyZ2V0KTtcbiAgICAgICAgdGhpcy5jbGlja1N0YXJ0ZWRBdFRhcmdldCA9IG51bGw7XG4gICAgICAgIGNvbnN0IHBoeEV2ZW50ID0gdGFyZ2V0ICYmIHRhcmdldC5nZXRBdHRyaWJ1dGUoY2xpY2spO1xuICAgICAgICBpZiAoIXBoeEV2ZW50KSB7XG4gICAgICAgICAgaWYgKERPTS5pc05ld1BhZ2VDbGljayhlLCB3aW5kb3cubG9jYXRpb24pKSB7XG4gICAgICAgICAgICB0aGlzLnVubG9hZCgpO1xuICAgICAgICAgIH1cbiAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICBpZiAodGFyZ2V0LmdldEF0dHJpYnV0ZShcImhyZWZcIikgPT09IFwiI1wiKSB7XG4gICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpO1xuICAgICAgICB9XG5cbiAgICAgICAgLy8gbm9vcCBpZiB3ZSBhcmUgaW4gdGhlIG1pZGRsZSBvZiBhd2FpdGluZyBhbiBhY2sgZm9yIHRoaXMgZWwgYWxyZWFkeVxuICAgICAgICBpZiAodGFyZ2V0Lmhhc0F0dHJpYnV0ZShQSFhfUkVGX1NSQykpIHtcbiAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICB0aGlzLmRlYm91bmNlKHRhcmdldCwgZSwgXCJjbGlja1wiLCAoKSA9PiB7XG4gICAgICAgICAgdGhpcy53aXRoaW5Pd25lcnModGFyZ2V0LCAodmlldykgPT4ge1xuICAgICAgICAgICAgSlMuZXhlYyhlLCBcImNsaWNrXCIsIHBoeEV2ZW50LCB2aWV3LCB0YXJnZXQsIFtcbiAgICAgICAgICAgICAgXCJwdXNoXCIsXG4gICAgICAgICAgICAgIHsgZGF0YTogdGhpcy5ldmVudE1ldGEoXCJjbGlja1wiLCBlLCB0YXJnZXQpIH0sXG4gICAgICAgICAgICBdKTtcbiAgICAgICAgICB9KTtcbiAgICAgICAgfSk7XG4gICAgICB9LFxuICAgICAgZmFsc2UsXG4gICAgKTtcbiAgfVxuXG4gIGRpc3BhdGNoQ2xpY2tBd2F5KGUsIGNsaWNrU3RhcnRlZEF0KSB7XG4gICAgY29uc3QgcGh4Q2xpY2tBd2F5ID0gdGhpcy5iaW5kaW5nKFwiY2xpY2stYXdheVwiKTtcbiAgICBET00uYWxsKGRvY3VtZW50LCBgWyR7cGh4Q2xpY2tBd2F5fV1gLCAoZWwpID0+IHtcbiAgICAgIGlmICghKGVsLmlzU2FtZU5vZGUoY2xpY2tTdGFydGVkQXQpIHx8IGVsLmNvbnRhaW5zKGNsaWNrU3RhcnRlZEF0KSkpIHtcbiAgICAgICAgdGhpcy53aXRoaW5Pd25lcnMoZWwsICh2aWV3KSA9PiB7XG4gICAgICAgICAgY29uc3QgcGh4RXZlbnQgPSBlbC5nZXRBdHRyaWJ1dGUocGh4Q2xpY2tBd2F5KTtcbiAgICAgICAgICBpZiAoSlMuaXNWaXNpYmxlKGVsKSAmJiBKUy5pc0luVmlld3BvcnQoZWwpKSB7XG4gICAgICAgICAgICBKUy5leGVjKGUsIFwiY2xpY2tcIiwgcGh4RXZlbnQsIHZpZXcsIGVsLCBbXG4gICAgICAgICAgICAgIFwicHVzaFwiLFxuICAgICAgICAgICAgICB7IGRhdGE6IHRoaXMuZXZlbnRNZXRhKFwiY2xpY2tcIiwgZSwgZS50YXJnZXQpIH0sXG4gICAgICAgICAgICBdKTtcbiAgICAgICAgICB9XG4gICAgICAgIH0pO1xuICAgICAgfVxuICAgIH0pO1xuICB9XG5cbiAgYmluZE5hdigpIHtcbiAgICBpZiAoIUJyb3dzZXIuY2FuUHVzaFN0YXRlKCkpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgaWYgKGhpc3Rvcnkuc2Nyb2xsUmVzdG9yYXRpb24pIHtcbiAgICAgIGhpc3Rvcnkuc2Nyb2xsUmVzdG9yYXRpb24gPSBcIm1hbnVhbFwiO1xuICAgIH1cbiAgICBsZXQgc2Nyb2xsVGltZXIgPSBudWxsO1xuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwic2Nyb2xsXCIsIChfZSkgPT4ge1xuICAgICAgY2xlYXJUaW1lb3V0KHNjcm9sbFRpbWVyKTtcbiAgICAgIHNjcm9sbFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7XG4gICAgICAgIEJyb3dzZXIudXBkYXRlQ3VycmVudFN0YXRlKChzdGF0ZSkgPT5cbiAgICAgICAgICBPYmplY3QuYXNzaWduKHN0YXRlLCB7IHNjcm9sbDogd2luZG93LnNjcm9sbFkgfSksXG4gICAgICAgICk7XG4gICAgICB9LCAxMDApO1xuICAgIH0pO1xuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFxuICAgICAgXCJwb3BzdGF0ZVwiLFxuICAgICAgKGV2ZW50KSA9PiB7XG4gICAgICAgIGlmICghdGhpcy5yZWdpc3Rlck5ld0xvY2F0aW9uKHdpbmRvdy5sb2NhdGlvbikpIHtcbiAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cbiAgICAgICAgY29uc3QgeyB0eXBlLCBiYWNrVHlwZSwgaWQsIHNjcm9sbCwgcG9zaXRpb24gfSA9IGV2ZW50LnN0YXRlIHx8IHt9O1xuICAgICAgICBjb25zdCBocmVmID0gd2luZG93LmxvY2F0aW9uLmhyZWY7XG5cbiAgICAgICAgLy8gQ29tcGFyZSBwb3NpdGlvbnMgdG8gZGV0ZXJtaW5lIGRpcmVjdGlvblxuICAgICAgICBjb25zdCBpc0ZvcndhcmQgPSBwb3NpdGlvbiA+IHRoaXMuY3VycmVudEhpc3RvcnlQb3NpdGlvbjtcbiAgICAgICAgY29uc3QgbmF2VHlwZSA9IGlzRm9yd2FyZCA/IHR5cGUgOiBiYWNrVHlwZSB8fCB0eXBlO1xuXG4gICAgICAgIC8vIFVwZGF0ZSBjdXJyZW50IHBvc2l0aW9uXG4gICAgICAgIHRoaXMuY3VycmVudEhpc3RvcnlQb3NpdGlvbiA9IHBvc2l0aW9uIHx8IDA7XG4gICAgICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2Uuc2V0SXRlbShcbiAgICAgICAgICBQSFhfTFZfSElTVE9SWV9QT1NJVElPTixcbiAgICAgICAgICB0aGlzLmN1cnJlbnRIaXN0b3J5UG9zaXRpb24udG9TdHJpbmcoKSxcbiAgICAgICAgKTtcblxuICAgICAgICBET00uZGlzcGF0Y2hFdmVudCh3aW5kb3csIFwicGh4Om5hdmlnYXRlXCIsIHtcbiAgICAgICAgICBkZXRhaWw6IHtcbiAgICAgICAgICAgIGhyZWYsXG4gICAgICAgICAgICBwYXRjaDogbmF2VHlwZSA9PT0gXCJwYXRjaFwiLFxuICAgICAgICAgICAgcG9wOiB0cnVlLFxuICAgICAgICAgICAgZGlyZWN0aW9uOiBpc0ZvcndhcmQgPyBcImZvcndhcmRcIiA6IFwiYmFja3dhcmRcIixcbiAgICAgICAgICB9LFxuICAgICAgICB9KTtcbiAgICAgICAgdGhpcy5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgICBjb25zdCBjYWxsYmFjayA9ICgpID0+IHtcbiAgICAgICAgICAgIHRoaXMubWF5YmVTY3JvbGwoc2Nyb2xsKTtcbiAgICAgICAgICB9O1xuICAgICAgICAgIGlmIChcbiAgICAgICAgICAgIHRoaXMubWFpbi5pc0Nvbm5lY3RlZCgpICYmXG4gICAgICAgICAgICBuYXZUeXBlID09PSBcInBhdGNoXCIgJiZcbiAgICAgICAgICAgIGlkID09PSB0aGlzLm1haW4uaWRcbiAgICAgICAgICApIHtcbiAgICAgICAgICAgIHRoaXMubWFpbi5wdXNoTGlua1BhdGNoKGV2ZW50LCBocmVmLCBudWxsLCBjYWxsYmFjayk7XG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRoaXMucmVwbGFjZU1haW4oaHJlZiwgbnVsbCwgY2FsbGJhY2spO1xuICAgICAgICAgIH1cbiAgICAgICAgfSk7XG4gICAgICB9LFxuICAgICAgZmFsc2UsXG4gICAgKTtcbiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihcbiAgICAgIFwiY2xpY2tcIixcbiAgICAgIChlKSA9PiB7XG4gICAgICAgIGNvbnN0IHRhcmdldCA9IGNsb3Nlc3RQaHhCaW5kaW5nKGUudGFyZ2V0LCBQSFhfTElWRV9MSU5LKTtcbiAgICAgICAgY29uc3QgdHlwZSA9IHRhcmdldCAmJiB0YXJnZXQuZ2V0QXR0cmlidXRlKFBIWF9MSVZFX0xJTkspO1xuICAgICAgICBpZiAoIXR5cGUgfHwgIXRoaXMuaXNDb25uZWN0ZWQoKSB8fCAhdGhpcy5tYWluIHx8IERPTS53YW50c05ld1RhYihlKSkge1xuICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIC8vIFdoZW4gd3JhcHBpbmcgYW4gU1ZHIGVsZW1lbnQgaW4gYW4gYW5jaG9yIHRhZywgdGhlIGhyZWYgY2FuIGJlIGFuIFNWR0FuaW1hdGVkU3RyaW5nXG4gICAgICAgIGNvbnN0IGhyZWYgPVxuICAgICAgICAgIHRhcmdldC5ocmVmIGluc3RhbmNlb2YgU1ZHQW5pbWF0ZWRTdHJpbmdcbiAgICAgICAgICAgID8gdGFyZ2V0LmhyZWYuYmFzZVZhbFxuICAgICAgICAgICAgOiB0YXJnZXQuaHJlZjtcblxuICAgICAgICBjb25zdCBsaW5rU3RhdGUgPSB0YXJnZXQuZ2V0QXR0cmlidXRlKFBIWF9MSU5LX1NUQVRFKTtcbiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpO1xuICAgICAgICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpOyAvLyBkbyBub3QgYnViYmxlIGNsaWNrIHRvIHJlZ3VsYXIgcGh4LWNsaWNrIGJpbmRpbmdzXG4gICAgICAgIGlmICh0aGlzLnBlbmRpbmdMaW5rID09PSBocmVmKSB7XG4gICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgICBpZiAodHlwZSA9PT0gXCJwYXRjaFwiKSB7XG4gICAgICAgICAgICB0aGlzLnB1c2hIaXN0b3J5UGF0Y2goZSwgaHJlZiwgbGlua1N0YXRlLCB0YXJnZXQpO1xuICAgICAgICAgIH0gZWxzZSBpZiAodHlwZSA9PT0gXCJyZWRpcmVjdFwiKSB7XG4gICAgICAgICAgICB0aGlzLmhpc3RvcnlSZWRpcmVjdChlLCBocmVmLCBsaW5rU3RhdGUsIG51bGwsIHRhcmdldCk7XG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcihcbiAgICAgICAgICAgICAgYGV4cGVjdGVkICR7UEhYX0xJVkVfTElOS30gdG8gYmUgXCJwYXRjaFwiIG9yIFwicmVkaXJlY3RcIiwgZ290OiAke3R5cGV9YCxcbiAgICAgICAgICAgICk7XG4gICAgICAgICAgfVxuICAgICAgICAgIGNvbnN0IHBoeENsaWNrID0gdGFyZ2V0LmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoXCJjbGlja1wiKSk7XG4gICAgICAgICAgaWYgKHBoeENsaWNrKSB7XG4gICAgICAgICAgICB0aGlzLnJlcXVlc3RET01VcGRhdGUoKCkgPT4gdGhpcy5leGVjSlModGFyZ2V0LCBwaHhDbGljaywgXCJjbGlja1wiKSk7XG4gICAgICAgICAgfVxuICAgICAgICB9KTtcbiAgICAgIH0sXG4gICAgICBmYWxzZSxcbiAgICApO1xuICB9XG5cbiAgbWF5YmVTY3JvbGwoc2Nyb2xsKSB7XG4gICAgaWYgKHR5cGVvZiBzY3JvbGwgPT09IFwibnVtYmVyXCIpIHtcbiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICAgIHdpbmRvdy5zY3JvbGxUbygwLCBzY3JvbGwpO1xuICAgICAgfSk7IC8vIHRoZSBib2R5IG5lZWRzIHRvIHJlbmRlciBiZWZvcmUgd2Ugc2Nyb2xsLlxuICAgIH1cbiAgfVxuXG4gIGRpc3BhdGNoRXZlbnQoZXZlbnQsIHBheWxvYWQgPSB7fSkge1xuICAgIERPTS5kaXNwYXRjaEV2ZW50KHdpbmRvdywgYHBoeDoke2V2ZW50fWAsIHsgZGV0YWlsOiBwYXlsb2FkIH0pO1xuICB9XG5cbiAgZGlzcGF0Y2hFdmVudHMoZXZlbnRzKSB7XG4gICAgZXZlbnRzLmZvckVhY2goKFtldmVudCwgcGF5bG9hZF0pID0+IHRoaXMuZGlzcGF0Y2hFdmVudChldmVudCwgcGF5bG9hZCkpO1xuICB9XG5cbiAgd2l0aFBhZ2VMb2FkaW5nKGluZm8sIGNhbGxiYWNrKSB7XG4gICAgRE9NLmRpc3BhdGNoRXZlbnQod2luZG93LCBcInBoeDpwYWdlLWxvYWRpbmctc3RhcnRcIiwgeyBkZXRhaWw6IGluZm8gfSk7XG4gICAgY29uc3QgZG9uZSA9ICgpID0+XG4gICAgICBET00uZGlzcGF0Y2hFdmVudCh3aW5kb3csIFwicGh4OnBhZ2UtbG9hZGluZy1zdG9wXCIsIHsgZGV0YWlsOiBpbmZvIH0pO1xuICAgIHJldHVybiBjYWxsYmFjayA/IGNhbGxiYWNrKGRvbmUpIDogZG9uZTtcbiAgfVxuXG4gIHB1c2hIaXN0b3J5UGF0Y2goZSwgaHJlZiwgbGlua1N0YXRlLCB0YXJnZXRFbCkge1xuICAgIGlmICghdGhpcy5pc0Nvbm5lY3RlZCgpIHx8ICF0aGlzLm1haW4uaXNNYWluKCkpIHtcbiAgICAgIHJldHVybiBCcm93c2VyLnJlZGlyZWN0KGhyZWYpO1xuICAgIH1cblxuICAgIHRoaXMud2l0aFBhZ2VMb2FkaW5nKHsgdG86IGhyZWYsIGtpbmQ6IFwicGF0Y2hcIiB9LCAoZG9uZSkgPT4ge1xuICAgICAgdGhpcy5tYWluLnB1c2hMaW5rUGF0Y2goZSwgaHJlZiwgdGFyZ2V0RWwsIChsaW5rUmVmKSA9PiB7XG4gICAgICAgIHRoaXMuaGlzdG9yeVBhdGNoKGhyZWYsIGxpbmtTdGF0ZSwgbGlua1JlZik7XG4gICAgICAgIGRvbmUoKTtcbiAgICAgIH0pO1xuICAgIH0pO1xuICB9XG5cbiAgaGlzdG9yeVBhdGNoKGhyZWYsIGxpbmtTdGF0ZSwgbGlua1JlZiA9IHRoaXMuc2V0UGVuZGluZ0xpbmsoaHJlZikpIHtcbiAgICBpZiAoIXRoaXMuY29tbWl0UGVuZGluZ0xpbmsobGlua1JlZikpIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG5cbiAgICAvLyBJbmNyZW1lbnQgcG9zaXRpb24gZm9yIG5ldyBzdGF0ZVxuICAgIHRoaXMuY3VycmVudEhpc3RvcnlQb3NpdGlvbisrO1xuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2Uuc2V0SXRlbShcbiAgICAgIFBIWF9MVl9ISVNUT1JZX1BPU0lUSU9OLFxuICAgICAgdGhpcy5jdXJyZW50SGlzdG9yeVBvc2l0aW9uLnRvU3RyaW5nKCksXG4gICAgKTtcblxuICAgIC8vIHN0b3JlIHRoZSB0eXBlIGZvciBiYWNrIG5hdmlnYXRpb25cbiAgICBCcm93c2VyLnVwZGF0ZUN1cnJlbnRTdGF0ZSgoc3RhdGUpID0+ICh7IC4uLnN0YXRlLCBiYWNrVHlwZTogXCJwYXRjaFwiIH0pKTtcblxuICAgIEJyb3dzZXIucHVzaFN0YXRlKFxuICAgICAgbGlua1N0YXRlLFxuICAgICAge1xuICAgICAgICB0eXBlOiBcInBhdGNoXCIsXG4gICAgICAgIGlkOiB0aGlzLm1haW4uaWQsXG4gICAgICAgIHBvc2l0aW9uOiB0aGlzLmN1cnJlbnRIaXN0b3J5UG9zaXRpb24sXG4gICAgICB9LFxuICAgICAgaHJlZixcbiAgICApO1xuXG4gICAgRE9NLmRpc3BhdGNoRXZlbnQod2luZG93LCBcInBoeDpuYXZpZ2F0ZVwiLCB7XG4gICAgICBkZXRhaWw6IHsgcGF0Y2g6IHRydWUsIGhyZWYsIHBvcDogZmFsc2UsIGRpcmVjdGlvbjogXCJmb3J3YXJkXCIgfSxcbiAgICB9KTtcbiAgICB0aGlzLnJlZ2lzdGVyTmV3TG9jYXRpb24od2luZG93LmxvY2F0aW9uKTtcbiAgfVxuXG4gIGhpc3RvcnlSZWRpcmVjdChlLCBocmVmLCBsaW5rU3RhdGUsIGZsYXNoLCB0YXJnZXRFbCkge1xuICAgIGNvbnN0IGNsaWNrTG9hZGluZyA9IHRhcmdldEVsICYmIGUuaXNUcnVzdGVkICYmIGUudHlwZSAhPT0gXCJwb3BzdGF0ZVwiO1xuICAgIGlmIChjbGlja0xvYWRpbmcpIHtcbiAgICAgIHRhcmdldEVsLmNsYXNzTGlzdC5hZGQoXCJwaHgtY2xpY2stbG9hZGluZ1wiKTtcbiAgICB9XG4gICAgaWYgKCF0aGlzLmlzQ29ubmVjdGVkKCkgfHwgIXRoaXMubWFpbi5pc01haW4oKSkge1xuICAgICAgcmV0dXJuIEJyb3dzZXIucmVkaXJlY3QoaHJlZiwgZmxhc2gpO1xuICAgIH1cblxuICAgIC8vIGNvbnZlcnQgdG8gZnVsbCBocmVmIGlmIG9ubHkgcGF0aCBwcmVmaXhcbiAgICBpZiAoL15cXC8kfF5cXC9bXlxcL10rLiokLy50ZXN0KGhyZWYpKSB7XG4gICAgICBjb25zdCB7IHByb3RvY29sLCBob3N0IH0gPSB3aW5kb3cubG9jYXRpb247XG4gICAgICBocmVmID0gYCR7cHJvdG9jb2x9Ly8ke2hvc3R9JHtocmVmfWA7XG4gICAgfVxuICAgIGNvbnN0IHNjcm9sbCA9IHdpbmRvdy5zY3JvbGxZO1xuICAgIHRoaXMud2l0aFBhZ2VMb2FkaW5nKHsgdG86IGhyZWYsIGtpbmQ6IFwicmVkaXJlY3RcIiB9LCAoZG9uZSkgPT4ge1xuICAgICAgdGhpcy5yZXBsYWNlTWFpbihocmVmLCBmbGFzaCwgKGxpbmtSZWYpID0+IHtcbiAgICAgICAgaWYgKGxpbmtSZWYgPT09IHRoaXMubGlua1JlZikge1xuICAgICAgICAgIC8vIEluY3JlbWVudCBwb3NpdGlvbiBmb3IgbmV3IHN0YXRlXG4gICAgICAgICAgdGhpcy5jdXJyZW50SGlzdG9yeVBvc2l0aW9uKys7XG4gICAgICAgICAgdGhpcy5zZXNzaW9uU3RvcmFnZS5zZXRJdGVtKFxuICAgICAgICAgICAgUEhYX0xWX0hJU1RPUllfUE9TSVRJT04sXG4gICAgICAgICAgICB0aGlzLmN1cnJlbnRIaXN0b3J5UG9zaXRpb24udG9TdHJpbmcoKSxcbiAgICAgICAgICApO1xuXG4gICAgICAgICAgLy8gc3RvcmUgdGhlIHR5cGUgZm9yIGJhY2sgbmF2aWdhdGlvblxuICAgICAgICAgIEJyb3dzZXIudXBkYXRlQ3VycmVudFN0YXRlKChzdGF0ZSkgPT4gKHtcbiAgICAgICAgICAgIC4uLnN0YXRlLFxuICAgICAgICAgICAgYmFja1R5cGU6IFwicmVkaXJlY3RcIixcbiAgICAgICAgICB9KSk7XG5cbiAgICAgICAgICBCcm93c2VyLnB1c2hTdGF0ZShcbiAgICAgICAgICAgIGxpbmtTdGF0ZSxcbiAgICAgICAgICAgIHtcbiAgICAgICAgICAgICAgdHlwZTogXCJyZWRpcmVjdFwiLFxuICAgICAgICAgICAgICBpZDogdGhpcy5tYWluLmlkLFxuICAgICAgICAgICAgICBzY3JvbGw6IHNjcm9sbCxcbiAgICAgICAgICAgICAgcG9zaXRpb246IHRoaXMuY3VycmVudEhpc3RvcnlQb3NpdGlvbixcbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgICBocmVmLFxuICAgICAgICAgICk7XG5cbiAgICAgICAgICBET00uZGlzcGF0Y2hFdmVudCh3aW5kb3csIFwicGh4Om5hdmlnYXRlXCIsIHtcbiAgICAgICAgICAgIGRldGFpbDogeyBocmVmLCBwYXRjaDogZmFsc2UsIHBvcDogZmFsc2UsIGRpcmVjdGlvbjogXCJmb3J3YXJkXCIgfSxcbiAgICAgICAgICB9KTtcbiAgICAgICAgICB0aGlzLnJlZ2lzdGVyTmV3TG9jYXRpb24od2luZG93LmxvY2F0aW9uKTtcbiAgICAgICAgfVxuICAgICAgICAvLyBleHBsaWNpdGx5IHVuZG8gY2xpY2stbG9hZGluZyBjbGFzc1xuICAgICAgICAvLyAoaW4gY2FzZSBpdCBvcmlnaW5hdGVkIGluIGEgc3RpY2t5IGxpdmUgdmlldywgb3RoZXJ3aXNlIGl0IHdvdWxkIGJlIHJlbW92ZWQgYW55d2F5KVxuICAgICAgICBpZiAoY2xpY2tMb2FkaW5nKSB7XG4gICAgICAgICAgdGFyZ2V0RWwuY2xhc3NMaXN0LnJlbW92ZShcInBoeC1jbGljay1sb2FkaW5nXCIpO1xuICAgICAgICB9XG4gICAgICAgIGRvbmUoKTtcbiAgICAgIH0pO1xuICAgIH0pO1xuICB9XG5cbiAgcmVnaXN0ZXJOZXdMb2NhdGlvbihuZXdMb2NhdGlvbikge1xuICAgIGNvbnN0IHsgcGF0aG5hbWUsIHNlYXJjaCB9ID0gdGhpcy5jdXJyZW50TG9jYXRpb247XG4gICAgaWYgKHBhdGhuYW1lICsgc2VhcmNoID09PSBuZXdMb2NhdGlvbi5wYXRobmFtZSArIG5ld0xvY2F0aW9uLnNlYXJjaCkge1xuICAgICAgcmV0dXJuIGZhbHNlO1xuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLmN1cnJlbnRMb2NhdGlvbiA9IGNsb25lKG5ld0xvY2F0aW9uKTtcbiAgICAgIHJldHVybiB0cnVlO1xuICAgIH1cbiAgfVxuXG4gIGJpbmRGb3JtcygpIHtcbiAgICBsZXQgaXRlcmF0aW9ucyA9IDA7XG4gICAgbGV0IGV4dGVybmFsRm9ybVN1Ym1pdHRlZCA9IGZhbHNlO1xuXG4gICAgLy8gZGlzYWJsZSBmb3JtcyBvbiBzdWJtaXQgdGhhdCB0cmFjayBwaHgtY2hhbmdlIGJ1dCBwZXJmb3JtIGV4dGVybmFsIHN1Ym1pdFxuICAgIHRoaXMub24oXCJzdWJtaXRcIiwgKGUpID0+IHtcbiAgICAgIGNvbnN0IHBoeFN1Ym1pdCA9IGUudGFyZ2V0LmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoXCJzdWJtaXRcIikpO1xuICAgICAgY29uc3QgcGh4Q2hhbmdlID0gZS50YXJnZXQuZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhcImNoYW5nZVwiKSk7XG4gICAgICBpZiAoIWV4dGVybmFsRm9ybVN1Ym1pdHRlZCAmJiBwaHhDaGFuZ2UgJiYgIXBoeFN1Ym1pdCkge1xuICAgICAgICBleHRlcm5hbEZvcm1TdWJtaXR0ZWQgPSB0cnVlO1xuICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7XG4gICAgICAgIHRoaXMud2l0aGluT3duZXJzKGUudGFyZ2V0LCAodmlldykgPT4ge1xuICAgICAgICAgIHZpZXcuZGlzYWJsZUZvcm0oZS50YXJnZXQpO1xuICAgICAgICAgIC8vIHNhZmFyaSBuZWVkcyBuZXh0IHRpY2tcbiAgICAgICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgICAgICAgIGlmIChET00uaXNVbmxvYWRhYmxlRm9ybVN1Ym1pdChlKSkge1xuICAgICAgICAgICAgICB0aGlzLnVubG9hZCgpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgZS50YXJnZXQuc3VibWl0KCk7XG4gICAgICAgICAgfSk7XG4gICAgICAgIH0pO1xuICAgICAgfVxuICAgIH0pO1xuXG4gICAgdGhpcy5vbihcInN1Ym1pdFwiLCAoZSkgPT4ge1xuICAgICAgY29uc3QgcGh4RXZlbnQgPSBlLnRhcmdldC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFwic3VibWl0XCIpKTtcbiAgICAgIGlmICghcGh4RXZlbnQpIHtcbiAgICAgICAgaWYgKERPTS5pc1VubG9hZGFibGVGb3JtU3VibWl0KGUpKSB7XG4gICAgICAgICAgdGhpcy51bmxvYWQoKTtcbiAgICAgICAgfVxuICAgICAgICByZXR1cm47XG4gICAgICB9XG4gICAgICBlLnByZXZlbnREZWZhdWx0KCk7XG4gICAgICBlLnRhcmdldC5kaXNhYmxlZCA9IHRydWU7XG4gICAgICB0aGlzLndpdGhpbk93bmVycyhlLnRhcmdldCwgKHZpZXcpID0+IHtcbiAgICAgICAgSlMuZXhlYyhlLCBcInN1Ym1pdFwiLCBwaHhFdmVudCwgdmlldywgZS50YXJnZXQsIFtcbiAgICAgICAgICBcInB1c2hcIixcbiAgICAgICAgICB7IHN1Ym1pdHRlcjogZS5zdWJtaXR0ZXIgfSxcbiAgICAgICAgXSk7XG4gICAgICB9KTtcbiAgICB9KTtcblxuICAgIGZvciAoY29uc3QgdHlwZSBvZiBbXCJjaGFuZ2VcIiwgXCJpbnB1dFwiXSkge1xuICAgICAgdGhpcy5vbih0eXBlLCAoZSkgPT4ge1xuICAgICAgICBpZiAoXG4gICAgICAgICAgZSBpbnN0YW5jZW9mIEN1c3RvbUV2ZW50ICYmXG4gICAgICAgICAgKGUudGFyZ2V0IGluc3RhbmNlb2YgSFRNTElucHV0RWxlbWVudCB8fFxuICAgICAgICAgICAgZS50YXJnZXQgaW5zdGFuY2VvZiBIVE1MU2VsZWN0RWxlbWVudCB8fFxuICAgICAgICAgICAgZS50YXJnZXQgaW5zdGFuY2VvZiBIVE1MVGV4dEFyZWFFbGVtZW50KSAmJlxuICAgICAgICAgIGUudGFyZ2V0LmZvcm0gPT09IHVuZGVmaW5lZFxuICAgICAgICApIHtcbiAgICAgICAgICAvLyB0aHJvdyBvbiBpbnZhbGlkIEpTLmRpc3BhdGNoIHRhcmdldCBhbmQgbm9vcCBpZiBDdXN0b21FdmVudCB0cmlnZ2VyZWQgb3V0c2lkZSBKUy5kaXNwYXRjaFxuICAgICAgICAgIGlmIChlLmRldGFpbCAmJiBlLmRldGFpbC5kaXNwYXRjaGVyKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoXG4gICAgICAgICAgICAgIGBkaXNwYXRjaGluZyBhIGN1c3RvbSAke3R5cGV9IGV2ZW50IGlzIG9ubHkgc3VwcG9ydGVkIG9uIGlucHV0IGVsZW1lbnRzIGluc2lkZSBhIGZvcm1gLFxuICAgICAgICAgICAgKTtcbiAgICAgICAgICB9XG4gICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG4gICAgICAgIGNvbnN0IHBoeENoYW5nZSA9IHRoaXMuYmluZGluZyhcImNoYW5nZVwiKTtcbiAgICAgICAgY29uc3QgaW5wdXQgPSBlLnRhcmdldDtcbiAgICAgICAgaWYgKHRoaXMuYmxvY2tQaHhDaGFuZ2VXaGlsZUNvbXBvc2luZyAmJiBlLmlzQ29tcG9zaW5nKSB7XG4gICAgICAgICAgY29uc3Qga2V5ID0gYGNvbXBvc2l0aW9uLWxpc3RlbmVyLSR7dHlwZX1gO1xuICAgICAgICAgIGlmICghRE9NLnByaXZhdGUoaW5wdXQsIGtleSkpIHtcbiAgICAgICAgICAgIERPTS5wdXRQcml2YXRlKGlucHV0LCBrZXksIHRydWUpO1xuICAgICAgICAgICAgaW5wdXQuYWRkRXZlbnRMaXN0ZW5lcihcbiAgICAgICAgICAgICAgXCJjb21wb3NpdGlvbmVuZFwiLFxuICAgICAgICAgICAgICAoKSA9PiB7XG4gICAgICAgICAgICAgICAgLy8gdHJpZ2dlciBhIG5ldyBpbnB1dC9jaGFuZ2UgZXZlbnRcbiAgICAgICAgICAgICAgICBpbnB1dC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCh0eXBlLCB7IGJ1YmJsZXM6IHRydWUgfSkpO1xuICAgICAgICAgICAgICAgIERPTS5kZWxldGVQcml2YXRlKGlucHV0LCBrZXkpO1xuICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICB7IG9uY2U6IHRydWUgfSxcbiAgICAgICAgICAgICk7XG4gICAgICAgICAgfVxuICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuICAgICAgICBjb25zdCBpbnB1dEV2ZW50ID0gaW5wdXQuZ2V0QXR0cmlidXRlKHBoeENoYW5nZSk7XG4gICAgICAgIGNvbnN0IGZvcm1FdmVudCA9IGlucHV0LmZvcm0gJiYgaW5wdXQuZm9ybS5nZXRBdHRyaWJ1dGUocGh4Q2hhbmdlKTtcbiAgICAgICAgY29uc3QgcGh4RXZlbnQgPSBpbnB1dEV2ZW50IHx8IGZvcm1FdmVudDtcbiAgICAgICAgaWYgKCFwaHhFdmVudCkge1xuICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuICAgICAgICBpZiAoXG4gICAgICAgICAgaW5wdXQudHlwZSA9PT0gXCJudW1iZXJcIiAmJlxuICAgICAgICAgIGlucHV0LnZhbGlkaXR5ICYmXG4gICAgICAgICAgaW5wdXQudmFsaWRpdHkuYmFkSW5wdXRcbiAgICAgICAgKSB7XG4gICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgY29uc3QgZGlzcGF0Y2hlciA9IGlucHV0RXZlbnQgPyBpbnB1dCA6IGlucHV0LmZvcm07XG4gICAgICAgIGNvbnN0IGN1cnJlbnRJdGVyYXRpb25zID0gaXRlcmF0aW9ucztcbiAgICAgICAgaXRlcmF0aW9ucysrO1xuICAgICAgICBjb25zdCB7IGF0OiBhdCwgdHlwZTogbGFzdFR5cGUgfSA9XG4gICAgICAgICAgRE9NLnByaXZhdGUoaW5wdXQsIFwicHJldi1pdGVyYXRpb25cIikgfHwge307XG4gICAgICAgIC8vIEJyb3dzZXJzIHNob3VsZCBhbHdheXMgZmlyZSBhdCBsZWFzdCBvbmUgXCJpbnB1dFwiIGV2ZW50IGJlZm9yZSBldmVyeSBcImNoYW5nZVwiXG4gICAgICAgIC8vIElnbm9yZSBcImNoYW5nZVwiIGV2ZW50cywgdW5sZXNzIHRoZXJlIHdhcyBubyBwcmlvciBcImlucHV0XCIgZXZlbnQuXG4gICAgICAgIC8vIFRoaXMgY291bGQgaGFwcGVuIGlmIHVzZXIgY29kZSB0cmlnZ2VycyBhIFwiY2hhbmdlXCIgZXZlbnQsIG9yIGlmIHRoZSBicm93c2VyIGlzIG5vbi1jb25mb3JtaW5nLlxuICAgICAgICBpZiAoXG4gICAgICAgICAgYXQgPT09IGN1cnJlbnRJdGVyYXRpb25zIC0gMSAmJlxuICAgICAgICAgIHR5cGUgPT09IFwiY2hhbmdlXCIgJiZcbiAgICAgICAgICBsYXN0VHlwZSA9PT0gXCJpbnB1dFwiXG4gICAgICAgICkge1xuICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIERPTS5wdXRQcml2YXRlKGlucHV0LCBcInByZXYtaXRlcmF0aW9uXCIsIHtcbiAgICAgICAgICBhdDogY3VycmVudEl0ZXJhdGlvbnMsXG4gICAgICAgICAgdHlwZTogdHlwZSxcbiAgICAgICAgfSk7XG5cbiAgICAgICAgdGhpcy5kZWJvdW5jZShpbnB1dCwgZSwgdHlwZSwgKCkgPT4ge1xuICAgICAgICAgIHRoaXMud2l0aGluT3duZXJzKGRpc3BhdGNoZXIsICh2aWV3KSA9PiB7XG4gICAgICAgICAgICBET00ucHV0UHJpdmF0ZShpbnB1dCwgUEhYX0hBU19GT0NVU0VELCB0cnVlKTtcbiAgICAgICAgICAgIEpTLmV4ZWMoZSwgXCJjaGFuZ2VcIiwgcGh4RXZlbnQsIHZpZXcsIGlucHV0LCBbXG4gICAgICAgICAgICAgIFwicHVzaFwiLFxuICAgICAgICAgICAgICB7IF90YXJnZXQ6IGUudGFyZ2V0Lm5hbWUsIGRpc3BhdGNoZXI6IGRpc3BhdGNoZXIgfSxcbiAgICAgICAgICAgIF0pO1xuICAgICAgICAgIH0pO1xuICAgICAgICB9KTtcbiAgICAgIH0pO1xuICAgIH1cbiAgICB0aGlzLm9uKFwicmVzZXRcIiwgKGUpID0+IHtcbiAgICAgIGNvbnN0IGZvcm0gPSBlLnRhcmdldDtcbiAgICAgIERPTS5yZXNldEZvcm0oZm9ybSk7XG4gICAgICBjb25zdCBpbnB1dCA9IEFycmF5LmZyb20oZm9ybS5lbGVtZW50cykuZmluZCgoZWwpID0+IGVsLnR5cGUgPT09IFwicmVzZXRcIik7XG4gICAgICBpZiAoaW5wdXQpIHtcbiAgICAgICAgLy8gd2FpdCB1bnRpbCBuZXh0IHRpY2sgdG8gZ2V0IHVwZGF0ZWQgaW5wdXQgdmFsdWVcbiAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICAgICAgaW5wdXQuZGlzcGF0Y2hFdmVudChcbiAgICAgICAgICAgIG5ldyBFdmVudChcImlucHV0XCIsIHsgYnViYmxlczogdHJ1ZSwgY2FuY2VsYWJsZTogZmFsc2UgfSksXG4gICAgICAgICAgKTtcbiAgICAgICAgfSk7XG4gICAgICB9XG4gICAgfSk7XG4gIH1cblxuICBkZWJvdW5jZShlbCwgZXZlbnQsIGV2ZW50VHlwZSwgY2FsbGJhY2spIHtcbiAgICBpZiAoZXZlbnRUeXBlID09PSBcImJsdXJcIiB8fCBldmVudFR5cGUgPT09IFwiZm9jdXNvdXRcIikge1xuICAgICAgcmV0dXJuIGNhbGxiYWNrKCk7XG4gICAgfVxuXG4gICAgY29uc3QgcGh4RGVib3VuY2UgPSB0aGlzLmJpbmRpbmcoUEhYX0RFQk9VTkNFKTtcbiAgICBjb25zdCBwaHhUaHJvdHRsZSA9IHRoaXMuYmluZGluZyhQSFhfVEhST1RUTEUpO1xuICAgIGNvbnN0IGRlZmF1bHREZWJvdW5jZSA9IHRoaXMuZGVmYXVsdHMuZGVib3VuY2UudG9TdHJpbmcoKTtcbiAgICBjb25zdCBkZWZhdWx0VGhyb3R0bGUgPSB0aGlzLmRlZmF1bHRzLnRocm90dGxlLnRvU3RyaW5nKCk7XG5cbiAgICB0aGlzLndpdGhpbk93bmVycyhlbCwgKHZpZXcpID0+IHtcbiAgICAgIGNvbnN0IGFzeW5jRmlsdGVyID0gKCkgPT5cbiAgICAgICAgIXZpZXcuaXNEZXN0cm95ZWQoKSAmJiBkb2N1bWVudC5ib2R5LmNvbnRhaW5zKGVsKTtcbiAgICAgIERPTS5kZWJvdW5jZShcbiAgICAgICAgZWwsXG4gICAgICAgIGV2ZW50LFxuICAgICAgICBwaHhEZWJvdW5jZSxcbiAgICAgICAgZGVmYXVsdERlYm91bmNlLFxuICAgICAgICBwaHhUaHJvdHRsZSxcbiAgICAgICAgZGVmYXVsdFRocm90dGxlLFxuICAgICAgICBhc3luY0ZpbHRlcixcbiAgICAgICAgKCkgPT4ge1xuICAgICAgICAgIGNhbGxiYWNrKCk7XG4gICAgICAgIH0sXG4gICAgICApO1xuICAgIH0pO1xuICB9XG5cbiAgc2lsZW5jZUV2ZW50cyhjYWxsYmFjaykge1xuICAgIHRoaXMuc2lsZW5jZWQgPSB0cnVlO1xuICAgIGNhbGxiYWNrKCk7XG4gICAgdGhpcy5zaWxlbmNlZCA9IGZhbHNlO1xuICB9XG5cbiAgb24oZXZlbnQsIGNhbGxiYWNrKSB7XG4gICAgdGhpcy5ib3VuZEV2ZW50TmFtZXMuYWRkKGV2ZW50KTtcbiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihldmVudCwgKGUpID0+IHtcbiAgICAgIGlmICghdGhpcy5zaWxlbmNlZCkge1xuICAgICAgICBjYWxsYmFjayhlKTtcbiAgICAgIH1cbiAgICB9KTtcbiAgfVxuXG4gIGpzUXVlcnlTZWxlY3RvckFsbChzb3VyY2VFbCwgcXVlcnksIGRlZmF1bHRRdWVyeSkge1xuICAgIGNvbnN0IGFsbCA9IHRoaXMuZG9tQ2FsbGJhY2tzLmpzUXVlcnlTZWxlY3RvckFsbDtcbiAgICByZXR1cm4gYWxsID8gYWxsKHNvdXJjZUVsLCBxdWVyeSwgZGVmYXVsdFF1ZXJ5KSA6IGRlZmF1bHRRdWVyeSgpO1xuICB9XG59XG5cbmNsYXNzIFRyYW5zaXRpb25TZXQge1xuICBjb25zdHJ1Y3RvcigpIHtcbiAgICB0aGlzLnRyYW5zaXRpb25zID0gbmV3IFNldCgpO1xuICAgIHRoaXMucHJvbWlzZXMgPSBuZXcgU2V0KCk7XG4gICAgdGhpcy5wZW5kaW5nT3BzID0gW107XG4gIH1cblxuICByZXNldCgpIHtcbiAgICB0aGlzLnRyYW5zaXRpb25zLmZvckVhY2goKHRpbWVyKSA9PiB7XG4gICAgICBjbGVhclRpbWVvdXQodGltZXIpO1xuICAgICAgdGhpcy50cmFuc2l0aW9ucy5kZWxldGUodGltZXIpO1xuICAgIH0pO1xuICAgIHRoaXMucHJvbWlzZXMuY2xlYXIoKTtcbiAgICB0aGlzLmZsdXNoUGVuZGluZ09wcygpO1xuICB9XG5cbiAgYWZ0ZXIoY2FsbGJhY2spIHtcbiAgICBpZiAodGhpcy5zaXplKCkgPT09IDApIHtcbiAgICAgIGNhbGxiYWNrKCk7XG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMucHVzaFBlbmRpbmdPcChjYWxsYmFjayk7XG4gICAgfVxuICB9XG5cbiAgYWRkVHJhbnNpdGlvbih0aW1lLCBvblN0YXJ0LCBvbkRvbmUpIHtcbiAgICBvblN0YXJ0KCk7XG4gICAgY29uc3QgdGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgIHRoaXMudHJhbnNpdGlvbnMuZGVsZXRlKHRpbWVyKTtcbiAgICAgIG9uRG9uZSgpO1xuICAgICAgdGhpcy5mbHVzaFBlbmRpbmdPcHMoKTtcbiAgICB9LCB0aW1lKTtcbiAgICB0aGlzLnRyYW5zaXRpb25zLmFkZCh0aW1lcik7XG4gIH1cblxuICBhZGRBc3luY1RyYW5zaXRpb24ocHJvbWlzZSkge1xuICAgIHRoaXMucHJvbWlzZXMuYWRkKHByb21pc2UpO1xuICAgIHByb21pc2UudGhlbigoKSA9PiB7XG4gICAgICB0aGlzLnByb21pc2VzLmRlbGV0ZShwcm9taXNlKTtcbiAgICAgIHRoaXMuZmx1c2hQZW5kaW5nT3BzKCk7XG4gICAgfSk7XG4gIH1cblxuICBwdXNoUGVuZGluZ09wKG9wKSB7XG4gICAgdGhpcy5wZW5kaW5nT3BzLnB1c2gob3ApO1xuICB9XG5cbiAgc2l6ZSgpIHtcbiAgICByZXR1cm4gdGhpcy50cmFuc2l0aW9ucy5zaXplICsgdGhpcy5wcm9taXNlcy5zaXplO1xuICB9XG5cbiAgZmx1c2hQZW5kaW5nT3BzKCkge1xuICAgIGlmICh0aGlzLnNpemUoKSA+IDApIHtcbiAgICAgIHJldHVybjtcbiAgICB9XG4gICAgY29uc3Qgb3AgPSB0aGlzLnBlbmRpbmdPcHMuc2hpZnQoKTtcbiAgICBpZiAob3ApIHtcbiAgICAgIG9wKCk7XG4gICAgICB0aGlzLmZsdXNoUGVuZGluZ09wcygpO1xuICAgIH1cbiAgfVxufVxuIiwgIi8qXG49PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PVxuUGhvZW5peCBMaXZlVmlldyBKYXZhU2NyaXB0IENsaWVudFxuPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT1cblxuU2VlIHRoZSBoZXhkb2NzIGF0IGBodHRwczovL2hleGRvY3MucG0vcGhvZW5peF9saXZlX3ZpZXdgIGZvciBkb2N1bWVudGF0aW9uLlxuKi9cblxuaW1wb3J0IE9yaWdpbmFsTGl2ZVNvY2tldCwgeyBpc1VzZWRJbnB1dCB9IGZyb20gXCIuL2xpdmVfc29ja2V0XCI7XG5pbXBvcnQgRE9NIGZyb20gXCIuL2RvbVwiO1xuaW1wb3J0IHsgVmlld0hvb2sgfSBmcm9tIFwiLi92aWV3X2hvb2tcIjtcbmltcG9ydCBWaWV3IGZyb20gXCIuL3ZpZXdcIjtcblxuaW1wb3J0IHR5cGUgeyBMaXZlU29ja2V0SlNDb21tYW5kcyB9IGZyb20gXCIuL2pzX2NvbW1hbmRzXCI7XG5pbXBvcnQgdHlwZSB7IEhvb2ssIEhvb2tzT3B0aW9ucyB9IGZyb20gXCIuL3ZpZXdfaG9va1wiO1xuaW1wb3J0IHR5cGUgeyBTb2NrZXQgYXMgUGhvZW5peFNvY2tldCB9IGZyb20gXCJwaG9lbml4XCI7XG5cbi8qKlxuICogT3B0aW9ucyBmb3IgY29uZmlndXJpbmcgdGhlIExpdmVTb2NrZXQgaW5zdGFuY2UuXG4gKi9cbmV4cG9ydCBpbnRlcmZhY2UgTGl2ZVNvY2tldE9wdGlvbnMge1xuICAvKipcbiAgICogRGVmYXVsdHMgZm9yIHBoeC1kZWJvdW5jZSBhbmQgcGh4LXRocm90dGxlLlxuICAgKi9cbiAgZGVmYXVsdHM/OiB7XG4gICAgLyoqIFRoZSBtaWxsaXNlY29uZCBwaHgtZGVib3VuY2UgdGltZS4gRGVmYXVsdHMgMzAwICovXG4gICAgZGVib3VuY2U/OiBudW1iZXI7XG4gICAgLyoqIFRoZSBtaWxsaXNlY29uZCBwaHgtdGhyb3R0bGUgdGltZS4gRGVmYXVsdHMgMzAwICovXG4gICAgdGhyb3R0bGU/OiBudW1iZXI7XG4gIH07XG4gIC8qKlxuICAgKiBBbiBvYmplY3Qgb3IgZnVuY3Rpb24gZm9yIHBhc3NpbmcgY29ubmVjdCBwYXJhbXMuXG4gICAqIFRoZSBmdW5jdGlvbiByZWNlaXZlcyB0aGUgZWxlbWVudCBhc3NvY2lhdGVkIHdpdGggYSBnaXZlbiBMaXZlVmlldy4gRm9yIGV4YW1wbGU6XG4gICAqXG4gICAqICAgICAoZWwpID0+IHt2aWV3OiBlbC5nZXRBdHRyaWJ1dGUoXCJkYXRhLW15LXZpZXctbmFtZVwiLCB0b2tlbjogd2luZG93Lm15VG9rZW59XG4gICAqXG4gICAqL1xuICBwYXJhbXM/OlxuICAgIHwgKChlbDogSFRNTEVsZW1lbnQpID0+IHsgW2tleTogc3RyaW5nXTogYW55IH0pXG4gICAgfCB7IFtrZXk6IHN0cmluZ106IGFueSB9O1xuICAvKipcbiAgICogVGhlIG9wdGlvbmFsIHByZWZpeCB0byB1c2UgZm9yIGFsbCBwaHggRE9NIGFubm90YXRpb25zLlxuICAgKlxuICAgKiBEZWZhdWx0cyB0byBcInBoeC1cIi5cbiAgICovXG4gIGJpbmRpbmdQcmVmaXg/OiBzdHJpbmc7XG4gIC8qKlxuICAgKiBDYWxsYmFja3MgZm9yIExpdmVWaWV3IGhvb2tzLlxuICAgKlxuICAgKiBTZWUgW0NsaWVudCBob29rcyB2aWEgYHBoeC1ob29rYF0oaHR0cHM6Ly9oZXhkb2NzLnBtL3Bob2VuaXhfbGl2ZV92aWV3L2pzLWludGVyb3AuaHRtbCNjbGllbnQtaG9va3MtdmlhLXBoeC1ob29rKSBmb3IgbW9yZSBpbmZvcm1hdGlvbi5cbiAgICovXG4gIGhvb2tzPzogSG9va3NPcHRpb25zO1xuICAvKiogQ2FsbGJhY2tzIGZvciBMaXZlVmlldyB1cGxvYWRlcnMuICovXG4gIHVwbG9hZGVycz86IHsgW2tleTogc3RyaW5nXTogYW55IH07IC8vIFRPRE86IGRlZmluZSBtb3JlIHNwZWNpZmljYWxseVxuICAvKiogRGVsYXkgaW4gbWlsbGlzZWNvbmRzIGJlZm9yZSBhcHBseWluZyBsb2FkaW5nIHN0YXRlcy4gKi9cbiAgbG9hZGVyVGltZW91dD86IG51bWJlcjtcbiAgLyoqIERlbGF5IGluIG1pbGxpc2Vjb25kcyBiZWZvcmUgZXhlY3V0aW5nIHBoeC1kaXNjb25uZWN0ZWQgY29tbWFuZHMuICovXG4gIGRpc2Nvbm5lY3RlZFRpbWVvdXQ/OiBudW1iZXI7XG4gIC8qKiBNYXhpbXVtIHJlbG9hZHMgYmVmb3JlIGVudGVyaW5nIGZhaWxzYWZlIG1vZGUuICovXG4gIG1heFJlbG9hZHM/OiBudW1iZXI7XG4gIC8qKiBNaW5pbXVtIHRpbWUgYmV0d2VlbiBub3JtYWwgcmVsb2FkIGF0dGVtcHRzLiAqL1xuICByZWxvYWRKaXR0ZXJNaW4/OiBudW1iZXI7XG4gIC8qKiBNYXhpbXVtIHRpbWUgYmV0d2VlbiBub3JtYWwgcmVsb2FkIGF0dGVtcHRzLiAqL1xuICByZWxvYWRKaXR0ZXJNYXg/OiBudW1iZXI7XG4gIC8qKiBUaW1lIGJldHdlZW4gcmVsb2FkIGF0dGVtcHRzIGluIGZhaWxzYWZlIG1vZGUuICovXG4gIGZhaWxzYWZlSml0dGVyPzogbnVtYmVyO1xuICAvKipcbiAgICogRnVuY3Rpb24gdG8gbG9nIGRlYnVnIGluZm9ybWF0aW9uLiBGb3IgZXhhbXBsZTpcbiAgICpcbiAgICogICAgICh2aWV3LCBraW5kLCBtc2csIG9iaikgPT4gY29uc29sZS5sb2coYCR7dmlldy5pZH0gJHtraW5kfTogJHttc2d9IC0gYCwgb2JqKVxuICAgKi9cbiAgdmlld0xvZ2dlcj86ICh2aWV3OiBWaWV3LCBraW5kOiBzdHJpbmcsIG1zZzogc3RyaW5nLCBvYmo6IGFueSkgPT4gdm9pZDtcbiAgLyoqXG4gICAqIE9iamVjdCBtYXBwaW5nIGV2ZW50IG5hbWVzIHRvIGZ1bmN0aW9ucyBmb3IgcG9wdWxhdGluZyBldmVudCBtZXRhZGF0YS5cbiAgICpcbiAgICogICAgIG1ldGFkYXRhOiB7XG4gICAqICAgICAgIGNsaWNrOiAoZSwgZWwpID0+IHtcbiAgICogICAgICAgICByZXR1cm4ge1xuICAgKiAgICAgICAgICAgY3RybEtleTogZS5jdHJsS2V5LFxuICAgKiAgICAgICAgICAgbWV0YUtleTogZS5tZXRhS2V5LFxuICAgKiAgICAgICAgICAgZGV0YWlsOiBlLmRldGFpbCB8fCAxLFxuICAgKiAgICAgICAgIH1cbiAgICogICAgICAgfSxcbiAgICogICAgICAga2V5ZG93bjogKGUsIGVsKSA9PiB7XG4gICAqICAgICAgICAgcmV0dXJuIHtcbiAgICogICAgICAgICAgIGtleTogZS5rZXksXG4gICAqICAgICAgICAgICBjdHJsS2V5OiBlLmN0cmxLZXksXG4gICAqICAgICAgICAgICBtZXRhS2V5OiBlLm1ldGFLZXksXG4gICAqICAgICAgICAgICBzaGlmdEtleTogZS5zaGlmdEtleVxuICAgKiAgICAgICAgIH1cbiAgICogICAgICAgfVxuICAgKiAgICAgfVxuICAgKlxuICAgKi9cbiAgbWV0YWRhdGE/OiB7IFtldmVudE5hbWU6IHN0cmluZ106IChlOiBFdmVudCwgZWw6IEhUTUxFbGVtZW50KSA9PiBvYmplY3QgfTtcbiAgLyoqXG4gICAqIEFuIG9wdGlvbmFsIFN0b3JhZ2UgY29tcGF0aWJsZSBvYmplY3RcbiAgICogVXNlZnVsIHdoZW4gTGl2ZVZpZXcgd29uJ3QgaGF2ZSBhY2Nlc3MgdG8gYHNlc3Npb25TdG9yYWdlYC4gRm9yIGV4YW1wbGUsIFRoaXMgY291bGRcbiAgICogaGFwcGVuIGlmIGEgc2l0ZSBsb2FkcyBhIGNyb3NzLWRvbWFpbiBMaXZlVmlldyBpbiBhbiBpZnJhbWUuXG4gICAqXG4gICAqIEV4YW1wbGUgdXNhZ2U6XG4gICAqXG4gICAqICAgICBjbGFzcyBJbk1lbW9yeVN0b3JhZ2Uge1xuICAgKiAgICAgICBjb25zdHJ1Y3RvcigpIHsgdGhpcy5zdG9yYWdlID0ge30gfVxuICAgKiAgICAgICBnZXRJdGVtKGtleU5hbWUpIHsgcmV0dXJuIHRoaXMuc3RvcmFnZVtrZXlOYW1lXSB8fCBudWxsIH1cbiAgICogICAgICAgcmVtb3ZlSXRlbShrZXlOYW1lKSB7IGRlbGV0ZSB0aGlzLnN0b3JhZ2Vba2V5TmFtZV0gfVxuICAgKiAgICAgICBzZXRJdGVtKGtleU5hbWUsIGtleVZhbHVlKSB7IHRoaXMuc3RvcmFnZVtrZXlOYW1lXSA9IGtleVZhbHVlIH1cbiAgICogICAgIH1cbiAgICovXG4gIHNlc3Npb25TdG9yYWdlPzogU3RvcmFnZTtcbiAgLyoqXG4gICAqIEFuIG9wdGlvbmFsIFN0b3JhZ2UgY29tcGF0aWJsZSBvYmplY3RcbiAgICogVXNlZnVsIHdoZW4gTGl2ZVZpZXcgd29uJ3QgaGF2ZSBhY2Nlc3MgdG8gYGxvY2FsU3RvcmFnZWAuXG4gICAqXG4gICAqIFNlZSBgc2Vzc2lvblN0b3JhZ2VgIGZvciBhbiBleGFtcGxlLlxuICAgKi9cbiAgbG9jYWxTdG9yYWdlPzogU3RvcmFnZTtcbiAgLyoqXG4gICAqIElmIHNldCB0byBgdHJ1ZWAsIGBwaHgtY2hhbmdlYCBldmVudHMgd2lsbCBiZSBibG9ja2VkICh3aWxsIG5vdCBmaXJlKVxuICAgKiB3aGlsZSB0aGUgdXNlciBpcyBjb21wb3NpbmcgaW5wdXQgdXNpbmcgYW4gSU1FIChJbnB1dCBNZXRob2QgRWRpdG9yKS5cbiAgICogVGhpcyBpcyBkZXRlcm1pbmVkIGJ5IHRoZSBgZS5pc0NvbXBvc2luZ2AgcHJvcGVydHkgb24ga2V5Ym9hcmQgZXZlbnRzLFxuICAgKiB3aGljaCBpcyBgdHJ1ZWAgd2hlbiB0aGUgdXNlciBpcyBpbiB0aGUgcHJvY2VzcyBvZiBlbnRlcmluZyBjb21wb3NlZCBjaGFyYWN0ZXJzIChmb3IgZXhhbXBsZSxcbiAgICogd2hlbiB0eXBpbmcgSmFwYW5lc2Ugb3IgQ2hpbmVzZSB1c2luZyByb21hamkgb3IgcGlueWluIGlucHV0IG1ldGhvZHMpLlxuICAgKiBCeSBkZWZhdWx0LCBgcGh4LWNoYW5nZWAgd2lsbCBub3QgYmUgYmxvY2tlZCBkdXJpbmcgYSBjb21wb3NpdGlvbiBzZXNzaW9uLFxuICAgKiBidXQgbm90ZSB0aGF0IHRoZXJlIHdlcmUgaXNzdWVzIHJlcG9ydGVkIGluIG9sZGVyIHZlcnNpb25zIG9mIFNhZmFyaSxcbiAgICogd2hlcmUgYSBMaXZlVmlldyBwYXRjaCB0byB0aGUgaW5wdXQgY2F1c2VkIHVuZXhwZWN0ZWQgYmVoYXZpb3IuXG4gICAqXG4gICAqIEZvciBtb3JlIGluZm9ybWF0aW9uLCBzZWVcbiAgICogLSBodHRwczovL2RldmVsb3Blci5tb3ppbGxhLm9yZy9lbi1VUy9kb2NzL1dlYi9BUEkvS2V5Ym9hcmRFdmVudC9pc0NvbXBvc2luZ1xuICAgKiAtIGh0dHBzOi8vZ2l0aHViLmNvbS9waG9lbml4ZnJhbWV3b3JrL3Bob2VuaXhfbGl2ZV92aWV3L2lzc3Vlcy8zMzIyXG4gICAqXG4gICAqIERlZmF1bHRzIHRvIGBmYWxzZWAuXG4gICAqL1xuICBibG9ja1BoeENoYW5nZVdoaWxlQ29tcG9zaW5nPzogYm9vbGVhbjtcbiAgLyoqIERPTSBjYWxsYmFja3MuICovXG4gIGRvbT86IHtcbiAgICAvKipcbiAgICAgKiBBbiBvcHRpb25hbCBmdW5jdGlvbiB0byBtb2RpZnkgdGhlIGJlaGF2aW9yIG9mIHF1ZXJ5aW5nIGVsZW1lbnRzIGluIEpTIGNvbW1hbmRzLlxuICAgICAqIEBwYXJhbSBzb3VyY2VFbCAtIFRoZSBzb3VyY2UgZWxlbWVudCwgZS5nLiB0aGUgYnV0dG9uIHRoYXQgd2FzIGNsaWNrZWQuXG4gICAgICogQHBhcmFtIHF1ZXJ5IC0gVGhlIHF1ZXJ5IHZhbHVlLlxuICAgICAqIEBwYXJhbSBkZWZhdWx0UXVlcnkgLSBBIGRlZmF1bHQgcXVlcnkgZnVuY3Rpb24gdGhhdCBjYW4gYmUgdXNlZCBpZiBubyBjdXN0b20gcXVlcnkgc2hvdWxkIGJlIGFwcGxpZWQuXG4gICAgICogQHJldHVybnMgQSBsaXN0IG9mIERPTSBlbGVtZW50cy5cbiAgICAgKi9cbiAgICBqc1F1ZXJ5U2VsZWN0b3JBbGw/OiAoXG4gICAgICBzb3VyY2VFbDogSFRNTEVsZW1lbnQsXG4gICAgICBxdWVyeTogc3RyaW5nLFxuICAgICAgZGVmYXVsdFF1ZXJ5OiAoKSA9PiBFbGVtZW50W10sXG4gICAgKSA9PiBFbGVtZW50W107XG4gICAgLyoqXG4gICAgICogQ2FsbGVkIGltbWVkaWF0ZWx5IGJlZm9yZSBhIERPTSBwYXRjaCBpcyBhcHBsaWVkLlxuICAgICAqL1xuICAgIG9uUGF0Y2hTdGFydD86IChjb250YWluZXI6IEhUTUxFbGVtZW50KSA9PiB2b2lkO1xuICAgIC8qKlxuICAgICAqIENhbGxlZCBpbW1lZGlhdGVseSBhZnRlciBhIERPTSBwYXRjaCBpcyBhcHBsaWVkLlxuICAgICAqL1xuICAgIG9uUGF0Y2hFbmQ/OiAoY29udGFpbmVyOiBIVE1MRWxlbWVudCkgPT4gdm9pZDtcbiAgICAvKipcbiAgICAgKiBDYWxsZWQgd2hlbiBhIG5ldyBET00gbm9kZSBpcyBhZGRlZC5cbiAgICAgKi9cbiAgICBvbk5vZGVBZGRlZD86IChub2RlOiBOb2RlKSA9PiB2b2lkO1xuICAgIC8qKlxuICAgICAqIENhbGxlZCBiZWZvcmUgYW4gZWxlbWVudCBpcyB1cGRhdGVkLlxuICAgICAqL1xuICAgIG9uQmVmb3JlRWxVcGRhdGVkPzogKGZyb21FbDogRWxlbWVudCwgdG9FbDogRWxlbWVudCkgPT4gdm9pZDtcbiAgfTtcbiAgLyoqIEFsbG93IHBhc3N0aHJvdWdoIG9mIG90aGVyIG9wdGlvbnMgdG8gdGhlIFBob2VuaXggU29ja2V0IGNvbnN0cnVjdG9yLiAqL1xuICBba2V5OiBzdHJpbmddOiBhbnk7XG59XG5cbi8qKlxuICogSW50ZXJmYWNlIGRlc2NyaWJpbmcgdGhlIHB1YmxpYyBBUEkgb2YgYSBMaXZlU29ja2V0IGluc3RhbmNlLlxuICovXG5leHBvcnQgaW50ZXJmYWNlIExpdmVTb2NrZXRJbnN0YW5jZUludGVyZmFjZSB7XG4gIC8qKlxuICAgKiBSZXR1cm5zIHRoZSB2ZXJzaW9uIG9mIHRoZSBMaXZlVmlldyBjbGllbnQuXG4gICAqL1xuICB2ZXJzaW9uKCk6IHN0cmluZztcbiAgLyoqXG4gICAqIFJldHVybnMgdHJ1ZSBpZiBwcm9maWxpbmcgaXMgZW5hYmxlZC4gU2VlIGBlbmFibGVQcm9maWxpbmdgIGFuZCBgZGlzYWJsZVByb2ZpbGluZ2AuXG4gICAqL1xuICBpc1Byb2ZpbGVFbmFibGVkKCk6IGJvb2xlYW47XG4gIC8qKlxuICAgKiBSZXR1cm5zIHRydWUgaWYgZGVidWdnaW5nIGlzIGVuYWJsZWQuIFNlZSBgZW5hYmxlRGVidWdgIGFuZCBgZGlzYWJsZURlYnVnYC5cbiAgICovXG4gIGlzRGVidWdFbmFibGVkKCk6IGJvb2xlYW47XG4gIC8qKlxuICAgKiBSZXR1cm5zIHRydWUgaWYgZGVidWdnaW5nIGlzIGRpc2FibGVkLiBTZWUgYGVuYWJsZURlYnVnYCBhbmQgYGRpc2FibGVEZWJ1Z2AuXG4gICAqL1xuICBpc0RlYnVnRGlzYWJsZWQoKTogYm9vbGVhbjtcbiAgLyoqXG4gICAqIEVuYWJsZXMgZGVidWdnaW5nLlxuICAgKlxuICAgKiBXaGVuIGRlYnVnZ2luZyBpcyBlbmFibGVkLCB0aGUgTGl2ZVZpZXcgY2xpZW50IHdpbGwgbG9nIGRlYnVnIGluZm9ybWF0aW9uIHRvIHRoZSBjb25zb2xlLlxuICAgKiBTZWUgW0RlYnVnZ2luZyBjbGllbnQgZXZlbnRzXShodHRwczovL2hleGRvY3MucG0vcGhvZW5peF9saXZlX3ZpZXcvanMtaW50ZXJvcC5odG1sI2RlYnVnZ2luZy1jbGllbnQtZXZlbnRzKSBmb3IgbW9yZSBpbmZvcm1hdGlvbi5cbiAgICovXG4gIGVuYWJsZURlYnVnKCk6IHZvaWQ7XG4gIC8qKlxuICAgKiBFbmFibGVzIHByb2ZpbGluZy5cbiAgICpcbiAgICogV2hlbiBwcm9maWxpbmcgaXMgZW5hYmxlZCwgdGhlIExpdmVWaWV3IGNsaWVudCB3aWxsIGxvZyBwcm9maWxpbmcgaW5mb3JtYXRpb24gdG8gdGhlIGNvbnNvbGUuXG4gICAqL1xuICBlbmFibGVQcm9maWxpbmcoKTogdm9pZDtcbiAgLyoqXG4gICAqIERpc2FibGVzIGRlYnVnZ2luZy5cbiAgICovXG4gIGRpc2FibGVEZWJ1ZygpOiB2b2lkO1xuICAvKipcbiAgICogRGlzYWJsZXMgcHJvZmlsaW5nLlxuICAgKi9cbiAgZGlzYWJsZVByb2ZpbGluZygpOiB2b2lkO1xuICAvKipcbiAgICogRW5hYmxlcyBsYXRlbmN5IHNpbXVsYXRpb24uXG4gICAqXG4gICAqIFdoZW4gbGF0ZW5jeSBzaW11bGF0aW9uIGlzIGVuYWJsZWQsIHRoZSBMaXZlVmlldyBjbGllbnQgd2lsbCBhZGQgYSBkZWxheSB0byByZXF1ZXN0cyBhbmQgcmVzcG9uc2VzIGZyb20gdGhlIHNlcnZlci5cbiAgICogU2VlIFtTaW11bGF0aW5nIExhdGVuY3ldKGh0dHBzOi8vaGV4ZG9jcy5wbS9waG9lbml4X2xpdmVfdmlldy9qcy1pbnRlcm9wLmh0bWwjc2ltdWxhdGluZy1sYXRlbmN5KSBmb3IgbW9yZSBpbmZvcm1hdGlvbi5cbiAgICovXG4gIGVuYWJsZUxhdGVuY3lTaW0odXBwZXJCb3VuZE1zOiBudW1iZXIpOiB2b2lkO1xuICAvKipcbiAgICogRGlzYWJsZXMgbGF0ZW5jeSBzaW11bGF0aW9uLlxuICAgKi9cbiAgZGlzYWJsZUxhdGVuY3lTaW0oKTogdm9pZDtcbiAgLyoqXG4gICAqIFJldHVybnMgdGhlIGN1cnJlbnQgbGF0ZW5jeSBzaW11bGF0aW9uIHVwcGVyIGJvdW5kLlxuICAgKi9cbiAgZ2V0TGF0ZW5jeVNpbSgpOiBudW1iZXIgfCBudWxsO1xuICAvKipcbiAgICogUmV0dXJucyB0aGUgUGhvZW5peCBTb2NrZXQgaW5zdGFuY2UuXG4gICAqL1xuICBnZXRTb2NrZXQoKTogUGhvZW5peFNvY2tldDtcbiAgLyoqXG4gICAqIENvbm5lY3RzIHRvIHRoZSBMaXZlVmlldyBzZXJ2ZXIuXG4gICAqL1xuICBjb25uZWN0KCk6IHZvaWQ7XG4gIC8qKlxuICAgKiBEaXNjb25uZWN0cyBmcm9tIHRoZSBMaXZlVmlldyBzZXJ2ZXIuXG4gICAqL1xuICBkaXNjb25uZWN0KGNhbGxiYWNrPzogKCkgPT4gdm9pZCk6IHZvaWQ7XG4gIC8qKlxuICAgKiBDYW4gYmUgdXNlZCB0byByZXBsYWNlIHRoZSB0cmFuc3BvcnQgdXNlZCBieSB0aGUgdW5kZXJseWluZyBQaG9lbml4IFNvY2tldC5cbiAgICovXG4gIHJlcGxhY2VUcmFuc3BvcnQodHJhbnNwb3J0OiBhbnkpOiB2b2lkO1xuICAvKipcbiAgICogRXhlY3V0ZXMgYW4gZW5jb2RlZCBKUyBjb21tYW5kLCB0YXJnZXRpbmcgdGhlIGdpdmVuIGVsZW1lbnQuXG4gICAqXG4gICAqIFNlZSBbYFBob2VuaXguTGl2ZVZpZXcuSlNgXShodHRwczovL2hleGRvY3MucG0vcGhvZW5peF9saXZlX3ZpZXcvUGhvZW5peC5MaXZlVmlldy5KUy5odG1sKSBmb3IgbW9yZSBpbmZvcm1hdGlvbi5cbiAgICovXG4gIGV4ZWNKUyhlbDogSFRNTEVsZW1lbnQsIGVuY29kZWRKUzogc3RyaW5nLCBldmVudFR5cGU/OiBzdHJpbmcgfCBudWxsKTogdm9pZDtcbiAgLyoqXG4gICAqIFJldHVybnMgYW4gb2JqZWN0IHdpdGggbWV0aG9kcyB0byBtYW5pcGx1YXRlIHRoZSBET00gYW5kIGV4ZWN1dGUgSmF2YVNjcmlwdC5cbiAgICogVGhlIGFwcGxpZWQgY2hhbmdlcyBpbnRlZ3JhdGUgd2l0aCBzZXJ2ZXIgRE9NIHBhdGNoaW5nLlxuICAgKlxuICAgKiBTZWUgW0phdmFTY3JpcHQgaW50ZXJvcGVyYWJpbGl0eV0oaHR0cHM6Ly9oZXhkb2NzLnBtL3Bob2VuaXhfbGl2ZV92aWV3L2pzLWludGVyb3AuaHRtbCkgZm9yIG1vcmUgaW5mb3JtYXRpb24uXG4gICAqL1xuICBqcygpOiBMaXZlU29ja2V0SlNDb21tYW5kcztcbn1cblxuLyoqXG4gKiBJbnRlcmZhY2UgZGVzY3JpYmluZyB0aGUgTGl2ZVNvY2tldCBjb25zdHJ1Y3Rvci5cbiAqL1xuZXhwb3J0IGludGVyZmFjZSBMaXZlU29ja2V0Q29uc3RydWN0b3Ige1xuICAvKipcbiAgICogQ3JlYXRlcyBhIG5ldyBMaXZlU29ja2V0IGluc3RhbmNlLlxuICAgKlxuICAgKiBAcGFyYW0gZW5kcG9pbnQgLSBUaGUgc3RyaW5nIFdlYlNvY2tldCBlbmRwb2ludCwgaWUsIGBcIndzczovL2V4YW1wbGUuY29tL2xpdmVcImAsXG4gICAqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBgXCIvbGl2ZVwiYCAoaW5oZXJpdGVkIGhvc3QgJiBwcm90b2NvbClcbiAgICogQHBhcmFtIHNvY2tldCAtIHRoZSByZXF1aXJlZCBQaG9lbml4IFNvY2tldCBjbGFzcyBpbXBvcnRlZCBmcm9tIFwicGhvZW5peFwiLiBGb3IgZXhhbXBsZTpcbiAgICpcbiAgICogICAgIGltcG9ydCB7U29ja2V0fSBmcm9tIFwicGhvZW5peFwiXG4gICAqICAgICBpbXBvcnQge0xpdmVTb2NrZXR9IGZyb20gXCJwaG9lbml4X2xpdmVfdmlld1wiXG4gICAqICAgICBsZXQgbGl2ZVNvY2tldCA9IG5ldyBMaXZlU29ja2V0KFwiL2xpdmVcIiwgU29ja2V0LCB7Li4ufSlcbiAgICpcbiAgICogQHBhcmFtIG9wdHMgLSBPcHRpb25hbCBjb25maWd1cmF0aW9uLlxuICAgKi9cbiAgbmV3IChcbiAgICBlbmRwb2ludDogc3RyaW5nLFxuICAgIHNvY2tldDogdHlwZW9mIFBob2VuaXhTb2NrZXQsXG4gICAgb3B0cz86IExpdmVTb2NrZXRPcHRpb25zLFxuICApOiBMaXZlU29ja2V0SW5zdGFuY2VJbnRlcmZhY2U7XG59XG5cbi8vIGJlY2F1c2UgTGl2ZVNvY2tldCBpcyBpbiBKUyAoZm9yIG5vdyksIHdlIGNhc3QgaXQgdG8gb3VyIGRlZmluZWQgVHlwZVNjcmlwdCBjb25zdHJ1Y3Rvci5cbmNvbnN0IExpdmVTb2NrZXQgPSBPcmlnaW5hbExpdmVTb2NrZXQgYXMgdW5rbm93biBhcyBMaXZlU29ja2V0Q29uc3RydWN0b3I7XG5cbi8qKiBDcmVhdGVzIGEgaG9vayBpbnN0YW5jZSBmb3IgdGhlIGdpdmVuIGVsZW1lbnQgYW5kIGNhbGxiYWNrcy5cbiAqXG4gKiBAcGFyYW0gZWwgLSBUaGUgZWxlbWVudCB0byBhc3NvY2lhdGUgd2l0aCB0aGUgaG9vay5cbiAqIEBwYXJhbSBjYWxsYmFja3MgLSBUaGUgbGlzdCBvZiBob29rIGNhbGxiYWNrcywgc3VjaCBhcyBtb3VudGVkLFxuICogICB1cGRhdGVkLCBkZXN0cm95ZWQsIGV0Yy5cbiAqXG4gKiAqTm90ZSo6IGBjcmVhdGVIb29rYCBtdXN0IGJlIGNhbGxlZCBmcm9tIHRoZSBgY29ubmVjdGVkQ2FsbGJhY2tgIGxpZmVjeWNsZVxuICogd2hpY2ggaXMgdHJpZ2dlcmVkIGFmdGVyIHRoZSBlbGVtZW50IGhhcyBiZWVuIGFkZGVkIHRvIHRoZSBET00uIElmIHlvdSB0cnlcbiAqIHRvIGNhbGwgYGNyZWF0ZUhvb2tgIGZyb20gdGhlIGNvbnN0cnVjdG9yLCBhbiBlcnJvciB3aWxsIGJlIGxvZ2dlZC5cbiAqXG4gKiBAZXhhbXBsZVxuICpcbiAqIGNsYXNzIE15Q29tcG9uZW50IGV4dGVuZHMgSFRNTEVsZW1lbnQge1xuICogICBjb25uZWN0ZWRDYWxsYmFjaygpe1xuICogICAgIGxldCBvbkxpdmVWaWV3TW91bnRlZCA9ICgpID0+IHRoaXMuaG9vay5wdXNoRXZlbnQoLi4uKSlcbiAqICAgICB0aGlzLmhvb2sgPSBjcmVhdGVIb29rKHRoaXMsIHttb3VudGVkOiBvbkxpdmVWaWV3TW91bnRlZH0pXG4gKiAgIH1cbiAqIH1cbiAqXG4gKiBAcmV0dXJucyBSZXR1cm5zIHRoZSBIb29rIGluc3RhbmNlIGZvciB0aGUgY3VzdG9tIGVsZW1lbnQuXG4gKi9cbmZ1bmN0aW9uIGNyZWF0ZUhvb2soZWw6IEhUTUxFbGVtZW50LCBjYWxsYmFja3M6IEhvb2spOiBWaWV3SG9vayB7XG4gIGxldCBleGlzdGluZ0hvb2sgPSBET00uZ2V0Q3VzdG9tRWxIb29rKGVsKTtcbiAgaWYgKGV4aXN0aW5nSG9vaykge1xuICAgIHJldHVybiBleGlzdGluZ0hvb2s7XG4gIH1cblxuICBsZXQgaG9vayA9IG5ldyBWaWV3SG9vayhWaWV3LmNsb3Nlc3RWaWV3KGVsKSwgZWwsIGNhbGxiYWNrcyk7XG4gIERPTS5wdXRDdXN0b21FbEhvb2soZWwsIGhvb2spO1xuICByZXR1cm4gaG9vaztcbn1cblxuZXhwb3J0IHsgTGl2ZVNvY2tldCwgaXNVc2VkSW5wdXQsIGNyZWF0ZUhvb2ssIFZpZXdIb29rLCBIb29rLCBIb29rc09wdGlvbnMgfTtcbiIsICIvLyBJbmNsdWRlIHBob2VuaXhfaHRtbCB0byBoYW5kbGUgbWV0aG9kPVBVVC9ERUxFVEUgaW4gZm9ybXMgYW5kIGJ1dHRvbnMuXG5pbXBvcnQgXCJwaG9lbml4X2h0bWxcIjtcbi8vIEVzdGFibGlzaCBQaG9lbml4IFNvY2tldCBhbmQgTGl2ZVZpZXcgY29uZmlndXJhdGlvbi5cbmltcG9ydCB7IFNvY2tldCB9IGZyb20gXCJwaG9lbml4XCI7XG5pbXBvcnQgeyBMaXZlU29ja2V0IH0gZnJvbSBcInBob2VuaXhfbGl2ZV92aWV3XCI7XG5cbi8vIENvbGxhcHNpYmxlIFNlY3Rpb24gSG9va1xuY29uc3QgQ29sbGFwc2libGVTZWN0aW9uID0ge1xuICBtb3VudGVkKCkge1xuICAgIHRoaXMuaXNPcGVuID0gdHJ1ZTsgLy8gU3RhcnQgb3BlbiBieSBkZWZhdWx0XG4gICAgdGhpcy5idXR0b24gPSB0aGlzLmVsLnF1ZXJ5U2VsZWN0b3IoXCJidXR0b25cIik7XG4gICAgdGhpcy5jb250ZW50Q29udGFpbmVyID0gdGhpcy5lbC5jaGlsZHJlblsxXTsgLy8gVGhlIGRpdiBhZnRlciB0aGUgYnV0dG9uXG4gICAgdGhpcy5wcmV2aWV3RGl2ID0gdGhpcy5jb250ZW50Q29udGFpbmVyLmNoaWxkcmVuWzBdOyAvLyBGaXJzdCBjaGlsZDogcHJldmlld1xuICAgIHRoaXMuZnVsbENvbnRlbnREaXYgPSB0aGlzLmNvbnRlbnRDb250YWluZXIuY2hpbGRyZW5bMV07IC8vIFNlY29uZCBjaGlsZDogZnVsbCBjb250ZW50XG4gICAgdGhpcy5hcnJvdyA9IHRoaXMuYnV0dG9uLnF1ZXJ5U2VsZWN0b3IoXCJzdmdcIikucGFyZW50RWxlbWVudDtcblxuICAgIHRoaXMuYnV0dG9uLmFkZEV2ZW50TGlzdGVuZXIoXCJjbGlja1wiLCAoKSA9PiB0aGlzLnRvZ2dsZSgpKTtcbiAgICBcbiAgICAvLyBJbml0aWFsaXplIGluIG9wZW4gc3RhdGVcbiAgICB0aGlzLmV4cGFuZCgpO1xuICB9LFxuXG4gIHRvZ2dsZSgpIHtcbiAgICB0aGlzLmlzT3BlbiA9ICF0aGlzLmlzT3BlbjtcblxuICAgIGlmICh0aGlzLmlzT3Blbikge1xuICAgICAgdGhpcy5leHBhbmQoKTtcbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy5jb2xsYXBzZSgpO1xuICAgIH1cbiAgfSxcblxuICBleHBhbmQoKSB7XG4gICAgdGhpcy5jb250ZW50Q29udGFpbmVyLnN0eWxlLmhlaWdodCA9IFwiYXV0b1wiO1xuICAgIHRoaXMuY29udGVudENvbnRhaW5lci5zdHlsZS5taW5IZWlnaHQgPSBcIjI0cmVtXCI7IC8vIG1pbi1oLTk2XG4gICAgdGhpcy5wcmV2aWV3RGl2LnN0eWxlLmRpc3BsYXkgPSBcIm5vbmVcIjtcbiAgICB0aGlzLmZ1bGxDb250ZW50RGl2LnN0eWxlLmRpc3BsYXkgPSBcImJsb2NrXCI7XG4gICAgdGhpcy5hcnJvdy5zdHlsZS50cmFuc2Zvcm0gPSBcInJvdGF0ZSgxODBkZWcpXCI7XG4gIH0sXG5cbiAgY29sbGFwc2UoKSB7XG4gICAgdGhpcy5jb250ZW50Q29udGFpbmVyLnN0eWxlLmhlaWdodCA9IFwiM3JlbVwiOyAvLyBoLTEyXG4gICAgdGhpcy5jb250ZW50Q29udGFpbmVyLnN0eWxlLm1pbkhlaWdodCA9IFwiYXV0b1wiO1xuICAgIHRoaXMucHJldmlld0Rpdi5zdHlsZS5kaXNwbGF5ID0gXCJibG9ja1wiO1xuICAgIHRoaXMuZnVsbENvbnRlbnREaXYuc3R5bGUuZGlzcGxheSA9IFwibm9uZVwiO1xuICAgIHRoaXMuYXJyb3cuc3R5bGUudHJhbnNmb3JtID0gXCJyb3RhdGUoMGRlZylcIjtcbiAgfSxcbn07XG5cbmxldCBjc3JmVG9rZW4gPSBkb2N1bWVudFxuICAucXVlcnlTZWxlY3RvcihcIm1ldGFbbmFtZT0nY3NyZi10b2tlbiddXCIpXG4gIC5nZXRBdHRyaWJ1dGUoXCJjb250ZW50XCIpO1xubGV0IGxpdmVTb2NrZXQgPSBuZXcgTGl2ZVNvY2tldChcIi9saXZlXCIsIFNvY2tldCwge1xuICBsb25nUG9sbEZhbGxiYWNrTXM6IDI1MDAsXG4gIHBhcmFtczogeyBfY3NyZl90b2tlbjogY3NyZlRva2VuIH0sXG4gIGhvb2tzOiB7XG4gICAgQ29sbGFwc2libGVTZWN0aW9uLFxuICB9LFxufSk7XG5cbi8vIGNvbm5lY3QgaWYgdGhlcmUgYXJlIGFueSBMaXZlVmlld3Mgb24gdGhlIHBhZ2VcbmxpdmVTb2NrZXQuY29ubmVjdCgpO1xuXG4vLyBleHBvc2UgbGl2ZVNvY2tldCBvbiB3aW5kb3cgZm9yIHdlYiBjb25zb2xlIGRlYnVnIGxvZ3MgYW5kIGxhdGVuY3kgc2ltdWxhdGlvbjpcbi8vID4+IGxpdmVTb2NrZXQuZW5hYmxlRGVidWcoKVxuLy8gPj4gbGl2ZVNvY2tldC5lbmFibGVMYXRlbmN5U2ltKDEwMDApICAvLyBlbmFibGVkIGZvciBkdXJhdGlvbiBvZiBicm93c2VyIHNlc3Npb25cbi8vID4+IGxpdmVTb2NrZXQuZGlzYWJsZUxhdGVuY3lTaW0oKVxud2luZG93LmxpdmVTb2NrZXQgPSBsaXZlU29ja2V0O1xuIl0sCiAgIm1hcHBpbmdzIjogIjs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7OztBQUVBLEdBQUMsV0FBVztBQUNWLFFBQUksZ0JBQWdCLGlCQUFpQjtBQUVyQyxhQUFTLG1CQUFtQjtBQUMxQixVQUFJLE9BQU8sT0FBTyxnQkFBZ0I7QUFBWSxlQUFPLE9BQU87QUFFNUQsZUFBU0EsYUFBWSxPQUFPLFFBQVE7QUFDbEMsaUJBQVMsVUFBVSxFQUFDLFNBQVMsT0FBTyxZQUFZLE9BQU8sUUFBUSxPQUFTO0FBQ3hFLFlBQUksTUFBTSxTQUFTLFlBQVksYUFBYTtBQUM1QyxZQUFJLGdCQUFnQixPQUFPLE9BQU8sU0FBUyxPQUFPLFlBQVksT0FBTyxNQUFNO0FBQzNFLGVBQU87QUFBQSxNQUNUO0FBQ0EsTUFBQUEsYUFBWSxZQUFZLE9BQU8sTUFBTTtBQUNyQyxhQUFPQTtBQUFBLElBQ1Q7QUFFQSxhQUFTLGlCQUFpQixNQUFNLE9BQU87QUFDckMsVUFBSSxRQUFRLFNBQVMsY0FBYyxPQUFPO0FBQzFDLFlBQU0sT0FBTztBQUNiLFlBQU0sT0FBTztBQUNiLFlBQU0sUUFBUTtBQUNkLGFBQU87QUFBQSxJQUNUO0FBRUEsYUFBUyxZQUFZLFNBQVMsbUJBQW1CO0FBQy9DLFVBQUksS0FBSyxRQUFRLGFBQWEsU0FBUyxHQUNuQyxTQUFTLGlCQUFpQixXQUFXLFFBQVEsYUFBYSxhQUFhLENBQUMsR0FDeEUsT0FBTyxpQkFBaUIsZUFBZSxRQUFRLGFBQWEsV0FBVyxDQUFDLEdBQ3hFLE9BQU8sU0FBUyxjQUFjLE1BQU0sR0FDcEMsU0FBUyxTQUFTLGNBQWMsT0FBTyxHQUN2QyxTQUFTLFFBQVEsYUFBYSxRQUFRO0FBRTFDLFdBQUssU0FBVSxRQUFR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QUssTUFBTSxNQUFNLFlBQVk7QUFBQSxJQUMvQjtBQUFBLEVBQ0Y7QUFFQSxNQUFJLFlBQVksU0FDYixjQUFjLHlCQUF5QixFQUN2QyxhQUFhLFNBQVM7QUFDekIsTUFBSSxhQUFhLElBQUksWUFBVyxTQUFTLFFBQVE7QUFBQSxJQUMvQyxvQkFBb0I7QUFBQSxJQUNwQixRQUFRLEVBQUUsYUFBYSxVQUFVO0FBQUEsSUFDakMsT0FBTztBQUFBLE1BQ0w7QUFBQSxJQUNGO0FBQUEsRUFDRixDQUFDO0FBR0QsYUFBVyxRQUFRO0FBTW5CLFNBQU8sYUFBYTsiLAogICJuYW1lcyI6IFsiQ3VzdG9tRXZlbnQiLCAiY2xvc3VyZSIsICJsaXZlU29ja2V0IiwgImNsb3N1cmUiLCAiZG9jIiwgImUiLCAiaXNFbXB0eSIsICJmaWxlIiwgIm1vcnBoQXR0cnMiLCAibW9ycGhkb20iLCAiY2hpbGRyZW5Pbmx5IiwgInRhcmdldENvbnRhaW5lciIsICJjbG9uZSIsICJlbCIsICJpbnB1dHNVbnVzZWQiLCAib25seUhpZGRlbklucHV0cyIsICJsb2NrIiwgImxvYWRpbmciLCAiZW50cnkiLCAiaW5wdXQiLCAiY2xvc3VyZSIsICJMaXZlU29ja2V0Il0KfQo=
