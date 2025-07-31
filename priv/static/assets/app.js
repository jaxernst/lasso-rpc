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
  var __objRest = (source, exclude) => {
    var target = {};
    for (var prop in source)
      if (__hasOwnProp.call(source, prop) && exclude.indexOf(prop) < 0)
        target[prop] = source[prop];
    if (source != null && __getOwnPropSymbols)
      for (var prop of __getOwnPropSymbols(source)) {
        if (exclude.indexOf(prop) < 0 && __propIsEnum.call(source, prop))
          target[prop] = source[prop];
      }
    return target;
  };

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
        if (element.getAttribute("data-method")) {
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
  var global = globalSelf || phxWindow || global;
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
    static request(method, endPoint, accept, body, timeout, ontimeout, callback) {
      if (global.XDomainRequest) {
        let req = new global.XDomainRequest();
        return this.xdomainRequest(req, method, endPoint, body, timeout, ontimeout, callback);
      } else {
        let req = new global.XMLHttpRequest();
        return this.xhrRequest(req, method, endPoint, accept, body, timeout, ontimeout, callback);
      }
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
    static xhrRequest(req, method, endPoint, accept, body, timeout, ontimeout, callback) {
      req.open(method, endPoint, true);
      req.timeout = timeout;
      req.setRequestHeader("Content-Type", accept);
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
    constructor(endPoint) {
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
      this.ajax("GET", "application/json", null, () => this.ontimeout(), (resp) => {
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
      this.ajax("POST", "application/x-ndjson", messages.join("\n"), () => this.onerror("timeout"), (resp) => {
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
    ajax(method, contentType, body, onCallerTimeout, callback) {
      let req;
      let ontimeout = () => {
        this.reqs.delete(req);
        onCallerTimeout();
      };
      req = Ajax.request(method, this.endpointURL(), contentType, body, this.timeout, ontimeout, (resp) => {
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
      this.conn = new this.transport(this.endPointURL());
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
  var PHX_LIVE_LINK = "data-phx-link";
  var PHX_TRACK_STATIC = "track-static";
  var PHX_LINK_STATE = "data-phx-link-state";
  var PHX_REF = "data-phx-ref";
  var PHX_REF_SRC = "data-phx-ref-src";
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
  var PHX_PAGE_LOADING = "page-loading";
  var PHX_CONNECTED_CLASS = "phx-connected";
  var PHX_LOADING_CLASS = "phx-loading";
  var PHX_NO_FEEDBACK_CLASS = "phx-no-feedback";
  var PHX_ERROR_CLASS = "phx-error";
  var PHX_CLIENT_ERROR_CLASS = "phx-client-error";
  var PHX_SERVER_ERROR_CLASS = "phx-server-error";
  var PHX_PARENT_ID = "data-phx-parent-id";
  var PHX_MAIN = "data-phx-main";
  var PHX_ROOT_ID = "data-phx-root-id";
  var PHX_VIEWPORT_TOP = "viewport-top";
  var PHX_VIEWPORT_BOTTOM = "viewport-bottom";
  var PHX_TRIGGER_ACTION = "trigger-action";
  var PHX_FEEDBACK_FOR = "feedback-for";
  var PHX_FEEDBACK_GROUP = "feedback-group";
  var PHX_HAS_FOCUSED = "phx-has-focused";
  var FOCUSABLE_INPUTS = ["text", "textarea", "number", "email", "password", "search", "tel", "url", "date", "time", "datetime-local", "color", "range"];
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
  var PHX_KEY = "key";
  var PHX_PRIVATE = "phxPrivate";
  var PHX_AUTO_RECOVER = "auto-recover";
  var PHX_LV_DEBUG = "phx:live-socket:debug";
  var PHX_LV_PROFILE = "phx:live-socket:profiling";
  var PHX_LV_LATENCY_SIM = "phx:live-socket:latency-sim";
  var PHX_PROGRESS = "progress";
  var PHX_MOUNTED = "mounted";
  var LOADER_TIMEOUT = 1;
  var BEFORE_UNLOAD_LOADER_TIMEOUT = 200;
  var BINDING_PREFIX = "phx-";
  var PUSH_TIMEOUT = 3e4;
  var DEBOUNCE_TRIGGER = "debounce-trigger";
  var THROTTLED = "throttled";
  var DEBOUNCE_PREV_KEY = "debounce-prev-key";
  var DEFAULTS = {
    debounce: 300,
    throttle: 300
  };
  var DYNAMICS = "d";
  var STATIC = "s";
  var ROOT = "r";
  var COMPONENTS = "c";
  var EVENTS = "e";
  var REPLY = "r";
  var TITLE = "t";
  var TEMPLATES = "p";
  var STREAM = "stream";
  var EntryUploader = class {
    constructor(entry, chunkSize, liveSocket2) {
      this.liveSocket = liveSocket2;
      this.entry = entry;
      this.offset = 0;
      this.chunkSize = chunkSize;
      this.chunkTimer = null;
      this.errored = false;
      this.uploadChannel = liveSocket2.channel(`lvu:${entry.ref}`, { token: entry.metadata() });
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
      let reader = new window.FileReader();
      let blob = this.entry.file.slice(this.offset, this.chunkSize + this.offset);
      reader.onload = (e) => {
        if (e.target.error === null) {
          this.offset += e.target.result.byteLength;
          this.pushChunk(e.target.result);
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
      this.uploadChannel.push("chunk", chunk).receive("ok", () => {
        this.entry.progress(this.offset / this.entry.file.size * 100);
        if (!this.isDone()) {
          this.chunkTimer = setTimeout(() => this.readNextChunk(), this.liveSocket.getLatencySim() || 0);
        }
      }).receive("error", ({ reason }) => this.error(reason));
    }
  };
  var logError = (msg, obj) => console.error && console.error(msg, obj);
  var isCid = (cid) => {
    let type = typeof cid;
    return type === "number" || type === "string" && /^(0|[1-9]\d*)$/.test(cid);
  };
  function detectDuplicateIds() {
    let ids = /* @__PURE__ */ new Set();
    let elems = document.querySelectorAll("*[id]");
    for (let i = 0, len = elems.length; i < len; i++) {
      if (ids.has(elems[i].id)) {
        console.error(`Multiple IDs detected: ${elems[i].id}. Ensure unique element ids.`);
      } else {
        ids.add(elems[i].id);
      }
    }
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
    for (let x in obj) {
      return false;
    }
    return true;
  };
  var maybe = (el, callback) => el && callback(el);
  var channelUploader = function(entries, onError, resp, liveSocket2) {
    entries.forEach((entry) => {
      let entryUploader = new EntryUploader(entry, resp.config.chunk_size, liveSocket2);
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
      let current = this.getLocal(localStorage, namespace, subkey);
      let key = this.localKey(namespace, subkey);
      let newVal = current === null ? initial : func(current);
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
      history.replaceState(callback(history.state || {}), "", window.location.href);
    },
    pushState(kind, meta, to) {
      if (this.canPushState()) {
        if (to !== window.location.href) {
          if (meta.type == "redirect" && meta.scroll) {
            let currentState = history.state || {};
            currentState.scroll = meta.scroll;
            history.replaceState(currentState, "", window.location.href);
          }
          delete meta.scroll;
          history[kind + "State"](meta, "", to || null);
          let hashEl = this.getHashTargetEl(window.location.hash);
          if (hashEl) {
            hashEl.scrollIntoView();
          } else if (meta.type === "redirect") {
            window.scroll(0, 0);
          }
        }
      } else {
        this.redirect(to);
      }
    },
    setCookie(name, value) {
      document.cookie = `${name}=${value}`;
    },
    getCookie(name) {
      return document.cookie.replace(new RegExp(`(?:(?:^|.*;s*)${name}s*=s*([^;]*).*$)|^.*$`), "$1");
    },
    redirect(toURL, flash) {
      if (flash) {
        Browser.setCookie("__phoenix_flash__", flash + "; max-age=60000; path=/");
      }
      window.location = toURL;
    },
    localKey(namespace, subkey) {
      return `${namespace}-${subkey}`;
    },
    getHashTargetEl(maybeHash) {
      let hash = maybeHash.toString().substring(1);
      if (hash === "") {
        return;
      }
      return document.getElementById(hash) || document.querySelector(`a[name="${hash}"]`);
    }
  };
  var browser_default = Browser;
  var ARIA = {
    focusMain() {
      let target = document.querySelector("main h1, main, h1");
      if (target) {
        let origTabIndex = target.tabIndex;
        target.tabIndex = -1;
        target.focus();
        target.tabIndex = origTabIndex;
      }
    },
    anyOf(instance, classes) {
      return classes.find((name) => instance instanceof name);
    },
    isFocusable(el, interactiveOnly) {
      return el instanceof HTMLAnchorElement && el.rel !== "ignore" || el instanceof HTMLAreaElement && el.href !== void 0 || !el.disabled && this.anyOf(el, [HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, HTMLButtonElement]) || el instanceof HTMLIFrameElement || (el.tabIndex > 0 || !interactiveOnly && el.getAttribute("tabindex") !== null && el.getAttribute("aria-hidden") !== "true");
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
        if (this.attemptFocus(child, true) || this.focusFirstInteractive(child, true)) {
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
  var focusStack = [];
  var default_transition_time = 200;
  var JS = {
    exec(eventType, phxEvent, view, sourceEl, defaults) {
      let [defaultKind, defaultArgs] = defaults || [null, { callback: defaults && defaults.callback }];
      let commands = phxEvent.charAt(0) === "[" ? JSON.parse(phxEvent) : [[defaultKind, defaultArgs]];
      commands.forEach(([kind, args]) => {
        if (kind === defaultKind && defaultArgs.data) {
          args.data = Object.assign(args.data || {}, defaultArgs.data);
          args.callback = args.callback || defaultArgs.callback;
        }
        this.filterToEls(sourceEl, args).forEach((el) => {
          this[`exec_${kind}`](eventType, phxEvent, view, sourceEl, el, args);
        });
      });
    },
    isVisible(el) {
      return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length > 0);
    },
    isInViewport(el) {
      const rect = el.getBoundingClientRect();
      const windowHeight = window.innerHeight || document.documentElement.clientHeight;
      const windowWidth = window.innerWidth || document.documentElement.clientWidth;
      return rect.right > 0 && rect.bottom > 0 && rect.left < windowWidth && rect.top < windowHeight;
    },
    exec_exec(eventType, phxEvent, view, sourceEl, el, { attr, to }) {
      let nodes = to ? dom_default.all(document, to) : [sourceEl];
      nodes.forEach((node) => {
        let encodedJS = node.getAttribute(attr);
        if (!encodedJS) {
          throw new Error(`expected ${attr} to contain JS command on "${to}"`);
        }
        view.liveSocket.execJS(node, encodedJS, eventType);
      });
    },
    exec_dispatch(eventType, phxEvent, view, sourceEl, el, { to, event, detail, bubbles }) {
      detail = detail || {};
      detail.dispatcher = sourceEl;
      dom_default.dispatchEvent(el, event, { detail, bubbles });
    },
    exec_push(eventType, phxEvent, view, sourceEl, el, args) {
      let { event, data, target, page_loading, loading, value, dispatcher, callback } = args;
      let pushOpts = { loading, value, target, page_loading: !!page_loading };
      let targetSrc = eventType === "change" && dispatcher ? dispatcher : sourceEl;
      let phxTarget = target || targetSrc.getAttribute(view.binding("target")) || targetSrc;
      view.withinTargets(phxTarget, (targetView, targetCtx) => {
        if (!targetView.isConnected()) {
          return;
        }
        if (eventType === "change") {
          let { newCid, _target } = args;
          _target = _target || (dom_default.isFormInput(sourceEl) ? sourceEl.name : void 0);
          if (_target) {
            pushOpts._target = _target;
          }
          targetView.pushInput(sourceEl, targetCtx, newCid, event || phxEvent, pushOpts, callback);
        } else if (eventType === "submit") {
          let { submitter } = args;
          targetView.submitForm(sourceEl, targetCtx, event || phxEvent, submitter, pushOpts, callback);
        } else {
          targetView.pushEvent(eventType, sourceEl, targetCtx, event || phxEvent, data, pushOpts, callback);
        }
      });
    },
    exec_navigate(eventType, phxEvent, view, sourceEl, el, { href, replace }) {
      view.liveSocket.historyRedirect(href, replace ? "replace" : "push");
    },
    exec_patch(eventType, phxEvent, view, sourceEl, el, { href, replace }) {
      view.liveSocket.pushHistoryPatch(href, replace ? "replace" : "push", sourceEl);
    },
    exec_focus(eventType, phxEvent, view, sourceEl, el) {
      window.requestAnimationFrame(() => aria_default.attemptFocus(el));
    },
    exec_focus_first(eventType, phxEvent, view, sourceEl, el) {
      window.requestAnimationFrame(() => aria_default.focusFirstInteractive(el) || aria_default.focusFirst(el));
    },
    exec_push_focus(eventType, phxEvent, view, sourceEl, el) {
      window.requestAnimationFrame(() => focusStack.push(el || sourceEl));
    },
    exec_pop_focus(eventType, phxEvent, view, sourceEl, el) {
      window.requestAnimationFrame(() => {
        const el2 = focusStack.pop();
        if (el2) {
          el2.focus();
        }
      });
    },
    exec_add_class(eventType, phxEvent, view, sourceEl, el, { names, transition, time }) {
      this.addOrRemoveClasses(el, names, [], transition, time, view);
    },
    exec_remove_class(eventType, phxEvent, view, sourceEl, el, { names, transition, time }) {
      this.addOrRemoveClasses(el, [], names, transition, time, view);
    },
    exec_toggle_class(eventType, phxEvent, view, sourceEl, el, { to, names, transition, time }) {
      this.toggleClasses(el, names, transition, time, view);
    },
    exec_toggle_attr(eventType, phxEvent, view, sourceEl, el, { attr: [attr, val1, val2] }) {
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
    exec_transition(eventType, phxEvent, view, sourceEl, el, { time, transition }) {
      this.addOrRemoveClasses(el, [], [], transition, time, view);
    },
    exec_toggle(eventType, phxEvent, view, sourceEl, el, { display, ins, outs, time }) {
      this.toggle(eventType, view, el, display, ins, outs, time);
    },
    exec_show(eventType, phxEvent, view, sourceEl, el, { display, transition, time }) {
      this.show(eventType, view, el, display, transition, time);
    },
    exec_hide(eventType, phxEvent, view, sourceEl, el, { display, transition, time }) {
      this.hide(eventType, view, el, display, transition, time);
    },
    exec_set_attr(eventType, phxEvent, view, sourceEl, el, { attr: [attr, val] }) {
      this.setOrRemoveAttrs(el, [[attr, val]], []);
    },
    exec_remove_attr(eventType, phxEvent, view, sourceEl, el, { attr }) {
      this.setOrRemoveAttrs(el, [], [attr]);
    },
    show(eventType, view, el, display, transition, time) {
      if (!this.isVisible(el)) {
        this.toggle(eventType, view, el, display, transition, null, time);
      }
    },
    hide(eventType, view, el, display, transition, time) {
      if (this.isVisible(el)) {
        this.toggle(eventType, view, el, display, null, transition, time);
      }
    },
    toggle(eventType, view, el, display, ins, outs, time) {
      time = time || default_transition_time;
      let [inClasses, inStartClasses, inEndClasses] = ins || [[], [], []];
      let [outClasses, outStartClasses, outEndClasses] = outs || [[], [], []];
      if (inClasses.length > 0 || outClasses.length > 0) {
        if (this.isVisible(el)) {
          let onStart = () => {
            this.addOrRemoveClasses(el, outStartClasses, inClasses.concat(inStartClasses).concat(inEndClasses));
            window.requestAnimationFrame(() => {
              this.addOrRemoveClasses(el, outClasses, []);
              window.requestAnimationFrame(() => this.addOrRemoveClasses(el, outEndClasses, outStartClasses));
            });
          };
          el.dispatchEvent(new Event("phx:hide-start"));
          view.transition(time, onStart, () => {
            this.addOrRemoveClasses(el, [], outClasses.concat(outEndClasses));
            dom_default.putSticky(el, "toggle", (currentEl) => currentEl.style.display = "none");
            el.dispatchEvent(new Event("phx:hide-end"));
          });
        } else {
          if (eventType === "remove") {
            return;
          }
          let onStart = () => {
            this.addOrRemoveClasses(el, inStartClasses, outClasses.concat(outStartClasses).concat(outEndClasses));
            let stickyDisplay = display || this.defaultDisplay(el);
            dom_default.putSticky(el, "toggle", (currentEl) => currentEl.style.display = stickyDisplay);
            window.requestAnimationFrame(() => {
              this.addOrRemoveClasses(el, inClasses, []);
              window.requestAnimationFrame(() => this.addOrRemoveClasses(el, inEndClasses, inStartClasses));
            });
          };
          el.dispatchEvent(new Event("phx:show-start"));
          view.transition(time, onStart, () => {
            this.addOrRemoveClasses(el, [], inClasses.concat(inEndClasses));
            el.dispatchEvent(new Event("phx:show-end"));
          });
        }
      } else {
        if (this.isVisible(el)) {
          window.requestAnimationFrame(() => {
            el.dispatchEvent(new Event("phx:hide-start"));
            dom_default.putSticky(el, "toggle", (currentEl) => currentEl.style.display = "none");
            el.dispatchEvent(new Event("phx:hide-end"));
          });
        } else {
          window.requestAnimationFrame(() => {
            el.dispatchEvent(new Event("phx:show-start"));
            let stickyDisplay = display || this.defaultDisplay(el);
            dom_default.putSticky(el, "toggle", (currentEl) => currentEl.style.display = stickyDisplay);
            el.dispatchEvent(new Event("phx:show-end"));
          });
        }
      }
    },
    toggleClasses(el, classes, transition, time, view) {
      window.requestAnimationFrame(() => {
        let [prevAdds, prevRemoves] = dom_default.getSticky(el, "classes", [[], []]);
        let newAdds = classes.filter((name) => prevAdds.indexOf(name) < 0 && !el.classList.contains(name));
        let newRemoves = classes.filter((name) => prevRemoves.indexOf(name) < 0 && el.classList.contains(name));
        this.addOrRemoveClasses(el, newAdds, newRemoves, transition, time, view);
      });
    },
    addOrRemoveClasses(el, adds, removes, transition, time, view) {
      time = time || default_transition_time;
      let [transitionRun, transitionStart, transitionEnd] = transition || [[], [], []];
      if (transitionRun.length > 0) {
        let onStart = () => {
          this.addOrRemoveClasses(el, transitionStart, [].concat(transitionRun).concat(transitionEnd));
          window.requestAnimationFrame(() => {
            this.addOrRemoveClasses(el, transitionRun, []);
            window.requestAnimationFrame(() => this.addOrRemoveClasses(el, transitionEnd, transitionStart));
          });
        };
        let onDone = () => this.addOrRemoveClasses(el, adds.concat(transitionEnd), removes.concat(transitionRun).concat(transitionStart));
        return view.transition(time, onStart, onDone);
      }
      window.requestAnimationFrame(() => {
        let [prevAdds, prevRemoves] = dom_default.getSticky(el, "classes", [[], []]);
        let keepAdds = adds.filter((name) => prevAdds.indexOf(name) < 0 && !el.classList.contains(name));
        let keepRemoves = removes.filter((name) => prevRemoves.indexOf(name) < 0 && el.classList.contains(name));
        let newAdds = prevAdds.filter((name) => removes.indexOf(name) < 0).concat(keepAdds);
        let newRemoves = prevRemoves.filter((name) => adds.indexOf(name) < 0).concat(keepRemoves);
        dom_default.putSticky(el, "classes", (currentEl) => {
          currentEl.classList.remove(...newRemoves);
          currentEl.classList.add(...newAdds);
          return [newAdds, newRemoves];
        });
      });
    },
    setOrRemoveAttrs(el, sets, removes) {
      let [prevSets, prevRemoves] = dom_default.getSticky(el, "attrs", [[], []]);
      let alteredAttrs = sets.map(([attr, _val]) => attr).concat(removes);
      let newSets = prevSets.filter(([attr, _val]) => !alteredAttrs.includes(attr)).concat(sets);
      let newRemoves = prevRemoves.filter((attr) => !alteredAttrs.includes(attr)).concat(removes);
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
    filterToEls(sourceEl, { to }) {
      return to ? dom_default.all(document, to) : [sourceEl];
    },
    defaultDisplay(el) {
      return { tr: "table-row", td: "table-cell" }[el.tagName.toLowerCase()] || "block";
    }
  };
  var js_default = JS;
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
      let array = Array.from(node.querySelectorAll(query));
      return callback ? array.forEach(callback) : array;
    },
    childNodeLength(html) {
      let template = document.createElement("template");
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
      const inputsOutsideForm = this.all(document, `input[type="file"][${PHX_UPLOAD_REF}][form="${formId}"]`);
      return this.all(node, `input[type="file"][${PHX_UPLOAD_REF}]`).concat(inputsOutsideForm);
    },
    findComponentNodeList(node, cid) {
      return this.filterWithinSameLiveView(this.all(node, `[${PHX_COMPONENT}="${cid}"]`), node);
    },
    isPhxDestroyed(node) {
      return node.id && DOM.private(node, "destroyed") ? true : false;
    },
    wantsNewTab(e) {
      let wantsNewTab = e.ctrlKey || e.shiftKey || e.metaKey || e.button && e.button === 1;
      let isDownload = e.target instanceof HTMLAnchorElement && e.target.hasAttribute("download");
      let isTargetBlank = e.target.hasAttribute("target") && e.target.getAttribute("target").toLowerCase() === "_blank";
      let isTargetNamedTab = e.target.hasAttribute("target") && !e.target.getAttribute("target").startsWith("_");
      return wantsNewTab || isTargetBlank || isDownload || isTargetNamedTab;
    },
    isUnloadableFormSubmit(e) {
      let isDialogSubmit = e.target && e.target.getAttribute("method") === "dialog" || e.submitter && e.submitter.getAttribute("formmethod") === "dialog";
      if (isDialogSubmit) {
        return false;
      } else {
        return !e.defaultPrevented && !this.wantsNewTab(e);
      }
    },
    isNewPageClick(e, currentLocation) {
      let href = e.target instanceof HTMLAnchorElement ? e.target.getAttribute("href") : null;
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
      let template = document.createElement("template");
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
    findExistingParentCIDs(node, cids) {
      let parentCids = /* @__PURE__ */ new Set();
      let childrenCids = /* @__PURE__ */ new Set();
      cids.forEach((cid) => {
        this.filterWithinSameLiveView(this.all(node, `[${PHX_COMPONENT}="${cid}"]`), node).forEach((parent) => {
          parentCids.add(cid);
          this.all(parent, `[${PHX_COMPONENT}]`).map((el) => parseInt(el.getAttribute(PHX_COMPONENT))).forEach((childCID) => childrenCids.add(childCID));
        });
      });
      childrenCids.forEach((childCid) => parentCids.delete(childCid));
      return parentCids;
    },
    filterWithinSameLiveView(nodes, parent) {
      if (parent.querySelector(PHX_VIEW_SELECTOR)) {
        return nodes.filter((el) => this.withinSameLiveView(el, parent));
      } else {
        return nodes;
      }
    },
    withinSameLiveView(node, parent) {
      while (node = node.parentNode) {
        if (node.isSameNode(parent)) {
          return true;
        }
        if (node.getAttribute(PHX_SESSION) !== null) {
          return false;
        }
      }
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
      let existing = this.private(el, key);
      if (existing === void 0) {
        this.putPrivate(el, key, updateFunc(defaultVal));
      } else {
        this.putPrivate(el, key, updateFunc(existing));
      }
    },
    copyPrivates(target, source) {
      if (source[PHX_PRIVATE]) {
        target[PHX_PRIVATE] = source[PHX_PRIVATE];
      }
    },
    putTitle(str) {
      let titleEl = document.querySelector("title");
      if (titleEl) {
        let { prefix, suffix } = titleEl.dataset;
        document.title = `${prefix || ""}${str}${suffix || ""}`;
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
      let value = debounce || throttle;
      switch (value) {
        case null:
          return callback();
        case "blur":
          if (this.once(el, "debounce-blur")) {
            el.addEventListener("blur", () => {
              if (asyncFilter()) {
                callback();
              }
            });
          }
          return;
        default:
          let timeout = parseInt(value);
          let trigger = () => throttle ? this.deletePrivate(el, THROTTLED) : callback();
          let currentCycle = this.incCycle(el, DEBOUNCE_TRIGGER, trigger);
          if (isNaN(timeout)) {
            return logError(`invalid throttle/debounce value: ${value}`);
          }
          if (throttle) {
            let newKeyDown = false;
            if (event.type === "keydown") {
              let prevKey = this.private(el, DEBOUNCE_PREV_KEY);
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
          let form = el.form;
          if (form && this.once(form, "bind-debounce")) {
            form.addEventListener("submit", () => {
              Array.from(new FormData(form).entries(), ([name]) => {
                let input = form.querySelector(`[name="${name}"]`);
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
      let [cycle, trigger] = this.private(el, key);
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
    maybeAddPrivateHooks(el, phxViewportTop, phxViewportBottom) {
      if (el.hasAttribute && (el.hasAttribute(phxViewportTop) || el.hasAttribute(phxViewportBottom))) {
        el.setAttribute("data-phx-hook", "Phoenix.InfiniteScroll");
      }
    },
    isFeedbackContainer(el, phxFeedbackFor) {
      return el.hasAttribute && el.hasAttribute(phxFeedbackFor);
    },
    maybeHideFeedback(container, feedbackContainers, phxFeedbackFor, phxFeedbackGroup) {
      const feedbackResults = {};
      feedbackContainers.forEach((el) => {
        if (!container.contains(el))
          return;
        const feedback = el.getAttribute(phxFeedbackFor);
        if (!feedback) {
          js_default.addOrRemoveClasses(el, [], [PHX_NO_FEEDBACK_CLASS]);
          return;
        }
        if (feedbackResults[feedback] === true) {
          this.hideFeedback(el);
          return;
        }
        feedbackResults[feedback] = this.shouldHideFeedback(container, feedback, phxFeedbackGroup);
        if (feedbackResults[feedback] === true) {
          this.hideFeedback(el);
        }
      });
    },
    hideFeedback(container) {
      js_default.addOrRemoveClasses(container, [PHX_NO_FEEDBACK_CLASS], []);
    },
    shouldHideFeedback(container, nameOrGroup, phxFeedbackGroup) {
      const query = `[name="${nameOrGroup}"],
                   [name="${nameOrGroup}[]"],
                   [${phxFeedbackGroup}="${nameOrGroup}"]`;
      let focused = false;
      DOM.all(container, query, (input) => {
        if (this.private(input, PHX_HAS_FOCUSED) || this.private(input, PHX_HAS_SUBMITTED)) {
          focused = true;
        }
      });
      return !focused;
    },
    feedbackSelector(input, phxFeedbackFor, phxFeedbackGroup) {
      let query = `[${phxFeedbackFor}="${input.name}"],
                 [${phxFeedbackFor}="${input.name.replace(/\[\]$/, "")}"]`;
      if (input.getAttribute(phxFeedbackGroup)) {
        query += `,[${phxFeedbackFor}="${input.getAttribute(phxFeedbackGroup)}"]`;
      }
      return query;
    },
    resetForm(form, phxFeedbackFor, phxFeedbackGroup) {
      Array.from(form.elements).forEach((input) => {
        let query = this.feedbackSelector(input, phxFeedbackFor, phxFeedbackGroup);
        this.deletePrivate(input, PHX_HAS_FOCUSED);
        this.deletePrivate(input, PHX_HAS_SUBMITTED);
        this.all(document, query, (feedbackEl) => {
          js_default.addOrRemoveClasses(feedbackEl, [PHX_NO_FEEDBACK_CLASS], []);
        });
      });
    },
    showError(inputEl, phxFeedbackFor, phxFeedbackGroup) {
      if (inputEl.name) {
        let query = this.feedbackSelector(inputEl, phxFeedbackFor, phxFeedbackGroup);
        this.all(document, query, (el) => {
          js_default.addOrRemoveClasses(el, [], [PHX_NO_FEEDBACK_CLASS]);
        });
      }
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
    dispatchEvent(target, name, opts = {}) {
      let defaultBubble = true;
      let isUploadTarget = target.nodeName === "INPUT" && target.type === "file";
      if (isUploadTarget && name === "click") {
        defaultBubble = false;
      }
      let bubbles = opts.bubbles === void 0 ? defaultBubble : !!opts.bubbles;
      let eventOpts = { bubbles, cancelable: true, detail: opts.detail || {} };
      let event = name === "click" ? new MouseEvent("click", eventOpts) : new CustomEvent(name, eventOpts);
      target.dispatchEvent(event);
    },
    cloneNode(node, html) {
      if (typeof html === "undefined") {
        return node.cloneNode(true);
      } else {
        let cloned = node.cloneNode(false);
        cloned.innerHTML = html;
        return cloned;
      }
    },
    mergeAttrs(target, source, opts = {}) {
      let exclude = new Set(opts.exclude || []);
      let isIgnored = opts.isIgnored;
      let sourceAttrs = source.attributes;
      for (let i = sourceAttrs.length - 1; i >= 0; i--) {
        let name = sourceAttrs[i].name;
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
      let targetAttrs = target.attributes;
      for (let i = targetAttrs.length - 1; i >= 0; i--) {
        let name = targetAttrs[i].name;
        if (isIgnored) {
          if (name.startsWith("data-") && !source.hasAttribute(name) && ![PHX_REF, PHX_REF_SRC].includes(name)) {
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
      let wasFocused = focused.matches(":focus");
      if (!wasFocused) {
        focused.focus();
      }
      if (this.hasSelectionRange(focused)) {
        focused.setSelectionRange(selectionStart, selectionEnd);
      }
    },
    isFormInput(el) {
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
      return el.getAttribute && el.getAttribute(phxTriggerExternal) !== null;
    },
    syncPendingRef(fromEl, toEl, disableWith) {
      let ref = fromEl.getAttribute(PHX_REF);
      if (ref === null) {
        return true;
      }
      let refSrc = fromEl.getAttribute(PHX_REF_SRC);
      if (DOM.isFormInput(fromEl) || fromEl.getAttribute(disableWith) !== null) {
        if (DOM.isUploadInput(fromEl)) {
          DOM.mergeAttrs(fromEl, toEl, { isIgnored: true });
        }
        DOM.putPrivate(fromEl, PHX_REF, toEl);
        return false;
      } else {
        PHX_EVENT_CLASSES.forEach((className) => {
          fromEl.classList.contains(className) && toEl.classList.add(className);
        });
        toEl.setAttribute(PHX_REF, ref);
        toEl.setAttribute(PHX_REF_SRC, refSrc);
        return true;
      }
    },
    cleanChildNodes(container, phxUpdate) {
      if (DOM.isPhxUpdate(container, phxUpdate, ["append", "prepend"])) {
        let toRemove = [];
        container.childNodes.forEach((childNode) => {
          if (!childNode.id) {
            let isEmptyTextNode = childNode.nodeType === Node.TEXT_NODE && childNode.nodeValue.trim() === "";
            if (!isEmptyTextNode && childNode.nodeType !== Node.COMMENT_NODE) {
              logError(`only HTML element tags with an id are allowed inside containers with phx-update.

removing illegal node: "${(childNode.outerHTML || childNode.nodeValue).trim()}"

`);
            }
            toRemove.push(childNode);
          }
        });
        toRemove.forEach((childNode) => childNode.remove());
      }
    },
    replaceRootContainer(container, tagName, attrs) {
      let retainedAttrs = /* @__PURE__ */ new Set(["id", PHX_SESSION, PHX_STATIC, PHX_MAIN, PHX_ROOT_ID]);
      if (container.tagName.toLowerCase() === tagName.toLowerCase()) {
        Array.from(container.attributes).filter((attr) => !retainedAttrs.has(attr.name.toLowerCase())).forEach((attr) => container.removeAttribute(attr.name));
        Object.keys(attrs).filter((name) => !retainedAttrs.has(name.toLowerCase())).forEach((attr) => container.setAttribute(attr, attrs[attr]));
        return container;
      } else {
        let newContainer = document.createElement(tagName);
        Object.keys(attrs).forEach((attr) => newContainer.setAttribute(attr, attrs[attr]));
        retainedAttrs.forEach((attr) => newContainer.setAttribute(attr, container.getAttribute(attr)));
        newContainer.innerHTML = container.innerHTML;
        container.replaceWith(newContainer);
        return newContainer;
      }
    },
    getSticky(el, name, defaultVal) {
      let op = (DOM.private(el, "sticky") || []).find(([existingName]) => name === existingName);
      if (op) {
        let [_name, _op, stashedResult] = op;
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
      let stashedResult = op(el);
      this.updatePrivate(el, "sticky", [], (ops) => {
        let existingIndex = ops.findIndex(([existingName]) => name === existingName);
        if (existingIndex >= 0) {
          ops[existingIndex] = [name, op, stashedResult];
        } else {
          ops.push([name, op, stashedResult]);
        }
        return ops;
      });
    },
    applyStickyOperations(el) {
      let ops = DOM.private(el, "sticky");
      if (!ops) {
        return;
      }
      ops.forEach(([name, op, _stashed]) => this.putSticky(el, name, op));
    }
  };
  var dom_default = DOM;
  var UploadEntry = class {
    static isActive(fileEl, file) {
      let isNew = file._phxRef === void 0;
      let activeRefs = fileEl.getAttribute(PHX_ACTIVE_ENTRY_REFS).split(",");
      let isActive = activeRefs.indexOf(LiveUploader.genFileRef(file)) >= 0;
      return file.size > 0 && (isNew || isActive);
    }
    static isPreflighted(fileEl, file) {
      let preflightedRefs = fileEl.getAttribute(PHX_PREFLIGHTED_REFS).split(",");
      let isPreflighted = preflightedRefs.indexOf(LiveUploader.genFileRef(file)) >= 0;
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
    onDone(callback) {
      this._onDone = () => {
        this.fileEl.removeEventListener(PHX_LIVE_FILE_UPDATED, this._onElUpdated);
        callback();
      };
    }
    onElUpdated() {
      let activeRefs = this.fileEl.getAttribute(PHX_ACTIVE_ENTRY_REFS).split(",");
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
        let callback = uploaders[this.meta.uploader] || logError(`no uploader configured for ${this.meta.uploader}`);
        return { name: this.meta.uploader, callback };
      } else {
        return { name: "channel", callback: channelUploader };
      }
    }
    zipPostFlight(resp) {
      this.meta = resp.entries[this.ref];
      if (!this.meta) {
        logError(`no preflight upload response returned with ref ${this.ref}`, { input: this.fileEl, response: resp });
      }
    }
  };
  var liveUploaderFileRef = 0;
  var LiveUploader = class {
    static genFileRef(file) {
      let ref = file._phxRef;
      if (ref !== void 0) {
        return ref;
      } else {
        file._phxRef = (liveUploaderFileRef++).toString();
        return file._phxRef;
      }
    }
    static getEntryDataURL(inputEl, ref, callback) {
      let file = this.activeFiles(inputEl).find((file2) => this.genFileRef(file2) === ref);
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
      let files = this.activeFiles(inputEl);
      let fileData = {};
      files.forEach((file) => {
        let entry = { path: inputEl.name };
        let uploadRef = inputEl.getAttribute(PHX_UPLOAD_REF);
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
      dom_default.putPrivate(inputEl, "files", dom_default.private(inputEl, "files").filter((f) => !Object.is(f, file)));
    }
    static trackFiles(inputEl, files, dataTransfer) {
      if (inputEl.getAttribute("multiple") !== null) {
        let newFiles = files.filter((file) => !this.activeFiles(inputEl).find((f) => Object.is(f, file)));
        dom_default.updatePrivate(inputEl, "files", [], (existing) => existing.concat(newFiles));
        inputEl.value = null;
      } else {
        if (dataTransfer && dataTransfer.files.length > 0) {
          inputEl.files = dataTransfer.files;
        }
        dom_default.putPrivate(inputEl, "files", files);
      }
    }
    static activeFileInputs(formEl) {
      let fileInputs = dom_default.findUploadInputs(formEl);
      return Array.from(fileInputs).filter((el) => el.files && this.activeFiles(el).length > 0);
    }
    static activeFiles(input) {
      return (dom_default.private(input, "files") || []).filter((f) => UploadEntry.isActive(input, f));
    }
    static inputsAwaitingPreflight(formEl) {
      let fileInputs = dom_default.findUploadInputs(formEl);
      return Array.from(fileInputs).filter((input) => this.filesAwaitingPreflight(input).length > 0);
    }
    static filesAwaitingPreflight(input) {
      return this.activeFiles(input).filter((f) => !UploadEntry.isPreflighted(input, f) && !UploadEntry.isPreflightInProgress(f));
    }
    static markPreflightInProgress(entries) {
      entries.forEach((entry) => UploadEntry.markPreflightInProgress(entry.file));
    }
    constructor(inputEl, view, onComplete) {
      this.autoUpload = dom_default.isAutoUpload(inputEl);
      this.view = view;
      this.onComplete = onComplete;
      this._entries = Array.from(LiveUploader.filesAwaitingPreflight(inputEl) || []).map((file) => new UploadEntry(inputEl, file, view, this.autoUpload));
      LiveUploader.markPreflightInProgress(this._entries);
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
      let groupedEntries = this._entries.reduce((acc, entry) => {
        if (!entry.meta) {
          return acc;
        }
        let { name, callback } = entry.uploader(liveSocket2.uploaders);
        acc[name] = acc[name] || { callback, entries: [] };
        acc[name].entries.push(entry);
        return acc;
      }, {});
      for (let name in groupedEntries) {
        let { callback, entries } = groupedEntries[name];
        callback(entries, onError, resp, liveSocket2);
      }
    }
  };
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
        let newPreflights = this.preflightedRefs();
        if (this.preflightedWas !== newPreflights) {
          this.preflightedWas = newPreflights;
          if (newPreflights === "") {
            this.__view.cancelSubmit(this.el.form);
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
        this.inputEl = document.getElementById(this.el.getAttribute(PHX_UPLOAD_REF));
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
        this.focusStart.addEventListener("focus", () => aria_default.focusLast(this.el));
        this.focusEnd.addEventListener("focus", () => aria_default.focusFirst(this.el));
        this.el.addEventListener("phx:show-end", () => this.el.focus());
        if (window.getComputedStyle(this.el).display !== "none") {
          aria_default.focusFirst(this.el);
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
    let rect = el.getBoundingClientRect();
    return rect.top >= top(scrollContainer) && rect.left >= 0 && rect.top <= bottom(scrollContainer);
  };
  var isAtViewportBottom = (el, scrollContainer) => {
    let rect = el.getBoundingClientRect();
    return rect.right >= top(scrollContainer) && rect.left >= 0 && rect.bottom <= bottom(scrollContainer);
  };
  var isWithinViewport = (el, scrollContainer) => {
    let rect = el.getBoundingClientRect();
    return rect.top >= top(scrollContainer) && rect.left >= 0 && rect.top <= bottom(scrollContainer);
  };
  Hooks.InfiniteScroll = {
    mounted() {
      this.scrollContainer = findScrollContainer(this.el);
      let scrollBefore = scrollTop(this.scrollContainer);
      let topOverran = false;
      let throttleInterval = 500;
      let pendingOp = null;
      let onTopOverrun = this.throttle(throttleInterval, (topEvent, firstChild) => {
        pendingOp = () => true;
        this.liveSocket.execJSHookPush(this.el, topEvent, { id: firstChild.id, _overran: true }, () => {
          pendingOp = null;
        });
      });
      let onFirstChildAtTop = this.throttle(throttleInterval, (topEvent, firstChild) => {
        pendingOp = () => firstChild.scrollIntoView({ block: "start" });
        this.liveSocket.execJSHookPush(this.el, topEvent, { id: firstChild.id }, () => {
          pendingOp = null;
          window.requestAnimationFrame(() => {
            if (!isWithinViewport(firstChild, this.scrollContainer)) {
              firstChild.scrollIntoView({ block: "start" });
            }
          });
        });
      });
      let onLastChildAtBottom = this.throttle(throttleInterval, (bottomEvent, lastChild) => {
        pendingOp = () => lastChild.scrollIntoView({ block: "end" });
        this.liveSocket.execJSHookPush(this.el, bottomEvent, { id: lastChild.id }, () => {
          pendingOp = null;
          window.requestAnimationFrame(() => {
            if (!isWithinViewport(lastChild, this.scrollContainer)) {
              lastChild.scrollIntoView({ block: "end" });
            }
          });
        });
      });
      this.onScroll = (_e) => {
        let scrollNow = scrollTop(this.scrollContainer);
        if (pendingOp) {
          scrollBefore = scrollNow;
          return pendingOp();
        }
        let rect = this.el.getBoundingClientRect();
        let topEvent = this.el.getAttribute(this.liveSocket.binding("viewport-top"));
        let bottomEvent = this.el.getAttribute(this.liveSocket.binding("viewport-bottom"));
        let lastChild = this.el.lastElementChild;
        let firstChild = this.el.firstElementChild;
        let isScrollingUp = scrollNow < scrollBefore;
        let isScrollingDown = scrollNow > scrollBefore;
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
        let now = Date.now();
        let remainingTime = interval - (now - lastCallAt);
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
  var DOMPostMorphRestorer = class {
    constructor(containerBefore, containerAfter, updateType) {
      let idsBefore = /* @__PURE__ */ new Set();
      let idsAfter = new Set([...containerAfter.children].map((child) => child.id));
      let elementsToModify = [];
      Array.from(containerBefore.children).forEach((child) => {
        if (child.id) {
          idsBefore.add(child.id);
          if (idsAfter.has(child.id)) {
            let previousElementId = child.previousElementSibling && child.previousElementSibling.id;
            elementsToModify.push({ elementId: child.id, previousElementId });
          }
        }
      });
      this.containerId = containerAfter.id;
      this.updateType = updateType;
      this.elementsToModify = elementsToModify;
      this.elementIdsToAdd = [...idsAfter].filter((id) => !idsBefore.has(id));
    }
    perform() {
      let container = dom_default.byId(this.containerId);
      this.elementsToModify.forEach((elementToModify) => {
        if (elementToModify.previousElementId) {
          maybe(document.getElementById(elementToModify.previousElementId), (previousElem) => {
            maybe(document.getElementById(elementToModify.elementId), (elem) => {
              let isInRightPlace = elem.previousElementSibling && elem.previousElementSibling.id == previousElem.id;
              if (!isInRightPlace) {
                previousElem.insertAdjacentElement("afterend", elem);
              }
            });
          });
        } else {
          maybe(document.getElementById(elementToModify.elementId), (elem) => {
            let isInRightPlace = elem.previousElementSibling == null;
            if (!isInRightPlace) {
              container.insertAdjacentElement("afterbegin", elem);
            }
          });
        }
      });
      if (this.updateType == "prepend") {
        this.elementIdsToAdd.reverse().forEach((elemId) => {
          maybe(document.getElementById(elemId), (elem) => container.insertAdjacentElement("afterbegin", elem));
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
            removeNode(curFromNodeChild, fromEl, true);
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
          if (onBeforeElUpdated(fromEl, toEl) === false) {
            return;
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
                            removeNode(curFromNodeChild, fromEl, true);
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
                removeNode(curFromNodeChild, fromEl, true);
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
    static patchEl(fromEl, toEl, activeElement) {
      morphdom_esm_default(fromEl, toEl, {
        childrenOnly: false,
        onBeforeElUpdated: (fromEl2, toEl2) => {
          if (activeElement && activeElement.isSameNode(fromEl2) && dom_default.isFormInput(fromEl2)) {
            dom_default.mergeFocusedInput(fromEl2, toEl2);
            return false;
          }
        }
      });
    }
    constructor(view, container, id, html, streams, targetCID) {
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
      let phxUpdate = this.liveSocket.binding(PHX_UPDATE);
      dom_default.all(this.container, `[${phxUpdate}=append] > *, [${phxUpdate}=prepend] > *`, (el) => {
        el.setAttribute(PHX_PRUNE, "");
      });
    }
    perform(isJoinPatch) {
      let { view, liveSocket: liveSocket2, container, html } = this;
      let targetContainer = this.isCIDPatch() ? this.targetCIDContainer(html) : container;
      if (this.isCIDPatch() && !targetContainer) {
        return;
      }
      let focused = liveSocket2.getActiveElement();
      let { selectionStart, selectionEnd } = focused && dom_default.hasSelectionRange(focused) ? focused : {};
      let phxUpdate = liveSocket2.binding(PHX_UPDATE);
      let phxFeedbackFor = liveSocket2.binding(PHX_FEEDBACK_FOR);
      let phxFeedbackGroup = liveSocket2.binding(PHX_FEEDBACK_GROUP);
      let disableWith = liveSocket2.binding(PHX_DISABLE_WITH);
      let phxViewportTop = liveSocket2.binding(PHX_VIEWPORT_TOP);
      let phxViewportBottom = liveSocket2.binding(PHX_VIEWPORT_BOTTOM);
      let phxTriggerExternal = liveSocket2.binding(PHX_TRIGGER_ACTION);
      let added = [];
      let feedbackContainers = [];
      let updates = [];
      let appendPrependUpdates = [];
      let externalFormTriggered = null;
      function morph(targetContainer2, source, withChildren = false) {
        morphdom_esm_default(targetContainer2, source, {
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
          skipFromChildren: (from) => {
            return from.getAttribute(phxUpdate) === PHX_STREAM;
          },
          addChild: (parent, child) => {
            let { ref, streamAt } = this.getStreamInsert(child);
            if (ref === void 0) {
              return parent.appendChild(child);
            }
            this.setStreamRef(child, ref);
            if (streamAt === 0) {
              parent.insertAdjacentElement("afterbegin", child);
            } else if (streamAt === -1) {
              parent.appendChild(child);
            } else if (streamAt > 0) {
              let sibling = Array.from(parent.children)[streamAt];
              parent.insertBefore(child, sibling);
            }
          },
          onBeforeNodeAdded: (el) => {
            dom_default.maybeAddPrivateHooks(el, phxViewportTop, phxViewportBottom);
            this.trackBefore("added", el);
            let morphedEl = el;
            if (!isJoinPatch && this.streamComponentRestore[el.id]) {
              morphedEl = this.streamComponentRestore[el.id];
              delete this.streamComponentRestore[el.id];
              morph.call(this, morphedEl, el, true);
            }
            return morphedEl;
          },
          onNodeAdded: (el) => {
            if (el.getAttribute) {
              this.maybeReOrderStream(el, true);
            }
            if (dom_default.isFeedbackContainer(el, phxFeedbackFor))
              feedbackContainers.push(el);
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
            added.push(el);
          },
          onNodeDiscarded: (el) => this.onNodeDiscarded(el),
          onBeforeNodeDiscarded: (el) => {
            if (el.getAttribute && el.getAttribute(PHX_PRUNE) !== null) {
              return true;
            }
            if (el.parentElement !== null && el.id && dom_default.isPhxUpdate(el.parentElement, phxUpdate, [PHX_STREAM, "append", "prepend"])) {
              return false;
            }
            if (this.maybePendingRemove(el)) {
              return false;
            }
            if (this.skipCIDSibling(el)) {
              return false;
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
            dom_default.maybeAddPrivateHooks(toEl, phxViewportTop, phxViewportBottom);
            if (dom_default.isFeedbackContainer(fromEl, phxFeedbackFor) || dom_default.isFeedbackContainer(toEl, phxFeedbackFor)) {
              feedbackContainers.push(fromEl);
              feedbackContainers.push(toEl);
            }
            dom_default.cleanChildNodes(toEl, phxUpdate);
            if (this.skipCIDSibling(toEl)) {
              this.maybeReOrderStream(fromEl);
              return false;
            }
            if (dom_default.isPhxSticky(fromEl)) {
              return false;
            }
            if (dom_default.isIgnored(fromEl, phxUpdate) || fromEl.form && fromEl.form.isSameNode(externalFormTriggered)) {
              this.trackBefore("updated", fromEl, toEl);
              dom_default.mergeAttrs(fromEl, toEl, { isIgnored: dom_default.isIgnored(fromEl, phxUpdate) });
              updates.push(fromEl);
              dom_default.applyStickyOperations(fromEl);
              return false;
            }
            if (fromEl.type === "number" && (fromEl.validity && fromEl.validity.badInput)) {
              return false;
            }
            if (!dom_default.syncPendingRef(fromEl, toEl, disableWith)) {
              if (dom_default.isUploadInput(fromEl)) {
                this.trackBefore("updated", fromEl, toEl);
                updates.push(fromEl);
              }
              dom_default.applyStickyOperations(fromEl);
              return false;
            }
            if (dom_default.isPhxChild(toEl)) {
              let prevSession = fromEl.getAttribute(PHX_SESSION);
              dom_default.mergeAttrs(fromEl, toEl, { exclude: [PHX_STATIC] });
              if (prevSession !== "") {
                fromEl.setAttribute(PHX_SESSION, prevSession);
              }
              fromEl.setAttribute(PHX_ROOT_ID, this.rootID);
              dom_default.applyStickyOperations(fromEl);
              return false;
            }
            dom_default.copyPrivates(toEl, fromEl);
            let isFocusedFormEl = focused && fromEl.isSameNode(focused) && dom_default.isFormInput(fromEl);
            let focusedSelectChanged = isFocusedFormEl && this.isChangedSelect(fromEl, toEl);
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
                appendPrependUpdates.push(new DOMPostMorphRestorer(fromEl, toEl, toEl.getAttribute(phxUpdate)));
              }
              dom_default.syncAttrsToProps(toEl);
              dom_default.applyStickyOperations(toEl);
              this.trackBefore("updated", fromEl, toEl);
              return true;
            }
          }
        });
      }
      this.trackBefore("added", container);
      this.trackBefore("updated", container, container);
      liveSocket2.time("morphdom", () => {
        this.streams.forEach(([ref, inserts, deleteIds, reset]) => {
          inserts.forEach(([key, streamAt, limit]) => {
            this.streamInserts[key] = { ref, streamAt, limit, reset };
          });
          if (reset !== void 0) {
            dom_default.all(container, `[${PHX_STREAM_REF}="${ref}"]`, (child) => {
              this.removeStreamChildElement(child);
            });
          }
          deleteIds.forEach((id) => {
            let child = container.querySelector(`[id="${id}"]`);
            if (child) {
              this.removeStreamChildElement(child);
            }
          });
        });
        if (isJoinPatch) {
          dom_default.all(this.container, `[${phxUpdate}=${PHX_STREAM}]`, (el) => {
            this.liveSocket.owner(el, (view2) => {
              if (view2 === this.view) {
                Array.from(el.children).forEach((child) => {
                  this.removeStreamChildElement(child);
                });
              }
            });
          });
        }
        morph.call(this, targetContainer, html);
      });
      if (liveSocket2.isDebugEnabled()) {
        detectDuplicateIds();
        Array.from(document.querySelectorAll("input[name=id]")).forEach((node) => {
          if (node.form) {
            console.error('Detected an input with name="id" inside a form! This will cause problems when patching the DOM.\n', node);
          }
        });
      }
      if (appendPrependUpdates.length > 0) {
        liveSocket2.time("post-morph append/prepend restoration", () => {
          appendPrependUpdates.forEach((update) => update.perform());
        });
      }
      dom_default.maybeHideFeedback(targetContainer, feedbackContainers, phxFeedbackFor, phxFeedbackGroup);
      liveSocket2.silenceEvents(() => dom_default.restoreFocus(focused, selectionStart, selectionEnd));
      dom_default.dispatchEvent(document, "phx:update");
      added.forEach((el) => this.trackAfter("added", el));
      updates.forEach((el) => this.trackAfter("updated", el));
      this.transitionPendingRemoves();
      if (externalFormTriggered) {
        liveSocket2.unload();
        Object.getPrototypeOf(externalFormTriggered).submit.call(externalFormTriggered);
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
    removeStreamChildElement(child) {
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
      let insert = el.id ? this.streamInserts[el.id] : {};
      return insert || {};
    }
    setStreamRef(el, ref) {
      dom_default.putSticky(el, PHX_STREAM_REF, (el2) => el2.setAttribute(PHX_STREAM_REF, ref));
    }
    maybeReOrderStream(el, isNew) {
      let { ref, streamAt, reset } = this.getStreamInsert(el);
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
        let children = Array.from(el.parentElement.children);
        let oldIndex = children.indexOf(el);
        if (streamAt >= children.length - 1) {
          el.parentElement.appendChild(el);
        } else {
          let sibling = children[streamAt];
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
      let { limit } = this.getStreamInsert(el);
      let children = limit !== null && Array.from(el.parentElement.children);
      if (limit && limit < 0 && children.length > limit * -1) {
        children.slice(0, children.length + limit).forEach((child) => this.removeStreamChildElement(child));
      } else if (limit && limit >= 0 && children.length > limit) {
        children.slice(limit).forEach((child) => this.removeStreamChildElement(child));
      }
    }
    transitionPendingRemoves() {
      let { pendingRemoves, liveSocket: liveSocket2 } = this;
      if (pendingRemoves.length > 0) {
        liveSocket2.transitionRemoves(pendingRemoves);
        liveSocket2.requestDOMUpdate(() => {
          pendingRemoves.forEach((el) => {
            let child = dom_default.firstPhxChild(el);
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
      let fromSelected = fromEl.selectedOptions[0];
      let toSelected = toEl.selectedOptions[0];
      if (fromSelected && fromSelected.hasAttribute("selected")) {
        toSelected.setAttribute("selected", fromSelected.getAttribute("selected"));
      }
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
      let [first, ...rest] = dom_default.findComponentNodeList(this.container, this.targetCID);
      if (rest.length === 0 && dom_default.childNodeLength(html) === 1) {
        return first;
      } else {
        return first && first.parentNode;
      }
    }
    indexOf(parent, child) {
      return Array.from(parent.children).indexOf(child);
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
    let lookahead = html.match(/^(\s*(?:<!--.*?-->\s*)*)<([^\s\/>]+)/);
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
        let isId = html.slice(i - 3, i) === " id";
        i++;
        let char = html.charAt(i);
        if (quoteChars.has(char)) {
          let attrStartsAt = i;
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
      let char = html.charAt(closeAt);
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
    let attrsStr = Object.keys(attrs).map((attr) => attrs[attr] === true ? attr : `${attr}="${attrs[attr]}"`).join(" ");
    if (clearInnerHTML) {
      let idAttrStr = id ? ` id="${id}"` : "";
      if (VOID_TAGS.has(tag)) {
        newHTML = `<${tag}${idAttrStr}${attrsStr === "" ? "" : " "}${attrsStr}/>`;
      } else {
        newHTML = `<${tag}${idAttrStr}${attrsStr === "" ? "" : " "}${attrsStr}></${tag}>`;
      }
    } else {
      let rest = html.slice(tagNameEndsAt, closeAt + 1);
      newHTML = `<${tag}${attrsStr === "" ? "" : " "}${attrsStr}${rest}`;
    }
    return [newHTML, beforeTag, afterTag];
  };
  var Rendered = class {
    static extract(diff) {
      let { [REPLY]: reply, [EVENTS]: events, [TITLE]: title } = diff;
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
      let [str, streams] = this.recursiveToString(this.rendered, this.rendered[COMPONENTS], onlyCids, true, {});
      return [str, streams];
    }
    recursiveToString(rendered, components = rendered[COMPONENTS], onlyCids, changeTracking, rootAttrs) {
      onlyCids = onlyCids ? new Set(onlyCids) : null;
      let output = { buffer: "", components, onlyCids, streams: /* @__PURE__ */ new Set() };
      this.toOutputBuffer(rendered, null, output, changeTracking, rootAttrs);
      return [output.buffer, output.streams];
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
      let newc = diff[COMPONENTS];
      let cache = {};
      delete diff[COMPONENTS];
      this.rendered = this.mutableMerge(this.rendered, diff);
      this.rendered[COMPONENTS] = this.rendered[COMPONENTS] || {};
      if (newc) {
        let oldc = this.rendered[COMPONENTS];
        for (let cid in newc) {
          newc[cid] = this.cachedFindComponent(cid, newc[cid], oldc, newc, cache);
        }
        for (let cid in newc) {
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
      for (let key in source) {
        let val = source[key];
        let targetVal = target[key];
        let isObjVal = isObject(val);
        if (isObjVal && val[STATIC] === void 0 && isObject(targetVal)) {
          this.doMutableMerge(targetVal, val);
        } else {
          target[key] = val;
        }
      }
      if (target[ROOT]) {
        target.newRender = true;
      }
    }
    cloneMerge(target, source, pruneMagicId) {
      let merged = __spreadValues(__spreadValues({}, target), source);
      for (let key in merged) {
        let val = source[key];
        let targetVal = target[key];
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
      let [str, streams] = this.recursiveCIDToString(this.rendered[COMPONENTS], cid, null);
      let [strippedHTML, _before, _after] = modifyRoot(str, {});
      return [strippedHTML, streams];
    }
    pruneCIDs(cids) {
      cids.forEach((cid) => delete this.rendered[COMPONENTS][cid]);
    }
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
    toOutputBuffer(rendered, templates, output, changeTracking, rootAttrs = {}) {
      if (rendered[DYNAMICS]) {
        return this.comprehensionToBuffer(rendered, templates, output);
      }
      let { [STATIC]: statics } = rendered;
      statics = this.templateStatic(statics, templates);
      let isRoot = rendered[ROOT];
      let prevBuffer = output.buffer;
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
        let [newRoot, commentBefore, commentAfter] = modifyRoot(output.buffer, attrs, skip);
        rendered.newRender = false;
        output.buffer = prevBuffer + commentBefore + newRoot + commentAfter;
      }
    }
    comprehensionToBuffer(rendered, templates, output) {
      let { [DYNAMICS]: dynamics, [STATIC]: statics, [STREAM]: stream } = rendered;
      let [_ref, _inserts, deleteIds, reset] = stream || [null, {}, [], null];
      statics = this.templateStatic(statics, templates);
      let compTemplates = templates || rendered[TEMPLATES];
      for (let d = 0; d < dynamics.length; d++) {
        let dynamic = dynamics[d];
        output.buffer += statics[0];
        for (let i = 1; i < statics.length; i++) {
          let changeTracking = false;
          this.dynamicToBuffer(dynamic[i - 1], compTemplates, output, changeTracking);
          output.buffer += statics[i];
        }
      }
      if (stream !== void 0 && (rendered[DYNAMICS].length > 0 || deleteIds.length > 0 || reset)) {
        delete rendered[STREAM];
        rendered[DYNAMICS] = [];
        output.streams.add(stream);
      }
    }
    dynamicToBuffer(rendered, templates, output, changeTracking) {
      if (typeof rendered === "number") {
        let [str, streams] = this.recursiveCIDToString(output.components, rendered, output.onlyCids);
        output.buffer += str;
        output.streams = /* @__PURE__ */ new Set([...output.streams, ...streams]);
      } else if (isObject(rendered)) {
        this.toOutputBuffer(rendered, templates, output, changeTracking, {});
      } else {
        output.buffer += rendered;
      }
    }
    recursiveCIDToString(components, cid, onlyCids) {
      let component = components[cid] || logError(`no component for CID ${cid}`, components);
      let attrs = { [PHX_COMPONENT]: cid };
      let skip = onlyCids && !onlyCids.has(cid);
      component.newRender = !skip;
      component.magicId = `c${cid}-${this.parentViewId()}`;
      let changeTracking = !component.reset;
      let [html, streams] = this.recursiveToString(component, components, onlyCids, changeTracking, attrs);
      delete component.reset;
      return [html, streams];
    }
  };
  var viewHookID = 1;
  var ViewHook = class {
    static makeID() {
      return viewHookID++;
    }
    static elementID(el) {
      return el.phxHookId;
    }
    constructor(view, el, callbacks) {
      this.__view = view;
      this.liveSocket = view.liveSocket;
      this.__callbacks = callbacks;
      this.__listeners = /* @__PURE__ */ new Set();
      this.__isDisconnected = false;
      this.el = el;
      this.el.phxHookId = this.constructor.makeID();
      for (let key in this.__callbacks) {
        this[key] = this.__callbacks[key];
      }
    }
    __mounted() {
      this.mounted && this.mounted();
    }
    __updated() {
      this.updated && this.updated();
    }
    __beforeUpdate() {
      this.beforeUpdate && this.beforeUpdate();
    }
    __destroyed() {
      this.destroyed && this.destroyed();
    }
    __reconnected() {
      if (this.__isDisconnected) {
        this.__isDisconnected = false;
        this.reconnected && this.reconnected();
      }
    }
    __disconnected() {
      this.__isDisconnected = true;
      this.disconnected && this.disconnected();
    }
    pushEvent(event, payload = {}, onReply = function() {
    }) {
      return this.__view.pushHookEvent(this.el, null, event, payload, onReply);
    }
    pushEventTo(phxTarget, event, payload = {}, onReply = function() {
    }) {
      return this.__view.withinTargets(phxTarget, (view, targetCtx) => {
        return view.pushHookEvent(this.el, targetCtx, event, payload, onReply);
      });
    }
    handleEvent(event, callback) {
      let callbackRef = (customEvent, bypass) => bypass ? event : callback(customEvent.detail);
      window.addEventListener(`phx:${event}`, callbackRef);
      this.__listeners.add(callbackRef);
      return callbackRef;
    }
    removeHandleEvent(callbackRef) {
      let event = callbackRef(null, true);
      window.removeEventListener(`phx:${event}`, callbackRef);
      this.__listeners.delete(callbackRef);
    }
    upload(name, files) {
      return this.__view.dispatchUploads(null, name, files);
    }
    uploadTo(phxTarget, name, files) {
      return this.__view.withinTargets(phxTarget, (view, targetCtx) => {
        view.dispatchUploads(targetCtx, name, files);
      });
    }
    __cleanup__() {
      this.__listeners.forEach((callbackRef) => this.removeHandleEvent(callbackRef));
    }
  };
  var serializeForm = (form, metadata, onlyNames = []) => {
    const _a = metadata, { submitter } = _a, meta = __objRest(_a, ["submitter"]);
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
    for (let [key, val] of formData.entries()) {
      if (onlyNames.length === 0 || onlyNames.indexOf(key) >= 0) {
        params.append(key, val);
      }
    }
    if (submitter && injectedElement) {
      submitter.parentElement.removeChild(injectedElement);
    }
    for (let metaKey in meta) {
      params.append(metaKey, meta[metaKey]);
    }
    return params.toString();
  };
  var View = class {
    constructor(el, liveSocket2, parentView, flash, liveReferer) {
      this.isDead = false;
      this.liveSocket = liveSocket2;
      this.flash = flash;
      this.parent = parentView;
      this.root = parentView ? parentView.root : this;
      this.el = el;
      this.id = this.el.id;
      this.ref = 0;
      this.childJoins = 0;
      this.loaderTimer = null;
      this.pendingDiffs = [];
      this.pendingForms = /* @__PURE__ */ new Set();
      this.redirect = false;
      this.href = null;
      this.joinCount = this.parent ? this.parent.joinCount - 1 : 0;
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
        let url = this.href && this.expandURL(this.href);
        return {
          redirect: this.redirect ? url : void 0,
          url: this.redirect ? void 0 : url || void 0,
          params: this.connectParams(liveReferer),
          session: this.getSession(),
          static: this.getStatic(),
          flash: this.flash
        };
      });
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
      let params = this.liveSocket.params(this.el);
      let manifest = dom_default.all(document, `[${this.binding(PHX_TRACK_STATIC)}]`).map((node) => node.src || node.href).filter((url) => typeof url === "string");
      if (manifest.length > 0) {
        params["_track_static"] = manifest;
      }
      params["_mounts"] = this.joinCount;
      params["_live_referer"] = liveReferer;
      return params;
    }
    isConnected() {
      return this.channel.canPush();
    }
    getSession() {
      return this.el.getAttribute(PHX_SESSION);
    }
    getStatic() {
      let val = this.el.getAttribute(PHX_STATIC);
      return val === "" ? null : val;
    }
    destroy(callback = function() {
    }) {
      this.destroyAllChildren();
      this.destroyed = true;
      delete this.root.children[this.id];
      if (this.parent) {
        delete this.root.children[this.parent.id][this.id];
      }
      clearTimeout(this.loaderTimer);
      let onFinished = () => {
        callback();
        for (let id in this.viewHooks) {
          this.destroyHook(this.viewHooks[id]);
        }
      };
      dom_default.markPhxChildDestroyed(this.el);
      this.log("destroyed", () => ["the child has been removed from the parent"]);
      this.channel.leave().receive("ok", onFinished).receive("error", onFinished).receive("timeout", onFinished);
    }
    setContainerClasses(...classes) {
      this.el.classList.remove(PHX_CONNECTED_CLASS, PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_CLIENT_ERROR_CLASS, PHX_SERVER_ERROR_CLASS);
      this.el.classList.add(...classes);
    }
    showLoader(timeout) {
      clearTimeout(this.loaderTimer);
      if (timeout) {
        this.loaderTimer = setTimeout(() => this.showLoader(), timeout);
      } else {
        for (let id in this.viewHooks) {
          this.viewHooks[id].__disconnected();
        }
        this.setContainerClasses(PHX_LOADING_CLASS);
      }
    }
    execAll(binding) {
      dom_default.all(this.el, `[${binding}]`, (el) => this.liveSocket.execJS(el, el.getAttribute(binding)));
    }
    hideLoader() {
      clearTimeout(this.loaderTimer);
      this.setContainerClasses(PHX_CONNECTED_CLASS);
      this.execAll(this.binding("connected"));
    }
    triggerReconnected() {
      for (let id in this.viewHooks) {
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
    withinTargets(phxTarget, callback, dom = document, viewEl) {
      if (phxTarget instanceof HTMLElement || phxTarget instanceof SVGElement) {
        return this.liveSocket.owner(phxTarget, (view) => callback(view, phxTarget));
      }
      if (isCid(phxTarget)) {
        let targets = dom_default.findComponentNodeList(viewEl || this.el, phxTarget);
        if (targets.length === 0) {
          logError(`no component found matching phx-target of ${phxTarget}`);
        } else {
          callback(this, parseInt(phxTarget));
        }
      } else {
        let targets = Array.from(dom.querySelectorAll(phxTarget));
        if (targets.length === 0) {
          logError(`nothing found matching the phx-target selector "${phxTarget}"`);
        }
        targets.forEach((target) => this.liveSocket.owner(target, (view) => callback(view, target)));
      }
    }
    applyDiff(type, rawDiff, callback) {
      this.log(type, () => ["", clone(rawDiff)]);
      let { diff, reply, events, title } = Rendered.extract(rawDiff);
      callback({ diff, reply, events });
      if (typeof title === "string") {
        window.requestAnimationFrame(() => dom_default.putTitle(title));
      }
    }
    onJoin(resp) {
      let { rendered, container, liveview_version } = resp;
      if (container) {
        let [tag, attrs] = container;
        this.el = dom_default.replaceRootContainer(this.el, tag, attrs);
      }
      this.childJoins = 0;
      this.joinPending = true;
      this.flash = null;
      if (this.root === this) {
        this.formsForRecovery = this.getFormsForRecovery();
      }
      if (liveview_version !== this.liveSocket.version()) {
        console.error(`LiveView asset version mismatch. JavaScript version ${this.liveSocket.version()} vs. server ${liveview_version}. To avoid issues, please ensure that your assets use the same version as the server.`);
      }
      browser_default.dropLocal(this.liveSocket.localStorage, window.location.pathname, CONSECUTIVE_RELOADS);
      this.applyDiff("mount", rendered, ({ diff, events }) => {
        this.rendered = new Rendered(this.id, diff);
        let [html, streams] = this.renderContainer(null, "join");
        this.dropPendingRefs();
        this.joinCount++;
        this.maybeRecoverForms(html, () => {
          this.onJoinComplete(resp, html, streams, events);
        });
      });
    }
    dropPendingRefs() {
      dom_default.all(document, `[${PHX_REF_SRC}="${this.id}"][${PHX_REF}]`, (el) => {
        el.removeAttribute(PHX_REF);
        el.removeAttribute(PHX_REF_SRC);
      });
    }
    onJoinComplete({ live_patch }, html, streams, events) {
      if (this.joinCount > 1 || this.parent && !this.parent.isJoinPending()) {
        return this.applyJoinPatch(live_patch, html, streams, events);
      }
      let newChildren = dom_default.findPhxChildrenInFragment(html, this.id).filter((toEl) => {
        let fromEl = toEl.id && this.el.querySelector(`[id="${toEl.id}"]`);
        let phxStatic = fromEl && fromEl.getAttribute(PHX_STATIC);
        if (phxStatic) {
          toEl.setAttribute(PHX_STATIC, phxStatic);
        }
        if (fromEl) {
          fromEl.setAttribute(PHX_ROOT_ID, this.root.id);
        }
        return this.joinChild(toEl);
      });
      if (newChildren.length === 0) {
        if (this.parent) {
          this.root.pendingJoinOps.push([this, () => this.applyJoinPatch(live_patch, html, streams, events)]);
          this.parent.ackJoin(this);
        } else {
          this.onAllChildJoinsComplete();
          this.applyJoinPatch(live_patch, html, streams, events);
        }
      } else {
        this.root.pendingJoinOps.push([this, () => this.applyJoinPatch(live_patch, html, streams, events)]);
      }
    }
    attachTrueDocEl() {
      this.el = dom_default.byId(this.id);
      this.el.setAttribute(PHX_ROOT_ID, this.root.id);
    }
    execNewMounted() {
      let phxViewportTop = this.binding(PHX_VIEWPORT_TOP);
      let phxViewportBottom = this.binding(PHX_VIEWPORT_BOTTOM);
      dom_default.all(this.el, `[${phxViewportTop}], [${phxViewportBottom}]`, (hookEl) => {
        if (this.ownsElement(hookEl)) {
          dom_default.maybeAddPrivateHooks(hookEl, phxViewportTop, phxViewportBottom);
          this.maybeAddNewHook(hookEl);
        }
      });
      dom_default.all(this.el, `[${this.binding(PHX_HOOK)}], [data-phx-${PHX_HOOK}]`, (hookEl) => {
        if (this.ownsElement(hookEl)) {
          this.maybeAddNewHook(hookEl);
        }
      });
      dom_default.all(this.el, `[${this.binding(PHX_MOUNTED)}]`, (el) => {
        if (this.ownsElement(el)) {
          this.maybeMounted(el);
        }
      });
    }
    applyJoinPatch(live_patch, html, streams, events) {
      this.attachTrueDocEl();
      let patch = new DOMPatch(this, this.el, this.id, html, streams, null);
      patch.markPrunableContentForRemoval();
      this.performPatch(patch, false, true);
      this.joinNewChildren();
      this.execNewMounted();
      this.joinPending = false;
      this.liveSocket.dispatchEvents(events);
      this.applyPendingUpdates();
      if (live_patch) {
        let { kind, to } = live_patch;
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
      let hook = this.getHook(fromEl);
      let isIgnored = hook && dom_default.isIgnored(fromEl, this.binding(PHX_UPDATE));
      if (hook && !fromEl.isEqualNode(toEl) && !(isIgnored && isEqualObj(fromEl.dataset, toEl.dataset))) {
        hook.__beforeUpdate();
        return hook;
      }
    }
    maybeMounted(el) {
      let phxMounted = el.getAttribute(this.binding(PHX_MOUNTED));
      let hasBeenInvoked = phxMounted && dom_default.private(el, "mounted");
      if (phxMounted && !hasBeenInvoked) {
        this.liveSocket.execJS(el, phxMounted);
        dom_default.putPrivate(el, "mounted", true);
      }
    }
    maybeAddNewHook(el, force) {
      let newHook = this.addHook(el);
      if (newHook) {
        newHook.__mounted();
      }
    }
    performPatch(patch, pruneCids, isJoinPatch = false) {
      let removedEls = [];
      let phxChildrenAdded = false;
      let updatedHookIds = /* @__PURE__ */ new Set();
      patch.after("added", (el) => {
        this.liveSocket.triggerDOM("onNodeAdded", [el]);
        let phxViewportTop = this.binding(PHX_VIEWPORT_TOP);
        let phxViewportBottom = this.binding(PHX_VIEWPORT_BOTTOM);
        dom_default.maybeAddPrivateHooks(el, phxViewportTop, phxViewportBottom);
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
        let hook = this.triggerBeforeUpdateHook(fromEl, toEl);
        if (hook) {
          updatedHookIds.add(fromEl.id);
        }
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
      patch.after("transitionsDiscarded", (els) => this.afterElementsRemoved(els, pruneCids));
      patch.perform(isJoinPatch);
      this.afterElementsRemoved(removedEls, pruneCids);
      return phxChildrenAdded;
    }
    afterElementsRemoved(elements, pruneCids) {
      let destroyedCIDs = [];
      elements.forEach((parent) => {
        let components = dom_default.all(parent, `[${PHX_COMPONENT}]`);
        let hooks = dom_default.all(parent, `[${this.binding(PHX_HOOK)}]`);
        components.concat(parent).forEach((el) => {
          let cid = this.componentID(el);
          if (isCid(cid) && destroyedCIDs.indexOf(cid) === -1) {
            destroyedCIDs.push(cid);
          }
        });
        hooks.concat(parent).forEach((hookEl) => {
          let hook = this.getHook(hookEl);
          hook && this.destroyHook(hook);
        });
      });
      if (pruneCids) {
        this.maybePushComponentsDestroyed(destroyedCIDs);
      }
    }
    joinNewChildren() {
      dom_default.findPhxChildren(this.el, this.id).forEach((el) => this.joinChild(el));
    }
    maybeRecoverForms(html, callback) {
      const phxChange = this.binding("change");
      const oldForms = this.root.formsForRecovery;
      let template = document.createElement("template");
      template.innerHTML = html;
      const rootEl = template.content.firstElementChild;
      rootEl.id = this.id;
      rootEl.setAttribute(PHX_ROOT_ID, this.root.id);
      rootEl.setAttribute(PHX_SESSION, this.getSession());
      rootEl.setAttribute(PHX_STATIC, this.getStatic());
      rootEl.setAttribute(PHX_PARENT_ID, this.parent ? this.parent.id : null);
      const formsToRecover = dom_default.all(template.content, "form").filter((newForm) => newForm.id && oldForms[newForm.id]).filter((newForm) => !this.pendingForms.has(newForm.id)).filter((newForm) => oldForms[newForm.id].getAttribute(phxChange) === newForm.getAttribute(phxChange)).map((newForm) => {
        return [oldForms[newForm.id], newForm];
      });
      if (formsToRecover.length === 0) {
        return callback();
      }
      formsToRecover.forEach(([oldForm, newForm], i) => {
        this.pendingForms.add(newForm.id);
        this.pushFormRecovery(oldForm, newForm, template.content, () => {
          this.pendingForms.delete(newForm.id);
          if (i === formsToRecover.length - 1) {
            callback();
          }
        });
      });
    }
    getChildById(id) {
      return this.root.children[this.id][id];
    }
    getDescendentByEl(el) {
      if (el.id === this.id) {
        return this;
      } else {
        return this.children[el.getAttribute(PHX_PARENT_ID)][el.id];
      }
    }
    destroyDescendent(id) {
      for (let parentId in this.root.children) {
        for (let childId in this.root.children[parentId]) {
          if (childId === id) {
            return this.root.children[parentId][childId].destroy();
          }
        }
      }
    }
    joinChild(el) {
      let child = this.getChildById(el.id);
      if (!child) {
        let view = new View(el, this.liveSocket, this);
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
          let parentCids = dom_default.findExistingParentCIDs(this.el, this.rendered.componentCIDs(diff));
          parentCids.forEach((parentCID) => {
            if (this.componentPatch(this.rendered.getComponent(diff, parentCID), parentCID)) {
              phxChildrenAdded = true;
            }
          });
        });
      } else if (!isEmpty(diff)) {
        this.liveSocket.time("full patch complete", () => {
          let [html, streams] = this.renderContainer(diff, "update");
          let patch = new DOMPatch(this, this.el, this.id, html, streams, null);
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
        let tag = this.el.tagName;
        let cids = diff ? this.rendered.componentCIDs(diff) : null;
        let [html, streams] = this.rendered.toString(cids);
        return [`<${tag}>${html}</${tag}>`, streams];
      });
    }
    componentPatch(diff, cid) {
      if (isEmpty(diff))
        return false;
      let [html, streams] = this.rendered.componentToString(cid);
      let patch = new DOMPatch(this, this.el, this.id, html, streams, cid);
      let childrenAdded = this.performPatch(patch, true);
      return childrenAdded;
    }
    getHook(el) {
      return this.viewHooks[ViewHook.elementID(el)];
    }
    addHook(el) {
      if (ViewHook.elementID(el) || !el.getAttribute) {
        return;
      }
      let hookName = el.getAttribute(`data-phx-${PHX_HOOK}`) || el.getAttribute(this.binding(PHX_HOOK));
      if (hookName && !this.ownsElement(el)) {
        return;
      }
      let callbacks = this.liveSocket.getHookCallbacks(hookName);
      if (callbacks) {
        if (!el.id) {
          logError(`no DOM ID for hook "${hookName}". Hooks require a unique ID on each element.`, el);
        }
        let hook = new ViewHook(this, el, callbacks);
        this.viewHooks[ViewHook.elementID(hook.el)] = hook;
        return hook;
      } else if (hookName !== null) {
        logError(`unknown hook found for "${hookName}"`, el);
      }
    }
    destroyHook(hook) {
      hook.__destroyed();
      hook.__cleanup__();
      delete this.viewHooks[ViewHook.elementID(hook.el)];
    }
    applyPendingUpdates() {
      this.pendingDiffs.forEach(({ diff, events }) => this.update(diff, events));
      this.pendingDiffs = [];
      this.eachChild((child) => child.applyPendingUpdates());
    }
    eachChild(callback) {
      let children = this.root.children[this.id] || {};
      for (let id in children) {
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
          this.applyDiff("update", rawDiff, ({ diff, events }) => this.update(diff, events));
        });
      });
      this.onChannel("redirect", ({ to, flash }) => this.onRedirect({ to, flash }));
      this.onChannel("live_patch", (redir) => this.onLivePatch(redir));
      this.onChannel("live_redirect", (redir) => this.onLiveRedirect(redir));
      this.channel.onError((reason) => this.onError(reason));
      this.channel.onClose((reason) => this.onClose(reason));
    }
    destroyAllChildren() {
      this.eachChild((child) => child.destroy());
    }
    onLiveRedirect(redir) {
      let { to, kind, flash } = redir;
      let url = this.expandURL(to);
      this.liveSocket.historyRedirect(url, kind, flash);
    }
    onLivePatch(redir) {
      let { to, kind } = redir;
      this.href = this.expandURL(to);
      this.liveSocket.historyPatch(to, kind);
    }
    expandURL(to) {
      return to.startsWith("/") ? `${window.location.protocol}//${window.location.host}${to}` : to;
    }
    onRedirect({ to, flash }) {
      this.liveSocket.redirect(to, flash);
    }
    isDestroyed() {
      return this.destroyed;
    }
    joinDead() {
      this.isDead = true;
    }
    join(callback) {
      this.showLoader(this.liveSocket.loaderTimeout);
      this.bindChannel();
      if (this.isMain()) {
        this.stopCallback = this.liveSocket.withPageLoading({ to: this.href, kind: "initial" });
      }
      this.joinCallback = (onDone) => {
        onDone = onDone || function() {
        };
        callback ? callback(this.joinCount, onDone) : onDone();
      };
      this.liveSocket.wrapPush(this, { timeout: false }, () => {
        return this.channel.join().receive("ok", (data) => {
          if (!this.isDestroyed()) {
            this.liveSocket.requestDOMUpdate(() => this.onJoin(data));
          }
        }).receive("error", (resp) => !this.isDestroyed() && this.onJoinError(resp)).receive("timeout", () => !this.isDestroyed() && this.onJoinError({ reason: "timeout" }));
      });
    }
    onJoinError(resp) {
      if (resp.reason === "reload") {
        this.log("error", () => [`failed mount with ${resp.status}. Falling back to page request`, resp]);
        if (this.isMain()) {
          this.onRedirect({ to: this.href });
        }
        return;
      } else if (resp.reason === "unauthorized" || resp.reason === "stale") {
        this.log("error", () => ["unauthorized live_redirect. Falling back to page request", resp]);
        if (this.isMain()) {
          this.onRedirect({ to: this.href });
        }
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
      this.displayError([PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_SERVER_ERROR_CLASS]);
      this.log("error", () => ["unable to join", resp]);
      if (this.liveSocket.isConnected()) {
        this.liveSocket.reloadWithJitter(this);
      }
    }
    onClose(reason) {
      if (this.isDestroyed()) {
        return;
      }
      if (this.liveSocket.hasPendingLink() && reason !== "leave") {
        return this.liveSocket.reloadWithJitter(this);
      }
      this.destroyAllChildren();
      this.liveSocket.dropActiveElement(this);
      if (document.activeElement) {
        document.activeElement.blur();
      }
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
          this.displayError([PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_SERVER_ERROR_CLASS]);
        } else {
          this.displayError([PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_CLIENT_ERROR_CLASS]);
        }
      }
    }
    displayError(classes) {
      if (this.isMain()) {
        dom_default.dispatchEvent(window, "phx:page-loading-start", { detail: { to: this.href, kind: "error" } });
      }
      this.showLoader();
      this.setContainerClasses(...classes);
      this.execAll(this.binding("disconnected"));
    }
    pushWithReply(refGenerator, event, payload, onReply = function() {
    }) {
      if (!this.isConnected()) {
        return;
      }
      let [ref, [el], opts] = refGenerator ? refGenerator() : [null, [], {}];
      let onLoadingDone = function() {
      };
      if (opts.page_loading || el && el.getAttribute(this.binding(PHX_PAGE_LOADING)) !== null) {
        onLoadingDone = this.liveSocket.withPageLoading({ kind: "element", target: el });
      }
      if (typeof payload.cid !== "number") {
        delete payload.cid;
      }
      return this.liveSocket.wrapPush(this, { timeout: true }, () => {
        return this.channel.push(event, payload, PUSH_TIMEOUT).receive("ok", (resp) => {
          let finish = (hookReply) => {
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
            onReply(resp, hookReply);
          };
          if (resp.diff) {
            this.liveSocket.requestDOMUpdate(() => {
              this.applyDiff("update", resp.diff, ({ diff, reply, events }) => {
                if (ref !== null) {
                  this.undoRefs(ref);
                }
                this.update(diff, events);
                finish(reply);
              });
            });
          } else {
            if (ref !== null) {
              this.undoRefs(ref);
            }
            finish(null);
          }
        });
      });
    }
    undoRefs(ref, onlyEls) {
      onlyEls = onlyEls ? new Set(onlyEls) : null;
      if (!this.isConnected()) {
        return;
      }
      dom_default.all(document, `[${PHX_REF_SRC}="${this.id}"][${PHX_REF}="${ref}"]`, (el) => {
        if (onlyEls && !onlyEls.has(el)) {
          return;
        }
        el.dispatchEvent(new CustomEvent("phx:unlock", { bubbles: true, cancelable: false }));
        let disabledVal = el.getAttribute(PHX_DISABLED);
        let readOnlyVal = el.getAttribute(PHX_READONLY);
        el.removeAttribute(PHX_REF);
        el.removeAttribute(PHX_REF_SRC);
        if (readOnlyVal !== null) {
          el.readOnly = readOnlyVal === "true" ? true : false;
          el.removeAttribute(PHX_READONLY);
        }
        if (disabledVal !== null) {
          el.disabled = disabledVal === "true" ? true : false;
          el.removeAttribute(PHX_DISABLED);
        }
        PHX_EVENT_CLASSES.forEach((className) => dom_default.removeClass(el, className));
        let disableRestore = el.getAttribute(PHX_DISABLE_WITH_RESTORE);
        if (disableRestore !== null) {
          el.innerText = disableRestore;
          el.removeAttribute(PHX_DISABLE_WITH_RESTORE);
        }
        let toEl = dom_default.private(el, PHX_REF);
        if (toEl) {
          let hook = this.triggerBeforeUpdateHook(el, toEl);
          DOMPatch.patchEl(el, toEl, this.liveSocket.getActiveElement());
          if (hook) {
            hook.__updated();
          }
          dom_default.deletePrivate(el, PHX_REF);
        }
      });
    }
    putRef(elements, event, opts = {}) {
      let newRef = this.ref++;
      let disableWith = this.binding(PHX_DISABLE_WITH);
      if (opts.loading) {
        elements = elements.concat(dom_default.all(document, opts.loading));
      }
      for (let el of elements) {
        el.setAttribute(PHX_REF, newRef);
        el.setAttribute(PHX_REF_SRC, this.el.id);
        if (opts.submitter && !(el === opts.submitter || el === opts.form)) {
          continue;
        }
        el.classList.add(`phx-${event}-loading`);
        el.dispatchEvent(new CustomEvent(`phx:${event}-loading`, { bubbles: true, cancelable: false }));
        let disableText = el.getAttribute(disableWith);
        if (disableText !== null) {
          if (!el.getAttribute(PHX_DISABLE_WITH_RESTORE)) {
            el.setAttribute(PHX_DISABLE_WITH_RESTORE, el.innerText);
          }
          if (disableText !== "") {
            el.innerText = disableText;
          }
          el.setAttribute(PHX_DISABLED, el.getAttribute(PHX_DISABLED) || el.disabled);
          el.setAttribute("disabled", "");
        }
      }
      return [newRef, elements, opts];
    }
    componentID(el) {
      let cid = el.getAttribute && el.getAttribute(PHX_COMPONENT);
      return cid ? parseInt(cid) : null;
    }
    targetComponentID(target, targetCtx, opts = {}) {
      if (isCid(targetCtx)) {
        return targetCtx;
      }
      let cidOrSelector = opts.target || target.getAttribute(this.binding("target"));
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
        return maybe(targetCtx.closest(`[${PHX_COMPONENT}]`), (el) => this.ownsElement(el) && this.componentID(el));
      } else {
        return null;
      }
    }
    pushHookEvent(el, targetCtx, event, payload, onReply) {
      if (!this.isConnected()) {
        this.log("hook", () => ["unable to push hook event. LiveView not connected", event, payload]);
        return false;
      }
      let [ref, els, opts] = this.putRef([el], "hook");
      this.pushWithReply(() => [ref, els, opts], "event", {
        type: "hook",
        event,
        value: payload,
        cid: this.closestComponentID(targetCtx)
      }, (resp, reply) => onReply(reply, ref));
      return ref;
    }
    extractMeta(el, meta, value) {
      let prefix = this.binding("value-");
      for (let i = 0; i < el.attributes.length; i++) {
        if (!meta) {
          meta = {};
        }
        let name = el.attributes[i].name;
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
        for (let key in value) {
          meta[key] = value[key];
        }
      }
      return meta;
    }
    pushEvent(type, el, targetCtx, phxEvent, meta, opts = {}, onReply) {
      this.pushWithReply(() => this.putRef([el], type, opts), "event", {
        type,
        event: phxEvent,
        value: this.extractMeta(el, meta, opts.value),
        cid: this.targetComponentID(el, targetCtx, opts)
      }, (resp, reply) => onReply && onReply(reply));
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
        }, onReply);
      });
    }
    pushInput(inputEl, targetCtx, forceCid, phxEvent, opts, callback) {
      let uploads;
      let cid = isCid(forceCid) ? forceCid : this.targetComponentID(inputEl.form, targetCtx, opts);
      let refGenerator = () => this.putRef([inputEl, inputEl.form], "change", opts);
      let formData;
      let meta = this.extractMeta(inputEl.form);
      if (inputEl instanceof HTMLButtonElement) {
        meta.submitter = inputEl;
      }
      if (inputEl.getAttribute(this.binding("change"))) {
        formData = serializeForm(inputEl.form, __spreadValues({ _target: opts._target }, meta), [inputEl.name]);
      } else {
        formData = serializeForm(inputEl.form, __spreadValues({ _target: opts._target }, meta));
      }
      if (dom_default.isUploadInput(inputEl) && inputEl.files && inputEl.files.length > 0) {
        LiveUploader.trackFiles(inputEl, Array.from(inputEl.files));
      }
      uploads = LiveUploader.serializeUploads(inputEl);
      let event = {
        type: "form",
        event: phxEvent,
        value: formData,
        uploads,
        cid
      };
      this.pushWithReply(refGenerator, "event", event, (resp) => {
        dom_default.showError(inputEl, this.liveSocket.binding(PHX_FEEDBACK_FOR), this.liveSocket.binding(PHX_FEEDBACK_GROUP));
        if (dom_default.isUploadInput(inputEl) && dom_default.isAutoUpload(inputEl)) {
          if (LiveUploader.filesAwaitingPreflight(inputEl).length > 0) {
            let [ref, _els] = refGenerator();
            this.undoRefs(ref, [inputEl.form]);
            this.uploadFiles(inputEl.form, targetCtx, ref, cid, (_uploads) => {
              callback && callback(resp);
              this.triggerAwaitingSubmit(inputEl.form);
              this.undoRefs(ref);
            });
          }
        } else {
          callback && callback(resp);
        }
      });
    }
    triggerAwaitingSubmit(formEl) {
      let awaitingSubmit = this.getScheduledSubmit(formEl);
      if (awaitingSubmit) {
        let [_el, _ref, _opts, callback] = awaitingSubmit;
        this.cancelSubmit(formEl);
        callback();
      }
    }
    getScheduledSubmit(formEl) {
      return this.formSubmits.find(([el, _ref, _opts, _callback]) => el.isSameNode(formEl));
    }
    scheduleSubmit(formEl, ref, opts, callback) {
      if (this.getScheduledSubmit(formEl)) {
        return true;
      }
      this.formSubmits.push([formEl, ref, opts, callback]);
    }
    cancelSubmit(formEl) {
      this.formSubmits = this.formSubmits.filter(([el, ref, _callback]) => {
        if (el.isSameNode(formEl)) {
          this.undoRefs(ref);
          return false;
        } else {
          return true;
        }
      });
    }
    disableForm(formEl, opts = {}) {
      let filterIgnored = (el) => {
        let userIgnored = closestPhxBinding(el, `${this.binding(PHX_UPDATE)}=ignore`, el.form);
        return !(userIgnored || closestPhxBinding(el, "data-phx-update=ignore", el.form));
      };
      let filterDisables = (el) => {
        return el.hasAttribute(this.binding(PHX_DISABLE_WITH));
      };
      let filterButton = (el) => el.tagName == "BUTTON";
      let filterInput = (el) => ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName);
      let formElements = Array.from(formEl.elements);
      let disables = formElements.filter(filterDisables);
      let buttons = formElements.filter(filterButton).filter(filterIgnored);
      let inputs = formElements.filter(filterInput).filter(filterIgnored);
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
      formEl.setAttribute(this.binding(PHX_PAGE_LOADING), "");
      return this.putRef([formEl].concat(disables).concat(buttons).concat(inputs), "submit", opts);
    }
    pushFormSubmit(formEl, targetCtx, phxEvent, submitter, opts, onReply) {
      let refGenerator = () => this.disableForm(formEl, __spreadProps(__spreadValues({}, opts), { form: formEl, submitter }));
      let cid = this.targetComponentID(formEl, targetCtx);
      if (LiveUploader.hasUploadsInProgress(formEl)) {
        let [ref, _els] = refGenerator();
        let push = () => this.pushFormSubmit(formEl, targetCtx, phxEvent, submitter, opts, onReply);
        return this.scheduleSubmit(formEl, ref, opts, push);
      } else if (LiveUploader.inputsAwaitingPreflight(formEl).length > 0) {
        let [ref, els] = refGenerator();
        let proxyRefGen = () => [ref, els, opts];
        this.uploadFiles(formEl, targetCtx, ref, cid, (uploads) => {
          if (LiveUploader.inputsAwaitingPreflight(formEl).length > 0) {
            return this.undoRefs(ref);
          }
          let meta = this.extractMeta(formEl);
          let formData = serializeForm(formEl, __spreadValues({ submitter }, meta));
          this.pushWithReply(proxyRefGen, "event", {
            type: "form",
            event: phxEvent,
            value: formData,
            cid
          }, onReply);
        });
      } else if (!(formEl.hasAttribute(PHX_REF) && formEl.classList.contains("phx-submit-loading"))) {
        let meta = this.extractMeta(formEl);
        let formData = serializeForm(formEl, __spreadValues({ submitter }, meta));
        this.pushWithReply(refGenerator, "event", {
          type: "form",
          event: phxEvent,
          value: formData,
          cid
        }, onReply);
      }
    }
    uploadFiles(formEl, targetCtx, ref, cid, onComplete) {
      let joinCountAtUpload = this.joinCount;
      let inputEls = LiveUploader.activeFileInputs(formEl);
      let numFileInputsInProgress = inputEls.length;
      inputEls.forEach((inputEl) => {
        let uploader = new LiveUploader(inputEl, this, () => {
          numFileInputsInProgress--;
          if (numFileInputsInProgress === 0) {
            onComplete();
          }
        });
        let entries = uploader.entries().map((entry) => entry.toPreflightPayload());
        if (entries.length === 0) {
          numFileInputsInProgress--;
          return;
        }
        let payload = {
          ref: inputEl.getAttribute(PHX_UPLOAD_REF),
          entries,
          cid: this.targetComponentID(inputEl.form, targetCtx)
        };
        this.log("upload", () => ["sending preflight request", payload]);
        this.pushWithReply(null, "allow_upload", payload, (resp) => {
          this.log("upload", () => ["got preflight response", resp]);
          uploader.entries().forEach((entry) => {
            if (resp.entries && !resp.entries[entry.ref]) {
              this.handleFailedEntryPreflight(entry.ref, "failed preflight", uploader);
            }
          });
          if (resp.error || Object.keys(resp.entries).length === 0) {
            this.undoRefs(ref);
            let errors = resp.error || [];
            errors.map(([entry_ref, reason]) => {
              this.handleFailedEntryPreflight(entry_ref, reason, uploader);
            });
          } else {
            let onError = (callback) => {
              this.channel.onError(() => {
                if (this.joinCount === joinCountAtUpload) {
                  callback();
                }
              });
            };
            uploader.initAdapterUpload(resp, onError, this.liveSocket);
          }
        });
      });
    }
    handleFailedEntryPreflight(uploadRef, reason, uploader) {
      if (uploader.isAutoUpload()) {
        let entry = uploader.entries().find((entry2) => entry2.ref === uploadRef.toString());
        if (entry) {
          entry.cancel();
        }
      } else {
        uploader.entries().map((entry) => entry.cancel());
      }
      this.log("upload", () => [`error for entry ${uploadRef}`, reason]);
    }
    dispatchUploads(targetCtx, name, filesOrBlobs) {
      let targetElement = this.targetCtxElement(targetCtx) || this.el;
      let inputs = dom_default.findUploadInputs(targetElement).filter((el) => el.name === name);
      if (inputs.length === 0) {
        logError(`no live file inputs found matching the name "${name}"`);
      } else if (inputs.length > 1) {
        logError(`duplicate live file inputs found matching the name "${name}"`);
      } else {
        dom_default.dispatchEvent(inputs[0], PHX_TRACK_UPLOADS, { detail: { files: filesOrBlobs } });
      }
    }
    targetCtxElement(targetCtx) {
      if (isCid(targetCtx)) {
        let [target] = dom_default.findComponentNodeList(this.el, targetCtx);
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
      const inputs = Array.from(oldForm.elements).filter((el) => dom_default.isFormInput(el) && el.name && !el.hasAttribute(phxChange));
      if (inputs.length === 0) {
        return;
      }
      inputs.forEach((input2) => input2.hasAttribute(PHX_UPLOAD_REF) && LiveUploader.clearFiles(input2));
      let input = inputs.find((el) => el.type !== "hidden") || inputs[0];
      let pending = 0;
      this.withinTargets(phxTarget, (targetView, targetCtx) => {
        const cid = this.targetComponentID(newForm, targetCtx);
        pending++;
        targetView.pushInput(input, targetCtx, cid, phxEvent, { _target: input.name }, () => {
          pending--;
          if (pending === 0) {
            callback();
          }
        });
      }, templateDom, templateDom);
    }
    pushLinkPatch(href, targetEl, callback) {
      let linkRef = this.liveSocket.setPendingLink(href);
      let refGen = targetEl ? () => this.putRef([targetEl], "click") : null;
      let fallback = () => this.liveSocket.redirect(window.location.href);
      let url = href.startsWith("/") ? `${location.protocol}//${location.host}${href}` : href;
      let push = this.pushWithReply(refGen, "live_patch", { url }, (resp) => {
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
      });
      if (push) {
        push.receive("timeout", fallback);
      } else {
        fallback();
      }
    }
    getFormsForRecovery() {
      if (this.joinCount === 0) {
        return {};
      }
      let phxChange = this.binding("change");
      return dom_default.all(this.el, `form[${phxChange}]`).filter((form) => form.id).filter((form) => form.elements.length > 0).filter((form) => form.getAttribute(this.binding(PHX_AUTO_RECOVER)) !== "ignore").map((form) => form.cloneNode(true)).reduce((acc, form) => {
        acc[form.id] = form;
        return acc;
      }, {});
    }
    maybePushComponentsDestroyed(destroyedCIDs) {
      let willDestroyCIDs = destroyedCIDs.filter((cid) => {
        return dom_default.findComponentNodeList(this.el, cid).length === 0;
      });
      if (willDestroyCIDs.length > 0) {
        willDestroyCIDs.forEach((cid) => this.rendered.resetRender(cid));
        this.pushWithReply(null, "cids_will_destroy", { cids: willDestroyCIDs }, () => {
          this.liveSocket.requestDOMUpdate(() => {
            let completelyDestroyCIDs = willDestroyCIDs.filter((cid) => {
              return dom_default.findComponentNodeList(this.el, cid).length === 0;
            });
            if (completelyDestroyCIDs.length > 0) {
              this.pushWithReply(null, "cids_destroyed", { cids: completelyDestroyCIDs }, (resp) => {
                this.rendered.pruneCIDs(resp.cids);
              });
            }
          });
        });
      }
    }
    ownsElement(el) {
      let parentViewEl = el.closest(PHX_VIEW_SELECTOR);
      return el.getAttribute(PHX_PARENT_ID) === this.id || parentViewEl && parentViewEl.id === this.id || !parentViewEl && this.isDead;
    }
    submitForm(form, targetCtx, phxEvent, submitter, opts = {}) {
      dom_default.putPrivate(form, PHX_HAS_SUBMITTED, true);
      const phxFeedbackFor = this.liveSocket.binding(PHX_FEEDBACK_FOR);
      const phxFeedbackGroup = this.liveSocket.binding(PHX_FEEDBACK_GROUP);
      const inputs = Array.from(form.elements);
      inputs.forEach((input) => dom_default.putPrivate(input, PHX_HAS_SUBMITTED, true));
      this.liveSocket.blurActiveElement(this);
      this.pushFormSubmit(form, targetCtx, phxEvent, submitter, opts, () => {
        inputs.forEach((input) => dom_default.showError(input, phxFeedbackFor, phxFeedbackGroup));
        this.liveSocket.restorePreviouslyActiveFocus();
      });
    }
    binding(kind) {
      return this.liveSocket.binding(kind);
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
      this.activeElement = null;
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
      this.reloadWithJitterTimer = null;
      this.maxReloads = opts.maxReloads || MAX_RELOADS;
      this.reloadJitterMin = opts.reloadJitterMin || RELOAD_JITTER_MIN;
      this.reloadJitterMax = opts.reloadJitterMax || RELOAD_JITTER_MAX;
      this.failsafeJitter = opts.failsafeJitter || FAILSAFE_JITTER;
      this.localStorage = opts.localStorage || window.localStorage;
      this.sessionStorage = opts.sessionStorage || window.sessionStorage;
      this.boundTopLevelEvents = false;
      this.serverCloseRef = null;
      this.domCallbacks = Object.assign({
        onPatchStart: closure2(),
        onPatchEnd: closure2(),
        onNodeAdded: closure2(),
        onBeforeElUpdated: closure2()
      }, opts.dom || {});
      this.transitions = new TransitionSet();
      window.addEventListener("pagehide", (_e) => {
        this.unloaded = true;
      });
      this.socket.onOpen(() => {
        if (this.isUnloaded()) {
          window.location.reload();
        }
      });
    }
    version() {
      return "0.20.17";
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
      console.log("latency simulator enabled for the duration of this browser session. Call disableLatencySim() to disable");
      this.sessionStorage.setItem(PHX_LV_LATENCY_SIM, upperBoundMs);
    }
    disableLatencySim() {
      this.sessionStorage.removeItem(PHX_LV_LATENCY_SIM);
    }
    getLatencySim() {
      let str = this.sessionStorage.getItem(PHX_LV_LATENCY_SIM);
      return str ? parseInt(str) : null;
    }
    getSocket() {
      return this.socket;
    }
    connect() {
      if (window.location.hostname === "localhost" && !this.isDebugDisabled()) {
        this.enableDebug();
      }
      let doConnect = () => {
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
      this.owner(el, (view) => js_default.exec(eventType, encodedJS, view, el));
    }
    execJSHookPush(el, phxEvent, data, callback) {
      this.withinOwners(el, (view) => {
        js_default.exec("hook", phxEvent, view, el, ["push", { data, callback }]);
      });
    }
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
      let result = func();
      console.timeEnd(name);
      return result;
    }
    log(view, kind, msgCallback) {
      if (this.viewLogger) {
        let [msg, obj] = msgCallback();
        this.viewLogger(view, kind, msg, obj);
      } else if (this.isDebugEnabled()) {
        let [msg, obj] = msgCallback();
        debug(view, kind, msg, obj);
      }
    }
    requestDOMUpdate(callback) {
      this.transitions.after(callback);
    }
    transition(time, onStart, onDone = function() {
    }) {
      this.transitions.addTransition(time, onStart, onDone);
    }
    onChannel(channel, event, cb) {
      channel.on(event, (data) => {
        let latency = this.getLatencySim();
        if (!latency) {
          cb(data);
        } else {
          setTimeout(() => cb(data), latency);
        }
      });
    }
    wrapPush(view, opts, push) {
      let latency = this.getLatencySim();
      let oldJoinCount = view.joinCount;
      if (!latency) {
        if (this.isConnected() && opts.timeout) {
          return push().receive("timeout", () => {
            if (view.joinCount === oldJoinCount && !view.isDestroyed()) {
              this.reloadWithJitter(view, () => {
                this.log(view, "timeout", () => ["received timeout while communicating with server. Falling back to hard refresh for recovery"]);
              });
            }
          });
        } else {
          return push();
        }
      }
      let fakePush = {
        receives: [],
        receive(kind, cb) {
          this.receives.push([kind, cb]);
        }
      };
      setTimeout(() => {
        if (view.isDestroyed()) {
          return;
        }
        fakePush.receives.reduce((acc, [kind, cb]) => acc.receive(kind, cb), push());
      }, latency);
      return fakePush;
    }
    reloadWithJitter(view, log) {
      clearTimeout(this.reloadWithJitterTimer);
      this.disconnect();
      let minMs = this.reloadJitterMin;
      let maxMs = this.reloadJitterMax;
      let afterMs = Math.floor(Math.random() * (maxMs - minMs + 1)) + minMs;
      let tries = browser_default.updateLocal(this.localStorage, window.location.pathname, CONSECUTIVE_RELOADS, 0, (count) => count + 1);
      if (tries > this.maxReloads) {
        afterMs = this.failsafeJitter;
      }
      this.reloadWithJitterTimer = setTimeout(() => {
        if (view.isDestroyed() || view.isConnected()) {
          return;
        }
        view.destroy();
        log ? log() : this.log(view, "join", () => [`encountered ${tries} consecutive reloads`]);
        if (tries > this.maxReloads) {
          this.log(view, "join", () => [`exceeded ${this.maxReloads} consecutive reloads. Entering failsafe mode`]);
        }
        if (this.hasPendingLink()) {
          window.location = this.pendingLink;
        } else {
          window.location.reload();
        }
      }, afterMs);
    }
    getHookCallbacks(name) {
      return name && name.startsWith("Phoenix.") ? hooks_default[name.split(".")[1]] : this.hooks[name];
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
      let body = document.body;
      if (body && !this.isPhxView(body) && !this.isPhxView(document.firstElementChild)) {
        let view = this.newRootView(body);
        view.setHref(this.getHref());
        view.joinDead();
        if (!this.main) {
          this.main = view;
        }
        window.requestAnimationFrame(() => view.execNewMounted());
      }
    }
    joinRootViews() {
      let rootsFound = false;
      dom_default.all(document, `${PHX_VIEW_SELECTOR}:not([${PHX_PARENT_ID}])`, (rootEl) => {
        if (!this.getRootById(rootEl.id)) {
          let view = this.newRootView(rootEl);
          view.setHref(this.getHref());
          view.join();
          if (rootEl.hasAttribute(PHX_MAIN)) {
            this.main = view;
          }
        }
        rootsFound = true;
      });
      return rootsFound;
    }
    redirect(to, flash) {
      this.unload();
      browser_default.redirect(to, flash);
    }
    replaceMain(href, flash, callback = null, linkRef = this.setPendingLink(href)) {
      let liveReferer = this.currentLocation.href;
      this.outgoingMainEl = this.outgoingMainEl || this.main.el;
      let newMainEl = dom_default.cloneNode(this.outgoingMainEl, "");
      this.main.showLoader(this.loaderTimeout);
      this.main.destroy();
      this.main = this.newRootView(newMainEl, flash, liveReferer);
      this.main.setRedirect(href);
      this.transitionRemoves(null, true);
      this.main.join((joinCount, onDone) => {
        if (joinCount === 1 && this.commitPendingLink(linkRef)) {
          this.requestDOMUpdate(() => {
            dom_default.findPhxSticky(document).forEach((el) => newMainEl.appendChild(el));
            this.outgoingMainEl.replaceWith(newMainEl);
            this.outgoingMainEl = null;
            callback && callback(linkRef);
            onDone();
          });
        }
      });
    }
    transitionRemoves(elements, skipSticky) {
      let removeAttr = this.binding("remove");
      elements = elements || dom_default.all(document, `[${removeAttr}]`);
      if (skipSticky) {
        const stickies = dom_default.findPhxSticky(document) || [];
        elements = elements.filter((el) => !dom_default.isChildOfAny(el, stickies));
      }
      elements.forEach((el) => {
        this.execJS(el, el.getAttribute(removeAttr), "remove");
      });
    }
    isPhxView(el) {
      return el.getAttribute && el.getAttribute(PHX_SESSION) !== null;
    }
    newRootView(el, flash, liveReferer) {
      let view = new View(el, this, null, flash, liveReferer);
      this.roots[view.id] = view;
      return view;
    }
    owner(childEl, callback) {
      let view = maybe(childEl.closest(PHX_VIEW_SELECTOR), (el) => this.getViewByEl(el)) || this.main;
      if (view) {
        callback(view);
      }
    }
    withinOwners(childEl, callback) {
      this.owner(childEl, (view) => callback(view, childEl));
    }
    getViewByEl(el) {
      let rootId = el.getAttribute(PHX_ROOT_ID);
      return maybe(this.getRootById(rootId), (root) => root.getDescendentByEl(el));
    }
    getRootById(id) {
      return this.roots[id];
    }
    destroyAllViews() {
      for (let id in this.roots) {
        this.roots[id].destroy();
        delete this.roots[id];
      }
      this.main = null;
    }
    destroyViewByEl(el) {
      let root = this.getRootById(el.getAttribute(PHX_ROOT_ID));
      if (root && root.id === el.id) {
        root.destroy();
        delete this.roots[root.id];
      } else if (root) {
        root.destroyDescendent(el.id);
      }
    }
    setActiveElement(target) {
      if (this.activeElement === target) {
        return;
      }
      this.activeElement = target;
      let cancel = () => {
        if (target === this.activeElement) {
          this.activeElement = null;
        }
        target.removeEventListener("mouseup", this);
        target.removeEventListener("touchend", this);
      };
      target.addEventListener("mouseup", cancel);
      target.addEventListener("touchend", cancel);
    }
    getActiveElement() {
      if (document.activeElement === document.body) {
        return this.activeElement || document.activeElement;
      } else {
        return document.activeElement || document.body;
      }
    }
    dropActiveElement(view) {
      if (this.prevActive && view.ownsElement(this.prevActive)) {
        this.prevActive = null;
      }
    }
    restorePreviouslyActiveFocus() {
      if (this.prevActive && this.prevActive !== document.body) {
        this.prevActive.focus();
      }
    }
    blurActiveElement() {
      this.prevActive = this.getActiveElement();
      if (this.prevActive !== document.body) {
        this.prevActive.blur();
      }
    }
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
      window.addEventListener("pageshow", (e) => {
        if (e.persisted) {
          this.getSocket().disconnect();
          this.withPageLoading({ to: window.location.href, kind: "redirect" });
          window.location.reload();
        }
      }, true);
      if (!dead) {
        this.bindNav();
      }
      this.bindClicks();
      if (!dead) {
        this.bindForms();
      }
      this.bind({ keyup: "keyup", keydown: "keydown" }, (e, type, view, targetEl, phxEvent, phxTarget) => {
        let matchKey = targetEl.getAttribute(this.binding(PHX_KEY));
        let pressedKey = e.key && e.key.toLowerCase();
        if (matchKey && matchKey.toLowerCase() !== pressedKey) {
          return;
        }
        let data = __spreadValues({ key: e.key }, this.eventMeta(type, e, targetEl));
        js_default.exec(type, phxEvent, view, targetEl, ["push", { data }]);
      });
      this.bind({ blur: "focusout", focus: "focusin" }, (e, type, view, targetEl, phxEvent, phxTarget) => {
        if (!phxTarget) {
          let data = __spreadValues({ key: e.key }, this.eventMeta(type, e, targetEl));
          js_default.exec(type, phxEvent, view, targetEl, ["push", { data }]);
        }
      });
      this.bind({ blur: "blur", focus: "focus" }, (e, type, view, targetEl, phxEvent, phxTarget) => {
        if (phxTarget === "window") {
          let data = this.eventMeta(type, e, targetEl);
          js_default.exec(type, phxEvent, view, targetEl, ["push", { data }]);
        }
      });
      window.addEventListener("dragover", (e) => e.preventDefault());
      window.addEventListener("drop", (e) => {
        e.preventDefault();
        let dropTargetId = maybe(closestPhxBinding(e.target, this.binding(PHX_DROP_TARGET)), (trueTarget) => {
          return trueTarget.getAttribute(this.binding(PHX_DROP_TARGET));
        });
        let dropTarget = dropTargetId && document.getElementById(dropTargetId);
        let files = Array.from(e.dataTransfer.files || []);
        if (!dropTarget || dropTarget.disabled || files.length === 0 || !(dropTarget.files instanceof FileList)) {
          return;
        }
        LiveUploader.trackFiles(dropTarget, files, e.dataTransfer);
        dropTarget.dispatchEvent(new Event("input", { bubbles: true }));
      });
      this.on(PHX_TRACK_UPLOADS, (e) => {
        let uploadTarget = e.target;
        if (!dom_default.isUploadInput(uploadTarget)) {
          return;
        }
        let files = Array.from(e.detail.files || []).filter((f) => f instanceof File || f instanceof Blob);
        LiveUploader.trackFiles(uploadTarget, files);
        uploadTarget.dispatchEvent(new Event("input", { bubbles: true }));
      });
    }
    eventMeta(eventName, e, targetEl) {
      let callback = this.metadataCallbacks[eventName];
      return callback ? callback(e, targetEl) : {};
    }
    setPendingLink(href) {
      this.linkRef++;
      this.pendingLink = href;
      return this.linkRef;
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
      for (let event in events) {
        let browserEventName = events[event];
        this.on(browserEventName, (e) => {
          let binding = this.binding(event);
          let windowBinding = this.binding(`window-${event}`);
          let targetPhxEvent = e.target.getAttribute && e.target.getAttribute(binding);
          if (targetPhxEvent) {
            this.debounce(e.target, e, browserEventName, () => {
              this.withinOwners(e.target, (view) => {
                callback(e, event, view, e.target, targetPhxEvent, null);
              });
            });
          } else {
            dom_default.all(document, `[${windowBinding}]`, (el) => {
              let phxEvent = el.getAttribute(windowBinding);
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
      window.addEventListener("mousedown", (e) => this.clickStartedAtTarget = e.target);
      this.bindClick("click", "click");
    }
    bindClick(eventName, bindingName) {
      let click = this.binding(bindingName);
      window.addEventListener(eventName, (e) => {
        let target = null;
        if (e.detail === 0)
          this.clickStartedAtTarget = e.target;
        let clickStartedAtTarget = this.clickStartedAtTarget || e.target;
        target = closestPhxBinding(clickStartedAtTarget, click);
        this.dispatchClickAway(e, clickStartedAtTarget);
        this.clickStartedAtTarget = null;
        let phxEvent = target && target.getAttribute(click);
        if (!phxEvent) {
          if (dom_default.isNewPageClick(e, window.location)) {
            this.unload();
          }
          return;
        }
        if (target.getAttribute("href") === "#") {
          e.preventDefault();
        }
        if (target.hasAttribute(PHX_REF)) {
          return;
        }
        this.debounce(target, e, "click", () => {
          this.withinOwners(target, (view) => {
            js_default.exec("click", phxEvent, view, target, ["push", { data: this.eventMeta("click", e, target) }]);
          });
        });
      }, false);
    }
    dispatchClickAway(e, clickStartedAt) {
      let phxClickAway = this.binding("click-away");
      dom_default.all(document, `[${phxClickAway}]`, (el) => {
        if (!(el.isSameNode(clickStartedAt) || el.contains(clickStartedAt))) {
          this.withinOwners(el, (view) => {
            let phxEvent = el.getAttribute(phxClickAway);
            if (js_default.isVisible(el) && js_default.isInViewport(el)) {
              js_default.exec("click", phxEvent, view, el, ["push", { data: this.eventMeta("click", e, e.target) }]);
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
          browser_default.updateCurrentState((state) => Object.assign(state, { scroll: window.scrollY }));
        }, 100);
      });
      window.addEventListener("popstate", (event) => {
        if (!this.registerNewLocation(window.location)) {
          return;
        }
        let { type, id, root, scroll } = event.state || {};
        let href = window.location.href;
        dom_default.dispatchEvent(window, "phx:navigate", { detail: { href, patch: type === "patch", pop: true } });
        this.requestDOMUpdate(() => {
          if (this.main.isConnected() && (type === "patch" && id === this.main.id)) {
            this.main.pushLinkPatch(href, null, () => {
              this.maybeScroll(scroll);
            });
          } else {
            this.replaceMain(href, null, () => {
              if (root) {
                this.replaceRootHistory();
              }
              this.maybeScroll(scroll);
            });
          }
        });
      }, false);
      window.addEventListener("click", (e) => {
        let target = closestPhxBinding(e.target, PHX_LIVE_LINK);
        let type = target && target.getAttribute(PHX_LIVE_LINK);
        if (!type || !this.isConnected() || !this.main || dom_default.wantsNewTab(e)) {
          return;
        }
        let href = target.href instanceof SVGAnimatedString ? target.href.baseVal : target.href;
        let linkState = target.getAttribute(PHX_LINK_STATE);
        e.preventDefault();
        e.stopImmediatePropagation();
        if (this.pendingLink === href) {
          return;
        }
        this.requestDOMUpdate(() => {
          if (type === "patch") {
            this.pushHistoryPatch(href, linkState, target);
          } else if (type === "redirect") {
            this.historyRedirect(href, linkState);
          } else {
            throw new Error(`expected ${PHX_LIVE_LINK} to be "patch" or "redirect", got: ${type}`);
          }
          let phxClick = target.getAttribute(this.binding("click"));
          if (phxClick) {
            this.requestDOMUpdate(() => this.execJS(target, phxClick, "click"));
          }
        });
      }, false);
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
      let done = () => dom_default.dispatchEvent(window, "phx:page-loading-stop", { detail: info });
      return callback ? callback(done) : done;
    }
    pushHistoryPatch(href, linkState, targetEl) {
      if (!this.isConnected() || !this.main.isMain()) {
        return browser_default.redirect(href);
      }
      this.withPageLoading({ to: href, kind: "patch" }, (done) => {
        this.main.pushLinkPatch(href, targetEl, (linkRef) => {
          this.historyPatch(href, linkState, linkRef);
          done();
        });
      });
    }
    historyPatch(href, linkState, linkRef = this.setPendingLink(href)) {
      if (!this.commitPendingLink(linkRef)) {
        return;
      }
      browser_default.pushState(linkState, { type: "patch", id: this.main.id }, href);
      dom_default.dispatchEvent(window, "phx:navigate", { detail: { patch: true, href, pop: false } });
      this.registerNewLocation(window.location);
    }
    historyRedirect(href, linkState, flash) {
      if (!this.isConnected() || !this.main.isMain()) {
        return browser_default.redirect(href, flash);
      }
      if (/^\/$|^\/[^\/]+.*$/.test(href)) {
        let { protocol, host } = window.location;
        href = `${protocol}//${host}${href}`;
      }
      let scroll = window.scrollY;
      this.withPageLoading({ to: href, kind: "redirect" }, (done) => {
        this.replaceMain(href, flash, (linkRef) => {
          if (linkRef === this.linkRef) {
            browser_default.pushState(linkState, { type: "redirect", id: this.main.id, scroll }, href);
            dom_default.dispatchEvent(window, "phx:navigate", { detail: { href, patch: false, pop: false } });
            this.registerNewLocation(window.location);
          }
          done();
        });
      });
    }
    replaceRootHistory() {
      browser_default.pushState("replace", { root: true, type: "patch", id: this.main.id });
    }
    registerNewLocation(newLocation) {
      let { pathname, search } = this.currentLocation;
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
        let phxSubmit = e.target.getAttribute(this.binding("submit"));
        let phxChange = e.target.getAttribute(this.binding("change"));
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
      }, true);
      this.on("submit", (e) => {
        let phxEvent = e.target.getAttribute(this.binding("submit"));
        if (!phxEvent) {
          if (dom_default.isUnloadableFormSubmit(e)) {
            this.unload();
          }
          return;
        }
        e.preventDefault();
        e.target.disabled = true;
        this.withinOwners(e.target, (view) => {
          js_default.exec("submit", phxEvent, view, e.target, ["push", { submitter: e.submitter }]);
        });
      }, false);
      for (let type of ["change", "input"]) {
        this.on(type, (e) => {
          let phxChange = this.binding("change");
          let input = e.target;
          let inputEvent = input.getAttribute(phxChange);
          let formEvent = input.form && input.form.getAttribute(phxChange);
          let phxEvent = inputEvent || formEvent;
          if (!phxEvent) {
            return;
          }
          if (input.type === "number" && input.validity && input.validity.badInput) {
            return;
          }
          let dispatcher = inputEvent ? input : input.form;
          let currentIterations = iterations;
          iterations++;
          let { at, type: lastType } = dom_default.private(input, "prev-iteration") || {};
          if (at === currentIterations - 1 && type === "change" && lastType === "input") {
            return;
          }
          dom_default.putPrivate(input, "prev-iteration", { at: currentIterations, type });
          this.debounce(input, e, type, () => {
            this.withinOwners(dispatcher, (view) => {
              dom_default.putPrivate(input, PHX_HAS_FOCUSED, true);
              if (!dom_default.isTextualInput(input)) {
                this.setActiveElement(input);
              }
              js_default.exec("change", phxEvent, view, input, ["push", { _target: e.target.name, dispatcher }]);
            });
          });
        }, false);
      }
      this.on("reset", (e) => {
        let form = e.target;
        dom_default.resetForm(form, this.binding(PHX_FEEDBACK_FOR), this.binding(PHX_FEEDBACK_GROUP));
        let input = Array.from(form.elements).find((el) => el.type === "reset");
        if (input) {
          window.requestAnimationFrame(() => {
            input.dispatchEvent(new Event("input", { bubbles: true, cancelable: false }));
          });
        }
      });
    }
    debounce(el, event, eventType, callback) {
      if (eventType === "blur" || eventType === "focusout") {
        return callback();
      }
      let phxDebounce = this.binding(PHX_DEBOUNCE);
      let phxThrottle = this.binding(PHX_THROTTLE);
      let defaultDebounce = this.defaults.debounce.toString();
      let defaultThrottle = this.defaults.throttle.toString();
      this.withinOwners(el, (view) => {
        let asyncFilter = () => !view.isDestroyed() && document.body.contains(el);
        dom_default.debounce(el, event, phxDebounce, defaultDebounce, phxThrottle, defaultThrottle, asyncFilter, () => {
          callback();
        });
      });
    }
    silenceEvents(callback) {
      this.silenced = true;
      callback();
      this.silenced = false;
    }
    on(event, callback) {
      window.addEventListener(event, (e) => {
        if (!this.silenced) {
          callback(e);
        }
      });
    }
  };
  var TransitionSet = class {
    constructor() {
      this.transitions = /* @__PURE__ */ new Set();
      this.pendingOps = [];
    }
    reset() {
      this.transitions.forEach((timer) => {
        clearTimeout(timer);
        this.transitions.delete(timer);
      });
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
      let timer = setTimeout(() => {
        this.transitions.delete(timer);
        onDone();
        this.flushPendingOps();
      }, time);
      this.transitions.add(timer);
    }
    pushPendingOp(op) {
      this.pendingOps.push(op);
    }
    size() {
      return this.transitions.size;
    }
    flushPendingOps() {
      if (this.size() > 0) {
        return;
      }
      let op = this.pendingOps.shift();
      if (op) {
        op();
        this.flushPendingOps();
      }
    }
  };

  // js/app.js
  var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken }
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vLi4vZGVwcy9waG9lbml4X2h0bWwvcHJpdi9zdGF0aWMvcGhvZW5peF9odG1sLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC91dGlscy5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvY29uc3RhbnRzLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC9wdXNoLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC90aW1lci5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvY2hhbm5lbC5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvYWpheC5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXgvYXNzZXRzL2pzL3Bob2VuaXgvbG9uZ3BvbGwuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4L2Fzc2V0cy9qcy9waG9lbml4L3ByZXNlbmNlLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC9zZXJpYWxpemVyLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peC9hc3NldHMvanMvcGhvZW5peC9zb2NrZXQuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvY29uc3RhbnRzLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2VudHJ5X3VwbG9hZGVyLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L3V0aWxzLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2Jyb3dzZXIuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvYXJpYS5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXhfbGl2ZV92aWV3L2Fzc2V0cy9qcy9waG9lbml4X2xpdmVfdmlldy9qcy5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXhfbGl2ZV92aWV3L2Fzc2V0cy9qcy9waG9lbml4X2xpdmVfdmlldy9kb20uanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvdXBsb2FkX2VudHJ5LmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2xpdmVfdXBsb2FkZXIuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvaG9va3MuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvZG9tX3Bvc3RfbW9ycGhfcmVzdG9yZXIuanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvbm9kZV9tb2R1bGVzL21vcnBoZG9tL2Rpc3QvbW9ycGhkb20tZXNtLmpzIiwgIi4uLy4uLy4uL2RlcHMvcGhvZW5peF9saXZlX3ZpZXcvYXNzZXRzL2pzL3Bob2VuaXhfbGl2ZV92aWV3L2RvbV9wYXRjaC5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXhfbGl2ZV92aWV3L2Fzc2V0cy9qcy9waG9lbml4X2xpdmVfdmlldy9yZW5kZXJlZC5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXhfbGl2ZV92aWV3L2Fzc2V0cy9qcy9waG9lbml4X2xpdmVfdmlldy92aWV3X2hvb2suanMiLCAiLi4vLi4vLi4vZGVwcy9waG9lbml4X2xpdmVfdmlldy9hc3NldHMvanMvcGhvZW5peF9saXZlX3ZpZXcvdmlldy5qcyIsICIuLi8uLi8uLi9kZXBzL3Bob2VuaXhfbGl2ZV92aWV3L2Fzc2V0cy9qcy9waG9lbml4X2xpdmVfdmlldy9saXZlX3NvY2tldC5qcyIsICIuLi8uLi8uLi9hc3NldHMvanMvYXBwLmpzIl0sCiAgInNvdXJjZXNDb250ZW50IjogWyJcInVzZSBzdHJpY3RcIjtcblxuKGZ1bmN0aW9uKCkge1xuICB2YXIgUG9seWZpbGxFdmVudCA9IGV2ZW50Q29uc3RydWN0b3IoKTtcblxuICBmdW5jdGlvbiBldmVudENvbnN0cnVjdG9yKCkge1xuICAgIGlmICh0eXBlb2Ygd2luZG93LkN1c3RvbUV2ZW50ID09PSBcImZ1bmN0aW9uXCIpIHJldHVybiB3aW5kb3cuQ3VzdG9tRXZlbnQ7XG4gICAgLy8gSUU8PTkgU3VwcG9ydFxuICAgIGZ1bmN0aW9uIEN1c3RvbUV2ZW50KGV2ZW50LCBwYXJhbXMpIHtcbiAgICAgIHBhcmFtcyA9IHBhcmFtcyB8fCB7YnViYmxlczogZmFsc2UsIGNhbmNlbGFibGU6IGZhbHNlLCBkZXRhaWw6IHVuZGVmaW5lZH07XG4gICAgICB2YXIgZXZ0ID0gZG9jdW1lbnQuY3JlYXRlRXZlbnQoJ0N1c3RvbUV2ZW50Jyk7XG4gICAgICBldnQuaW5pdEN1c3RvbUV2ZW50KGV2ZW50LCBwYXJhbXMuYnViYmxlcywgcGFyYW1zLmNhbmNlbGFibGUsIHBhcmFtcy5kZXRhaWwpO1xuICAgICAgcmV0dXJuIGV2dDtcbiAgICB9XG4gICAgQ3VzdG9tRXZlbnQucHJvdG90eXBlID0gd2luZG93LkV2ZW50LnByb3RvdHlwZTtcbiAgICByZXR1cm4gQ3VzdG9tRXZlbnQ7XG4gIH1cblxuICBmdW5jdGlvbiBidWlsZEhpZGRlbklucHV0KG5hbWUsIHZhbHVlKSB7XG4gICAgdmFyIGlucHV0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcImlucHV0XCIpO1xuICAgIGlucHV0LnR5cGUgPSBcImhpZGRlblwiO1xuICAgIGlucHV0Lm5hbWUgPSBuYW1lO1xuICAgIGlucHV0LnZhbHVlID0gdmFsdWU7XG4gICAgcmV0dXJuIGlucHV0O1xuICB9XG5cbiAgZnVuY3Rpb24gaGFuZGxlQ2xpY2soZWxlbWVudCwgdGFyZ2V0TW9kaWZpZXJLZXkpIHtcbiAgICB2YXIgdG8gPSBlbGVtZW50LmdldEF0dHJpYnV0ZShcImRhdGEtdG9cIiksXG4gICAgICAgIG1ldGhvZCA9IGJ1aWxkSGlkZGVuSW5wdXQoXCJfbWV0aG9kXCIsIGVsZW1lbnQuZ2V0QXR0cmlidXRlKFwiZGF0YS1tZXRob2RcIikpLFxuICAgICAgICBjc3JmID0gYnVpbGRIaWRkZW5JbnB1dChcIl9jc3JmX3Rva2VuXCIsIGVsZW1lbnQuZ2V0QXR0cmlidXRlKFwiZGF0YS1jc3JmXCIpKSxcbiAgICAgICAgZm9ybSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJmb3JtXCIpLFxuICAgICAgICBzdWJtaXQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwiaW5wdXRcIiksXG4gICAgICAgIHRhcmdldCA9IGVsZW1lbnQuZ2V0QXR0cmlidXRlKFwidGFyZ2V0XCIpO1xuXG4gICAgZm9ybS5tZXRob2QgPSAoZWxlbWVudC5nZXRBdHRyaWJ1dGUoXCJkYXRhLW1ldGhvZFwiKSA9PT0gXCJnZXRcIikgPyBcImdldFwiIDogXCJwb3N0XCI7XG4gICAgZm9ybS5hY3Rpb24gPSB0bztcbiAgICBmb3JtLnN0eWxlLmRpc3BsYXkgPSBcIm5vbmVcIjtcblxuICAgIGlmICh0YXJnZXQpIGZvcm0udGFyZ2V0ID0gdGFyZ2V0O1xuICAgIGVsc2UgaWYgKHRhcmdldE1vZGlmaWVyS2V5KSBmb3JtLnRhcmdldCA9IFwiX2JsYW5rXCI7XG5cbiAgICBmb3JtLmFwcGVuZENoaWxkKGNzcmYpO1xuICAgIGZvcm0uYXBwZW5kQ2hpbGQobWV0aG9kKTtcbiAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKGZvcm0pO1xuXG4gICAgLy8gSW5zZXJ0IGEgYnV0dG9uIGFuZCBjbGljayBpdCBpbnN0ZWFkIG9mIHVzaW5nIGBmb3JtLnN1Ym1pdGBcbiAgICAvLyBiZWNhdXNlIHRoZSBgc3VibWl0YCBmdW5jdGlvbiBkb2VzIG5vdCBlbWl0IGEgYHN1Ym1pdGAgZXZlbnQuXG4gICAgc3VibWl0LnR5cGUgPSBcInN1Ym1pdFwiO1xuICAgIGZvcm0uYXBwZW5kQ2hpbGQoc3VibWl0KTtcbiAgICBzdWJtaXQuY2xpY2soKTtcbiAgfVxuXG4gIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwiY2xpY2tcIiwgZnVuY3Rpb24oZSkge1xuICAgIHZhciBlbGVtZW50ID0gZS50YXJnZXQ7XG4gICAgaWYgKGUuZGVmYXVsdFByZXZlbnRlZCkgcmV0dXJuO1xuXG4gICAgd2hpbGUgKGVsZW1lbnQgJiYgZWxlbWVudC5nZXRBdHRyaWJ1dGUpIHtcbiAgICAgIHZhciBwaG9lbml4TGlua0V2ZW50ID0gbmV3IFBvbHlmaWxsRXZlbnQoJ3Bob2VuaXgubGluay5jbGljaycsIHtcbiAgICAgICAgXCJidWJibGVzXCI6IHRydWUsIFwiY2FuY2VsYWJsZVwiOiB0cnVlXG4gICAgICB9KTtcblxuICAgICAgaWYgKCFlbGVtZW50LmRpc3BhdGNoRXZlbnQocGhvZW5peExpbmtFdmVudCkpIHtcbiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpO1xuICAgICAgICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpO1xuICAgICAgICByZXR1cm4gZmFsc2U7XG4gICAgICB9XG5cbiAgICAgIGlmIChlbGVtZW50LmdldEF0dHJpYnV0ZShcImRhdGEtbWV0aG9kXCIpKSB7XG4gICAgICAgIGhhbmRsZUNsaWNrKGVsZW1lbnQsIGUubWV0YUtleSB8fCBlLnNoaWZ0S2V5KTtcbiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpO1xuICAgICAgICByZXR1cm4gZmFsc2U7XG4gICAgICB9IGVsc2Uge1xuICAgICAgICBlbGVtZW50ID0gZWxlbWVudC5wYXJlbnROb2RlO1xuICAgICAgfVxuICAgIH1cbiAgfSwgZmFsc2UpO1xuXG4gIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdwaG9lbml4LmxpbmsuY2xpY2snLCBmdW5jdGlvbiAoZSkge1xuICAgIHZhciBtZXNzYWdlID0gZS50YXJnZXQuZ2V0QXR0cmlidXRlKFwiZGF0YS1jb25maXJtXCIpO1xuICAgIGlmKG1lc3NhZ2UgJiYgIXdpbmRvdy5jb25maXJtKG1lc3NhZ2UpKSB7XG4gICAgICBlLnByZXZlbnREZWZhdWx0KCk7XG4gICAgfVxuICB9LCBmYWxzZSk7XG59KSgpO1xuIiwgIi8vIHdyYXBzIHZhbHVlIGluIGNsb3N1cmUgb3IgcmV0dXJucyBjbG9zdXJlXG5leHBvcnQgbGV0IGNsb3N1cmUgPSAodmFsdWUpID0+IHtcbiAgaWYodHlwZW9mIHZhbHVlID09PSBcImZ1bmN0aW9uXCIpe1xuICAgIHJldHVybiB2YWx1ZVxuICB9IGVsc2Uge1xuICAgIGxldCBjbG9zdXJlID0gZnVuY3Rpb24gKCl7IHJldHVybiB2YWx1ZSB9XG4gICAgcmV0dXJuIGNsb3N1cmVcbiAgfVxufVxuIiwgImV4cG9ydCBjb25zdCBnbG9iYWxTZWxmID0gdHlwZW9mIHNlbGYgIT09IFwidW5kZWZpbmVkXCIgPyBzZWxmIDogbnVsbFxuZXhwb3J0IGNvbnN0IHBoeFdpbmRvdyA9IHR5cGVvZiB3aW5kb3cgIT09IFwidW5kZWZpbmVkXCIgPyB3aW5kb3cgOiBudWxsXG5leHBvcnQgY29uc3QgZ2xvYmFsID0gZ2xvYmFsU2VsZiB8fCBwaHhXaW5kb3cgfHwgZ2xvYmFsXG5leHBvcnQgY29uc3QgREVGQVVMVF9WU04gPSBcIjIuMC4wXCJcbmV4cG9ydCBjb25zdCBTT0NLRVRfU1RBVEVTID0ge2Nvbm5lY3Rpbmc6IDAsIG9wZW46IDEsIGNsb3Npbmc6IDIsIGNsb3NlZDogM31cbmV4cG9ydCBjb25zdCBERUZBVUxUX1RJTUVPVVQgPSAxMDAwMFxuZXhwb3J0IGNvbnN0IFdTX0NMT1NFX05PUk1BTCA9IDEwMDBcbmV4cG9ydCBjb25zdCBDSEFOTkVMX1NUQVRFUyA9IHtcbiAgY2xvc2VkOiBcImNsb3NlZFwiLFxuICBlcnJvcmVkOiBcImVycm9yZWRcIixcbiAgam9pbmVkOiBcImpvaW5lZFwiLFxuICBqb2luaW5nOiBcImpvaW5pbmdcIixcbiAgbGVhdmluZzogXCJsZWF2aW5nXCIsXG59XG5leHBvcnQgY29uc3QgQ0hBTk5FTF9FVkVOVFMgPSB7XG4gIGNsb3NlOiBcInBoeF9jbG9zZVwiLFxuICBlcnJvcjogXCJwaHhfZXJyb3JcIixcbiAgam9pbjogXCJwaHhfam9pblwiLFxuICByZXBseTogXCJwaHhfcmVwbHlcIixcbiAgbGVhdmU6IFwicGh4X2xlYXZlXCJcbn1cblxuZXhwb3J0IGNvbnN0IFRSQU5TUE9SVFMgPSB7XG4gIGxvbmdwb2xsOiBcImxvbmdwb2xsXCIsXG4gIHdlYnNvY2tldDogXCJ3ZWJzb2NrZXRcIlxufVxuZXhwb3J0IGNvbnN0IFhIUl9TVEFURVMgPSB7XG4gIGNvbXBsZXRlOiA0XG59XG4iLCAiLyoqXG4gKiBJbml0aWFsaXplcyB0aGUgUHVzaFxuICogQHBhcmFtIHtDaGFubmVsfSBjaGFubmVsIC0gVGhlIENoYW5uZWxcbiAqIEBwYXJhbSB7c3RyaW5nfSBldmVudCAtIFRoZSBldmVudCwgZm9yIGV4YW1wbGUgYFwicGh4X2pvaW5cImBcbiAqIEBwYXJhbSB7T2JqZWN0fSBwYXlsb2FkIC0gVGhlIHBheWxvYWQsIGZvciBleGFtcGxlIGB7dXNlcl9pZDogMTIzfWBcbiAqIEBwYXJhbSB7bnVtYmVyfSB0aW1lb3V0IC0gVGhlIHB1c2ggdGltZW91dCBpbiBtaWxsaXNlY29uZHNcbiAqL1xuZXhwb3J0IGRlZmF1bHQgY2xhc3MgUHVzaCB7XG4gIGNvbnN0cnVjdG9yKGNoYW5uZWwsIGV2ZW50LCBwYXlsb2FkLCB0aW1lb3V0KXtcbiAgICB0aGlzLmNoYW5uZWwgPSBjaGFubmVsXG4gICAgdGhpcy5ldmVudCA9IGV2ZW50XG4gICAgdGhpcy5wYXlsb2FkID0gcGF5bG9hZCB8fCBmdW5jdGlvbiAoKXsgcmV0dXJuIHt9IH1cbiAgICB0aGlzLnJlY2VpdmVkUmVzcCA9IG51bGxcbiAgICB0aGlzLnRpbWVvdXQgPSB0aW1lb3V0XG4gICAgdGhpcy50aW1lb3V0VGltZXIgPSBudWxsXG4gICAgdGhpcy5yZWNIb29rcyA9IFtdXG4gICAgdGhpcy5zZW50ID0gZmFsc2VcbiAgfVxuXG4gIC8qKlxuICAgKlxuICAgKiBAcGFyYW0ge251bWJlcn0gdGltZW91dFxuICAgKi9cbiAgcmVzZW5kKHRpbWVvdXQpe1xuICAgIHRoaXMudGltZW91dCA9IHRpbWVvdXRcbiAgICB0aGlzLnJlc2V0KClcbiAgICB0aGlzLnNlbmQoKVxuICB9XG5cbiAgLyoqXG4gICAqXG4gICAqL1xuICBzZW5kKCl7XG4gICAgaWYodGhpcy5oYXNSZWNlaXZlZChcInRpbWVvdXRcIikpeyByZXR1cm4gfVxuICAgIHRoaXMuc3RhcnRUaW1lb3V0KClcbiAgICB0aGlzLnNlbnQgPSB0cnVlXG4gICAgdGhpcy5jaGFubmVsLnNvY2tldC5wdXNoKHtcbiAgICAgIHRvcGljOiB0aGlzLmNoYW5uZWwudG9waWMsXG4gICAgICBldmVudDogdGhpcy5ldmVudCxcbiAgICAgIHBheWxvYWQ6IHRoaXMucGF5bG9hZCgpLFxuICAgICAgcmVmOiB0aGlzLnJlZixcbiAgICAgIGpvaW5fcmVmOiB0aGlzLmNoYW5uZWwuam9pblJlZigpXG4gICAgfSlcbiAgfVxuXG4gIC8qKlxuICAgKlxuICAgKiBAcGFyYW0geyp9IHN0YXR1c1xuICAgKiBAcGFyYW0geyp9IGNhbGxiYWNrXG4gICAqL1xuICByZWNlaXZlKHN0YXR1cywgY2FsbGJhY2spe1xuICAgIGlmKHRoaXMuaGFzUmVjZWl2ZWQoc3RhdHVzKSl7XG4gICAgICBjYWxsYmFjayh0aGlzLnJlY2VpdmVkUmVzcC5yZXNwb25zZSlcbiAgICB9XG5cbiAgICB0aGlzLnJlY0hvb2tzLnB1c2goe3N0YXR1cywgY2FsbGJhY2t9KVxuICAgIHJldHVybiB0aGlzXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIHJlc2V0KCl7XG4gICAgdGhpcy5jYW5jZWxSZWZFdmVudCgpXG4gICAgdGhpcy5yZWYgPSBudWxsXG4gICAgdGhpcy5yZWZFdmVudCA9IG51bGxcbiAgICB0aGlzLnJlY2VpdmVkUmVzcCA9IG51bGxcbiAgICB0aGlzLnNlbnQgPSBmYWxzZVxuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBtYXRjaFJlY2VpdmUoe3N0YXR1cywgcmVzcG9uc2UsIF9yZWZ9KXtcbiAgICB0aGlzLnJlY0hvb2tzLmZpbHRlcihoID0+IGguc3RhdHVzID09PSBzdGF0dXMpXG4gICAgICAuZm9yRWFjaChoID0+IGguY2FsbGJhY2socmVzcG9uc2UpKVxuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBjYW5jZWxSZWZFdmVudCgpe1xuICAgIGlmKCF0aGlzLnJlZkV2ZW50KXsgcmV0dXJuIH1cbiAgICB0aGlzLmNoYW5uZWwub2ZmKHRoaXMucmVmRXZlbnQpXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIGNhbmNlbFRpbWVvdXQoKXtcbiAgICBjbGVhclRpbWVvdXQodGhpcy50aW1lb3V0VGltZXIpXG4gICAgdGhpcy50aW1lb3V0VGltZXIgPSBudWxsXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIHN0YXJ0VGltZW91dCgpe1xuICAgIGlmKHRoaXMudGltZW91dFRpbWVyKXsgdGhpcy5jYW5jZWxUaW1lb3V0KCkgfVxuICAgIHRoaXMucmVmID0gdGhpcy5jaGFubmVsLnNvY2tldC5tYWtlUmVmKClcbiAgICB0aGlzLnJlZkV2ZW50ID0gdGhpcy5jaGFubmVsLnJlcGx5RXZlbnROYW1lKHRoaXMucmVmKVxuXG4gICAgdGhpcy5jaGFubmVsLm9uKHRoaXMucmVmRXZlbnQsIHBheWxvYWQgPT4ge1xuICAgICAgdGhpcy5jYW5jZWxSZWZFdmVudCgpXG4gICAgICB0aGlzLmNhbmNlbFRpbWVvdXQoKVxuICAgICAgdGhpcy5yZWNlaXZlZFJlc3AgPSBwYXlsb2FkXG4gICAgICB0aGlzLm1hdGNoUmVjZWl2ZShwYXlsb2FkKVxuICAgIH0pXG5cbiAgICB0aGlzLnRpbWVvdXRUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgdGhpcy50cmlnZ2VyKFwidGltZW91dFwiLCB7fSlcbiAgICB9LCB0aGlzLnRpbWVvdXQpXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIGhhc1JlY2VpdmVkKHN0YXR1cyl7XG4gICAgcmV0dXJuIHRoaXMucmVjZWl2ZWRSZXNwICYmIHRoaXMucmVjZWl2ZWRSZXNwLnN0YXR1cyA9PT0gc3RhdHVzXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIHRyaWdnZXIoc3RhdHVzLCByZXNwb25zZSl7XG4gICAgdGhpcy5jaGFubmVsLnRyaWdnZXIodGhpcy5yZWZFdmVudCwge3N0YXR1cywgcmVzcG9uc2V9KVxuICB9XG59XG4iLCAiLyoqXG4gKlxuICogQ3JlYXRlcyBhIHRpbWVyIHRoYXQgYWNjZXB0cyBhIGB0aW1lckNhbGNgIGZ1bmN0aW9uIHRvIHBlcmZvcm1cbiAqIGNhbGN1bGF0ZWQgdGltZW91dCByZXRyaWVzLCBzdWNoIGFzIGV4cG9uZW50aWFsIGJhY2tvZmYuXG4gKlxuICogQGV4YW1wbGVcbiAqIGxldCByZWNvbm5lY3RUaW1lciA9IG5ldyBUaW1lcigoKSA9PiB0aGlzLmNvbm5lY3QoKSwgZnVuY3Rpb24odHJpZXMpe1xuICogICByZXR1cm4gWzEwMDAsIDUwMDAsIDEwMDAwXVt0cmllcyAtIDFdIHx8IDEwMDAwXG4gKiB9KVxuICogcmVjb25uZWN0VGltZXIuc2NoZWR1bGVUaW1lb3V0KCkgLy8gZmlyZXMgYWZ0ZXIgMTAwMFxuICogcmVjb25uZWN0VGltZXIuc2NoZWR1bGVUaW1lb3V0KCkgLy8gZmlyZXMgYWZ0ZXIgNTAwMFxuICogcmVjb25uZWN0VGltZXIucmVzZXQoKVxuICogcmVjb25uZWN0VGltZXIuc2NoZWR1bGVUaW1lb3V0KCkgLy8gZmlyZXMgYWZ0ZXIgMTAwMFxuICpcbiAqIEBwYXJhbSB7RnVuY3Rpb259IGNhbGxiYWNrXG4gKiBAcGFyYW0ge0Z1bmN0aW9ufSB0aW1lckNhbGNcbiAqL1xuZXhwb3J0IGRlZmF1bHQgY2xhc3MgVGltZXIge1xuICBjb25zdHJ1Y3RvcihjYWxsYmFjaywgdGltZXJDYWxjKXtcbiAgICB0aGlzLmNhbGxiYWNrID0gY2FsbGJhY2tcbiAgICB0aGlzLnRpbWVyQ2FsYyA9IHRpbWVyQ2FsY1xuICAgIHRoaXMudGltZXIgPSBudWxsXG4gICAgdGhpcy50cmllcyA9IDBcbiAgfVxuXG4gIHJlc2V0KCl7XG4gICAgdGhpcy50cmllcyA9IDBcbiAgICBjbGVhclRpbWVvdXQodGhpcy50aW1lcilcbiAgfVxuXG4gIC8qKlxuICAgKiBDYW5jZWxzIGFueSBwcmV2aW91cyBzY2hlZHVsZVRpbWVvdXQgYW5kIHNjaGVkdWxlcyBjYWxsYmFja1xuICAgKi9cbiAgc2NoZWR1bGVUaW1lb3V0KCl7XG4gICAgY2xlYXJUaW1lb3V0KHRoaXMudGltZXIpXG5cbiAgICB0aGlzLnRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7XG4gICAgICB0aGlzLnRyaWVzID0gdGhpcy50cmllcyArIDFcbiAgICAgIHRoaXMuY2FsbGJhY2soKVxuICAgIH0sIHRoaXMudGltZXJDYWxjKHRoaXMudHJpZXMgKyAxKSlcbiAgfVxufVxuIiwgImltcG9ydCB7Y2xvc3VyZX0gZnJvbSBcIi4vdXRpbHNcIlxuaW1wb3J0IHtcbiAgQ0hBTk5FTF9FVkVOVFMsXG4gIENIQU5ORUxfU1RBVEVTLFxufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5pbXBvcnQgUHVzaCBmcm9tIFwiLi9wdXNoXCJcbmltcG9ydCBUaW1lciBmcm9tIFwiLi90aW1lclwiXG5cbi8qKlxuICpcbiAqIEBwYXJhbSB7c3RyaW5nfSB0b3BpY1xuICogQHBhcmFtIHsoT2JqZWN0fGZ1bmN0aW9uKX0gcGFyYW1zXG4gKiBAcGFyYW0ge1NvY2tldH0gc29ja2V0XG4gKi9cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIENoYW5uZWwge1xuICBjb25zdHJ1Y3Rvcih0b3BpYywgcGFyYW1zLCBzb2NrZXQpe1xuICAgIHRoaXMuc3RhdGUgPSBDSEFOTkVMX1NUQVRFUy5jbG9zZWRcbiAgICB0aGlzLnRvcGljID0gdG9waWNcbiAgICB0aGlzLnBhcmFtcyA9IGNsb3N1cmUocGFyYW1zIHx8IHt9KVxuICAgIHRoaXMuc29ja2V0ID0gc29ja2V0XG4gICAgdGhpcy5iaW5kaW5ncyA9IFtdXG4gICAgdGhpcy5iaW5kaW5nUmVmID0gMFxuICAgIHRoaXMudGltZW91dCA9IHRoaXMuc29ja2V0LnRpbWVvdXRcbiAgICB0aGlzLmpvaW5lZE9uY2UgPSBmYWxzZVxuICAgIHRoaXMuam9pblB1c2ggPSBuZXcgUHVzaCh0aGlzLCBDSEFOTkVMX0VWRU5UUy5qb2luLCB0aGlzLnBhcmFtcywgdGhpcy50aW1lb3V0KVxuICAgIHRoaXMucHVzaEJ1ZmZlciA9IFtdXG4gICAgdGhpcy5zdGF0ZUNoYW5nZVJlZnMgPSBbXVxuXG4gICAgdGhpcy5yZWpvaW5UaW1lciA9IG5ldyBUaW1lcigoKSA9PiB7XG4gICAgICBpZih0aGlzLnNvY2tldC5pc0Nvbm5lY3RlZCgpKXsgdGhpcy5yZWpvaW4oKSB9XG4gICAgfSwgdGhpcy5zb2NrZXQucmVqb2luQWZ0ZXJNcylcbiAgICB0aGlzLnN0YXRlQ2hhbmdlUmVmcy5wdXNoKHRoaXMuc29ja2V0Lm9uRXJyb3IoKCkgPT4gdGhpcy5yZWpvaW5UaW1lci5yZXNldCgpKSlcbiAgICB0aGlzLnN0YXRlQ2hhbmdlUmVmcy5wdXNoKHRoaXMuc29ja2V0Lm9uT3BlbigoKSA9PiB7XG4gICAgICB0aGlzLnJlam9pblRpbWVyLnJlc2V0KClcbiAgICAgIGlmKHRoaXMuaXNFcnJvcmVkKCkpeyB0aGlzLnJlam9pbigpIH1cbiAgICB9KVxuICAgIClcbiAgICB0aGlzLmpvaW5QdXNoLnJlY2VpdmUoXCJva1wiLCAoKSA9PiB7XG4gICAgICB0aGlzLnN0YXRlID0gQ0hBTk5FTF9TVEFURVMuam9pbmVkXG4gICAgICB0aGlzLnJlam9pblRpbWVyLnJlc2V0KClcbiAgICAgIHRoaXMucHVzaEJ1ZmZlci5mb3JFYWNoKHB1c2hFdmVudCA9PiBwdXNoRXZlbnQuc2VuZCgpKVxuICAgICAgdGhpcy5wdXNoQnVmZmVyID0gW11cbiAgICB9KVxuICAgIHRoaXMuam9pblB1c2gucmVjZWl2ZShcImVycm9yXCIsICgpID0+IHtcbiAgICAgIHRoaXMuc3RhdGUgPSBDSEFOTkVMX1NUQVRFUy5lcnJvcmVkXG4gICAgICBpZih0aGlzLnNvY2tldC5pc0Nvbm5lY3RlZCgpKXsgdGhpcy5yZWpvaW5UaW1lci5zY2hlZHVsZVRpbWVvdXQoKSB9XG4gICAgfSlcbiAgICB0aGlzLm9uQ2xvc2UoKCkgPT4ge1xuICAgICAgdGhpcy5yZWpvaW5UaW1lci5yZXNldCgpXG4gICAgICBpZih0aGlzLnNvY2tldC5oYXNMb2dnZXIoKSkgdGhpcy5zb2NrZXQubG9nKFwiY2hhbm5lbFwiLCBgY2xvc2UgJHt0aGlzLnRvcGljfSAke3RoaXMuam9pblJlZigpfWApXG4gICAgICB0aGlzLnN0YXRlID0gQ0hBTk5FTF9TVEFURVMuY2xvc2VkXG4gICAgICB0aGlzLnNvY2tldC5yZW1vdmUodGhpcylcbiAgICB9KVxuICAgIHRoaXMub25FcnJvcihyZWFzb24gPT4ge1xuICAgICAgaWYodGhpcy5zb2NrZXQuaGFzTG9nZ2VyKCkpIHRoaXMuc29ja2V0LmxvZyhcImNoYW5uZWxcIiwgYGVycm9yICR7dGhpcy50b3BpY31gLCByZWFzb24pXG4gICAgICBpZih0aGlzLmlzSm9pbmluZygpKXsgdGhpcy5qb2luUHVzaC5yZXNldCgpIH1cbiAgICAgIHRoaXMuc3RhdGUgPSBDSEFOTkVMX1NUQVRFUy5lcnJvcmVkXG4gICAgICBpZih0aGlzLnNvY2tldC5pc0Nvbm5lY3RlZCgpKXsgdGhpcy5yZWpvaW5UaW1lci5zY2hlZHVsZVRpbWVvdXQoKSB9XG4gICAgfSlcbiAgICB0aGlzLmpvaW5QdXNoLnJlY2VpdmUoXCJ0aW1lb3V0XCIsICgpID0+IHtcbiAgICAgIGlmKHRoaXMuc29ja2V0Lmhhc0xvZ2dlcigpKSB0aGlzLnNvY2tldC5sb2coXCJjaGFubmVsXCIsIGB0aW1lb3V0ICR7dGhpcy50b3BpY30gKCR7dGhpcy5qb2luUmVmKCl9KWAsIHRoaXMuam9pblB1c2gudGltZW91dClcbiAgICAgIGxldCBsZWF2ZVB1c2ggPSBuZXcgUHVzaCh0aGlzLCBDSEFOTkVMX0VWRU5UUy5sZWF2ZSwgY2xvc3VyZSh7fSksIHRoaXMudGltZW91dClcbiAgICAgIGxlYXZlUHVzaC5zZW5kKClcbiAgICAgIHRoaXMuc3RhdGUgPSBDSEFOTkVMX1NUQVRFUy5lcnJvcmVkXG4gICAgICB0aGlzLmpvaW5QdXNoLnJlc2V0KClcbiAgICAgIGlmKHRoaXMuc29ja2V0LmlzQ29ubmVjdGVkKCkpeyB0aGlzLnJlam9pblRpbWVyLnNjaGVkdWxlVGltZW91dCgpIH1cbiAgICB9KVxuICAgIHRoaXMub24oQ0hBTk5FTF9FVkVOVFMucmVwbHksIChwYXlsb2FkLCByZWYpID0+IHtcbiAgICAgIHRoaXMudHJpZ2dlcih0aGlzLnJlcGx5RXZlbnROYW1lKHJlZiksIHBheWxvYWQpXG4gICAgfSlcbiAgfVxuXG4gIC8qKlxuICAgKiBKb2luIHRoZSBjaGFubmVsXG4gICAqIEBwYXJhbSB7aW50ZWdlcn0gdGltZW91dFxuICAgKiBAcmV0dXJucyB7UHVzaH1cbiAgICovXG4gIGpvaW4odGltZW91dCA9IHRoaXMudGltZW91dCl7XG4gICAgaWYodGhpcy5qb2luZWRPbmNlKXtcbiAgICAgIHRocm93IG5ldyBFcnJvcihcInRyaWVkIHRvIGpvaW4gbXVsdGlwbGUgdGltZXMuICdqb2luJyBjYW4gb25seSBiZSBjYWxsZWQgYSBzaW5nbGUgdGltZSBwZXIgY2hhbm5lbCBpbnN0YW5jZVwiKVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLnRpbWVvdXQgPSB0aW1lb3V0XG4gICAgICB0aGlzLmpvaW5lZE9uY2UgPSB0cnVlXG4gICAgICB0aGlzLnJlam9pbigpXG4gICAgICByZXR1cm4gdGhpcy5qb2luUHVzaFxuICAgIH1cbiAgfVxuXG4gIC8qKlxuICAgKiBIb29rIGludG8gY2hhbm5lbCBjbG9zZVxuICAgKiBAcGFyYW0ge0Z1bmN0aW9ufSBjYWxsYmFja1xuICAgKi9cbiAgb25DbG9zZShjYWxsYmFjayl7XG4gICAgdGhpcy5vbihDSEFOTkVMX0VWRU5UUy5jbG9zZSwgY2FsbGJhY2spXG4gIH1cblxuICAvKipcbiAgICogSG9vayBpbnRvIGNoYW5uZWwgZXJyb3JzXG4gICAqIEBwYXJhbSB7RnVuY3Rpb259IGNhbGxiYWNrXG4gICAqL1xuICBvbkVycm9yKGNhbGxiYWNrKXtcbiAgICByZXR1cm4gdGhpcy5vbihDSEFOTkVMX0VWRU5UUy5lcnJvciwgcmVhc29uID0+IGNhbGxiYWNrKHJlYXNvbikpXG4gIH1cblxuICAvKipcbiAgICogU3Vic2NyaWJlcyBvbiBjaGFubmVsIGV2ZW50c1xuICAgKlxuICAgKiBTdWJzY3JpcHRpb24gcmV0dXJucyBhIHJlZiBjb3VudGVyLCB3aGljaCBjYW4gYmUgdXNlZCBsYXRlciB0b1xuICAgKiB1bnN1YnNjcmliZSB0aGUgZXhhY3QgZXZlbnQgbGlzdGVuZXJcbiAgICpcbiAgICogQGV4YW1wbGVcbiAgICogY29uc3QgcmVmMSA9IGNoYW5uZWwub24oXCJldmVudFwiLCBkb19zdHVmZilcbiAgICogY29uc3QgcmVmMiA9IGNoYW5uZWwub24oXCJldmVudFwiLCBkb19vdGhlcl9zdHVmZilcbiAgICogY2hhbm5lbC5vZmYoXCJldmVudFwiLCByZWYxKVxuICAgKiAvLyBTaW5jZSB1bnN1YnNjcmlwdGlvbiwgZG9fc3R1ZmYgd29uJ3QgZmlyZSxcbiAgICogLy8gd2hpbGUgZG9fb3RoZXJfc3R1ZmYgd2lsbCBrZWVwIGZpcmluZyBvbiB0aGUgXCJldmVudFwiXG4gICAqXG4gICAqIEBwYXJhbSB7c3RyaW5nfSBldmVudFxuICAgKiBAcGFyYW0ge0Z1bmN0aW9ufSBjYWxsYmFja1xuICAgKiBAcmV0dXJucyB7aW50ZWdlcn0gcmVmXG4gICAqL1xuICBvbihldmVudCwgY2FsbGJhY2spe1xuICAgIGxldCByZWYgPSB0aGlzLmJpbmRpbmdSZWYrK1xuICAgIHRoaXMuYmluZGluZ3MucHVzaCh7ZXZlbnQsIHJlZiwgY2FsbGJhY2t9KVxuICAgIHJldHVybiByZWZcbiAgfVxuXG4gIC8qKlxuICAgKiBVbnN1YnNjcmliZXMgb2ZmIG9mIGNoYW5uZWwgZXZlbnRzXG4gICAqXG4gICAqIFVzZSB0aGUgcmVmIHJldHVybmVkIGZyb20gYSBjaGFubmVsLm9uKCkgdG8gdW5zdWJzY3JpYmUgb25lXG4gICAqIGhhbmRsZXIsIG9yIHBhc3Mgbm90aGluZyBmb3IgdGhlIHJlZiB0byB1bnN1YnNjcmliZSBhbGxcbiAgICogaGFuZGxlcnMgZm9yIHRoZSBnaXZlbiBldmVudC5cbiAgICpcbiAgICogQGV4YW1wbGVcbiAgICogLy8gVW5zdWJzY3JpYmUgdGhlIGRvX3N0dWZmIGhhbmRsZXJcbiAgICogY29uc3QgcmVmMSA9IGNoYW5uZWwub24oXCJldmVudFwiLCBkb19zdHVmZilcbiAgICogY2hhbm5lbC5vZmYoXCJldmVudFwiLCByZWYxKVxuICAgKlxuICAgKiAvLyBVbnN1YnNjcmliZSBhbGwgaGFuZGxlcnMgZnJvbSBldmVudFxuICAgKiBjaGFubmVsLm9mZihcImV2ZW50XCIpXG4gICAqXG4gICAqIEBwYXJhbSB7c3RyaW5nfSBldmVudFxuICAgKiBAcGFyYW0ge2ludGVnZXJ9IHJlZlxuICAgKi9cbiAgb2ZmKGV2ZW50LCByZWYpe1xuICAgIHRoaXMuYmluZGluZ3MgPSB0aGlzLmJpbmRpbmdzLmZpbHRlcigoYmluZCkgPT4ge1xuICAgICAgcmV0dXJuICEoYmluZC5ldmVudCA9PT0gZXZlbnQgJiYgKHR5cGVvZiByZWYgPT09IFwidW5kZWZpbmVkXCIgfHwgcmVmID09PSBiaW5kLnJlZikpXG4gICAgfSlcbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgY2FuUHVzaCgpeyByZXR1cm4gdGhpcy5zb2NrZXQuaXNDb25uZWN0ZWQoKSAmJiB0aGlzLmlzSm9pbmVkKCkgfVxuXG4gIC8qKlxuICAgKiBTZW5kcyBhIG1lc3NhZ2UgYGV2ZW50YCB0byBwaG9lbml4IHdpdGggdGhlIHBheWxvYWQgYHBheWxvYWRgLlxuICAgKiBQaG9lbml4IHJlY2VpdmVzIHRoaXMgaW4gdGhlIGBoYW5kbGVfaW4oZXZlbnQsIHBheWxvYWQsIHNvY2tldClgXG4gICAqIGZ1bmN0aW9uLiBpZiBwaG9lbml4IHJlcGxpZXMgb3IgaXQgdGltZXMgb3V0IChkZWZhdWx0IDEwMDAwbXMpLFxuICAgKiB0aGVuIG9wdGlvbmFsbHkgdGhlIHJlcGx5IGNhbiBiZSByZWNlaXZlZC5cbiAgICpcbiAgICogQGV4YW1wbGVcbiAgICogY2hhbm5lbC5wdXNoKFwiZXZlbnRcIilcbiAgICogICAucmVjZWl2ZShcIm9rXCIsIHBheWxvYWQgPT4gY29uc29sZS5sb2coXCJwaG9lbml4IHJlcGxpZWQ6XCIsIHBheWxvYWQpKVxuICAgKiAgIC5yZWNlaXZlKFwiZXJyb3JcIiwgZXJyID0+IGNvbnNvbGUubG9nKFwicGhvZW5peCBlcnJvcmVkXCIsIGVycikpXG4gICAqICAgLnJlY2VpdmUoXCJ0aW1lb3V0XCIsICgpID0+IGNvbnNvbGUubG9nKFwidGltZWQgb3V0IHB1c2hpbmdcIikpXG4gICAqIEBwYXJhbSB7c3RyaW5nfSBldmVudFxuICAgKiBAcGFyYW0ge09iamVjdH0gcGF5bG9hZFxuICAgKiBAcGFyYW0ge251bWJlcn0gW3RpbWVvdXRdXG4gICAqIEByZXR1cm5zIHtQdXNofVxuICAgKi9cbiAgcHVzaChldmVudCwgcGF5bG9hZCwgdGltZW91dCA9IHRoaXMudGltZW91dCl7XG4gICAgcGF5bG9hZCA9IHBheWxvYWQgfHwge31cbiAgICBpZighdGhpcy5qb2luZWRPbmNlKXtcbiAgICAgIHRocm93IG5ldyBFcnJvcihgdHJpZWQgdG8gcHVzaCAnJHtldmVudH0nIHRvICcke3RoaXMudG9waWN9JyBiZWZvcmUgam9pbmluZy4gVXNlIGNoYW5uZWwuam9pbigpIGJlZm9yZSBwdXNoaW5nIGV2ZW50c2ApXG4gICAgfVxuICAgIGxldCBwdXNoRXZlbnQgPSBuZXcgUHVzaCh0aGlzLCBldmVudCwgZnVuY3Rpb24gKCl7IHJldHVybiBwYXlsb2FkIH0sIHRpbWVvdXQpXG4gICAgaWYodGhpcy5jYW5QdXNoKCkpe1xuICAgICAgcHVzaEV2ZW50LnNlbmQoKVxuICAgIH0gZWxzZSB7XG4gICAgICBwdXNoRXZlbnQuc3RhcnRUaW1lb3V0KClcbiAgICAgIHRoaXMucHVzaEJ1ZmZlci5wdXNoKHB1c2hFdmVudClcbiAgICB9XG5cbiAgICByZXR1cm4gcHVzaEV2ZW50XG4gIH1cblxuICAvKiogTGVhdmVzIHRoZSBjaGFubmVsXG4gICAqXG4gICAqIFVuc3Vic2NyaWJlcyBmcm9tIHNlcnZlciBldmVudHMsIGFuZFxuICAgKiBpbnN0cnVjdHMgY2hhbm5lbCB0byB0ZXJtaW5hdGUgb24gc2VydmVyXG4gICAqXG4gICAqIFRyaWdnZXJzIG9uQ2xvc2UoKSBob29rc1xuICAgKlxuICAgKiBUbyByZWNlaXZlIGxlYXZlIGFja25vd2xlZGdlbWVudHMsIHVzZSB0aGUgYHJlY2VpdmVgXG4gICAqIGhvb2sgdG8gYmluZCB0byB0aGUgc2VydmVyIGFjaywgaWU6XG4gICAqXG4gICAqIEBleGFtcGxlXG4gICAqIGNoYW5uZWwubGVhdmUoKS5yZWNlaXZlKFwib2tcIiwgKCkgPT4gYWxlcnQoXCJsZWZ0IVwiKSApXG4gICAqXG4gICAqIEBwYXJhbSB7aW50ZWdlcn0gdGltZW91dFxuICAgKiBAcmV0dXJucyB7UHVzaH1cbiAgICovXG4gIGxlYXZlKHRpbWVvdXQgPSB0aGlzLnRpbWVvdXQpe1xuICAgIHRoaXMucmVqb2luVGltZXIucmVzZXQoKVxuICAgIHRoaXMuam9pblB1c2guY2FuY2VsVGltZW91dCgpXG5cbiAgICB0aGlzLnN0YXRlID0gQ0hBTk5FTF9TVEFURVMubGVhdmluZ1xuICAgIGxldCBvbkNsb3NlID0gKCkgPT4ge1xuICAgICAgaWYodGhpcy5zb2NrZXQuaGFzTG9nZ2VyKCkpIHRoaXMuc29ja2V0LmxvZyhcImNoYW5uZWxcIiwgYGxlYXZlICR7dGhpcy50b3BpY31gKVxuICAgICAgdGhpcy50cmlnZ2VyKENIQU5ORUxfRVZFTlRTLmNsb3NlLCBcImxlYXZlXCIpXG4gICAgfVxuICAgIGxldCBsZWF2ZVB1c2ggPSBuZXcgUHVzaCh0aGlzLCBDSEFOTkVMX0VWRU5UUy5sZWF2ZSwgY2xvc3VyZSh7fSksIHRpbWVvdXQpXG4gICAgbGVhdmVQdXNoLnJlY2VpdmUoXCJva1wiLCAoKSA9PiBvbkNsb3NlKCkpXG4gICAgICAucmVjZWl2ZShcInRpbWVvdXRcIiwgKCkgPT4gb25DbG9zZSgpKVxuICAgIGxlYXZlUHVzaC5zZW5kKClcbiAgICBpZighdGhpcy5jYW5QdXNoKCkpeyBsZWF2ZVB1c2gudHJpZ2dlcihcIm9rXCIsIHt9KSB9XG5cbiAgICByZXR1cm4gbGVhdmVQdXNoXG4gIH1cblxuICAvKipcbiAgICogT3ZlcnJpZGFibGUgbWVzc2FnZSBob29rXG4gICAqXG4gICAqIFJlY2VpdmVzIGFsbCBldmVudHMgZm9yIHNwZWNpYWxpemVkIG1lc3NhZ2UgaGFuZGxpbmdcbiAgICogYmVmb3JlIGRpc3BhdGNoaW5nIHRvIHRoZSBjaGFubmVsIGNhbGxiYWNrcy5cbiAgICpcbiAgICogTXVzdCByZXR1cm4gdGhlIHBheWxvYWQsIG1vZGlmaWVkIG9yIHVubW9kaWZpZWRcbiAgICogQHBhcmFtIHtzdHJpbmd9IGV2ZW50XG4gICAqIEBwYXJhbSB7T2JqZWN0fSBwYXlsb2FkXG4gICAqIEBwYXJhbSB7aW50ZWdlcn0gcmVmXG4gICAqIEByZXR1cm5zIHtPYmplY3R9XG4gICAqL1xuICBvbk1lc3NhZ2UoX2V2ZW50LCBwYXlsb2FkLCBfcmVmKXsgcmV0dXJuIHBheWxvYWQgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgaXNNZW1iZXIodG9waWMsIGV2ZW50LCBwYXlsb2FkLCBqb2luUmVmKXtcbiAgICBpZih0aGlzLnRvcGljICE9PSB0b3BpYyl7IHJldHVybiBmYWxzZSB9XG5cbiAgICBpZihqb2luUmVmICYmIGpvaW5SZWYgIT09IHRoaXMuam9pblJlZigpKXtcbiAgICAgIGlmKHRoaXMuc29ja2V0Lmhhc0xvZ2dlcigpKSB0aGlzLnNvY2tldC5sb2coXCJjaGFubmVsXCIsIFwiZHJvcHBpbmcgb3V0ZGF0ZWQgbWVzc2FnZVwiLCB7dG9waWMsIGV2ZW50LCBwYXlsb2FkLCBqb2luUmVmfSlcbiAgICAgIHJldHVybiBmYWxzZVxuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gdHJ1ZVxuICAgIH1cbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgam9pblJlZigpeyByZXR1cm4gdGhpcy5qb2luUHVzaC5yZWYgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgcmVqb2luKHRpbWVvdXQgPSB0aGlzLnRpbWVvdXQpe1xuICAgIGlmKHRoaXMuaXNMZWF2aW5nKCkpeyByZXR1cm4gfVxuICAgIHRoaXMuc29ja2V0LmxlYXZlT3BlblRvcGljKHRoaXMudG9waWMpXG4gICAgdGhpcy5zdGF0ZSA9IENIQU5ORUxfU1RBVEVTLmpvaW5pbmdcbiAgICB0aGlzLmpvaW5QdXNoLnJlc2VuZCh0aW1lb3V0KVxuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICB0cmlnZ2VyKGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5SZWYpe1xuICAgIGxldCBoYW5kbGVkUGF5bG9hZCA9IHRoaXMub25NZXNzYWdlKGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5SZWYpXG4gICAgaWYocGF5bG9hZCAmJiAhaGFuZGxlZFBheWxvYWQpeyB0aHJvdyBuZXcgRXJyb3IoXCJjaGFubmVsIG9uTWVzc2FnZSBjYWxsYmFja3MgbXVzdCByZXR1cm4gdGhlIHBheWxvYWQsIG1vZGlmaWVkIG9yIHVubW9kaWZpZWRcIikgfVxuXG4gICAgbGV0IGV2ZW50QmluZGluZ3MgPSB0aGlzLmJpbmRpbmdzLmZpbHRlcihiaW5kID0+IGJpbmQuZXZlbnQgPT09IGV2ZW50KVxuXG4gICAgZm9yKGxldCBpID0gMDsgaSA8IGV2ZW50QmluZGluZ3MubGVuZ3RoOyBpKyspe1xuICAgICAgbGV0IGJpbmQgPSBldmVudEJpbmRpbmdzW2ldXG4gICAgICBiaW5kLmNhbGxiYWNrKGhhbmRsZWRQYXlsb2FkLCByZWYsIGpvaW5SZWYgfHwgdGhpcy5qb2luUmVmKCkpXG4gICAgfVxuICB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICByZXBseUV2ZW50TmFtZShyZWYpeyByZXR1cm4gYGNoYW5fcmVwbHlfJHtyZWZ9YCB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBpc0Nsb3NlZCgpeyByZXR1cm4gdGhpcy5zdGF0ZSA9PT0gQ0hBTk5FTF9TVEFURVMuY2xvc2VkIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIGlzRXJyb3JlZCgpeyByZXR1cm4gdGhpcy5zdGF0ZSA9PT0gQ0hBTk5FTF9TVEFURVMuZXJyb3JlZCB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBpc0pvaW5lZCgpeyByZXR1cm4gdGhpcy5zdGF0ZSA9PT0gQ0hBTk5FTF9TVEFURVMuam9pbmVkIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIGlzSm9pbmluZygpeyByZXR1cm4gdGhpcy5zdGF0ZSA9PT0gQ0hBTk5FTF9TVEFURVMuam9pbmluZyB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqL1xuICBpc0xlYXZpbmcoKXsgcmV0dXJuIHRoaXMuc3RhdGUgPT09IENIQU5ORUxfU1RBVEVTLmxlYXZpbmcgfVxufVxuIiwgImltcG9ydCB7XG4gIGdsb2JhbCxcbiAgWEhSX1NUQVRFU1xufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBBamF4IHtcblxuICBzdGF0aWMgcmVxdWVzdChtZXRob2QsIGVuZFBvaW50LCBhY2NlcHQsIGJvZHksIHRpbWVvdXQsIG9udGltZW91dCwgY2FsbGJhY2spe1xuICAgIGlmKGdsb2JhbC5YRG9tYWluUmVxdWVzdCl7XG4gICAgICBsZXQgcmVxID0gbmV3IGdsb2JhbC5YRG9tYWluUmVxdWVzdCgpIC8vIElFOCwgSUU5XG4gICAgICByZXR1cm4gdGhpcy54ZG9tYWluUmVxdWVzdChyZXEsIG1ldGhvZCwgZW5kUG9pbnQsIGJvZHksIHRpbWVvdXQsIG9udGltZW91dCwgY2FsbGJhY2spXG4gICAgfSBlbHNlIHtcbiAgICAgIGxldCByZXEgPSBuZXcgZ2xvYmFsLlhNTEh0dHBSZXF1ZXN0KCkgLy8gSUU3KywgRmlyZWZveCwgQ2hyb21lLCBPcGVyYSwgU2FmYXJpXG4gICAgICByZXR1cm4gdGhpcy54aHJSZXF1ZXN0KHJlcSwgbWV0aG9kLCBlbmRQb2ludCwgYWNjZXB0LCBib2R5LCB0aW1lb3V0LCBvbnRpbWVvdXQsIGNhbGxiYWNrKVxuICAgIH1cbiAgfVxuXG4gIHN0YXRpYyB4ZG9tYWluUmVxdWVzdChyZXEsIG1ldGhvZCwgZW5kUG9pbnQsIGJvZHksIHRpbWVvdXQsIG9udGltZW91dCwgY2FsbGJhY2spe1xuICAgIHJlcS50aW1lb3V0ID0gdGltZW91dFxuICAgIHJlcS5vcGVuKG1ldGhvZCwgZW5kUG9pbnQpXG4gICAgcmVxLm9ubG9hZCA9ICgpID0+IHtcbiAgICAgIGxldCByZXNwb25zZSA9IHRoaXMucGFyc2VKU09OKHJlcS5yZXNwb25zZVRleHQpXG4gICAgICBjYWxsYmFjayAmJiBjYWxsYmFjayhyZXNwb25zZSlcbiAgICB9XG4gICAgaWYob250aW1lb3V0KXsgcmVxLm9udGltZW91dCA9IG9udGltZW91dCB9XG5cbiAgICAvLyBXb3JrIGFyb3VuZCBidWcgaW4gSUU5IHRoYXQgcmVxdWlyZXMgYW4gYXR0YWNoZWQgb25wcm9ncmVzcyBoYW5kbGVyXG4gICAgcmVxLm9ucHJvZ3Jlc3MgPSAoKSA9PiB7IH1cblxuICAgIHJlcS5zZW5kKGJvZHkpXG4gICAgcmV0dXJuIHJlcVxuICB9XG5cbiAgc3RhdGljIHhoclJlcXVlc3QocmVxLCBtZXRob2QsIGVuZFBvaW50LCBhY2NlcHQsIGJvZHksIHRpbWVvdXQsIG9udGltZW91dCwgY2FsbGJhY2spe1xuICAgIHJlcS5vcGVuKG1ldGhvZCwgZW5kUG9pbnQsIHRydWUpXG4gICAgcmVxLnRpbWVvdXQgPSB0aW1lb3V0XG4gICAgcmVxLnNldFJlcXVlc3RIZWFkZXIoXCJDb250ZW50LVR5cGVcIiwgYWNjZXB0KVxuICAgIHJlcS5vbmVycm9yID0gKCkgPT4gY2FsbGJhY2sgJiYgY2FsbGJhY2sobnVsbClcbiAgICByZXEub25yZWFkeXN0YXRlY2hhbmdlID0gKCkgPT4ge1xuICAgICAgaWYocmVxLnJlYWR5U3RhdGUgPT09IFhIUl9TVEFURVMuY29tcGxldGUgJiYgY2FsbGJhY2spe1xuICAgICAgICBsZXQgcmVzcG9uc2UgPSB0aGlzLnBhcnNlSlNPTihyZXEucmVzcG9uc2VUZXh0KVxuICAgICAgICBjYWxsYmFjayhyZXNwb25zZSlcbiAgICAgIH1cbiAgICB9XG4gICAgaWYob250aW1lb3V0KXsgcmVxLm9udGltZW91dCA9IG9udGltZW91dCB9XG5cbiAgICByZXEuc2VuZChib2R5KVxuICAgIHJldHVybiByZXFcbiAgfVxuXG4gIHN0YXRpYyBwYXJzZUpTT04ocmVzcCl7XG4gICAgaWYoIXJlc3AgfHwgcmVzcCA9PT0gXCJcIil7IHJldHVybiBudWxsIH1cblxuICAgIHRyeSB7XG4gICAgICByZXR1cm4gSlNPTi5wYXJzZShyZXNwKVxuICAgIH0gY2F0Y2ggKGUpe1xuICAgICAgY29uc29sZSAmJiBjb25zb2xlLmxvZyhcImZhaWxlZCB0byBwYXJzZSBKU09OIHJlc3BvbnNlXCIsIHJlc3ApXG4gICAgICByZXR1cm4gbnVsbFxuICAgIH1cbiAgfVxuXG4gIHN0YXRpYyBzZXJpYWxpemUob2JqLCBwYXJlbnRLZXkpe1xuICAgIGxldCBxdWVyeVN0ciA9IFtdXG4gICAgZm9yKHZhciBrZXkgaW4gb2JqKXtcbiAgICAgIGlmKCFPYmplY3QucHJvdG90eXBlLmhhc093blByb3BlcnR5LmNhbGwob2JqLCBrZXkpKXsgY29udGludWUgfVxuICAgICAgbGV0IHBhcmFtS2V5ID0gcGFyZW50S2V5ID8gYCR7cGFyZW50S2V5fVske2tleX1dYCA6IGtleVxuICAgICAgbGV0IHBhcmFtVmFsID0gb2JqW2tleV1cbiAgICAgIGlmKHR5cGVvZiBwYXJhbVZhbCA9PT0gXCJvYmplY3RcIil7XG4gICAgICAgIHF1ZXJ5U3RyLnB1c2godGhpcy5zZXJpYWxpemUocGFyYW1WYWwsIHBhcmFtS2V5KSlcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHF1ZXJ5U3RyLnB1c2goZW5jb2RlVVJJQ29tcG9uZW50KHBhcmFtS2V5KSArIFwiPVwiICsgZW5jb2RlVVJJQ29tcG9uZW50KHBhcmFtVmFsKSlcbiAgICAgIH1cbiAgICB9XG4gICAgcmV0dXJuIHF1ZXJ5U3RyLmpvaW4oXCImXCIpXG4gIH1cblxuICBzdGF0aWMgYXBwZW5kUGFyYW1zKHVybCwgcGFyYW1zKXtcbiAgICBpZihPYmplY3Qua2V5cyhwYXJhbXMpLmxlbmd0aCA9PT0gMCl7IHJldHVybiB1cmwgfVxuXG4gICAgbGV0IHByZWZpeCA9IHVybC5tYXRjaCgvXFw/LykgPyBcIiZcIiA6IFwiP1wiXG4gICAgcmV0dXJuIGAke3VybH0ke3ByZWZpeH0ke3RoaXMuc2VyaWFsaXplKHBhcmFtcyl9YFxuICB9XG59XG4iLCAiaW1wb3J0IHtcbiAgU09DS0VUX1NUQVRFUyxcbiAgVFJBTlNQT1JUU1xufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5pbXBvcnQgQWpheCBmcm9tIFwiLi9hamF4XCJcblxubGV0IGFycmF5QnVmZmVyVG9CYXNlNjQgPSAoYnVmZmVyKSA9PiB7XG4gIGxldCBiaW5hcnkgPSBcIlwiXG4gIGxldCBieXRlcyA9IG5ldyBVaW50OEFycmF5KGJ1ZmZlcilcbiAgbGV0IGxlbiA9IGJ5dGVzLmJ5dGVMZW5ndGhcbiAgZm9yKGxldCBpID0gMDsgaSA8IGxlbjsgaSsrKXsgYmluYXJ5ICs9IFN0cmluZy5mcm9tQ2hhckNvZGUoYnl0ZXNbaV0pIH1cbiAgcmV0dXJuIGJ0b2EoYmluYXJ5KVxufVxuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBMb25nUG9sbCB7XG5cbiAgY29uc3RydWN0b3IoZW5kUG9pbnQpe1xuICAgIHRoaXMuZW5kUG9pbnQgPSBudWxsXG4gICAgdGhpcy50b2tlbiA9IG51bGxcbiAgICB0aGlzLnNraXBIZWFydGJlYXQgPSB0cnVlXG4gICAgdGhpcy5yZXFzID0gbmV3IFNldCgpXG4gICAgdGhpcy5hd2FpdGluZ0JhdGNoQWNrID0gZmFsc2VcbiAgICB0aGlzLmN1cnJlbnRCYXRjaCA9IG51bGxcbiAgICB0aGlzLmN1cnJlbnRCYXRjaFRpbWVyID0gbnVsbFxuICAgIHRoaXMuYmF0Y2hCdWZmZXIgPSBbXVxuICAgIHRoaXMub25vcGVuID0gZnVuY3Rpb24gKCl7IH0gLy8gbm9vcFxuICAgIHRoaXMub25lcnJvciA9IGZ1bmN0aW9uICgpeyB9IC8vIG5vb3BcbiAgICB0aGlzLm9ubWVzc2FnZSA9IGZ1bmN0aW9uICgpeyB9IC8vIG5vb3BcbiAgICB0aGlzLm9uY2xvc2UgPSBmdW5jdGlvbiAoKXsgfSAvLyBub29wXG4gICAgdGhpcy5wb2xsRW5kcG9pbnQgPSB0aGlzLm5vcm1hbGl6ZUVuZHBvaW50KGVuZFBvaW50KVxuICAgIHRoaXMucmVhZHlTdGF0ZSA9IFNPQ0tFVF9TVEFURVMuY29ubmVjdGluZ1xuICAgIC8vIHdlIG11c3Qgd2FpdCBmb3IgdGhlIGNhbGxlciB0byBmaW5pc2ggc2V0dGluZyB1cCBvdXIgY2FsbGJhY2tzIGFuZCB0aW1lb3V0IHByb3BlcnRpZXNcbiAgICBzZXRUaW1lb3V0KCgpID0+IHRoaXMucG9sbCgpLCAwKVxuICB9XG5cbiAgbm9ybWFsaXplRW5kcG9pbnQoZW5kUG9pbnQpe1xuICAgIHJldHVybiAoZW5kUG9pbnRcbiAgICAgIC5yZXBsYWNlKFwid3M6Ly9cIiwgXCJodHRwOi8vXCIpXG4gICAgICAucmVwbGFjZShcIndzczovL1wiLCBcImh0dHBzOi8vXCIpXG4gICAgICAucmVwbGFjZShuZXcgUmVnRXhwKFwiKC4qKVxcL1wiICsgVFJBTlNQT1JUUy53ZWJzb2NrZXQpLCBcIiQxL1wiICsgVFJBTlNQT1JUUy5sb25ncG9sbCkpXG4gIH1cblxuICBlbmRwb2ludFVSTCgpe1xuICAgIHJldHVybiBBamF4LmFwcGVuZFBhcmFtcyh0aGlzLnBvbGxFbmRwb2ludCwge3Rva2VuOiB0aGlzLnRva2VufSlcbiAgfVxuXG4gIGNsb3NlQW5kUmV0cnkoY29kZSwgcmVhc29uLCB3YXNDbGVhbil7XG4gICAgdGhpcy5jbG9zZShjb2RlLCByZWFzb24sIHdhc0NsZWFuKVxuICAgIHRoaXMucmVhZHlTdGF0ZSA9IFNPQ0tFVF9TVEFURVMuY29ubmVjdGluZ1xuICB9XG5cbiAgb250aW1lb3V0KCl7XG4gICAgdGhpcy5vbmVycm9yKFwidGltZW91dFwiKVxuICAgIHRoaXMuY2xvc2VBbmRSZXRyeSgxMDA1LCBcInRpbWVvdXRcIiwgZmFsc2UpXG4gIH1cblxuICBpc0FjdGl2ZSgpeyByZXR1cm4gdGhpcy5yZWFkeVN0YXRlID09PSBTT0NLRVRfU1RBVEVTLm9wZW4gfHwgdGhpcy5yZWFkeVN0YXRlID09PSBTT0NLRVRfU1RBVEVTLmNvbm5lY3RpbmcgfVxuXG4gIHBvbGwoKXtcbiAgICB0aGlzLmFqYXgoXCJHRVRcIiwgXCJhcHBsaWNhdGlvbi9qc29uXCIsIG51bGwsICgpID0+IHRoaXMub250aW1lb3V0KCksIHJlc3AgPT4ge1xuICAgICAgaWYocmVzcCl7XG4gICAgICAgIHZhciB7c3RhdHVzLCB0b2tlbiwgbWVzc2FnZXN9ID0gcmVzcFxuICAgICAgICB0aGlzLnRva2VuID0gdG9rZW5cbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHN0YXR1cyA9IDBcbiAgICAgIH1cblxuICAgICAgc3dpdGNoKHN0YXR1cyl7XG4gICAgICAgIGNhc2UgMjAwOlxuICAgICAgICAgIG1lc3NhZ2VzLmZvckVhY2gobXNnID0+IHtcbiAgICAgICAgICAgIC8vIFRhc2tzIGFyZSB3aGF0IHRoaW5ncyBsaWtlIGV2ZW50IGhhbmRsZXJzLCBzZXRUaW1lb3V0IGNhbGxiYWNrcyxcbiAgICAgICAgICAgIC8vIHByb21pc2UgcmVzb2x2ZXMgYW5kIG1vcmUgYXJlIHJ1biB3aXRoaW4uXG4gICAgICAgICAgICAvLyBJbiBtb2Rlcm4gYnJvd3NlcnMsIHRoZXJlIGFyZSB0d28gZGlmZmVyZW50IGtpbmRzIG9mIHRhc2tzLFxuICAgICAgICAgICAgLy8gbWljcm90YXNrcyBhbmQgbWFjcm90YXNrcy5cbiAgICAgICAgICAgIC8vIE1pY3JvdGFza3MgYXJlIG1haW5seSB1c2VkIGZvciBQcm9taXNlcywgd2hpbGUgbWFjcm90YXNrcyBhcmVcbiAgICAgICAgICAgIC8vIHVzZWQgZm9yIGV2ZXJ5dGhpbmcgZWxzZS5cbiAgICAgICAgICAgIC8vIE1pY3JvdGFza3MgYWx3YXlzIGhhdmUgcHJpb3JpdHkgb3ZlciBtYWNyb3Rhc2tzLiBJZiB0aGUgSlMgZW5naW5lXG4gICAgICAgICAgICAvLyBpcyBsb29raW5nIGZvciBhIHRhc2sgdG8gcnVuLCBpdCB3aWxsIGFsd2F5cyB0cnkgdG8gZW1wdHkgdGhlXG4gICAgICAgICAgICAvLyBtaWNyb3Rhc2sgcXVldWUgYmVmb3JlIGF0dGVtcHRpbmcgdG8gcnVuIGFueXRoaW5nIGZyb20gdGhlXG4gICAgICAgICAgICAvLyBtYWNyb3Rhc2sgcXVldWUuXG4gICAgICAgICAgICAvL1xuICAgICAgICAgICAgLy8gRm9yIHRoZSBXZWJTb2NrZXQgdHJhbnNwb3J0LCBtZXNzYWdlcyBhbHdheXMgYXJyaXZlIGluIHRoZWlyIG93blxuICAgICAgICAgICAgLy8gZXZlbnQuIFRoaXMgbWVhbnMgdGhhdCBpZiBhbnkgcHJvbWlzZXMgYXJlIHJlc29sdmVkIGZyb20gd2l0aGluLFxuICAgICAgICAgICAgLy8gdGhlaXIgY2FsbGJhY2tzIHdpbGwgYWx3YXlzIGZpbmlzaCBleGVjdXRpb24gYnkgdGhlIHRpbWUgdGhlXG4gICAgICAgICAgICAvLyBuZXh0IG1lc3NhZ2UgZXZlbnQgaGFuZGxlciBpcyBydW4uXG4gICAgICAgICAgICAvL1xuICAgICAgICAgICAgLy8gSW4gb3JkZXIgdG8gZW11bGF0ZSB0aGlzIGJlaGF2aW91ciwgd2UgbmVlZCB0byBtYWtlIHN1cmUgZWFjaFxuICAgICAgICAgICAgLy8gb25tZXNzYWdlIGhhbmRsZXIgaXMgcnVuIHdpdGhpbiBpdHMgb3duIG1hY3JvdGFzay5cbiAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gdGhpcy5vbm1lc3NhZ2Uoe2RhdGE6IG1zZ30pLCAwKVxuICAgICAgICAgIH0pXG4gICAgICAgICAgdGhpcy5wb2xsKClcbiAgICAgICAgICBicmVha1xuICAgICAgICBjYXNlIDIwNDpcbiAgICAgICAgICB0aGlzLnBvbGwoKVxuICAgICAgICAgIGJyZWFrXG4gICAgICAgIGNhc2UgNDEwOlxuICAgICAgICAgIHRoaXMucmVhZHlTdGF0ZSA9IFNPQ0tFVF9TVEFURVMub3BlblxuICAgICAgICAgIHRoaXMub25vcGVuKHt9KVxuICAgICAgICAgIHRoaXMucG9sbCgpXG4gICAgICAgICAgYnJlYWtcbiAgICAgICAgY2FzZSA0MDM6XG4gICAgICAgICAgdGhpcy5vbmVycm9yKDQwMylcbiAgICAgICAgICB0aGlzLmNsb3NlKDEwMDgsIFwiZm9yYmlkZGVuXCIsIGZhbHNlKVxuICAgICAgICAgIGJyZWFrXG4gICAgICAgIGNhc2UgMDpcbiAgICAgICAgY2FzZSA1MDA6XG4gICAgICAgICAgdGhpcy5vbmVycm9yKDUwMClcbiAgICAgICAgICB0aGlzLmNsb3NlQW5kUmV0cnkoMTAxMSwgXCJpbnRlcm5hbCBzZXJ2ZXIgZXJyb3JcIiwgNTAwKVxuICAgICAgICAgIGJyZWFrXG4gICAgICAgIGRlZmF1bHQ6IHRocm93IG5ldyBFcnJvcihgdW5oYW5kbGVkIHBvbGwgc3RhdHVzICR7c3RhdHVzfWApXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIC8vIHdlIGNvbGxlY3QgYWxsIHB1c2hlcyB3aXRoaW4gdGhlIGN1cnJlbnQgZXZlbnQgbG9vcCBieVxuICAvLyBzZXRUaW1lb3V0IDAsIHdoaWNoIG9wdGltaXplcyBiYWNrLXRvLWJhY2sgcHJvY2VkdXJhbFxuICAvLyBwdXNoZXMgYWdhaW5zdCBhbiBlbXB0eSBidWZmZXJcblxuICBzZW5kKGJvZHkpe1xuICAgIGlmKHR5cGVvZihib2R5KSAhPT0gXCJzdHJpbmdcIil7IGJvZHkgPSBhcnJheUJ1ZmZlclRvQmFzZTY0KGJvZHkpIH1cbiAgICBpZih0aGlzLmN1cnJlbnRCYXRjaCl7XG4gICAgICB0aGlzLmN1cnJlbnRCYXRjaC5wdXNoKGJvZHkpXG4gICAgfSBlbHNlIGlmKHRoaXMuYXdhaXRpbmdCYXRjaEFjayl7XG4gICAgICB0aGlzLmJhdGNoQnVmZmVyLnB1c2goYm9keSlcbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy5jdXJyZW50QmF0Y2ggPSBbYm9keV1cbiAgICAgIHRoaXMuY3VycmVudEJhdGNoVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgICAgdGhpcy5iYXRjaFNlbmQodGhpcy5jdXJyZW50QmF0Y2gpXG4gICAgICAgIHRoaXMuY3VycmVudEJhdGNoID0gbnVsbFxuICAgICAgfSwgMClcbiAgICB9XG4gIH1cblxuICBiYXRjaFNlbmQobWVzc2FnZXMpe1xuICAgIHRoaXMuYXdhaXRpbmdCYXRjaEFjayA9IHRydWVcbiAgICB0aGlzLmFqYXgoXCJQT1NUXCIsIFwiYXBwbGljYXRpb24veC1uZGpzb25cIiwgbWVzc2FnZXMuam9pbihcIlxcblwiKSwgKCkgPT4gdGhpcy5vbmVycm9yKFwidGltZW91dFwiKSwgcmVzcCA9PiB7XG4gICAgICB0aGlzLmF3YWl0aW5nQmF0Y2hBY2sgPSBmYWxzZVxuICAgICAgaWYoIXJlc3AgfHwgcmVzcC5zdGF0dXMgIT09IDIwMCl7XG4gICAgICAgIHRoaXMub25lcnJvcihyZXNwICYmIHJlc3Auc3RhdHVzKVxuICAgICAgICB0aGlzLmNsb3NlQW5kUmV0cnkoMTAxMSwgXCJpbnRlcm5hbCBzZXJ2ZXIgZXJyb3JcIiwgZmFsc2UpXG4gICAgICB9IGVsc2UgaWYodGhpcy5iYXRjaEJ1ZmZlci5sZW5ndGggPiAwKXtcbiAgICAgICAgdGhpcy5iYXRjaFNlbmQodGhpcy5iYXRjaEJ1ZmZlcilcbiAgICAgICAgdGhpcy5iYXRjaEJ1ZmZlciA9IFtdXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIGNsb3NlKGNvZGUsIHJlYXNvbiwgd2FzQ2xlYW4pe1xuICAgIGZvcihsZXQgcmVxIG9mIHRoaXMucmVxcyl7IHJlcS5hYm9ydCgpIH1cbiAgICB0aGlzLnJlYWR5U3RhdGUgPSBTT0NLRVRfU1RBVEVTLmNsb3NlZFxuICAgIGxldCBvcHRzID0gT2JqZWN0LmFzc2lnbih7Y29kZTogMTAwMCwgcmVhc29uOiB1bmRlZmluZWQsIHdhc0NsZWFuOiB0cnVlfSwge2NvZGUsIHJlYXNvbiwgd2FzQ2xlYW59KVxuICAgIHRoaXMuYmF0Y2hCdWZmZXIgPSBbXVxuICAgIGNsZWFyVGltZW91dCh0aGlzLmN1cnJlbnRCYXRjaFRpbWVyKVxuICAgIHRoaXMuY3VycmVudEJhdGNoVGltZXIgPSBudWxsXG4gICAgaWYodHlwZW9mKENsb3NlRXZlbnQpICE9PSBcInVuZGVmaW5lZFwiKXtcbiAgICAgIHRoaXMub25jbG9zZShuZXcgQ2xvc2VFdmVudChcImNsb3NlXCIsIG9wdHMpKVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLm9uY2xvc2Uob3B0cylcbiAgICB9XG4gIH1cblxuICBhamF4KG1ldGhvZCwgY29udGVudFR5cGUsIGJvZHksIG9uQ2FsbGVyVGltZW91dCwgY2FsbGJhY2spe1xuICAgIGxldCByZXFcbiAgICBsZXQgb250aW1lb3V0ID0gKCkgPT4ge1xuICAgICAgdGhpcy5yZXFzLmRlbGV0ZShyZXEpXG4gICAgICBvbkNhbGxlclRpbWVvdXQoKVxuICAgIH1cbiAgICByZXEgPSBBamF4LnJlcXVlc3QobWV0aG9kLCB0aGlzLmVuZHBvaW50VVJMKCksIGNvbnRlbnRUeXBlLCBib2R5LCB0aGlzLnRpbWVvdXQsIG9udGltZW91dCwgcmVzcCA9PiB7XG4gICAgICB0aGlzLnJlcXMuZGVsZXRlKHJlcSlcbiAgICAgIGlmKHRoaXMuaXNBY3RpdmUoKSl7IGNhbGxiYWNrKHJlc3ApIH1cbiAgICB9KVxuICAgIHRoaXMucmVxcy5hZGQocmVxKVxuICB9XG59XG4iLCAiLyoqXG4gKiBJbml0aWFsaXplcyB0aGUgUHJlc2VuY2VcbiAqIEBwYXJhbSB7Q2hhbm5lbH0gY2hhbm5lbCAtIFRoZSBDaGFubmVsXG4gKiBAcGFyYW0ge09iamVjdH0gb3B0cyAtIFRoZSBvcHRpb25zLFxuICogICAgICAgIGZvciBleGFtcGxlIGB7ZXZlbnRzOiB7c3RhdGU6IFwic3RhdGVcIiwgZGlmZjogXCJkaWZmXCJ9fWBcbiAqL1xuZXhwb3J0IGRlZmF1bHQgY2xhc3MgUHJlc2VuY2Uge1xuXG4gIGNvbnN0cnVjdG9yKGNoYW5uZWwsIG9wdHMgPSB7fSl7XG4gICAgbGV0IGV2ZW50cyA9IG9wdHMuZXZlbnRzIHx8IHtzdGF0ZTogXCJwcmVzZW5jZV9zdGF0ZVwiLCBkaWZmOiBcInByZXNlbmNlX2RpZmZcIn1cbiAgICB0aGlzLnN0YXRlID0ge31cbiAgICB0aGlzLnBlbmRpbmdEaWZmcyA9IFtdXG4gICAgdGhpcy5jaGFubmVsID0gY2hhbm5lbFxuICAgIHRoaXMuam9pblJlZiA9IG51bGxcbiAgICB0aGlzLmNhbGxlciA9IHtcbiAgICAgIG9uSm9pbjogZnVuY3Rpb24gKCl7IH0sXG4gICAgICBvbkxlYXZlOiBmdW5jdGlvbiAoKXsgfSxcbiAgICAgIG9uU3luYzogZnVuY3Rpb24gKCl7IH1cbiAgICB9XG5cbiAgICB0aGlzLmNoYW5uZWwub24oZXZlbnRzLnN0YXRlLCBuZXdTdGF0ZSA9PiB7XG4gICAgICBsZXQge29uSm9pbiwgb25MZWF2ZSwgb25TeW5jfSA9IHRoaXMuY2FsbGVyXG5cbiAgICAgIHRoaXMuam9pblJlZiA9IHRoaXMuY2hhbm5lbC5qb2luUmVmKClcbiAgICAgIHRoaXMuc3RhdGUgPSBQcmVzZW5jZS5zeW5jU3RhdGUodGhpcy5zdGF0ZSwgbmV3U3RhdGUsIG9uSm9pbiwgb25MZWF2ZSlcblxuICAgICAgdGhpcy5wZW5kaW5nRGlmZnMuZm9yRWFjaChkaWZmID0+IHtcbiAgICAgICAgdGhpcy5zdGF0ZSA9IFByZXNlbmNlLnN5bmNEaWZmKHRoaXMuc3RhdGUsIGRpZmYsIG9uSm9pbiwgb25MZWF2ZSlcbiAgICAgIH0pXG4gICAgICB0aGlzLnBlbmRpbmdEaWZmcyA9IFtdXG4gICAgICBvblN5bmMoKVxuICAgIH0pXG5cbiAgICB0aGlzLmNoYW5uZWwub24oZXZlbnRzLmRpZmYsIGRpZmYgPT4ge1xuICAgICAgbGV0IHtvbkpvaW4sIG9uTGVhdmUsIG9uU3luY30gPSB0aGlzLmNhbGxlclxuXG4gICAgICBpZih0aGlzLmluUGVuZGluZ1N5bmNTdGF0ZSgpKXtcbiAgICAgICAgdGhpcy5wZW5kaW5nRGlmZnMucHVzaChkaWZmKVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdGhpcy5zdGF0ZSA9IFByZXNlbmNlLnN5bmNEaWZmKHRoaXMuc3RhdGUsIGRpZmYsIG9uSm9pbiwgb25MZWF2ZSlcbiAgICAgICAgb25TeW5jKClcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgb25Kb2luKGNhbGxiYWNrKXsgdGhpcy5jYWxsZXIub25Kb2luID0gY2FsbGJhY2sgfVxuXG4gIG9uTGVhdmUoY2FsbGJhY2speyB0aGlzLmNhbGxlci5vbkxlYXZlID0gY2FsbGJhY2sgfVxuXG4gIG9uU3luYyhjYWxsYmFjayl7IHRoaXMuY2FsbGVyLm9uU3luYyA9IGNhbGxiYWNrIH1cblxuICBsaXN0KGJ5KXsgcmV0dXJuIFByZXNlbmNlLmxpc3QodGhpcy5zdGF0ZSwgYnkpIH1cblxuICBpblBlbmRpbmdTeW5jU3RhdGUoKXtcbiAgICByZXR1cm4gIXRoaXMuam9pblJlZiB8fCAodGhpcy5qb2luUmVmICE9PSB0aGlzLmNoYW5uZWwuam9pblJlZigpKVxuICB9XG5cbiAgLy8gbG93ZXItbGV2ZWwgcHVibGljIHN0YXRpYyBBUElcblxuICAvKipcbiAgICogVXNlZCB0byBzeW5jIHRoZSBsaXN0IG9mIHByZXNlbmNlcyBvbiB0aGUgc2VydmVyXG4gICAqIHdpdGggdGhlIGNsaWVudCdzIHN0YXRlLiBBbiBvcHRpb25hbCBgb25Kb2luYCBhbmQgYG9uTGVhdmVgIGNhbGxiYWNrIGNhblxuICAgKiBiZSBwcm92aWRlZCB0byByZWFjdCB0byBjaGFuZ2VzIGluIHRoZSBjbGllbnQncyBsb2NhbCBwcmVzZW5jZXMgYWNyb3NzXG4gICAqIGRpc2Nvbm5lY3RzIGFuZCByZWNvbm5lY3RzIHdpdGggdGhlIHNlcnZlci5cbiAgICpcbiAgICogQHJldHVybnMge1ByZXNlbmNlfVxuICAgKi9cbiAgc3RhdGljIHN5bmNTdGF0ZShjdXJyZW50U3RhdGUsIG5ld1N0YXRlLCBvbkpvaW4sIG9uTGVhdmUpe1xuICAgIGxldCBzdGF0ZSA9IHRoaXMuY2xvbmUoY3VycmVudFN0YXRlKVxuICAgIGxldCBqb2lucyA9IHt9XG4gICAgbGV0IGxlYXZlcyA9IHt9XG5cbiAgICB0aGlzLm1hcChzdGF0ZSwgKGtleSwgcHJlc2VuY2UpID0+IHtcbiAgICAgIGlmKCFuZXdTdGF0ZVtrZXldKXtcbiAgICAgICAgbGVhdmVzW2tleV0gPSBwcmVzZW5jZVxuICAgICAgfVxuICAgIH0pXG4gICAgdGhpcy5tYXAobmV3U3RhdGUsIChrZXksIG5ld1ByZXNlbmNlKSA9PiB7XG4gICAgICBsZXQgY3VycmVudFByZXNlbmNlID0gc3RhdGVba2V5XVxuICAgICAgaWYoY3VycmVudFByZXNlbmNlKXtcbiAgICAgICAgbGV0IG5ld1JlZnMgPSBuZXdQcmVzZW5jZS5tZXRhcy5tYXAobSA9PiBtLnBoeF9yZWYpXG4gICAgICAgIGxldCBjdXJSZWZzID0gY3VycmVudFByZXNlbmNlLm1ldGFzLm1hcChtID0+IG0ucGh4X3JlZilcbiAgICAgICAgbGV0IGpvaW5lZE1ldGFzID0gbmV3UHJlc2VuY2UubWV0YXMuZmlsdGVyKG0gPT4gY3VyUmVmcy5pbmRleE9mKG0ucGh4X3JlZikgPCAwKVxuICAgICAgICBsZXQgbGVmdE1ldGFzID0gY3VycmVudFByZXNlbmNlLm1ldGFzLmZpbHRlcihtID0+IG5ld1JlZnMuaW5kZXhPZihtLnBoeF9yZWYpIDwgMClcbiAgICAgICAgaWYoam9pbmVkTWV0YXMubGVuZ3RoID4gMCl7XG4gICAgICAgICAgam9pbnNba2V5XSA9IG5ld1ByZXNlbmNlXG4gICAgICAgICAgam9pbnNba2V5XS5tZXRhcyA9IGpvaW5lZE1ldGFzXG4gICAgICAgIH1cbiAgICAgICAgaWYobGVmdE1ldGFzLmxlbmd0aCA+IDApe1xuICAgICAgICAgIGxlYXZlc1trZXldID0gdGhpcy5jbG9uZShjdXJyZW50UHJlc2VuY2UpXG4gICAgICAgICAgbGVhdmVzW2tleV0ubWV0YXMgPSBsZWZ0TWV0YXNcbiAgICAgICAgfVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgam9pbnNba2V5XSA9IG5ld1ByZXNlbmNlXG4gICAgICB9XG4gICAgfSlcbiAgICByZXR1cm4gdGhpcy5zeW5jRGlmZihzdGF0ZSwge2pvaW5zOiBqb2lucywgbGVhdmVzOiBsZWF2ZXN9LCBvbkpvaW4sIG9uTGVhdmUpXG4gIH1cblxuICAvKipcbiAgICpcbiAgICogVXNlZCB0byBzeW5jIGEgZGlmZiBvZiBwcmVzZW5jZSBqb2luIGFuZCBsZWF2ZVxuICAgKiBldmVudHMgZnJvbSB0aGUgc2VydmVyLCBhcyB0aGV5IGhhcHBlbi4gTGlrZSBgc3luY1N0YXRlYCwgYHN5bmNEaWZmYFxuICAgKiBhY2NlcHRzIG9wdGlvbmFsIGBvbkpvaW5gIGFuZCBgb25MZWF2ZWAgY2FsbGJhY2tzIHRvIHJlYWN0IHRvIGEgdXNlclxuICAgKiBqb2luaW5nIG9yIGxlYXZpbmcgZnJvbSBhIGRldmljZS5cbiAgICpcbiAgICogQHJldHVybnMge1ByZXNlbmNlfVxuICAgKi9cbiAgc3RhdGljIHN5bmNEaWZmKHN0YXRlLCBkaWZmLCBvbkpvaW4sIG9uTGVhdmUpe1xuICAgIGxldCB7am9pbnMsIGxlYXZlc30gPSB0aGlzLmNsb25lKGRpZmYpXG4gICAgaWYoIW9uSm9pbil7IG9uSm9pbiA9IGZ1bmN0aW9uICgpeyB9IH1cbiAgICBpZighb25MZWF2ZSl7IG9uTGVhdmUgPSBmdW5jdGlvbiAoKXsgfSB9XG5cbiAgICB0aGlzLm1hcChqb2lucywgKGtleSwgbmV3UHJlc2VuY2UpID0+IHtcbiAgICAgIGxldCBjdXJyZW50UHJlc2VuY2UgPSBzdGF0ZVtrZXldXG4gICAgICBzdGF0ZVtrZXldID0gdGhpcy5jbG9uZShuZXdQcmVzZW5jZSlcbiAgICAgIGlmKGN1cnJlbnRQcmVzZW5jZSl7XG4gICAgICAgIGxldCBqb2luZWRSZWZzID0gc3RhdGVba2V5XS5tZXRhcy5tYXAobSA9PiBtLnBoeF9yZWYpXG4gICAgICAgIGxldCBjdXJNZXRhcyA9IGN1cnJlbnRQcmVzZW5jZS5tZXRhcy5maWx0ZXIobSA9PiBqb2luZWRSZWZzLmluZGV4T2YobS5waHhfcmVmKSA8IDApXG4gICAgICAgIHN0YXRlW2tleV0ubWV0YXMudW5zaGlmdCguLi5jdXJNZXRhcylcbiAgICAgIH1cbiAgICAgIG9uSm9pbihrZXksIGN1cnJlbnRQcmVzZW5jZSwgbmV3UHJlc2VuY2UpXG4gICAgfSlcbiAgICB0aGlzLm1hcChsZWF2ZXMsIChrZXksIGxlZnRQcmVzZW5jZSkgPT4ge1xuICAgICAgbGV0IGN1cnJlbnRQcmVzZW5jZSA9IHN0YXRlW2tleV1cbiAgICAgIGlmKCFjdXJyZW50UHJlc2VuY2UpeyByZXR1cm4gfVxuICAgICAgbGV0IHJlZnNUb1JlbW92ZSA9IGxlZnRQcmVzZW5jZS5tZXRhcy5tYXAobSA9PiBtLnBoeF9yZWYpXG4gICAgICBjdXJyZW50UHJlc2VuY2UubWV0YXMgPSBjdXJyZW50UHJlc2VuY2UubWV0YXMuZmlsdGVyKHAgPT4ge1xuICAgICAgICByZXR1cm4gcmVmc1RvUmVtb3ZlLmluZGV4T2YocC5waHhfcmVmKSA8IDBcbiAgICAgIH0pXG4gICAgICBvbkxlYXZlKGtleSwgY3VycmVudFByZXNlbmNlLCBsZWZ0UHJlc2VuY2UpXG4gICAgICBpZihjdXJyZW50UHJlc2VuY2UubWV0YXMubGVuZ3RoID09PSAwKXtcbiAgICAgICAgZGVsZXRlIHN0YXRlW2tleV1cbiAgICAgIH1cbiAgICB9KVxuICAgIHJldHVybiBzdGF0ZVxuICB9XG5cbiAgLyoqXG4gICAqIFJldHVybnMgdGhlIGFycmF5IG9mIHByZXNlbmNlcywgd2l0aCBzZWxlY3RlZCBtZXRhZGF0YS5cbiAgICpcbiAgICogQHBhcmFtIHtPYmplY3R9IHByZXNlbmNlc1xuICAgKiBAcGFyYW0ge0Z1bmN0aW9ufSBjaG9vc2VyXG4gICAqXG4gICAqIEByZXR1cm5zIHtQcmVzZW5jZX1cbiAgICovXG4gIHN0YXRpYyBsaXN0KHByZXNlbmNlcywgY2hvb3Nlcil7XG4gICAgaWYoIWNob29zZXIpeyBjaG9vc2VyID0gZnVuY3Rpb24gKGtleSwgcHJlcyl7IHJldHVybiBwcmVzIH0gfVxuXG4gICAgcmV0dXJuIHRoaXMubWFwKHByZXNlbmNlcywgKGtleSwgcHJlc2VuY2UpID0+IHtcbiAgICAgIHJldHVybiBjaG9vc2VyKGtleSwgcHJlc2VuY2UpXG4gICAgfSlcbiAgfVxuXG4gIC8vIHByaXZhdGVcblxuICBzdGF0aWMgbWFwKG9iaiwgZnVuYyl7XG4gICAgcmV0dXJuIE9iamVjdC5nZXRPd25Qcm9wZXJ0eU5hbWVzKG9iaikubWFwKGtleSA9PiBmdW5jKGtleSwgb2JqW2tleV0pKVxuICB9XG5cbiAgc3RhdGljIGNsb25lKG9iail7IHJldHVybiBKU09OLnBhcnNlKEpTT04uc3RyaW5naWZ5KG9iaikpIH1cbn1cbiIsICIvKiBUaGUgZGVmYXVsdCBzZXJpYWxpemVyIGZvciBlbmNvZGluZyBhbmQgZGVjb2RpbmcgbWVzc2FnZXMgKi9cbmltcG9ydCB7XG4gIENIQU5ORUxfRVZFTlRTXG59IGZyb20gXCIuL2NvbnN0YW50c1wiXG5cbmV4cG9ydCBkZWZhdWx0IHtcbiAgSEVBREVSX0xFTkdUSDogMSxcbiAgTUVUQV9MRU5HVEg6IDQsXG4gIEtJTkRTOiB7cHVzaDogMCwgcmVwbHk6IDEsIGJyb2FkY2FzdDogMn0sXG5cbiAgZW5jb2RlKG1zZywgY2FsbGJhY2spe1xuICAgIGlmKG1zZy5wYXlsb2FkLmNvbnN0cnVjdG9yID09PSBBcnJheUJ1ZmZlcil7XG4gICAgICByZXR1cm4gY2FsbGJhY2sodGhpcy5iaW5hcnlFbmNvZGUobXNnKSlcbiAgICB9IGVsc2Uge1xuICAgICAgbGV0IHBheWxvYWQgPSBbbXNnLmpvaW5fcmVmLCBtc2cucmVmLCBtc2cudG9waWMsIG1zZy5ldmVudCwgbXNnLnBheWxvYWRdXG4gICAgICByZXR1cm4gY2FsbGJhY2soSlNPTi5zdHJpbmdpZnkocGF5bG9hZCkpXG4gICAgfVxuICB9LFxuXG4gIGRlY29kZShyYXdQYXlsb2FkLCBjYWxsYmFjayl7XG4gICAgaWYocmF3UGF5bG9hZC5jb25zdHJ1Y3RvciA9PT0gQXJyYXlCdWZmZXIpe1xuICAgICAgcmV0dXJuIGNhbGxiYWNrKHRoaXMuYmluYXJ5RGVjb2RlKHJhd1BheWxvYWQpKVxuICAgIH0gZWxzZSB7XG4gICAgICBsZXQgW2pvaW5fcmVmLCByZWYsIHRvcGljLCBldmVudCwgcGF5bG9hZF0gPSBKU09OLnBhcnNlKHJhd1BheWxvYWQpXG4gICAgICByZXR1cm4gY2FsbGJhY2soe2pvaW5fcmVmLCByZWYsIHRvcGljLCBldmVudCwgcGF5bG9hZH0pXG4gICAgfVxuICB9LFxuXG4gIC8vIHByaXZhdGVcblxuICBiaW5hcnlFbmNvZGUobWVzc2FnZSl7XG4gICAgbGV0IHtqb2luX3JlZiwgcmVmLCBldmVudCwgdG9waWMsIHBheWxvYWR9ID0gbWVzc2FnZVxuICAgIGxldCBtZXRhTGVuZ3RoID0gdGhpcy5NRVRBX0xFTkdUSCArIGpvaW5fcmVmLmxlbmd0aCArIHJlZi5sZW5ndGggKyB0b3BpYy5sZW5ndGggKyBldmVudC5sZW5ndGhcbiAgICBsZXQgaGVhZGVyID0gbmV3IEFycmF5QnVmZmVyKHRoaXMuSEVBREVSX0xFTkdUSCArIG1ldGFMZW5ndGgpXG4gICAgbGV0IHZpZXcgPSBuZXcgRGF0YVZpZXcoaGVhZGVyKVxuICAgIGxldCBvZmZzZXQgPSAwXG5cbiAgICB2aWV3LnNldFVpbnQ4KG9mZnNldCsrLCB0aGlzLktJTkRTLnB1c2gpIC8vIGtpbmRcbiAgICB2aWV3LnNldFVpbnQ4KG9mZnNldCsrLCBqb2luX3JlZi5sZW5ndGgpXG4gICAgdmlldy5zZXRVaW50OChvZmZzZXQrKywgcmVmLmxlbmd0aClcbiAgICB2aWV3LnNldFVpbnQ4KG9mZnNldCsrLCB0b3BpYy5sZW5ndGgpXG4gICAgdmlldy5zZXRVaW50OChvZmZzZXQrKywgZXZlbnQubGVuZ3RoKVxuICAgIEFycmF5LmZyb20oam9pbl9yZWYsIGNoYXIgPT4gdmlldy5zZXRVaW50OChvZmZzZXQrKywgY2hhci5jaGFyQ29kZUF0KDApKSlcbiAgICBBcnJheS5mcm9tKHJlZiwgY2hhciA9PiB2aWV3LnNldFVpbnQ4KG9mZnNldCsrLCBjaGFyLmNoYXJDb2RlQXQoMCkpKVxuICAgIEFycmF5LmZyb20odG9waWMsIGNoYXIgPT4gdmlldy5zZXRVaW50OChvZmZzZXQrKywgY2hhci5jaGFyQ29kZUF0KDApKSlcbiAgICBBcnJheS5mcm9tKGV2ZW50LCBjaGFyID0+IHZpZXcuc2V0VWludDgob2Zmc2V0KyssIGNoYXIuY2hhckNvZGVBdCgwKSkpXG5cbiAgICB2YXIgY29tYmluZWQgPSBuZXcgVWludDhBcnJheShoZWFkZXIuYnl0ZUxlbmd0aCArIHBheWxvYWQuYnl0ZUxlbmd0aClcbiAgICBjb21iaW5lZC5zZXQobmV3IFVpbnQ4QXJyYXkoaGVhZGVyKSwgMClcbiAgICBjb21iaW5lZC5zZXQobmV3IFVpbnQ4QXJyYXkocGF5bG9hZCksIGhlYWRlci5ieXRlTGVuZ3RoKVxuXG4gICAgcmV0dXJuIGNvbWJpbmVkLmJ1ZmZlclxuICB9LFxuXG4gIGJpbmFyeURlY29kZShidWZmZXIpe1xuICAgIGxldCB2aWV3ID0gbmV3IERhdGFWaWV3KGJ1ZmZlcilcbiAgICBsZXQga2luZCA9IHZpZXcuZ2V0VWludDgoMClcbiAgICBsZXQgZGVjb2RlciA9IG5ldyBUZXh0RGVjb2RlcigpXG4gICAgc3dpdGNoKGtpbmQpe1xuICAgICAgY2FzZSB0aGlzLktJTkRTLnB1c2g6IHJldHVybiB0aGlzLmRlY29kZVB1c2goYnVmZmVyLCB2aWV3LCBkZWNvZGVyKVxuICAgICAgY2FzZSB0aGlzLktJTkRTLnJlcGx5OiByZXR1cm4gdGhpcy5kZWNvZGVSZXBseShidWZmZXIsIHZpZXcsIGRlY29kZXIpXG4gICAgICBjYXNlIHRoaXMuS0lORFMuYnJvYWRjYXN0OiByZXR1cm4gdGhpcy5kZWNvZGVCcm9hZGNhc3QoYnVmZmVyLCB2aWV3LCBkZWNvZGVyKVxuICAgIH1cbiAgfSxcblxuICBkZWNvZGVQdXNoKGJ1ZmZlciwgdmlldywgZGVjb2Rlcil7XG4gICAgbGV0IGpvaW5SZWZTaXplID0gdmlldy5nZXRVaW50OCgxKVxuICAgIGxldCB0b3BpY1NpemUgPSB2aWV3LmdldFVpbnQ4KDIpXG4gICAgbGV0IGV2ZW50U2l6ZSA9IHZpZXcuZ2V0VWludDgoMylcbiAgICBsZXQgb2Zmc2V0ID0gdGhpcy5IRUFERVJfTEVOR1RIICsgdGhpcy5NRVRBX0xFTkdUSCAtIDEgLy8gcHVzaGVzIGhhdmUgbm8gcmVmXG4gICAgbGV0IGpvaW5SZWYgPSBkZWNvZGVyLmRlY29kZShidWZmZXIuc2xpY2Uob2Zmc2V0LCBvZmZzZXQgKyBqb2luUmVmU2l6ZSkpXG4gICAgb2Zmc2V0ID0gb2Zmc2V0ICsgam9pblJlZlNpemVcbiAgICBsZXQgdG9waWMgPSBkZWNvZGVyLmRlY29kZShidWZmZXIuc2xpY2Uob2Zmc2V0LCBvZmZzZXQgKyB0b3BpY1NpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIHRvcGljU2l6ZVxuICAgIGxldCBldmVudCA9IGRlY29kZXIuZGVjb2RlKGJ1ZmZlci5zbGljZShvZmZzZXQsIG9mZnNldCArIGV2ZW50U2l6ZSkpXG4gICAgb2Zmc2V0ID0gb2Zmc2V0ICsgZXZlbnRTaXplXG4gICAgbGV0IGRhdGEgPSBidWZmZXIuc2xpY2Uob2Zmc2V0LCBidWZmZXIuYnl0ZUxlbmd0aClcbiAgICByZXR1cm4ge2pvaW5fcmVmOiBqb2luUmVmLCByZWY6IG51bGwsIHRvcGljOiB0b3BpYywgZXZlbnQ6IGV2ZW50LCBwYXlsb2FkOiBkYXRhfVxuICB9LFxuXG4gIGRlY29kZVJlcGx5KGJ1ZmZlciwgdmlldywgZGVjb2Rlcil7XG4gICAgbGV0IGpvaW5SZWZTaXplID0gdmlldy5nZXRVaW50OCgxKVxuICAgIGxldCByZWZTaXplID0gdmlldy5nZXRVaW50OCgyKVxuICAgIGxldCB0b3BpY1NpemUgPSB2aWV3LmdldFVpbnQ4KDMpXG4gICAgbGV0IGV2ZW50U2l6ZSA9IHZpZXcuZ2V0VWludDgoNClcbiAgICBsZXQgb2Zmc2V0ID0gdGhpcy5IRUFERVJfTEVOR1RIICsgdGhpcy5NRVRBX0xFTkdUSFxuICAgIGxldCBqb2luUmVmID0gZGVjb2Rlci5kZWNvZGUoYnVmZmVyLnNsaWNlKG9mZnNldCwgb2Zmc2V0ICsgam9pblJlZlNpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIGpvaW5SZWZTaXplXG4gICAgbGV0IHJlZiA9IGRlY29kZXIuZGVjb2RlKGJ1ZmZlci5zbGljZShvZmZzZXQsIG9mZnNldCArIHJlZlNpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIHJlZlNpemVcbiAgICBsZXQgdG9waWMgPSBkZWNvZGVyLmRlY29kZShidWZmZXIuc2xpY2Uob2Zmc2V0LCBvZmZzZXQgKyB0b3BpY1NpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIHRvcGljU2l6ZVxuICAgIGxldCBldmVudCA9IGRlY29kZXIuZGVjb2RlKGJ1ZmZlci5zbGljZShvZmZzZXQsIG9mZnNldCArIGV2ZW50U2l6ZSkpXG4gICAgb2Zmc2V0ID0gb2Zmc2V0ICsgZXZlbnRTaXplXG4gICAgbGV0IGRhdGEgPSBidWZmZXIuc2xpY2Uob2Zmc2V0LCBidWZmZXIuYnl0ZUxlbmd0aClcbiAgICBsZXQgcGF5bG9hZCA9IHtzdGF0dXM6IGV2ZW50LCByZXNwb25zZTogZGF0YX1cbiAgICByZXR1cm4ge2pvaW5fcmVmOiBqb2luUmVmLCByZWY6IHJlZiwgdG9waWM6IHRvcGljLCBldmVudDogQ0hBTk5FTF9FVkVOVFMucmVwbHksIHBheWxvYWQ6IHBheWxvYWR9XG4gIH0sXG5cbiAgZGVjb2RlQnJvYWRjYXN0KGJ1ZmZlciwgdmlldywgZGVjb2Rlcil7XG4gICAgbGV0IHRvcGljU2l6ZSA9IHZpZXcuZ2V0VWludDgoMSlcbiAgICBsZXQgZXZlbnRTaXplID0gdmlldy5nZXRVaW50OCgyKVxuICAgIGxldCBvZmZzZXQgPSB0aGlzLkhFQURFUl9MRU5HVEggKyAyXG4gICAgbGV0IHRvcGljID0gZGVjb2Rlci5kZWNvZGUoYnVmZmVyLnNsaWNlKG9mZnNldCwgb2Zmc2V0ICsgdG9waWNTaXplKSlcbiAgICBvZmZzZXQgPSBvZmZzZXQgKyB0b3BpY1NpemVcbiAgICBsZXQgZXZlbnQgPSBkZWNvZGVyLmRlY29kZShidWZmZXIuc2xpY2Uob2Zmc2V0LCBvZmZzZXQgKyBldmVudFNpemUpKVxuICAgIG9mZnNldCA9IG9mZnNldCArIGV2ZW50U2l6ZVxuICAgIGxldCBkYXRhID0gYnVmZmVyLnNsaWNlKG9mZnNldCwgYnVmZmVyLmJ5dGVMZW5ndGgpXG5cbiAgICByZXR1cm4ge2pvaW5fcmVmOiBudWxsLCByZWY6IG51bGwsIHRvcGljOiB0b3BpYywgZXZlbnQ6IGV2ZW50LCBwYXlsb2FkOiBkYXRhfVxuICB9XG59XG4iLCAiaW1wb3J0IHtcbiAgZ2xvYmFsLFxuICBwaHhXaW5kb3csXG4gIENIQU5ORUxfRVZFTlRTLFxuICBERUZBVUxUX1RJTUVPVVQsXG4gIERFRkFVTFRfVlNOLFxuICBTT0NLRVRfU1RBVEVTLFxuICBUUkFOU1BPUlRTLFxuICBXU19DTE9TRV9OT1JNQUxcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCJcblxuaW1wb3J0IHtcbiAgY2xvc3VyZVxufSBmcm9tIFwiLi91dGlsc1wiXG5cbmltcG9ydCBBamF4IGZyb20gXCIuL2FqYXhcIlxuaW1wb3J0IENoYW5uZWwgZnJvbSBcIi4vY2hhbm5lbFwiXG5pbXBvcnQgTG9uZ1BvbGwgZnJvbSBcIi4vbG9uZ3BvbGxcIlxuaW1wb3J0IFNlcmlhbGl6ZXIgZnJvbSBcIi4vc2VyaWFsaXplclwiXG5pbXBvcnQgVGltZXIgZnJvbSBcIi4vdGltZXJcIlxuXG4vKiogSW5pdGlhbGl6ZXMgdGhlIFNvY2tldCAqXG4gKlxuICogRm9yIElFOCBzdXBwb3J0IHVzZSBhbiBFUzUtc2hpbSAoaHR0cHM6Ly9naXRodWIuY29tL2VzLXNoaW1zL2VzNS1zaGltKVxuICpcbiAqIEBwYXJhbSB7c3RyaW5nfSBlbmRQb2ludCAtIFRoZSBzdHJpbmcgV2ViU29ja2V0IGVuZHBvaW50LCBpZSwgYFwid3M6Ly9leGFtcGxlLmNvbS9zb2NrZXRcImAsXG4gKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYFwid3NzOi8vZXhhbXBsZS5jb21cImBcbiAqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBgXCIvc29ja2V0XCJgIChpbmhlcml0ZWQgaG9zdCAmIHByb3RvY29sKVxuICogQHBhcmFtIHtPYmplY3R9IFtvcHRzXSAtIE9wdGlvbmFsIGNvbmZpZ3VyYXRpb25cbiAqIEBwYXJhbSB7RnVuY3Rpb259IFtvcHRzLnRyYW5zcG9ydF0gLSBUaGUgV2Vic29ja2V0IFRyYW5zcG9ydCwgZm9yIGV4YW1wbGUgV2ViU29ja2V0IG9yIFBob2VuaXguTG9uZ1BvbGwuXG4gKlxuICogRGVmYXVsdHMgdG8gV2ViU29ja2V0IHdpdGggYXV0b21hdGljIExvbmdQb2xsIGZhbGxiYWNrIGlmIFdlYlNvY2tldCBpcyBub3QgZGVmaW5lZC5cbiAqIFRvIGZhbGxiYWNrIHRvIExvbmdQb2xsIHdoZW4gV2ViU29ja2V0IGF0dGVtcHRzIGZhaWwsIHVzZSBgbG9uZ1BvbGxGYWxsYmFja01zOiAyNTAwYC5cbiAqXG4gKiBAcGFyYW0ge0Z1bmN0aW9ufSBbb3B0cy5sb25nUG9sbEZhbGxiYWNrTXNdIC0gVGhlIG1pbGxpc2Vjb25kIHRpbWUgdG8gYXR0ZW1wdCB0aGUgcHJpbWFyeSB0cmFuc3BvcnRcbiAqIGJlZm9yZSBmYWxsaW5nIGJhY2sgdG8gdGhlIExvbmdQb2xsIHRyYW5zcG9ydC4gRGlzYWJsZWQgYnkgZGVmYXVsdC5cbiAqXG4gKiBAcGFyYW0ge0Z1bmN0aW9ufSBbb3B0cy5kZWJ1Z10gLSBXaGVuIHRydWUsIGVuYWJsZXMgZGVidWcgbG9nZ2luZy4gRGVmYXVsdCBmYWxzZS5cbiAqXG4gKiBAcGFyYW0ge0Z1bmN0aW9ufSBbb3B0cy5lbmNvZGVdIC0gVGhlIGZ1bmN0aW9uIHRvIGVuY29kZSBvdXRnb2luZyBtZXNzYWdlcy5cbiAqXG4gKiBEZWZhdWx0cyB0byBKU09OIGVuY29kZXIuXG4gKlxuICogQHBhcmFtIHtGdW5jdGlvbn0gW29wdHMuZGVjb2RlXSAtIFRoZSBmdW5jdGlvbiB0byBkZWNvZGUgaW5jb21pbmcgbWVzc2FnZXMuXG4gKlxuICogRGVmYXVsdHMgdG8gSlNPTjpcbiAqXG4gKiBgYGBqYXZhc2NyaXB0XG4gKiAocGF5bG9hZCwgY2FsbGJhY2spID0+IGNhbGxiYWNrKEpTT04ucGFyc2UocGF5bG9hZCkpXG4gKiBgYGBcbiAqXG4gKiBAcGFyYW0ge251bWJlcn0gW29wdHMudGltZW91dF0gLSBUaGUgZGVmYXVsdCB0aW1lb3V0IGluIG1pbGxpc2Vjb25kcyB0byB0cmlnZ2VyIHB1c2ggdGltZW91dHMuXG4gKlxuICogRGVmYXVsdHMgYERFRkFVTFRfVElNRU9VVGBcbiAqIEBwYXJhbSB7bnVtYmVyfSBbb3B0cy5oZWFydGJlYXRJbnRlcnZhbE1zXSAtIFRoZSBtaWxsaXNlYyBpbnRlcnZhbCB0byBzZW5kIGEgaGVhcnRiZWF0IG1lc3NhZ2VcbiAqIEBwYXJhbSB7bnVtYmVyfSBbb3B0cy5yZWNvbm5lY3RBZnRlck1zXSAtIFRoZSBvcHRpb25hbCBmdW5jdGlvbiB0aGF0IHJldHVybnMgdGhlIG1pbGxpc2VjXG4gKiBzb2NrZXQgcmVjb25uZWN0IGludGVydmFsLlxuICpcbiAqIERlZmF1bHRzIHRvIHN0ZXBwZWQgYmFja29mZiBvZjpcbiAqXG4gKiBgYGBqYXZhc2NyaXB0XG4gKiBmdW5jdGlvbih0cmllcyl7XG4gKiAgIHJldHVybiBbMTAsIDUwLCAxMDAsIDE1MCwgMjAwLCAyNTAsIDUwMCwgMTAwMCwgMjAwMF1bdHJpZXMgLSAxXSB8fCA1MDAwXG4gKiB9XG4gKiBgYGBgXG4gKlxuICogQHBhcmFtIHtudW1iZXJ9IFtvcHRzLnJlam9pbkFmdGVyTXNdIC0gVGhlIG9wdGlvbmFsIGZ1bmN0aW9uIHRoYXQgcmV0dXJucyB0aGUgbWlsbGlzZWNcbiAqIHJlam9pbiBpbnRlcnZhbCBmb3IgaW5kaXZpZHVhbCBjaGFubmVscy5cbiAqXG4gKiBgYGBqYXZhc2NyaXB0XG4gKiBmdW5jdGlvbih0cmllcyl7XG4gKiAgIHJldHVybiBbMTAwMCwgMjAwMCwgNTAwMF1bdHJpZXMgLSAxXSB8fCAxMDAwMFxuICogfVxuICogYGBgYFxuICpcbiAqIEBwYXJhbSB7RnVuY3Rpb259IFtvcHRzLmxvZ2dlcl0gLSBUaGUgb3B0aW9uYWwgZnVuY3Rpb24gZm9yIHNwZWNpYWxpemVkIGxvZ2dpbmcsIGllOlxuICpcbiAqIGBgYGphdmFzY3JpcHRcbiAqIGZ1bmN0aW9uKGtpbmQsIG1zZywgZGF0YSkge1xuICogICBjb25zb2xlLmxvZyhgJHtraW5kfTogJHttc2d9YCwgZGF0YSlcbiAqIH1cbiAqIGBgYFxuICpcbiAqIEBwYXJhbSB7bnVtYmVyfSBbb3B0cy5sb25ncG9sbGVyVGltZW91dF0gLSBUaGUgbWF4aW11bSB0aW1lb3V0IG9mIGEgbG9uZyBwb2xsIEFKQVggcmVxdWVzdC5cbiAqXG4gKiBEZWZhdWx0cyB0byAyMHMgKGRvdWJsZSB0aGUgc2VydmVyIGxvbmcgcG9sbCB0aW1lcikuXG4gKlxuICogQHBhcmFtIHsoT2JqZWN0fGZ1bmN0aW9uKX0gW29wdHMucGFyYW1zXSAtIFRoZSBvcHRpb25hbCBwYXJhbXMgdG8gcGFzcyB3aGVuIGNvbm5lY3RpbmdcbiAqIEBwYXJhbSB7c3RyaW5nfSBbb3B0cy5iaW5hcnlUeXBlXSAtIFRoZSBiaW5hcnkgdHlwZSB0byB1c2UgZm9yIGJpbmFyeSBXZWJTb2NrZXQgZnJhbWVzLlxuICpcbiAqIERlZmF1bHRzIHRvIFwiYXJyYXlidWZmZXJcIlxuICpcbiAqIEBwYXJhbSB7dnNufSBbb3B0cy52c25dIC0gVGhlIHNlcmlhbGl6ZXIncyBwcm90b2NvbCB2ZXJzaW9uIHRvIHNlbmQgb24gY29ubmVjdC5cbiAqXG4gKiBEZWZhdWx0cyB0byBERUZBVUxUX1ZTTi5cbiAqXG4gKiBAcGFyYW0ge09iamVjdH0gW29wdHMuc2Vzc2lvblN0b3JhZ2VdIC0gQW4gb3B0aW9uYWwgU3RvcmFnZSBjb21wYXRpYmxlIG9iamVjdFxuICogUGhvZW5peCB1c2VzIHNlc3Npb25TdG9yYWdlIGZvciBsb25ncG9sbCBmYWxsYmFjayBoaXN0b3J5LiBPdmVycmlkaW5nIHRoZSBzdG9yZSBpc1xuICogdXNlZnVsIHdoZW4gUGhvZW5peCB3b24ndCBoYXZlIGFjY2VzcyB0byBgc2Vzc2lvblN0b3JhZ2VgLiBGb3IgZXhhbXBsZSwgVGhpcyBjb3VsZFxuICogaGFwcGVuIGlmIGEgc2l0ZSBsb2FkcyBhIGNyb3NzLWRvbWFpbiBjaGFubmVsIGluIGFuIGlmcmFtZS4gRXhhbXBsZSB1c2FnZTpcbiAqXG4gKiAgICAgY2xhc3MgSW5NZW1vcnlTdG9yYWdlIHtcbiAqICAgICAgIGNvbnN0cnVjdG9yKCkgeyB0aGlzLnN0b3JhZ2UgPSB7fSB9XG4gKiAgICAgICBnZXRJdGVtKGtleU5hbWUpIHsgcmV0dXJuIHRoaXMuc3RvcmFnZVtrZXlOYW1lXSB8fCBudWxsIH1cbiAqICAgICAgIHJlbW92ZUl0ZW0oa2V5TmFtZSkgeyBkZWxldGUgdGhpcy5zdG9yYWdlW2tleU5hbWVdIH1cbiAqICAgICAgIHNldEl0ZW0oa2V5TmFtZSwga2V5VmFsdWUpIHsgdGhpcy5zdG9yYWdlW2tleU5hbWVdID0ga2V5VmFsdWUgfVxuICogICAgIH1cbiAqXG4qL1xuZXhwb3J0IGRlZmF1bHQgY2xhc3MgU29ja2V0IHtcbiAgY29uc3RydWN0b3IoZW5kUG9pbnQsIG9wdHMgPSB7fSl7XG4gICAgdGhpcy5zdGF0ZUNoYW5nZUNhbGxiYWNrcyA9IHtvcGVuOiBbXSwgY2xvc2U6IFtdLCBlcnJvcjogW10sIG1lc3NhZ2U6IFtdfVxuICAgIHRoaXMuY2hhbm5lbHMgPSBbXVxuICAgIHRoaXMuc2VuZEJ1ZmZlciA9IFtdXG4gICAgdGhpcy5yZWYgPSAwXG4gICAgdGhpcy50aW1lb3V0ID0gb3B0cy50aW1lb3V0IHx8IERFRkFVTFRfVElNRU9VVFxuICAgIHRoaXMudHJhbnNwb3J0ID0gb3B0cy50cmFuc3BvcnQgfHwgZ2xvYmFsLldlYlNvY2tldCB8fCBMb25nUG9sbFxuICAgIHRoaXMucHJpbWFyeVBhc3NlZEhlYWx0aENoZWNrID0gZmFsc2VcbiAgICB0aGlzLmxvbmdQb2xsRmFsbGJhY2tNcyA9IG9wdHMubG9uZ1BvbGxGYWxsYmFja01zXG4gICAgdGhpcy5mYWxsYmFja1RpbWVyID0gbnVsbFxuICAgIHRoaXMuc2Vzc2lvblN0b3JlID0gb3B0cy5zZXNzaW9uU3RvcmFnZSB8fCAoZ2xvYmFsICYmIGdsb2JhbC5zZXNzaW9uU3RvcmFnZSlcbiAgICB0aGlzLmVzdGFibGlzaGVkQ29ubmVjdGlvbnMgPSAwXG4gICAgdGhpcy5kZWZhdWx0RW5jb2RlciA9IFNlcmlhbGl6ZXIuZW5jb2RlLmJpbmQoU2VyaWFsaXplcilcbiAgICB0aGlzLmRlZmF1bHREZWNvZGVyID0gU2VyaWFsaXplci5kZWNvZGUuYmluZChTZXJpYWxpemVyKVxuICAgIHRoaXMuY2xvc2VXYXNDbGVhbiA9IGZhbHNlXG4gICAgdGhpcy5kaXNjb25uZWN0aW5nID0gZmFsc2VcbiAgICB0aGlzLmJpbmFyeVR5cGUgPSBvcHRzLmJpbmFyeVR5cGUgfHwgXCJhcnJheWJ1ZmZlclwiXG4gICAgdGhpcy5jb25uZWN0Q2xvY2sgPSAxXG4gICAgaWYodGhpcy50cmFuc3BvcnQgIT09IExvbmdQb2xsKXtcbiAgICAgIHRoaXMuZW5jb2RlID0gb3B0cy5lbmNvZGUgfHwgdGhpcy5kZWZhdWx0RW5jb2RlclxuICAgICAgdGhpcy5kZWNvZGUgPSBvcHRzLmRlY29kZSB8fCB0aGlzLmRlZmF1bHREZWNvZGVyXG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMuZW5jb2RlID0gdGhpcy5kZWZhdWx0RW5jb2RlclxuICAgICAgdGhpcy5kZWNvZGUgPSB0aGlzLmRlZmF1bHREZWNvZGVyXG4gICAgfVxuICAgIGxldCBhd2FpdGluZ0Nvbm5lY3Rpb25PblBhZ2VTaG93ID0gbnVsbFxuICAgIGlmKHBoeFdpbmRvdyAmJiBwaHhXaW5kb3cuYWRkRXZlbnRMaXN0ZW5lcil7XG4gICAgICBwaHhXaW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihcInBhZ2VoaWRlXCIsIF9lID0+IHtcbiAgICAgICAgaWYodGhpcy5jb25uKXtcbiAgICAgICAgICB0aGlzLmRpc2Nvbm5lY3QoKVxuICAgICAgICAgIGF3YWl0aW5nQ29ubmVjdGlvbk9uUGFnZVNob3cgPSB0aGlzLmNvbm5lY3RDbG9ja1xuICAgICAgICB9XG4gICAgICB9KVxuICAgICAgcGh4V2luZG93LmFkZEV2ZW50TGlzdGVuZXIoXCJwYWdlc2hvd1wiLCBfZSA9PiB7XG4gICAgICAgIGlmKGF3YWl0aW5nQ29ubmVjdGlvbk9uUGFnZVNob3cgPT09IHRoaXMuY29ubmVjdENsb2NrKXtcbiAgICAgICAgICBhd2FpdGluZ0Nvbm5lY3Rpb25PblBhZ2VTaG93ID0gbnVsbFxuICAgICAgICAgIHRoaXMuY29ubmVjdCgpXG4gICAgICAgIH1cbiAgICAgIH0pXG4gICAgfVxuICAgIHRoaXMuaGVhcnRiZWF0SW50ZXJ2YWxNcyA9IG9wdHMuaGVhcnRiZWF0SW50ZXJ2YWxNcyB8fCAzMDAwMFxuICAgIHRoaXMucmVqb2luQWZ0ZXJNcyA9ICh0cmllcykgPT4ge1xuICAgICAgaWYob3B0cy5yZWpvaW5BZnRlck1zKXtcbiAgICAgICAgcmV0dXJuIG9wdHMucmVqb2luQWZ0ZXJNcyh0cmllcylcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHJldHVybiBbMTAwMCwgMjAwMCwgNTAwMF1bdHJpZXMgLSAxXSB8fCAxMDAwMFxuICAgICAgfVxuICAgIH1cbiAgICB0aGlzLnJlY29ubmVjdEFmdGVyTXMgPSAodHJpZXMpID0+IHtcbiAgICAgIGlmKG9wdHMucmVjb25uZWN0QWZ0ZXJNcyl7XG4gICAgICAgIHJldHVybiBvcHRzLnJlY29ubmVjdEFmdGVyTXModHJpZXMpXG4gICAgICB9IGVsc2Uge1xuICAgICAgICByZXR1cm4gWzEwLCA1MCwgMTAwLCAxNTAsIDIwMCwgMjUwLCA1MDAsIDEwMDAsIDIwMDBdW3RyaWVzIC0gMV0gfHwgNTAwMFxuICAgICAgfVxuICAgIH1cbiAgICB0aGlzLmxvZ2dlciA9IG9wdHMubG9nZ2VyIHx8IG51bGxcbiAgICBpZighdGhpcy5sb2dnZXIgJiYgb3B0cy5kZWJ1Zyl7XG4gICAgICB0aGlzLmxvZ2dlciA9IChraW5kLCBtc2csIGRhdGEpID0+IHsgY29uc29sZS5sb2coYCR7a2luZH06ICR7bXNnfWAsIGRhdGEpIH1cbiAgICB9XG4gICAgdGhpcy5sb25ncG9sbGVyVGltZW91dCA9IG9wdHMubG9uZ3BvbGxlclRpbWVvdXQgfHwgMjAwMDBcbiAgICB0aGlzLnBhcmFtcyA9IGNsb3N1cmUob3B0cy5wYXJhbXMgfHwge30pXG4gICAgdGhpcy5lbmRQb2ludCA9IGAke2VuZFBvaW50fS8ke1RSQU5TUE9SVFMud2Vic29ja2V0fWBcbiAgICB0aGlzLnZzbiA9IG9wdHMudnNuIHx8IERFRkFVTFRfVlNOXG4gICAgdGhpcy5oZWFydGJlYXRUaW1lb3V0VGltZXIgPSBudWxsXG4gICAgdGhpcy5oZWFydGJlYXRUaW1lciA9IG51bGxcbiAgICB0aGlzLnBlbmRpbmdIZWFydGJlYXRSZWYgPSBudWxsXG4gICAgdGhpcy5yZWNvbm5lY3RUaW1lciA9IG5ldyBUaW1lcigoKSA9PiB7XG4gICAgICB0aGlzLnRlYXJkb3duKCgpID0+IHRoaXMuY29ubmVjdCgpKVxuICAgIH0sIHRoaXMucmVjb25uZWN0QWZ0ZXJNcylcbiAgfVxuXG4gIC8qKlxuICAgKiBSZXR1cm5zIHRoZSBMb25nUG9sbCB0cmFuc3BvcnQgcmVmZXJlbmNlXG4gICAqL1xuICBnZXRMb25nUG9sbFRyYW5zcG9ydCgpeyByZXR1cm4gTG9uZ1BvbGwgfVxuXG4gIC8qKlxuICAgKiBEaXNjb25uZWN0cyBhbmQgcmVwbGFjZXMgdGhlIGFjdGl2ZSB0cmFuc3BvcnRcbiAgICpcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gbmV3VHJhbnNwb3J0IC0gVGhlIG5ldyB0cmFuc3BvcnQgY2xhc3MgdG8gaW5zdGFudGlhdGVcbiAgICpcbiAgICovXG4gIHJlcGxhY2VUcmFuc3BvcnQobmV3VHJhbnNwb3J0KXtcbiAgICB0aGlzLmNvbm5lY3RDbG9jaysrXG4gICAgdGhpcy5jbG9zZVdhc0NsZWFuID0gdHJ1ZVxuICAgIGNsZWFyVGltZW91dCh0aGlzLmZhbGxiYWNrVGltZXIpXG4gICAgdGhpcy5yZWNvbm5lY3RUaW1lci5yZXNldCgpXG4gICAgaWYodGhpcy5jb25uKXtcbiAgICAgIHRoaXMuY29ubi5jbG9zZSgpXG4gICAgICB0aGlzLmNvbm4gPSBudWxsXG4gICAgfVxuICAgIHRoaXMudHJhbnNwb3J0ID0gbmV3VHJhbnNwb3J0XG4gIH1cblxuICAvKipcbiAgICogUmV0dXJucyB0aGUgc29ja2V0IHByb3RvY29sXG4gICAqXG4gICAqIEByZXR1cm5zIHtzdHJpbmd9XG4gICAqL1xuICBwcm90b2NvbCgpeyByZXR1cm4gbG9jYXRpb24ucHJvdG9jb2wubWF0Y2goL15odHRwcy8pID8gXCJ3c3NcIiA6IFwid3NcIiB9XG5cbiAgLyoqXG4gICAqIFRoZSBmdWxseSBxdWFsaWZpZWQgc29ja2V0IHVybFxuICAgKlxuICAgKiBAcmV0dXJucyB7c3RyaW5nfVxuICAgKi9cbiAgZW5kUG9pbnRVUkwoKXtcbiAgICBsZXQgdXJpID0gQWpheC5hcHBlbmRQYXJhbXMoXG4gICAgICBBamF4LmFwcGVuZFBhcmFtcyh0aGlzLmVuZFBvaW50LCB0aGlzLnBhcmFtcygpKSwge3ZzbjogdGhpcy52c259KVxuICAgIGlmKHVyaS5jaGFyQXQoMCkgIT09IFwiL1wiKXsgcmV0dXJuIHVyaSB9XG4gICAgaWYodXJpLmNoYXJBdCgxKSA9PT0gXCIvXCIpeyByZXR1cm4gYCR7dGhpcy5wcm90b2NvbCgpfToke3VyaX1gIH1cblxuICAgIHJldHVybiBgJHt0aGlzLnByb3RvY29sKCl9Oi8vJHtsb2NhdGlvbi5ob3N0fSR7dXJpfWBcbiAgfVxuXG4gIC8qKlxuICAgKiBEaXNjb25uZWN0cyB0aGUgc29ja2V0XG4gICAqXG4gICAqIFNlZSBodHRwczovL2RldmVsb3Blci5tb3ppbGxhLm9yZy9lbi1VUy9kb2NzL1dlYi9BUEkvQ2xvc2VFdmVudCNTdGF0dXNfY29kZXMgZm9yIHZhbGlkIHN0YXR1cyBjb2Rlcy5cbiAgICpcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2sgLSBPcHRpb25hbCBjYWxsYmFjayB3aGljaCBpcyBjYWxsZWQgYWZ0ZXIgc29ja2V0IGlzIGRpc2Nvbm5lY3RlZC5cbiAgICogQHBhcmFtIHtpbnRlZ2VyfSBjb2RlIC0gQSBzdGF0dXMgY29kZSBmb3IgZGlzY29ubmVjdGlvbiAoT3B0aW9uYWwpLlxuICAgKiBAcGFyYW0ge3N0cmluZ30gcmVhc29uIC0gQSB0ZXh0dWFsIGRlc2NyaXB0aW9uIG9mIHRoZSByZWFzb24gdG8gZGlzY29ubmVjdC4gKE9wdGlvbmFsKVxuICAgKi9cbiAgZGlzY29ubmVjdChjYWxsYmFjaywgY29kZSwgcmVhc29uKXtcbiAgICB0aGlzLmNvbm5lY3RDbG9jaysrXG4gICAgdGhpcy5kaXNjb25uZWN0aW5nID0gdHJ1ZVxuICAgIHRoaXMuY2xvc2VXYXNDbGVhbiA9IHRydWVcbiAgICBjbGVhclRpbWVvdXQodGhpcy5mYWxsYmFja1RpbWVyKVxuICAgIHRoaXMucmVjb25uZWN0VGltZXIucmVzZXQoKVxuICAgIHRoaXMudGVhcmRvd24oKCkgPT4ge1xuICAgICAgdGhpcy5kaXNjb25uZWN0aW5nID0gZmFsc2VcbiAgICAgIGNhbGxiYWNrICYmIGNhbGxiYWNrKClcbiAgICB9LCBjb2RlLCByZWFzb24pXG4gIH1cblxuICAvKipcbiAgICpcbiAgICogQHBhcmFtIHtPYmplY3R9IHBhcmFtcyAtIFRoZSBwYXJhbXMgdG8gc2VuZCB3aGVuIGNvbm5lY3RpbmcsIGZvciBleGFtcGxlIGB7dXNlcl9pZDogdXNlclRva2VufWBcbiAgICpcbiAgICogUGFzc2luZyBwYXJhbXMgdG8gY29ubmVjdCBpcyBkZXByZWNhdGVkOyBwYXNzIHRoZW0gaW4gdGhlIFNvY2tldCBjb25zdHJ1Y3RvciBpbnN0ZWFkOlxuICAgKiBgbmV3IFNvY2tldChcIi9zb2NrZXRcIiwge3BhcmFtczoge3VzZXJfaWQ6IHVzZXJUb2tlbn19KWAuXG4gICAqL1xuICBjb25uZWN0KHBhcmFtcyl7XG4gICAgaWYocGFyYW1zKXtcbiAgICAgIGNvbnNvbGUgJiYgY29uc29sZS5sb2coXCJwYXNzaW5nIHBhcmFtcyB0byBjb25uZWN0IGlzIGRlcHJlY2F0ZWQuIEluc3RlYWQgcGFzcyA6cGFyYW1zIHRvIHRoZSBTb2NrZXQgY29uc3RydWN0b3JcIilcbiAgICAgIHRoaXMucGFyYW1zID0gY2xvc3VyZShwYXJhbXMpXG4gICAgfVxuICAgIGlmKHRoaXMuY29ubiAmJiAhdGhpcy5kaXNjb25uZWN0aW5nKXsgcmV0dXJuIH1cbiAgICBpZih0aGlzLmxvbmdQb2xsRmFsbGJhY2tNcyAmJiB0aGlzLnRyYW5zcG9ydCAhPT0gTG9uZ1BvbGwpe1xuICAgICAgdGhpcy5jb25uZWN0V2l0aEZhbGxiYWNrKExvbmdQb2xsLCB0aGlzLmxvbmdQb2xsRmFsbGJhY2tNcylcbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy50cmFuc3BvcnRDb25uZWN0KClcbiAgICB9XG4gIH1cblxuICAvKipcbiAgICogTG9ncyB0aGUgbWVzc2FnZS4gT3ZlcnJpZGUgYHRoaXMubG9nZ2VyYCBmb3Igc3BlY2lhbGl6ZWQgbG9nZ2luZy4gbm9vcHMgYnkgZGVmYXVsdFxuICAgKiBAcGFyYW0ge3N0cmluZ30ga2luZFxuICAgKiBAcGFyYW0ge3N0cmluZ30gbXNnXG4gICAqIEBwYXJhbSB7T2JqZWN0fSBkYXRhXG4gICAqL1xuICBsb2coa2luZCwgbXNnLCBkYXRhKXsgdGhpcy5sb2dnZXIgJiYgdGhpcy5sb2dnZXIoa2luZCwgbXNnLCBkYXRhKSB9XG5cbiAgLyoqXG4gICAqIFJldHVybnMgdHJ1ZSBpZiBhIGxvZ2dlciBoYXMgYmVlbiBzZXQgb24gdGhpcyBzb2NrZXQuXG4gICAqL1xuICBoYXNMb2dnZXIoKXsgcmV0dXJuIHRoaXMubG9nZ2VyICE9PSBudWxsIH1cblxuICAvKipcbiAgICogUmVnaXN0ZXJzIGNhbGxiYWNrcyBmb3IgY29ubmVjdGlvbiBvcGVuIGV2ZW50c1xuICAgKlxuICAgKiBAZXhhbXBsZSBzb2NrZXQub25PcGVuKGZ1bmN0aW9uKCl7IGNvbnNvbGUuaW5mbyhcInRoZSBzb2NrZXQgd2FzIG9wZW5lZFwiKSB9KVxuICAgKlxuICAgKiBAcGFyYW0ge0Z1bmN0aW9ufSBjYWxsYmFja1xuICAgKi9cbiAgb25PcGVuKGNhbGxiYWNrKXtcbiAgICBsZXQgcmVmID0gdGhpcy5tYWtlUmVmKClcbiAgICB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzLm9wZW4ucHVzaChbcmVmLCBjYWxsYmFja10pXG4gICAgcmV0dXJuIHJlZlxuICB9XG5cbiAgLyoqXG4gICAqIFJlZ2lzdGVycyBjYWxsYmFja3MgZm9yIGNvbm5lY3Rpb24gY2xvc2UgZXZlbnRzXG4gICAqIEBwYXJhbSB7RnVuY3Rpb259IGNhbGxiYWNrXG4gICAqL1xuICBvbkNsb3NlKGNhbGxiYWNrKXtcbiAgICBsZXQgcmVmID0gdGhpcy5tYWtlUmVmKClcbiAgICB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzLmNsb3NlLnB1c2goW3JlZiwgY2FsbGJhY2tdKVxuICAgIHJldHVybiByZWZcbiAgfVxuXG4gIC8qKlxuICAgKiBSZWdpc3RlcnMgY2FsbGJhY2tzIGZvciBjb25uZWN0aW9uIGVycm9yIGV2ZW50c1xuICAgKlxuICAgKiBAZXhhbXBsZSBzb2NrZXQub25FcnJvcihmdW5jdGlvbihlcnJvcil7IGFsZXJ0KFwiQW4gZXJyb3Igb2NjdXJyZWRcIikgfSlcbiAgICpcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2tcbiAgICovXG4gIG9uRXJyb3IoY2FsbGJhY2spe1xuICAgIGxldCByZWYgPSB0aGlzLm1ha2VSZWYoKVxuICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3MuZXJyb3IucHVzaChbcmVmLCBjYWxsYmFja10pXG4gICAgcmV0dXJuIHJlZlxuICB9XG5cbiAgLyoqXG4gICAqIFJlZ2lzdGVycyBjYWxsYmFja3MgZm9yIGNvbm5lY3Rpb24gbWVzc2FnZSBldmVudHNcbiAgICogQHBhcmFtIHtGdW5jdGlvbn0gY2FsbGJhY2tcbiAgICovXG4gIG9uTWVzc2FnZShjYWxsYmFjayl7XG4gICAgbGV0IHJlZiA9IHRoaXMubWFrZVJlZigpXG4gICAgdGhpcy5zdGF0ZUNoYW5nZUNhbGxiYWNrcy5tZXNzYWdlLnB1c2goW3JlZiwgY2FsbGJhY2tdKVxuICAgIHJldHVybiByZWZcbiAgfVxuXG4gIC8qKlxuICAgKiBQaW5ncyB0aGUgc2VydmVyIGFuZCBpbnZva2VzIHRoZSBjYWxsYmFjayB3aXRoIHRoZSBSVFQgaW4gbWlsbGlzZWNvbmRzXG4gICAqIEBwYXJhbSB7RnVuY3Rpb259IGNhbGxiYWNrXG4gICAqXG4gICAqIFJldHVybnMgdHJ1ZSBpZiB0aGUgcGluZyB3YXMgcHVzaGVkIG9yIGZhbHNlIGlmIHVuYWJsZSB0byBiZSBwdXNoZWQuXG4gICAqL1xuICBwaW5nKGNhbGxiYWNrKXtcbiAgICBpZighdGhpcy5pc0Nvbm5lY3RlZCgpKXsgcmV0dXJuIGZhbHNlIH1cbiAgICBsZXQgcmVmID0gdGhpcy5tYWtlUmVmKClcbiAgICBsZXQgc3RhcnRUaW1lID0gRGF0ZS5ub3coKVxuICAgIHRoaXMucHVzaCh7dG9waWM6IFwicGhvZW5peFwiLCBldmVudDogXCJoZWFydGJlYXRcIiwgcGF5bG9hZDoge30sIHJlZjogcmVmfSlcbiAgICBsZXQgb25Nc2dSZWYgPSB0aGlzLm9uTWVzc2FnZShtc2cgPT4ge1xuICAgICAgaWYobXNnLnJlZiA9PT0gcmVmKXtcbiAgICAgICAgdGhpcy5vZmYoW29uTXNnUmVmXSlcbiAgICAgICAgY2FsbGJhY2soRGF0ZS5ub3coKSAtIHN0YXJ0VGltZSlcbiAgICAgIH1cbiAgICB9KVxuICAgIHJldHVybiB0cnVlXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG5cbiAgdHJhbnNwb3J0Q29ubmVjdCgpe1xuICAgIHRoaXMuY29ubmVjdENsb2NrKytcbiAgICB0aGlzLmNsb3NlV2FzQ2xlYW4gPSBmYWxzZVxuICAgIHRoaXMuY29ubiA9IG5ldyB0aGlzLnRyYW5zcG9ydCh0aGlzLmVuZFBvaW50VVJMKCkpXG4gICAgdGhpcy5jb25uLmJpbmFyeVR5cGUgPSB0aGlzLmJpbmFyeVR5cGVcbiAgICB0aGlzLmNvbm4udGltZW91dCA9IHRoaXMubG9uZ3BvbGxlclRpbWVvdXRcbiAgICB0aGlzLmNvbm4ub25vcGVuID0gKCkgPT4gdGhpcy5vbkNvbm5PcGVuKClcbiAgICB0aGlzLmNvbm4ub25lcnJvciA9IGVycm9yID0+IHRoaXMub25Db25uRXJyb3IoZXJyb3IpXG4gICAgdGhpcy5jb25uLm9ubWVzc2FnZSA9IGV2ZW50ID0+IHRoaXMub25Db25uTWVzc2FnZShldmVudClcbiAgICB0aGlzLmNvbm4ub25jbG9zZSA9IGV2ZW50ID0+IHRoaXMub25Db25uQ2xvc2UoZXZlbnQpXG4gIH1cblxuICBnZXRTZXNzaW9uKGtleSl7IHJldHVybiB0aGlzLnNlc3Npb25TdG9yZSAmJiB0aGlzLnNlc3Npb25TdG9yZS5nZXRJdGVtKGtleSkgfVxuXG4gIHN0b3JlU2Vzc2lvbihrZXksIHZhbCl7IHRoaXMuc2Vzc2lvblN0b3JlICYmIHRoaXMuc2Vzc2lvblN0b3JlLnNldEl0ZW0oa2V5LCB2YWwpIH1cblxuICBjb25uZWN0V2l0aEZhbGxiYWNrKGZhbGxiYWNrVHJhbnNwb3J0LCBmYWxsYmFja1RocmVzaG9sZCA9IDI1MDApe1xuICAgIGNsZWFyVGltZW91dCh0aGlzLmZhbGxiYWNrVGltZXIpXG4gICAgbGV0IGVzdGFibGlzaGVkID0gZmFsc2VcbiAgICBsZXQgcHJpbWFyeVRyYW5zcG9ydCA9IHRydWVcbiAgICBsZXQgb3BlblJlZiwgZXJyb3JSZWZcbiAgICBsZXQgZmFsbGJhY2sgPSAocmVhc29uKSA9PiB7XG4gICAgICB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBgZmFsbGluZyBiYWNrIHRvICR7ZmFsbGJhY2tUcmFuc3BvcnQubmFtZX0uLi5gLCByZWFzb24pXG4gICAgICB0aGlzLm9mZihbb3BlblJlZiwgZXJyb3JSZWZdKVxuICAgICAgcHJpbWFyeVRyYW5zcG9ydCA9IGZhbHNlXG4gICAgICB0aGlzLnJlcGxhY2VUcmFuc3BvcnQoZmFsbGJhY2tUcmFuc3BvcnQpXG4gICAgICB0aGlzLnRyYW5zcG9ydENvbm5lY3QoKVxuICAgIH1cbiAgICBpZih0aGlzLmdldFNlc3Npb24oYHBoeDpmYWxsYmFjazoke2ZhbGxiYWNrVHJhbnNwb3J0Lm5hbWV9YCkpeyByZXR1cm4gZmFsbGJhY2soXCJtZW1vcml6ZWRcIikgfVxuXG4gICAgdGhpcy5mYWxsYmFja1RpbWVyID0gc2V0VGltZW91dChmYWxsYmFjaywgZmFsbGJhY2tUaHJlc2hvbGQpXG5cbiAgICBlcnJvclJlZiA9IHRoaXMub25FcnJvcihyZWFzb24gPT4ge1xuICAgICAgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJlcnJvclwiLCByZWFzb24pXG4gICAgICBpZihwcmltYXJ5VHJhbnNwb3J0ICYmICFlc3RhYmxpc2hlZCl7XG4gICAgICAgIGNsZWFyVGltZW91dCh0aGlzLmZhbGxiYWNrVGltZXIpXG4gICAgICAgIGZhbGxiYWNrKHJlYXNvbilcbiAgICAgIH1cbiAgICB9KVxuICAgIHRoaXMub25PcGVuKCgpID0+IHtcbiAgICAgIGVzdGFibGlzaGVkID0gdHJ1ZVxuICAgICAgaWYoIXByaW1hcnlUcmFuc3BvcnQpe1xuICAgICAgICAvLyBvbmx5IG1lbW9yaXplIExQIGlmIHdlIG5ldmVyIGNvbm5lY3RlZCB0byBwcmltYXJ5XG4gICAgICAgIGlmKCF0aGlzLnByaW1hcnlQYXNzZWRIZWFsdGhDaGVjayl7IHRoaXMuc3RvcmVTZXNzaW9uKGBwaHg6ZmFsbGJhY2s6JHtmYWxsYmFja1RyYW5zcG9ydC5uYW1lfWAsIFwidHJ1ZVwiKSB9XG4gICAgICAgIHJldHVybiB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBgZXN0YWJsaXNoZWQgJHtmYWxsYmFja1RyYW5zcG9ydC5uYW1lfSBmYWxsYmFja2ApXG4gICAgICB9XG4gICAgICAvLyBpZiB3ZSd2ZSBlc3RhYmxpc2hlZCBwcmltYXJ5LCBnaXZlIHRoZSBmYWxsYmFjayBhIG5ldyBwZXJpb2QgdG8gYXR0ZW1wdCBwaW5nXG4gICAgICBjbGVhclRpbWVvdXQodGhpcy5mYWxsYmFja1RpbWVyKVxuICAgICAgdGhpcy5mYWxsYmFja1RpbWVyID0gc2V0VGltZW91dChmYWxsYmFjaywgZmFsbGJhY2tUaHJlc2hvbGQpXG4gICAgICB0aGlzLnBpbmcocnR0ID0+IHtcbiAgICAgICAgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJjb25uZWN0ZWQgdG8gcHJpbWFyeSBhZnRlclwiLCBydHQpXG4gICAgICAgIHRoaXMucHJpbWFyeVBhc3NlZEhlYWx0aENoZWNrID0gdHJ1ZVxuICAgICAgICBjbGVhclRpbWVvdXQodGhpcy5mYWxsYmFja1RpbWVyKVxuICAgICAgfSlcbiAgICB9KVxuICAgIHRoaXMudHJhbnNwb3J0Q29ubmVjdCgpXG4gIH1cblxuICBjbGVhckhlYXJ0YmVhdHMoKXtcbiAgICBjbGVhclRpbWVvdXQodGhpcy5oZWFydGJlYXRUaW1lcilcbiAgICBjbGVhclRpbWVvdXQodGhpcy5oZWFydGJlYXRUaW1lb3V0VGltZXIpXG4gIH1cblxuICBvbkNvbm5PcGVuKCl7XG4gICAgaWYodGhpcy5oYXNMb2dnZXIoKSkgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgYCR7dGhpcy50cmFuc3BvcnQubmFtZX0gY29ubmVjdGVkIHRvICR7dGhpcy5lbmRQb2ludFVSTCgpfWApXG4gICAgdGhpcy5jbG9zZVdhc0NsZWFuID0gZmFsc2VcbiAgICB0aGlzLmRpc2Nvbm5lY3RpbmcgPSBmYWxzZVxuICAgIHRoaXMuZXN0YWJsaXNoZWRDb25uZWN0aW9ucysrXG4gICAgdGhpcy5mbHVzaFNlbmRCdWZmZXIoKVxuICAgIHRoaXMucmVjb25uZWN0VGltZXIucmVzZXQoKVxuICAgIHRoaXMucmVzZXRIZWFydGJlYXQoKVxuICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3Mub3Blbi5mb3JFYWNoKChbLCBjYWxsYmFja10pID0+IGNhbGxiYWNrKCkpXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG5cbiAgaGVhcnRiZWF0VGltZW91dCgpe1xuICAgIGlmKHRoaXMucGVuZGluZ0hlYXJ0YmVhdFJlZil7XG4gICAgICB0aGlzLnBlbmRpbmdIZWFydGJlYXRSZWYgPSBudWxsXG4gICAgICBpZih0aGlzLmhhc0xvZ2dlcigpKXsgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJoZWFydGJlYXQgdGltZW91dC4gQXR0ZW1wdGluZyB0byByZS1lc3RhYmxpc2ggY29ubmVjdGlvblwiKSB9XG4gICAgICB0aGlzLnRyaWdnZXJDaGFuRXJyb3IoKVxuICAgICAgdGhpcy5jbG9zZVdhc0NsZWFuID0gZmFsc2VcbiAgICAgIHRoaXMudGVhcmRvd24oKCkgPT4gdGhpcy5yZWNvbm5lY3RUaW1lci5zY2hlZHVsZVRpbWVvdXQoKSwgV1NfQ0xPU0VfTk9STUFMLCBcImhlYXJ0YmVhdCB0aW1lb3V0XCIpXG4gICAgfVxuICB9XG5cbiAgcmVzZXRIZWFydGJlYXQoKXtcbiAgICBpZih0aGlzLmNvbm4gJiYgdGhpcy5jb25uLnNraXBIZWFydGJlYXQpeyByZXR1cm4gfVxuICAgIHRoaXMucGVuZGluZ0hlYXJ0YmVhdFJlZiA9IG51bGxcbiAgICB0aGlzLmNsZWFySGVhcnRiZWF0cygpXG4gICAgdGhpcy5oZWFydGJlYXRUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gdGhpcy5zZW5kSGVhcnRiZWF0KCksIHRoaXMuaGVhcnRiZWF0SW50ZXJ2YWxNcylcbiAgfVxuXG4gIHRlYXJkb3duKGNhbGxiYWNrLCBjb2RlLCByZWFzb24pe1xuICAgIGlmKCF0aGlzLmNvbm4pe1xuICAgICAgcmV0dXJuIGNhbGxiYWNrICYmIGNhbGxiYWNrKClcbiAgICB9XG4gICAgbGV0IGNvbm5lY3RDbG9jayA9IHRoaXMuY29ubmVjdENsb2NrXG5cbiAgICB0aGlzLndhaXRGb3JCdWZmZXJEb25lKCgpID0+IHtcbiAgICAgIGlmKGNvbm5lY3RDbG9jayAhPT0gdGhpcy5jb25uZWN0Q2xvY2speyByZXR1cm4gfVxuICAgICAgaWYodGhpcy5jb25uKXtcbiAgICAgICAgaWYoY29kZSl7IHRoaXMuY29ubi5jbG9zZShjb2RlLCByZWFzb24gfHwgXCJcIikgfSBlbHNlIHsgdGhpcy5jb25uLmNsb3NlKCkgfVxuICAgICAgfVxuXG4gICAgICB0aGlzLndhaXRGb3JTb2NrZXRDbG9zZWQoKCkgPT4ge1xuICAgICAgICBpZihjb25uZWN0Q2xvY2sgIT09IHRoaXMuY29ubmVjdENsb2NrKXsgcmV0dXJuIH1cbiAgICAgICAgaWYodGhpcy5jb25uKXtcbiAgICAgICAgICB0aGlzLmNvbm4ub25vcGVuID0gZnVuY3Rpb24gKCl7IH0gLy8gbm9vcFxuICAgICAgICAgIHRoaXMuY29ubi5vbmVycm9yID0gZnVuY3Rpb24gKCl7IH0gLy8gbm9vcFxuICAgICAgICAgIHRoaXMuY29ubi5vbm1lc3NhZ2UgPSBmdW5jdGlvbiAoKXsgfSAvLyBub29wXG4gICAgICAgICAgdGhpcy5jb25uLm9uY2xvc2UgPSBmdW5jdGlvbiAoKXsgfSAvLyBub29wXG4gICAgICAgICAgdGhpcy5jb25uID0gbnVsbFxuICAgICAgICB9XG5cbiAgICAgICAgY2FsbGJhY2sgJiYgY2FsbGJhY2soKVxuICAgICAgfSlcbiAgICB9KVxuICB9XG5cbiAgd2FpdEZvckJ1ZmZlckRvbmUoY2FsbGJhY2ssIHRyaWVzID0gMSl7XG4gICAgaWYodHJpZXMgPT09IDUgfHwgIXRoaXMuY29ubiB8fCAhdGhpcy5jb25uLmJ1ZmZlcmVkQW1vdW50KXtcbiAgICAgIGNhbGxiYWNrKClcbiAgICAgIHJldHVyblxuICAgIH1cblxuICAgIHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgdGhpcy53YWl0Rm9yQnVmZmVyRG9uZShjYWxsYmFjaywgdHJpZXMgKyAxKVxuICAgIH0sIDE1MCAqIHRyaWVzKVxuICB9XG5cbiAgd2FpdEZvclNvY2tldENsb3NlZChjYWxsYmFjaywgdHJpZXMgPSAxKXtcbiAgICBpZih0cmllcyA9PT0gNSB8fCAhdGhpcy5jb25uIHx8IHRoaXMuY29ubi5yZWFkeVN0YXRlID09PSBTT0NLRVRfU1RBVEVTLmNsb3NlZCl7XG4gICAgICBjYWxsYmFjaygpXG4gICAgICByZXR1cm5cbiAgICB9XG5cbiAgICBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgIHRoaXMud2FpdEZvclNvY2tldENsb3NlZChjYWxsYmFjaywgdHJpZXMgKyAxKVxuICAgIH0sIDE1MCAqIHRyaWVzKVxuICB9XG5cbiAgb25Db25uQ2xvc2UoZXZlbnQpe1xuICAgIGxldCBjbG9zZUNvZGUgPSBldmVudCAmJiBldmVudC5jb2RlXG4gICAgaWYodGhpcy5oYXNMb2dnZXIoKSkgdGhpcy5sb2coXCJ0cmFuc3BvcnRcIiwgXCJjbG9zZVwiLCBldmVudClcbiAgICB0aGlzLnRyaWdnZXJDaGFuRXJyb3IoKVxuICAgIHRoaXMuY2xlYXJIZWFydGJlYXRzKClcbiAgICBpZighdGhpcy5jbG9zZVdhc0NsZWFuICYmIGNsb3NlQ29kZSAhPT0gMTAwMCl7XG4gICAgICB0aGlzLnJlY29ubmVjdFRpbWVyLnNjaGVkdWxlVGltZW91dCgpXG4gICAgfVxuICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3MuY2xvc2UuZm9yRWFjaCgoWywgY2FsbGJhY2tdKSA9PiBjYWxsYmFjayhldmVudCkpXG4gIH1cblxuICAvKipcbiAgICogQHByaXZhdGVcbiAgICovXG4gIG9uQ29ubkVycm9yKGVycm9yKXtcbiAgICBpZih0aGlzLmhhc0xvZ2dlcigpKSB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBlcnJvcilcbiAgICBsZXQgdHJhbnNwb3J0QmVmb3JlID0gdGhpcy50cmFuc3BvcnRcbiAgICBsZXQgZXN0YWJsaXNoZWRCZWZvcmUgPSB0aGlzLmVzdGFibGlzaGVkQ29ubmVjdGlvbnNcbiAgICB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzLmVycm9yLmZvckVhY2goKFssIGNhbGxiYWNrXSkgPT4ge1xuICAgICAgY2FsbGJhY2soZXJyb3IsIHRyYW5zcG9ydEJlZm9yZSwgZXN0YWJsaXNoZWRCZWZvcmUpXG4gICAgfSlcbiAgICBpZih0cmFuc3BvcnRCZWZvcmUgPT09IHRoaXMudHJhbnNwb3J0IHx8IGVzdGFibGlzaGVkQmVmb3JlID4gMCl7XG4gICAgICB0aGlzLnRyaWdnZXJDaGFuRXJyb3IoKVxuICAgIH1cbiAgfVxuXG4gIC8qKlxuICAgKiBAcHJpdmF0ZVxuICAgKi9cbiAgdHJpZ2dlckNoYW5FcnJvcigpe1xuICAgIHRoaXMuY2hhbm5lbHMuZm9yRWFjaChjaGFubmVsID0+IHtcbiAgICAgIGlmKCEoY2hhbm5lbC5pc0Vycm9yZWQoKSB8fCBjaGFubmVsLmlzTGVhdmluZygpIHx8IGNoYW5uZWwuaXNDbG9zZWQoKSkpe1xuICAgICAgICBjaGFubmVsLnRyaWdnZXIoQ0hBTk5FTF9FVkVOVFMuZXJyb3IpXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIC8qKlxuICAgKiBAcmV0dXJucyB7c3RyaW5nfVxuICAgKi9cbiAgY29ubmVjdGlvblN0YXRlKCl7XG4gICAgc3dpdGNoKHRoaXMuY29ubiAmJiB0aGlzLmNvbm4ucmVhZHlTdGF0ZSl7XG4gICAgICBjYXNlIFNPQ0tFVF9TVEFURVMuY29ubmVjdGluZzogcmV0dXJuIFwiY29ubmVjdGluZ1wiXG4gICAgICBjYXNlIFNPQ0tFVF9TVEFURVMub3BlbjogcmV0dXJuIFwib3BlblwiXG4gICAgICBjYXNlIFNPQ0tFVF9TVEFURVMuY2xvc2luZzogcmV0dXJuIFwiY2xvc2luZ1wiXG4gICAgICBkZWZhdWx0OiByZXR1cm4gXCJjbG9zZWRcIlxuICAgIH1cbiAgfVxuXG4gIC8qKlxuICAgKiBAcmV0dXJucyB7Ym9vbGVhbn1cbiAgICovXG4gIGlzQ29ubmVjdGVkKCl7IHJldHVybiB0aGlzLmNvbm5lY3Rpb25TdGF0ZSgpID09PSBcIm9wZW5cIiB9XG5cbiAgLyoqXG4gICAqIEBwcml2YXRlXG4gICAqXG4gICAqIEBwYXJhbSB7Q2hhbm5lbH1cbiAgICovXG4gIHJlbW92ZShjaGFubmVsKXtcbiAgICB0aGlzLm9mZihjaGFubmVsLnN0YXRlQ2hhbmdlUmVmcylcbiAgICB0aGlzLmNoYW5uZWxzID0gdGhpcy5jaGFubmVscy5maWx0ZXIoYyA9PiBjICE9PSBjaGFubmVsKVxuICB9XG5cbiAgLyoqXG4gICAqIFJlbW92ZXMgYG9uT3BlbmAsIGBvbkNsb3NlYCwgYG9uRXJyb3IsYCBhbmQgYG9uTWVzc2FnZWAgcmVnaXN0cmF0aW9ucy5cbiAgICpcbiAgICogQHBhcmFtIHtyZWZzfSAtIGxpc3Qgb2YgcmVmcyByZXR1cm5lZCBieSBjYWxscyB0b1xuICAgKiAgICAgICAgICAgICAgICAgYG9uT3BlbmAsIGBvbkNsb3NlYCwgYG9uRXJyb3IsYCBhbmQgYG9uTWVzc2FnZWBcbiAgICovXG4gIG9mZihyZWZzKXtcbiAgICBmb3IobGV0IGtleSBpbiB0aGlzLnN0YXRlQ2hhbmdlQ2FsbGJhY2tzKXtcbiAgICAgIHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3Nba2V5XSA9IHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3Nba2V5XS5maWx0ZXIoKFtyZWZdKSA9PiB7XG4gICAgICAgIHJldHVybiByZWZzLmluZGV4T2YocmVmKSA9PT0gLTFcbiAgICAgIH0pXG4gICAgfVxuICB9XG5cbiAgLyoqXG4gICAqIEluaXRpYXRlcyBhIG5ldyBjaGFubmVsIGZvciB0aGUgZ2l2ZW4gdG9waWNcbiAgICpcbiAgICogQHBhcmFtIHtzdHJpbmd9IHRvcGljXG4gICAqIEBwYXJhbSB7T2JqZWN0fSBjaGFuUGFyYW1zIC0gUGFyYW1ldGVycyBmb3IgdGhlIGNoYW5uZWxcbiAgICogQHJldHVybnMge0NoYW5uZWx9XG4gICAqL1xuICBjaGFubmVsKHRvcGljLCBjaGFuUGFyYW1zID0ge30pe1xuICAgIGxldCBjaGFuID0gbmV3IENoYW5uZWwodG9waWMsIGNoYW5QYXJhbXMsIHRoaXMpXG4gICAgdGhpcy5jaGFubmVscy5wdXNoKGNoYW4pXG4gICAgcmV0dXJuIGNoYW5cbiAgfVxuXG4gIC8qKlxuICAgKiBAcGFyYW0ge09iamVjdH0gZGF0YVxuICAgKi9cbiAgcHVzaChkYXRhKXtcbiAgICBpZih0aGlzLmhhc0xvZ2dlcigpKXtcbiAgICAgIGxldCB7dG9waWMsIGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5fcmVmfSA9IGRhdGFcbiAgICAgIHRoaXMubG9nKFwicHVzaFwiLCBgJHt0b3BpY30gJHtldmVudH0gKCR7am9pbl9yZWZ9LCAke3JlZn0pYCwgcGF5bG9hZClcbiAgICB9XG5cbiAgICBpZih0aGlzLmlzQ29ubmVjdGVkKCkpe1xuICAgICAgdGhpcy5lbmNvZGUoZGF0YSwgcmVzdWx0ID0+IHRoaXMuY29ubi5zZW5kKHJlc3VsdCkpXG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMuc2VuZEJ1ZmZlci5wdXNoKCgpID0+IHRoaXMuZW5jb2RlKGRhdGEsIHJlc3VsdCA9PiB0aGlzLmNvbm4uc2VuZChyZXN1bHQpKSlcbiAgICB9XG4gIH1cblxuICAvKipcbiAgICogUmV0dXJuIHRoZSBuZXh0IG1lc3NhZ2UgcmVmLCBhY2NvdW50aW5nIGZvciBvdmVyZmxvd3NcbiAgICogQHJldHVybnMge3N0cmluZ31cbiAgICovXG4gIG1ha2VSZWYoKXtcbiAgICBsZXQgbmV3UmVmID0gdGhpcy5yZWYgKyAxXG4gICAgaWYobmV3UmVmID09PSB0aGlzLnJlZil7IHRoaXMucmVmID0gMCB9IGVsc2UgeyB0aGlzLnJlZiA9IG5ld1JlZiB9XG5cbiAgICByZXR1cm4gdGhpcy5yZWYudG9TdHJpbmcoKVxuICB9XG5cbiAgc2VuZEhlYXJ0YmVhdCgpe1xuICAgIGlmKHRoaXMucGVuZGluZ0hlYXJ0YmVhdFJlZiAmJiAhdGhpcy5pc0Nvbm5lY3RlZCgpKXsgcmV0dXJuIH1cbiAgICB0aGlzLnBlbmRpbmdIZWFydGJlYXRSZWYgPSB0aGlzLm1ha2VSZWYoKVxuICAgIHRoaXMucHVzaCh7dG9waWM6IFwicGhvZW5peFwiLCBldmVudDogXCJoZWFydGJlYXRcIiwgcGF5bG9hZDoge30sIHJlZjogdGhpcy5wZW5kaW5nSGVhcnRiZWF0UmVmfSlcbiAgICB0aGlzLmhlYXJ0YmVhdFRpbWVvdXRUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gdGhpcy5oZWFydGJlYXRUaW1lb3V0KCksIHRoaXMuaGVhcnRiZWF0SW50ZXJ2YWxNcylcbiAgfVxuXG4gIGZsdXNoU2VuZEJ1ZmZlcigpe1xuICAgIGlmKHRoaXMuaXNDb25uZWN0ZWQoKSAmJiB0aGlzLnNlbmRCdWZmZXIubGVuZ3RoID4gMCl7XG4gICAgICB0aGlzLnNlbmRCdWZmZXIuZm9yRWFjaChjYWxsYmFjayA9PiBjYWxsYmFjaygpKVxuICAgICAgdGhpcy5zZW5kQnVmZmVyID0gW11cbiAgICB9XG4gIH1cblxuICBvbkNvbm5NZXNzYWdlKHJhd01lc3NhZ2Upe1xuICAgIHRoaXMuZGVjb2RlKHJhd01lc3NhZ2UuZGF0YSwgbXNnID0+IHtcbiAgICAgIGxldCB7dG9waWMsIGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5fcmVmfSA9IG1zZ1xuICAgICAgaWYocmVmICYmIHJlZiA9PT0gdGhpcy5wZW5kaW5nSGVhcnRiZWF0UmVmKXtcbiAgICAgICAgdGhpcy5jbGVhckhlYXJ0YmVhdHMoKVxuICAgICAgICB0aGlzLnBlbmRpbmdIZWFydGJlYXRSZWYgPSBudWxsXG4gICAgICAgIHRoaXMuaGVhcnRiZWF0VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHRoaXMuc2VuZEhlYXJ0YmVhdCgpLCB0aGlzLmhlYXJ0YmVhdEludGVydmFsTXMpXG4gICAgICB9XG5cbiAgICAgIGlmKHRoaXMuaGFzTG9nZ2VyKCkpIHRoaXMubG9nKFwicmVjZWl2ZVwiLCBgJHtwYXlsb2FkLnN0YXR1cyB8fCBcIlwifSAke3RvcGljfSAke2V2ZW50fSAke3JlZiAmJiBcIihcIiArIHJlZiArIFwiKVwiIHx8IFwiXCJ9YCwgcGF5bG9hZClcblxuICAgICAgZm9yKGxldCBpID0gMDsgaSA8IHRoaXMuY2hhbm5lbHMubGVuZ3RoOyBpKyspe1xuICAgICAgICBjb25zdCBjaGFubmVsID0gdGhpcy5jaGFubmVsc1tpXVxuICAgICAgICBpZighY2hhbm5lbC5pc01lbWJlcih0b3BpYywgZXZlbnQsIHBheWxvYWQsIGpvaW5fcmVmKSl7IGNvbnRpbnVlIH1cbiAgICAgICAgY2hhbm5lbC50cmlnZ2VyKGV2ZW50LCBwYXlsb2FkLCByZWYsIGpvaW5fcmVmKVxuICAgICAgfVxuXG4gICAgICBmb3IobGV0IGkgPSAwOyBpIDwgdGhpcy5zdGF0ZUNoYW5nZUNhbGxiYWNrcy5tZXNzYWdlLmxlbmd0aDsgaSsrKXtcbiAgICAgICAgbGV0IFssIGNhbGxiYWNrXSA9IHRoaXMuc3RhdGVDaGFuZ2VDYWxsYmFja3MubWVzc2FnZVtpXVxuICAgICAgICBjYWxsYmFjayhtc2cpXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIGxlYXZlT3BlblRvcGljKHRvcGljKXtcbiAgICBsZXQgZHVwQ2hhbm5lbCA9IHRoaXMuY2hhbm5lbHMuZmluZChjID0+IGMudG9waWMgPT09IHRvcGljICYmIChjLmlzSm9pbmVkKCkgfHwgYy5pc0pvaW5pbmcoKSkpXG4gICAgaWYoZHVwQ2hhbm5lbCl7XG4gICAgICBpZih0aGlzLmhhc0xvZ2dlcigpKSB0aGlzLmxvZyhcInRyYW5zcG9ydFwiLCBgbGVhdmluZyBkdXBsaWNhdGUgdG9waWMgXCIke3RvcGljfVwiYClcbiAgICAgIGR1cENoYW5uZWwubGVhdmUoKVxuICAgIH1cbiAgfVxufVxuIiwgImV4cG9ydCBjb25zdCBDT05TRUNVVElWRV9SRUxPQURTID0gXCJjb25zZWN1dGl2ZS1yZWxvYWRzXCJcbmV4cG9ydCBjb25zdCBNQVhfUkVMT0FEUyA9IDEwXG5leHBvcnQgY29uc3QgUkVMT0FEX0pJVFRFUl9NSU4gPSA1MDAwXG5leHBvcnQgY29uc3QgUkVMT0FEX0pJVFRFUl9NQVggPSAxMDAwMFxuZXhwb3J0IGNvbnN0IEZBSUxTQUZFX0pJVFRFUiA9IDMwMDAwXG5leHBvcnQgY29uc3QgUEhYX0VWRU5UX0NMQVNTRVMgPSBbXG4gIFwicGh4LWNsaWNrLWxvYWRpbmdcIiwgXCJwaHgtY2hhbmdlLWxvYWRpbmdcIiwgXCJwaHgtc3VibWl0LWxvYWRpbmdcIixcbiAgXCJwaHgta2V5ZG93bi1sb2FkaW5nXCIsIFwicGh4LWtleXVwLWxvYWRpbmdcIiwgXCJwaHgtYmx1ci1sb2FkaW5nXCIsIFwicGh4LWZvY3VzLWxvYWRpbmdcIixcbiAgXCJwaHgtaG9vay1sb2FkaW5nXCJcbl1cbmV4cG9ydCBjb25zdCBQSFhfQ09NUE9ORU5UID0gXCJkYXRhLXBoeC1jb21wb25lbnRcIlxuZXhwb3J0IGNvbnN0IFBIWF9MSVZFX0xJTksgPSBcImRhdGEtcGh4LWxpbmtcIlxuZXhwb3J0IGNvbnN0IFBIWF9UUkFDS19TVEFUSUMgPSBcInRyYWNrLXN0YXRpY1wiXG5leHBvcnQgY29uc3QgUEhYX0xJTktfU1RBVEUgPSBcImRhdGEtcGh4LWxpbmstc3RhdGVcIlxuZXhwb3J0IGNvbnN0IFBIWF9SRUYgPSBcImRhdGEtcGh4LXJlZlwiXG5leHBvcnQgY29uc3QgUEhYX1JFRl9TUkMgPSBcImRhdGEtcGh4LXJlZi1zcmNcIlxuZXhwb3J0IGNvbnN0IFBIWF9UUkFDS19VUExPQURTID0gXCJ0cmFjay11cGxvYWRzXCJcbmV4cG9ydCBjb25zdCBQSFhfVVBMT0FEX1JFRiA9IFwiZGF0YS1waHgtdXBsb2FkLXJlZlwiXG5leHBvcnQgY29uc3QgUEhYX1BSRUZMSUdIVEVEX1JFRlMgPSBcImRhdGEtcGh4LXByZWZsaWdodGVkLXJlZnNcIlxuZXhwb3J0IGNvbnN0IFBIWF9ET05FX1JFRlMgPSBcImRhdGEtcGh4LWRvbmUtcmVmc1wiXG5leHBvcnQgY29uc3QgUEhYX0RST1BfVEFSR0VUID0gXCJkcm9wLXRhcmdldFwiXG5leHBvcnQgY29uc3QgUEhYX0FDVElWRV9FTlRSWV9SRUZTID0gXCJkYXRhLXBoeC1hY3RpdmUtcmVmc1wiXG5leHBvcnQgY29uc3QgUEhYX0xJVkVfRklMRV9VUERBVEVEID0gXCJwaHg6bGl2ZS1maWxlOnVwZGF0ZWRcIlxuZXhwb3J0IGNvbnN0IFBIWF9TS0lQID0gXCJkYXRhLXBoeC1za2lwXCJcbmV4cG9ydCBjb25zdCBQSFhfTUFHSUNfSUQgPSBcImRhdGEtcGh4LWlkXCJcbmV4cG9ydCBjb25zdCBQSFhfUFJVTkUgPSBcImRhdGEtcGh4LXBydW5lXCJcbmV4cG9ydCBjb25zdCBQSFhfUEFHRV9MT0FESU5HID0gXCJwYWdlLWxvYWRpbmdcIlxuZXhwb3J0IGNvbnN0IFBIWF9DT05ORUNURURfQ0xBU1MgPSBcInBoeC1jb25uZWN0ZWRcIlxuZXhwb3J0IGNvbnN0IFBIWF9MT0FESU5HX0NMQVNTID0gXCJwaHgtbG9hZGluZ1wiXG5leHBvcnQgY29uc3QgUEhYX05PX0ZFRURCQUNLX0NMQVNTID0gXCJwaHgtbm8tZmVlZGJhY2tcIlxuZXhwb3J0IGNvbnN0IFBIWF9FUlJPUl9DTEFTUyA9IFwicGh4LWVycm9yXCJcbmV4cG9ydCBjb25zdCBQSFhfQ0xJRU5UX0VSUk9SX0NMQVNTID0gXCJwaHgtY2xpZW50LWVycm9yXCJcbmV4cG9ydCBjb25zdCBQSFhfU0VSVkVSX0VSUk9SX0NMQVNTID0gXCJwaHgtc2VydmVyLWVycm9yXCJcbmV4cG9ydCBjb25zdCBQSFhfUEFSRU5UX0lEID0gXCJkYXRhLXBoeC1wYXJlbnQtaWRcIlxuZXhwb3J0IGNvbnN0IFBIWF9NQUlOID0gXCJkYXRhLXBoeC1tYWluXCJcbmV4cG9ydCBjb25zdCBQSFhfUk9PVF9JRCA9IFwiZGF0YS1waHgtcm9vdC1pZFwiXG5leHBvcnQgY29uc3QgUEhYX1ZJRVdQT1JUX1RPUCA9IFwidmlld3BvcnQtdG9wXCJcbmV4cG9ydCBjb25zdCBQSFhfVklFV1BPUlRfQk9UVE9NID0gXCJ2aWV3cG9ydC1ib3R0b21cIlxuZXhwb3J0IGNvbnN0IFBIWF9UUklHR0VSX0FDVElPTiA9IFwidHJpZ2dlci1hY3Rpb25cIlxuZXhwb3J0IGNvbnN0IFBIWF9GRUVEQkFDS19GT1IgPSBcImZlZWRiYWNrLWZvclwiXG5leHBvcnQgY29uc3QgUEhYX0ZFRURCQUNLX0dST1VQID0gXCJmZWVkYmFjay1ncm91cFwiXG5leHBvcnQgY29uc3QgUEhYX0hBU19GT0NVU0VEID0gXCJwaHgtaGFzLWZvY3VzZWRcIlxuZXhwb3J0IGNvbnN0IEZPQ1VTQUJMRV9JTlBVVFMgPSBbXCJ0ZXh0XCIsIFwidGV4dGFyZWFcIiwgXCJudW1iZXJcIiwgXCJlbWFpbFwiLCBcInBhc3N3b3JkXCIsIFwic2VhcmNoXCIsIFwidGVsXCIsIFwidXJsXCIsIFwiZGF0ZVwiLCBcInRpbWVcIiwgXCJkYXRldGltZS1sb2NhbFwiLCBcImNvbG9yXCIsIFwicmFuZ2VcIl1cbmV4cG9ydCBjb25zdCBDSEVDS0FCTEVfSU5QVVRTID0gW1wiY2hlY2tib3hcIiwgXCJyYWRpb1wiXVxuZXhwb3J0IGNvbnN0IFBIWF9IQVNfU1VCTUlUVEVEID0gXCJwaHgtaGFzLXN1Ym1pdHRlZFwiXG5leHBvcnQgY29uc3QgUEhYX1NFU1NJT04gPSBcImRhdGEtcGh4LXNlc3Npb25cIlxuZXhwb3J0IGNvbnN0IFBIWF9WSUVXX1NFTEVDVE9SID0gYFske1BIWF9TRVNTSU9OfV1gXG5leHBvcnQgY29uc3QgUEhYX1NUSUNLWSA9IFwiZGF0YS1waHgtc3RpY2t5XCJcbmV4cG9ydCBjb25zdCBQSFhfU1RBVElDID0gXCJkYXRhLXBoeC1zdGF0aWNcIlxuZXhwb3J0IGNvbnN0IFBIWF9SRUFET05MWSA9IFwiZGF0YS1waHgtcmVhZG9ubHlcIlxuZXhwb3J0IGNvbnN0IFBIWF9ESVNBQkxFRCA9IFwiZGF0YS1waHgtZGlzYWJsZWRcIlxuZXhwb3J0IGNvbnN0IFBIWF9ESVNBQkxFX1dJVEggPSBcImRpc2FibGUtd2l0aFwiXG5leHBvcnQgY29uc3QgUEhYX0RJU0FCTEVfV0lUSF9SRVNUT1JFID0gXCJkYXRhLXBoeC1kaXNhYmxlLXdpdGgtcmVzdG9yZVwiXG5leHBvcnQgY29uc3QgUEhYX0hPT0sgPSBcImhvb2tcIlxuZXhwb3J0IGNvbnN0IFBIWF9ERUJPVU5DRSA9IFwiZGVib3VuY2VcIlxuZXhwb3J0IGNvbnN0IFBIWF9USFJPVFRMRSA9IFwidGhyb3R0bGVcIlxuZXhwb3J0IGNvbnN0IFBIWF9VUERBVEUgPSBcInVwZGF0ZVwiXG5leHBvcnQgY29uc3QgUEhYX1NUUkVBTSA9IFwic3RyZWFtXCJcbmV4cG9ydCBjb25zdCBQSFhfU1RSRUFNX1JFRiA9IFwiZGF0YS1waHgtc3RyZWFtXCJcbmV4cG9ydCBjb25zdCBQSFhfS0VZID0gXCJrZXlcIlxuZXhwb3J0IGNvbnN0IFBIWF9QUklWQVRFID0gXCJwaHhQcml2YXRlXCJcbmV4cG9ydCBjb25zdCBQSFhfQVVUT19SRUNPVkVSID0gXCJhdXRvLXJlY292ZXJcIlxuZXhwb3J0IGNvbnN0IFBIWF9MVl9ERUJVRyA9IFwicGh4OmxpdmUtc29ja2V0OmRlYnVnXCJcbmV4cG9ydCBjb25zdCBQSFhfTFZfUFJPRklMRSA9IFwicGh4OmxpdmUtc29ja2V0OnByb2ZpbGluZ1wiXG5leHBvcnQgY29uc3QgUEhYX0xWX0xBVEVOQ1lfU0lNID0gXCJwaHg6bGl2ZS1zb2NrZXQ6bGF0ZW5jeS1zaW1cIlxuZXhwb3J0IGNvbnN0IFBIWF9QUk9HUkVTUyA9IFwicHJvZ3Jlc3NcIlxuZXhwb3J0IGNvbnN0IFBIWF9NT1VOVEVEID0gXCJtb3VudGVkXCJcbmV4cG9ydCBjb25zdCBMT0FERVJfVElNRU9VVCA9IDFcbmV4cG9ydCBjb25zdCBCRUZPUkVfVU5MT0FEX0xPQURFUl9USU1FT1VUID0gMjAwXG5leHBvcnQgY29uc3QgQklORElOR19QUkVGSVggPSBcInBoeC1cIlxuZXhwb3J0IGNvbnN0IFBVU0hfVElNRU9VVCA9IDMwMDAwXG5leHBvcnQgY29uc3QgTElOS19IRUFERVIgPSBcIngtcmVxdWVzdGVkLXdpdGhcIlxuZXhwb3J0IGNvbnN0IFJFU1BPTlNFX1VSTF9IRUFERVIgPSBcIngtcmVzcG9uc2UtdXJsXCJcbmV4cG9ydCBjb25zdCBERUJPVU5DRV9UUklHR0VSID0gXCJkZWJvdW5jZS10cmlnZ2VyXCJcbmV4cG9ydCBjb25zdCBUSFJPVFRMRUQgPSBcInRocm90dGxlZFwiXG5leHBvcnQgY29uc3QgREVCT1VOQ0VfUFJFVl9LRVkgPSBcImRlYm91bmNlLXByZXYta2V5XCJcbmV4cG9ydCBjb25zdCBERUZBVUxUUyA9IHtcbiAgZGVib3VuY2U6IDMwMCxcbiAgdGhyb3R0bGU6IDMwMFxufVxuXG4vLyBSZW5kZXJlZFxuZXhwb3J0IGNvbnN0IERZTkFNSUNTID0gXCJkXCJcbmV4cG9ydCBjb25zdCBTVEFUSUMgPSBcInNcIlxuZXhwb3J0IGNvbnN0IFJPT1QgPSBcInJcIlxuZXhwb3J0IGNvbnN0IENPTVBPTkVOVFMgPSBcImNcIlxuZXhwb3J0IGNvbnN0IEVWRU5UUyA9IFwiZVwiXG5leHBvcnQgY29uc3QgUkVQTFkgPSBcInJcIlxuZXhwb3J0IGNvbnN0IFRJVExFID0gXCJ0XCJcbmV4cG9ydCBjb25zdCBURU1QTEFURVMgPSBcInBcIlxuZXhwb3J0IGNvbnN0IFNUUkVBTSA9IFwic3RyZWFtXCIiLCAiaW1wb3J0IHtcbiAgbG9nRXJyb3Jcbn0gZnJvbSBcIi4vdXRpbHNcIlxuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBFbnRyeVVwbG9hZGVyIHtcbiAgY29uc3RydWN0b3IoZW50cnksIGNodW5rU2l6ZSwgbGl2ZVNvY2tldCl7XG4gICAgdGhpcy5saXZlU29ja2V0ID0gbGl2ZVNvY2tldFxuICAgIHRoaXMuZW50cnkgPSBlbnRyeVxuICAgIHRoaXMub2Zmc2V0ID0gMFxuICAgIHRoaXMuY2h1bmtTaXplID0gY2h1bmtTaXplXG4gICAgdGhpcy5jaHVua1RpbWVyID0gbnVsbFxuICAgIHRoaXMuZXJyb3JlZCA9IGZhbHNlXG4gICAgdGhpcy51cGxvYWRDaGFubmVsID0gbGl2ZVNvY2tldC5jaGFubmVsKGBsdnU6JHtlbnRyeS5yZWZ9YCwge3Rva2VuOiBlbnRyeS5tZXRhZGF0YSgpfSlcbiAgfVxuXG4gIGVycm9yKHJlYXNvbil7XG4gICAgaWYodGhpcy5lcnJvcmVkKXsgcmV0dXJuIH1cbiAgICB0aGlzLnVwbG9hZENoYW5uZWwubGVhdmUoKVxuICAgIHRoaXMuZXJyb3JlZCA9IHRydWVcbiAgICBjbGVhclRpbWVvdXQodGhpcy5jaHVua1RpbWVyKVxuICAgIHRoaXMuZW50cnkuZXJyb3IocmVhc29uKVxuICB9XG5cbiAgdXBsb2FkKCl7XG4gICAgdGhpcy51cGxvYWRDaGFubmVsLm9uRXJyb3IocmVhc29uID0+IHRoaXMuZXJyb3IocmVhc29uKSlcbiAgICB0aGlzLnVwbG9hZENoYW5uZWwuam9pbigpXG4gICAgICAucmVjZWl2ZShcIm9rXCIsIF9kYXRhID0+IHRoaXMucmVhZE5leHRDaHVuaygpKVxuICAgICAgLnJlY2VpdmUoXCJlcnJvclwiLCByZWFzb24gPT4gdGhpcy5lcnJvcihyZWFzb24pKVxuICB9XG5cbiAgaXNEb25lKCl7IHJldHVybiB0aGlzLm9mZnNldCA+PSB0aGlzLmVudHJ5LmZpbGUuc2l6ZSB9XG5cbiAgcmVhZE5leHRDaHVuaygpe1xuICAgIGxldCByZWFkZXIgPSBuZXcgd2luZG93LkZpbGVSZWFkZXIoKVxuICAgIGxldCBibG9iID0gdGhpcy5lbnRyeS5maWxlLnNsaWNlKHRoaXMub2Zmc2V0LCB0aGlzLmNodW5rU2l6ZSArIHRoaXMub2Zmc2V0KVxuICAgIHJlYWRlci5vbmxvYWQgPSAoZSkgPT4ge1xuICAgICAgaWYoZS50YXJnZXQuZXJyb3IgPT09IG51bGwpe1xuICAgICAgICB0aGlzLm9mZnNldCArPSBlLnRhcmdldC5yZXN1bHQuYnl0ZUxlbmd0aFxuICAgICAgICB0aGlzLnB1c2hDaHVuayhlLnRhcmdldC5yZXN1bHQpXG4gICAgICB9IGVsc2Uge1xuICAgICAgICByZXR1cm4gbG9nRXJyb3IoXCJSZWFkIGVycm9yOiBcIiArIGUudGFyZ2V0LmVycm9yKVxuICAgICAgfVxuICAgIH1cbiAgICByZWFkZXIucmVhZEFzQXJyYXlCdWZmZXIoYmxvYilcbiAgfVxuXG4gIHB1c2hDaHVuayhjaHVuayl7XG4gICAgaWYoIXRoaXMudXBsb2FkQ2hhbm5lbC5pc0pvaW5lZCgpKXsgcmV0dXJuIH1cbiAgICB0aGlzLnVwbG9hZENoYW5uZWwucHVzaChcImNodW5rXCIsIGNodW5rKVxuICAgICAgLnJlY2VpdmUoXCJva1wiLCAoKSA9PiB7XG4gICAgICAgIHRoaXMuZW50cnkucHJvZ3Jlc3MoKHRoaXMub2Zmc2V0IC8gdGhpcy5lbnRyeS5maWxlLnNpemUpICogMTAwKVxuICAgICAgICBpZighdGhpcy5pc0RvbmUoKSl7XG4gICAgICAgICAgdGhpcy5jaHVua1RpbWVyID0gc2V0VGltZW91dCgoKSA9PiB0aGlzLnJlYWROZXh0Q2h1bmsoKSwgdGhpcy5saXZlU29ja2V0LmdldExhdGVuY3lTaW0oKSB8fCAwKVxuICAgICAgICB9XG4gICAgICB9KVxuICAgICAgLnJlY2VpdmUoXCJlcnJvclwiLCAoe3JlYXNvbn0pID0+IHRoaXMuZXJyb3IocmVhc29uKSlcbiAgfVxufVxuIiwgImltcG9ydCB7XG4gIFBIWF9WSUVXX1NFTEVDVE9SXG59IGZyb20gXCIuL2NvbnN0YW50c1wiXG5cbmltcG9ydCBFbnRyeVVwbG9hZGVyIGZyb20gXCIuL2VudHJ5X3VwbG9hZGVyXCJcblxuZXhwb3J0IGxldCBsb2dFcnJvciA9IChtc2csIG9iaikgPT4gY29uc29sZS5lcnJvciAmJiBjb25zb2xlLmVycm9yKG1zZywgb2JqKVxuXG5leHBvcnQgbGV0IGlzQ2lkID0gKGNpZCkgPT4ge1xuICBsZXQgdHlwZSA9IHR5cGVvZihjaWQpXG4gIHJldHVybiB0eXBlID09PSBcIm51bWJlclwiIHx8ICh0eXBlID09PSBcInN0cmluZ1wiICYmIC9eKDB8WzEtOV1cXGQqKSQvLnRlc3QoY2lkKSlcbn1cblxuZXhwb3J0IGZ1bmN0aW9uIGRldGVjdER1cGxpY2F0ZUlkcygpe1xuICBsZXQgaWRzID0gbmV3IFNldCgpXG4gIGxldCBlbGVtcyA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoXCIqW2lkXVwiKVxuICBmb3IobGV0IGkgPSAwLCBsZW4gPSBlbGVtcy5sZW5ndGg7IGkgPCBsZW47IGkrKyl7XG4gICAgaWYoaWRzLmhhcyhlbGVtc1tpXS5pZCkpe1xuICAgICAgY29uc29sZS5lcnJvcihgTXVsdGlwbGUgSURzIGRldGVjdGVkOiAke2VsZW1zW2ldLmlkfS4gRW5zdXJlIHVuaXF1ZSBlbGVtZW50IGlkcy5gKVxuICAgIH0gZWxzZSB7XG4gICAgICBpZHMuYWRkKGVsZW1zW2ldLmlkKVxuICAgIH1cbiAgfVxufVxuXG5leHBvcnQgbGV0IGRlYnVnID0gKHZpZXcsIGtpbmQsIG1zZywgb2JqKSA9PiB7XG4gIGlmKHZpZXcubGl2ZVNvY2tldC5pc0RlYnVnRW5hYmxlZCgpKXtcbiAgICBjb25zb2xlLmxvZyhgJHt2aWV3LmlkfSAke2tpbmR9OiAke21zZ30gLSBgLCBvYmopXG4gIH1cbn1cblxuLy8gd3JhcHMgdmFsdWUgaW4gY2xvc3VyZSBvciByZXR1cm5zIGNsb3N1cmVcbmV4cG9ydCBsZXQgY2xvc3VyZSA9ICh2YWwpID0+IHR5cGVvZiB2YWwgPT09IFwiZnVuY3Rpb25cIiA/IHZhbCA6IGZ1bmN0aW9uICgpeyByZXR1cm4gdmFsIH1cblxuZXhwb3J0IGxldCBjbG9uZSA9IChvYmopID0+IHsgcmV0dXJuIEpTT04ucGFyc2UoSlNPTi5zdHJpbmdpZnkob2JqKSkgfVxuXG5leHBvcnQgbGV0IGNsb3Nlc3RQaHhCaW5kaW5nID0gKGVsLCBiaW5kaW5nLCBib3JkZXJFbCkgPT4ge1xuICBkbyB7XG4gICAgaWYoZWwubWF0Y2hlcyhgWyR7YmluZGluZ31dYCkgJiYgIWVsLmRpc2FibGVkKXsgcmV0dXJuIGVsIH1cbiAgICBlbCA9IGVsLnBhcmVudEVsZW1lbnQgfHwgZWwucGFyZW50Tm9kZVxuICB9IHdoaWxlKGVsICE9PSBudWxsICYmIGVsLm5vZGVUeXBlID09PSAxICYmICEoKGJvcmRlckVsICYmIGJvcmRlckVsLmlzU2FtZU5vZGUoZWwpKSB8fCBlbC5tYXRjaGVzKFBIWF9WSUVXX1NFTEVDVE9SKSkpXG4gIHJldHVybiBudWxsXG59XG5cbmV4cG9ydCBsZXQgaXNPYmplY3QgPSAob2JqKSA9PiB7XG4gIHJldHVybiBvYmogIT09IG51bGwgJiYgdHlwZW9mIG9iaiA9PT0gXCJvYmplY3RcIiAmJiAhKG9iaiBpbnN0YW5jZW9mIEFycmF5KVxufVxuXG5leHBvcnQgbGV0IGlzRXF1YWxPYmogPSAob2JqMSwgb2JqMikgPT4gSlNPTi5zdHJpbmdpZnkob2JqMSkgPT09IEpTT04uc3RyaW5naWZ5KG9iajIpXG5cbmV4cG9ydCBsZXQgaXNFbXB0eSA9IChvYmopID0+IHtcbiAgZm9yKGxldCB4IGluIG9iail7IHJldHVybiBmYWxzZSB9XG4gIHJldHVybiB0cnVlXG59XG5cbmV4cG9ydCBsZXQgbWF5YmUgPSAoZWwsIGNhbGxiYWNrKSA9PiBlbCAmJiBjYWxsYmFjayhlbClcblxuZXhwb3J0IGxldCBjaGFubmVsVXBsb2FkZXIgPSBmdW5jdGlvbiAoZW50cmllcywgb25FcnJvciwgcmVzcCwgbGl2ZVNvY2tldCl7XG4gIGVudHJpZXMuZm9yRWFjaChlbnRyeSA9PiB7XG4gICAgbGV0IGVudHJ5VXBsb2FkZXIgPSBuZXcgRW50cnlVcGxvYWRlcihlbnRyeSwgcmVzcC5jb25maWcuY2h1bmtfc2l6ZSwgbGl2ZVNvY2tldClcbiAgICBlbnRyeVVwbG9hZGVyLnVwbG9hZCgpXG4gIH0pXG59XG4iLCAibGV0IEJyb3dzZXIgPSB7XG4gIGNhblB1c2hTdGF0ZSgpeyByZXR1cm4gKHR5cGVvZiAoaGlzdG9yeS5wdXNoU3RhdGUpICE9PSBcInVuZGVmaW5lZFwiKSB9LFxuXG4gIGRyb3BMb2NhbChsb2NhbFN0b3JhZ2UsIG5hbWVzcGFjZSwgc3Via2V5KXtcbiAgICByZXR1cm4gbG9jYWxTdG9yYWdlLnJlbW92ZUl0ZW0odGhpcy5sb2NhbEtleShuYW1lc3BhY2UsIHN1YmtleSkpXG4gIH0sXG5cbiAgdXBkYXRlTG9jYWwobG9jYWxTdG9yYWdlLCBuYW1lc3BhY2UsIHN1YmtleSwgaW5pdGlhbCwgZnVuYyl7XG4gICAgbGV0IGN1cnJlbnQgPSB0aGlzLmdldExvY2FsKGxvY2FsU3RvcmFnZSwgbmFtZXNwYWNlLCBzdWJrZXkpXG4gICAgbGV0IGtleSA9IHRoaXMubG9jYWxLZXkobmFtZXNwYWNlLCBzdWJrZXkpXG4gICAgbGV0IG5ld1ZhbCA9IGN1cnJlbnQgPT09IG51bGwgPyBpbml0aWFsIDogZnVuYyhjdXJyZW50KVxuICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKGtleSwgSlNPTi5zdHJpbmdpZnkobmV3VmFsKSlcbiAgICByZXR1cm4gbmV3VmFsXG4gIH0sXG5cbiAgZ2V0TG9jYWwobG9jYWxTdG9yYWdlLCBuYW1lc3BhY2UsIHN1YmtleSl7XG4gICAgcmV0dXJuIEpTT04ucGFyc2UobG9jYWxTdG9yYWdlLmdldEl0ZW0odGhpcy5sb2NhbEtleShuYW1lc3BhY2UsIHN1YmtleSkpKVxuICB9LFxuXG4gIHVwZGF0ZUN1cnJlbnRTdGF0ZShjYWxsYmFjayl7XG4gICAgaWYoIXRoaXMuY2FuUHVzaFN0YXRlKCkpeyByZXR1cm4gfVxuICAgIGhpc3RvcnkucmVwbGFjZVN0YXRlKGNhbGxiYWNrKGhpc3Rvcnkuc3RhdGUgfHwge30pLCBcIlwiLCB3aW5kb3cubG9jYXRpb24uaHJlZilcbiAgfSxcblxuICBwdXNoU3RhdGUoa2luZCwgbWV0YSwgdG8pe1xuICAgIGlmKHRoaXMuY2FuUHVzaFN0YXRlKCkpe1xuICAgICAgaWYodG8gIT09IHdpbmRvdy5sb2NhdGlvbi5ocmVmKXtcbiAgICAgICAgaWYobWV0YS50eXBlID09IFwicmVkaXJlY3RcIiAmJiBtZXRhLnNjcm9sbCl7XG4gICAgICAgICAgLy8gSWYgd2UncmUgcmVkaXJlY3Rpbmcgc3RvcmUgdGhlIGN1cnJlbnQgc2Nyb2xsWSBmb3IgdGhlIGN1cnJlbnQgaGlzdG9yeSBzdGF0ZS5cbiAgICAgICAgICBsZXQgY3VycmVudFN0YXRlID0gaGlzdG9yeS5zdGF0ZSB8fCB7fVxuICAgICAgICAgIGN1cnJlbnRTdGF0ZS5zY3JvbGwgPSBtZXRhLnNjcm9sbFxuICAgICAgICAgIGhpc3RvcnkucmVwbGFjZVN0YXRlKGN1cnJlbnRTdGF0ZSwgXCJcIiwgd2luZG93LmxvY2F0aW9uLmhyZWYpXG4gICAgICAgIH1cblxuICAgICAgICBkZWxldGUgbWV0YS5zY3JvbGwgLy8gT25seSBzdG9yZSB0aGUgc2Nyb2xsIGluIHRoZSByZWRpcmVjdCBjYXNlLlxuICAgICAgICBoaXN0b3J5W2tpbmQgKyBcIlN0YXRlXCJdKG1ldGEsIFwiXCIsIHRvIHx8IG51bGwpIC8vIElFIHdpbGwgY29lcmNlIHVuZGVmaW5lZCB0byBzdHJpbmdcbiAgICAgICAgbGV0IGhhc2hFbCA9IHRoaXMuZ2V0SGFzaFRhcmdldEVsKHdpbmRvdy5sb2NhdGlvbi5oYXNoKVxuXG4gICAgICAgIGlmKGhhc2hFbCl7XG4gICAgICAgICAgaGFzaEVsLnNjcm9sbEludG9WaWV3KClcbiAgICAgICAgfSBlbHNlIGlmKG1ldGEudHlwZSA9PT0gXCJyZWRpcmVjdFwiKXtcbiAgICAgICAgICB3aW5kb3cuc2Nyb2xsKDAsIDApXG4gICAgICAgIH1cbiAgICAgIH1cbiAgICB9IGVsc2Uge1xuICAgICAgdGhpcy5yZWRpcmVjdCh0bylcbiAgICB9XG4gIH0sXG5cbiAgc2V0Q29va2llKG5hbWUsIHZhbHVlKXtcbiAgICBkb2N1bWVudC5jb29raWUgPSBgJHtuYW1lfT0ke3ZhbHVlfWBcbiAgfSxcblxuICBnZXRDb29raWUobmFtZSl7XG4gICAgcmV0dXJuIGRvY3VtZW50LmNvb2tpZS5yZXBsYWNlKG5ldyBSZWdFeHAoYCg/Oig/Ol58Lio7XFxzKikke25hbWV9XFxzKlxcPVxccyooW147XSopLiokKXxeLiokYCksIFwiJDFcIilcbiAgfSxcblxuICByZWRpcmVjdCh0b1VSTCwgZmxhc2gpe1xuICAgIGlmKGZsYXNoKXsgQnJvd3Nlci5zZXRDb29raWUoXCJfX3Bob2VuaXhfZmxhc2hfX1wiLCBmbGFzaCArIFwiOyBtYXgtYWdlPTYwMDAwOyBwYXRoPS9cIikgfVxuICAgIHdpbmRvdy5sb2NhdGlvbiA9IHRvVVJMXG4gIH0sXG5cbiAgbG9jYWxLZXkobmFtZXNwYWNlLCBzdWJrZXkpeyByZXR1cm4gYCR7bmFtZXNwYWNlfS0ke3N1YmtleX1gIH0sXG5cbiAgZ2V0SGFzaFRhcmdldEVsKG1heWJlSGFzaCl7XG4gICAgbGV0IGhhc2ggPSBtYXliZUhhc2gudG9TdHJpbmcoKS5zdWJzdHJpbmcoMSlcbiAgICBpZihoYXNoID09PSBcIlwiKXsgcmV0dXJuIH1cbiAgICByZXR1cm4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaGFzaCkgfHwgZG9jdW1lbnQucXVlcnlTZWxlY3RvcihgYVtuYW1lPVwiJHtoYXNofVwiXWApXG4gIH1cbn1cblxuZXhwb3J0IGRlZmF1bHQgQnJvd3NlclxuIiwgImxldCBBUklBID0ge1xuICBmb2N1c01haW4oKXtcbiAgICBsZXQgdGFyZ2V0ID0gZG9jdW1lbnQucXVlcnlTZWxlY3RvcihcIm1haW4gaDEsIG1haW4sIGgxXCIpXG4gICAgaWYodGFyZ2V0KXtcbiAgICAgIGxldCBvcmlnVGFiSW5kZXggPSB0YXJnZXQudGFiSW5kZXhcbiAgICAgIHRhcmdldC50YWJJbmRleCA9IC0xXG4gICAgICB0YXJnZXQuZm9jdXMoKVxuICAgICAgdGFyZ2V0LnRhYkluZGV4ID0gb3JpZ1RhYkluZGV4XG4gICAgfVxuICB9LFxuXG4gIGFueU9mKGluc3RhbmNlLCBjbGFzc2VzKXsgcmV0dXJuIGNsYXNzZXMuZmluZChuYW1lID0+IGluc3RhbmNlIGluc3RhbmNlb2YgbmFtZSkgfSxcblxuICBpc0ZvY3VzYWJsZShlbCwgaW50ZXJhY3RpdmVPbmx5KXtcbiAgICByZXR1cm4oXG4gICAgICAoZWwgaW5zdGFuY2VvZiBIVE1MQW5jaG9yRWxlbWVudCAmJiBlbC5yZWwgIT09IFwiaWdub3JlXCIpIHx8XG4gICAgICAoZWwgaW5zdGFuY2VvZiBIVE1MQXJlYUVsZW1lbnQgJiYgZWwuaHJlZiAhPT0gdW5kZWZpbmVkKSB8fFxuICAgICAgKCFlbC5kaXNhYmxlZCAmJiAodGhpcy5hbnlPZihlbCwgW0hUTUxJbnB1dEVsZW1lbnQsIEhUTUxTZWxlY3RFbGVtZW50LCBIVE1MVGV4dEFyZWFFbGVtZW50LCBIVE1MQnV0dG9uRWxlbWVudF0pKSkgfHxcbiAgICAgIChlbCBpbnN0YW5jZW9mIEhUTUxJRnJhbWVFbGVtZW50KSB8fFxuICAgICAgKGVsLnRhYkluZGV4ID4gMCB8fCAoIWludGVyYWN0aXZlT25seSAmJiBlbC5nZXRBdHRyaWJ1dGUoXCJ0YWJpbmRleFwiKSAhPT0gbnVsbCAmJiBlbC5nZXRBdHRyaWJ1dGUoXCJhcmlhLWhpZGRlblwiKSAhPT0gXCJ0cnVlXCIpKVxuICAgIClcbiAgfSxcblxuICBhdHRlbXB0Rm9jdXMoZWwsIGludGVyYWN0aXZlT25seSl7XG4gICAgaWYodGhpcy5pc0ZvY3VzYWJsZShlbCwgaW50ZXJhY3RpdmVPbmx5KSl7IHRyeXsgZWwuZm9jdXMoKSB9IGNhdGNoKGUpe30gfVxuICAgIHJldHVybiAhIWRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgJiYgZG9jdW1lbnQuYWN0aXZlRWxlbWVudC5pc1NhbWVOb2RlKGVsKVxuICB9LFxuXG4gIGZvY3VzRmlyc3RJbnRlcmFjdGl2ZShlbCl7XG4gICAgbGV0IGNoaWxkID0gZWwuZmlyc3RFbGVtZW50Q2hpbGRcbiAgICB3aGlsZShjaGlsZCl7XG4gICAgICBpZih0aGlzLmF0dGVtcHRGb2N1cyhjaGlsZCwgdHJ1ZSkgfHwgdGhpcy5mb2N1c0ZpcnN0SW50ZXJhY3RpdmUoY2hpbGQsIHRydWUpKXtcbiAgICAgICAgcmV0dXJuIHRydWVcbiAgICAgIH1cbiAgICAgIGNoaWxkID0gY2hpbGQubmV4dEVsZW1lbnRTaWJsaW5nXG4gICAgfVxuICB9LFxuXG4gIGZvY3VzRmlyc3QoZWwpe1xuICAgIGxldCBjaGlsZCA9IGVsLmZpcnN0RWxlbWVudENoaWxkXG4gICAgd2hpbGUoY2hpbGQpe1xuICAgICAgaWYodGhpcy5hdHRlbXB0Rm9jdXMoY2hpbGQpIHx8IHRoaXMuZm9jdXNGaXJzdChjaGlsZCkpe1xuICAgICAgICByZXR1cm4gdHJ1ZVxuICAgICAgfVxuICAgICAgY2hpbGQgPSBjaGlsZC5uZXh0RWxlbWVudFNpYmxpbmdcbiAgICB9XG4gIH0sXG5cbiAgZm9jdXNMYXN0KGVsKXtcbiAgICBsZXQgY2hpbGQgPSBlbC5sYXN0RWxlbWVudENoaWxkXG4gICAgd2hpbGUoY2hpbGQpe1xuICAgICAgaWYodGhpcy5hdHRlbXB0Rm9jdXMoY2hpbGQpIHx8IHRoaXMuZm9jdXNMYXN0KGNoaWxkKSl7XG4gICAgICAgIHJldHVybiB0cnVlXG4gICAgICB9XG4gICAgICBjaGlsZCA9IGNoaWxkLnByZXZpb3VzRWxlbWVudFNpYmxpbmdcbiAgICB9XG4gIH1cbn1cbmV4cG9ydCBkZWZhdWx0IEFSSUEiLCAiaW1wb3J0IERPTSBmcm9tIFwiLi9kb21cIlxuaW1wb3J0IEFSSUEgZnJvbSBcIi4vYXJpYVwiXG5cbmxldCBmb2N1c1N0YWNrID0gW11cbmxldCBkZWZhdWx0X3RyYW5zaXRpb25fdGltZSA9IDIwMFxuXG5sZXQgSlMgPSB7XG4gIGV4ZWMoZXZlbnRUeXBlLCBwaHhFdmVudCwgdmlldywgc291cmNlRWwsIGRlZmF1bHRzKXtcbiAgICBsZXQgW2RlZmF1bHRLaW5kLCBkZWZhdWx0QXJnc10gPSBkZWZhdWx0cyB8fCBbbnVsbCwge2NhbGxiYWNrOiBkZWZhdWx0cyAmJiBkZWZhdWx0cy5jYWxsYmFja31dXG4gICAgbGV0IGNvbW1hbmRzID0gcGh4RXZlbnQuY2hhckF0KDApID09PSBcIltcIiA/XG4gICAgICBKU09OLnBhcnNlKHBoeEV2ZW50KSA6IFtbZGVmYXVsdEtpbmQsIGRlZmF1bHRBcmdzXV1cblxuICAgIGNvbW1hbmRzLmZvckVhY2goKFtraW5kLCBhcmdzXSkgPT4ge1xuICAgICAgaWYoa2luZCA9PT0gZGVmYXVsdEtpbmQgJiYgZGVmYXVsdEFyZ3MuZGF0YSl7XG4gICAgICAgIGFyZ3MuZGF0YSA9IE9iamVjdC5hc3NpZ24oYXJncy5kYXRhIHx8IHt9LCBkZWZhdWx0QXJncy5kYXRhKVxuICAgICAgICBhcmdzLmNhbGxiYWNrID0gYXJncy5jYWxsYmFjayB8fCBkZWZhdWx0QXJncy5jYWxsYmFja1xuICAgICAgfVxuICAgICAgdGhpcy5maWx0ZXJUb0Vscyhzb3VyY2VFbCwgYXJncykuZm9yRWFjaChlbCA9PiB7XG4gICAgICAgIHRoaXNbYGV4ZWNfJHtraW5kfWBdKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwgYXJncylcbiAgICAgIH0pXG4gICAgfSlcbiAgfSxcblxuICBpc1Zpc2libGUoZWwpe1xuICAgIHJldHVybiAhIShlbC5vZmZzZXRXaWR0aCB8fCBlbC5vZmZzZXRIZWlnaHQgfHwgZWwuZ2V0Q2xpZW50UmVjdHMoKS5sZW5ndGggPiAwKVxuICB9LFxuXG4gIC8vIHJldHVybnMgdHJ1ZSBpZiBhbnkgcGFydCBvZiB0aGUgZWxlbWVudCBpcyBpbnNpZGUgdGhlIHZpZXdwb3J0XG4gIGlzSW5WaWV3cG9ydChlbCl7XG4gICAgY29uc3QgcmVjdCA9IGVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpXG4gICAgY29uc3Qgd2luZG93SGVpZ2h0ID0gd2luZG93LmlubmVySGVpZ2h0IHx8IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5jbGllbnRIZWlnaHRcbiAgICBjb25zdCB3aW5kb3dXaWR0aCA9IHdpbmRvdy5pbm5lcldpZHRoIHx8IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5jbGllbnRXaWR0aFxuXG4gICAgcmV0dXJuIChcbiAgICAgIHJlY3QucmlnaHQgPiAwICYmXG4gICAgICByZWN0LmJvdHRvbSA+IDAgJiZcbiAgICAgIHJlY3QubGVmdCA8IHdpbmRvd1dpZHRoICYmXG4gICAgICByZWN0LnRvcCA8IHdpbmRvd0hlaWdodFxuICAgIClcbiAgfSxcblxuICAvLyBwcml2YXRlXG5cbiAgLy8gY29tbWFuZHNcblxuICBleGVjX2V4ZWMoZXZlbnRUeXBlLCBwaHhFdmVudCwgdmlldywgc291cmNlRWwsIGVsLCB7YXR0ciwgdG99KXtcbiAgICBsZXQgbm9kZXMgPSB0byA/IERPTS5hbGwoZG9jdW1lbnQsIHRvKSA6IFtzb3VyY2VFbF1cbiAgICBub2Rlcy5mb3JFYWNoKG5vZGUgPT4ge1xuICAgICAgbGV0IGVuY29kZWRKUyA9IG5vZGUuZ2V0QXR0cmlidXRlKGF0dHIpXG4gICAgICBpZighZW5jb2RlZEpTKXsgdGhyb3cgbmV3IEVycm9yKGBleHBlY3RlZCAke2F0dHJ9IHRvIGNvbnRhaW4gSlMgY29tbWFuZCBvbiBcIiR7dG99XCJgKSB9XG4gICAgICB2aWV3LmxpdmVTb2NrZXQuZXhlY0pTKG5vZGUsIGVuY29kZWRKUywgZXZlbnRUeXBlKVxuICAgIH0pXG4gIH0sXG5cbiAgZXhlY19kaXNwYXRjaChldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIHt0bywgZXZlbnQsIGRldGFpbCwgYnViYmxlc30pe1xuICAgIGRldGFpbCA9IGRldGFpbCB8fCB7fVxuICAgIGRldGFpbC5kaXNwYXRjaGVyID0gc291cmNlRWxcbiAgICBET00uZGlzcGF0Y2hFdmVudChlbCwgZXZlbnQsIHtkZXRhaWwsIGJ1YmJsZXN9KVxuICB9LFxuXG4gIGV4ZWNfcHVzaChldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIGFyZ3Mpe1xuICAgIGxldCB7ZXZlbnQsIGRhdGEsIHRhcmdldCwgcGFnZV9sb2FkaW5nLCBsb2FkaW5nLCB2YWx1ZSwgZGlzcGF0Y2hlciwgY2FsbGJhY2t9ID0gYXJnc1xuICAgIGxldCBwdXNoT3B0cyA9IHtsb2FkaW5nLCB2YWx1ZSwgdGFyZ2V0LCBwYWdlX2xvYWRpbmc6ICEhcGFnZV9sb2FkaW5nfVxuICAgIGxldCB0YXJnZXRTcmMgPSBldmVudFR5cGUgPT09IFwiY2hhbmdlXCIgJiYgZGlzcGF0Y2hlciA/IGRpc3BhdGNoZXIgOiBzb3VyY2VFbFxuICAgIGxldCBwaHhUYXJnZXQgPSB0YXJnZXQgfHwgdGFyZ2V0U3JjLmdldEF0dHJpYnV0ZSh2aWV3LmJpbmRpbmcoXCJ0YXJnZXRcIikpIHx8IHRhcmdldFNyY1xuICAgIHZpZXcud2l0aGluVGFyZ2V0cyhwaHhUYXJnZXQsICh0YXJnZXRWaWV3LCB0YXJnZXRDdHgpID0+IHtcbiAgICAgIGlmKCF0YXJnZXRWaWV3LmlzQ29ubmVjdGVkKCkpeyByZXR1cm4gfVxuICAgICAgaWYoZXZlbnRUeXBlID09PSBcImNoYW5nZVwiKXtcbiAgICAgICAgbGV0IHtuZXdDaWQsIF90YXJnZXR9ID0gYXJnc1xuICAgICAgICBfdGFyZ2V0ID0gX3RhcmdldCB8fCAoRE9NLmlzRm9ybUlucHV0KHNvdXJjZUVsKSA/IHNvdXJjZUVsLm5hbWUgOiB1bmRlZmluZWQpXG4gICAgICAgIGlmKF90YXJnZXQpeyBwdXNoT3B0cy5fdGFyZ2V0ID0gX3RhcmdldCB9XG4gICAgICAgIHRhcmdldFZpZXcucHVzaElucHV0KHNvdXJjZUVsLCB0YXJnZXRDdHgsIG5ld0NpZCwgZXZlbnQgfHwgcGh4RXZlbnQsIHB1c2hPcHRzLCBjYWxsYmFjaylcbiAgICAgIH0gZWxzZSBpZihldmVudFR5cGUgPT09IFwic3VibWl0XCIpe1xuICAgICAgICBsZXQge3N1Ym1pdHRlcn0gPSBhcmdzXG4gICAgICAgIHRhcmdldFZpZXcuc3VibWl0Rm9ybShzb3VyY2VFbCwgdGFyZ2V0Q3R4LCBldmVudCB8fCBwaHhFdmVudCwgc3VibWl0dGVyLCBwdXNoT3B0cywgY2FsbGJhY2spXG4gICAgICB9IGVsc2Uge1xuICAgICAgICB0YXJnZXRWaWV3LnB1c2hFdmVudChldmVudFR5cGUsIHNvdXJjZUVsLCB0YXJnZXRDdHgsIGV2ZW50IHx8IHBoeEV2ZW50LCBkYXRhLCBwdXNoT3B0cywgY2FsbGJhY2spXG4gICAgICB9XG4gICAgfSlcbiAgfSxcblxuICBleGVjX25hdmlnYXRlKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwge2hyZWYsIHJlcGxhY2V9KXtcbiAgICB2aWV3LmxpdmVTb2NrZXQuaGlzdG9yeVJlZGlyZWN0KGhyZWYsIHJlcGxhY2UgPyBcInJlcGxhY2VcIiA6IFwicHVzaFwiKVxuICB9LFxuXG4gIGV4ZWNfcGF0Y2goZXZlbnRUeXBlLCBwaHhFdmVudCwgdmlldywgc291cmNlRWwsIGVsLCB7aHJlZiwgcmVwbGFjZX0pe1xuICAgIHZpZXcubGl2ZVNvY2tldC5wdXNoSGlzdG9yeVBhdGNoKGhyZWYsIHJlcGxhY2UgPyBcInJlcGxhY2VcIiA6IFwicHVzaFwiLCBzb3VyY2VFbClcbiAgfSxcblxuICBleGVjX2ZvY3VzKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCl7XG4gICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiBBUklBLmF0dGVtcHRGb2N1cyhlbCkpXG4gIH0sXG5cbiAgZXhlY19mb2N1c19maXJzdChldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwpe1xuICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gQVJJQS5mb2N1c0ZpcnN0SW50ZXJhY3RpdmUoZWwpIHx8IEFSSUEuZm9jdXNGaXJzdChlbCkpXG4gIH0sXG5cbiAgZXhlY19wdXNoX2ZvY3VzKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCl7XG4gICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiBmb2N1c1N0YWNrLnB1c2goZWwgfHwgc291cmNlRWwpKVxuICB9LFxuXG4gIGV4ZWNfcG9wX2ZvY3VzKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCl7XG4gICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICBjb25zdCBlbCA9IGZvY3VzU3RhY2sucG9wKClcbiAgICAgIGlmKGVsKXsgZWwuZm9jdXMoKSB9XG4gICAgfSlcbiAgfSxcblxuICBleGVjX2FkZF9jbGFzcyhldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIHtuYW1lcywgdHJhbnNpdGlvbiwgdGltZX0pe1xuICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBuYW1lcywgW10sIHRyYW5zaXRpb24sIHRpbWUsIHZpZXcpXG4gIH0sXG5cbiAgZXhlY19yZW1vdmVfY2xhc3MoZXZlbnRUeXBlLCBwaHhFdmVudCwgdmlldywgc291cmNlRWwsIGVsLCB7bmFtZXMsIHRyYW5zaXRpb24sIHRpbWV9KXtcbiAgICB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgW10sIG5hbWVzLCB0cmFuc2l0aW9uLCB0aW1lLCB2aWV3KVxuICB9LFxuXG4gIGV4ZWNfdG9nZ2xlX2NsYXNzKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwge3RvLCBuYW1lcywgdHJhbnNpdGlvbiwgdGltZX0pe1xuICAgIHRoaXMudG9nZ2xlQ2xhc3NlcyhlbCwgbmFtZXMsIHRyYW5zaXRpb24sIHRpbWUsIHZpZXcpXG4gIH0sXG5cbiAgZXhlY190b2dnbGVfYXR0cihldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIHthdHRyOiBbYXR0ciwgdmFsMSwgdmFsMl19KXtcbiAgICBpZihlbC5oYXNBdHRyaWJ1dGUoYXR0cikpe1xuICAgICAgaWYodmFsMiAhPT0gdW5kZWZpbmVkKXtcbiAgICAgICAgLy8gdG9nZ2xlIGJldHdlZW4gdmFsMSBhbmQgdmFsMlxuICAgICAgICBpZihlbC5nZXRBdHRyaWJ1dGUoYXR0cikgPT09IHZhbDEpe1xuICAgICAgICAgIHRoaXMuc2V0T3JSZW1vdmVBdHRycyhlbCwgW1thdHRyLCB2YWwyXV0sIFtdKVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIHRoaXMuc2V0T3JSZW1vdmVBdHRycyhlbCwgW1thdHRyLCB2YWwxXV0sIFtdKVxuICAgICAgICB9XG4gICAgICB9IGVsc2Uge1xuICAgICAgICAvLyByZW1vdmUgYXR0clxuICAgICAgICB0aGlzLnNldE9yUmVtb3ZlQXR0cnMoZWwsIFtdLCBbYXR0cl0pXG4gICAgICB9XG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMuc2V0T3JSZW1vdmVBdHRycyhlbCwgW1thdHRyLCB2YWwxXV0sIFtdKVxuICAgIH1cbiAgfSxcblxuICBleGVjX3RyYW5zaXRpb24oZXZlbnRUeXBlLCBwaHhFdmVudCwgdmlldywgc291cmNlRWwsIGVsLCB7dGltZSwgdHJhbnNpdGlvbn0pe1xuICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBbXSwgW10sIHRyYW5zaXRpb24sIHRpbWUsIHZpZXcpXG4gIH0sXG5cbiAgZXhlY190b2dnbGUoZXZlbnRUeXBlLCBwaHhFdmVudCwgdmlldywgc291cmNlRWwsIGVsLCB7ZGlzcGxheSwgaW5zLCBvdXRzLCB0aW1lfSl7XG4gICAgdGhpcy50b2dnbGUoZXZlbnRUeXBlLCB2aWV3LCBlbCwgZGlzcGxheSwgaW5zLCBvdXRzLCB0aW1lKVxuICB9LFxuXG4gIGV4ZWNfc2hvdyhldmVudFR5cGUsIHBoeEV2ZW50LCB2aWV3LCBzb3VyY2VFbCwgZWwsIHtkaXNwbGF5LCB0cmFuc2l0aW9uLCB0aW1lfSl7XG4gICAgdGhpcy5zaG93KGV2ZW50VHlwZSwgdmlldywgZWwsIGRpc3BsYXksIHRyYW5zaXRpb24sIHRpbWUpXG4gIH0sXG5cbiAgZXhlY19oaWRlKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwge2Rpc3BsYXksIHRyYW5zaXRpb24sIHRpbWV9KXtcbiAgICB0aGlzLmhpZGUoZXZlbnRUeXBlLCB2aWV3LCBlbCwgZGlzcGxheSwgdHJhbnNpdGlvbiwgdGltZSlcbiAgfSxcblxuICBleGVjX3NldF9hdHRyKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwge2F0dHI6IFthdHRyLCB2YWxdfSl7XG4gICAgdGhpcy5zZXRPclJlbW92ZUF0dHJzKGVsLCBbW2F0dHIsIHZhbF1dLCBbXSlcbiAgfSxcblxuICBleGVjX3JlbW92ZV9hdHRyKGV2ZW50VHlwZSwgcGh4RXZlbnQsIHZpZXcsIHNvdXJjZUVsLCBlbCwge2F0dHJ9KXtcbiAgICB0aGlzLnNldE9yUmVtb3ZlQXR0cnMoZWwsIFtdLCBbYXR0cl0pXG4gIH0sXG5cbiAgLy8gdXRpbHMgZm9yIGNvbW1hbmRzXG5cbiAgc2hvdyhldmVudFR5cGUsIHZpZXcsIGVsLCBkaXNwbGF5LCB0cmFuc2l0aW9uLCB0aW1lKXtcbiAgICBpZighdGhpcy5pc1Zpc2libGUoZWwpKXtcbiAgICAgIHRoaXMudG9nZ2xlKGV2ZW50VHlwZSwgdmlldywgZWwsIGRpc3BsYXksIHRyYW5zaXRpb24sIG51bGwsIHRpbWUpXG4gICAgfVxuICB9LFxuXG4gIGhpZGUoZXZlbnRUeXBlLCB2aWV3LCBlbCwgZGlzcGxheSwgdHJhbnNpdGlvbiwgdGltZSl7XG4gICAgaWYodGhpcy5pc1Zpc2libGUoZWwpKXtcbiAgICAgIHRoaXMudG9nZ2xlKGV2ZW50VHlwZSwgdmlldywgZWwsIGRpc3BsYXksIG51bGwsIHRyYW5zaXRpb24sIHRpbWUpXG4gICAgfVxuICB9LFxuXG4gIHRvZ2dsZShldmVudFR5cGUsIHZpZXcsIGVsLCBkaXNwbGF5LCBpbnMsIG91dHMsIHRpbWUpe1xuICAgIHRpbWUgPSB0aW1lIHx8IGRlZmF1bHRfdHJhbnNpdGlvbl90aW1lXG4gICAgbGV0IFtpbkNsYXNzZXMsIGluU3RhcnRDbGFzc2VzLCBpbkVuZENsYXNzZXNdID0gaW5zIHx8IFtbXSwgW10sIFtdXVxuICAgIGxldCBbb3V0Q2xhc3Nlcywgb3V0U3RhcnRDbGFzc2VzLCBvdXRFbmRDbGFzc2VzXSA9IG91dHMgfHwgW1tdLCBbXSwgW11dXG4gICAgaWYoaW5DbGFzc2VzLmxlbmd0aCA+IDAgfHwgb3V0Q2xhc3Nlcy5sZW5ndGggPiAwKXtcbiAgICAgIGlmKHRoaXMuaXNWaXNpYmxlKGVsKSl7XG4gICAgICAgIGxldCBvblN0YXJ0ID0gKCkgPT4ge1xuICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBvdXRTdGFydENsYXNzZXMsIGluQ2xhc3Nlcy5jb25jYXQoaW5TdGFydENsYXNzZXMpLmNvbmNhdChpbkVuZENsYXNzZXMpKVxuICAgICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIG91dENsYXNzZXMsIFtdKVxuICAgICAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgb3V0RW5kQ2xhc3Nlcywgb3V0U3RhcnRDbGFzc2VzKSlcbiAgICAgICAgICB9KVxuICAgICAgICB9XG4gICAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwicGh4OmhpZGUtc3RhcnRcIikpXG4gICAgICAgIHZpZXcudHJhbnNpdGlvbih0aW1lLCBvblN0YXJ0LCAoKSA9PiB7XG4gICAgICAgICAgdGhpcy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIFtdLCBvdXRDbGFzc2VzLmNvbmNhdChvdXRFbmRDbGFzc2VzKSlcbiAgICAgICAgICBET00ucHV0U3RpY2t5KGVsLCBcInRvZ2dsZVwiLCBjdXJyZW50RWwgPT4gY3VycmVudEVsLnN0eWxlLmRpc3BsYXkgPSBcIm5vbmVcIilcbiAgICAgICAgICBlbC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudChcInBoeDpoaWRlLWVuZFwiKSlcbiAgICAgICAgfSlcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIGlmKGV2ZW50VHlwZSA9PT0gXCJyZW1vdmVcIil7IHJldHVybiB9XG4gICAgICAgIGxldCBvblN0YXJ0ID0gKCkgPT4ge1xuICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBpblN0YXJ0Q2xhc3Nlcywgb3V0Q2xhc3Nlcy5jb25jYXQob3V0U3RhcnRDbGFzc2VzKS5jb25jYXQob3V0RW5kQ2xhc3NlcykpXG4gICAgICAgICAgbGV0IHN0aWNreURpc3BsYXkgPSBkaXNwbGF5IHx8IHRoaXMuZGVmYXVsdERpc3BsYXkoZWwpXG4gICAgICAgICAgRE9NLnB1dFN0aWNreShlbCwgXCJ0b2dnbGVcIiwgY3VycmVudEVsID0+IGN1cnJlbnRFbC5zdHlsZS5kaXNwbGF5ID0gc3RpY2t5RGlzcGxheSlcbiAgICAgICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBpbkNsYXNzZXMsIFtdKVxuICAgICAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgaW5FbmRDbGFzc2VzLCBpblN0YXJ0Q2xhc3NlcykpXG4gICAgICAgICAgfSlcbiAgICAgICAgfVxuICAgICAgICBlbC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudChcInBoeDpzaG93LXN0YXJ0XCIpKVxuICAgICAgICB2aWV3LnRyYW5zaXRpb24odGltZSwgb25TdGFydCwgKCkgPT4ge1xuICAgICAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBbXSwgaW5DbGFzc2VzLmNvbmNhdChpbkVuZENsYXNzZXMpKVxuICAgICAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwicGh4OnNob3ctZW5kXCIpKVxuICAgICAgICB9KVxuICAgICAgfVxuICAgIH0gZWxzZSB7XG4gICAgICBpZih0aGlzLmlzVmlzaWJsZShlbCkpe1xuICAgICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgICAgICBlbC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudChcInBoeDpoaWRlLXN0YXJ0XCIpKVxuICAgICAgICAgIERPTS5wdXRTdGlja3koZWwsIFwidG9nZ2xlXCIsIGN1cnJlbnRFbCA9PiBjdXJyZW50RWwuc3R5bGUuZGlzcGxheSA9IFwibm9uZVwiKVxuICAgICAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwicGh4OmhpZGUtZW5kXCIpKVxuICAgICAgICB9KVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICAgICAgZWwuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoXCJwaHg6c2hvdy1zdGFydFwiKSlcbiAgICAgICAgICBsZXQgc3RpY2t5RGlzcGxheSA9IGRpc3BsYXkgfHwgdGhpcy5kZWZhdWx0RGlzcGxheShlbClcbiAgICAgICAgICBET00ucHV0U3RpY2t5KGVsLCBcInRvZ2dsZVwiLCBjdXJyZW50RWwgPT4gY3VycmVudEVsLnN0eWxlLmRpc3BsYXkgPSBzdGlja3lEaXNwbGF5KVxuICAgICAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwicGh4OnNob3ctZW5kXCIpKVxuICAgICAgICB9KVxuICAgICAgfVxuICAgIH1cbiAgfSxcblxuICB0b2dnbGVDbGFzc2VzKGVsLCBjbGFzc2VzLCB0cmFuc2l0aW9uLCB0aW1lLCB2aWV3KXtcbiAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgIGxldCBbcHJldkFkZHMsIHByZXZSZW1vdmVzXSA9IERPTS5nZXRTdGlja3koZWwsIFwiY2xhc3Nlc1wiLCBbW10sIFtdXSlcbiAgICAgIGxldCBuZXdBZGRzID0gY2xhc3Nlcy5maWx0ZXIobmFtZSA9PiBwcmV2QWRkcy5pbmRleE9mKG5hbWUpIDwgMCAmJiAhZWwuY2xhc3NMaXN0LmNvbnRhaW5zKG5hbWUpKVxuICAgICAgbGV0IG5ld1JlbW92ZXMgPSBjbGFzc2VzLmZpbHRlcihuYW1lID0+IHByZXZSZW1vdmVzLmluZGV4T2YobmFtZSkgPCAwICYmIGVsLmNsYXNzTGlzdC5jb250YWlucyhuYW1lKSlcbiAgICAgIHRoaXMuYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBuZXdBZGRzLCBuZXdSZW1vdmVzLCB0cmFuc2l0aW9uLCB0aW1lLCB2aWV3KVxuICAgIH0pXG4gIH0sXG5cbiAgYWRkT3JSZW1vdmVDbGFzc2VzKGVsLCBhZGRzLCByZW1vdmVzLCB0cmFuc2l0aW9uLCB0aW1lLCB2aWV3KXtcbiAgICB0aW1lID0gdGltZSB8fCBkZWZhdWx0X3RyYW5zaXRpb25fdGltZVxuICAgIGxldCBbdHJhbnNpdGlvblJ1biwgdHJhbnNpdGlvblN0YXJ0LCB0cmFuc2l0aW9uRW5kXSA9IHRyYW5zaXRpb24gfHwgW1tdLCBbXSwgW11dXG4gICAgaWYodHJhbnNpdGlvblJ1bi5sZW5ndGggPiAwKXtcbiAgICAgIGxldCBvblN0YXJ0ID0gKCkgPT4ge1xuICAgICAgICB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgdHJhbnNpdGlvblN0YXJ0LCBbXS5jb25jYXQodHJhbnNpdGlvblJ1bikuY29uY2F0KHRyYW5zaXRpb25FbmQpKVxuICAgICAgICB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgICAgICB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgdHJhbnNpdGlvblJ1biwgW10pXG4gICAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgdHJhbnNpdGlvbkVuZCwgdHJhbnNpdGlvblN0YXJ0KSlcbiAgICAgICAgfSlcbiAgICAgIH1cbiAgICAgIGxldCBvbkRvbmUgPSAoKSA9PiB0aGlzLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgYWRkcy5jb25jYXQodHJhbnNpdGlvbkVuZCksIHJlbW92ZXMuY29uY2F0KHRyYW5zaXRpb25SdW4pLmNvbmNhdCh0cmFuc2l0aW9uU3RhcnQpKVxuICAgICAgcmV0dXJuIHZpZXcudHJhbnNpdGlvbih0aW1lLCBvblN0YXJ0LCBvbkRvbmUpXG4gICAgfVxuXG4gICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICBsZXQgW3ByZXZBZGRzLCBwcmV2UmVtb3Zlc10gPSBET00uZ2V0U3RpY2t5KGVsLCBcImNsYXNzZXNcIiwgW1tdLCBbXV0pXG4gICAgICBsZXQga2VlcEFkZHMgPSBhZGRzLmZpbHRlcihuYW1lID0+IHByZXZBZGRzLmluZGV4T2YobmFtZSkgPCAwICYmICFlbC5jbGFzc0xpc3QuY29udGFpbnMobmFtZSkpXG4gICAgICBsZXQga2VlcFJlbW92ZXMgPSByZW1vdmVzLmZpbHRlcihuYW1lID0+IHByZXZSZW1vdmVzLmluZGV4T2YobmFtZSkgPCAwICYmIGVsLmNsYXNzTGlzdC5jb250YWlucyhuYW1lKSlcbiAgICAgIGxldCBuZXdBZGRzID0gcHJldkFkZHMuZmlsdGVyKG5hbWUgPT4gcmVtb3Zlcy5pbmRleE9mKG5hbWUpIDwgMCkuY29uY2F0KGtlZXBBZGRzKVxuICAgICAgbGV0IG5ld1JlbW92ZXMgPSBwcmV2UmVtb3Zlcy5maWx0ZXIobmFtZSA9PiBhZGRzLmluZGV4T2YobmFtZSkgPCAwKS5jb25jYXQoa2VlcFJlbW92ZXMpXG5cbiAgICAgIERPTS5wdXRTdGlja3koZWwsIFwiY2xhc3Nlc1wiLCBjdXJyZW50RWwgPT4ge1xuICAgICAgICBjdXJyZW50RWwuY2xhc3NMaXN0LnJlbW92ZSguLi5uZXdSZW1vdmVzKVxuICAgICAgICBjdXJyZW50RWwuY2xhc3NMaXN0LmFkZCguLi5uZXdBZGRzKVxuICAgICAgICByZXR1cm4gW25ld0FkZHMsIG5ld1JlbW92ZXNdXG4gICAgICB9KVxuICAgIH0pXG4gIH0sXG5cbiAgc2V0T3JSZW1vdmVBdHRycyhlbCwgc2V0cywgcmVtb3Zlcyl7XG4gICAgbGV0IFtwcmV2U2V0cywgcHJldlJlbW92ZXNdID0gRE9NLmdldFN0aWNreShlbCwgXCJhdHRyc1wiLCBbW10sIFtdXSlcblxuICAgIGxldCBhbHRlcmVkQXR0cnMgPSBzZXRzLm1hcCgoW2F0dHIsIF92YWxdKSA9PiBhdHRyKS5jb25jYXQocmVtb3ZlcylcbiAgICBsZXQgbmV3U2V0cyA9IHByZXZTZXRzLmZpbHRlcigoW2F0dHIsIF92YWxdKSA9PiAhYWx0ZXJlZEF0dHJzLmluY2x1ZGVzKGF0dHIpKS5jb25jYXQoc2V0cylcbiAgICBsZXQgbmV3UmVtb3ZlcyA9IHByZXZSZW1vdmVzLmZpbHRlcigoYXR0cikgPT4gIWFsdGVyZWRBdHRycy5pbmNsdWRlcyhhdHRyKSkuY29uY2F0KHJlbW92ZXMpXG5cbiAgICBET00ucHV0U3RpY2t5KGVsLCBcImF0dHJzXCIsIGN1cnJlbnRFbCA9PiB7XG4gICAgICBuZXdSZW1vdmVzLmZvckVhY2goYXR0ciA9PiBjdXJyZW50RWwucmVtb3ZlQXR0cmlidXRlKGF0dHIpKVxuICAgICAgbmV3U2V0cy5mb3JFYWNoKChbYXR0ciwgdmFsXSkgPT4gY3VycmVudEVsLnNldEF0dHJpYnV0ZShhdHRyLCB2YWwpKVxuICAgICAgcmV0dXJuIFtuZXdTZXRzLCBuZXdSZW1vdmVzXVxuICAgIH0pXG4gIH0sXG5cbiAgaGFzQWxsQ2xhc3NlcyhlbCwgY2xhc3Nlcyl7IHJldHVybiBjbGFzc2VzLmV2ZXJ5KG5hbWUgPT4gZWwuY2xhc3NMaXN0LmNvbnRhaW5zKG5hbWUpKSB9LFxuXG4gIGlzVG9nZ2xlZE91dChlbCwgb3V0Q2xhc3Nlcyl7XG4gICAgcmV0dXJuICF0aGlzLmlzVmlzaWJsZShlbCkgfHwgdGhpcy5oYXNBbGxDbGFzc2VzKGVsLCBvdXRDbGFzc2VzKVxuICB9LFxuXG4gIGZpbHRlclRvRWxzKHNvdXJjZUVsLCB7dG99KXtcbiAgICByZXR1cm4gdG8gPyBET00uYWxsKGRvY3VtZW50LCB0bykgOiBbc291cmNlRWxdXG4gIH0sXG5cbiAgZGVmYXVsdERpc3BsYXkoZWwpe1xuICAgIHJldHVybiB7dHI6IFwidGFibGUtcm93XCIsIHRkOiBcInRhYmxlLWNlbGxcIn1bZWwudGFnTmFtZS50b0xvd2VyQ2FzZSgpXSB8fCBcImJsb2NrXCJcbiAgfVxufVxuXG5leHBvcnQgZGVmYXVsdCBKUyIsICJpbXBvcnQge1xuICBDSEVDS0FCTEVfSU5QVVRTLFxuICBERUJPVU5DRV9QUkVWX0tFWSxcbiAgREVCT1VOQ0VfVFJJR0dFUixcbiAgRk9DVVNBQkxFX0lOUFVUUyxcbiAgUEhYX0NPTVBPTkVOVCxcbiAgUEhYX0VWRU5UX0NMQVNTRVMsXG4gIFBIWF9IQVNfRk9DVVNFRCxcbiAgUEhYX0hBU19TVUJNSVRURUQsXG4gIFBIWF9NQUlOLFxuICBQSFhfTk9fRkVFREJBQ0tfQ0xBU1MsXG4gIFBIWF9QQVJFTlRfSUQsXG4gIFBIWF9QUklWQVRFLFxuICBQSFhfUkVGLFxuICBQSFhfUkVGX1NSQyxcbiAgUEhYX1JPT1RfSUQsXG4gIFBIWF9TRVNTSU9OLFxuICBQSFhfU1RBVElDLFxuICBQSFhfVVBMT0FEX1JFRixcbiAgUEhYX1ZJRVdfU0VMRUNUT1IsXG4gIFBIWF9TVElDS1ksXG4gIFRIUk9UVExFRFxufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5pbXBvcnQgSlMgZnJvbSBcIi4vanNcIlxuXG5pbXBvcnQge1xuICBsb2dFcnJvclxufSBmcm9tIFwiLi91dGlsc1wiXG5cbmxldCBET00gPSB7XG4gIGJ5SWQoaWQpeyByZXR1cm4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpIHx8IGxvZ0Vycm9yKGBubyBpZCBmb3VuZCBmb3IgJHtpZH1gKSB9LFxuXG4gIHJlbW92ZUNsYXNzKGVsLCBjbGFzc05hbWUpe1xuICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoY2xhc3NOYW1lKVxuICAgIGlmKGVsLmNsYXNzTGlzdC5sZW5ndGggPT09IDApeyBlbC5yZW1vdmVBdHRyaWJ1dGUoXCJjbGFzc1wiKSB9XG4gIH0sXG5cbiAgYWxsKG5vZGUsIHF1ZXJ5LCBjYWxsYmFjayl7XG4gICAgaWYoIW5vZGUpeyByZXR1cm4gW10gfVxuICAgIGxldCBhcnJheSA9IEFycmF5LmZyb20obm9kZS5xdWVyeVNlbGVjdG9yQWxsKHF1ZXJ5KSlcbiAgICByZXR1cm4gY2FsbGJhY2sgPyBhcnJheS5mb3JFYWNoKGNhbGxiYWNrKSA6IGFycmF5XG4gIH0sXG5cbiAgY2hpbGROb2RlTGVuZ3RoKGh0bWwpe1xuICAgIGxldCB0ZW1wbGF0ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJ0ZW1wbGF0ZVwiKVxuICAgIHRlbXBsYXRlLmlubmVySFRNTCA9IGh0bWxcbiAgICByZXR1cm4gdGVtcGxhdGUuY29udGVudC5jaGlsZEVsZW1lbnRDb3VudFxuICB9LFxuXG4gIGlzVXBsb2FkSW5wdXQoZWwpeyByZXR1cm4gZWwudHlwZSA9PT0gXCJmaWxlXCIgJiYgZWwuZ2V0QXR0cmlidXRlKFBIWF9VUExPQURfUkVGKSAhPT0gbnVsbCB9LFxuXG4gIGlzQXV0b1VwbG9hZChpbnB1dEVsKXsgcmV0dXJuIGlucHV0RWwuaGFzQXR0cmlidXRlKFwiZGF0YS1waHgtYXV0by11cGxvYWRcIikgfSxcblxuICBmaW5kVXBsb2FkSW5wdXRzKG5vZGUpe1xuICAgIGNvbnN0IGZvcm1JZCA9IG5vZGUuaWRcbiAgICBjb25zdCBpbnB1dHNPdXRzaWRlRm9ybSA9IHRoaXMuYWxsKGRvY3VtZW50LCBgaW5wdXRbdHlwZT1cImZpbGVcIl1bJHtQSFhfVVBMT0FEX1JFRn1dW2Zvcm09XCIke2Zvcm1JZH1cIl1gKVxuICAgIHJldHVybiB0aGlzLmFsbChub2RlLCBgaW5wdXRbdHlwZT1cImZpbGVcIl1bJHtQSFhfVVBMT0FEX1JFRn1dYCkuY29uY2F0KGlucHV0c091dHNpZGVGb3JtKVxuICB9LFxuXG4gIGZpbmRDb21wb25lbnROb2RlTGlzdChub2RlLCBjaWQpe1xuICAgIHJldHVybiB0aGlzLmZpbHRlcldpdGhpblNhbWVMaXZlVmlldyh0aGlzLmFsbChub2RlLCBgWyR7UEhYX0NPTVBPTkVOVH09XCIke2NpZH1cIl1gKSwgbm9kZSlcbiAgfSxcblxuICBpc1BoeERlc3Ryb3llZChub2RlKXtcbiAgICByZXR1cm4gbm9kZS5pZCAmJiBET00ucHJpdmF0ZShub2RlLCBcImRlc3Ryb3llZFwiKSA/IHRydWUgOiBmYWxzZVxuICB9LFxuXG4gIHdhbnRzTmV3VGFiKGUpe1xuICAgIGxldCB3YW50c05ld1RhYiA9IGUuY3RybEtleSB8fCBlLnNoaWZ0S2V5IHx8IGUubWV0YUtleSB8fCAoZS5idXR0b24gJiYgZS5idXR0b24gPT09IDEpXG4gICAgbGV0IGlzRG93bmxvYWQgPSAoZS50YXJnZXQgaW5zdGFuY2VvZiBIVE1MQW5jaG9yRWxlbWVudCAmJiBlLnRhcmdldC5oYXNBdHRyaWJ1dGUoXCJkb3dubG9hZFwiKSlcbiAgICBsZXQgaXNUYXJnZXRCbGFuayA9IGUudGFyZ2V0Lmhhc0F0dHJpYnV0ZShcInRhcmdldFwiKSAmJiBlLnRhcmdldC5nZXRBdHRyaWJ1dGUoXCJ0YXJnZXRcIikudG9Mb3dlckNhc2UoKSA9PT0gXCJfYmxhbmtcIlxuICAgIGxldCBpc1RhcmdldE5hbWVkVGFiID0gZS50YXJnZXQuaGFzQXR0cmlidXRlKFwidGFyZ2V0XCIpICYmICFlLnRhcmdldC5nZXRBdHRyaWJ1dGUoXCJ0YXJnZXRcIikuc3RhcnRzV2l0aChcIl9cIilcbiAgICByZXR1cm4gd2FudHNOZXdUYWIgfHwgaXNUYXJnZXRCbGFuayB8fCBpc0Rvd25sb2FkIHx8IGlzVGFyZ2V0TmFtZWRUYWJcbiAgfSxcblxuICBpc1VubG9hZGFibGVGb3JtU3VibWl0KGUpe1xuICAgIC8vIElnbm9yZSBmb3JtIHN1Ym1pc3Npb25zIGludGVuZGVkIHRvIGNsb3NlIGEgbmF0aXZlIDxkaWFsb2c+IGVsZW1lbnRcbiAgICAvLyBodHRwczovL2RldmVsb3Blci5tb3ppbGxhLm9yZy9lbi1VUy9kb2NzL1dlYi9IVE1ML0VsZW1lbnQvZGlhbG9nI3VzYWdlX25vdGVzXG4gICAgbGV0IGlzRGlhbG9nU3VibWl0ID0gKGUudGFyZ2V0ICYmIGUudGFyZ2V0LmdldEF0dHJpYnV0ZShcIm1ldGhvZFwiKSA9PT0gXCJkaWFsb2dcIikgfHxcbiAgICAgIChlLnN1Ym1pdHRlciAmJiBlLnN1Ym1pdHRlci5nZXRBdHRyaWJ1dGUoXCJmb3JtbWV0aG9kXCIpID09PSBcImRpYWxvZ1wiKVxuXG4gICAgaWYoaXNEaWFsb2dTdWJtaXQpe1xuICAgICAgcmV0dXJuIGZhbHNlXG4gICAgfSBlbHNlIHtcbiAgICAgIHJldHVybiAhZS5kZWZhdWx0UHJldmVudGVkICYmICF0aGlzLndhbnRzTmV3VGFiKGUpXG4gICAgfVxuICB9LFxuXG4gIGlzTmV3UGFnZUNsaWNrKGUsIGN1cnJlbnRMb2NhdGlvbil7XG4gICAgbGV0IGhyZWYgPSBlLnRhcmdldCBpbnN0YW5jZW9mIEhUTUxBbmNob3JFbGVtZW50ID8gZS50YXJnZXQuZ2V0QXR0cmlidXRlKFwiaHJlZlwiKSA6IG51bGxcbiAgICBsZXQgdXJsXG5cbiAgICBpZihlLmRlZmF1bHRQcmV2ZW50ZWQgfHwgaHJlZiA9PT0gbnVsbCB8fCB0aGlzLndhbnRzTmV3VGFiKGUpKXsgcmV0dXJuIGZhbHNlIH1cbiAgICBpZihocmVmLnN0YXJ0c1dpdGgoXCJtYWlsdG86XCIpIHx8IGhyZWYuc3RhcnRzV2l0aChcInRlbDpcIikpeyByZXR1cm4gZmFsc2UgfVxuICAgIGlmKGUudGFyZ2V0LmlzQ29udGVudEVkaXRhYmxlKXsgcmV0dXJuIGZhbHNlIH1cblxuICAgIHRyeSB7XG4gICAgICB1cmwgPSBuZXcgVVJMKGhyZWYpXG4gICAgfSBjYXRjaChlKSB7XG4gICAgICB0cnkge1xuICAgICAgICB1cmwgPSBuZXcgVVJMKGhyZWYsIGN1cnJlbnRMb2NhdGlvbilcbiAgICAgIH0gY2F0Y2goZSkge1xuICAgICAgICAvLyBiYWQgVVJMLCBmYWxsYmFjayB0byBsZXQgYnJvd3NlciB0cnkgaXQgYXMgZXh0ZXJuYWxcbiAgICAgICAgcmV0dXJuIHRydWVcbiAgICAgIH1cbiAgICB9XG5cbiAgICBpZih1cmwuaG9zdCA9PT0gY3VycmVudExvY2F0aW9uLmhvc3QgJiYgdXJsLnByb3RvY29sID09PSBjdXJyZW50TG9jYXRpb24ucHJvdG9jb2wpe1xuICAgICAgaWYodXJsLnBhdGhuYW1lID09PSBjdXJyZW50TG9jYXRpb24ucGF0aG5hbWUgJiYgdXJsLnNlYXJjaCA9PT0gY3VycmVudExvY2F0aW9uLnNlYXJjaCl7XG4gICAgICAgIHJldHVybiB1cmwuaGFzaCA9PT0gXCJcIiAmJiAhdXJsLmhyZWYuZW5kc1dpdGgoXCIjXCIpXG4gICAgICB9XG4gICAgfVxuICAgIHJldHVybiB1cmwucHJvdG9jb2wuc3RhcnRzV2l0aChcImh0dHBcIilcbiAgfSxcblxuICBtYXJrUGh4Q2hpbGREZXN0cm95ZWQoZWwpe1xuICAgIGlmKHRoaXMuaXNQaHhDaGlsZChlbCkpeyBlbC5zZXRBdHRyaWJ1dGUoUEhYX1NFU1NJT04sIFwiXCIpIH1cbiAgICB0aGlzLnB1dFByaXZhdGUoZWwsIFwiZGVzdHJveWVkXCIsIHRydWUpXG4gIH0sXG5cbiAgZmluZFBoeENoaWxkcmVuSW5GcmFnbWVudChodG1sLCBwYXJlbnRJZCl7XG4gICAgbGV0IHRlbXBsYXRlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcInRlbXBsYXRlXCIpXG4gICAgdGVtcGxhdGUuaW5uZXJIVE1MID0gaHRtbFxuICAgIHJldHVybiB0aGlzLmZpbmRQaHhDaGlsZHJlbih0ZW1wbGF0ZS5jb250ZW50LCBwYXJlbnRJZClcbiAgfSxcblxuICBpc0lnbm9yZWQoZWwsIHBoeFVwZGF0ZSl7XG4gICAgcmV0dXJuIChlbC5nZXRBdHRyaWJ1dGUocGh4VXBkYXRlKSB8fCBlbC5nZXRBdHRyaWJ1dGUoXCJkYXRhLXBoeC11cGRhdGVcIikpID09PSBcImlnbm9yZVwiXG4gIH0sXG5cbiAgaXNQaHhVcGRhdGUoZWwsIHBoeFVwZGF0ZSwgdXBkYXRlVHlwZXMpe1xuICAgIHJldHVybiBlbC5nZXRBdHRyaWJ1dGUgJiYgdXBkYXRlVHlwZXMuaW5kZXhPZihlbC5nZXRBdHRyaWJ1dGUocGh4VXBkYXRlKSkgPj0gMFxuICB9LFxuXG4gIGZpbmRQaHhTdGlja3koZWwpeyByZXR1cm4gdGhpcy5hbGwoZWwsIGBbJHtQSFhfU1RJQ0tZfV1gKSB9LFxuXG4gIGZpbmRQaHhDaGlsZHJlbihlbCwgcGFyZW50SWQpe1xuICAgIHJldHVybiB0aGlzLmFsbChlbCwgYCR7UEhYX1ZJRVdfU0VMRUNUT1J9WyR7UEhYX1BBUkVOVF9JRH09XCIke3BhcmVudElkfVwiXWApXG4gIH0sXG5cbiAgZmluZEV4aXN0aW5nUGFyZW50Q0lEcyhub2RlLCBjaWRzKXtcbiAgICAvLyB3ZSBvbmx5IHdhbnQgdG8gZmluZCBwYXJlbnRzIHRoYXQgZXhpc3Qgb24gdGhlIHBhZ2VcbiAgICAvLyBpZiBhIGNpZCBpcyBub3Qgb24gdGhlIHBhZ2UsIHRoZSBvbmx5IHdheSBpdCBjYW4gYmUgYWRkZWQgYmFjayB0byB0aGUgcGFnZVxuICAgIC8vIGlzIGlmIGEgcGFyZW50IGFkZHMgaXQgYmFjaywgdGhlcmVmb3JlIGlmIGEgY2lkIGRvZXMgbm90IGV4aXN0IG9uIHRoZSBwYWdlLFxuICAgIC8vIHdlIHNob3VsZCBub3QgdHJ5IHRvIHJlbmRlciBpdCBieSBpdHNlbGYgKGJlY2F1c2UgaXQgd291bGQgYmUgcmVuZGVyZWQgdHdpY2UsXG4gICAgLy8gb25lIGJ5IHRoZSBwYXJlbnQsIGFuZCBhIHNlY29uZCB0aW1lIGJ5IGl0c2VsZilcbiAgICBsZXQgcGFyZW50Q2lkcyA9IG5ldyBTZXQoKVxuICAgIGxldCBjaGlsZHJlbkNpZHMgPSBuZXcgU2V0KClcblxuICAgIGNpZHMuZm9yRWFjaChjaWQgPT4ge1xuICAgICAgdGhpcy5maWx0ZXJXaXRoaW5TYW1lTGl2ZVZpZXcodGhpcy5hbGwobm9kZSwgYFske1BIWF9DT01QT05FTlR9PVwiJHtjaWR9XCJdYCksIG5vZGUpLmZvckVhY2gocGFyZW50ID0+IHtcbiAgICAgICAgcGFyZW50Q2lkcy5hZGQoY2lkKVxuICAgICAgICB0aGlzLmFsbChwYXJlbnQsIGBbJHtQSFhfQ09NUE9ORU5UfV1gKVxuICAgICAgICAgIC5tYXAoZWwgPT4gcGFyc2VJbnQoZWwuZ2V0QXR0cmlidXRlKFBIWF9DT01QT05FTlQpKSlcbiAgICAgICAgICAuZm9yRWFjaChjaGlsZENJRCA9PiBjaGlsZHJlbkNpZHMuYWRkKGNoaWxkQ0lEKSlcbiAgICAgIH0pXG4gICAgfSlcblxuICAgIGNoaWxkcmVuQ2lkcy5mb3JFYWNoKGNoaWxkQ2lkID0+IHBhcmVudENpZHMuZGVsZXRlKGNoaWxkQ2lkKSlcblxuICAgIHJldHVybiBwYXJlbnRDaWRzXG4gIH0sXG5cbiAgZmlsdGVyV2l0aGluU2FtZUxpdmVWaWV3KG5vZGVzLCBwYXJlbnQpe1xuICAgIGlmKHBhcmVudC5xdWVyeVNlbGVjdG9yKFBIWF9WSUVXX1NFTEVDVE9SKSl7XG4gICAgICByZXR1cm4gbm9kZXMuZmlsdGVyKGVsID0+IHRoaXMud2l0aGluU2FtZUxpdmVWaWV3KGVsLCBwYXJlbnQpKVxuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gbm9kZXNcbiAgICB9XG4gIH0sXG5cbiAgd2l0aGluU2FtZUxpdmVWaWV3KG5vZGUsIHBhcmVudCl7XG4gICAgd2hpbGUobm9kZSA9IG5vZGUucGFyZW50Tm9kZSl7XG4gICAgICBpZihub2RlLmlzU2FtZU5vZGUocGFyZW50KSl7IHJldHVybiB0cnVlIH1cbiAgICAgIGlmKG5vZGUuZ2V0QXR0cmlidXRlKFBIWF9TRVNTSU9OKSAhPT0gbnVsbCl7IHJldHVybiBmYWxzZSB9XG4gICAgfVxuICB9LFxuXG4gIHByaXZhdGUoZWwsIGtleSl7IHJldHVybiBlbFtQSFhfUFJJVkFURV0gJiYgZWxbUEhYX1BSSVZBVEVdW2tleV0gfSxcblxuICBkZWxldGVQcml2YXRlKGVsLCBrZXkpeyBlbFtQSFhfUFJJVkFURV0gJiYgZGVsZXRlIChlbFtQSFhfUFJJVkFURV1ba2V5XSkgfSxcblxuICBwdXRQcml2YXRlKGVsLCBrZXksIHZhbHVlKXtcbiAgICBpZighZWxbUEhYX1BSSVZBVEVdKXsgZWxbUEhYX1BSSVZBVEVdID0ge30gfVxuICAgIGVsW1BIWF9QUklWQVRFXVtrZXldID0gdmFsdWVcbiAgfSxcblxuICB1cGRhdGVQcml2YXRlKGVsLCBrZXksIGRlZmF1bHRWYWwsIHVwZGF0ZUZ1bmMpe1xuICAgIGxldCBleGlzdGluZyA9IHRoaXMucHJpdmF0ZShlbCwga2V5KVxuICAgIGlmKGV4aXN0aW5nID09PSB1bmRlZmluZWQpe1xuICAgICAgdGhpcy5wdXRQcml2YXRlKGVsLCBrZXksIHVwZGF0ZUZ1bmMoZGVmYXVsdFZhbCkpXG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMucHV0UHJpdmF0ZShlbCwga2V5LCB1cGRhdGVGdW5jKGV4aXN0aW5nKSlcbiAgICB9XG4gIH0sXG5cbiAgY29weVByaXZhdGVzKHRhcmdldCwgc291cmNlKXtcbiAgICBpZihzb3VyY2VbUEhYX1BSSVZBVEVdKXtcbiAgICAgIHRhcmdldFtQSFhfUFJJVkFURV0gPSBzb3VyY2VbUEhYX1BSSVZBVEVdXG4gICAgfVxuICB9LFxuXG4gIHB1dFRpdGxlKHN0cil7XG4gICAgbGV0IHRpdGxlRWwgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yKFwidGl0bGVcIilcbiAgICBpZih0aXRsZUVsKXtcbiAgICAgIGxldCB7cHJlZml4LCBzdWZmaXh9ID0gdGl0bGVFbC5kYXRhc2V0XG4gICAgICBkb2N1bWVudC50aXRsZSA9IGAke3ByZWZpeCB8fCBcIlwifSR7c3RyfSR7c3VmZml4IHx8IFwiXCJ9YFxuICAgIH0gZWxzZSB7XG4gICAgICBkb2N1bWVudC50aXRsZSA9IHN0clxuICAgIH1cbiAgfSxcblxuICBkZWJvdW5jZShlbCwgZXZlbnQsIHBoeERlYm91bmNlLCBkZWZhdWx0RGVib3VuY2UsIHBoeFRocm90dGxlLCBkZWZhdWx0VGhyb3R0bGUsIGFzeW5jRmlsdGVyLCBjYWxsYmFjayl7XG4gICAgbGV0IGRlYm91bmNlID0gZWwuZ2V0QXR0cmlidXRlKHBoeERlYm91bmNlKVxuICAgIGxldCB0aHJvdHRsZSA9IGVsLmdldEF0dHJpYnV0ZShwaHhUaHJvdHRsZSlcblxuICAgIGlmKGRlYm91bmNlID09PSBcIlwiKXsgZGVib3VuY2UgPSBkZWZhdWx0RGVib3VuY2UgfVxuICAgIGlmKHRocm90dGxlID09PSBcIlwiKXsgdGhyb3R0bGUgPSBkZWZhdWx0VGhyb3R0bGUgfVxuICAgIGxldCB2YWx1ZSA9IGRlYm91bmNlIHx8IHRocm90dGxlXG4gICAgc3dpdGNoKHZhbHVlKXtcbiAgICAgIGNhc2UgbnVsbDogcmV0dXJuIGNhbGxiYWNrKClcblxuICAgICAgY2FzZSBcImJsdXJcIjpcbiAgICAgICAgaWYodGhpcy5vbmNlKGVsLCBcImRlYm91bmNlLWJsdXJcIikpe1xuICAgICAgICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoXCJibHVyXCIsICgpID0+IHtcbiAgICAgICAgICAgIGlmKGFzeW5jRmlsdGVyKCkpeyBjYWxsYmFjaygpIH1cbiAgICAgICAgICB9KVxuICAgICAgICB9XG4gICAgICAgIHJldHVyblxuXG4gICAgICBkZWZhdWx0OlxuICAgICAgICBsZXQgdGltZW91dCA9IHBhcnNlSW50KHZhbHVlKVxuICAgICAgICBsZXQgdHJpZ2dlciA9ICgpID0+IHRocm90dGxlID8gdGhpcy5kZWxldGVQcml2YXRlKGVsLCBUSFJPVFRMRUQpIDogY2FsbGJhY2soKVxuICAgICAgICBsZXQgY3VycmVudEN5Y2xlID0gdGhpcy5pbmNDeWNsZShlbCwgREVCT1VOQ0VfVFJJR0dFUiwgdHJpZ2dlcilcbiAgICAgICAgaWYoaXNOYU4odGltZW91dCkpeyByZXR1cm4gbG9nRXJyb3IoYGludmFsaWQgdGhyb3R0bGUvZGVib3VuY2UgdmFsdWU6ICR7dmFsdWV9YCkgfVxuICAgICAgICBpZih0aHJvdHRsZSl7XG4gICAgICAgICAgbGV0IG5ld0tleURvd24gPSBmYWxzZVxuICAgICAgICAgIGlmKGV2ZW50LnR5cGUgPT09IFwia2V5ZG93blwiKXtcbiAgICAgICAgICAgIGxldCBwcmV2S2V5ID0gdGhpcy5wcml2YXRlKGVsLCBERUJPVU5DRV9QUkVWX0tFWSlcbiAgICAgICAgICAgIHRoaXMucHV0UHJpdmF0ZShlbCwgREVCT1VOQ0VfUFJFVl9LRVksIGV2ZW50LmtleSlcbiAgICAgICAgICAgIG5ld0tleURvd24gPSBwcmV2S2V5ICE9PSBldmVudC5rZXlcbiAgICAgICAgICB9XG5cbiAgICAgICAgICBpZighbmV3S2V5RG93biAmJiB0aGlzLnByaXZhdGUoZWwsIFRIUk9UVExFRCkpe1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlXG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGNhbGxiYWNrKClcbiAgICAgICAgICAgIGNvbnN0IHQgPSBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgICAgICAgICAgaWYoYXN5bmNGaWx0ZXIoKSl7IHRoaXMudHJpZ2dlckN5Y2xlKGVsLCBERUJPVU5DRV9UUklHR0VSKSB9XG4gICAgICAgICAgICB9LCB0aW1lb3V0KVxuICAgICAgICAgICAgdGhpcy5wdXRQcml2YXRlKGVsLCBUSFJPVFRMRUQsIHQpXG4gICAgICAgICAgfVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgICAgICAgaWYoYXN5bmNGaWx0ZXIoKSl7IHRoaXMudHJpZ2dlckN5Y2xlKGVsLCBERUJPVU5DRV9UUklHR0VSLCBjdXJyZW50Q3ljbGUpIH1cbiAgICAgICAgICB9LCB0aW1lb3V0KVxuICAgICAgICB9XG5cbiAgICAgICAgbGV0IGZvcm0gPSBlbC5mb3JtXG4gICAgICAgIGlmKGZvcm0gJiYgdGhpcy5vbmNlKGZvcm0sIFwiYmluZC1kZWJvdW5jZVwiKSl7XG4gICAgICAgICAgZm9ybS5hZGRFdmVudExpc3RlbmVyKFwic3VibWl0XCIsICgpID0+IHtcbiAgICAgICAgICAgIEFycmF5LmZyb20oKG5ldyBGb3JtRGF0YShmb3JtKSkuZW50cmllcygpLCAoW25hbWVdKSA9PiB7XG4gICAgICAgICAgICAgIGxldCBpbnB1dCA9IGZvcm0ucXVlcnlTZWxlY3RvcihgW25hbWU9XCIke25hbWV9XCJdYClcbiAgICAgICAgICAgICAgdGhpcy5pbmNDeWNsZShpbnB1dCwgREVCT1VOQ0VfVFJJR0dFUilcbiAgICAgICAgICAgICAgdGhpcy5kZWxldGVQcml2YXRlKGlucHV0LCBUSFJPVFRMRUQpXG4gICAgICAgICAgICB9KVxuICAgICAgICAgIH0pXG4gICAgICAgIH1cbiAgICAgICAgaWYodGhpcy5vbmNlKGVsLCBcImJpbmQtZGVib3VuY2VcIikpe1xuICAgICAgICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoXCJibHVyXCIsICgpID0+IHtcbiAgICAgICAgICAgIC8vIGJlY2F1c2Ugd2UgdHJpZ2dlciB0aGUgY2FsbGJhY2sgaGVyZSxcbiAgICAgICAgICAgIC8vIHdlIGFsc28gY2xlYXIgdGhlIHRocm90dGxlIHRpbWVvdXQgdG8gcHJldmVudCB0aGUgY2FsbGJhY2tcbiAgICAgICAgICAgIC8vIGZyb20gYmVpbmcgY2FsbGVkIGFnYWluIGFmdGVyIHRoZSB0aW1lb3V0IGZpcmVzXG4gICAgICAgICAgICBjbGVhclRpbWVvdXQodGhpcy5wcml2YXRlKGVsLCBUSFJPVFRMRUQpKVxuICAgICAgICAgICAgdGhpcy50cmlnZ2VyQ3ljbGUoZWwsIERFQk9VTkNFX1RSSUdHRVIpXG4gICAgICAgICAgfSlcbiAgICAgICAgfVxuICAgIH1cbiAgfSxcblxuICB0cmlnZ2VyQ3ljbGUoZWwsIGtleSwgY3VycmVudEN5Y2xlKXtcbiAgICBsZXQgW2N5Y2xlLCB0cmlnZ2VyXSA9IHRoaXMucHJpdmF0ZShlbCwga2V5KVxuICAgIGlmKCFjdXJyZW50Q3ljbGUpeyBjdXJyZW50Q3ljbGUgPSBjeWNsZSB9XG4gICAgaWYoY3VycmVudEN5Y2xlID09PSBjeWNsZSl7XG4gICAgICB0aGlzLmluY0N5Y2xlKGVsLCBrZXkpXG4gICAgICB0cmlnZ2VyKClcbiAgICB9XG4gIH0sXG5cbiAgb25jZShlbCwga2V5KXtcbiAgICBpZih0aGlzLnByaXZhdGUoZWwsIGtleSkgPT09IHRydWUpeyByZXR1cm4gZmFsc2UgfVxuICAgIHRoaXMucHV0UHJpdmF0ZShlbCwga2V5LCB0cnVlKVxuICAgIHJldHVybiB0cnVlXG4gIH0sXG5cbiAgaW5jQ3ljbGUoZWwsIGtleSwgdHJpZ2dlciA9IGZ1bmN0aW9uICgpeyB9KXtcbiAgICBsZXQgW2N1cnJlbnRDeWNsZV0gPSB0aGlzLnByaXZhdGUoZWwsIGtleSkgfHwgWzAsIHRyaWdnZXJdXG4gICAgY3VycmVudEN5Y2xlKytcbiAgICB0aGlzLnB1dFByaXZhdGUoZWwsIGtleSwgW2N1cnJlbnRDeWNsZSwgdHJpZ2dlcl0pXG4gICAgcmV0dXJuIGN1cnJlbnRDeWNsZVxuICB9LFxuXG4gIG1heWJlQWRkUHJpdmF0ZUhvb2tzKGVsLCBwaHhWaWV3cG9ydFRvcCwgcGh4Vmlld3BvcnRCb3R0b20pe1xuICAgIGlmKGVsLmhhc0F0dHJpYnV0ZSAmJiAoZWwuaGFzQXR0cmlidXRlKHBoeFZpZXdwb3J0VG9wKSB8fCBlbC5oYXNBdHRyaWJ1dGUocGh4Vmlld3BvcnRCb3R0b20pKSl7XG4gICAgICBlbC5zZXRBdHRyaWJ1dGUoXCJkYXRhLXBoeC1ob29rXCIsIFwiUGhvZW5peC5JbmZpbml0ZVNjcm9sbFwiKVxuICAgIH1cbiAgfSxcblxuICBpc0ZlZWRiYWNrQ29udGFpbmVyKGVsLCBwaHhGZWVkYmFja0Zvcil7XG4gICAgcmV0dXJuIGVsLmhhc0F0dHJpYnV0ZSAmJiBlbC5oYXNBdHRyaWJ1dGUocGh4RmVlZGJhY2tGb3IpXG4gIH0sXG5cbiAgbWF5YmVIaWRlRmVlZGJhY2soY29udGFpbmVyLCBmZWVkYmFja0NvbnRhaW5lcnMsIHBoeEZlZWRiYWNrRm9yLCBwaHhGZWVkYmFja0dyb3VwKXtcbiAgICAvLyBiZWNhdXNlIHdlIGNhbiBoYXZlIG11bHRpcGxlIGNvbnRhaW5lcnMgd2l0aCB0aGUgc2FtZSBwaHhGZWVkYmFja0ZvciB2YWx1ZVxuICAgIC8vIHdlIHBlcmZvcm0gdGhlIGNoZWNrIG9ubHkgb25jZSBhbmQgc3RvcmUgdGhlIHJlc3VsdDtcbiAgICAvLyB3ZSBvZnRlbiBoYXZlIG11bHRpcGxlIGNvbnRhaW5lcnMsIGJlY2F1c2Ugd2UgcHVzaCBib3RoIGZyb21FbCBhbmQgdG9FbCBpbiBkb21wYXRjaFxuICAgIC8vIHdoZW4gYSBjb250YWluZXIgaXMgdXBkYXRlZFxuICAgIGNvbnN0IGZlZWRiYWNrUmVzdWx0cyA9IHt9XG4gICAgZmVlZGJhY2tDb250YWluZXJzLmZvckVhY2goZWwgPT4ge1xuICAgICAgLy8gc2tpcCBlbGVtZW50cyB0aGF0IGFyZSBub3QgaW4gdGhlIERPTVxuICAgICAgaWYoIWNvbnRhaW5lci5jb250YWlucyhlbCkpIHJldHVyblxuICAgICAgY29uc3QgZmVlZGJhY2sgPSBlbC5nZXRBdHRyaWJ1dGUocGh4RmVlZGJhY2tGb3IpXG4gICAgICBpZighZmVlZGJhY2spe1xuICAgICAgICAvLyB0aGUgY29udGFpbmVyIHByZXZpb3VzbHkgaGFkIHBoeC1mZWVkYmFjay1mb3IsIGJ1dCBub3cgaXQgZG9lc24ndFxuICAgICAgICAvLyByZW1vdmUgdGhlIGNsYXNzIGZyb20gdGhlIGNvbnRhaW5lciAoaWYgaXQgZXhpc3RzKVxuICAgICAgICBKUy5hZGRPclJlbW92ZUNsYXNzZXMoZWwsIFtdLCBbUEhYX05PX0ZFRURCQUNLX0NMQVNTXSlcbiAgICAgICAgcmV0dXJuXG4gICAgICB9XG4gICAgICBpZihmZWVkYmFja1Jlc3VsdHNbZmVlZGJhY2tdID09PSB0cnVlKXtcbiAgICAgICAgdGhpcy5oaWRlRmVlZGJhY2soZWwpXG4gICAgICAgIHJldHVyblxuICAgICAgfVxuICAgICAgZmVlZGJhY2tSZXN1bHRzW2ZlZWRiYWNrXSA9IHRoaXMuc2hvdWxkSGlkZUZlZWRiYWNrKGNvbnRhaW5lciwgZmVlZGJhY2ssIHBoeEZlZWRiYWNrR3JvdXApXG4gICAgICBpZihmZWVkYmFja1Jlc3VsdHNbZmVlZGJhY2tdID09PSB0cnVlKXtcbiAgICAgICAgdGhpcy5oaWRlRmVlZGJhY2soZWwpXG4gICAgICB9XG4gICAgfSlcbiAgfSxcblxuICBoaWRlRmVlZGJhY2soY29udGFpbmVyKXtcbiAgICBKUy5hZGRPclJlbW92ZUNsYXNzZXMoY29udGFpbmVyLCBbUEhYX05PX0ZFRURCQUNLX0NMQVNTXSwgW10pXG4gIH0sXG5cbiAgc2hvdWxkSGlkZUZlZWRiYWNrKGNvbnRhaW5lciwgbmFtZU9yR3JvdXAsIHBoeEZlZWRiYWNrR3JvdXApe1xuICAgIGNvbnN0IHF1ZXJ5ID0gYFtuYW1lPVwiJHtuYW1lT3JHcm91cH1cIl0sXG4gICAgICAgICAgICAgICAgICAgW25hbWU9XCIke25hbWVPckdyb3VwfVtdXCJdLFxuICAgICAgICAgICAgICAgICAgIFske3BoeEZlZWRiYWNrR3JvdXB9PVwiJHtuYW1lT3JHcm91cH1cIl1gXG4gICAgbGV0IGZvY3VzZWQgPSBmYWxzZVxuICAgIERPTS5hbGwoY29udGFpbmVyLCBxdWVyeSwgKGlucHV0KSA9PiB7XG4gICAgICBpZih0aGlzLnByaXZhdGUoaW5wdXQsIFBIWF9IQVNfRk9DVVNFRCkgfHwgdGhpcy5wcml2YXRlKGlucHV0LCBQSFhfSEFTX1NVQk1JVFRFRCkpe1xuICAgICAgICBmb2N1c2VkID0gdHJ1ZVxuICAgICAgfVxuICAgIH0pXG4gICAgcmV0dXJuICFmb2N1c2VkXG4gIH0sXG5cbiAgZmVlZGJhY2tTZWxlY3RvcihpbnB1dCwgcGh4RmVlZGJhY2tGb3IsIHBoeEZlZWRiYWNrR3JvdXApe1xuICAgIGxldCBxdWVyeSA9IGBbJHtwaHhGZWVkYmFja0Zvcn09XCIke2lucHV0Lm5hbWV9XCJdLFxuICAgICAgICAgICAgICAgICBbJHtwaHhGZWVkYmFja0Zvcn09XCIke2lucHV0Lm5hbWUucmVwbGFjZSgvXFxbXFxdJC8sIFwiXCIpfVwiXWBcbiAgICBpZihpbnB1dC5nZXRBdHRyaWJ1dGUocGh4RmVlZGJhY2tHcm91cCkpe1xuICAgICAgcXVlcnkgKz0gYCxbJHtwaHhGZWVkYmFja0Zvcn09XCIke2lucHV0LmdldEF0dHJpYnV0ZShwaHhGZWVkYmFja0dyb3VwKX1cIl1gXG4gICAgfVxuICAgIHJldHVybiBxdWVyeVxuICB9LFxuXG4gIHJlc2V0Rm9ybShmb3JtLCBwaHhGZWVkYmFja0ZvciwgcGh4RmVlZGJhY2tHcm91cCl7XG4gICAgQXJyYXkuZnJvbShmb3JtLmVsZW1lbnRzKS5mb3JFYWNoKGlucHV0ID0+IHtcbiAgICAgIGxldCBxdWVyeSA9IHRoaXMuZmVlZGJhY2tTZWxlY3RvcihpbnB1dCwgcGh4RmVlZGJhY2tGb3IsIHBoeEZlZWRiYWNrR3JvdXApXG4gICAgICB0aGlzLmRlbGV0ZVByaXZhdGUoaW5wdXQsIFBIWF9IQVNfRk9DVVNFRClcbiAgICAgIHRoaXMuZGVsZXRlUHJpdmF0ZShpbnB1dCwgUEhYX0hBU19TVUJNSVRURUQpXG4gICAgICB0aGlzLmFsbChkb2N1bWVudCwgcXVlcnksIGZlZWRiYWNrRWwgPT4ge1xuICAgICAgICBKUy5hZGRPclJlbW92ZUNsYXNzZXMoZmVlZGJhY2tFbCwgW1BIWF9OT19GRUVEQkFDS19DTEFTU10sIFtdKVxuICAgICAgfSlcbiAgICB9KVxuICB9LFxuXG4gIHNob3dFcnJvcihpbnB1dEVsLCBwaHhGZWVkYmFja0ZvciwgcGh4RmVlZGJhY2tHcm91cCl7XG4gICAgaWYoaW5wdXRFbC5uYW1lKXtcbiAgICAgIGxldCBxdWVyeSA9IHRoaXMuZmVlZGJhY2tTZWxlY3RvcihpbnB1dEVsLCBwaHhGZWVkYmFja0ZvciwgcGh4RmVlZGJhY2tHcm91cClcbiAgICAgIHRoaXMuYWxsKGRvY3VtZW50LCBxdWVyeSwgKGVsKSA9PiB7XG4gICAgICAgIEpTLmFkZE9yUmVtb3ZlQ2xhc3NlcyhlbCwgW10sIFtQSFhfTk9fRkVFREJBQ0tfQ0xBU1NdKVxuICAgICAgfSlcbiAgICB9XG4gIH0sXG5cbiAgaXNQaHhDaGlsZChub2RlKXtcbiAgICByZXR1cm4gbm9kZS5nZXRBdHRyaWJ1dGUgJiYgbm9kZS5nZXRBdHRyaWJ1dGUoUEhYX1BBUkVOVF9JRClcbiAgfSxcblxuICBpc1BoeFN0aWNreShub2RlKXtcbiAgICByZXR1cm4gbm9kZS5nZXRBdHRyaWJ1dGUgJiYgbm9kZS5nZXRBdHRyaWJ1dGUoUEhYX1NUSUNLWSkgIT09IG51bGxcbiAgfSxcblxuICBpc0NoaWxkT2ZBbnkoZWwsIHBhcmVudHMpe1xuICAgIHJldHVybiAhIXBhcmVudHMuZmluZChwYXJlbnQgPT4gcGFyZW50LmNvbnRhaW5zKGVsKSlcbiAgfSxcblxuICBmaXJzdFBoeENoaWxkKGVsKXtcbiAgICByZXR1cm4gdGhpcy5pc1BoeENoaWxkKGVsKSA/IGVsIDogdGhpcy5hbGwoZWwsIGBbJHtQSFhfUEFSRU5UX0lEfV1gKVswXVxuICB9LFxuXG4gIGRpc3BhdGNoRXZlbnQodGFyZ2V0LCBuYW1lLCBvcHRzID0ge30pe1xuICAgIGxldCBkZWZhdWx0QnViYmxlID0gdHJ1ZVxuICAgIGxldCBpc1VwbG9hZFRhcmdldCA9IHRhcmdldC5ub2RlTmFtZSA9PT0gXCJJTlBVVFwiICYmIHRhcmdldC50eXBlID09PSBcImZpbGVcIlxuICAgIGlmKGlzVXBsb2FkVGFyZ2V0ICYmIG5hbWUgPT09IFwiY2xpY2tcIil7XG4gICAgICBkZWZhdWx0QnViYmxlID0gZmFsc2VcbiAgICB9XG4gICAgbGV0IGJ1YmJsZXMgPSBvcHRzLmJ1YmJsZXMgPT09IHVuZGVmaW5lZCA/IGRlZmF1bHRCdWJibGUgOiAhIW9wdHMuYnViYmxlc1xuICAgIGxldCBldmVudE9wdHMgPSB7YnViYmxlczogYnViYmxlcywgY2FuY2VsYWJsZTogdHJ1ZSwgZGV0YWlsOiBvcHRzLmRldGFpbCB8fCB7fX1cbiAgICBsZXQgZXZlbnQgPSBuYW1lID09PSBcImNsaWNrXCIgPyBuZXcgTW91c2VFdmVudChcImNsaWNrXCIsIGV2ZW50T3B0cykgOiBuZXcgQ3VzdG9tRXZlbnQobmFtZSwgZXZlbnRPcHRzKVxuICAgIHRhcmdldC5kaXNwYXRjaEV2ZW50KGV2ZW50KVxuICB9LFxuXG4gIGNsb25lTm9kZShub2RlLCBodG1sKXtcbiAgICBpZih0eXBlb2YgKGh0bWwpID09PSBcInVuZGVmaW5lZFwiKXtcbiAgICAgIHJldHVybiBub2RlLmNsb25lTm9kZSh0cnVlKVxuICAgIH0gZWxzZSB7XG4gICAgICBsZXQgY2xvbmVkID0gbm9kZS5jbG9uZU5vZGUoZmFsc2UpXG4gICAgICBjbG9uZWQuaW5uZXJIVE1MID0gaHRtbFxuICAgICAgcmV0dXJuIGNsb25lZFxuICAgIH1cbiAgfSxcblxuICAvLyBtZXJnZSBhdHRyaWJ1dGVzIGZyb20gc291cmNlIHRvIHRhcmdldFxuICAvLyBpZiBhbiBlbGVtZW50IGlzIGlnbm9yZWQsIHdlIG9ubHkgbWVyZ2UgZGF0YSBhdHRyaWJ1dGVzXG4gIC8vIGluY2x1ZGluZyByZW1vdmluZyBkYXRhIGF0dHJpYnV0ZXMgdGhhdCBhcmUgbm8gbG9uZ2VyIGluIHRoZSBzb3VyY2VcbiAgbWVyZ2VBdHRycyh0YXJnZXQsIHNvdXJjZSwgb3B0cyA9IHt9KXtcbiAgICBsZXQgZXhjbHVkZSA9IG5ldyBTZXQob3B0cy5leGNsdWRlIHx8IFtdKVxuICAgIGxldCBpc0lnbm9yZWQgPSBvcHRzLmlzSWdub3JlZFxuICAgIGxldCBzb3VyY2VBdHRycyA9IHNvdXJjZS5hdHRyaWJ1dGVzXG4gICAgZm9yKGxldCBpID0gc291cmNlQXR0cnMubGVuZ3RoIC0gMTsgaSA+PSAwOyBpLS0pe1xuICAgICAgbGV0IG5hbWUgPSBzb3VyY2VBdHRyc1tpXS5uYW1lXG4gICAgICBpZighZXhjbHVkZS5oYXMobmFtZSkpe1xuICAgICAgICBjb25zdCBzb3VyY2VWYWx1ZSA9IHNvdXJjZS5nZXRBdHRyaWJ1dGUobmFtZSlcbiAgICAgICAgaWYodGFyZ2V0LmdldEF0dHJpYnV0ZShuYW1lKSAhPT0gc291cmNlVmFsdWUgJiYgKCFpc0lnbm9yZWQgfHwgKGlzSWdub3JlZCAmJiBuYW1lLnN0YXJ0c1dpdGgoXCJkYXRhLVwiKSkpKXtcbiAgICAgICAgICB0YXJnZXQuc2V0QXR0cmlidXRlKG5hbWUsIHNvdXJjZVZhbHVlKVxuICAgICAgICB9XG4gICAgICB9IGVsc2Uge1xuICAgICAgICAvLyBXZSBleGNsdWRlIHRoZSB2YWx1ZSBmcm9tIGJlaW5nIG1lcmdlZCBvbiBmb2N1c2VkIGlucHV0cywgYmVjYXVzZSB0aGVcbiAgICAgICAgLy8gdXNlcidzIGlucHV0IHNob3VsZCBhbHdheXMgd2luLlxuICAgICAgICAvLyBXZSBjYW4gc3RpbGwgYXNzaWduIGl0IGFzIGxvbmcgYXMgdGhlIHZhbHVlIHByb3BlcnR5IGlzIHRoZSBzYW1lLCB0aG91Z2guXG4gICAgICAgIC8vIFRoaXMgcHJldmVudHMgYSBzaXR1YXRpb24gd2hlcmUgdGhlIHVwZGF0ZWQgaG9vayBpcyBub3QgYmVpbmcgdHJpZ2dlcmVkXG4gICAgICAgIC8vIHdoZW4gYW4gaW5wdXQgaXMgYmFjayBpbiBpdHMgXCJvcmlnaW5hbCBzdGF0ZVwiLCBiZWNhdXNlIHRoZSBhdHRyaWJ1dGVcbiAgICAgICAgLy8gd2FzIG5ldmVyIGNoYW5nZWQsIHNlZTpcbiAgICAgICAgLy8gaHR0cHM6Ly9naXRodWIuY29tL3Bob2VuaXhmcmFtZXdvcmsvcGhvZW5peF9saXZlX3ZpZXcvaXNzdWVzLzIxNjNcbiAgICAgICAgaWYobmFtZSA9PT0gXCJ2YWx1ZVwiICYmIHRhcmdldC52YWx1ZSA9PT0gc291cmNlLnZhbHVlKXtcbiAgICAgICAgICAvLyBhY3R1YWxseSBzZXQgdGhlIHZhbHVlIGF0dHJpYnV0ZSB0byBzeW5jIGl0IHdpdGggdGhlIHZhbHVlIHByb3BlcnR5XG4gICAgICAgICAgdGFyZ2V0LnNldEF0dHJpYnV0ZShcInZhbHVlXCIsIHNvdXJjZS5nZXRBdHRyaWJ1dGUobmFtZSkpXG4gICAgICAgIH1cbiAgICAgIH1cbiAgICB9XG5cbiAgICBsZXQgdGFyZ2V0QXR0cnMgPSB0YXJnZXQuYXR0cmlidXRlc1xuICAgIGZvcihsZXQgaSA9IHRhcmdldEF0dHJzLmxlbmd0aCAtIDE7IGkgPj0gMDsgaS0tKXtcbiAgICAgIGxldCBuYW1lID0gdGFyZ2V0QXR0cnNbaV0ubmFtZVxuICAgICAgaWYoaXNJZ25vcmVkKXtcbiAgICAgICAgaWYobmFtZS5zdGFydHNXaXRoKFwiZGF0YS1cIikgJiYgIXNvdXJjZS5oYXNBdHRyaWJ1dGUobmFtZSkgJiYgIVtQSFhfUkVGLCBQSFhfUkVGX1NSQ10uaW5jbHVkZXMobmFtZSkpeyB0YXJnZXQucmVtb3ZlQXR0cmlidXRlKG5hbWUpIH1cbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIGlmKCFzb3VyY2UuaGFzQXR0cmlidXRlKG5hbWUpKXsgdGFyZ2V0LnJlbW92ZUF0dHJpYnV0ZShuYW1lKSB9XG4gICAgICB9XG4gICAgfVxuICB9LFxuXG4gIG1lcmdlRm9jdXNlZElucHV0KHRhcmdldCwgc291cmNlKXtcbiAgICAvLyBza2lwIHNlbGVjdHMgYmVjYXVzZSBGRiB3aWxsIHJlc2V0IGhpZ2hsaWdodGVkIGluZGV4IGZvciBhbnkgc2V0QXR0cmlidXRlXG4gICAgaWYoISh0YXJnZXQgaW5zdGFuY2VvZiBIVE1MU2VsZWN0RWxlbWVudCkpeyBET00ubWVyZ2VBdHRycyh0YXJnZXQsIHNvdXJjZSwge2V4Y2x1ZGU6IFtcInZhbHVlXCJdfSkgfVxuXG4gICAgaWYoc291cmNlLnJlYWRPbmx5KXtcbiAgICAgIHRhcmdldC5zZXRBdHRyaWJ1dGUoXCJyZWFkb25seVwiLCB0cnVlKVxuICAgIH0gZWxzZSB7XG4gICAgICB0YXJnZXQucmVtb3ZlQXR0cmlidXRlKFwicmVhZG9ubHlcIilcbiAgICB9XG4gIH0sXG5cbiAgaGFzU2VsZWN0aW9uUmFuZ2UoZWwpe1xuICAgIHJldHVybiBlbC5zZXRTZWxlY3Rpb25SYW5nZSAmJiAoZWwudHlwZSA9PT0gXCJ0ZXh0XCIgfHwgZWwudHlwZSA9PT0gXCJ0ZXh0YXJlYVwiKVxuICB9LFxuXG4gIHJlc3RvcmVGb2N1cyhmb2N1c2VkLCBzZWxlY3Rpb25TdGFydCwgc2VsZWN0aW9uRW5kKXtcbiAgICBpZihmb2N1c2VkIGluc3RhbmNlb2YgSFRNTFNlbGVjdEVsZW1lbnQpeyBmb2N1c2VkLmZvY3VzKCkgfVxuICAgIGlmKCFET00uaXNUZXh0dWFsSW5wdXQoZm9jdXNlZCkpeyByZXR1cm4gfVxuXG4gICAgbGV0IHdhc0ZvY3VzZWQgPSBmb2N1c2VkLm1hdGNoZXMoXCI6Zm9jdXNcIilcbiAgICBpZighd2FzRm9jdXNlZCl7IGZvY3VzZWQuZm9jdXMoKSB9XG4gICAgaWYodGhpcy5oYXNTZWxlY3Rpb25SYW5nZShmb2N1c2VkKSl7XG4gICAgICBmb2N1c2VkLnNldFNlbGVjdGlvblJhbmdlKHNlbGVjdGlvblN0YXJ0LCBzZWxlY3Rpb25FbmQpXG4gICAgfVxuICB9LFxuXG4gIGlzRm9ybUlucHV0KGVsKXsgcmV0dXJuIC9eKD86aW5wdXR8c2VsZWN0fHRleHRhcmVhKSQvaS50ZXN0KGVsLnRhZ05hbWUpICYmIGVsLnR5cGUgIT09IFwiYnV0dG9uXCIgfSxcblxuICBzeW5jQXR0cnNUb1Byb3BzKGVsKXtcbiAgICBpZihlbCBpbnN0YW5jZW9mIEhUTUxJbnB1dEVsZW1lbnQgJiYgQ0hFQ0tBQkxFX0lOUFVUUy5pbmRleE9mKGVsLnR5cGUudG9Mb2NhbGVMb3dlckNhc2UoKSkgPj0gMCl7XG4gICAgICBlbC5jaGVja2VkID0gZWwuZ2V0QXR0cmlidXRlKFwiY2hlY2tlZFwiKSAhPT0gbnVsbFxuICAgIH1cbiAgfSxcblxuICBpc1RleHR1YWxJbnB1dChlbCl7IHJldHVybiBGT0NVU0FCTEVfSU5QVVRTLmluZGV4T2YoZWwudHlwZSkgPj0gMCB9LFxuXG4gIGlzTm93VHJpZ2dlckZvcm1FeHRlcm5hbChlbCwgcGh4VHJpZ2dlckV4dGVybmFsKXtcbiAgICByZXR1cm4gZWwuZ2V0QXR0cmlidXRlICYmIGVsLmdldEF0dHJpYnV0ZShwaHhUcmlnZ2VyRXh0ZXJuYWwpICE9PSBudWxsXG4gIH0sXG5cbiAgc3luY1BlbmRpbmdSZWYoZnJvbUVsLCB0b0VsLCBkaXNhYmxlV2l0aCl7XG4gICAgbGV0IHJlZiA9IGZyb21FbC5nZXRBdHRyaWJ1dGUoUEhYX1JFRilcbiAgICBpZihyZWYgPT09IG51bGwpeyByZXR1cm4gdHJ1ZSB9XG4gICAgbGV0IHJlZlNyYyA9IGZyb21FbC5nZXRBdHRyaWJ1dGUoUEhYX1JFRl9TUkMpXG5cbiAgICBpZihET00uaXNGb3JtSW5wdXQoZnJvbUVsKSB8fCBmcm9tRWwuZ2V0QXR0cmlidXRlKGRpc2FibGVXaXRoKSAhPT0gbnVsbCl7XG4gICAgICBpZihET00uaXNVcGxvYWRJbnB1dChmcm9tRWwpKXsgRE9NLm1lcmdlQXR0cnMoZnJvbUVsLCB0b0VsLCB7aXNJZ25vcmVkOiB0cnVlfSkgfVxuICAgICAgRE9NLnB1dFByaXZhdGUoZnJvbUVsLCBQSFhfUkVGLCB0b0VsKVxuICAgICAgcmV0dXJuIGZhbHNlXG4gICAgfSBlbHNlIHtcbiAgICAgIFBIWF9FVkVOVF9DTEFTU0VTLmZvckVhY2goY2xhc3NOYW1lID0+IHtcbiAgICAgICAgZnJvbUVsLmNsYXNzTGlzdC5jb250YWlucyhjbGFzc05hbWUpICYmIHRvRWwuY2xhc3NMaXN0LmFkZChjbGFzc05hbWUpXG4gICAgICB9KVxuICAgICAgdG9FbC5zZXRBdHRyaWJ1dGUoUEhYX1JFRiwgcmVmKVxuICAgICAgdG9FbC5zZXRBdHRyaWJ1dGUoUEhYX1JFRl9TUkMsIHJlZlNyYylcbiAgICAgIHJldHVybiB0cnVlXG4gICAgfVxuICB9LFxuXG4gIGNsZWFuQ2hpbGROb2Rlcyhjb250YWluZXIsIHBoeFVwZGF0ZSl7XG4gICAgaWYoRE9NLmlzUGh4VXBkYXRlKGNvbnRhaW5lciwgcGh4VXBkYXRlLCBbXCJhcHBlbmRcIiwgXCJwcmVwZW5kXCJdKSl7XG4gICAgICBsZXQgdG9SZW1vdmUgPSBbXVxuICAgICAgY29udGFpbmVyLmNoaWxkTm9kZXMuZm9yRWFjaChjaGlsZE5vZGUgPT4ge1xuICAgICAgICBpZighY2hpbGROb2RlLmlkKXtcbiAgICAgICAgICAvLyBTa2lwIHdhcm5pbmcgaWYgaXQncyBhbiBlbXB0eSB0ZXh0IG5vZGUgKGUuZy4gYSBuZXctbGluZSlcbiAgICAgICAgICBsZXQgaXNFbXB0eVRleHROb2RlID0gY2hpbGROb2RlLm5vZGVUeXBlID09PSBOb2RlLlRFWFRfTk9ERSAmJiBjaGlsZE5vZGUubm9kZVZhbHVlLnRyaW0oKSA9PT0gXCJcIlxuICAgICAgICAgIGlmKCFpc0VtcHR5VGV4dE5vZGUgJiYgY2hpbGROb2RlLm5vZGVUeXBlICE9PSBOb2RlLkNPTU1FTlRfTk9ERSl7XG4gICAgICAgICAgICBsb2dFcnJvcihcIm9ubHkgSFRNTCBlbGVtZW50IHRhZ3Mgd2l0aCBhbiBpZCBhcmUgYWxsb3dlZCBpbnNpZGUgY29udGFpbmVycyB3aXRoIHBoeC11cGRhdGUuXFxuXFxuXCIgK1xuICAgICAgICAgICAgICBgcmVtb3ZpbmcgaWxsZWdhbCBub2RlOiBcIiR7KGNoaWxkTm9kZS5vdXRlckhUTUwgfHwgY2hpbGROb2RlLm5vZGVWYWx1ZSkudHJpbSgpfVwiXFxuXFxuYClcbiAgICAgICAgICB9XG4gICAgICAgICAgdG9SZW1vdmUucHVzaChjaGlsZE5vZGUpXG4gICAgICAgIH1cbiAgICAgIH0pXG4gICAgICB0b1JlbW92ZS5mb3JFYWNoKGNoaWxkTm9kZSA9PiBjaGlsZE5vZGUucmVtb3ZlKCkpXG4gICAgfVxuICB9LFxuXG4gIHJlcGxhY2VSb290Q29udGFpbmVyKGNvbnRhaW5lciwgdGFnTmFtZSwgYXR0cnMpe1xuICAgIGxldCByZXRhaW5lZEF0dHJzID0gbmV3IFNldChbXCJpZFwiLCBQSFhfU0VTU0lPTiwgUEhYX1NUQVRJQywgUEhYX01BSU4sIFBIWF9ST09UX0lEXSlcbiAgICBpZihjb250YWluZXIudGFnTmFtZS50b0xvd2VyQ2FzZSgpID09PSB0YWdOYW1lLnRvTG93ZXJDYXNlKCkpe1xuICAgICAgQXJyYXkuZnJvbShjb250YWluZXIuYXR0cmlidXRlcylcbiAgICAgICAgLmZpbHRlcihhdHRyID0+ICFyZXRhaW5lZEF0dHJzLmhhcyhhdHRyLm5hbWUudG9Mb3dlckNhc2UoKSkpXG4gICAgICAgIC5mb3JFYWNoKGF0dHIgPT4gY29udGFpbmVyLnJlbW92ZUF0dHJpYnV0ZShhdHRyLm5hbWUpKVxuXG4gICAgICBPYmplY3Qua2V5cyhhdHRycylcbiAgICAgICAgLmZpbHRlcihuYW1lID0+ICFyZXRhaW5lZEF0dHJzLmhhcyhuYW1lLnRvTG93ZXJDYXNlKCkpKVxuICAgICAgICAuZm9yRWFjaChhdHRyID0+IGNvbnRhaW5lci5zZXRBdHRyaWJ1dGUoYXR0ciwgYXR0cnNbYXR0cl0pKVxuXG4gICAgICByZXR1cm4gY29udGFpbmVyXG5cbiAgICB9IGVsc2Uge1xuICAgICAgbGV0IG5ld0NvbnRhaW5lciA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQodGFnTmFtZSlcbiAgICAgIE9iamVjdC5rZXlzKGF0dHJzKS5mb3JFYWNoKGF0dHIgPT4gbmV3Q29udGFpbmVyLnNldEF0dHJpYnV0ZShhdHRyLCBhdHRyc1thdHRyXSkpXG4gICAgICByZXRhaW5lZEF0dHJzLmZvckVhY2goYXR0ciA9PiBuZXdDb250YWluZXIuc2V0QXR0cmlidXRlKGF0dHIsIGNvbnRhaW5lci5nZXRBdHRyaWJ1dGUoYXR0cikpKVxuICAgICAgbmV3Q29udGFpbmVyLmlubmVySFRNTCA9IGNvbnRhaW5lci5pbm5lckhUTUxcbiAgICAgIGNvbnRhaW5lci5yZXBsYWNlV2l0aChuZXdDb250YWluZXIpXG4gICAgICByZXR1cm4gbmV3Q29udGFpbmVyXG4gICAgfVxuICB9LFxuXG4gIGdldFN0aWNreShlbCwgbmFtZSwgZGVmYXVsdFZhbCl7XG4gICAgbGV0IG9wID0gKERPTS5wcml2YXRlKGVsLCBcInN0aWNreVwiKSB8fCBbXSkuZmluZCgoW2V4aXN0aW5nTmFtZSwgXSkgPT4gbmFtZSA9PT0gZXhpc3RpbmdOYW1lKVxuICAgIGlmKG9wKXtcbiAgICAgIGxldCBbX25hbWUsIF9vcCwgc3Rhc2hlZFJlc3VsdF0gPSBvcFxuICAgICAgcmV0dXJuIHN0YXNoZWRSZXN1bHRcbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuIHR5cGVvZihkZWZhdWx0VmFsKSA9PT0gXCJmdW5jdGlvblwiID8gZGVmYXVsdFZhbCgpIDogZGVmYXVsdFZhbFxuICAgIH1cbiAgfSxcblxuICBkZWxldGVTdGlja3koZWwsIG5hbWUpe1xuICAgIHRoaXMudXBkYXRlUHJpdmF0ZShlbCwgXCJzdGlja3lcIiwgW10sIG9wcyA9PiB7XG4gICAgICByZXR1cm4gb3BzLmZpbHRlcigoW2V4aXN0aW5nTmFtZSwgX10pID0+IGV4aXN0aW5nTmFtZSAhPT0gbmFtZSlcbiAgICB9KVxuICB9LFxuXG4gIHB1dFN0aWNreShlbCwgbmFtZSwgb3Ape1xuICAgIGxldCBzdGFzaGVkUmVzdWx0ID0gb3AoZWwpXG4gICAgdGhpcy51cGRhdGVQcml2YXRlKGVsLCBcInN0aWNreVwiLCBbXSwgb3BzID0+IHtcbiAgICAgIGxldCBleGlzdGluZ0luZGV4ID0gb3BzLmZpbmRJbmRleCgoW2V4aXN0aW5nTmFtZSwgXSkgPT4gbmFtZSA9PT0gZXhpc3RpbmdOYW1lKVxuICAgICAgaWYoZXhpc3RpbmdJbmRleCA+PSAwKXtcbiAgICAgICAgb3BzW2V4aXN0aW5nSW5kZXhdID0gW25hbWUsIG9wLCBzdGFzaGVkUmVzdWx0XVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgb3BzLnB1c2goW25hbWUsIG9wLCBzdGFzaGVkUmVzdWx0XSlcbiAgICAgIH1cbiAgICAgIHJldHVybiBvcHNcbiAgICB9KVxuICB9LFxuXG4gIGFwcGx5U3RpY2t5T3BlcmF0aW9ucyhlbCl7XG4gICAgbGV0IG9wcyA9IERPTS5wcml2YXRlKGVsLCBcInN0aWNreVwiKVxuICAgIGlmKCFvcHMpeyByZXR1cm4gfVxuXG4gICAgb3BzLmZvckVhY2goKFtuYW1lLCBvcCwgX3N0YXNoZWRdKSA9PiB0aGlzLnB1dFN0aWNreShlbCwgbmFtZSwgb3ApKVxuICB9XG59XG5cbmV4cG9ydCBkZWZhdWx0IERPTVxuIiwgImltcG9ydCB7XG4gIFBIWF9BQ1RJVkVfRU5UUllfUkVGUyxcbiAgUEhYX0xJVkVfRklMRV9VUERBVEVELFxuICBQSFhfUFJFRkxJR0hURURfUkVGU1xufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5pbXBvcnQge1xuICBjaGFubmVsVXBsb2FkZXIsXG4gIGxvZ0Vycm9yXG59IGZyb20gXCIuL3V0aWxzXCJcblxuaW1wb3J0IExpdmVVcGxvYWRlciBmcm9tIFwiLi9saXZlX3VwbG9hZGVyXCJcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgVXBsb2FkRW50cnkge1xuICBzdGF0aWMgaXNBY3RpdmUoZmlsZUVsLCBmaWxlKXtcbiAgICBsZXQgaXNOZXcgPSBmaWxlLl9waHhSZWYgPT09IHVuZGVmaW5lZFxuICAgIGxldCBhY3RpdmVSZWZzID0gZmlsZUVsLmdldEF0dHJpYnV0ZShQSFhfQUNUSVZFX0VOVFJZX1JFRlMpLnNwbGl0KFwiLFwiKVxuICAgIGxldCBpc0FjdGl2ZSA9IGFjdGl2ZVJlZnMuaW5kZXhPZihMaXZlVXBsb2FkZXIuZ2VuRmlsZVJlZihmaWxlKSkgPj0gMFxuICAgIHJldHVybiBmaWxlLnNpemUgPiAwICYmIChpc05ldyB8fCBpc0FjdGl2ZSlcbiAgfVxuXG4gIHN0YXRpYyBpc1ByZWZsaWdodGVkKGZpbGVFbCwgZmlsZSl7XG4gICAgbGV0IHByZWZsaWdodGVkUmVmcyA9IGZpbGVFbC5nZXRBdHRyaWJ1dGUoUEhYX1BSRUZMSUdIVEVEX1JFRlMpLnNwbGl0KFwiLFwiKVxuICAgIGxldCBpc1ByZWZsaWdodGVkID0gcHJlZmxpZ2h0ZWRSZWZzLmluZGV4T2YoTGl2ZVVwbG9hZGVyLmdlbkZpbGVSZWYoZmlsZSkpID49IDBcbiAgICByZXR1cm4gaXNQcmVmbGlnaHRlZCAmJiB0aGlzLmlzQWN0aXZlKGZpbGVFbCwgZmlsZSlcbiAgfVxuXG4gIHN0YXRpYyBpc1ByZWZsaWdodEluUHJvZ3Jlc3MoZmlsZSl7XG4gICAgcmV0dXJuIGZpbGUuX3ByZWZsaWdodEluUHJvZ3Jlc3MgPT09IHRydWVcbiAgfVxuXG4gIHN0YXRpYyBtYXJrUHJlZmxpZ2h0SW5Qcm9ncmVzcyhmaWxlKXtcbiAgICBmaWxlLl9wcmVmbGlnaHRJblByb2dyZXNzID0gdHJ1ZVxuICB9XG5cbiAgY29uc3RydWN0b3IoZmlsZUVsLCBmaWxlLCB2aWV3LCBhdXRvVXBsb2FkKXtcbiAgICB0aGlzLnJlZiA9IExpdmVVcGxvYWRlci5nZW5GaWxlUmVmKGZpbGUpXG4gICAgdGhpcy5maWxlRWwgPSBmaWxlRWxcbiAgICB0aGlzLmZpbGUgPSBmaWxlXG4gICAgdGhpcy52aWV3ID0gdmlld1xuICAgIHRoaXMubWV0YSA9IG51bGxcbiAgICB0aGlzLl9pc0NhbmNlbGxlZCA9IGZhbHNlXG4gICAgdGhpcy5faXNEb25lID0gZmFsc2VcbiAgICB0aGlzLl9wcm9ncmVzcyA9IDBcbiAgICB0aGlzLl9sYXN0UHJvZ3Jlc3NTZW50ID0gLTFcbiAgICB0aGlzLl9vbkRvbmUgPSBmdW5jdGlvbigpeyB9XG4gICAgdGhpcy5fb25FbFVwZGF0ZWQgPSB0aGlzLm9uRWxVcGRhdGVkLmJpbmQodGhpcylcbiAgICB0aGlzLmZpbGVFbC5hZGRFdmVudExpc3RlbmVyKFBIWF9MSVZFX0ZJTEVfVVBEQVRFRCwgdGhpcy5fb25FbFVwZGF0ZWQpXG4gICAgdGhpcy5hdXRvVXBsb2FkID0gYXV0b1VwbG9hZFxuICB9XG5cbiAgbWV0YWRhdGEoKXsgcmV0dXJuIHRoaXMubWV0YSB9XG5cbiAgcHJvZ3Jlc3MocHJvZ3Jlc3Mpe1xuICAgIHRoaXMuX3Byb2dyZXNzID0gTWF0aC5mbG9vcihwcm9ncmVzcylcbiAgICBpZih0aGlzLl9wcm9ncmVzcyA+IHRoaXMuX2xhc3RQcm9ncmVzc1NlbnQpe1xuICAgICAgaWYodGhpcy5fcHJvZ3Jlc3MgPj0gMTAwKXtcbiAgICAgICAgdGhpcy5fcHJvZ3Jlc3MgPSAxMDBcbiAgICAgICAgdGhpcy5fbGFzdFByb2dyZXNzU2VudCA9IDEwMFxuICAgICAgICB0aGlzLl9pc0RvbmUgPSB0cnVlXG4gICAgICAgIHRoaXMudmlldy5wdXNoRmlsZVByb2dyZXNzKHRoaXMuZmlsZUVsLCB0aGlzLnJlZiwgMTAwLCAoKSA9PiB7XG4gICAgICAgICAgTGl2ZVVwbG9hZGVyLnVudHJhY2tGaWxlKHRoaXMuZmlsZUVsLCB0aGlzLmZpbGUpXG4gICAgICAgICAgdGhpcy5fb25Eb25lKClcbiAgICAgICAgfSlcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHRoaXMuX2xhc3RQcm9ncmVzc1NlbnQgPSB0aGlzLl9wcm9ncmVzc1xuICAgICAgICB0aGlzLnZpZXcucHVzaEZpbGVQcm9ncmVzcyh0aGlzLmZpbGVFbCwgdGhpcy5yZWYsIHRoaXMuX3Byb2dyZXNzKVxuICAgICAgfVxuICAgIH1cbiAgfVxuXG4gIGlzQ2FuY2VsbGVkKCl7IHJldHVybiB0aGlzLl9pc0NhbmNlbGxlZCB9XG5cbiAgY2FuY2VsKCl7XG4gICAgdGhpcy5maWxlLl9wcmVmbGlnaHRJblByb2dyZXNzID0gZmFsc2VcbiAgICB0aGlzLl9pc0NhbmNlbGxlZCA9IHRydWVcbiAgICB0aGlzLl9pc0RvbmUgPSB0cnVlXG4gICAgdGhpcy5fb25Eb25lKClcbiAgfVxuXG4gIGlzRG9uZSgpeyByZXR1cm4gdGhpcy5faXNEb25lIH1cblxuICBlcnJvcihyZWFzb24gPSBcImZhaWxlZFwiKXtcbiAgICB0aGlzLmZpbGVFbC5yZW1vdmVFdmVudExpc3RlbmVyKFBIWF9MSVZFX0ZJTEVfVVBEQVRFRCwgdGhpcy5fb25FbFVwZGF0ZWQpXG4gICAgdGhpcy52aWV3LnB1c2hGaWxlUHJvZ3Jlc3ModGhpcy5maWxlRWwsIHRoaXMucmVmLCB7ZXJyb3I6IHJlYXNvbn0pXG4gICAgaWYoIXRoaXMuaXNBdXRvVXBsb2FkKCkpeyBMaXZlVXBsb2FkZXIuY2xlYXJGaWxlcyh0aGlzLmZpbGVFbCkgfVxuICB9XG5cbiAgaXNBdXRvVXBsb2FkKCl7IHJldHVybiB0aGlzLmF1dG9VcGxvYWQgfVxuXG4gIC8vcHJpdmF0ZVxuXG4gIG9uRG9uZShjYWxsYmFjayl7XG4gICAgdGhpcy5fb25Eb25lID0gKCkgPT4ge1xuICAgICAgdGhpcy5maWxlRWwucmVtb3ZlRXZlbnRMaXN0ZW5lcihQSFhfTElWRV9GSUxFX1VQREFURUQsIHRoaXMuX29uRWxVcGRhdGVkKVxuICAgICAgY2FsbGJhY2soKVxuICAgIH1cbiAgfVxuXG4gIG9uRWxVcGRhdGVkKCl7XG4gICAgbGV0IGFjdGl2ZVJlZnMgPSB0aGlzLmZpbGVFbC5nZXRBdHRyaWJ1dGUoUEhYX0FDVElWRV9FTlRSWV9SRUZTKS5zcGxpdChcIixcIilcbiAgICBpZihhY3RpdmVSZWZzLmluZGV4T2YodGhpcy5yZWYpID09PSAtMSl7XG4gICAgICBMaXZlVXBsb2FkZXIudW50cmFja0ZpbGUodGhpcy5maWxlRWwsIHRoaXMuZmlsZSlcbiAgICAgIHRoaXMuY2FuY2VsKClcbiAgICB9XG4gIH1cblxuICB0b1ByZWZsaWdodFBheWxvYWQoKXtcbiAgICByZXR1cm4ge1xuICAgICAgbGFzdF9tb2RpZmllZDogdGhpcy5maWxlLmxhc3RNb2RpZmllZCxcbiAgICAgIG5hbWU6IHRoaXMuZmlsZS5uYW1lLFxuICAgICAgcmVsYXRpdmVfcGF0aDogdGhpcy5maWxlLndlYmtpdFJlbGF0aXZlUGF0aCxcbiAgICAgIHNpemU6IHRoaXMuZmlsZS5zaXplLFxuICAgICAgdHlwZTogdGhpcy5maWxlLnR5cGUsXG4gICAgICByZWY6IHRoaXMucmVmLFxuICAgICAgbWV0YTogdHlwZW9mKHRoaXMuZmlsZS5tZXRhKSA9PT0gXCJmdW5jdGlvblwiID8gdGhpcy5maWxlLm1ldGEoKSA6IHVuZGVmaW5lZFxuICAgIH1cbiAgfVxuXG4gIHVwbG9hZGVyKHVwbG9hZGVycyl7XG4gICAgaWYodGhpcy5tZXRhLnVwbG9hZGVyKXtcbiAgICAgIGxldCBjYWxsYmFjayA9IHVwbG9hZGVyc1t0aGlzLm1ldGEudXBsb2FkZXJdIHx8IGxvZ0Vycm9yKGBubyB1cGxvYWRlciBjb25maWd1cmVkIGZvciAke3RoaXMubWV0YS51cGxvYWRlcn1gKVxuICAgICAgcmV0dXJuIHtuYW1lOiB0aGlzLm1ldGEudXBsb2FkZXIsIGNhbGxiYWNrOiBjYWxsYmFja31cbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuIHtuYW1lOiBcImNoYW5uZWxcIiwgY2FsbGJhY2s6IGNoYW5uZWxVcGxvYWRlcn1cbiAgICB9XG4gIH1cblxuICB6aXBQb3N0RmxpZ2h0KHJlc3Ape1xuICAgIHRoaXMubWV0YSA9IHJlc3AuZW50cmllc1t0aGlzLnJlZl1cbiAgICBpZighdGhpcy5tZXRhKXsgbG9nRXJyb3IoYG5vIHByZWZsaWdodCB1cGxvYWQgcmVzcG9uc2UgcmV0dXJuZWQgd2l0aCByZWYgJHt0aGlzLnJlZn1gLCB7aW5wdXQ6IHRoaXMuZmlsZUVsLCByZXNwb25zZTogcmVzcH0pIH1cbiAgfVxufVxuIiwgImltcG9ydCB7XG4gIFBIWF9ET05FX1JFRlMsXG4gIFBIWF9QUkVGTElHSFRFRF9SRUZTLFxuICBQSFhfVVBMT0FEX1JFRlxufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5pbXBvcnQge1xufSBmcm9tIFwiLi91dGlsc1wiXG5cbmltcG9ydCBET00gZnJvbSBcIi4vZG9tXCJcbmltcG9ydCBVcGxvYWRFbnRyeSBmcm9tIFwiLi91cGxvYWRfZW50cnlcIlxuXG5sZXQgbGl2ZVVwbG9hZGVyRmlsZVJlZiA9IDBcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgTGl2ZVVwbG9hZGVyIHtcbiAgc3RhdGljIGdlbkZpbGVSZWYoZmlsZSl7XG4gICAgbGV0IHJlZiA9IGZpbGUuX3BoeFJlZlxuICAgIGlmKHJlZiAhPT0gdW5kZWZpbmVkKXtcbiAgICAgIHJldHVybiByZWZcbiAgICB9IGVsc2Uge1xuICAgICAgZmlsZS5fcGh4UmVmID0gKGxpdmVVcGxvYWRlckZpbGVSZWYrKykudG9TdHJpbmcoKVxuICAgICAgcmV0dXJuIGZpbGUuX3BoeFJlZlxuICAgIH1cbiAgfVxuXG4gIHN0YXRpYyBnZXRFbnRyeURhdGFVUkwoaW5wdXRFbCwgcmVmLCBjYWxsYmFjayl7XG4gICAgbGV0IGZpbGUgPSB0aGlzLmFjdGl2ZUZpbGVzKGlucHV0RWwpLmZpbmQoZmlsZSA9PiB0aGlzLmdlbkZpbGVSZWYoZmlsZSkgPT09IHJlZilcbiAgICBjYWxsYmFjayhVUkwuY3JlYXRlT2JqZWN0VVJMKGZpbGUpKVxuICB9XG5cbiAgc3RhdGljIGhhc1VwbG9hZHNJblByb2dyZXNzKGZvcm1FbCl7XG4gICAgbGV0IGFjdGl2ZSA9IDBcbiAgICBET00uZmluZFVwbG9hZElucHV0cyhmb3JtRWwpLmZvckVhY2goaW5wdXQgPT4ge1xuICAgICAgaWYoaW5wdXQuZ2V0QXR0cmlidXRlKFBIWF9QUkVGTElHSFRFRF9SRUZTKSAhPT0gaW5wdXQuZ2V0QXR0cmlidXRlKFBIWF9ET05FX1JFRlMpKXtcbiAgICAgICAgYWN0aXZlKytcbiAgICAgIH1cbiAgICB9KVxuICAgIHJldHVybiBhY3RpdmUgPiAwXG4gIH1cblxuICBzdGF0aWMgc2VyaWFsaXplVXBsb2FkcyhpbnB1dEVsKXtcbiAgICBsZXQgZmlsZXMgPSB0aGlzLmFjdGl2ZUZpbGVzKGlucHV0RWwpXG4gICAgbGV0IGZpbGVEYXRhID0ge31cbiAgICBmaWxlcy5mb3JFYWNoKGZpbGUgPT4ge1xuICAgICAgbGV0IGVudHJ5ID0ge3BhdGg6IGlucHV0RWwubmFtZX1cbiAgICAgIGxldCB1cGxvYWRSZWYgPSBpbnB1dEVsLmdldEF0dHJpYnV0ZShQSFhfVVBMT0FEX1JFRilcbiAgICAgIGZpbGVEYXRhW3VwbG9hZFJlZl0gPSBmaWxlRGF0YVt1cGxvYWRSZWZdIHx8IFtdXG4gICAgICBlbnRyeS5yZWYgPSB0aGlzLmdlbkZpbGVSZWYoZmlsZSlcbiAgICAgIGVudHJ5Lmxhc3RfbW9kaWZpZWQgPSBmaWxlLmxhc3RNb2RpZmllZFxuICAgICAgZW50cnkubmFtZSA9IGZpbGUubmFtZSB8fCBlbnRyeS5yZWZcbiAgICAgIGVudHJ5LnJlbGF0aXZlX3BhdGggPSBmaWxlLndlYmtpdFJlbGF0aXZlUGF0aFxuICAgICAgZW50cnkudHlwZSA9IGZpbGUudHlwZVxuICAgICAgZW50cnkuc2l6ZSA9IGZpbGUuc2l6ZVxuICAgICAgaWYodHlwZW9mKGZpbGUubWV0YSkgPT09IFwiZnVuY3Rpb25cIil7IGVudHJ5Lm1ldGEgPSBmaWxlLm1ldGEoKSB9XG4gICAgICBmaWxlRGF0YVt1cGxvYWRSZWZdLnB1c2goZW50cnkpXG4gICAgfSlcbiAgICByZXR1cm4gZmlsZURhdGFcbiAgfVxuXG4gIHN0YXRpYyBjbGVhckZpbGVzKGlucHV0RWwpe1xuICAgIGlucHV0RWwudmFsdWUgPSBudWxsXG4gICAgaW5wdXRFbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1VQTE9BRF9SRUYpXG4gICAgRE9NLnB1dFByaXZhdGUoaW5wdXRFbCwgXCJmaWxlc1wiLCBbXSlcbiAgfVxuXG4gIHN0YXRpYyB1bnRyYWNrRmlsZShpbnB1dEVsLCBmaWxlKXtcbiAgICBET00ucHV0UHJpdmF0ZShpbnB1dEVsLCBcImZpbGVzXCIsIERPTS5wcml2YXRlKGlucHV0RWwsIFwiZmlsZXNcIikuZmlsdGVyKGYgPT4gIU9iamVjdC5pcyhmLCBmaWxlKSkpXG4gIH1cblxuICBzdGF0aWMgdHJhY2tGaWxlcyhpbnB1dEVsLCBmaWxlcywgZGF0YVRyYW5zZmVyKXtcbiAgICBpZihpbnB1dEVsLmdldEF0dHJpYnV0ZShcIm11bHRpcGxlXCIpICE9PSBudWxsKXtcbiAgICAgIGxldCBuZXdGaWxlcyA9IGZpbGVzLmZpbHRlcihmaWxlID0+ICF0aGlzLmFjdGl2ZUZpbGVzKGlucHV0RWwpLmZpbmQoZiA9PiBPYmplY3QuaXMoZiwgZmlsZSkpKVxuICAgICAgRE9NLnVwZGF0ZVByaXZhdGUoaW5wdXRFbCwgXCJmaWxlc1wiLCBbXSwgKGV4aXN0aW5nKSA9PiBleGlzdGluZy5jb25jYXQobmV3RmlsZXMpKVxuICAgICAgaW5wdXRFbC52YWx1ZSA9IG51bGxcbiAgICB9IGVsc2Uge1xuICAgICAgLy8gUmVzZXQgaW5wdXRFbCBmaWxlcyB0byBhbGlnbiBvdXRwdXQgd2l0aCBwcm9ncmFtbWF0aWMgY2hhbmdlcyAoaS5lLiBkcmFnIGFuZCBkcm9wKVxuICAgICAgaWYoZGF0YVRyYW5zZmVyICYmIGRhdGFUcmFuc2Zlci5maWxlcy5sZW5ndGggPiAwKXsgaW5wdXRFbC5maWxlcyA9IGRhdGFUcmFuc2Zlci5maWxlcyB9XG4gICAgICBET00ucHV0UHJpdmF0ZShpbnB1dEVsLCBcImZpbGVzXCIsIGZpbGVzKVxuICAgIH1cbiAgfVxuXG4gIHN0YXRpYyBhY3RpdmVGaWxlSW5wdXRzKGZvcm1FbCl7XG4gICAgbGV0IGZpbGVJbnB1dHMgPSBET00uZmluZFVwbG9hZElucHV0cyhmb3JtRWwpXG4gICAgcmV0dXJuIEFycmF5LmZyb20oZmlsZUlucHV0cykuZmlsdGVyKGVsID0+IGVsLmZpbGVzICYmIHRoaXMuYWN0aXZlRmlsZXMoZWwpLmxlbmd0aCA+IDApXG4gIH1cblxuICBzdGF0aWMgYWN0aXZlRmlsZXMoaW5wdXQpe1xuICAgIHJldHVybiAoRE9NLnByaXZhdGUoaW5wdXQsIFwiZmlsZXNcIikgfHwgW10pLmZpbHRlcihmID0+IFVwbG9hZEVudHJ5LmlzQWN0aXZlKGlucHV0LCBmKSlcbiAgfVxuXG4gIHN0YXRpYyBpbnB1dHNBd2FpdGluZ1ByZWZsaWdodChmb3JtRWwpe1xuICAgIGxldCBmaWxlSW5wdXRzID0gRE9NLmZpbmRVcGxvYWRJbnB1dHMoZm9ybUVsKVxuICAgIHJldHVybiBBcnJheS5mcm9tKGZpbGVJbnB1dHMpLmZpbHRlcihpbnB1dCA9PiB0aGlzLmZpbGVzQXdhaXRpbmdQcmVmbGlnaHQoaW5wdXQpLmxlbmd0aCA+IDApXG4gIH1cblxuICBzdGF0aWMgZmlsZXNBd2FpdGluZ1ByZWZsaWdodChpbnB1dCl7XG4gICAgcmV0dXJuIHRoaXMuYWN0aXZlRmlsZXMoaW5wdXQpLmZpbHRlcihmID0+ICFVcGxvYWRFbnRyeS5pc1ByZWZsaWdodGVkKGlucHV0LCBmKSAmJiAhVXBsb2FkRW50cnkuaXNQcmVmbGlnaHRJblByb2dyZXNzKGYpKVxuICB9XG5cbiAgc3RhdGljIG1hcmtQcmVmbGlnaHRJblByb2dyZXNzKGVudHJpZXMpe1xuICAgIGVudHJpZXMuZm9yRWFjaChlbnRyeSA9PiBVcGxvYWRFbnRyeS5tYXJrUHJlZmxpZ2h0SW5Qcm9ncmVzcyhlbnRyeS5maWxlKSlcbiAgfVxuXG4gIGNvbnN0cnVjdG9yKGlucHV0RWwsIHZpZXcsIG9uQ29tcGxldGUpe1xuICAgIHRoaXMuYXV0b1VwbG9hZCA9IERPTS5pc0F1dG9VcGxvYWQoaW5wdXRFbClcbiAgICB0aGlzLnZpZXcgPSB2aWV3XG4gICAgdGhpcy5vbkNvbXBsZXRlID0gb25Db21wbGV0ZVxuICAgIHRoaXMuX2VudHJpZXMgPVxuICAgICAgQXJyYXkuZnJvbShMaXZlVXBsb2FkZXIuZmlsZXNBd2FpdGluZ1ByZWZsaWdodChpbnB1dEVsKSB8fCBbXSlcbiAgICAgICAgLm1hcChmaWxlID0+IG5ldyBVcGxvYWRFbnRyeShpbnB1dEVsLCBmaWxlLCB2aWV3LCB0aGlzLmF1dG9VcGxvYWQpKVxuXG4gICAgLy8gcHJldmVudCBzZW5kaW5nIGR1cGxpY2F0ZSBwcmVmbGlnaHQgcmVxdWVzdHNcbiAgICBMaXZlVXBsb2FkZXIubWFya1ByZWZsaWdodEluUHJvZ3Jlc3ModGhpcy5fZW50cmllcylcblxuICAgIHRoaXMubnVtRW50cmllc0luUHJvZ3Jlc3MgPSB0aGlzLl9lbnRyaWVzLmxlbmd0aFxuICB9XG5cbiAgaXNBdXRvVXBsb2FkKCl7IHJldHVybiB0aGlzLmF1dG9VcGxvYWQgfVxuXG4gIGVudHJpZXMoKXsgcmV0dXJuIHRoaXMuX2VudHJpZXMgfVxuXG4gIGluaXRBZGFwdGVyVXBsb2FkKHJlc3AsIG9uRXJyb3IsIGxpdmVTb2NrZXQpe1xuICAgIHRoaXMuX2VudHJpZXMgPVxuICAgICAgdGhpcy5fZW50cmllcy5tYXAoZW50cnkgPT4ge1xuICAgICAgICBpZihlbnRyeS5pc0NhbmNlbGxlZCgpKXtcbiAgICAgICAgICB0aGlzLm51bUVudHJpZXNJblByb2dyZXNzLS1cbiAgICAgICAgICBpZih0aGlzLm51bUVudHJpZXNJblByb2dyZXNzID09PSAwKXsgdGhpcy5vbkNvbXBsZXRlKCkgfVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIGVudHJ5LnppcFBvc3RGbGlnaHQocmVzcClcbiAgICAgICAgICBlbnRyeS5vbkRvbmUoKCkgPT4ge1xuICAgICAgICAgICAgdGhpcy5udW1FbnRyaWVzSW5Qcm9ncmVzcy0tXG4gICAgICAgICAgICBpZih0aGlzLm51bUVudHJpZXNJblByb2dyZXNzID09PSAwKXsgdGhpcy5vbkNvbXBsZXRlKCkgfVxuICAgICAgICAgIH0pXG4gICAgICAgIH1cbiAgICAgICAgcmV0dXJuIGVudHJ5XG4gICAgICB9KVxuXG4gICAgbGV0IGdyb3VwZWRFbnRyaWVzID0gdGhpcy5fZW50cmllcy5yZWR1Y2UoKGFjYywgZW50cnkpID0+IHtcbiAgICAgIGlmKCFlbnRyeS5tZXRhKXsgcmV0dXJuIGFjYyB9XG4gICAgICBsZXQge25hbWUsIGNhbGxiYWNrfSA9IGVudHJ5LnVwbG9hZGVyKGxpdmVTb2NrZXQudXBsb2FkZXJzKVxuICAgICAgYWNjW25hbWVdID0gYWNjW25hbWVdIHx8IHtjYWxsYmFjazogY2FsbGJhY2ssIGVudHJpZXM6IFtdfVxuICAgICAgYWNjW25hbWVdLmVudHJpZXMucHVzaChlbnRyeSlcbiAgICAgIHJldHVybiBhY2NcbiAgICB9LCB7fSlcblxuICAgIGZvcihsZXQgbmFtZSBpbiBncm91cGVkRW50cmllcyl7XG4gICAgICBsZXQge2NhbGxiYWNrLCBlbnRyaWVzfSA9IGdyb3VwZWRFbnRyaWVzW25hbWVdXG4gICAgICBjYWxsYmFjayhlbnRyaWVzLCBvbkVycm9yLCByZXNwLCBsaXZlU29ja2V0KVxuICAgIH1cbiAgfVxufVxuIiwgImltcG9ydCB7XG4gIFBIWF9BQ1RJVkVfRU5UUllfUkVGUyxcbiAgUEhYX0xJVkVfRklMRV9VUERBVEVELFxuICBQSFhfUFJFRkxJR0hURURfUkVGUyxcbiAgUEhYX1VQTE9BRF9SRUZcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCJcblxuaW1wb3J0IExpdmVVcGxvYWRlciBmcm9tIFwiLi9saXZlX3VwbG9hZGVyXCJcbmltcG9ydCBBUklBIGZyb20gXCIuL2FyaWFcIlxuXG5sZXQgSG9va3MgPSB7XG4gIExpdmVGaWxlVXBsb2FkOiB7XG4gICAgYWN0aXZlUmVmcygpeyByZXR1cm4gdGhpcy5lbC5nZXRBdHRyaWJ1dGUoUEhYX0FDVElWRV9FTlRSWV9SRUZTKSB9LFxuXG4gICAgcHJlZmxpZ2h0ZWRSZWZzKCl7IHJldHVybiB0aGlzLmVsLmdldEF0dHJpYnV0ZShQSFhfUFJFRkxJR0hURURfUkVGUykgfSxcblxuICAgIG1vdW50ZWQoKXsgdGhpcy5wcmVmbGlnaHRlZFdhcyA9IHRoaXMucHJlZmxpZ2h0ZWRSZWZzKCkgfSxcblxuICAgIHVwZGF0ZWQoKXtcbiAgICAgIGxldCBuZXdQcmVmbGlnaHRzID0gdGhpcy5wcmVmbGlnaHRlZFJlZnMoKVxuICAgICAgaWYodGhpcy5wcmVmbGlnaHRlZFdhcyAhPT0gbmV3UHJlZmxpZ2h0cyl7XG4gICAgICAgIHRoaXMucHJlZmxpZ2h0ZWRXYXMgPSBuZXdQcmVmbGlnaHRzXG4gICAgICAgIGlmKG5ld1ByZWZsaWdodHMgPT09IFwiXCIpe1xuICAgICAgICAgIHRoaXMuX192aWV3LmNhbmNlbFN1Ym1pdCh0aGlzLmVsLmZvcm0pXG4gICAgICAgIH1cbiAgICAgIH1cblxuICAgICAgaWYodGhpcy5hY3RpdmVSZWZzKCkgPT09IFwiXCIpeyB0aGlzLmVsLnZhbHVlID0gbnVsbCB9XG4gICAgICB0aGlzLmVsLmRpc3BhdGNoRXZlbnQobmV3IEN1c3RvbUV2ZW50KFBIWF9MSVZFX0ZJTEVfVVBEQVRFRCkpXG4gICAgfVxuICB9LFxuXG4gIExpdmVJbWdQcmV2aWV3OiB7XG4gICAgbW91bnRlZCgpe1xuICAgICAgdGhpcy5yZWYgPSB0aGlzLmVsLmdldEF0dHJpYnV0ZShcImRhdGEtcGh4LWVudHJ5LXJlZlwiKVxuICAgICAgdGhpcy5pbnB1dEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQodGhpcy5lbC5nZXRBdHRyaWJ1dGUoUEhYX1VQTE9BRF9SRUYpKVxuICAgICAgTGl2ZVVwbG9hZGVyLmdldEVudHJ5RGF0YVVSTCh0aGlzLmlucHV0RWwsIHRoaXMucmVmLCB1cmwgPT4ge1xuICAgICAgICB0aGlzLnVybCA9IHVybFxuICAgICAgICB0aGlzLmVsLnNyYyA9IHVybFxuICAgICAgfSlcbiAgICB9LFxuICAgIGRlc3Ryb3llZCgpe1xuICAgICAgVVJMLnJldm9rZU9iamVjdFVSTCh0aGlzLnVybClcbiAgICB9XG4gIH0sXG4gIEZvY3VzV3JhcDoge1xuICAgIG1vdW50ZWQoKXtcbiAgICAgIHRoaXMuZm9jdXNTdGFydCA9IHRoaXMuZWwuZmlyc3RFbGVtZW50Q2hpbGRcbiAgICAgIHRoaXMuZm9jdXNFbmQgPSB0aGlzLmVsLmxhc3RFbGVtZW50Q2hpbGRcbiAgICAgIHRoaXMuZm9jdXNTdGFydC5hZGRFdmVudExpc3RlbmVyKFwiZm9jdXNcIiwgKCkgPT4gQVJJQS5mb2N1c0xhc3QodGhpcy5lbCkpXG4gICAgICB0aGlzLmZvY3VzRW5kLmFkZEV2ZW50TGlzdGVuZXIoXCJmb2N1c1wiLCAoKSA9PiBBUklBLmZvY3VzRmlyc3QodGhpcy5lbCkpXG4gICAgICB0aGlzLmVsLmFkZEV2ZW50TGlzdGVuZXIoXCJwaHg6c2hvdy1lbmRcIiwgKCkgPT4gdGhpcy5lbC5mb2N1cygpKVxuICAgICAgaWYod2luZG93LmdldENvbXB1dGVkU3R5bGUodGhpcy5lbCkuZGlzcGxheSAhPT0gXCJub25lXCIpe1xuICAgICAgICBBUklBLmZvY3VzRmlyc3QodGhpcy5lbClcbiAgICAgIH1cbiAgICB9XG4gIH1cbn1cblxubGV0IGZpbmRTY3JvbGxDb250YWluZXIgPSAoZWwpID0+IHtcbiAgLy8gdGhlIHNjcm9sbCBldmVudCB3b24ndCBiZSBmaXJlZCBvbiB0aGUgaHRtbC9ib2R5IGVsZW1lbnQgZXZlbiBpZiBvdmVyZmxvdyBpcyBzZXRcbiAgLy8gdGhlcmVmb3JlIHdlIHJldHVybiBudWxsIHRvIGluc3RlYWQgbGlzdGVuIGZvciBzY3JvbGwgZXZlbnRzIG9uIGRvY3VtZW50XG4gIGlmIChbXCJIVE1MXCIsIFwiQk9EWVwiXS5pbmRleE9mKGVsLm5vZGVOYW1lLnRvVXBwZXJDYXNlKCkpID49IDApIHJldHVybiBudWxsXG4gIGlmKFtcInNjcm9sbFwiLCBcImF1dG9cIl0uaW5kZXhPZihnZXRDb21wdXRlZFN0eWxlKGVsKS5vdmVyZmxvd1kpID49IDApIHJldHVybiBlbFxuICByZXR1cm4gZmluZFNjcm9sbENvbnRhaW5lcihlbC5wYXJlbnRFbGVtZW50KVxufVxuXG5sZXQgc2Nyb2xsVG9wID0gKHNjcm9sbENvbnRhaW5lcikgPT4ge1xuICBpZihzY3JvbGxDb250YWluZXIpe1xuICAgIHJldHVybiBzY3JvbGxDb250YWluZXIuc2Nyb2xsVG9wXG4gIH0gZWxzZSB7XG4gICAgcmV0dXJuIGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5zY3JvbGxUb3AgfHwgZG9jdW1lbnQuYm9keS5zY3JvbGxUb3BcbiAgfVxufVxuXG5sZXQgYm90dG9tID0gKHNjcm9sbENvbnRhaW5lcikgPT4ge1xuICBpZihzY3JvbGxDb250YWluZXIpe1xuICAgIHJldHVybiBzY3JvbGxDb250YWluZXIuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCkuYm90dG9tXG4gIH0gZWxzZSB7XG4gICAgLy8gd2hlbiB3ZSBoYXZlIG5vIGNvbnRhaW5lciwgdGhlIHdob2xlIHBhZ2Ugc2Nyb2xscyxcbiAgICAvLyB0aGVyZWZvcmUgdGhlIGJvdHRvbSBjb29yZGluYXRlIGlzIHRoZSB2aWV3cG9ydCBoZWlnaHRcbiAgICByZXR1cm4gd2luZG93LmlubmVySGVpZ2h0IHx8IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5jbGllbnRIZWlnaHRcbiAgfVxufVxuXG5sZXQgdG9wID0gKHNjcm9sbENvbnRhaW5lcikgPT4ge1xuICBpZihzY3JvbGxDb250YWluZXIpe1xuICAgIHJldHVybiBzY3JvbGxDb250YWluZXIuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCkudG9wXG4gIH0gZWxzZSB7XG4gICAgLy8gd2hlbiB3ZSBoYXZlIG5vIGNvbnRhaW5lciB0aGUgd2hvbGUgcGFnZSBzY3JvbGxzLFxuICAgIC8vIHRoZXJlZm9yZSB0aGUgdG9wIGNvb3JkaW5hdGUgaXMgMFxuICAgIHJldHVybiAwXG4gIH1cbn1cblxubGV0IGlzQXRWaWV3cG9ydFRvcCA9IChlbCwgc2Nyb2xsQ29udGFpbmVyKSA9PiB7XG4gIGxldCByZWN0ID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KClcbiAgcmV0dXJuIHJlY3QudG9wID49IHRvcChzY3JvbGxDb250YWluZXIpICYmIHJlY3QubGVmdCA+PSAwICYmIHJlY3QudG9wIDw9IGJvdHRvbShzY3JvbGxDb250YWluZXIpXG59XG5cbmxldCBpc0F0Vmlld3BvcnRCb3R0b20gPSAoZWwsIHNjcm9sbENvbnRhaW5lcikgPT4ge1xuICBsZXQgcmVjdCA9IGVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpXG4gIHJldHVybiByZWN0LnJpZ2h0ID49IHRvcChzY3JvbGxDb250YWluZXIpICYmIHJlY3QubGVmdCA+PSAwICYmIHJlY3QuYm90dG9tIDw9IGJvdHRvbShzY3JvbGxDb250YWluZXIpXG59XG5cbmxldCBpc1dpdGhpblZpZXdwb3J0ID0gKGVsLCBzY3JvbGxDb250YWluZXIpID0+IHtcbiAgbGV0IHJlY3QgPSBlbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKVxuICByZXR1cm4gcmVjdC50b3AgPj0gdG9wKHNjcm9sbENvbnRhaW5lcikgJiYgcmVjdC5sZWZ0ID49IDAgJiYgcmVjdC50b3AgPD0gYm90dG9tKHNjcm9sbENvbnRhaW5lcilcbn1cblxuSG9va3MuSW5maW5pdGVTY3JvbGwgPSB7XG4gIG1vdW50ZWQoKXtcbiAgICB0aGlzLnNjcm9sbENvbnRhaW5lciA9IGZpbmRTY3JvbGxDb250YWluZXIodGhpcy5lbClcbiAgICBsZXQgc2Nyb2xsQmVmb3JlID0gc2Nyb2xsVG9wKHRoaXMuc2Nyb2xsQ29udGFpbmVyKVxuICAgIGxldCB0b3BPdmVycmFuID0gZmFsc2VcbiAgICBsZXQgdGhyb3R0bGVJbnRlcnZhbCA9IDUwMFxuICAgIGxldCBwZW5kaW5nT3AgPSBudWxsXG5cbiAgICBsZXQgb25Ub3BPdmVycnVuID0gdGhpcy50aHJvdHRsZSh0aHJvdHRsZUludGVydmFsLCAodG9wRXZlbnQsIGZpcnN0Q2hpbGQpID0+IHtcbiAgICAgIHBlbmRpbmdPcCA9ICgpID0+IHRydWVcbiAgICAgIHRoaXMubGl2ZVNvY2tldC5leGVjSlNIb29rUHVzaCh0aGlzLmVsLCB0b3BFdmVudCwge2lkOiBmaXJzdENoaWxkLmlkLCBfb3ZlcnJhbjogdHJ1ZX0sICgpID0+IHtcbiAgICAgICAgcGVuZGluZ09wID0gbnVsbFxuICAgICAgfSlcbiAgICB9KVxuXG4gICAgbGV0IG9uRmlyc3RDaGlsZEF0VG9wID0gdGhpcy50aHJvdHRsZSh0aHJvdHRsZUludGVydmFsLCAodG9wRXZlbnQsIGZpcnN0Q2hpbGQpID0+IHtcbiAgICAgIHBlbmRpbmdPcCA9ICgpID0+IGZpcnN0Q2hpbGQuc2Nyb2xsSW50b1ZpZXcoe2Jsb2NrOiBcInN0YXJ0XCJ9KVxuICAgICAgdGhpcy5saXZlU29ja2V0LmV4ZWNKU0hvb2tQdXNoKHRoaXMuZWwsIHRvcEV2ZW50LCB7aWQ6IGZpcnN0Q2hpbGQuaWR9LCAoKSA9PiB7XG4gICAgICAgIHBlbmRpbmdPcCA9IG51bGxcbiAgICAgICAgLy8gbWFrZSBzdXJlIHRoYXQgdGhlIERPTSBpcyBwYXRjaGVkIGJ5IHdhaXRpbmcgZm9yIHRoZSBuZXh0IHRpY2tcbiAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICAgICAgaWYoIWlzV2l0aGluVmlld3BvcnQoZmlyc3RDaGlsZCwgdGhpcy5zY3JvbGxDb250YWluZXIpKXtcbiAgICAgICAgICAgIGZpcnN0Q2hpbGQuc2Nyb2xsSW50b1ZpZXcoe2Jsb2NrOiBcInN0YXJ0XCJ9KVxuICAgICAgICAgIH1cbiAgICAgICAgfSlcbiAgICAgIH0pXG4gICAgfSlcblxuICAgIGxldCBvbkxhc3RDaGlsZEF0Qm90dG9tID0gdGhpcy50aHJvdHRsZSh0aHJvdHRsZUludGVydmFsLCAoYm90dG9tRXZlbnQsIGxhc3RDaGlsZCkgPT4ge1xuICAgICAgcGVuZGluZ09wID0gKCkgPT4gbGFzdENoaWxkLnNjcm9sbEludG9WaWV3KHtibG9jazogXCJlbmRcIn0pXG4gICAgICB0aGlzLmxpdmVTb2NrZXQuZXhlY0pTSG9va1B1c2godGhpcy5lbCwgYm90dG9tRXZlbnQsIHtpZDogbGFzdENoaWxkLmlkfSwgKCkgPT4ge1xuICAgICAgICBwZW5kaW5nT3AgPSBudWxsXG4gICAgICAgIC8vIG1ha2Ugc3VyZSB0aGF0IHRoZSBET00gaXMgcGF0Y2hlZCBieSB3YWl0aW5nIGZvciB0aGUgbmV4dCB0aWNrXG4gICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgIGlmKCFpc1dpdGhpblZpZXdwb3J0KGxhc3RDaGlsZCwgdGhpcy5zY3JvbGxDb250YWluZXIpKXtcbiAgICAgICAgICAgIGxhc3RDaGlsZC5zY3JvbGxJbnRvVmlldyh7YmxvY2s6IFwiZW5kXCJ9KVxuICAgICAgICAgIH1cbiAgICAgICAgfSlcbiAgICAgIH0pXG4gICAgfSlcblxuICAgIHRoaXMub25TY3JvbGwgPSAoX2UpID0+IHtcbiAgICAgIGxldCBzY3JvbGxOb3cgPSBzY3JvbGxUb3AodGhpcy5zY3JvbGxDb250YWluZXIpXG5cbiAgICAgIGlmKHBlbmRpbmdPcCl7XG4gICAgICAgIHNjcm9sbEJlZm9yZSA9IHNjcm9sbE5vd1xuICAgICAgICByZXR1cm4gcGVuZGluZ09wKClcbiAgICAgIH1cbiAgICAgIGxldCByZWN0ID0gdGhpcy5lbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKVxuICAgICAgbGV0IHRvcEV2ZW50ID0gdGhpcy5lbC5nZXRBdHRyaWJ1dGUodGhpcy5saXZlU29ja2V0LmJpbmRpbmcoXCJ2aWV3cG9ydC10b3BcIikpXG4gICAgICBsZXQgYm90dG9tRXZlbnQgPSB0aGlzLmVsLmdldEF0dHJpYnV0ZSh0aGlzLmxpdmVTb2NrZXQuYmluZGluZyhcInZpZXdwb3J0LWJvdHRvbVwiKSlcbiAgICAgIGxldCBsYXN0Q2hpbGQgPSB0aGlzLmVsLmxhc3RFbGVtZW50Q2hpbGRcbiAgICAgIGxldCBmaXJzdENoaWxkID0gdGhpcy5lbC5maXJzdEVsZW1lbnRDaGlsZFxuICAgICAgbGV0IGlzU2Nyb2xsaW5nVXAgPSBzY3JvbGxOb3cgPCBzY3JvbGxCZWZvcmVcbiAgICAgIGxldCBpc1Njcm9sbGluZ0Rvd24gPSBzY3JvbGxOb3cgPiBzY3JvbGxCZWZvcmVcblxuICAgICAgLy8gZWwgb3ZlcnJhbiB3aGlsZSBzY3JvbGxpbmcgdXBcbiAgICAgIGlmKGlzU2Nyb2xsaW5nVXAgJiYgdG9wRXZlbnQgJiYgIXRvcE92ZXJyYW4gJiYgcmVjdC50b3AgPj0gMCl7XG4gICAgICAgIHRvcE92ZXJyYW4gPSB0cnVlXG4gICAgICAgIG9uVG9wT3ZlcnJ1bih0b3BFdmVudCwgZmlyc3RDaGlsZClcbiAgICAgIH0gZWxzZSBpZihpc1Njcm9sbGluZ0Rvd24gJiYgdG9wT3ZlcnJhbiAmJiByZWN0LnRvcCA8PSAwKXtcbiAgICAgICAgdG9wT3ZlcnJhbiA9IGZhbHNlXG4gICAgICB9XG5cbiAgICAgIGlmKHRvcEV2ZW50ICYmIGlzU2Nyb2xsaW5nVXAgJiYgaXNBdFZpZXdwb3J0VG9wKGZpcnN0Q2hpbGQsIHRoaXMuc2Nyb2xsQ29udGFpbmVyKSl7XG4gICAgICAgIG9uRmlyc3RDaGlsZEF0VG9wKHRvcEV2ZW50LCBmaXJzdENoaWxkKVxuICAgICAgfSBlbHNlIGlmKGJvdHRvbUV2ZW50ICYmIGlzU2Nyb2xsaW5nRG93biAmJiBpc0F0Vmlld3BvcnRCb3R0b20obGFzdENoaWxkLCB0aGlzLnNjcm9sbENvbnRhaW5lcikpe1xuICAgICAgICBvbkxhc3RDaGlsZEF0Qm90dG9tKGJvdHRvbUV2ZW50LCBsYXN0Q2hpbGQpXG4gICAgICB9XG4gICAgICBzY3JvbGxCZWZvcmUgPSBzY3JvbGxOb3dcbiAgICB9XG5cbiAgICBpZih0aGlzLnNjcm9sbENvbnRhaW5lcil7XG4gICAgICB0aGlzLnNjcm9sbENvbnRhaW5lci5hZGRFdmVudExpc3RlbmVyKFwic2Nyb2xsXCIsIHRoaXMub25TY3JvbGwpXG4gICAgfSBlbHNlIHtcbiAgICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwic2Nyb2xsXCIsIHRoaXMub25TY3JvbGwpXG4gICAgfVxuICB9LFxuICBcbiAgZGVzdHJveWVkKCl7XG4gICAgaWYodGhpcy5zY3JvbGxDb250YWluZXIpe1xuICAgICAgdGhpcy5zY3JvbGxDb250YWluZXIucmVtb3ZlRXZlbnRMaXN0ZW5lcihcInNjcm9sbFwiLCB0aGlzLm9uU2Nyb2xsKVxuICAgIH0gZWxzZSB7XG4gICAgICB3aW5kb3cucmVtb3ZlRXZlbnRMaXN0ZW5lcihcInNjcm9sbFwiLCB0aGlzLm9uU2Nyb2xsKVxuICAgIH1cbiAgfSxcblxuICB0aHJvdHRsZShpbnRlcnZhbCwgY2FsbGJhY2spe1xuICAgIGxldCBsYXN0Q2FsbEF0ID0gMFxuICAgIGxldCB0aW1lclxuXG4gICAgcmV0dXJuICguLi5hcmdzKSA9PiB7XG4gICAgICBsZXQgbm93ID0gRGF0ZS5ub3coKVxuICAgICAgbGV0IHJlbWFpbmluZ1RpbWUgPSBpbnRlcnZhbCAtIChub3cgLSBsYXN0Q2FsbEF0KVxuXG4gICAgICBpZihyZW1haW5pbmdUaW1lIDw9IDAgfHwgcmVtYWluaW5nVGltZSA+IGludGVydmFsKXtcbiAgICAgICAgaWYodGltZXIpIHtcbiAgICAgICAgICBjbGVhclRpbWVvdXQodGltZXIpXG4gICAgICAgICAgdGltZXIgPSBudWxsXG4gICAgICAgIH1cbiAgICAgICAgbGFzdENhbGxBdCA9IG5vd1xuICAgICAgICBjYWxsYmFjayguLi5hcmdzKVxuICAgICAgfSBlbHNlIGlmKCF0aW1lcil7XG4gICAgICAgIHRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7XG4gICAgICAgICAgbGFzdENhbGxBdCA9IERhdGUubm93KClcbiAgICAgICAgICB0aW1lciA9IG51bGxcbiAgICAgICAgICBjYWxsYmFjayguLi5hcmdzKVxuICAgICAgICB9LCByZW1haW5pbmdUaW1lKVxuICAgICAgfVxuICAgIH1cbiAgfVxufVxuZXhwb3J0IGRlZmF1bHQgSG9va3NcbiIsICJpbXBvcnQge1xuICBtYXliZVxufSBmcm9tIFwiLi91dGlsc1wiXG5cbmltcG9ydCBET00gZnJvbSBcIi4vZG9tXCJcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgRE9NUG9zdE1vcnBoUmVzdG9yZXIge1xuICBjb25zdHJ1Y3Rvcihjb250YWluZXJCZWZvcmUsIGNvbnRhaW5lckFmdGVyLCB1cGRhdGVUeXBlKXtcbiAgICBsZXQgaWRzQmVmb3JlID0gbmV3IFNldCgpXG4gICAgbGV0IGlkc0FmdGVyID0gbmV3IFNldChbLi4uY29udGFpbmVyQWZ0ZXIuY2hpbGRyZW5dLm1hcChjaGlsZCA9PiBjaGlsZC5pZCkpXG5cbiAgICBsZXQgZWxlbWVudHNUb01vZGlmeSA9IFtdXG5cbiAgICBBcnJheS5mcm9tKGNvbnRhaW5lckJlZm9yZS5jaGlsZHJlbikuZm9yRWFjaChjaGlsZCA9PiB7XG4gICAgICBpZihjaGlsZC5pZCl7IC8vIGFsbCBvZiBvdXIgY2hpbGRyZW4gc2hvdWxkIGJlIGVsZW1lbnRzIHdpdGggaWRzXG4gICAgICAgIGlkc0JlZm9yZS5hZGQoY2hpbGQuaWQpXG4gICAgICAgIGlmKGlkc0FmdGVyLmhhcyhjaGlsZC5pZCkpe1xuICAgICAgICAgIGxldCBwcmV2aW91c0VsZW1lbnRJZCA9IGNoaWxkLnByZXZpb3VzRWxlbWVudFNpYmxpbmcgJiYgY2hpbGQucHJldmlvdXNFbGVtZW50U2libGluZy5pZFxuICAgICAgICAgIGVsZW1lbnRzVG9Nb2RpZnkucHVzaCh7ZWxlbWVudElkOiBjaGlsZC5pZCwgcHJldmlvdXNFbGVtZW50SWQ6IHByZXZpb3VzRWxlbWVudElkfSlcbiAgICAgICAgfVxuICAgICAgfVxuICAgIH0pXG5cbiAgICB0aGlzLmNvbnRhaW5lcklkID0gY29udGFpbmVyQWZ0ZXIuaWRcbiAgICB0aGlzLnVwZGF0ZVR5cGUgPSB1cGRhdGVUeXBlXG4gICAgdGhpcy5lbGVtZW50c1RvTW9kaWZ5ID0gZWxlbWVudHNUb01vZGlmeVxuICAgIHRoaXMuZWxlbWVudElkc1RvQWRkID0gWy4uLmlkc0FmdGVyXS5maWx0ZXIoaWQgPT4gIWlkc0JlZm9yZS5oYXMoaWQpKVxuICB9XG5cbiAgLy8gV2UgZG8gdGhlIGZvbGxvd2luZyB0byBvcHRpbWl6ZSBhcHBlbmQvcHJlcGVuZCBvcGVyYXRpb25zOlxuICAvLyAgIDEpIFRyYWNrIGlkcyBvZiBtb2RpZmllZCBlbGVtZW50cyAmIG9mIG5ldyBlbGVtZW50c1xuICAvLyAgIDIpIEFsbCB0aGUgbW9kaWZpZWQgZWxlbWVudHMgYXJlIHB1dCBiYWNrIGluIHRoZSBjb3JyZWN0IHBvc2l0aW9uIGluIHRoZSBET00gdHJlZVxuICAvLyAgICAgIGJ5IHN0b3JpbmcgdGhlIGlkIG9mIHRoZWlyIHByZXZpb3VzIHNpYmxpbmdcbiAgLy8gICAzKSBOZXcgZWxlbWVudHMgYXJlIGdvaW5nIHRvIGJlIHB1dCBpbiB0aGUgcmlnaHQgcGxhY2UgYnkgbW9ycGhkb20gZHVyaW5nIGFwcGVuZC5cbiAgLy8gICAgICBGb3IgcHJlcGVuZCwgd2UgbW92ZSB0aGVtIHRvIHRoZSBmaXJzdCBwb3NpdGlvbiBpbiB0aGUgY29udGFpbmVyXG4gIHBlcmZvcm0oKXtcbiAgICBsZXQgY29udGFpbmVyID0gRE9NLmJ5SWQodGhpcy5jb250YWluZXJJZClcbiAgICB0aGlzLmVsZW1lbnRzVG9Nb2RpZnkuZm9yRWFjaChlbGVtZW50VG9Nb2RpZnkgPT4ge1xuICAgICAgaWYoZWxlbWVudFRvTW9kaWZ5LnByZXZpb3VzRWxlbWVudElkKXtcbiAgICAgICAgbWF5YmUoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoZWxlbWVudFRvTW9kaWZ5LnByZXZpb3VzRWxlbWVudElkKSwgcHJldmlvdXNFbGVtID0+IHtcbiAgICAgICAgICBtYXliZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZChlbGVtZW50VG9Nb2RpZnkuZWxlbWVudElkKSwgZWxlbSA9PiB7XG4gICAgICAgICAgICBsZXQgaXNJblJpZ2h0UGxhY2UgPSBlbGVtLnByZXZpb3VzRWxlbWVudFNpYmxpbmcgJiYgZWxlbS5wcmV2aW91c0VsZW1lbnRTaWJsaW5nLmlkID09IHByZXZpb3VzRWxlbS5pZFxuICAgICAgICAgICAgaWYoIWlzSW5SaWdodFBsYWNlKXtcbiAgICAgICAgICAgICAgcHJldmlvdXNFbGVtLmluc2VydEFkamFjZW50RWxlbWVudChcImFmdGVyZW5kXCIsIGVsZW0pXG4gICAgICAgICAgICB9XG4gICAgICAgICAgfSlcbiAgICAgICAgfSlcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIC8vIFRoaXMgaXMgdGhlIGZpcnN0IGVsZW1lbnQgaW4gdGhlIGNvbnRhaW5lclxuICAgICAgICBtYXliZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZChlbGVtZW50VG9Nb2RpZnkuZWxlbWVudElkKSwgZWxlbSA9PiB7XG4gICAgICAgICAgbGV0IGlzSW5SaWdodFBsYWNlID0gZWxlbS5wcmV2aW91c0VsZW1lbnRTaWJsaW5nID09IG51bGxcbiAgICAgICAgICBpZighaXNJblJpZ2h0UGxhY2Upe1xuICAgICAgICAgICAgY29udGFpbmVyLmluc2VydEFkamFjZW50RWxlbWVudChcImFmdGVyYmVnaW5cIiwgZWxlbSlcbiAgICAgICAgICB9XG4gICAgICAgIH0pXG4gICAgICB9XG4gICAgfSlcblxuICAgIGlmKHRoaXMudXBkYXRlVHlwZSA9PSBcInByZXBlbmRcIil7XG4gICAgICB0aGlzLmVsZW1lbnRJZHNUb0FkZC5yZXZlcnNlKCkuZm9yRWFjaChlbGVtSWQgPT4ge1xuICAgICAgICBtYXliZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZChlbGVtSWQpLCBlbGVtID0+IGNvbnRhaW5lci5pbnNlcnRBZGphY2VudEVsZW1lbnQoXCJhZnRlcmJlZ2luXCIsIGVsZW0pKVxuICAgICAgfSlcbiAgICB9XG4gIH1cbn1cbiIsICJ2YXIgRE9DVU1FTlRfRlJBR01FTlRfTk9ERSA9IDExO1xuXG5mdW5jdGlvbiBtb3JwaEF0dHJzKGZyb21Ob2RlLCB0b05vZGUpIHtcbiAgICB2YXIgdG9Ob2RlQXR0cnMgPSB0b05vZGUuYXR0cmlidXRlcztcbiAgICB2YXIgYXR0cjtcbiAgICB2YXIgYXR0ck5hbWU7XG4gICAgdmFyIGF0dHJOYW1lc3BhY2VVUkk7XG4gICAgdmFyIGF0dHJWYWx1ZTtcbiAgICB2YXIgZnJvbVZhbHVlO1xuXG4gICAgLy8gZG9jdW1lbnQtZnJhZ21lbnRzIGRvbnQgaGF2ZSBhdHRyaWJ1dGVzIHNvIGxldHMgbm90IGRvIGFueXRoaW5nXG4gICAgaWYgKHRvTm9kZS5ub2RlVHlwZSA9PT0gRE9DVU1FTlRfRlJBR01FTlRfTk9ERSB8fCBmcm9tTm9kZS5ub2RlVHlwZSA9PT0gRE9DVU1FTlRfRlJBR01FTlRfTk9ERSkge1xuICAgICAgcmV0dXJuO1xuICAgIH1cblxuICAgIC8vIHVwZGF0ZSBhdHRyaWJ1dGVzIG9uIG9yaWdpbmFsIERPTSBlbGVtZW50XG4gICAgZm9yICh2YXIgaSA9IHRvTm9kZUF0dHJzLmxlbmd0aCAtIDE7IGkgPj0gMDsgaS0tKSB7XG4gICAgICAgIGF0dHIgPSB0b05vZGVBdHRyc1tpXTtcbiAgICAgICAgYXR0ck5hbWUgPSBhdHRyLm5hbWU7XG4gICAgICAgIGF0dHJOYW1lc3BhY2VVUkkgPSBhdHRyLm5hbWVzcGFjZVVSSTtcbiAgICAgICAgYXR0clZhbHVlID0gYXR0ci52YWx1ZTtcblxuICAgICAgICBpZiAoYXR0ck5hbWVzcGFjZVVSSSkge1xuICAgICAgICAgICAgYXR0ck5hbWUgPSBhdHRyLmxvY2FsTmFtZSB8fCBhdHRyTmFtZTtcbiAgICAgICAgICAgIGZyb21WYWx1ZSA9IGZyb21Ob2RlLmdldEF0dHJpYnV0ZU5TKGF0dHJOYW1lc3BhY2VVUkksIGF0dHJOYW1lKTtcblxuICAgICAgICAgICAgaWYgKGZyb21WYWx1ZSAhPT0gYXR0clZhbHVlKSB7XG4gICAgICAgICAgICAgICAgaWYgKGF0dHIucHJlZml4ID09PSAneG1sbnMnKXtcbiAgICAgICAgICAgICAgICAgICAgYXR0ck5hbWUgPSBhdHRyLm5hbWU7IC8vIEl0J3Mgbm90IGFsbG93ZWQgdG8gc2V0IGFuIGF0dHJpYnV0ZSB3aXRoIHRoZSBYTUxOUyBuYW1lc3BhY2Ugd2l0aG91dCBzcGVjaWZ5aW5nIHRoZSBgeG1sbnNgIHByZWZpeFxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICBmcm9tTm9kZS5zZXRBdHRyaWJ1dGVOUyhhdHRyTmFtZXNwYWNlVVJJLCBhdHRyTmFtZSwgYXR0clZhbHVlKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGZyb21WYWx1ZSA9IGZyb21Ob2RlLmdldEF0dHJpYnV0ZShhdHRyTmFtZSk7XG5cbiAgICAgICAgICAgIGlmIChmcm9tVmFsdWUgIT09IGF0dHJWYWx1ZSkge1xuICAgICAgICAgICAgICAgIGZyb21Ob2RlLnNldEF0dHJpYnV0ZShhdHRyTmFtZSwgYXR0clZhbHVlKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8vIFJlbW92ZSBhbnkgZXh0cmEgYXR0cmlidXRlcyBmb3VuZCBvbiB0aGUgb3JpZ2luYWwgRE9NIGVsZW1lbnQgdGhhdFxuICAgIC8vIHdlcmVuJ3QgZm91bmQgb24gdGhlIHRhcmdldCBlbGVtZW50LlxuICAgIHZhciBmcm9tTm9kZUF0dHJzID0gZnJvbU5vZGUuYXR0cmlidXRlcztcblxuICAgIGZvciAodmFyIGQgPSBmcm9tTm9kZUF0dHJzLmxlbmd0aCAtIDE7IGQgPj0gMDsgZC0tKSB7XG4gICAgICAgIGF0dHIgPSBmcm9tTm9kZUF0dHJzW2RdO1xuICAgICAgICBhdHRyTmFtZSA9IGF0dHIubmFtZTtcbiAgICAgICAgYXR0ck5hbWVzcGFjZVVSSSA9IGF0dHIubmFtZXNwYWNlVVJJO1xuXG4gICAgICAgIGlmIChhdHRyTmFtZXNwYWNlVVJJKSB7XG4gICAgICAgICAgICBhdHRyTmFtZSA9IGF0dHIubG9jYWxOYW1lIHx8IGF0dHJOYW1lO1xuXG4gICAgICAgICAgICBpZiAoIXRvTm9kZS5oYXNBdHRyaWJ1dGVOUyhhdHRyTmFtZXNwYWNlVVJJLCBhdHRyTmFtZSkpIHtcbiAgICAgICAgICAgICAgICBmcm9tTm9kZS5yZW1vdmVBdHRyaWJ1dGVOUyhhdHRyTmFtZXNwYWNlVVJJLCBhdHRyTmFtZSk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBpZiAoIXRvTm9kZS5oYXNBdHRyaWJ1dGUoYXR0ck5hbWUpKSB7XG4gICAgICAgICAgICAgICAgZnJvbU5vZGUucmVtb3ZlQXR0cmlidXRlKGF0dHJOYW1lKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgIH1cbn1cblxudmFyIHJhbmdlOyAvLyBDcmVhdGUgYSByYW5nZSBvYmplY3QgZm9yIGVmZmljZW50bHkgcmVuZGVyaW5nIHN0cmluZ3MgdG8gZWxlbWVudHMuXG52YXIgTlNfWEhUTUwgPSAnaHR0cDovL3d3dy53My5vcmcvMTk5OS94aHRtbCc7XG5cbnZhciBkb2MgPSB0eXBlb2YgZG9jdW1lbnQgPT09ICd1bmRlZmluZWQnID8gdW5kZWZpbmVkIDogZG9jdW1lbnQ7XG52YXIgSEFTX1RFTVBMQVRFX1NVUFBPUlQgPSAhIWRvYyAmJiAnY29udGVudCcgaW4gZG9jLmNyZWF0ZUVsZW1lbnQoJ3RlbXBsYXRlJyk7XG52YXIgSEFTX1JBTkdFX1NVUFBPUlQgPSAhIWRvYyAmJiBkb2MuY3JlYXRlUmFuZ2UgJiYgJ2NyZWF0ZUNvbnRleHR1YWxGcmFnbWVudCcgaW4gZG9jLmNyZWF0ZVJhbmdlKCk7XG5cbmZ1bmN0aW9uIGNyZWF0ZUZyYWdtZW50RnJvbVRlbXBsYXRlKHN0cikge1xuICAgIHZhciB0ZW1wbGF0ZSA9IGRvYy5jcmVhdGVFbGVtZW50KCd0ZW1wbGF0ZScpO1xuICAgIHRlbXBsYXRlLmlubmVySFRNTCA9IHN0cjtcbiAgICByZXR1cm4gdGVtcGxhdGUuY29udGVudC5jaGlsZE5vZGVzWzBdO1xufVxuXG5mdW5jdGlvbiBjcmVhdGVGcmFnbWVudEZyb21SYW5nZShzdHIpIHtcbiAgICBpZiAoIXJhbmdlKSB7XG4gICAgICAgIHJhbmdlID0gZG9jLmNyZWF0ZVJhbmdlKCk7XG4gICAgICAgIHJhbmdlLnNlbGVjdE5vZGUoZG9jLmJvZHkpO1xuICAgIH1cblxuICAgIHZhciBmcmFnbWVudCA9IHJhbmdlLmNyZWF0ZUNvbnRleHR1YWxGcmFnbWVudChzdHIpO1xuICAgIHJldHVybiBmcmFnbWVudC5jaGlsZE5vZGVzWzBdO1xufVxuXG5mdW5jdGlvbiBjcmVhdGVGcmFnbWVudEZyb21XcmFwKHN0cikge1xuICAgIHZhciBmcmFnbWVudCA9IGRvYy5jcmVhdGVFbGVtZW50KCdib2R5Jyk7XG4gICAgZnJhZ21lbnQuaW5uZXJIVE1MID0gc3RyO1xuICAgIHJldHVybiBmcmFnbWVudC5jaGlsZE5vZGVzWzBdO1xufVxuXG4vKipcbiAqIFRoaXMgaXMgYWJvdXQgdGhlIHNhbWVcbiAqIHZhciBodG1sID0gbmV3IERPTVBhcnNlcigpLnBhcnNlRnJvbVN0cmluZyhzdHIsICd0ZXh0L2h0bWwnKTtcbiAqIHJldHVybiBodG1sLmJvZHkuZmlyc3RDaGlsZDtcbiAqXG4gKiBAbWV0aG9kIHRvRWxlbWVudFxuICogQHBhcmFtIHtTdHJpbmd9IHN0clxuICovXG5mdW5jdGlvbiB0b0VsZW1lbnQoc3RyKSB7XG4gICAgc3RyID0gc3RyLnRyaW0oKTtcbiAgICBpZiAoSEFTX1RFTVBMQVRFX1NVUFBPUlQpIHtcbiAgICAgIC8vIGF2b2lkIHJlc3RyaWN0aW9ucyBvbiBjb250ZW50IGZvciB0aGluZ3MgbGlrZSBgPHRyPjx0aD5IaTwvdGg+PC90cj5gIHdoaWNoXG4gICAgICAvLyBjcmVhdGVDb250ZXh0dWFsRnJhZ21lbnQgZG9lc24ndCBzdXBwb3J0XG4gICAgICAvLyA8dGVtcGxhdGU+IHN1cHBvcnQgbm90IGF2YWlsYWJsZSBpbiBJRVxuICAgICAgcmV0dXJuIGNyZWF0ZUZyYWdtZW50RnJvbVRlbXBsYXRlKHN0cik7XG4gICAgfSBlbHNlIGlmIChIQVNfUkFOR0VfU1VQUE9SVCkge1xuICAgICAgcmV0dXJuIGNyZWF0ZUZyYWdtZW50RnJvbVJhbmdlKHN0cik7XG4gICAgfVxuXG4gICAgcmV0dXJuIGNyZWF0ZUZyYWdtZW50RnJvbVdyYXAoc3RyKTtcbn1cblxuLyoqXG4gKiBSZXR1cm5zIHRydWUgaWYgdHdvIG5vZGUncyBuYW1lcyBhcmUgdGhlIHNhbWUuXG4gKlxuICogTk9URTogV2UgZG9uJ3QgYm90aGVyIGNoZWNraW5nIGBuYW1lc3BhY2VVUklgIGJlY2F1c2UgeW91IHdpbGwgbmV2ZXIgZmluZCB0d28gSFRNTCBlbGVtZW50cyB3aXRoIHRoZSBzYW1lXG4gKiAgICAgICBub2RlTmFtZSBhbmQgZGlmZmVyZW50IG5hbWVzcGFjZSBVUklzLlxuICpcbiAqIEBwYXJhbSB7RWxlbWVudH0gYVxuICogQHBhcmFtIHtFbGVtZW50fSBiIFRoZSB0YXJnZXQgZWxlbWVudFxuICogQHJldHVybiB7Ym9vbGVhbn1cbiAqL1xuZnVuY3Rpb24gY29tcGFyZU5vZGVOYW1lcyhmcm9tRWwsIHRvRWwpIHtcbiAgICB2YXIgZnJvbU5vZGVOYW1lID0gZnJvbUVsLm5vZGVOYW1lO1xuICAgIHZhciB0b05vZGVOYW1lID0gdG9FbC5ub2RlTmFtZTtcbiAgICB2YXIgZnJvbUNvZGVTdGFydCwgdG9Db2RlU3RhcnQ7XG5cbiAgICBpZiAoZnJvbU5vZGVOYW1lID09PSB0b05vZGVOYW1lKSB7XG4gICAgICAgIHJldHVybiB0cnVlO1xuICAgIH1cblxuICAgIGZyb21Db2RlU3RhcnQgPSBmcm9tTm9kZU5hbWUuY2hhckNvZGVBdCgwKTtcbiAgICB0b0NvZGVTdGFydCA9IHRvTm9kZU5hbWUuY2hhckNvZGVBdCgwKTtcblxuICAgIC8vIElmIHRoZSB0YXJnZXQgZWxlbWVudCBpcyBhIHZpcnR1YWwgRE9NIG5vZGUgb3IgU1ZHIG5vZGUgdGhlbiB3ZSBtYXlcbiAgICAvLyBuZWVkIHRvIG5vcm1hbGl6ZSB0aGUgdGFnIG5hbWUgYmVmb3JlIGNvbXBhcmluZy4gTm9ybWFsIEhUTUwgZWxlbWVudHMgdGhhdCBhcmVcbiAgICAvLyBpbiB0aGUgXCJodHRwOi8vd3d3LnczLm9yZy8xOTk5L3hodG1sXCJcbiAgICAvLyBhcmUgY29udmVydGVkIHRvIHVwcGVyIGNhc2VcbiAgICBpZiAoZnJvbUNvZGVTdGFydCA8PSA5MCAmJiB0b0NvZGVTdGFydCA+PSA5NykgeyAvLyBmcm9tIGlzIHVwcGVyIGFuZCB0byBpcyBsb3dlclxuICAgICAgICByZXR1cm4gZnJvbU5vZGVOYW1lID09PSB0b05vZGVOYW1lLnRvVXBwZXJDYXNlKCk7XG4gICAgfSBlbHNlIGlmICh0b0NvZGVTdGFydCA8PSA5MCAmJiBmcm9tQ29kZVN0YXJ0ID49IDk3KSB7IC8vIHRvIGlzIHVwcGVyIGFuZCBmcm9tIGlzIGxvd2VyXG4gICAgICAgIHJldHVybiB0b05vZGVOYW1lID09PSBmcm9tTm9kZU5hbWUudG9VcHBlckNhc2UoKTtcbiAgICB9IGVsc2Uge1xuICAgICAgICByZXR1cm4gZmFsc2U7XG4gICAgfVxufVxuXG4vKipcbiAqIENyZWF0ZSBhbiBlbGVtZW50LCBvcHRpb25hbGx5IHdpdGggYSBrbm93biBuYW1lc3BhY2UgVVJJLlxuICpcbiAqIEBwYXJhbSB7c3RyaW5nfSBuYW1lIHRoZSBlbGVtZW50IG5hbWUsIGUuZy4gJ2Rpdicgb3IgJ3N2ZydcbiAqIEBwYXJhbSB7c3RyaW5nfSBbbmFtZXNwYWNlVVJJXSB0aGUgZWxlbWVudCdzIG5hbWVzcGFjZSBVUkksIGkuZS4gdGhlIHZhbHVlIG9mXG4gKiBpdHMgYHhtbG5zYCBhdHRyaWJ1dGUgb3IgaXRzIGluZmVycmVkIG5hbWVzcGFjZS5cbiAqXG4gKiBAcmV0dXJuIHtFbGVtZW50fVxuICovXG5mdW5jdGlvbiBjcmVhdGVFbGVtZW50TlMobmFtZSwgbmFtZXNwYWNlVVJJKSB7XG4gICAgcmV0dXJuICFuYW1lc3BhY2VVUkkgfHwgbmFtZXNwYWNlVVJJID09PSBOU19YSFRNTCA/XG4gICAgICAgIGRvYy5jcmVhdGVFbGVtZW50KG5hbWUpIDpcbiAgICAgICAgZG9jLmNyZWF0ZUVsZW1lbnROUyhuYW1lc3BhY2VVUkksIG5hbWUpO1xufVxuXG4vKipcbiAqIENvcGllcyB0aGUgY2hpbGRyZW4gb2Ygb25lIERPTSBlbGVtZW50IHRvIGFub3RoZXIgRE9NIGVsZW1lbnRcbiAqL1xuZnVuY3Rpb24gbW92ZUNoaWxkcmVuKGZyb21FbCwgdG9FbCkge1xuICAgIHZhciBjdXJDaGlsZCA9IGZyb21FbC5maXJzdENoaWxkO1xuICAgIHdoaWxlIChjdXJDaGlsZCkge1xuICAgICAgICB2YXIgbmV4dENoaWxkID0gY3VyQ2hpbGQubmV4dFNpYmxpbmc7XG4gICAgICAgIHRvRWwuYXBwZW5kQ2hpbGQoY3VyQ2hpbGQpO1xuICAgICAgICBjdXJDaGlsZCA9IG5leHRDaGlsZDtcbiAgICB9XG4gICAgcmV0dXJuIHRvRWw7XG59XG5cbmZ1bmN0aW9uIHN5bmNCb29sZWFuQXR0clByb3AoZnJvbUVsLCB0b0VsLCBuYW1lKSB7XG4gICAgaWYgKGZyb21FbFtuYW1lXSAhPT0gdG9FbFtuYW1lXSkge1xuICAgICAgICBmcm9tRWxbbmFtZV0gPSB0b0VsW25hbWVdO1xuICAgICAgICBpZiAoZnJvbUVsW25hbWVdKSB7XG4gICAgICAgICAgICBmcm9tRWwuc2V0QXR0cmlidXRlKG5hbWUsICcnKTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGZyb21FbC5yZW1vdmVBdHRyaWJ1dGUobmFtZSk7XG4gICAgICAgIH1cbiAgICB9XG59XG5cbnZhciBzcGVjaWFsRWxIYW5kbGVycyA9IHtcbiAgICBPUFRJT046IGZ1bmN0aW9uKGZyb21FbCwgdG9FbCkge1xuICAgICAgICB2YXIgcGFyZW50Tm9kZSA9IGZyb21FbC5wYXJlbnROb2RlO1xuICAgICAgICBpZiAocGFyZW50Tm9kZSkge1xuICAgICAgICAgICAgdmFyIHBhcmVudE5hbWUgPSBwYXJlbnROb2RlLm5vZGVOYW1lLnRvVXBwZXJDYXNlKCk7XG4gICAgICAgICAgICBpZiAocGFyZW50TmFtZSA9PT0gJ09QVEdST1VQJykge1xuICAgICAgICAgICAgICAgIHBhcmVudE5vZGUgPSBwYXJlbnROb2RlLnBhcmVudE5vZGU7XG4gICAgICAgICAgICAgICAgcGFyZW50TmFtZSA9IHBhcmVudE5vZGUgJiYgcGFyZW50Tm9kZS5ub2RlTmFtZS50b1VwcGVyQ2FzZSgpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgaWYgKHBhcmVudE5hbWUgPT09ICdTRUxFQ1QnICYmICFwYXJlbnROb2RlLmhhc0F0dHJpYnV0ZSgnbXVsdGlwbGUnKSkge1xuICAgICAgICAgICAgICAgIGlmIChmcm9tRWwuaGFzQXR0cmlidXRlKCdzZWxlY3RlZCcpICYmICF0b0VsLnNlbGVjdGVkKSB7XG4gICAgICAgICAgICAgICAgICAgIC8vIFdvcmthcm91bmQgZm9yIE1TIEVkZ2UgYnVnIHdoZXJlIHRoZSAnc2VsZWN0ZWQnIGF0dHJpYnV0ZSBjYW4gb25seSBiZVxuICAgICAgICAgICAgICAgICAgICAvLyByZW1vdmVkIGlmIHNldCB0byBhIG5vbi1lbXB0eSB2YWx1ZTpcbiAgICAgICAgICAgICAgICAgICAgLy8gaHR0cHM6Ly9kZXZlbG9wZXIubWljcm9zb2Z0LmNvbS9lbi11cy9taWNyb3NvZnQtZWRnZS9wbGF0Zm9ybS9pc3N1ZXMvMTIwODc2NzkvXG4gICAgICAgICAgICAgICAgICAgIGZyb21FbC5zZXRBdHRyaWJ1dGUoJ3NlbGVjdGVkJywgJ3NlbGVjdGVkJyk7XG4gICAgICAgICAgICAgICAgICAgIGZyb21FbC5yZW1vdmVBdHRyaWJ1dGUoJ3NlbGVjdGVkJyk7XG4gICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIC8vIFdlIGhhdmUgdG8gcmVzZXQgc2VsZWN0IGVsZW1lbnQncyBzZWxlY3RlZEluZGV4IHRvIC0xLCBvdGhlcndpc2Ugc2V0dGluZ1xuICAgICAgICAgICAgICAgIC8vIGZyb21FbC5zZWxlY3RlZCB1c2luZyB0aGUgc3luY0Jvb2xlYW5BdHRyUHJvcCBiZWxvdyBoYXMgbm8gZWZmZWN0LlxuICAgICAgICAgICAgICAgIC8vIFRoZSBjb3JyZWN0IHNlbGVjdGVkSW5kZXggd2lsbCBiZSBzZXQgaW4gdGhlIFNFTEVDVCBzcGVjaWFsIGhhbmRsZXIgYmVsb3cuXG4gICAgICAgICAgICAgICAgcGFyZW50Tm9kZS5zZWxlY3RlZEluZGV4ID0gLTE7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICAgICAgc3luY0Jvb2xlYW5BdHRyUHJvcChmcm9tRWwsIHRvRWwsICdzZWxlY3RlZCcpO1xuICAgIH0sXG4gICAgLyoqXG4gICAgICogVGhlIFwidmFsdWVcIiBhdHRyaWJ1dGUgaXMgc3BlY2lhbCBmb3IgdGhlIDxpbnB1dD4gZWxlbWVudCBzaW5jZSBpdCBzZXRzXG4gICAgICogdGhlIGluaXRpYWwgdmFsdWUuIENoYW5naW5nIHRoZSBcInZhbHVlXCIgYXR0cmlidXRlIHdpdGhvdXQgY2hhbmdpbmcgdGhlXG4gICAgICogXCJ2YWx1ZVwiIHByb3BlcnR5IHdpbGwgaGF2ZSBubyBlZmZlY3Qgc2luY2UgaXQgaXMgb25seSB1c2VkIHRvIHRoZSBzZXQgdGhlXG4gICAgICogaW5pdGlhbCB2YWx1ZS4gIFNpbWlsYXIgZm9yIHRoZSBcImNoZWNrZWRcIiBhdHRyaWJ1dGUsIGFuZCBcImRpc2FibGVkXCIuXG4gICAgICovXG4gICAgSU5QVVQ6IGZ1bmN0aW9uKGZyb21FbCwgdG9FbCkge1xuICAgICAgICBzeW5jQm9vbGVhbkF0dHJQcm9wKGZyb21FbCwgdG9FbCwgJ2NoZWNrZWQnKTtcbiAgICAgICAgc3luY0Jvb2xlYW5BdHRyUHJvcChmcm9tRWwsIHRvRWwsICdkaXNhYmxlZCcpO1xuXG4gICAgICAgIGlmIChmcm9tRWwudmFsdWUgIT09IHRvRWwudmFsdWUpIHtcbiAgICAgICAgICAgIGZyb21FbC52YWx1ZSA9IHRvRWwudmFsdWU7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoIXRvRWwuaGFzQXR0cmlidXRlKCd2YWx1ZScpKSB7XG4gICAgICAgICAgICBmcm9tRWwucmVtb3ZlQXR0cmlidXRlKCd2YWx1ZScpO1xuICAgICAgICB9XG4gICAgfSxcblxuICAgIFRFWFRBUkVBOiBmdW5jdGlvbihmcm9tRWwsIHRvRWwpIHtcbiAgICAgICAgdmFyIG5ld1ZhbHVlID0gdG9FbC52YWx1ZTtcbiAgICAgICAgaWYgKGZyb21FbC52YWx1ZSAhPT0gbmV3VmFsdWUpIHtcbiAgICAgICAgICAgIGZyb21FbC52YWx1ZSA9IG5ld1ZhbHVlO1xuICAgICAgICB9XG5cbiAgICAgICAgdmFyIGZpcnN0Q2hpbGQgPSBmcm9tRWwuZmlyc3RDaGlsZDtcbiAgICAgICAgaWYgKGZpcnN0Q2hpbGQpIHtcbiAgICAgICAgICAgIC8vIE5lZWRlZCBmb3IgSUUuIEFwcGFyZW50bHkgSUUgc2V0cyB0aGUgcGxhY2Vob2xkZXIgYXMgdGhlXG4gICAgICAgICAgICAvLyBub2RlIHZhbHVlIGFuZCB2aXNlIHZlcnNhLiBUaGlzIGlnbm9yZXMgYW4gZW1wdHkgdXBkYXRlLlxuICAgICAgICAgICAgdmFyIG9sZFZhbHVlID0gZmlyc3RDaGlsZC5ub2RlVmFsdWU7XG5cbiAgICAgICAgICAgIGlmIChvbGRWYWx1ZSA9PSBuZXdWYWx1ZSB8fCAoIW5ld1ZhbHVlICYmIG9sZFZhbHVlID09IGZyb21FbC5wbGFjZWhvbGRlcikpIHtcbiAgICAgICAgICAgICAgICByZXR1cm47XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIGZpcnN0Q2hpbGQubm9kZVZhbHVlID0gbmV3VmFsdWU7XG4gICAgICAgIH1cbiAgICB9LFxuICAgIFNFTEVDVDogZnVuY3Rpb24oZnJvbUVsLCB0b0VsKSB7XG4gICAgICAgIGlmICghdG9FbC5oYXNBdHRyaWJ1dGUoJ211bHRpcGxlJykpIHtcbiAgICAgICAgICAgIHZhciBzZWxlY3RlZEluZGV4ID0gLTE7XG4gICAgICAgICAgICB2YXIgaSA9IDA7XG4gICAgICAgICAgICAvLyBXZSBoYXZlIHRvIGxvb3AgdGhyb3VnaCBjaGlsZHJlbiBvZiBmcm9tRWwsIG5vdCB0b0VsIHNpbmNlIG5vZGVzIGNhbiBiZSBtb3ZlZFxuICAgICAgICAgICAgLy8gZnJvbSB0b0VsIHRvIGZyb21FbCBkaXJlY3RseSB3aGVuIG1vcnBoaW5nLlxuICAgICAgICAgICAgLy8gQXQgdGhlIHRpbWUgdGhpcyBzcGVjaWFsIGhhbmRsZXIgaXMgaW52b2tlZCwgYWxsIGNoaWxkcmVuIGhhdmUgYWxyZWFkeSBiZWVuIG1vcnBoZWRcbiAgICAgICAgICAgIC8vIGFuZCBhcHBlbmRlZCB0byAvIHJlbW92ZWQgZnJvbSBmcm9tRWwsIHNvIHVzaW5nIGZyb21FbCBoZXJlIGlzIHNhZmUgYW5kIGNvcnJlY3QuXG4gICAgICAgICAgICB2YXIgY3VyQ2hpbGQgPSBmcm9tRWwuZmlyc3RDaGlsZDtcbiAgICAgICAgICAgIHZhciBvcHRncm91cDtcbiAgICAgICAgICAgIHZhciBub2RlTmFtZTtcbiAgICAgICAgICAgIHdoaWxlKGN1ckNoaWxkKSB7XG4gICAgICAgICAgICAgICAgbm9kZU5hbWUgPSBjdXJDaGlsZC5ub2RlTmFtZSAmJiBjdXJDaGlsZC5ub2RlTmFtZS50b1VwcGVyQ2FzZSgpO1xuICAgICAgICAgICAgICAgIGlmIChub2RlTmFtZSA9PT0gJ09QVEdST1VQJykge1xuICAgICAgICAgICAgICAgICAgICBvcHRncm91cCA9IGN1ckNoaWxkO1xuICAgICAgICAgICAgICAgICAgICBjdXJDaGlsZCA9IG9wdGdyb3VwLmZpcnN0Q2hpbGQ7XG4gICAgICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICAgICAgaWYgKG5vZGVOYW1lID09PSAnT1BUSU9OJykge1xuICAgICAgICAgICAgICAgICAgICAgICAgaWYgKGN1ckNoaWxkLmhhc0F0dHJpYnV0ZSgnc2VsZWN0ZWQnKSkge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIHNlbGVjdGVkSW5kZXggPSBpO1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIGJyZWFrO1xuICAgICAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgICAgICAgICAgaSsrO1xuICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgICAgIGN1ckNoaWxkID0gY3VyQ2hpbGQubmV4dFNpYmxpbmc7XG4gICAgICAgICAgICAgICAgICAgIGlmICghY3VyQ2hpbGQgJiYgb3B0Z3JvdXApIHtcbiAgICAgICAgICAgICAgICAgICAgICAgIGN1ckNoaWxkID0gb3B0Z3JvdXAubmV4dFNpYmxpbmc7XG4gICAgICAgICAgICAgICAgICAgICAgICBvcHRncm91cCA9IG51bGw7XG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIGZyb21FbC5zZWxlY3RlZEluZGV4ID0gc2VsZWN0ZWRJbmRleDtcbiAgICAgICAgfVxuICAgIH1cbn07XG5cbnZhciBFTEVNRU5UX05PREUgPSAxO1xudmFyIERPQ1VNRU5UX0ZSQUdNRU5UX05PREUkMSA9IDExO1xudmFyIFRFWFRfTk9ERSA9IDM7XG52YXIgQ09NTUVOVF9OT0RFID0gODtcblxuZnVuY3Rpb24gbm9vcCgpIHt9XG5cbmZ1bmN0aW9uIGRlZmF1bHRHZXROb2RlS2V5KG5vZGUpIHtcbiAgaWYgKG5vZGUpIHtcbiAgICByZXR1cm4gKG5vZGUuZ2V0QXR0cmlidXRlICYmIG5vZGUuZ2V0QXR0cmlidXRlKCdpZCcpKSB8fCBub2RlLmlkO1xuICB9XG59XG5cbmZ1bmN0aW9uIG1vcnBoZG9tRmFjdG9yeShtb3JwaEF0dHJzKSB7XG5cbiAgcmV0dXJuIGZ1bmN0aW9uIG1vcnBoZG9tKGZyb21Ob2RlLCB0b05vZGUsIG9wdGlvbnMpIHtcbiAgICBpZiAoIW9wdGlvbnMpIHtcbiAgICAgIG9wdGlvbnMgPSB7fTtcbiAgICB9XG5cbiAgICBpZiAodHlwZW9mIHRvTm9kZSA9PT0gJ3N0cmluZycpIHtcbiAgICAgIGlmIChmcm9tTm9kZS5ub2RlTmFtZSA9PT0gJyNkb2N1bWVudCcgfHwgZnJvbU5vZGUubm9kZU5hbWUgPT09ICdIVE1MJyB8fCBmcm9tTm9kZS5ub2RlTmFtZSA9PT0gJ0JPRFknKSB7XG4gICAgICAgIHZhciB0b05vZGVIdG1sID0gdG9Ob2RlO1xuICAgICAgICB0b05vZGUgPSBkb2MuY3JlYXRlRWxlbWVudCgnaHRtbCcpO1xuICAgICAgICB0b05vZGUuaW5uZXJIVE1MID0gdG9Ob2RlSHRtbDtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHRvTm9kZSA9IHRvRWxlbWVudCh0b05vZGUpO1xuICAgICAgfVxuICAgIH0gZWxzZSBpZiAodG9Ob2RlLm5vZGVUeXBlID09PSBET0NVTUVOVF9GUkFHTUVOVF9OT0RFJDEpIHtcbiAgICAgIHRvTm9kZSA9IHRvTm9kZS5maXJzdEVsZW1lbnRDaGlsZDtcbiAgICB9XG5cbiAgICB2YXIgZ2V0Tm9kZUtleSA9IG9wdGlvbnMuZ2V0Tm9kZUtleSB8fCBkZWZhdWx0R2V0Tm9kZUtleTtcbiAgICB2YXIgb25CZWZvcmVOb2RlQWRkZWQgPSBvcHRpb25zLm9uQmVmb3JlTm9kZUFkZGVkIHx8IG5vb3A7XG4gICAgdmFyIG9uTm9kZUFkZGVkID0gb3B0aW9ucy5vbk5vZGVBZGRlZCB8fCBub29wO1xuICAgIHZhciBvbkJlZm9yZUVsVXBkYXRlZCA9IG9wdGlvbnMub25CZWZvcmVFbFVwZGF0ZWQgfHwgbm9vcDtcbiAgICB2YXIgb25FbFVwZGF0ZWQgPSBvcHRpb25zLm9uRWxVcGRhdGVkIHx8IG5vb3A7XG4gICAgdmFyIG9uQmVmb3JlTm9kZURpc2NhcmRlZCA9IG9wdGlvbnMub25CZWZvcmVOb2RlRGlzY2FyZGVkIHx8IG5vb3A7XG4gICAgdmFyIG9uTm9kZURpc2NhcmRlZCA9IG9wdGlvbnMub25Ob2RlRGlzY2FyZGVkIHx8IG5vb3A7XG4gICAgdmFyIG9uQmVmb3JlRWxDaGlsZHJlblVwZGF0ZWQgPSBvcHRpb25zLm9uQmVmb3JlRWxDaGlsZHJlblVwZGF0ZWQgfHwgbm9vcDtcbiAgICB2YXIgc2tpcEZyb21DaGlsZHJlbiA9IG9wdGlvbnMuc2tpcEZyb21DaGlsZHJlbiB8fCBub29wO1xuICAgIHZhciBhZGRDaGlsZCA9IG9wdGlvbnMuYWRkQ2hpbGQgfHwgZnVuY3Rpb24ocGFyZW50LCBjaGlsZCl7IHJldHVybiBwYXJlbnQuYXBwZW5kQ2hpbGQoY2hpbGQpOyB9O1xuICAgIHZhciBjaGlsZHJlbk9ubHkgPSBvcHRpb25zLmNoaWxkcmVuT25seSA9PT0gdHJ1ZTtcblxuICAgIC8vIFRoaXMgb2JqZWN0IGlzIHVzZWQgYXMgYSBsb29rdXAgdG8gcXVpY2tseSBmaW5kIGFsbCBrZXllZCBlbGVtZW50cyBpbiB0aGUgb3JpZ2luYWwgRE9NIHRyZWUuXG4gICAgdmFyIGZyb21Ob2Rlc0xvb2t1cCA9IE9iamVjdC5jcmVhdGUobnVsbCk7XG4gICAgdmFyIGtleWVkUmVtb3ZhbExpc3QgPSBbXTtcblxuICAgIGZ1bmN0aW9uIGFkZEtleWVkUmVtb3ZhbChrZXkpIHtcbiAgICAgIGtleWVkUmVtb3ZhbExpc3QucHVzaChrZXkpO1xuICAgIH1cblxuICAgIGZ1bmN0aW9uIHdhbGtEaXNjYXJkZWRDaGlsZE5vZGVzKG5vZGUsIHNraXBLZXllZE5vZGVzKSB7XG4gICAgICBpZiAobm9kZS5ub2RlVHlwZSA9PT0gRUxFTUVOVF9OT0RFKSB7XG4gICAgICAgIHZhciBjdXJDaGlsZCA9IG5vZGUuZmlyc3RDaGlsZDtcbiAgICAgICAgd2hpbGUgKGN1ckNoaWxkKSB7XG5cbiAgICAgICAgICB2YXIga2V5ID0gdW5kZWZpbmVkO1xuXG4gICAgICAgICAgaWYgKHNraXBLZXllZE5vZGVzICYmIChrZXkgPSBnZXROb2RlS2V5KGN1ckNoaWxkKSkpIHtcbiAgICAgICAgICAgIC8vIElmIHdlIGFyZSBza2lwcGluZyBrZXllZCBub2RlcyB0aGVuIHdlIGFkZCB0aGUga2V5XG4gICAgICAgICAgICAvLyB0byBhIGxpc3Qgc28gdGhhdCBpdCBjYW4gYmUgaGFuZGxlZCBhdCB0aGUgdmVyeSBlbmQuXG4gICAgICAgICAgICBhZGRLZXllZFJlbW92YWwoa2V5KTtcbiAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgLy8gT25seSByZXBvcnQgdGhlIG5vZGUgYXMgZGlzY2FyZGVkIGlmIGl0IGlzIG5vdCBrZXllZC4gV2UgZG8gdGhpcyBiZWNhdXNlXG4gICAgICAgICAgICAvLyBhdCB0aGUgZW5kIHdlIGxvb3AgdGhyb3VnaCBhbGwga2V5ZWQgZWxlbWVudHMgdGhhdCB3ZXJlIHVubWF0Y2hlZFxuICAgICAgICAgICAgLy8gYW5kIHRoZW4gZGlzY2FyZCB0aGVtIGluIG9uZSBmaW5hbCBwYXNzLlxuICAgICAgICAgICAgb25Ob2RlRGlzY2FyZGVkKGN1ckNoaWxkKTtcbiAgICAgICAgICAgIGlmIChjdXJDaGlsZC5maXJzdENoaWxkKSB7XG4gICAgICAgICAgICAgIHdhbGtEaXNjYXJkZWRDaGlsZE5vZGVzKGN1ckNoaWxkLCBza2lwS2V5ZWROb2Rlcyk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgY3VyQ2hpbGQgPSBjdXJDaGlsZC5uZXh0U2libGluZztcbiAgICAgICAgfVxuICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICogUmVtb3ZlcyBhIERPTSBub2RlIG91dCBvZiB0aGUgb3JpZ2luYWwgRE9NXG4gICAgKlxuICAgICogQHBhcmFtICB7Tm9kZX0gbm9kZSBUaGUgbm9kZSB0byByZW1vdmVcbiAgICAqIEBwYXJhbSAge05vZGV9IHBhcmVudE5vZGUgVGhlIG5vZGVzIHBhcmVudFxuICAgICogQHBhcmFtICB7Qm9vbGVhbn0gc2tpcEtleWVkTm9kZXMgSWYgdHJ1ZSB0aGVuIGVsZW1lbnRzIHdpdGgga2V5cyB3aWxsIGJlIHNraXBwZWQgYW5kIG5vdCBkaXNjYXJkZWQuXG4gICAgKiBAcmV0dXJuIHt1bmRlZmluZWR9XG4gICAgKi9cbiAgICBmdW5jdGlvbiByZW1vdmVOb2RlKG5vZGUsIHBhcmVudE5vZGUsIHNraXBLZXllZE5vZGVzKSB7XG4gICAgICBpZiAob25CZWZvcmVOb2RlRGlzY2FyZGVkKG5vZGUpID09PSBmYWxzZSkge1xuICAgICAgICByZXR1cm47XG4gICAgICB9XG5cbiAgICAgIGlmIChwYXJlbnROb2RlKSB7XG4gICAgICAgIHBhcmVudE5vZGUucmVtb3ZlQ2hpbGQobm9kZSk7XG4gICAgICB9XG5cbiAgICAgIG9uTm9kZURpc2NhcmRlZChub2RlKTtcbiAgICAgIHdhbGtEaXNjYXJkZWRDaGlsZE5vZGVzKG5vZGUsIHNraXBLZXllZE5vZGVzKTtcbiAgICB9XG5cbiAgICAvLyAvLyBUcmVlV2Fsa2VyIGltcGxlbWVudGF0aW9uIGlzIG5vIGZhc3RlciwgYnV0IGtlZXBpbmcgdGhpcyBhcm91bmQgaW4gY2FzZSB0aGlzIGNoYW5nZXMgaW4gdGhlIGZ1dHVyZVxuICAgIC8vIGZ1bmN0aW9uIGluZGV4VHJlZShyb290KSB7XG4gICAgLy8gICAgIHZhciB0cmVlV2Fsa2VyID0gZG9jdW1lbnQuY3JlYXRlVHJlZVdhbGtlcihcbiAgICAvLyAgICAgICAgIHJvb3QsXG4gICAgLy8gICAgICAgICBOb2RlRmlsdGVyLlNIT1dfRUxFTUVOVCk7XG4gICAgLy9cbiAgICAvLyAgICAgdmFyIGVsO1xuICAgIC8vICAgICB3aGlsZSgoZWwgPSB0cmVlV2Fsa2VyLm5leHROb2RlKCkpKSB7XG4gICAgLy8gICAgICAgICB2YXIga2V5ID0gZ2V0Tm9kZUtleShlbCk7XG4gICAgLy8gICAgICAgICBpZiAoa2V5KSB7XG4gICAgLy8gICAgICAgICAgICAgZnJvbU5vZGVzTG9va3VwW2tleV0gPSBlbDtcbiAgICAvLyAgICAgICAgIH1cbiAgICAvLyAgICAgfVxuICAgIC8vIH1cblxuICAgIC8vIC8vIE5vZGVJdGVyYXRvciBpbXBsZW1lbnRhdGlvbiBpcyBubyBmYXN0ZXIsIGJ1dCBrZWVwaW5nIHRoaXMgYXJvdW5kIGluIGNhc2UgdGhpcyBjaGFuZ2VzIGluIHRoZSBmdXR1cmVcbiAgICAvL1xuICAgIC8vIGZ1bmN0aW9uIGluZGV4VHJlZShub2RlKSB7XG4gICAgLy8gICAgIHZhciBub2RlSXRlcmF0b3IgPSBkb2N1bWVudC5jcmVhdGVOb2RlSXRlcmF0b3Iobm9kZSwgTm9kZUZpbHRlci5TSE9XX0VMRU1FTlQpO1xuICAgIC8vICAgICB2YXIgZWw7XG4gICAgLy8gICAgIHdoaWxlKChlbCA9IG5vZGVJdGVyYXRvci5uZXh0Tm9kZSgpKSkge1xuICAgIC8vICAgICAgICAgdmFyIGtleSA9IGdldE5vZGVLZXkoZWwpO1xuICAgIC8vICAgICAgICAgaWYgKGtleSkge1xuICAgIC8vICAgICAgICAgICAgIGZyb21Ob2Rlc0xvb2t1cFtrZXldID0gZWw7XG4gICAgLy8gICAgICAgICB9XG4gICAgLy8gICAgIH1cbiAgICAvLyB9XG5cbiAgICBmdW5jdGlvbiBpbmRleFRyZWUobm9kZSkge1xuICAgICAgaWYgKG5vZGUubm9kZVR5cGUgPT09IEVMRU1FTlRfTk9ERSB8fCBub2RlLm5vZGVUeXBlID09PSBET0NVTUVOVF9GUkFHTUVOVF9OT0RFJDEpIHtcbiAgICAgICAgdmFyIGN1ckNoaWxkID0gbm9kZS5maXJzdENoaWxkO1xuICAgICAgICB3aGlsZSAoY3VyQ2hpbGQpIHtcbiAgICAgICAgICB2YXIga2V5ID0gZ2V0Tm9kZUtleShjdXJDaGlsZCk7XG4gICAgICAgICAgaWYgKGtleSkge1xuICAgICAgICAgICAgZnJvbU5vZGVzTG9va3VwW2tleV0gPSBjdXJDaGlsZDtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICAvLyBXYWxrIHJlY3Vyc2l2ZWx5XG4gICAgICAgICAgaW5kZXhUcmVlKGN1ckNoaWxkKTtcblxuICAgICAgICAgIGN1ckNoaWxkID0gY3VyQ2hpbGQubmV4dFNpYmxpbmc7XG4gICAgICAgIH1cbiAgICAgIH1cbiAgICB9XG5cbiAgICBpbmRleFRyZWUoZnJvbU5vZGUpO1xuXG4gICAgZnVuY3Rpb24gaGFuZGxlTm9kZUFkZGVkKGVsKSB7XG4gICAgICBvbk5vZGVBZGRlZChlbCk7XG5cbiAgICAgIHZhciBjdXJDaGlsZCA9IGVsLmZpcnN0Q2hpbGQ7XG4gICAgICB3aGlsZSAoY3VyQ2hpbGQpIHtcbiAgICAgICAgdmFyIG5leHRTaWJsaW5nID0gY3VyQ2hpbGQubmV4dFNpYmxpbmc7XG5cbiAgICAgICAgdmFyIGtleSA9IGdldE5vZGVLZXkoY3VyQ2hpbGQpO1xuICAgICAgICBpZiAoa2V5KSB7XG4gICAgICAgICAgdmFyIHVubWF0Y2hlZEZyb21FbCA9IGZyb21Ob2Rlc0xvb2t1cFtrZXldO1xuICAgICAgICAgIC8vIGlmIHdlIGZpbmQgYSBkdXBsaWNhdGUgI2lkIG5vZGUgaW4gY2FjaGUsIHJlcGxhY2UgYGVsYCB3aXRoIGNhY2hlIHZhbHVlXG4gICAgICAgICAgLy8gYW5kIG1vcnBoIGl0IHRvIHRoZSBjaGlsZCBub2RlLlxuICAgICAgICAgIGlmICh1bm1hdGNoZWRGcm9tRWwgJiYgY29tcGFyZU5vZGVOYW1lcyhjdXJDaGlsZCwgdW5tYXRjaGVkRnJvbUVsKSkge1xuICAgICAgICAgICAgY3VyQ2hpbGQucGFyZW50Tm9kZS5yZXBsYWNlQ2hpbGQodW5tYXRjaGVkRnJvbUVsLCBjdXJDaGlsZCk7XG4gICAgICAgICAgICBtb3JwaEVsKHVubWF0Y2hlZEZyb21FbCwgY3VyQ2hpbGQpO1xuICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBoYW5kbGVOb2RlQWRkZWQoY3VyQ2hpbGQpO1xuICAgICAgICAgIH1cbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAvLyByZWN1cnNpdmVseSBjYWxsIGZvciBjdXJDaGlsZCBhbmQgaXQncyBjaGlsZHJlbiB0byBzZWUgaWYgd2UgZmluZCBzb21ldGhpbmcgaW5cbiAgICAgICAgICAvLyBmcm9tTm9kZXNMb29rdXBcbiAgICAgICAgICBoYW5kbGVOb2RlQWRkZWQoY3VyQ2hpbGQpO1xuICAgICAgICB9XG5cbiAgICAgICAgY3VyQ2hpbGQgPSBuZXh0U2libGluZztcbiAgICAgIH1cbiAgICB9XG5cbiAgICBmdW5jdGlvbiBjbGVhbnVwRnJvbUVsKGZyb21FbCwgY3VyRnJvbU5vZGVDaGlsZCwgY3VyRnJvbU5vZGVLZXkpIHtcbiAgICAgIC8vIFdlIGhhdmUgcHJvY2Vzc2VkIGFsbCBvZiB0aGUgXCJ0byBub2Rlc1wiLiBJZiBjdXJGcm9tTm9kZUNoaWxkIGlzXG4gICAgICAvLyBub24tbnVsbCB0aGVuIHdlIHN0aWxsIGhhdmUgc29tZSBmcm9tIG5vZGVzIGxlZnQgb3ZlciB0aGF0IG5lZWRcbiAgICAgIC8vIHRvIGJlIHJlbW92ZWRcbiAgICAgIHdoaWxlIChjdXJGcm9tTm9kZUNoaWxkKSB7XG4gICAgICAgIHZhciBmcm9tTmV4dFNpYmxpbmcgPSBjdXJGcm9tTm9kZUNoaWxkLm5leHRTaWJsaW5nO1xuICAgICAgICBpZiAoKGN1ckZyb21Ob2RlS2V5ID0gZ2V0Tm9kZUtleShjdXJGcm9tTm9kZUNoaWxkKSkpIHtcbiAgICAgICAgICAvLyBTaW5jZSB0aGUgbm9kZSBpcyBrZXllZCBpdCBtaWdodCBiZSBtYXRjaGVkIHVwIGxhdGVyIHNvIHdlIGRlZmVyXG4gICAgICAgICAgLy8gdGhlIGFjdHVhbCByZW1vdmFsIHRvIGxhdGVyXG4gICAgICAgICAgYWRkS2V5ZWRSZW1vdmFsKGN1ckZyb21Ob2RlS2V5KTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAvLyBOT1RFOiB3ZSBza2lwIG5lc3RlZCBrZXllZCBub2RlcyBmcm9tIGJlaW5nIHJlbW92ZWQgc2luY2UgdGhlcmUgaXNcbiAgICAgICAgICAvLyAgICAgICBzdGlsbCBhIGNoYW5jZSB0aGV5IHdpbGwgYmUgbWF0Y2hlZCB1cCBsYXRlclxuICAgICAgICAgIHJlbW92ZU5vZGUoY3VyRnJvbU5vZGVDaGlsZCwgZnJvbUVsLCB0cnVlIC8qIHNraXAga2V5ZWQgbm9kZXMgKi8pO1xuICAgICAgICB9XG4gICAgICAgIGN1ckZyb21Ob2RlQ2hpbGQgPSBmcm9tTmV4dFNpYmxpbmc7XG4gICAgICB9XG4gICAgfVxuXG4gICAgZnVuY3Rpb24gbW9ycGhFbChmcm9tRWwsIHRvRWwsIGNoaWxkcmVuT25seSkge1xuICAgICAgdmFyIHRvRWxLZXkgPSBnZXROb2RlS2V5KHRvRWwpO1xuXG4gICAgICBpZiAodG9FbEtleSkge1xuICAgICAgICAvLyBJZiBhbiBlbGVtZW50IHdpdGggYW4gSUQgaXMgYmVpbmcgbW9ycGhlZCB0aGVuIGl0IHdpbGwgYmUgaW4gdGhlIGZpbmFsXG4gICAgICAgIC8vIERPTSBzbyBjbGVhciBpdCBvdXQgb2YgdGhlIHNhdmVkIGVsZW1lbnRzIGNvbGxlY3Rpb25cbiAgICAgICAgZGVsZXRlIGZyb21Ob2Rlc0xvb2t1cFt0b0VsS2V5XTtcbiAgICAgIH1cblxuICAgICAgaWYgKCFjaGlsZHJlbk9ubHkpIHtcbiAgICAgICAgLy8gb3B0aW9uYWxcbiAgICAgICAgaWYgKG9uQmVmb3JlRWxVcGRhdGVkKGZyb21FbCwgdG9FbCkgPT09IGZhbHNlKSB7XG4gICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgLy8gdXBkYXRlIGF0dHJpYnV0ZXMgb24gb3JpZ2luYWwgRE9NIGVsZW1lbnQgZmlyc3RcbiAgICAgICAgbW9ycGhBdHRycyhmcm9tRWwsIHRvRWwpO1xuICAgICAgICAvLyBvcHRpb25hbFxuICAgICAgICBvbkVsVXBkYXRlZChmcm9tRWwpO1xuXG4gICAgICAgIGlmIChvbkJlZm9yZUVsQ2hpbGRyZW5VcGRhdGVkKGZyb21FbCwgdG9FbCkgPT09IGZhbHNlKSB7XG4gICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG4gICAgICB9XG5cbiAgICAgIGlmIChmcm9tRWwubm9kZU5hbWUgIT09ICdURVhUQVJFQScpIHtcbiAgICAgICAgbW9ycGhDaGlsZHJlbihmcm9tRWwsIHRvRWwpO1xuICAgICAgfSBlbHNlIHtcbiAgICAgICAgc3BlY2lhbEVsSGFuZGxlcnMuVEVYVEFSRUEoZnJvbUVsLCB0b0VsKTtcbiAgICAgIH1cbiAgICB9XG5cbiAgICBmdW5jdGlvbiBtb3JwaENoaWxkcmVuKGZyb21FbCwgdG9FbCkge1xuICAgICAgdmFyIHNraXBGcm9tID0gc2tpcEZyb21DaGlsZHJlbihmcm9tRWwsIHRvRWwpO1xuICAgICAgdmFyIGN1clRvTm9kZUNoaWxkID0gdG9FbC5maXJzdENoaWxkO1xuICAgICAgdmFyIGN1ckZyb21Ob2RlQ2hpbGQgPSBmcm9tRWwuZmlyc3RDaGlsZDtcbiAgICAgIHZhciBjdXJUb05vZGVLZXk7XG4gICAgICB2YXIgY3VyRnJvbU5vZGVLZXk7XG5cbiAgICAgIHZhciBmcm9tTmV4dFNpYmxpbmc7XG4gICAgICB2YXIgdG9OZXh0U2libGluZztcbiAgICAgIHZhciBtYXRjaGluZ0Zyb21FbDtcblxuICAgICAgLy8gd2FsayB0aGUgY2hpbGRyZW5cbiAgICAgIG91dGVyOiB3aGlsZSAoY3VyVG9Ob2RlQ2hpbGQpIHtcbiAgICAgICAgdG9OZXh0U2libGluZyA9IGN1clRvTm9kZUNoaWxkLm5leHRTaWJsaW5nO1xuICAgICAgICBjdXJUb05vZGVLZXkgPSBnZXROb2RlS2V5KGN1clRvTm9kZUNoaWxkKTtcblxuICAgICAgICAvLyB3YWxrIHRoZSBmcm9tTm9kZSBjaGlsZHJlbiBhbGwgdGhlIHdheSB0aHJvdWdoXG4gICAgICAgIHdoaWxlICghc2tpcEZyb20gJiYgY3VyRnJvbU5vZGVDaGlsZCkge1xuICAgICAgICAgIGZyb21OZXh0U2libGluZyA9IGN1ckZyb21Ob2RlQ2hpbGQubmV4dFNpYmxpbmc7XG5cbiAgICAgICAgICBpZiAoY3VyVG9Ob2RlQ2hpbGQuaXNTYW1lTm9kZSAmJiBjdXJUb05vZGVDaGlsZC5pc1NhbWVOb2RlKGN1ckZyb21Ob2RlQ2hpbGQpKSB7XG4gICAgICAgICAgICBjdXJUb05vZGVDaGlsZCA9IHRvTmV4dFNpYmxpbmc7XG4gICAgICAgICAgICBjdXJGcm9tTm9kZUNoaWxkID0gZnJvbU5leHRTaWJsaW5nO1xuICAgICAgICAgICAgY29udGludWUgb3V0ZXI7XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgY3VyRnJvbU5vZGVLZXkgPSBnZXROb2RlS2V5KGN1ckZyb21Ob2RlQ2hpbGQpO1xuXG4gICAgICAgICAgdmFyIGN1ckZyb21Ob2RlVHlwZSA9IGN1ckZyb21Ob2RlQ2hpbGQubm9kZVR5cGU7XG5cbiAgICAgICAgICAvLyB0aGlzIG1lYW5zIGlmIHRoZSBjdXJGcm9tTm9kZUNoaWxkIGRvZXNudCBoYXZlIGEgbWF0Y2ggd2l0aCB0aGUgY3VyVG9Ob2RlQ2hpbGRcbiAgICAgICAgICB2YXIgaXNDb21wYXRpYmxlID0gdW5kZWZpbmVkO1xuXG4gICAgICAgICAgaWYgKGN1ckZyb21Ob2RlVHlwZSA9PT0gY3VyVG9Ob2RlQ2hpbGQubm9kZVR5cGUpIHtcbiAgICAgICAgICAgIGlmIChjdXJGcm9tTm9kZVR5cGUgPT09IEVMRU1FTlRfTk9ERSkge1xuICAgICAgICAgICAgICAvLyBCb3RoIG5vZGVzIGJlaW5nIGNvbXBhcmVkIGFyZSBFbGVtZW50IG5vZGVzXG5cbiAgICAgICAgICAgICAgaWYgKGN1clRvTm9kZUtleSkge1xuICAgICAgICAgICAgICAgIC8vIFRoZSB0YXJnZXQgbm9kZSBoYXMgYSBrZXkgc28gd2Ugd2FudCB0byBtYXRjaCBpdCB1cCB3aXRoIHRoZSBjb3JyZWN0IGVsZW1lbnRcbiAgICAgICAgICAgICAgICAvLyBpbiB0aGUgb3JpZ2luYWwgRE9NIHRyZWVcbiAgICAgICAgICAgICAgICBpZiAoY3VyVG9Ob2RlS2V5ICE9PSBjdXJGcm9tTm9kZUtleSkge1xuICAgICAgICAgICAgICAgICAgLy8gVGhlIGN1cnJlbnQgZWxlbWVudCBpbiB0aGUgb3JpZ2luYWwgRE9NIHRyZWUgZG9lcyBub3QgaGF2ZSBhIG1hdGNoaW5nIGtleSBzb1xuICAgICAgICAgICAgICAgICAgLy8gbGV0J3MgY2hlY2sgb3VyIGxvb2t1cCB0byBzZWUgaWYgdGhlcmUgaXMgYSBtYXRjaGluZyBlbGVtZW50IGluIHRoZSBvcmlnaW5hbFxuICAgICAgICAgICAgICAgICAgLy8gRE9NIHRyZWVcbiAgICAgICAgICAgICAgICAgIGlmICgobWF0Y2hpbmdGcm9tRWwgPSBmcm9tTm9kZXNMb29rdXBbY3VyVG9Ob2RlS2V5XSkpIHtcbiAgICAgICAgICAgICAgICAgICAgaWYgKGZyb21OZXh0U2libGluZyA9PT0gbWF0Y2hpbmdGcm9tRWwpIHtcbiAgICAgICAgICAgICAgICAgICAgICAvLyBTcGVjaWFsIGNhc2UgZm9yIHNpbmdsZSBlbGVtZW50IHJlbW92YWxzLiBUbyBhdm9pZCByZW1vdmluZyB0aGUgb3JpZ2luYWxcbiAgICAgICAgICAgICAgICAgICAgICAvLyBET00gbm9kZSBvdXQgb2YgdGhlIHRyZWUgKHNpbmNlIHRoYXQgY2FuIGJyZWFrIENTUyB0cmFuc2l0aW9ucywgZXRjLiksXG4gICAgICAgICAgICAgICAgICAgICAgLy8gd2Ugd2lsbCBpbnN0ZWFkIGRpc2NhcmQgdGhlIGN1cnJlbnQgbm9kZSBhbmQgd2FpdCB1bnRpbCB0aGUgbmV4dFxuICAgICAgICAgICAgICAgICAgICAgIC8vIGl0ZXJhdGlvbiB0byBwcm9wZXJseSBtYXRjaCB1cCB0aGUga2V5ZWQgdGFyZ2V0IGVsZW1lbnQgd2l0aCBpdHMgbWF0Y2hpbmdcbiAgICAgICAgICAgICAgICAgICAgICAvLyBlbGVtZW50IGluIHRoZSBvcmlnaW5hbCB0cmVlXG4gICAgICAgICAgICAgICAgICAgICAgaXNDb21wYXRpYmxlID0gZmFsc2U7XG4gICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgICAgLy8gV2UgZm91bmQgYSBtYXRjaGluZyBrZXllZCBlbGVtZW50IHNvbWV3aGVyZSBpbiB0aGUgb3JpZ2luYWwgRE9NIHRyZWUuXG4gICAgICAgICAgICAgICAgICAgICAgLy8gTGV0J3MgbW92ZSB0aGUgb3JpZ2luYWwgRE9NIG5vZGUgaW50byB0aGUgY3VycmVudCBwb3NpdGlvbiBhbmQgbW9ycGhcbiAgICAgICAgICAgICAgICAgICAgICAvLyBpdC5cblxuICAgICAgICAgICAgICAgICAgICAgIC8vIE5PVEU6IFdlIHVzZSBpbnNlcnRCZWZvcmUgaW5zdGVhZCBvZiByZXBsYWNlQ2hpbGQgYmVjYXVzZSB3ZSB3YW50IHRvIGdvIHRocm91Z2hcbiAgICAgICAgICAgICAgICAgICAgICAvLyB0aGUgYHJlbW92ZU5vZGUoKWAgZnVuY3Rpb24gZm9yIHRoZSBub2RlIHRoYXQgaXMgYmVpbmcgZGlzY2FyZGVkIHNvIHRoYXRcbiAgICAgICAgICAgICAgICAgICAgICAvLyBhbGwgbGlmZWN5Y2xlIGhvb2tzIGFyZSBjb3JyZWN0bHkgaW52b2tlZFxuICAgICAgICAgICAgICAgICAgICAgIGZyb21FbC5pbnNlcnRCZWZvcmUobWF0Y2hpbmdGcm9tRWwsIGN1ckZyb21Ob2RlQ2hpbGQpO1xuXG4gICAgICAgICAgICAgICAgICAgICAgLy8gZnJvbU5leHRTaWJsaW5nID0gY3VyRnJvbU5vZGVDaGlsZC5uZXh0U2libGluZztcblxuICAgICAgICAgICAgICAgICAgICAgIGlmIChjdXJGcm9tTm9kZUtleSkge1xuICAgICAgICAgICAgICAgICAgICAgICAgLy8gU2luY2UgdGhlIG5vZGUgaXMga2V5ZWQgaXQgbWlnaHQgYmUgbWF0Y2hlZCB1cCBsYXRlciBzbyB3ZSBkZWZlclxuICAgICAgICAgICAgICAgICAgICAgICAgLy8gdGhlIGFjdHVhbCByZW1vdmFsIHRvIGxhdGVyXG4gICAgICAgICAgICAgICAgICAgICAgICBhZGRLZXllZFJlbW92YWwoY3VyRnJvbU5vZGVLZXkpO1xuICAgICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgICAgICAvLyBOT1RFOiB3ZSBza2lwIG5lc3RlZCBrZXllZCBub2RlcyBmcm9tIGJlaW5nIHJlbW92ZWQgc2luY2UgdGhlcmUgaXNcbiAgICAgICAgICAgICAgICAgICAgICAgIC8vICAgICAgIHN0aWxsIGEgY2hhbmNlIHRoZXkgd2lsbCBiZSBtYXRjaGVkIHVwIGxhdGVyXG4gICAgICAgICAgICAgICAgICAgICAgICByZW1vdmVOb2RlKGN1ckZyb21Ob2RlQ2hpbGQsIGZyb21FbCwgdHJ1ZSAvKiBza2lwIGtleWVkIG5vZGVzICovKTtcbiAgICAgICAgICAgICAgICAgICAgICB9XG5cbiAgICAgICAgICAgICAgICAgICAgICBjdXJGcm9tTm9kZUNoaWxkID0gbWF0Y2hpbmdGcm9tRWw7XG4gICAgICAgICAgICAgICAgICAgICAgY3VyRnJvbU5vZGVLZXkgPSBnZXROb2RlS2V5KGN1ckZyb21Ob2RlQ2hpbGQpO1xuICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgICAgICAvLyBUaGUgbm9kZXMgYXJlIG5vdCBjb21wYXRpYmxlIHNpbmNlIHRoZSBcInRvXCIgbm9kZSBoYXMgYSBrZXkgYW5kIHRoZXJlXG4gICAgICAgICAgICAgICAgICAgIC8vIGlzIG5vIG1hdGNoaW5nIGtleWVkIG5vZGUgaW4gdGhlIHNvdXJjZSB0cmVlXG4gICAgICAgICAgICAgICAgICAgIGlzQ29tcGF0aWJsZSA9IGZhbHNlO1xuICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgfSBlbHNlIGlmIChjdXJGcm9tTm9kZUtleSkge1xuICAgICAgICAgICAgICAgIC8vIFRoZSBvcmlnaW5hbCBoYXMgYSBrZXlcbiAgICAgICAgICAgICAgICBpc0NvbXBhdGlibGUgPSBmYWxzZTtcbiAgICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICAgIGlzQ29tcGF0aWJsZSA9IGlzQ29tcGF0aWJsZSAhPT0gZmFsc2UgJiYgY29tcGFyZU5vZGVOYW1lcyhjdXJGcm9tTm9kZUNoaWxkLCBjdXJUb05vZGVDaGlsZCk7XG4gICAgICAgICAgICAgIGlmIChpc0NvbXBhdGlibGUpIHtcbiAgICAgICAgICAgICAgICAvLyBXZSBmb3VuZCBjb21wYXRpYmxlIERPTSBlbGVtZW50cyBzbyB0cmFuc2Zvcm1cbiAgICAgICAgICAgICAgICAvLyB0aGUgY3VycmVudCBcImZyb21cIiBub2RlIHRvIG1hdGNoIHRoZSBjdXJyZW50XG4gICAgICAgICAgICAgICAgLy8gdGFyZ2V0IERPTSBub2RlLlxuICAgICAgICAgICAgICAgIC8vIE1PUlBIXG4gICAgICAgICAgICAgICAgbW9ycGhFbChjdXJGcm9tTm9kZUNoaWxkLCBjdXJUb05vZGVDaGlsZCk7XG4gICAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgfSBlbHNlIGlmIChjdXJGcm9tTm9kZVR5cGUgPT09IFRFWFRfTk9ERSB8fCBjdXJGcm9tTm9kZVR5cGUgPT0gQ09NTUVOVF9OT0RFKSB7XG4gICAgICAgICAgICAgIC8vIEJvdGggbm9kZXMgYmVpbmcgY29tcGFyZWQgYXJlIFRleHQgb3IgQ29tbWVudCBub2Rlc1xuICAgICAgICAgICAgICBpc0NvbXBhdGlibGUgPSB0cnVlO1xuICAgICAgICAgICAgICAvLyBTaW1wbHkgdXBkYXRlIG5vZGVWYWx1ZSBvbiB0aGUgb3JpZ2luYWwgbm9kZSB0b1xuICAgICAgICAgICAgICAvLyBjaGFuZ2UgdGhlIHRleHQgdmFsdWVcbiAgICAgICAgICAgICAgaWYgKGN1ckZyb21Ob2RlQ2hpbGQubm9kZVZhbHVlICE9PSBjdXJUb05vZGVDaGlsZC5ub2RlVmFsdWUpIHtcbiAgICAgICAgICAgICAgICBjdXJGcm9tTm9kZUNoaWxkLm5vZGVWYWx1ZSA9IGN1clRvTm9kZUNoaWxkLm5vZGVWYWx1ZTtcbiAgICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICB9XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgaWYgKGlzQ29tcGF0aWJsZSkge1xuICAgICAgICAgICAgLy8gQWR2YW5jZSBib3RoIHRoZSBcInRvXCIgY2hpbGQgYW5kIHRoZSBcImZyb21cIiBjaGlsZCBzaW5jZSB3ZSBmb3VuZCBhIG1hdGNoXG4gICAgICAgICAgICAvLyBOb3RoaW5nIGVsc2UgdG8gZG8gYXMgd2UgYWxyZWFkeSByZWN1cnNpdmVseSBjYWxsZWQgbW9ycGhDaGlsZHJlbiBhYm92ZVxuICAgICAgICAgICAgY3VyVG9Ob2RlQ2hpbGQgPSB0b05leHRTaWJsaW5nO1xuICAgICAgICAgICAgY3VyRnJvbU5vZGVDaGlsZCA9IGZyb21OZXh0U2libGluZztcbiAgICAgICAgICAgIGNvbnRpbnVlIG91dGVyO1xuICAgICAgICAgIH1cblxuICAgICAgICAgIC8vIE5vIGNvbXBhdGlibGUgbWF0Y2ggc28gcmVtb3ZlIHRoZSBvbGQgbm9kZSBmcm9tIHRoZSBET00gYW5kIGNvbnRpbnVlIHRyeWluZyB0byBmaW5kIGFcbiAgICAgICAgICAvLyBtYXRjaCBpbiB0aGUgb3JpZ2luYWwgRE9NLiBIb3dldmVyLCB3ZSBvbmx5IGRvIHRoaXMgaWYgdGhlIGZyb20gbm9kZSBpcyBub3Qga2V5ZWRcbiAgICAgICAgICAvLyBzaW5jZSBpdCBpcyBwb3NzaWJsZSB0aGF0IGEga2V5ZWQgbm9kZSBtaWdodCBtYXRjaCB1cCB3aXRoIGEgbm9kZSBzb21ld2hlcmUgZWxzZSBpbiB0aGVcbiAgICAgICAgICAvLyB0YXJnZXQgdHJlZSBhbmQgd2UgZG9uJ3Qgd2FudCB0byBkaXNjYXJkIGl0IGp1c3QgeWV0IHNpbmNlIGl0IHN0aWxsIG1pZ2h0IGZpbmQgYVxuICAgICAgICAgIC8vIGhvbWUgaW4gdGhlIGZpbmFsIERPTSB0cmVlLiBBZnRlciBldmVyeXRoaW5nIGlzIGRvbmUgd2Ugd2lsbCByZW1vdmUgYW55IGtleWVkIG5vZGVzXG4gICAgICAgICAgLy8gdGhhdCBkaWRuJ3QgZmluZCBhIGhvbWVcbiAgICAgICAgICBpZiAoY3VyRnJvbU5vZGVLZXkpIHtcbiAgICAgICAgICAgIC8vIFNpbmNlIHRoZSBub2RlIGlzIGtleWVkIGl0IG1pZ2h0IGJlIG1hdGNoZWQgdXAgbGF0ZXIgc28gd2UgZGVmZXJcbiAgICAgICAgICAgIC8vIHRoZSBhY3R1YWwgcmVtb3ZhbCB0byBsYXRlclxuICAgICAgICAgICAgYWRkS2V5ZWRSZW1vdmFsKGN1ckZyb21Ob2RlS2V5KTtcbiAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgLy8gTk9URTogd2Ugc2tpcCBuZXN0ZWQga2V5ZWQgbm9kZXMgZnJvbSBiZWluZyByZW1vdmVkIHNpbmNlIHRoZXJlIGlzXG4gICAgICAgICAgICAvLyAgICAgICBzdGlsbCBhIGNoYW5jZSB0aGV5IHdpbGwgYmUgbWF0Y2hlZCB1cCBsYXRlclxuICAgICAgICAgICAgcmVtb3ZlTm9kZShjdXJGcm9tTm9kZUNoaWxkLCBmcm9tRWwsIHRydWUgLyogc2tpcCBrZXllZCBub2RlcyAqLyk7XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgY3VyRnJvbU5vZGVDaGlsZCA9IGZyb21OZXh0U2libGluZztcbiAgICAgICAgfSAvLyBFTkQ6IHdoaWxlKGN1ckZyb21Ob2RlQ2hpbGQpIHt9XG5cbiAgICAgICAgLy8gSWYgd2UgZ290IHRoaXMgZmFyIHRoZW4gd2UgZGlkIG5vdCBmaW5kIGEgY2FuZGlkYXRlIG1hdGNoIGZvclxuICAgICAgICAvLyBvdXIgXCJ0byBub2RlXCIgYW5kIHdlIGV4aGF1c3RlZCBhbGwgb2YgdGhlIGNoaWxkcmVuIFwiZnJvbVwiXG4gICAgICAgIC8vIG5vZGVzLiBUaGVyZWZvcmUsIHdlIHdpbGwganVzdCBhcHBlbmQgdGhlIGN1cnJlbnQgXCJ0b1wiIG5vZGVcbiAgICAgICAgLy8gdG8gdGhlIGVuZFxuICAgICAgICBpZiAoY3VyVG9Ob2RlS2V5ICYmIChtYXRjaGluZ0Zyb21FbCA9IGZyb21Ob2Rlc0xvb2t1cFtjdXJUb05vZGVLZXldKSAmJiBjb21wYXJlTm9kZU5hbWVzKG1hdGNoaW5nRnJvbUVsLCBjdXJUb05vZGVDaGlsZCkpIHtcbiAgICAgICAgICAvLyBNT1JQSFxuICAgICAgICAgIGlmKCFza2lwRnJvbSl7IGFkZENoaWxkKGZyb21FbCwgbWF0Y2hpbmdGcm9tRWwpOyB9XG4gICAgICAgICAgbW9ycGhFbChtYXRjaGluZ0Zyb21FbCwgY3VyVG9Ob2RlQ2hpbGQpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIHZhciBvbkJlZm9yZU5vZGVBZGRlZFJlc3VsdCA9IG9uQmVmb3JlTm9kZUFkZGVkKGN1clRvTm9kZUNoaWxkKTtcbiAgICAgICAgICBpZiAob25CZWZvcmVOb2RlQWRkZWRSZXN1bHQgIT09IGZhbHNlKSB7XG4gICAgICAgICAgICBpZiAob25CZWZvcmVOb2RlQWRkZWRSZXN1bHQpIHtcbiAgICAgICAgICAgICAgY3VyVG9Ob2RlQ2hpbGQgPSBvbkJlZm9yZU5vZGVBZGRlZFJlc3VsdDtcbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgaWYgKGN1clRvTm9kZUNoaWxkLmFjdHVhbGl6ZSkge1xuICAgICAgICAgICAgICBjdXJUb05vZGVDaGlsZCA9IGN1clRvTm9kZUNoaWxkLmFjdHVhbGl6ZShmcm9tRWwub3duZXJEb2N1bWVudCB8fCBkb2MpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgYWRkQ2hpbGQoZnJvbUVsLCBjdXJUb05vZGVDaGlsZCk7XG4gICAgICAgICAgICBoYW5kbGVOb2RlQWRkZWQoY3VyVG9Ob2RlQ2hpbGQpO1xuICAgICAgICAgIH1cbiAgICAgICAgfVxuXG4gICAgICAgIGN1clRvTm9kZUNoaWxkID0gdG9OZXh0U2libGluZztcbiAgICAgICAgY3VyRnJvbU5vZGVDaGlsZCA9IGZyb21OZXh0U2libGluZztcbiAgICAgIH1cblxuICAgICAgY2xlYW51cEZyb21FbChmcm9tRWwsIGN1ckZyb21Ob2RlQ2hpbGQsIGN1ckZyb21Ob2RlS2V5KTtcblxuICAgICAgdmFyIHNwZWNpYWxFbEhhbmRsZXIgPSBzcGVjaWFsRWxIYW5kbGVyc1tmcm9tRWwubm9kZU5hbWVdO1xuICAgICAgaWYgKHNwZWNpYWxFbEhhbmRsZXIpIHtcbiAgICAgICAgc3BlY2lhbEVsSGFuZGxlcihmcm9tRWwsIHRvRWwpO1xuICAgICAgfVxuICAgIH0gLy8gRU5EOiBtb3JwaENoaWxkcmVuKC4uLilcblxuICAgIHZhciBtb3JwaGVkTm9kZSA9IGZyb21Ob2RlO1xuICAgIHZhciBtb3JwaGVkTm9kZVR5cGUgPSBtb3JwaGVkTm9kZS5ub2RlVHlwZTtcbiAgICB2YXIgdG9Ob2RlVHlwZSA9IHRvTm9kZS5ub2RlVHlwZTtcblxuICAgIGlmICghY2hpbGRyZW5Pbmx5KSB7XG4gICAgICAvLyBIYW5kbGUgdGhlIGNhc2Ugd2hlcmUgd2UgYXJlIGdpdmVuIHR3byBET00gbm9kZXMgdGhhdCBhcmUgbm90XG4gICAgICAvLyBjb21wYXRpYmxlIChlLmcuIDxkaXY+IC0tPiA8c3Bhbj4gb3IgPGRpdj4gLS0+IFRFWFQpXG4gICAgICBpZiAobW9ycGhlZE5vZGVUeXBlID09PSBFTEVNRU5UX05PREUpIHtcbiAgICAgICAgaWYgKHRvTm9kZVR5cGUgPT09IEVMRU1FTlRfTk9ERSkge1xuICAgICAgICAgIGlmICghY29tcGFyZU5vZGVOYW1lcyhmcm9tTm9kZSwgdG9Ob2RlKSkge1xuICAgICAgICAgICAgb25Ob2RlRGlzY2FyZGVkKGZyb21Ob2RlKTtcbiAgICAgICAgICAgIG1vcnBoZWROb2RlID0gbW92ZUNoaWxkcmVuKGZyb21Ob2RlLCBjcmVhdGVFbGVtZW50TlModG9Ob2RlLm5vZGVOYW1lLCB0b05vZGUubmFtZXNwYWNlVVJJKSk7XG4gICAgICAgICAgfVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIC8vIEdvaW5nIGZyb20gYW4gZWxlbWVudCBub2RlIHRvIGEgdGV4dCBub2RlXG4gICAgICAgICAgbW9ycGhlZE5vZGUgPSB0b05vZGU7XG4gICAgICAgIH1cbiAgICAgIH0gZWxzZSBpZiAobW9ycGhlZE5vZGVUeXBlID09PSBURVhUX05PREUgfHwgbW9ycGhlZE5vZGVUeXBlID09PSBDT01NRU5UX05PREUpIHsgLy8gVGV4dCBvciBjb21tZW50IG5vZGVcbiAgICAgICAgaWYgKHRvTm9kZVR5cGUgPT09IG1vcnBoZWROb2RlVHlwZSkge1xuICAgICAgICAgIGlmIChtb3JwaGVkTm9kZS5ub2RlVmFsdWUgIT09IHRvTm9kZS5ub2RlVmFsdWUpIHtcbiAgICAgICAgICAgIG1vcnBoZWROb2RlLm5vZGVWYWx1ZSA9IHRvTm9kZS5ub2RlVmFsdWU7XG4gICAgICAgICAgfVxuXG4gICAgICAgICAgcmV0dXJuIG1vcnBoZWROb2RlO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIC8vIFRleHQgbm9kZSB0byBzb21ldGhpbmcgZWxzZVxuICAgICAgICAgIG1vcnBoZWROb2RlID0gdG9Ob2RlO1xuICAgICAgICB9XG4gICAgICB9XG4gICAgfVxuXG4gICAgaWYgKG1vcnBoZWROb2RlID09PSB0b05vZGUpIHtcbiAgICAgIC8vIFRoZSBcInRvIG5vZGVcIiB3YXMgbm90IGNvbXBhdGlibGUgd2l0aCB0aGUgXCJmcm9tIG5vZGVcIiBzbyB3ZSBoYWQgdG9cbiAgICAgIC8vIHRvc3Mgb3V0IHRoZSBcImZyb20gbm9kZVwiIGFuZCB1c2UgdGhlIFwidG8gbm9kZVwiXG4gICAgICBvbk5vZGVEaXNjYXJkZWQoZnJvbU5vZGUpO1xuICAgIH0gZWxzZSB7XG4gICAgICBpZiAodG9Ob2RlLmlzU2FtZU5vZGUgJiYgdG9Ob2RlLmlzU2FtZU5vZGUobW9ycGhlZE5vZGUpKSB7XG4gICAgICAgIHJldHVybjtcbiAgICAgIH1cblxuICAgICAgbW9ycGhFbChtb3JwaGVkTm9kZSwgdG9Ob2RlLCBjaGlsZHJlbk9ubHkpO1xuXG4gICAgICAvLyBXZSBub3cgbmVlZCB0byBsb29wIG92ZXIgYW55IGtleWVkIG5vZGVzIHRoYXQgbWlnaHQgbmVlZCB0byBiZVxuICAgICAgLy8gcmVtb3ZlZC4gV2Ugb25seSBkbyB0aGUgcmVtb3ZhbCBpZiB3ZSBrbm93IHRoYXQgdGhlIGtleWVkIG5vZGVcbiAgICAgIC8vIG5ldmVyIGZvdW5kIGEgbWF0Y2guIFdoZW4gYSBrZXllZCBub2RlIGlzIG1hdGNoZWQgdXAgd2UgcmVtb3ZlXG4gICAgICAvLyBpdCBvdXQgb2YgZnJvbU5vZGVzTG9va3VwIGFuZCB3ZSB1c2UgZnJvbU5vZGVzTG9va3VwIHRvIGRldGVybWluZVxuICAgICAgLy8gaWYgYSBrZXllZCBub2RlIGhhcyBiZWVuIG1hdGNoZWQgdXAgb3Igbm90XG4gICAgICBpZiAoa2V5ZWRSZW1vdmFsTGlzdCkge1xuICAgICAgICBmb3IgKHZhciBpPTAsIGxlbj1rZXllZFJlbW92YWxMaXN0Lmxlbmd0aDsgaTxsZW47IGkrKykge1xuICAgICAgICAgIHZhciBlbFRvUmVtb3ZlID0gZnJvbU5vZGVzTG9va3VwW2tleWVkUmVtb3ZhbExpc3RbaV1dO1xuICAgICAgICAgIGlmIChlbFRvUmVtb3ZlKSB7XG4gICAgICAgICAgICByZW1vdmVOb2RlKGVsVG9SZW1vdmUsIGVsVG9SZW1vdmUucGFyZW50Tm9kZSwgZmFsc2UpO1xuICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgICAgfVxuICAgIH1cblxuICAgIGlmICghY2hpbGRyZW5Pbmx5ICYmIG1vcnBoZWROb2RlICE9PSBmcm9tTm9kZSAmJiBmcm9tTm9kZS5wYXJlbnROb2RlKSB7XG4gICAgICBpZiAobW9ycGhlZE5vZGUuYWN0dWFsaXplKSB7XG4gICAgICAgIG1vcnBoZWROb2RlID0gbW9ycGhlZE5vZGUuYWN0dWFsaXplKGZyb21Ob2RlLm93bmVyRG9jdW1lbnQgfHwgZG9jKTtcbiAgICAgIH1cbiAgICAgIC8vIElmIHdlIGhhZCB0byBzd2FwIG91dCB0aGUgZnJvbSBub2RlIHdpdGggYSBuZXcgbm9kZSBiZWNhdXNlIHRoZSBvbGRcbiAgICAgIC8vIG5vZGUgd2FzIG5vdCBjb21wYXRpYmxlIHdpdGggdGhlIHRhcmdldCBub2RlIHRoZW4gd2UgbmVlZCB0b1xuICAgICAgLy8gcmVwbGFjZSB0aGUgb2xkIERPTSBub2RlIGluIHRoZSBvcmlnaW5hbCBET00gdHJlZS4gVGhpcyBpcyBvbmx5XG4gICAgICAvLyBwb3NzaWJsZSBpZiB0aGUgb3JpZ2luYWwgRE9NIG5vZGUgd2FzIHBhcnQgb2YgYSBET00gdHJlZSB3aGljaFxuICAgICAgLy8gd2Uga25vdyBpcyB0aGUgY2FzZSBpZiBpdCBoYXMgYSBwYXJlbnQgbm9kZS5cbiAgICAgIGZyb21Ob2RlLnBhcmVudE5vZGUucmVwbGFjZUNoaWxkKG1vcnBoZWROb2RlLCBmcm9tTm9kZSk7XG4gICAgfVxuXG4gICAgcmV0dXJuIG1vcnBoZWROb2RlO1xuICB9O1xufVxuXG52YXIgbW9ycGhkb20gPSBtb3JwaGRvbUZhY3RvcnkobW9ycGhBdHRycyk7XG5cbmV4cG9ydCBkZWZhdWx0IG1vcnBoZG9tO1xuIiwgImltcG9ydCB7XG4gIFBIWF9DT01QT05FTlQsXG4gIFBIWF9ESVNBQkxFX1dJVEgsXG4gIFBIWF9GRUVEQkFDS19GT1IsXG4gIFBIWF9GRUVEQkFDS19HUk9VUCxcbiAgUEhYX1BSVU5FLFxuICBQSFhfUk9PVF9JRCxcbiAgUEhYX1NFU1NJT04sXG4gIFBIWF9TS0lQLFxuICBQSFhfTUFHSUNfSUQsXG4gIFBIWF9TVEFUSUMsXG4gIFBIWF9UUklHR0VSX0FDVElPTixcbiAgUEhYX1VQREFURSxcbiAgUEhYX1NUUkVBTSxcbiAgUEhYX1NUUkVBTV9SRUYsXG4gIFBIWF9WSUVXUE9SVF9UT1AsXG4gIFBIWF9WSUVXUE9SVF9CT1RUT00sXG59IGZyb20gXCIuL2NvbnN0YW50c1wiXG5cbmltcG9ydCB7XG4gIGRldGVjdER1cGxpY2F0ZUlkcyxcbiAgaXNDaWRcbn0gZnJvbSBcIi4vdXRpbHNcIlxuXG5pbXBvcnQgRE9NIGZyb20gXCIuL2RvbVwiXG5pbXBvcnQgRE9NUG9zdE1vcnBoUmVzdG9yZXIgZnJvbSBcIi4vZG9tX3Bvc3RfbW9ycGhfcmVzdG9yZXJcIlxuaW1wb3J0IG1vcnBoZG9tIGZyb20gXCJtb3JwaGRvbVwiXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIERPTVBhdGNoIHtcbiAgc3RhdGljIHBhdGNoRWwoZnJvbUVsLCB0b0VsLCBhY3RpdmVFbGVtZW50KXtcbiAgICBtb3JwaGRvbShmcm9tRWwsIHRvRWwsIHtcbiAgICAgIGNoaWxkcmVuT25seTogZmFsc2UsXG4gICAgICBvbkJlZm9yZUVsVXBkYXRlZDogKGZyb21FbCwgdG9FbCkgPT4ge1xuICAgICAgICBpZihhY3RpdmVFbGVtZW50ICYmIGFjdGl2ZUVsZW1lbnQuaXNTYW1lTm9kZShmcm9tRWwpICYmIERPTS5pc0Zvcm1JbnB1dChmcm9tRWwpKXtcbiAgICAgICAgICBET00ubWVyZ2VGb2N1c2VkSW5wdXQoZnJvbUVsLCB0b0VsKVxuICAgICAgICAgIHJldHVybiBmYWxzZVxuICAgICAgICB9XG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIGNvbnN0cnVjdG9yKHZpZXcsIGNvbnRhaW5lciwgaWQsIGh0bWwsIHN0cmVhbXMsIHRhcmdldENJRCl7XG4gICAgdGhpcy52aWV3ID0gdmlld1xuICAgIHRoaXMubGl2ZVNvY2tldCA9IHZpZXcubGl2ZVNvY2tldFxuICAgIHRoaXMuY29udGFpbmVyID0gY29udGFpbmVyXG4gICAgdGhpcy5pZCA9IGlkXG4gICAgdGhpcy5yb290SUQgPSB2aWV3LnJvb3QuaWRcbiAgICB0aGlzLmh0bWwgPSBodG1sXG4gICAgdGhpcy5zdHJlYW1zID0gc3RyZWFtc1xuICAgIHRoaXMuc3RyZWFtSW5zZXJ0cyA9IHt9XG4gICAgdGhpcy5zdHJlYW1Db21wb25lbnRSZXN0b3JlID0ge31cbiAgICB0aGlzLnRhcmdldENJRCA9IHRhcmdldENJRFxuICAgIHRoaXMuY2lkUGF0Y2ggPSBpc0NpZCh0aGlzLnRhcmdldENJRClcbiAgICB0aGlzLnBlbmRpbmdSZW1vdmVzID0gW11cbiAgICB0aGlzLnBoeFJlbW92ZSA9IHRoaXMubGl2ZVNvY2tldC5iaW5kaW5nKFwicmVtb3ZlXCIpXG4gICAgdGhpcy5jYWxsYmFja3MgPSB7XG4gICAgICBiZWZvcmVhZGRlZDogW10sIGJlZm9yZXVwZGF0ZWQ6IFtdLCBiZWZvcmVwaHhDaGlsZEFkZGVkOiBbXSxcbiAgICAgIGFmdGVyYWRkZWQ6IFtdLCBhZnRlcnVwZGF0ZWQ6IFtdLCBhZnRlcmRpc2NhcmRlZDogW10sIGFmdGVycGh4Q2hpbGRBZGRlZDogW10sXG4gICAgICBhZnRlcnRyYW5zaXRpb25zRGlzY2FyZGVkOiBbXVxuICAgIH1cbiAgfVxuXG4gIGJlZm9yZShraW5kLCBjYWxsYmFjayl7IHRoaXMuY2FsbGJhY2tzW2BiZWZvcmUke2tpbmR9YF0ucHVzaChjYWxsYmFjaykgfVxuICBhZnRlcihraW5kLCBjYWxsYmFjayl7IHRoaXMuY2FsbGJhY2tzW2BhZnRlciR7a2luZH1gXS5wdXNoKGNhbGxiYWNrKSB9XG5cbiAgdHJhY2tCZWZvcmUoa2luZCwgLi4uYXJncyl7XG4gICAgdGhpcy5jYWxsYmFja3NbYGJlZm9yZSR7a2luZH1gXS5mb3JFYWNoKGNhbGxiYWNrID0+IGNhbGxiYWNrKC4uLmFyZ3MpKVxuICB9XG5cbiAgdHJhY2tBZnRlcihraW5kLCAuLi5hcmdzKXtcbiAgICB0aGlzLmNhbGxiYWNrc1tgYWZ0ZXIke2tpbmR9YF0uZm9yRWFjaChjYWxsYmFjayA9PiBjYWxsYmFjayguLi5hcmdzKSlcbiAgfVxuXG4gIG1hcmtQcnVuYWJsZUNvbnRlbnRGb3JSZW1vdmFsKCl7XG4gICAgbGV0IHBoeFVwZGF0ZSA9IHRoaXMubGl2ZVNvY2tldC5iaW5kaW5nKFBIWF9VUERBVEUpXG4gICAgRE9NLmFsbCh0aGlzLmNvbnRhaW5lciwgYFske3BoeFVwZGF0ZX09YXBwZW5kXSA+ICosIFske3BoeFVwZGF0ZX09cHJlcGVuZF0gPiAqYCwgZWwgPT4ge1xuICAgICAgZWwuc2V0QXR0cmlidXRlKFBIWF9QUlVORSwgXCJcIilcbiAgICB9KVxuICB9XG5cbiAgcGVyZm9ybShpc0pvaW5QYXRjaCl7XG4gICAgbGV0IHt2aWV3LCBsaXZlU29ja2V0LCBjb250YWluZXIsIGh0bWx9ID0gdGhpc1xuICAgIGxldCB0YXJnZXRDb250YWluZXIgPSB0aGlzLmlzQ0lEUGF0Y2goKSA/IHRoaXMudGFyZ2V0Q0lEQ29udGFpbmVyKGh0bWwpIDogY29udGFpbmVyXG4gICAgaWYodGhpcy5pc0NJRFBhdGNoKCkgJiYgIXRhcmdldENvbnRhaW5lcil7IHJldHVybiB9XG5cbiAgICBsZXQgZm9jdXNlZCA9IGxpdmVTb2NrZXQuZ2V0QWN0aXZlRWxlbWVudCgpXG4gICAgbGV0IHtzZWxlY3Rpb25TdGFydCwgc2VsZWN0aW9uRW5kfSA9IGZvY3VzZWQgJiYgRE9NLmhhc1NlbGVjdGlvblJhbmdlKGZvY3VzZWQpID8gZm9jdXNlZCA6IHt9XG4gICAgbGV0IHBoeFVwZGF0ZSA9IGxpdmVTb2NrZXQuYmluZGluZyhQSFhfVVBEQVRFKVxuICAgIGxldCBwaHhGZWVkYmFja0ZvciA9IGxpdmVTb2NrZXQuYmluZGluZyhQSFhfRkVFREJBQ0tfRk9SKVxuICAgIGxldCBwaHhGZWVkYmFja0dyb3VwID0gbGl2ZVNvY2tldC5iaW5kaW5nKFBIWF9GRUVEQkFDS19HUk9VUClcbiAgICBsZXQgZGlzYWJsZVdpdGggPSBsaXZlU29ja2V0LmJpbmRpbmcoUEhYX0RJU0FCTEVfV0lUSClcbiAgICBsZXQgcGh4Vmlld3BvcnRUb3AgPSBsaXZlU29ja2V0LmJpbmRpbmcoUEhYX1ZJRVdQT1JUX1RPUClcbiAgICBsZXQgcGh4Vmlld3BvcnRCb3R0b20gPSBsaXZlU29ja2V0LmJpbmRpbmcoUEhYX1ZJRVdQT1JUX0JPVFRPTSlcbiAgICBsZXQgcGh4VHJpZ2dlckV4dGVybmFsID0gbGl2ZVNvY2tldC5iaW5kaW5nKFBIWF9UUklHR0VSX0FDVElPTilcbiAgICBsZXQgYWRkZWQgPSBbXVxuICAgIGxldCBmZWVkYmFja0NvbnRhaW5lcnMgPSBbXVxuICAgIGxldCB1cGRhdGVzID0gW11cbiAgICBsZXQgYXBwZW5kUHJlcGVuZFVwZGF0ZXMgPSBbXVxuXG4gICAgbGV0IGV4dGVybmFsRm9ybVRyaWdnZXJlZCA9IG51bGxcblxuICAgIGZ1bmN0aW9uIG1vcnBoKHRhcmdldENvbnRhaW5lciwgc291cmNlLCB3aXRoQ2hpbGRyZW49ZmFsc2Upe1xuICAgICAgbW9ycGhkb20odGFyZ2V0Q29udGFpbmVyLCBzb3VyY2UsIHtcbiAgICAgICAgLy8gbm9ybWFsbHksIHdlIGFyZSBydW5uaW5nIHdpdGggY2hpbGRyZW5Pbmx5LCBhcyB0aGUgcGF0Y2ggSFRNTCBmb3IgYSBMVlxuICAgICAgICAvLyBkb2VzIG5vdCBpbmNsdWRlIHRoZSBMViBhdHRycyAoZGF0YS1waHgtc2Vzc2lvbiwgZXRjLilcbiAgICAgICAgLy8gd2hlbiB3ZSBhcmUgcGF0Y2hpbmcgYSBsaXZlIGNvbXBvbmVudCwgd2UgZG8gd2FudCB0byBwYXRjaCB0aGUgcm9vdCBlbGVtZW50IGFzIHdlbGw7XG4gICAgICAgIC8vIGFub3RoZXIgY2FzZSBpcyB0aGUgcmVjdXJzaXZlIHBhdGNoIG9mIGEgc3RyZWFtIGl0ZW0gdGhhdCB3YXMga2VwdCBvbiByZXNldCAoLT4gb25CZWZvcmVOb2RlQWRkZWQpXG4gICAgICAgIGNoaWxkcmVuT25seTogdGFyZ2V0Q29udGFpbmVyLmdldEF0dHJpYnV0ZShQSFhfQ09NUE9ORU5UKSA9PT0gbnVsbCAmJiAhd2l0aENoaWxkcmVuLFxuICAgICAgICBnZXROb2RlS2V5OiAobm9kZSkgPT4ge1xuICAgICAgICAgIGlmKERPTS5pc1BoeERlc3Ryb3llZChub2RlKSl7IHJldHVybiBudWxsIH1cbiAgICAgICAgICAvLyBJZiB3ZSBoYXZlIGEgam9pbiBwYXRjaCwgdGhlbiBieSBkZWZpbml0aW9uIHRoZXJlIHdhcyBubyBQSFhfTUFHSUNfSUQuXG4gICAgICAgICAgLy8gVGhpcyBpcyBpbXBvcnRhbnQgdG8gcmVkdWNlIHRoZSBhbW91bnQgb2YgZWxlbWVudHMgbW9ycGhkb20gZGlzY2FyZHMuXG4gICAgICAgICAgaWYoaXNKb2luUGF0Y2gpeyByZXR1cm4gbm9kZS5pZCB9XG4gICAgICAgICAgcmV0dXJuIG5vZGUuaWQgfHwgKG5vZGUuZ2V0QXR0cmlidXRlICYmIG5vZGUuZ2V0QXR0cmlidXRlKFBIWF9NQUdJQ19JRCkpXG4gICAgICAgIH0sXG4gICAgICAgIC8vIHNraXAgaW5kZXhpbmcgZnJvbSBjaGlsZHJlbiB3aGVuIGNvbnRhaW5lciBpcyBzdHJlYW1cbiAgICAgICAgc2tpcEZyb21DaGlsZHJlbjogKGZyb20pID0+IHsgcmV0dXJuIGZyb20uZ2V0QXR0cmlidXRlKHBoeFVwZGF0ZSkgPT09IFBIWF9TVFJFQU0gfSxcbiAgICAgICAgLy8gdGVsbCBtb3JwaGRvbSBob3cgdG8gYWRkIGEgY2hpbGRcbiAgICAgICAgYWRkQ2hpbGQ6IChwYXJlbnQsIGNoaWxkKSA9PiB7XG4gICAgICAgICAgbGV0IHtyZWYsIHN0cmVhbUF0fSA9IHRoaXMuZ2V0U3RyZWFtSW5zZXJ0KGNoaWxkKVxuICAgICAgICAgIGlmKHJlZiA9PT0gdW5kZWZpbmVkKXsgcmV0dXJuIHBhcmVudC5hcHBlbmRDaGlsZChjaGlsZCkgfVxuXG4gICAgICAgICAgdGhpcy5zZXRTdHJlYW1SZWYoY2hpbGQsIHJlZilcblxuICAgICAgICAgIC8vIHN0cmVhbWluZ1xuICAgICAgICAgIGlmKHN0cmVhbUF0ID09PSAwKXtcbiAgICAgICAgICAgIHBhcmVudC5pbnNlcnRBZGphY2VudEVsZW1lbnQoXCJhZnRlcmJlZ2luXCIsIGNoaWxkKVxuICAgICAgICAgIH0gZWxzZSBpZihzdHJlYW1BdCA9PT0gLTEpe1xuICAgICAgICAgICAgcGFyZW50LmFwcGVuZENoaWxkKGNoaWxkKVxuICAgICAgICAgIH0gZWxzZSBpZihzdHJlYW1BdCA+IDApe1xuICAgICAgICAgICAgbGV0IHNpYmxpbmcgPSBBcnJheS5mcm9tKHBhcmVudC5jaGlsZHJlbilbc3RyZWFtQXRdXG4gICAgICAgICAgICBwYXJlbnQuaW5zZXJ0QmVmb3JlKGNoaWxkLCBzaWJsaW5nKVxuICAgICAgICAgIH1cbiAgICAgICAgfSxcbiAgICAgICAgb25CZWZvcmVOb2RlQWRkZWQ6IChlbCkgPT4ge1xuICAgICAgICAgIERPTS5tYXliZUFkZFByaXZhdGVIb29rcyhlbCwgcGh4Vmlld3BvcnRUb3AsIHBoeFZpZXdwb3J0Qm90dG9tKVxuICAgICAgICAgIHRoaXMudHJhY2tCZWZvcmUoXCJhZGRlZFwiLCBlbClcblxuICAgICAgICAgIGxldCBtb3JwaGVkRWwgPSBlbFxuICAgICAgICAgIC8vIHRoaXMgaXMgYSBzdHJlYW0gaXRlbSB0aGF0IHdhcyBrZXB0IG9uIHJlc2V0LCByZWN1cnNpdmVseSBtb3JwaCBpdFxuICAgICAgICAgIGlmKCFpc0pvaW5QYXRjaCAmJiB0aGlzLnN0cmVhbUNvbXBvbmVudFJlc3RvcmVbZWwuaWRdKXtcbiAgICAgICAgICAgIG1vcnBoZWRFbCA9IHRoaXMuc3RyZWFtQ29tcG9uZW50UmVzdG9yZVtlbC5pZF1cbiAgICAgICAgICAgIGRlbGV0ZSB0aGlzLnN0cmVhbUNvbXBvbmVudFJlc3RvcmVbZWwuaWRdXG4gICAgICAgICAgICBtb3JwaC5jYWxsKHRoaXMsIG1vcnBoZWRFbCwgZWwsIHRydWUpXG4gICAgICAgICAgfVxuXG4gICAgICAgICAgcmV0dXJuIG1vcnBoZWRFbFxuICAgICAgICB9LFxuICAgICAgICBvbk5vZGVBZGRlZDogKGVsKSA9PiB7XG4gICAgICAgICAgaWYoZWwuZ2V0QXR0cmlidXRlKXsgdGhpcy5tYXliZVJlT3JkZXJTdHJlYW0oZWwsIHRydWUpIH1cbiAgICAgICAgICBpZihET00uaXNGZWVkYmFja0NvbnRhaW5lcihlbCwgcGh4RmVlZGJhY2tGb3IpKSBmZWVkYmFja0NvbnRhaW5lcnMucHVzaChlbClcblxuICAgICAgICAgIC8vIGhhY2sgdG8gZml4IFNhZmFyaSBoYW5kbGluZyBvZiBpbWcgc3Jjc2V0IGFuZCB2aWRlbyB0YWdzXG4gICAgICAgICAgaWYoZWwgaW5zdGFuY2VvZiBIVE1MSW1hZ2VFbGVtZW50ICYmIGVsLnNyY3NldCl7XG4gICAgICAgICAgICBlbC5zcmNzZXQgPSBlbC5zcmNzZXRcbiAgICAgICAgICB9IGVsc2UgaWYoZWwgaW5zdGFuY2VvZiBIVE1MVmlkZW9FbGVtZW50ICYmIGVsLmF1dG9wbGF5KXtcbiAgICAgICAgICAgIGVsLnBsYXkoKVxuICAgICAgICAgIH1cbiAgICAgICAgICBpZihET00uaXNOb3dUcmlnZ2VyRm9ybUV4dGVybmFsKGVsLCBwaHhUcmlnZ2VyRXh0ZXJuYWwpKXtcbiAgICAgICAgICAgIGV4dGVybmFsRm9ybVRyaWdnZXJlZCA9IGVsXG4gICAgICAgICAgfVxuXG4gICAgICAgICAgLy8gbmVzdGVkIHZpZXcgaGFuZGxpbmdcbiAgICAgICAgICBpZigoRE9NLmlzUGh4Q2hpbGQoZWwpICYmIHZpZXcub3duc0VsZW1lbnQoZWwpKSB8fCBET00uaXNQaHhTdGlja3koZWwpICYmIHZpZXcub3duc0VsZW1lbnQoZWwucGFyZW50Tm9kZSkpe1xuICAgICAgICAgICAgdGhpcy50cmFja0FmdGVyKFwicGh4Q2hpbGRBZGRlZFwiLCBlbClcbiAgICAgICAgICB9XG4gICAgICAgICAgYWRkZWQucHVzaChlbClcbiAgICAgICAgfSxcbiAgICAgICAgb25Ob2RlRGlzY2FyZGVkOiAoZWwpID0+IHRoaXMub25Ob2RlRGlzY2FyZGVkKGVsKSxcbiAgICAgICAgb25CZWZvcmVOb2RlRGlzY2FyZGVkOiAoZWwpID0+IHtcbiAgICAgICAgICBpZihlbC5nZXRBdHRyaWJ1dGUgJiYgZWwuZ2V0QXR0cmlidXRlKFBIWF9QUlVORSkgIT09IG51bGwpeyByZXR1cm4gdHJ1ZSB9XG4gICAgICAgICAgaWYoZWwucGFyZW50RWxlbWVudCAhPT0gbnVsbCAmJiBlbC5pZCAmJlxuICAgICAgICAgICAgRE9NLmlzUGh4VXBkYXRlKGVsLnBhcmVudEVsZW1lbnQsIHBoeFVwZGF0ZSwgW1BIWF9TVFJFQU0sIFwiYXBwZW5kXCIsIFwicHJlcGVuZFwiXSkpe1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlXG4gICAgICAgICAgfVxuICAgICAgICAgIGlmKHRoaXMubWF5YmVQZW5kaW5nUmVtb3ZlKGVsKSl7IHJldHVybiBmYWxzZSB9XG4gICAgICAgICAgaWYodGhpcy5za2lwQ0lEU2libGluZyhlbCkpeyByZXR1cm4gZmFsc2UgfVxuXG4gICAgICAgICAgcmV0dXJuIHRydWVcbiAgICAgICAgfSxcbiAgICAgICAgb25FbFVwZGF0ZWQ6IChlbCkgPT4ge1xuICAgICAgICAgIGlmKERPTS5pc05vd1RyaWdnZXJGb3JtRXh0ZXJuYWwoZWwsIHBoeFRyaWdnZXJFeHRlcm5hbCkpe1xuICAgICAgICAgICAgZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkID0gZWxcbiAgICAgICAgICB9XG4gICAgICAgICAgdXBkYXRlcy5wdXNoKGVsKVxuICAgICAgICAgIHRoaXMubWF5YmVSZU9yZGVyU3RyZWFtKGVsLCBmYWxzZSlcbiAgICAgICAgfSxcbiAgICAgICAgb25CZWZvcmVFbFVwZGF0ZWQ6IChmcm9tRWwsIHRvRWwpID0+IHtcbiAgICAgICAgICBET00ubWF5YmVBZGRQcml2YXRlSG9va3ModG9FbCwgcGh4Vmlld3BvcnRUb3AsIHBoeFZpZXdwb3J0Qm90dG9tKVxuICAgICAgICAgIC8vIG1hcmsgYm90aCBmcm9tIGFuZCB0byBlbHMgYXMgZmVlZGJhY2sgY29udGFpbmVycywgYXMgd2UgZG9uJ3Qga25vdyB5ZXQgd2hpY2ggb25lIHdpbGwgYmUgdXNlZFxuICAgICAgICAgIC8vIGFuZCB3ZSBhbHNvIG5lZWQgdG8gcmVtb3ZlIHRoZSBwaHgtbm8tZmVlZGJhY2sgY2xhc3Mgd2hlbiB0aGUgcGh4LWZlZWRiYWNrLWZvciBhdHRyaWJ1dGUgaXMgcmVtb3ZlZFxuICAgICAgICAgIGlmKERPTS5pc0ZlZWRiYWNrQ29udGFpbmVyKGZyb21FbCwgcGh4RmVlZGJhY2tGb3IpIHx8IERPTS5pc0ZlZWRiYWNrQ29udGFpbmVyKHRvRWwsIHBoeEZlZWRiYWNrRm9yKSl7XG4gICAgICAgICAgICBmZWVkYmFja0NvbnRhaW5lcnMucHVzaChmcm9tRWwpXG4gICAgICAgICAgICBmZWVkYmFja0NvbnRhaW5lcnMucHVzaCh0b0VsKVxuICAgICAgICAgIH1cbiAgICAgICAgICBET00uY2xlYW5DaGlsZE5vZGVzKHRvRWwsIHBoeFVwZGF0ZSlcbiAgICAgICAgICBpZih0aGlzLnNraXBDSURTaWJsaW5nKHRvRWwpKXtcbiAgICAgICAgICAgIC8vIGlmIHRoaXMgaXMgYSBsaXZlIGNvbXBvbmVudCB1c2VkIGluIGEgc3RyZWFtLCB3ZSBtYXkgbmVlZCB0byByZW9yZGVyIGl0XG4gICAgICAgICAgICB0aGlzLm1heWJlUmVPcmRlclN0cmVhbShmcm9tRWwpXG4gICAgICAgICAgICByZXR1cm4gZmFsc2VcbiAgICAgICAgICB9XG4gICAgICAgICAgaWYoRE9NLmlzUGh4U3RpY2t5KGZyb21FbCkpeyByZXR1cm4gZmFsc2UgfVxuICAgICAgICAgIGlmKERPTS5pc0lnbm9yZWQoZnJvbUVsLCBwaHhVcGRhdGUpIHx8IChmcm9tRWwuZm9ybSAmJiBmcm9tRWwuZm9ybS5pc1NhbWVOb2RlKGV4dGVybmFsRm9ybVRyaWdnZXJlZCkpKXtcbiAgICAgICAgICAgIHRoaXMudHJhY2tCZWZvcmUoXCJ1cGRhdGVkXCIsIGZyb21FbCwgdG9FbClcbiAgICAgICAgICAgIERPTS5tZXJnZUF0dHJzKGZyb21FbCwgdG9FbCwge2lzSWdub3JlZDogRE9NLmlzSWdub3JlZChmcm9tRWwsIHBoeFVwZGF0ZSl9KVxuICAgICAgICAgICAgdXBkYXRlcy5wdXNoKGZyb21FbClcbiAgICAgICAgICAgIERPTS5hcHBseVN0aWNreU9wZXJhdGlvbnMoZnJvbUVsKVxuICAgICAgICAgICAgcmV0dXJuIGZhbHNlXG4gICAgICAgICAgfVxuICAgICAgICAgIGlmKGZyb21FbC50eXBlID09PSBcIm51bWJlclwiICYmIChmcm9tRWwudmFsaWRpdHkgJiYgZnJvbUVsLnZhbGlkaXR5LmJhZElucHV0KSl7IHJldHVybiBmYWxzZSB9XG4gICAgICAgICAgaWYoIURPTS5zeW5jUGVuZGluZ1JlZihmcm9tRWwsIHRvRWwsIGRpc2FibGVXaXRoKSl7XG4gICAgICAgICAgICBpZihET00uaXNVcGxvYWRJbnB1dChmcm9tRWwpKXtcbiAgICAgICAgICAgICAgdGhpcy50cmFja0JlZm9yZShcInVwZGF0ZWRcIiwgZnJvbUVsLCB0b0VsKVxuICAgICAgICAgICAgICB1cGRhdGVzLnB1c2goZnJvbUVsKVxuICAgICAgICAgICAgfVxuICAgICAgICAgICAgRE9NLmFwcGx5U3RpY2t5T3BlcmF0aW9ucyhmcm9tRWwpXG4gICAgICAgICAgICByZXR1cm4gZmFsc2VcbiAgICAgICAgICB9XG5cbiAgICAgICAgICAvLyBuZXN0ZWQgdmlldyBoYW5kbGluZ1xuICAgICAgICAgIGlmKERPTS5pc1BoeENoaWxkKHRvRWwpKXtcbiAgICAgICAgICAgIGxldCBwcmV2U2Vzc2lvbiA9IGZyb21FbC5nZXRBdHRyaWJ1dGUoUEhYX1NFU1NJT04pXG4gICAgICAgICAgICBET00ubWVyZ2VBdHRycyhmcm9tRWwsIHRvRWwsIHtleGNsdWRlOiBbUEhYX1NUQVRJQ119KVxuICAgICAgICAgICAgaWYocHJldlNlc3Npb24gIT09IFwiXCIpeyBmcm9tRWwuc2V0QXR0cmlidXRlKFBIWF9TRVNTSU9OLCBwcmV2U2Vzc2lvbikgfVxuICAgICAgICAgICAgZnJvbUVsLnNldEF0dHJpYnV0ZShQSFhfUk9PVF9JRCwgdGhpcy5yb290SUQpXG4gICAgICAgICAgICBET00uYXBwbHlTdGlja3lPcGVyYXRpb25zKGZyb21FbClcbiAgICAgICAgICAgIHJldHVybiBmYWxzZVxuICAgICAgICAgIH1cblxuICAgICAgICAgIC8vIGlucHV0IGhhbmRsaW5nXG4gICAgICAgICAgRE9NLmNvcHlQcml2YXRlcyh0b0VsLCBmcm9tRWwpXG5cbiAgICAgICAgICBsZXQgaXNGb2N1c2VkRm9ybUVsID0gZm9jdXNlZCAmJiBmcm9tRWwuaXNTYW1lTm9kZShmb2N1c2VkKSAmJiBET00uaXNGb3JtSW5wdXQoZnJvbUVsKVxuICAgICAgICAgIC8vIHNraXAgcGF0Y2hpbmcgZm9jdXNlZCBpbnB1dHMgdW5sZXNzIGZvY3VzIGlzIGEgc2VsZWN0IHRoYXQgaGFzIGNoYW5nZWQgb3B0aW9uc1xuICAgICAgICAgIGxldCBmb2N1c2VkU2VsZWN0Q2hhbmdlZCA9IGlzRm9jdXNlZEZvcm1FbCAmJiB0aGlzLmlzQ2hhbmdlZFNlbGVjdChmcm9tRWwsIHRvRWwpXG4gICAgICAgICAgaWYoaXNGb2N1c2VkRm9ybUVsICYmIGZyb21FbC50eXBlICE9PSBcImhpZGRlblwiICYmICFmb2N1c2VkU2VsZWN0Q2hhbmdlZCl7XG4gICAgICAgICAgICB0aGlzLnRyYWNrQmVmb3JlKFwidXBkYXRlZFwiLCBmcm9tRWwsIHRvRWwpXG4gICAgICAgICAgICBET00ubWVyZ2VGb2N1c2VkSW5wdXQoZnJvbUVsLCB0b0VsKVxuICAgICAgICAgICAgRE9NLnN5bmNBdHRyc1RvUHJvcHMoZnJvbUVsKVxuICAgICAgICAgICAgdXBkYXRlcy5wdXNoKGZyb21FbClcbiAgICAgICAgICAgIERPTS5hcHBseVN0aWNreU9wZXJhdGlvbnMoZnJvbUVsKVxuICAgICAgICAgICAgcmV0dXJuIGZhbHNlXG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIC8vIGJsdXIgZm9jdXNlZCBzZWxlY3QgaWYgaXQgY2hhbmdlZCBzbyBuYXRpdmUgVUkgaXMgdXBkYXRlZCAoaWUgc2FmYXJpIHdvbid0IHVwZGF0ZSB2aXNpYmxlIG9wdGlvbnMpXG4gICAgICAgICAgICBpZihmb2N1c2VkU2VsZWN0Q2hhbmdlZCl7IGZyb21FbC5ibHVyKCkgfVxuICAgICAgICAgICAgaWYoRE9NLmlzUGh4VXBkYXRlKHRvRWwsIHBoeFVwZGF0ZSwgW1wiYXBwZW5kXCIsIFwicHJlcGVuZFwiXSkpe1xuICAgICAgICAgICAgICBhcHBlbmRQcmVwZW5kVXBkYXRlcy5wdXNoKG5ldyBET01Qb3N0TW9ycGhSZXN0b3Jlcihmcm9tRWwsIHRvRWwsIHRvRWwuZ2V0QXR0cmlidXRlKHBoeFVwZGF0ZSkpKVxuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICBET00uc3luY0F0dHJzVG9Qcm9wcyh0b0VsKVxuICAgICAgICAgICAgRE9NLmFwcGx5U3RpY2t5T3BlcmF0aW9ucyh0b0VsKVxuICAgICAgICAgICAgdGhpcy50cmFja0JlZm9yZShcInVwZGF0ZWRcIiwgZnJvbUVsLCB0b0VsKVxuICAgICAgICAgICAgcmV0dXJuIHRydWVcbiAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICAgIH0pXG4gICAgfVxuXG4gICAgdGhpcy50cmFja0JlZm9yZShcImFkZGVkXCIsIGNvbnRhaW5lcilcbiAgICB0aGlzLnRyYWNrQmVmb3JlKFwidXBkYXRlZFwiLCBjb250YWluZXIsIGNvbnRhaW5lcilcblxuICAgIGxpdmVTb2NrZXQudGltZShcIm1vcnBoZG9tXCIsICgpID0+IHtcbiAgICAgIHRoaXMuc3RyZWFtcy5mb3JFYWNoKChbcmVmLCBpbnNlcnRzLCBkZWxldGVJZHMsIHJlc2V0XSkgPT4ge1xuICAgICAgICBpbnNlcnRzLmZvckVhY2goKFtrZXksIHN0cmVhbUF0LCBsaW1pdF0pID0+IHtcbiAgICAgICAgICB0aGlzLnN0cmVhbUluc2VydHNba2V5XSA9IHtyZWYsIHN0cmVhbUF0LCBsaW1pdCwgcmVzZXR9XG4gICAgICAgIH0pXG4gICAgICAgIGlmKHJlc2V0ICE9PSB1bmRlZmluZWQpe1xuICAgICAgICAgIERPTS5hbGwoY29udGFpbmVyLCBgWyR7UEhYX1NUUkVBTV9SRUZ9PVwiJHtyZWZ9XCJdYCwgY2hpbGQgPT4ge1xuICAgICAgICAgICAgdGhpcy5yZW1vdmVTdHJlYW1DaGlsZEVsZW1lbnQoY2hpbGQpXG4gICAgICAgICAgfSlcbiAgICAgICAgfVxuICAgICAgICBkZWxldGVJZHMuZm9yRWFjaChpZCA9PiB7XG4gICAgICAgICAgbGV0IGNoaWxkID0gY29udGFpbmVyLnF1ZXJ5U2VsZWN0b3IoYFtpZD1cIiR7aWR9XCJdYClcbiAgICAgICAgICBpZihjaGlsZCl7IHRoaXMucmVtb3ZlU3RyZWFtQ2hpbGRFbGVtZW50KGNoaWxkKSB9XG4gICAgICAgIH0pXG4gICAgICB9KVxuXG4gICAgICAvLyBjbGVhciBzdHJlYW0gaXRlbXMgZnJvbSB0aGUgZGVhZCByZW5kZXIgaWYgdGhleSBhcmUgbm90IGluc2VydGVkIGFnYWluXG4gICAgICBpZihpc0pvaW5QYXRjaCl7XG4gICAgICAgIERPTS5hbGwodGhpcy5jb250YWluZXIsIGBbJHtwaHhVcGRhdGV9PSR7UEhYX1NUUkVBTX1dYCwgZWwgPT4ge1xuICAgICAgICAgIC8vIG1ha2Ugc3VyZSB0byBvbmx5IHJlbW92ZSBlbGVtZW50cyBvd25lZCBieSB0aGUgY3VycmVudCB2aWV3XG4gICAgICAgICAgLy8gc2VlIGh0dHBzOi8vZ2l0aHViLmNvbS9waG9lbml4ZnJhbWV3b3JrL3Bob2VuaXhfbGl2ZV92aWV3L2lzc3Vlcy8zMDQ3XG4gICAgICAgICAgdGhpcy5saXZlU29ja2V0Lm93bmVyKGVsLCAodmlldykgPT4ge1xuICAgICAgICAgICAgaWYodmlldyA9PT0gdGhpcy52aWV3KXtcbiAgICAgICAgICAgICAgQXJyYXkuZnJvbShlbC5jaGlsZHJlbikuZm9yRWFjaChjaGlsZCA9PiB7XG4gICAgICAgICAgICAgICAgdGhpcy5yZW1vdmVTdHJlYW1DaGlsZEVsZW1lbnQoY2hpbGQpXG4gICAgICAgICAgICAgIH0pXG4gICAgICAgICAgICB9XG4gICAgICAgICAgfSlcbiAgICAgICAgfSlcbiAgICAgIH1cblxuICAgICAgbW9ycGguY2FsbCh0aGlzLCB0YXJnZXRDb250YWluZXIsIGh0bWwpXG4gICAgfSlcblxuICAgIGlmKGxpdmVTb2NrZXQuaXNEZWJ1Z0VuYWJsZWQoKSl7XG4gICAgICBkZXRlY3REdXBsaWNhdGVJZHMoKVxuICAgICAgLy8gd2FybiBpZiB0aGVyZSBhcmUgYW55IGlucHV0cyBuYW1lZCBcImlkXCJcbiAgICAgIEFycmF5LmZyb20oZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbChcImlucHV0W25hbWU9aWRdXCIpKS5mb3JFYWNoKG5vZGUgPT4ge1xuICAgICAgICBpZihub2RlLmZvcm0pe1xuICAgICAgICAgIGNvbnNvbGUuZXJyb3IoXCJEZXRlY3RlZCBhbiBpbnB1dCB3aXRoIG5hbWU9XFxcImlkXFxcIiBpbnNpZGUgYSBmb3JtISBUaGlzIHdpbGwgY2F1c2UgcHJvYmxlbXMgd2hlbiBwYXRjaGluZyB0aGUgRE9NLlxcblwiLCBub2RlKVxuICAgICAgICB9XG4gICAgICB9KVxuICAgIH1cblxuICAgIGlmKGFwcGVuZFByZXBlbmRVcGRhdGVzLmxlbmd0aCA+IDApe1xuICAgICAgbGl2ZVNvY2tldC50aW1lKFwicG9zdC1tb3JwaCBhcHBlbmQvcHJlcGVuZCByZXN0b3JhdGlvblwiLCAoKSA9PiB7XG4gICAgICAgIGFwcGVuZFByZXBlbmRVcGRhdGVzLmZvckVhY2godXBkYXRlID0+IHVwZGF0ZS5wZXJmb3JtKCkpXG4gICAgICB9KVxuICAgIH1cblxuICAgIERPTS5tYXliZUhpZGVGZWVkYmFjayh0YXJnZXRDb250YWluZXIsIGZlZWRiYWNrQ29udGFpbmVycywgcGh4RmVlZGJhY2tGb3IsIHBoeEZlZWRiYWNrR3JvdXApXG5cbiAgICBsaXZlU29ja2V0LnNpbGVuY2VFdmVudHMoKCkgPT4gRE9NLnJlc3RvcmVGb2N1cyhmb2N1c2VkLCBzZWxlY3Rpb25TdGFydCwgc2VsZWN0aW9uRW5kKSlcbiAgICBET00uZGlzcGF0Y2hFdmVudChkb2N1bWVudCwgXCJwaHg6dXBkYXRlXCIpXG4gICAgYWRkZWQuZm9yRWFjaChlbCA9PiB0aGlzLnRyYWNrQWZ0ZXIoXCJhZGRlZFwiLCBlbCkpXG4gICAgdXBkYXRlcy5mb3JFYWNoKGVsID0+IHRoaXMudHJhY2tBZnRlcihcInVwZGF0ZWRcIiwgZWwpKVxuXG4gICAgdGhpcy50cmFuc2l0aW9uUGVuZGluZ1JlbW92ZXMoKVxuXG4gICAgaWYoZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkKXtcbiAgICAgIGxpdmVTb2NrZXQudW5sb2FkKClcbiAgICAgIC8vIHVzZSBwcm90b3R5cGUncyBzdWJtaXQgaW4gY2FzZSB0aGVyZSdzIGEgZm9ybSBjb250cm9sIHdpdGggbmFtZSBvciBpZCBvZiBcInN1Ym1pdFwiXG4gICAgICAvLyBodHRwczovL2RldmVsb3Blci5tb3ppbGxhLm9yZy9lbi1VUy9kb2NzL1dlYi9BUEkvSFRNTEZvcm1FbGVtZW50L3N1Ym1pdFxuICAgICAgT2JqZWN0LmdldFByb3RvdHlwZU9mKGV4dGVybmFsRm9ybVRyaWdnZXJlZCkuc3VibWl0LmNhbGwoZXh0ZXJuYWxGb3JtVHJpZ2dlcmVkKVxuICAgIH1cbiAgICByZXR1cm4gdHJ1ZVxuICB9XG5cbiAgb25Ob2RlRGlzY2FyZGVkKGVsKXtcbiAgICAvLyBuZXN0ZWQgdmlldyBoYW5kbGluZ1xuICAgIGlmKERPTS5pc1BoeENoaWxkKGVsKSB8fCBET00uaXNQaHhTdGlja3koZWwpKXsgdGhpcy5saXZlU29ja2V0LmRlc3Ryb3lWaWV3QnlFbChlbCkgfVxuICAgIHRoaXMudHJhY2tBZnRlcihcImRpc2NhcmRlZFwiLCBlbClcbiAgfVxuXG4gIG1heWJlUGVuZGluZ1JlbW92ZShub2RlKXtcbiAgICBpZihub2RlLmdldEF0dHJpYnV0ZSAmJiBub2RlLmdldEF0dHJpYnV0ZSh0aGlzLnBoeFJlbW92ZSkgIT09IG51bGwpe1xuICAgICAgdGhpcy5wZW5kaW5nUmVtb3Zlcy5wdXNoKG5vZGUpXG4gICAgICByZXR1cm4gdHJ1ZVxuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gZmFsc2VcbiAgICB9XG4gIH1cblxuICByZW1vdmVTdHJlYW1DaGlsZEVsZW1lbnQoY2hpbGQpe1xuICAgIC8vIHdlIG5lZWQgdG8gc3RvcmUgdGhlIG5vZGUgaWYgaXQgaXMgYWN0dWFsbHkgcmUtYWRkZWQgaW4gdGhlIHNhbWUgcGF0Y2hcbiAgICAvLyB3ZSBkbyBOT1Qgd2FudCB0byBleGVjdXRlIHBoeC1yZW1vdmUsIHdlIGRvIE5PVCB3YW50IHRvIGNhbGwgb25Ob2RlRGlzY2FyZGVkXG4gICAgaWYodGhpcy5zdHJlYW1JbnNlcnRzW2NoaWxkLmlkXSl7XG4gICAgICB0aGlzLnN0cmVhbUNvbXBvbmVudFJlc3RvcmVbY2hpbGQuaWRdID0gY2hpbGRcbiAgICAgIGNoaWxkLnJlbW92ZSgpXG4gICAgfSBlbHNlIHtcbiAgICAgIC8vIG9ubHkgcmVtb3ZlIHRoZSBlbGVtZW50IG5vdyBpZiBpdCBoYXMgbm8gcGh4LXJlbW92ZSBiaW5kaW5nXG4gICAgICBpZighdGhpcy5tYXliZVBlbmRpbmdSZW1vdmUoY2hpbGQpKXtcbiAgICAgICAgY2hpbGQucmVtb3ZlKClcbiAgICAgICAgdGhpcy5vbk5vZGVEaXNjYXJkZWQoY2hpbGQpXG4gICAgICB9XG4gICAgfVxuICB9XG5cbiAgZ2V0U3RyZWFtSW5zZXJ0KGVsKXtcbiAgICBsZXQgaW5zZXJ0ID0gZWwuaWQgPyB0aGlzLnN0cmVhbUluc2VydHNbZWwuaWRdIDoge31cbiAgICByZXR1cm4gaW5zZXJ0IHx8IHt9XG4gIH1cblxuICBzZXRTdHJlYW1SZWYoZWwsIHJlZil7XG4gICAgRE9NLnB1dFN0aWNreShlbCwgUEhYX1NUUkVBTV9SRUYsIGVsID0+IGVsLnNldEF0dHJpYnV0ZShQSFhfU1RSRUFNX1JFRiwgcmVmKSlcbiAgfVxuXG4gIG1heWJlUmVPcmRlclN0cmVhbShlbCwgaXNOZXcpe1xuICAgIGxldCB7cmVmLCBzdHJlYW1BdCwgcmVzZXR9ID0gdGhpcy5nZXRTdHJlYW1JbnNlcnQoZWwpXG4gICAgaWYoc3RyZWFtQXQgPT09IHVuZGVmaW5lZCl7IHJldHVybiB9XG5cbiAgICAvLyB3ZSBuZWVkIHRvIHNldCB0aGUgUEhYX1NUUkVBTV9SRUYgaGVyZSBhcyB3ZWxsIGFzIGFkZENoaWxkIGlzIGludm9rZWQgb25seSBmb3IgcGFyZW50c1xuICAgIHRoaXMuc2V0U3RyZWFtUmVmKGVsLCByZWYpXG5cbiAgICBpZighcmVzZXQgJiYgIWlzTmV3KXtcbiAgICAgIC8vIHdlIG9ubHkgcmVvcmRlciBpZiB0aGUgZWxlbWVudCBpcyBuZXcgb3IgaXQncyBhIHN0cmVhbSByZXNldFxuICAgICAgcmV0dXJuXG4gICAgfVxuXG4gICAgLy8gY2hlY2sgaWYgdGhlIGVsZW1lbnQgaGFzIGEgcGFyZW50IGVsZW1lbnQ7XG4gICAgLy8gaXQgZG9lc24ndCBpZiB3ZSBhcmUgY3VycmVudGx5IHJlY3Vyc2l2ZWx5IG1vcnBoaW5nIChyZXN0b3JpbmcgYSBzYXZlZCBzdHJlYW0gY2hpbGQpXG4gICAgLy8gYmVjYXVzZSB0aGUgZWxlbWVudCBpcyBub3QgeWV0IGFkZGVkIHRvIHRoZSByZWFsIGRvbTtcbiAgICAvLyByZW9yZGVyaW5nIGRvZXMgbm90IG1ha2Ugc2Vuc2UgaW4gdGhhdCBjYXNlIGFueXdheVxuICAgIGlmKCFlbC5wYXJlbnRFbGVtZW50KXsgcmV0dXJuIH1cblxuICAgIGlmKHN0cmVhbUF0ID09PSAwKXtcbiAgICAgIGVsLnBhcmVudEVsZW1lbnQuaW5zZXJ0QmVmb3JlKGVsLCBlbC5wYXJlbnRFbGVtZW50LmZpcnN0RWxlbWVudENoaWxkKVxuICAgIH0gZWxzZSBpZihzdHJlYW1BdCA+IDApe1xuICAgICAgbGV0IGNoaWxkcmVuID0gQXJyYXkuZnJvbShlbC5wYXJlbnRFbGVtZW50LmNoaWxkcmVuKVxuICAgICAgbGV0IG9sZEluZGV4ID0gY2hpbGRyZW4uaW5kZXhPZihlbClcbiAgICAgIGlmKHN0cmVhbUF0ID49IGNoaWxkcmVuLmxlbmd0aCAtIDEpe1xuICAgICAgICBlbC5wYXJlbnRFbGVtZW50LmFwcGVuZENoaWxkKGVsKVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgbGV0IHNpYmxpbmcgPSBjaGlsZHJlbltzdHJlYW1BdF1cbiAgICAgICAgaWYob2xkSW5kZXggPiBzdHJlYW1BdCl7XG4gICAgICAgICAgZWwucGFyZW50RWxlbWVudC5pbnNlcnRCZWZvcmUoZWwsIHNpYmxpbmcpXG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgZWwucGFyZW50RWxlbWVudC5pbnNlcnRCZWZvcmUoZWwsIHNpYmxpbmcubmV4dEVsZW1lbnRTaWJsaW5nKVxuICAgICAgICB9XG4gICAgICB9XG4gICAgfVxuXG4gICAgdGhpcy5tYXliZUxpbWl0U3RyZWFtKGVsKVxuICB9XG5cbiAgbWF5YmVMaW1pdFN0cmVhbShlbCl7XG4gICAgbGV0IHtsaW1pdH0gPSB0aGlzLmdldFN0cmVhbUluc2VydChlbClcbiAgICBsZXQgY2hpbGRyZW4gPSBsaW1pdCAhPT0gbnVsbCAmJiBBcnJheS5mcm9tKGVsLnBhcmVudEVsZW1lbnQuY2hpbGRyZW4pXG4gICAgaWYobGltaXQgJiYgbGltaXQgPCAwICYmIGNoaWxkcmVuLmxlbmd0aCA+IGxpbWl0ICogLTEpe1xuICAgICAgY2hpbGRyZW4uc2xpY2UoMCwgY2hpbGRyZW4ubGVuZ3RoICsgbGltaXQpLmZvckVhY2goY2hpbGQgPT4gdGhpcy5yZW1vdmVTdHJlYW1DaGlsZEVsZW1lbnQoY2hpbGQpKVxuICAgIH0gZWxzZSBpZihsaW1pdCAmJiBsaW1pdCA+PSAwICYmIGNoaWxkcmVuLmxlbmd0aCA+IGxpbWl0KXtcbiAgICAgIGNoaWxkcmVuLnNsaWNlKGxpbWl0KS5mb3JFYWNoKGNoaWxkID0+IHRoaXMucmVtb3ZlU3RyZWFtQ2hpbGRFbGVtZW50KGNoaWxkKSlcbiAgICB9XG4gIH1cblxuICB0cmFuc2l0aW9uUGVuZGluZ1JlbW92ZXMoKXtcbiAgICBsZXQge3BlbmRpbmdSZW1vdmVzLCBsaXZlU29ja2V0fSA9IHRoaXNcbiAgICBpZihwZW5kaW5nUmVtb3Zlcy5sZW5ndGggPiAwKXtcbiAgICAgIGxpdmVTb2NrZXQudHJhbnNpdGlvblJlbW92ZXMocGVuZGluZ1JlbW92ZXMpXG4gICAgICBsaXZlU29ja2V0LnJlcXVlc3RET01VcGRhdGUoKCkgPT4ge1xuICAgICAgICBwZW5kaW5nUmVtb3Zlcy5mb3JFYWNoKGVsID0+IHtcbiAgICAgICAgICBsZXQgY2hpbGQgPSBET00uZmlyc3RQaHhDaGlsZChlbClcbiAgICAgICAgICBpZihjaGlsZCl7IGxpdmVTb2NrZXQuZGVzdHJveVZpZXdCeUVsKGNoaWxkKSB9XG4gICAgICAgICAgZWwucmVtb3ZlKClcbiAgICAgICAgfSlcbiAgICAgICAgdGhpcy50cmFja0FmdGVyKFwidHJhbnNpdGlvbnNEaXNjYXJkZWRcIiwgcGVuZGluZ1JlbW92ZXMpXG4gICAgICB9KVxuICAgIH1cbiAgfVxuXG4gIGlzQ2hhbmdlZFNlbGVjdChmcm9tRWwsIHRvRWwpe1xuICAgIGlmKCEoZnJvbUVsIGluc3RhbmNlb2YgSFRNTFNlbGVjdEVsZW1lbnQpIHx8IGZyb21FbC5tdWx0aXBsZSl7IHJldHVybiBmYWxzZSB9XG4gICAgaWYoZnJvbUVsLm9wdGlvbnMubGVuZ3RoICE9PSB0b0VsLm9wdGlvbnMubGVuZ3RoKXsgcmV0dXJuIHRydWUgfVxuXG4gICAgbGV0IGZyb21TZWxlY3RlZCA9IGZyb21FbC5zZWxlY3RlZE9wdGlvbnNbMF1cbiAgICBsZXQgdG9TZWxlY3RlZCA9IHRvRWwuc2VsZWN0ZWRPcHRpb25zWzBdXG4gICAgaWYoZnJvbVNlbGVjdGVkICYmIGZyb21TZWxlY3RlZC5oYXNBdHRyaWJ1dGUoXCJzZWxlY3RlZFwiKSl7XG4gICAgICB0b1NlbGVjdGVkLnNldEF0dHJpYnV0ZShcInNlbGVjdGVkXCIsIGZyb21TZWxlY3RlZC5nZXRBdHRyaWJ1dGUoXCJzZWxlY3RlZFwiKSlcbiAgICB9XG5cbiAgICAvLyBpbiBnZW5lcmFsIHdlIGhhdmUgdG8gYmUgdmVyeSBjYXJlZnVsIHdpdGggdXNpbmcgaXNFcXVhbE5vZGUgYXMgaXQgZG9lcyBub3QgYSByZWxpYWJsZVxuICAgIC8vIERPTSB0cmVlIGVxdWFsaXR5IGNoZWNrLCBidXQgZm9yIHNlbGVjdGlvbiBhdHRyaWJ1dGVzIGFuZCBvcHRpb25zIGl0IHdvcmtzIGZpbmVcbiAgICByZXR1cm4gIWZyb21FbC5pc0VxdWFsTm9kZSh0b0VsKVxuICB9XG5cbiAgaXNDSURQYXRjaCgpeyByZXR1cm4gdGhpcy5jaWRQYXRjaCB9XG5cbiAgc2tpcENJRFNpYmxpbmcoZWwpe1xuICAgIHJldHVybiBlbC5ub2RlVHlwZSA9PT0gTm9kZS5FTEVNRU5UX05PREUgJiYgZWwuaGFzQXR0cmlidXRlKFBIWF9TS0lQKVxuICB9XG5cbiAgdGFyZ2V0Q0lEQ29udGFpbmVyKGh0bWwpe1xuICAgIGlmKCF0aGlzLmlzQ0lEUGF0Y2goKSl7IHJldHVybiB9XG4gICAgbGV0IFtmaXJzdCwgLi4ucmVzdF0gPSBET00uZmluZENvbXBvbmVudE5vZGVMaXN0KHRoaXMuY29udGFpbmVyLCB0aGlzLnRhcmdldENJRClcbiAgICBpZihyZXN0Lmxlbmd0aCA9PT0gMCAmJiBET00uY2hpbGROb2RlTGVuZ3RoKGh0bWwpID09PSAxKXtcbiAgICAgIHJldHVybiBmaXJzdFxuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gZmlyc3QgJiYgZmlyc3QucGFyZW50Tm9kZVxuICAgIH1cbiAgfVxuXG4gIGluZGV4T2YocGFyZW50LCBjaGlsZCl7IHJldHVybiBBcnJheS5mcm9tKHBhcmVudC5jaGlsZHJlbikuaW5kZXhPZihjaGlsZCkgfVxufVxuIiwgImltcG9ydCB7XG4gIENPTVBPTkVOVFMsXG4gIERZTkFNSUNTLFxuICBURU1QTEFURVMsXG4gIEVWRU5UUyxcbiAgUEhYX0NPTVBPTkVOVCxcbiAgUEhYX1NLSVAsXG4gIFBIWF9NQUdJQ19JRCxcbiAgUkVQTFksXG4gIFNUQVRJQyxcbiAgVElUTEUsXG4gIFNUUkVBTSxcbiAgUk9PVCxcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCJcblxuaW1wb3J0IHtcbiAgaXNPYmplY3QsXG4gIGxvZ0Vycm9yLFxuICBpc0NpZCxcbn0gZnJvbSBcIi4vdXRpbHNcIlxuXG5jb25zdCBWT0lEX1RBR1MgPSBuZXcgU2V0KFtcbiAgXCJhcmVhXCIsXG4gIFwiYmFzZVwiLFxuICBcImJyXCIsXG4gIFwiY29sXCIsXG4gIFwiY29tbWFuZFwiLFxuICBcImVtYmVkXCIsXG4gIFwiaHJcIixcbiAgXCJpbWdcIixcbiAgXCJpbnB1dFwiLFxuICBcImtleWdlblwiLFxuICBcImxpbmtcIixcbiAgXCJtZXRhXCIsXG4gIFwicGFyYW1cIixcbiAgXCJzb3VyY2VcIixcbiAgXCJ0cmFja1wiLFxuICBcIndiclwiXG5dKVxuY29uc3QgcXVvdGVDaGFycyA9IG5ldyBTZXQoW1wiJ1wiLCAnXCInXSlcblxuZXhwb3J0IGxldCBtb2RpZnlSb290ID0gKGh0bWwsIGF0dHJzLCBjbGVhcklubmVySFRNTCkgPT4ge1xuICBsZXQgaSA9IDBcbiAgbGV0IGluc2lkZUNvbW1lbnQgPSBmYWxzZVxuICBsZXQgYmVmb3JlVGFnLCBhZnRlclRhZywgdGFnLCB0YWdOYW1lRW5kc0F0LCBpZCwgbmV3SFRNTFxuXG4gIGxldCBsb29rYWhlYWQgPSBodG1sLm1hdGNoKC9eKFxccyooPzo8IS0tLio/LS0+XFxzKikqKTwoW15cXHNcXC8+XSspLylcbiAgaWYobG9va2FoZWFkID09PSBudWxsKSB7IHRocm93IG5ldyBFcnJvcihgbWFsZm9ybWVkIGh0bWwgJHtodG1sfWApIH1cblxuICBpID0gbG9va2FoZWFkWzBdLmxlbmd0aFxuICBiZWZvcmVUYWcgPSBsb29rYWhlYWRbMV1cbiAgdGFnID0gbG9va2FoZWFkWzJdXG4gIHRhZ05hbWVFbmRzQXQgPSBpXG5cbiAgLy8gU2NhbiB0aGUgb3BlbmluZyB0YWcgZm9yIGlkLCBpZiB0aGVyZSBpcyBhbnlcbiAgZm9yKGk7IGkgPCBodG1sLmxlbmd0aDsgaSsrKXtcbiAgICBpZihodG1sLmNoYXJBdChpKSA9PT0gXCI+XCIgKXsgYnJlYWsgfVxuICAgIGlmKGh0bWwuY2hhckF0KGkpID09PSBcIj1cIil7XG4gICAgICBsZXQgaXNJZCA9IGh0bWwuc2xpY2UoaSAtIDMsIGkpID09PSBcIiBpZFwiXG4gICAgICBpKys7XG4gICAgICBsZXQgY2hhciA9IGh0bWwuY2hhckF0KGkpXG4gICAgICBpZiAocXVvdGVDaGFycy5oYXMoY2hhcikpIHtcbiAgICAgICAgbGV0IGF0dHJTdGFydHNBdCA9IGlcbiAgICAgICAgaSsrXG4gICAgICAgIGZvcihpOyBpIDwgaHRtbC5sZW5ndGg7IGkrKyl7XG4gICAgICAgICAgaWYoaHRtbC5jaGFyQXQoaSkgPT09IGNoYXIpeyBicmVhayB9XG4gICAgICAgIH1cbiAgICAgICAgaWYgKGlzSWQpIHtcbiAgICAgICAgICBpZCA9IGh0bWwuc2xpY2UoYXR0clN0YXJ0c0F0ICsgMSwgaSlcbiAgICAgICAgICBicmVha1xuICAgICAgICB9XG4gICAgICB9XG4gICAgfVxuICB9XG5cbiAgbGV0IGNsb3NlQXQgPSBodG1sLmxlbmd0aCAtIDFcbiAgaW5zaWRlQ29tbWVudCA9IGZhbHNlXG4gIHdoaWxlKGNsb3NlQXQgPj0gYmVmb3JlVGFnLmxlbmd0aCArIHRhZy5sZW5ndGgpe1xuICAgIGxldCBjaGFyID0gaHRtbC5jaGFyQXQoY2xvc2VBdClcbiAgICBpZihpbnNpZGVDb21tZW50KXtcbiAgICAgIGlmKGNoYXIgPT09IFwiLVwiICYmIGh0bWwuc2xpY2UoY2xvc2VBdCAtIDMsIGNsb3NlQXQpID09PSBcIjwhLVwiKXtcbiAgICAgICAgaW5zaWRlQ29tbWVudCA9IGZhbHNlXG4gICAgICAgIGNsb3NlQXQgLT0gNFxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgY2xvc2VBdCAtPSAxXG4gICAgICB9XG4gICAgfSBlbHNlIGlmKGNoYXIgPT09IFwiPlwiICYmIGh0bWwuc2xpY2UoY2xvc2VBdCAtIDIsIGNsb3NlQXQpID09PSBcIi0tXCIpe1xuICAgICAgaW5zaWRlQ29tbWVudCA9IHRydWVcbiAgICAgIGNsb3NlQXQgLT0gM1xuICAgIH0gZWxzZSBpZihjaGFyID09PSBcIj5cIil7XG4gICAgICBicmVha1xuICAgIH0gZWxzZSB7XG4gICAgICBjbG9zZUF0IC09IDFcbiAgICB9XG4gIH1cbiAgYWZ0ZXJUYWcgPSBodG1sLnNsaWNlKGNsb3NlQXQgKyAxLCBodG1sLmxlbmd0aClcblxuICBsZXQgYXR0cnNTdHIgPVxuICAgIE9iamVjdC5rZXlzKGF0dHJzKVxuICAgIC5tYXAoYXR0ciA9PiBhdHRyc1thdHRyXSA9PT0gdHJ1ZSA/IGF0dHIgOiBgJHthdHRyfT1cIiR7YXR0cnNbYXR0cl19XCJgKVxuICAgIC5qb2luKFwiIFwiKVxuXG4gIGlmKGNsZWFySW5uZXJIVE1MKXtcbiAgICAvLyBLZWVwIHRoZSBpZCBpZiBhbnlcbiAgICBsZXQgaWRBdHRyU3RyID0gaWQgPyBgIGlkPVwiJHtpZH1cImAgOiBcIlwiO1xuICAgIGlmKFZPSURfVEFHUy5oYXModGFnKSl7XG4gICAgICBuZXdIVE1MID0gYDwke3RhZ30ke2lkQXR0clN0cn0ke2F0dHJzU3RyID09PSBcIlwiID8gXCJcIiA6IFwiIFwifSR7YXR0cnNTdHJ9Lz5gXG4gICAgfSBlbHNlIHtcbiAgICAgIG5ld0hUTUwgPSBgPCR7dGFnfSR7aWRBdHRyU3RyfSR7YXR0cnNTdHIgPT09IFwiXCIgPyBcIlwiIDogXCIgXCJ9JHthdHRyc1N0cn0+PC8ke3RhZ30+YFxuICAgIH1cbiAgfSBlbHNlIHtcbiAgICBsZXQgcmVzdCA9IGh0bWwuc2xpY2UodGFnTmFtZUVuZHNBdCwgY2xvc2VBdCArIDEpXG4gICAgbmV3SFRNTCA9IGA8JHt0YWd9JHthdHRyc1N0ciA9PT0gXCJcIiA/IFwiXCIgOiBcIiBcIn0ke2F0dHJzU3RyfSR7cmVzdH1gXG4gIH1cblxuICByZXR1cm4gW25ld0hUTUwsIGJlZm9yZVRhZywgYWZ0ZXJUYWddXG59XG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFJlbmRlcmVkIHtcbiAgc3RhdGljIGV4dHJhY3QoZGlmZil7XG4gICAgbGV0IHtbUkVQTFldOiByZXBseSwgW0VWRU5UU106IGV2ZW50cywgW1RJVExFXTogdGl0bGV9ID0gZGlmZlxuICAgIGRlbGV0ZSBkaWZmW1JFUExZXVxuICAgIGRlbGV0ZSBkaWZmW0VWRU5UU11cbiAgICBkZWxldGUgZGlmZltUSVRMRV1cbiAgICByZXR1cm4ge2RpZmYsIHRpdGxlLCByZXBseTogcmVwbHkgfHwgbnVsbCwgZXZlbnRzOiBldmVudHMgfHwgW119XG4gIH1cblxuICBjb25zdHJ1Y3Rvcih2aWV3SWQsIHJlbmRlcmVkKXtcbiAgICB0aGlzLnZpZXdJZCA9IHZpZXdJZFxuICAgIHRoaXMucmVuZGVyZWQgPSB7fVxuICAgIHRoaXMubWFnaWNJZCA9IDBcbiAgICB0aGlzLm1lcmdlRGlmZihyZW5kZXJlZClcbiAgfVxuXG4gIHBhcmVudFZpZXdJZCgpeyByZXR1cm4gdGhpcy52aWV3SWQgfVxuXG4gIHRvU3RyaW5nKG9ubHlDaWRzKXtcbiAgICBsZXQgW3N0ciwgc3RyZWFtc10gPSB0aGlzLnJlY3Vyc2l2ZVRvU3RyaW5nKHRoaXMucmVuZGVyZWQsIHRoaXMucmVuZGVyZWRbQ09NUE9ORU5UU10sIG9ubHlDaWRzLCB0cnVlLCB7fSlcbiAgICByZXR1cm4gW3N0ciwgc3RyZWFtc11cbiAgfVxuXG4gIHJlY3Vyc2l2ZVRvU3RyaW5nKHJlbmRlcmVkLCBjb21wb25lbnRzID0gcmVuZGVyZWRbQ09NUE9ORU5UU10sIG9ubHlDaWRzLCBjaGFuZ2VUcmFja2luZywgcm9vdEF0dHJzKXtcbiAgICBvbmx5Q2lkcyA9IG9ubHlDaWRzID8gbmV3IFNldChvbmx5Q2lkcykgOiBudWxsXG4gICAgbGV0IG91dHB1dCA9IHtidWZmZXI6IFwiXCIsIGNvbXBvbmVudHM6IGNvbXBvbmVudHMsIG9ubHlDaWRzOiBvbmx5Q2lkcywgc3RyZWFtczogbmV3IFNldCgpfVxuICAgIHRoaXMudG9PdXRwdXRCdWZmZXIocmVuZGVyZWQsIG51bGwsIG91dHB1dCwgY2hhbmdlVHJhY2tpbmcsIHJvb3RBdHRycylcbiAgICByZXR1cm4gW291dHB1dC5idWZmZXIsIG91dHB1dC5zdHJlYW1zXVxuICB9XG5cbiAgY29tcG9uZW50Q0lEcyhkaWZmKXsgcmV0dXJuIE9iamVjdC5rZXlzKGRpZmZbQ09NUE9ORU5UU10gfHwge30pLm1hcChpID0+IHBhcnNlSW50KGkpKSB9XG5cbiAgaXNDb21wb25lbnRPbmx5RGlmZihkaWZmKXtcbiAgICBpZighZGlmZltDT01QT05FTlRTXSl7IHJldHVybiBmYWxzZSB9XG4gICAgcmV0dXJuIE9iamVjdC5rZXlzKGRpZmYpLmxlbmd0aCA9PT0gMVxuICB9XG5cbiAgZ2V0Q29tcG9uZW50KGRpZmYsIGNpZCl7IHJldHVybiBkaWZmW0NPTVBPTkVOVFNdW2NpZF0gfVxuXG4gIHJlc2V0UmVuZGVyKGNpZCl7XG4gICAgLy8gd2UgYXJlIHJhY2luZyBhIGNvbXBvbmVudCBkZXN0cm95LCBpdCBjb3VsZCBub3QgZXhpc3QsIHNvXG4gICAgLy8gbWFrZSBzdXJlIHRoYXQgd2UgZG9uJ3QgdHJ5IHRvIHNldCByZXNldCBvbiB1bmRlZmluZWRcbiAgICBpZih0aGlzLnJlbmRlcmVkW0NPTVBPTkVOVFNdW2NpZF0pe1xuICAgICAgdGhpcy5yZW5kZXJlZFtDT01QT05FTlRTXVtjaWRdLnJlc2V0ID0gdHJ1ZVxuICAgIH1cbiAgfVxuXG4gIG1lcmdlRGlmZihkaWZmKXtcbiAgICBsZXQgbmV3YyA9IGRpZmZbQ09NUE9ORU5UU11cbiAgICBsZXQgY2FjaGUgPSB7fVxuICAgIGRlbGV0ZSBkaWZmW0NPTVBPTkVOVFNdXG4gICAgdGhpcy5yZW5kZXJlZCA9IHRoaXMubXV0YWJsZU1lcmdlKHRoaXMucmVuZGVyZWQsIGRpZmYpXG4gICAgdGhpcy5yZW5kZXJlZFtDT01QT05FTlRTXSA9IHRoaXMucmVuZGVyZWRbQ09NUE9ORU5UU10gfHwge31cblxuICAgIGlmKG5ld2Mpe1xuICAgICAgbGV0IG9sZGMgPSB0aGlzLnJlbmRlcmVkW0NPTVBPTkVOVFNdXG5cbiAgICAgIGZvcihsZXQgY2lkIGluIG5ld2Mpe1xuICAgICAgICBuZXdjW2NpZF0gPSB0aGlzLmNhY2hlZEZpbmRDb21wb25lbnQoY2lkLCBuZXdjW2NpZF0sIG9sZGMsIG5ld2MsIGNhY2hlKVxuICAgICAgfVxuXG4gICAgICBmb3IobGV0IGNpZCBpbiBuZXdjKXsgb2xkY1tjaWRdID0gbmV3Y1tjaWRdIH1cbiAgICAgIGRpZmZbQ09NUE9ORU5UU10gPSBuZXdjXG4gICAgfVxuICB9XG5cbiAgY2FjaGVkRmluZENvbXBvbmVudChjaWQsIGNkaWZmLCBvbGRjLCBuZXdjLCBjYWNoZSl7XG4gICAgaWYoY2FjaGVbY2lkXSl7XG4gICAgICByZXR1cm4gY2FjaGVbY2lkXVxuICAgIH0gZWxzZSB7XG4gICAgICBsZXQgbmRpZmYsIHN0YXQsIHNjaWQgPSBjZGlmZltTVEFUSUNdXG5cbiAgICAgIGlmKGlzQ2lkKHNjaWQpKXtcbiAgICAgICAgbGV0IHRkaWZmXG5cbiAgICAgICAgaWYoc2NpZCA+IDApe1xuICAgICAgICAgIHRkaWZmID0gdGhpcy5jYWNoZWRGaW5kQ29tcG9uZW50KHNjaWQsIG5ld2Nbc2NpZF0sIG9sZGMsIG5ld2MsIGNhY2hlKVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIHRkaWZmID0gb2xkY1stc2NpZF1cbiAgICAgICAgfVxuXG4gICAgICAgIHN0YXQgPSB0ZGlmZltTVEFUSUNdXG4gICAgICAgIG5kaWZmID0gdGhpcy5jbG9uZU1lcmdlKHRkaWZmLCBjZGlmZiwgdHJ1ZSlcbiAgICAgICAgbmRpZmZbU1RBVElDXSA9IHN0YXRcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIG5kaWZmID0gY2RpZmZbU1RBVElDXSAhPT0gdW5kZWZpbmVkIHx8IG9sZGNbY2lkXSA9PT0gdW5kZWZpbmVkID9cbiAgICAgICAgICBjZGlmZiA6IHRoaXMuY2xvbmVNZXJnZShvbGRjW2NpZF0sIGNkaWZmLCBmYWxzZSlcbiAgICAgIH1cblxuICAgICAgY2FjaGVbY2lkXSA9IG5kaWZmXG4gICAgICByZXR1cm4gbmRpZmZcbiAgICB9XG4gIH1cblxuICBtdXRhYmxlTWVyZ2UodGFyZ2V0LCBzb3VyY2Upe1xuICAgIGlmKHNvdXJjZVtTVEFUSUNdICE9PSB1bmRlZmluZWQpe1xuICAgICAgcmV0dXJuIHNvdXJjZVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLmRvTXV0YWJsZU1lcmdlKHRhcmdldCwgc291cmNlKVxuICAgICAgcmV0dXJuIHRhcmdldFxuICAgIH1cbiAgfVxuXG4gIGRvTXV0YWJsZU1lcmdlKHRhcmdldCwgc291cmNlKXtcbiAgICBmb3IobGV0IGtleSBpbiBzb3VyY2Upe1xuICAgICAgbGV0IHZhbCA9IHNvdXJjZVtrZXldXG4gICAgICBsZXQgdGFyZ2V0VmFsID0gdGFyZ2V0W2tleV1cbiAgICAgIGxldCBpc09ialZhbCA9IGlzT2JqZWN0KHZhbClcbiAgICAgIGlmKGlzT2JqVmFsICYmIHZhbFtTVEFUSUNdID09PSB1bmRlZmluZWQgJiYgaXNPYmplY3QodGFyZ2V0VmFsKSl7XG4gICAgICAgIHRoaXMuZG9NdXRhYmxlTWVyZ2UodGFyZ2V0VmFsLCB2YWwpXG4gICAgICB9IGVsc2Uge1xuICAgICAgICB0YXJnZXRba2V5XSA9IHZhbFxuICAgICAgfVxuICAgIH1cbiAgICBpZih0YXJnZXRbUk9PVF0pe1xuICAgICAgdGFyZ2V0Lm5ld1JlbmRlciA9IHRydWVcbiAgICB9XG4gIH1cblxuICAvLyBNZXJnZXMgY2lkIHRyZWVzIHRvZ2V0aGVyLCBjb3B5aW5nIHN0YXRpY3MgZnJvbSBzb3VyY2UgdHJlZS5cbiAgLy9cbiAgLy8gVGhlIGBwcnVuZU1hZ2ljSWRgIGlzIHBhc3NlZCB0byBjb250cm9sIHBydW5pbmcgdGhlIG1hZ2ljSWQgb2YgdGhlXG4gIC8vIHRhcmdldC4gV2UgbXVzdCBhbHdheXMgcHJ1bmUgdGhlIG1hZ2ljSWQgd2hlbiB3ZSBhcmUgc2hhcmluZyBzdGF0aWNzXG4gIC8vIGZyb20gYW5vdGhlciBjb21wb25lbnQuIElmIG5vdCBwcnVuaW5nLCB3ZSByZXBsaWNhdGUgdGhlIGxvZ2ljIGZyb21cbiAgLy8gbXV0YWJsZU1lcmdlLCB3aGVyZSB3ZSBzZXQgbmV3UmVuZGVyIHRvIHRydWUgaWYgdGhlcmUgaXMgYSByb290XG4gIC8vIChlZmZlY3RpdmVseSBmb3JjaW5nIHRoZSBuZXcgdmVyc2lvbiB0byBiZSByZW5kZXJlZCBpbnN0ZWFkIG9mIHNraXBwZWQpXG4gIC8vXG4gIGNsb25lTWVyZ2UodGFyZ2V0LCBzb3VyY2UsIHBydW5lTWFnaWNJZCl7XG4gICAgbGV0IG1lcmdlZCA9IHsuLi50YXJnZXQsIC4uLnNvdXJjZX1cbiAgICBmb3IobGV0IGtleSBpbiBtZXJnZWQpe1xuICAgICAgbGV0IHZhbCA9IHNvdXJjZVtrZXldXG4gICAgICBsZXQgdGFyZ2V0VmFsID0gdGFyZ2V0W2tleV1cbiAgICAgIGlmKGlzT2JqZWN0KHZhbCkgJiYgdmFsW1NUQVRJQ10gPT09IHVuZGVmaW5lZCAmJiBpc09iamVjdCh0YXJnZXRWYWwpKXtcbiAgICAgICAgbWVyZ2VkW2tleV0gPSB0aGlzLmNsb25lTWVyZ2UodGFyZ2V0VmFsLCB2YWwsIHBydW5lTWFnaWNJZClcbiAgICAgIH0gZWxzZSBpZih2YWwgPT09IHVuZGVmaW5lZCAmJiBpc09iamVjdCh0YXJnZXRWYWwpKXtcbiAgICAgICAgbWVyZ2VkW2tleV0gPSB0aGlzLmNsb25lTWVyZ2UodGFyZ2V0VmFsLCB7fSwgcHJ1bmVNYWdpY0lkKVxuICAgICAgfVxuICAgIH1cbiAgICBpZihwcnVuZU1hZ2ljSWQpe1xuICAgICAgZGVsZXRlIG1lcmdlZC5tYWdpY0lkXG4gICAgICBkZWxldGUgbWVyZ2VkLm5ld1JlbmRlclxuICAgIH0gZWxzZSBpZih0YXJnZXRbUk9PVF0pe1xuICAgICAgbWVyZ2VkLm5ld1JlbmRlciA9IHRydWVcbiAgICB9XG4gICAgcmV0dXJuIG1lcmdlZFxuICB9XG5cbiAgY29tcG9uZW50VG9TdHJpbmcoY2lkKXtcbiAgICBsZXQgW3N0ciwgc3RyZWFtc10gPSB0aGlzLnJlY3Vyc2l2ZUNJRFRvU3RyaW5nKHRoaXMucmVuZGVyZWRbQ09NUE9ORU5UU10sIGNpZCwgbnVsbClcbiAgICBsZXQgW3N0cmlwcGVkSFRNTCwgX2JlZm9yZSwgX2FmdGVyXSA9IG1vZGlmeVJvb3Qoc3RyLCB7fSlcbiAgICByZXR1cm4gW3N0cmlwcGVkSFRNTCwgc3RyZWFtc11cbiAgfVxuXG4gIHBydW5lQ0lEcyhjaWRzKXtcbiAgICBjaWRzLmZvckVhY2goY2lkID0+IGRlbGV0ZSB0aGlzLnJlbmRlcmVkW0NPTVBPTkVOVFNdW2NpZF0pXG4gIH1cblxuICAvLyBwcml2YXRlXG5cbiAgZ2V0KCl7IHJldHVybiB0aGlzLnJlbmRlcmVkIH1cblxuICBpc05ld0ZpbmdlcnByaW50KGRpZmYgPSB7fSl7IHJldHVybiAhIWRpZmZbU1RBVElDXSB9XG5cbiAgdGVtcGxhdGVTdGF0aWMocGFydCwgdGVtcGxhdGVzKXtcbiAgICBpZih0eXBlb2YgKHBhcnQpID09PSBcIm51bWJlclwiKSB7XG4gICAgICByZXR1cm4gdGVtcGxhdGVzW3BhcnRdXG4gICAgfSBlbHNlIHtcbiAgICAgIHJldHVybiBwYXJ0XG4gICAgfVxuICB9XG5cbiAgbmV4dE1hZ2ljSUQoKXtcbiAgICB0aGlzLm1hZ2ljSWQrK1xuICAgIHJldHVybiBgbSR7dGhpcy5tYWdpY0lkfS0ke3RoaXMucGFyZW50Vmlld0lkKCl9YFxuICB9XG5cbiAgLy8gQ29udmVydHMgcmVuZGVyZWQgdHJlZSB0byBvdXRwdXQgYnVmZmVyLlxuICAvL1xuICAvLyBjaGFuZ2VUcmFja2luZyBjb250cm9scyBpZiB3ZSBjYW4gYXBwbHkgdGhlIFBIWF9TS0lQIG9wdGltaXphdGlvbi5cbiAgLy8gSXQgaXMgZGlzYWJsZWQgZm9yIGNvbXByZWhlbnNpb25zIHNpbmNlIHdlIG11c3QgcmUtcmVuZGVyIHRoZSBlbnRpcmUgY29sbGVjdGlvblxuICAvLyBhbmQgbm8gaW5kaXZpZHVhbCBlbGVtZW50IGlzIHRyYWNrZWQgaW5zaWRlIHRoZSBjb21wcmVoZW5zaW9uLlxuICB0b091dHB1dEJ1ZmZlcihyZW5kZXJlZCwgdGVtcGxhdGVzLCBvdXRwdXQsIGNoYW5nZVRyYWNraW5nLCByb290QXR0cnMgPSB7fSl7XG4gICAgaWYocmVuZGVyZWRbRFlOQU1JQ1NdKXsgcmV0dXJuIHRoaXMuY29tcHJlaGVuc2lvblRvQnVmZmVyKHJlbmRlcmVkLCB0ZW1wbGF0ZXMsIG91dHB1dCkgfVxuICAgIGxldCB7W1NUQVRJQ106IHN0YXRpY3N9ID0gcmVuZGVyZWRcbiAgICBzdGF0aWNzID0gdGhpcy50ZW1wbGF0ZVN0YXRpYyhzdGF0aWNzLCB0ZW1wbGF0ZXMpXG4gICAgbGV0IGlzUm9vdCA9IHJlbmRlcmVkW1JPT1RdXG4gICAgbGV0IHByZXZCdWZmZXIgPSBvdXRwdXQuYnVmZmVyXG4gICAgaWYoaXNSb290KXsgb3V0cHV0LmJ1ZmZlciA9IFwiXCIgfVxuXG4gICAgLy8gdGhpcyBjb25kaXRpb24gaXMgY2FsbGVkIHdoZW4gZmlyc3QgcmVuZGVyaW5nIGFuIG9wdGltaXphYmxlIGZ1bmN0aW9uIGNvbXBvbmVudC5cbiAgICAvLyBMQyBoYXZlIHRoZWlyIG1hZ2ljSWQgcHJldmlvdXNseSBzZXRcbiAgICBpZihjaGFuZ2VUcmFja2luZyAmJiBpc1Jvb3QgJiYgIXJlbmRlcmVkLm1hZ2ljSWQpe1xuICAgICAgcmVuZGVyZWQubmV3UmVuZGVyID0gdHJ1ZVxuICAgICAgcmVuZGVyZWQubWFnaWNJZCA9IHRoaXMubmV4dE1hZ2ljSUQoKVxuICAgIH1cblxuICAgIG91dHB1dC5idWZmZXIgKz0gc3RhdGljc1swXVxuICAgIGZvcihsZXQgaSA9IDE7IGkgPCBzdGF0aWNzLmxlbmd0aDsgaSsrKXtcbiAgICAgIHRoaXMuZHluYW1pY1RvQnVmZmVyKHJlbmRlcmVkW2kgLSAxXSwgdGVtcGxhdGVzLCBvdXRwdXQsIGNoYW5nZVRyYWNraW5nKVxuICAgICAgb3V0cHV0LmJ1ZmZlciArPSBzdGF0aWNzW2ldXG4gICAgfVxuXG4gICAgLy8gQXBwbGllcyB0aGUgcm9vdCB0YWcgXCJza2lwXCIgb3B0aW1pemF0aW9uIGlmIHN1cHBvcnRlZCwgd2hpY2ggY2xlYXJzXG4gICAgLy8gdGhlIHJvb3QgdGFnIGF0dHJpYnV0ZXMgYW5kIGlubmVySFRNTCwgYW5kIG9ubHkgbWFpbnRhaW5zIHRoZSBtYWdpY0lkLlxuICAgIC8vIFdlIGNhbiBvbmx5IHNraXAgd2hlbiBjaGFuZ2VUcmFja2luZyBpcyBzdXBwb3J0ZWQgKG91dHNpZGUgb2YgYSBjb21wcmVoZW5zaW9uKSxcbiAgICAvLyBhbmQgd2hlbiB0aGUgcm9vdCBlbGVtZW50IGhhc24ndCBleHBlcmllbmNlZCBhbiB1bnJlbmRlcmVkIG1lcmdlIChuZXdSZW5kZXIgdHJ1ZSkuXG4gICAgaWYoaXNSb290KXtcbiAgICAgIGxldCBza2lwID0gZmFsc2VcbiAgICAgIGxldCBhdHRyc1xuICAgICAgLy8gV2hlbiBhIExDIGlzIHJlLWFkZGVkIHRvIHRoZSBwYWdlLCB3ZSBuZWVkIHRvIHJlLXJlbmRlciB0aGUgZW50aXJlIExDIHRyZWUsXG4gICAgICAvLyB0aGVyZWZvcmUgY2hhbmdlVHJhY2tpbmcgaXMgZmFsc2U7IGhvd2V2ZXIsIHdlIG5lZWQgdG8ga2VlcCBhbGwgdGhlIG1hZ2ljSWRzXG4gICAgICAvLyBmcm9tIGFueSBmdW5jdGlvbiBjb21wb25lbnQgc28gdGhlIG5leHQgdGltZSB0aGUgTEMgaXMgdXBkYXRlZCwgd2UgY2FuIGFwcGx5XG4gICAgICAvLyB0aGUgc2tpcCBvcHRpbWl6YXRpb25cbiAgICAgIGlmKGNoYW5nZVRyYWNraW5nIHx8IHJlbmRlcmVkLm1hZ2ljSWQpe1xuICAgICAgICBza2lwID0gY2hhbmdlVHJhY2tpbmcgJiYgIXJlbmRlcmVkLm5ld1JlbmRlclxuICAgICAgICBhdHRycyA9IHtbUEhYX01BR0lDX0lEXTogcmVuZGVyZWQubWFnaWNJZCwgLi4ucm9vdEF0dHJzfVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgYXR0cnMgPSByb290QXR0cnNcbiAgICAgIH1cbiAgICAgIGlmKHNraXApeyBhdHRyc1tQSFhfU0tJUF0gPSB0cnVlIH1cbiAgICAgIGxldCBbbmV3Um9vdCwgY29tbWVudEJlZm9yZSwgY29tbWVudEFmdGVyXSA9IG1vZGlmeVJvb3Qob3V0cHV0LmJ1ZmZlciwgYXR0cnMsIHNraXApXG4gICAgICByZW5kZXJlZC5uZXdSZW5kZXIgPSBmYWxzZVxuICAgICAgb3V0cHV0LmJ1ZmZlciA9IHByZXZCdWZmZXIgKyBjb21tZW50QmVmb3JlICsgbmV3Um9vdCArIGNvbW1lbnRBZnRlclxuICAgIH1cbiAgfVxuXG4gIGNvbXByZWhlbnNpb25Ub0J1ZmZlcihyZW5kZXJlZCwgdGVtcGxhdGVzLCBvdXRwdXQpe1xuICAgIGxldCB7W0RZTkFNSUNTXTogZHluYW1pY3MsIFtTVEFUSUNdOiBzdGF0aWNzLCBbU1RSRUFNXTogc3RyZWFtfSA9IHJlbmRlcmVkXG4gICAgbGV0IFtfcmVmLCBfaW5zZXJ0cywgZGVsZXRlSWRzLCByZXNldF0gPSBzdHJlYW0gfHwgW251bGwsIHt9LCBbXSwgbnVsbF1cbiAgICBzdGF0aWNzID0gdGhpcy50ZW1wbGF0ZVN0YXRpYyhzdGF0aWNzLCB0ZW1wbGF0ZXMpXG4gICAgbGV0IGNvbXBUZW1wbGF0ZXMgPSB0ZW1wbGF0ZXMgfHwgcmVuZGVyZWRbVEVNUExBVEVTXVxuICAgIGZvcihsZXQgZCA9IDA7IGQgPCBkeW5hbWljcy5sZW5ndGg7IGQrKyl7XG4gICAgICBsZXQgZHluYW1pYyA9IGR5bmFtaWNzW2RdXG4gICAgICBvdXRwdXQuYnVmZmVyICs9IHN0YXRpY3NbMF1cbiAgICAgIGZvcihsZXQgaSA9IDE7IGkgPCBzdGF0aWNzLmxlbmd0aDsgaSsrKXtcbiAgICAgICAgLy8gSW5zaWRlIGEgY29tcHJlaGVuc2lvbiwgd2UgZG9uJ3QgdHJhY2sgaG93IGR5bmFtaWNzIGNoYW5nZVxuICAgICAgICAvLyBvdmVyIHRpbWUgKGFuZCBmZWF0dXJlcyBsaWtlIHN0cmVhbXMgd291bGQgbWFrZSB0aGF0IGltcG9zc2libGVcbiAgICAgICAgLy8gdW5sZXNzIHdlIG1vdmUgdGhlIHN0cmVhbSBkaWZmaW5nIGF3YXkgZnJvbSBtb3JwaGRvbSksXG4gICAgICAgIC8vIHNvIHdlIGNhbid0IHBlcmZvcm0gcm9vdCBjaGFuZ2UgdHJhY2tpbmcuXG4gICAgICAgIGxldCBjaGFuZ2VUcmFja2luZyA9IGZhbHNlXG4gICAgICAgIHRoaXMuZHluYW1pY1RvQnVmZmVyKGR5bmFtaWNbaSAtIDFdLCBjb21wVGVtcGxhdGVzLCBvdXRwdXQsIGNoYW5nZVRyYWNraW5nKVxuICAgICAgICBvdXRwdXQuYnVmZmVyICs9IHN0YXRpY3NbaV1cbiAgICAgIH1cbiAgICB9XG5cbiAgICBpZihzdHJlYW0gIT09IHVuZGVmaW5lZCAmJiAocmVuZGVyZWRbRFlOQU1JQ1NdLmxlbmd0aCA+IDAgfHwgZGVsZXRlSWRzLmxlbmd0aCA+IDAgfHwgcmVzZXQpKXtcbiAgICAgIGRlbGV0ZSByZW5kZXJlZFtTVFJFQU1dXG4gICAgICByZW5kZXJlZFtEWU5BTUlDU10gPSBbXVxuICAgICAgb3V0cHV0LnN0cmVhbXMuYWRkKHN0cmVhbSlcbiAgICB9XG4gIH1cblxuICBkeW5hbWljVG9CdWZmZXIocmVuZGVyZWQsIHRlbXBsYXRlcywgb3V0cHV0LCBjaGFuZ2VUcmFja2luZyl7XG4gICAgaWYodHlwZW9mIChyZW5kZXJlZCkgPT09IFwibnVtYmVyXCIpe1xuICAgICAgbGV0IFtzdHIsIHN0cmVhbXNdID0gdGhpcy5yZWN1cnNpdmVDSURUb1N0cmluZyhvdXRwdXQuY29tcG9uZW50cywgcmVuZGVyZWQsIG91dHB1dC5vbmx5Q2lkcylcbiAgICAgIG91dHB1dC5idWZmZXIgKz0gc3RyXG4gICAgICBvdXRwdXQuc3RyZWFtcyA9IG5ldyBTZXQoWy4uLm91dHB1dC5zdHJlYW1zLCAuLi5zdHJlYW1zXSlcbiAgICB9IGVsc2UgaWYoaXNPYmplY3QocmVuZGVyZWQpKXtcbiAgICAgIHRoaXMudG9PdXRwdXRCdWZmZXIocmVuZGVyZWQsIHRlbXBsYXRlcywgb3V0cHV0LCBjaGFuZ2VUcmFja2luZywge30pXG4gICAgfSBlbHNlIHtcbiAgICAgIG91dHB1dC5idWZmZXIgKz0gcmVuZGVyZWRcbiAgICB9XG4gIH1cblxuICByZWN1cnNpdmVDSURUb1N0cmluZyhjb21wb25lbnRzLCBjaWQsIG9ubHlDaWRzKXtcbiAgICBsZXQgY29tcG9uZW50ID0gY29tcG9uZW50c1tjaWRdIHx8IGxvZ0Vycm9yKGBubyBjb21wb25lbnQgZm9yIENJRCAke2NpZH1gLCBjb21wb25lbnRzKVxuICAgIGxldCBhdHRycyA9IHtbUEhYX0NPTVBPTkVOVF06IGNpZH1cbiAgICBsZXQgc2tpcCA9IG9ubHlDaWRzICYmICFvbmx5Q2lkcy5oYXMoY2lkKVxuICAgIC8vIFR3byBvcHRpbWl6YXRpb24gcGF0aHMgYXBwbHkgaGVyZTpcbiAgICAvL1xuICAgIC8vICAgMS4gVGhlIG9ubHlDaWRzIG9wdGltaXphdGlvbiB3b3JrcyBieSB0aGUgc2VydmVyIGRpZmYgdGVsbGluZyB1cyBvbmx5IHNwZWNpZmljXG4gICAgLy8gICAgIGNpZCdzIGhhdmUgY2hhbmdlZC4gVGhpcyBhbGxvd3MgdXMgdG8gc2tpcCByZW5kZXJpbmcgYW55IGNvbXBvbmVudCB0aGF0IGhhc24ndCBjaGFuZ2VkLFxuICAgIC8vICAgICB3aGljaCB1bHRpbWF0ZWx5IHNldHMgUEhYX1NLSVAgcm9vdCBhdHRyaWJ1dGUgYW5kIGF2b2lkcyByZW5kZXJpbmcgdGhlIGlubmVySFRNTC5cbiAgICAvL1xuICAgIC8vICAgMi4gVGhlIHJvb3QgUEhYX1NLSVAgb3B0aW1pemF0aW9uIGdlbmVyYWxpemVzIHRvIGFsbCBIRUV4IGZ1bmN0aW9uIGNvbXBvbmVudHMsIGFuZFxuICAgIC8vICAgICB3b3JrcyBpbiB0aGUgc2FtZSBQSFhfU0tJUCBhdHRyaWJ1dGUgZmFzaGlvbiBhcyAxLCBidXQgdGhlIG5ld1JlbmRlciB0cmFja2luZyBpcyBkb25lXG4gICAgLy8gICAgIGF0IHRoZSBnZW5lcmFsIGRpZmYgbWVyZ2UgbGV2ZWwuIElmIHdlIG1lcmdlIGEgZGlmZiB3aXRoIG5ldyBkeW5hbWljcywgd2UgbmVjZXNzYXJpbHkgaGF2ZVxuICAgIC8vICAgICBleHBlcmllbmNlZCBhIGNoYW5nZSB3aGljaCBtdXN0IGJlIGEgbmV3UmVuZGVyLCBhbmQgdGh1cyB3ZSBjYW4ndCBza2lwIHRoZSByZW5kZXIuXG4gICAgLy9cbiAgICAvLyBCb3RoIG9wdGltaXphdGlvbiBmbG93cyBhcHBseSBoZXJlLiBuZXdSZW5kZXIgaXMgc2V0IGJhc2VkIG9uIHRoZSBvbmx5Q2lkcyBvcHRpbWl6YXRpb24sIGFuZFxuICAgIC8vIHdlIHRyYWNrIGEgZGV0ZXJtaW5pc3RpYyBtYWdpY0lkIGJhc2VkIG9uIHRoZSBjaWQuXG4gICAgLy9cbiAgICAvLyBjaGFuZ2VUcmFja2luZyBpcyBhYm91dCB0aGUgZW50aXJlIHRyZWVcbiAgICAvLyBuZXdSZW5kZXIgaXMgYWJvdXQgdGhlIGN1cnJlbnQgcm9vdCBpbiB0aGUgdHJlZVxuICAgIC8vXG4gICAgLy8gQnkgZGVmYXVsdCBjaGFuZ2VUcmFja2luZyBpcyBlbmFibGVkLCBidXQgd2Ugc3BlY2lhbCBjYXNlIHRoZSBmbG93IHdoZXJlIHRoZSBjbGllbnQgaXMgcHJ1bmluZ1xuICAgIC8vIGNpZHMgYW5kIHRoZSBzZXJ2ZXIgYWRkcyB0aGUgY29tcG9uZW50IGJhY2suIEluIHN1Y2ggY2FzZXMsIHdlIGV4cGxpY2l0bHkgZGlzYWJsZSBjaGFuZ2VUcmFja2luZ1xuICAgIC8vIHdpdGggcmVzZXRSZW5kZXIgZm9yIHRoaXMgY2lkLCB0aGVuIHJlLWVuYWJsZSBpdCBhZnRlciB0aGUgcmVjdXJzaXZlIGNhbGwgdG8gc2tpcCB0aGUgb3B0aW1pemF0aW9uXG4gICAgLy8gZm9yIHRoZSBlbnRpcmUgY29tcG9uZW50IHRyZWUuXG4gICAgY29tcG9uZW50Lm5ld1JlbmRlciA9ICFza2lwXG4gICAgY29tcG9uZW50Lm1hZ2ljSWQgPSBgYyR7Y2lkfS0ke3RoaXMucGFyZW50Vmlld0lkKCl9YFxuICAgIC8vIGVuYWJsZSBjaGFuZ2UgdHJhY2tpbmcgYXMgbG9uZyBhcyB0aGUgY29tcG9uZW50IGhhc24ndCBiZWVuIHJlc2V0XG4gICAgbGV0IGNoYW5nZVRyYWNraW5nID0gIWNvbXBvbmVudC5yZXNldFxuICAgIGxldCBbaHRtbCwgc3RyZWFtc10gPSB0aGlzLnJlY3Vyc2l2ZVRvU3RyaW5nKGNvbXBvbmVudCwgY29tcG9uZW50cywgb25seUNpZHMsIGNoYW5nZVRyYWNraW5nLCBhdHRycylcbiAgICAvLyBkaXNhYmxlIHJlc2V0IGFmdGVyIHdlJ3ZlIHJlbmRlcmVkXG4gICAgZGVsZXRlIGNvbXBvbmVudC5yZXNldFxuXG4gICAgcmV0dXJuIFtodG1sLCBzdHJlYW1zXVxuICB9XG59XG4iLCAibGV0IHZpZXdIb29rSUQgPSAxXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBWaWV3SG9vayB7XG4gIHN0YXRpYyBtYWtlSUQoKXsgcmV0dXJuIHZpZXdIb29rSUQrKyB9XG4gIHN0YXRpYyBlbGVtZW50SUQoZWwpeyByZXR1cm4gZWwucGh4SG9va0lkIH1cblxuICBjb25zdHJ1Y3Rvcih2aWV3LCBlbCwgY2FsbGJhY2tzKXtcbiAgICB0aGlzLl9fdmlldyA9IHZpZXdcbiAgICB0aGlzLmxpdmVTb2NrZXQgPSB2aWV3LmxpdmVTb2NrZXRcbiAgICB0aGlzLl9fY2FsbGJhY2tzID0gY2FsbGJhY2tzXG4gICAgdGhpcy5fX2xpc3RlbmVycyA9IG5ldyBTZXQoKVxuICAgIHRoaXMuX19pc0Rpc2Nvbm5lY3RlZCA9IGZhbHNlXG4gICAgdGhpcy5lbCA9IGVsXG4gICAgdGhpcy5lbC5waHhIb29rSWQgPSB0aGlzLmNvbnN0cnVjdG9yLm1ha2VJRCgpXG4gICAgZm9yKGxldCBrZXkgaW4gdGhpcy5fX2NhbGxiYWNrcyl7IHRoaXNba2V5XSA9IHRoaXMuX19jYWxsYmFja3Nba2V5XSB9XG4gIH1cblxuICBfX21vdW50ZWQoKXsgdGhpcy5tb3VudGVkICYmIHRoaXMubW91bnRlZCgpIH1cbiAgX191cGRhdGVkKCl7IHRoaXMudXBkYXRlZCAmJiB0aGlzLnVwZGF0ZWQoKSB9XG4gIF9fYmVmb3JlVXBkYXRlKCl7IHRoaXMuYmVmb3JlVXBkYXRlICYmIHRoaXMuYmVmb3JlVXBkYXRlKCkgfVxuICBfX2Rlc3Ryb3llZCgpeyB0aGlzLmRlc3Ryb3llZCAmJiB0aGlzLmRlc3Ryb3llZCgpIH1cbiAgX19yZWNvbm5lY3RlZCgpe1xuICAgIGlmKHRoaXMuX19pc0Rpc2Nvbm5lY3RlZCl7XG4gICAgICB0aGlzLl9faXNEaXNjb25uZWN0ZWQgPSBmYWxzZVxuICAgICAgdGhpcy5yZWNvbm5lY3RlZCAmJiB0aGlzLnJlY29ubmVjdGVkKClcbiAgICB9XG4gIH1cbiAgX19kaXNjb25uZWN0ZWQoKXtcbiAgICB0aGlzLl9faXNEaXNjb25uZWN0ZWQgPSB0cnVlXG4gICAgdGhpcy5kaXNjb25uZWN0ZWQgJiYgdGhpcy5kaXNjb25uZWN0ZWQoKVxuICB9XG5cbiAgcHVzaEV2ZW50KGV2ZW50LCBwYXlsb2FkID0ge30sIG9uUmVwbHkgPSBmdW5jdGlvbiAoKXsgfSl7XG4gICAgcmV0dXJuIHRoaXMuX192aWV3LnB1c2hIb29rRXZlbnQodGhpcy5lbCwgbnVsbCwgZXZlbnQsIHBheWxvYWQsIG9uUmVwbHkpXG4gIH1cblxuICBwdXNoRXZlbnRUbyhwaHhUYXJnZXQsIGV2ZW50LCBwYXlsb2FkID0ge30sIG9uUmVwbHkgPSBmdW5jdGlvbiAoKXsgfSl7XG4gICAgcmV0dXJuIHRoaXMuX192aWV3LndpdGhpblRhcmdldHMocGh4VGFyZ2V0LCAodmlldywgdGFyZ2V0Q3R4KSA9PiB7XG4gICAgICByZXR1cm4gdmlldy5wdXNoSG9va0V2ZW50KHRoaXMuZWwsIHRhcmdldEN0eCwgZXZlbnQsIHBheWxvYWQsIG9uUmVwbHkpXG4gICAgfSlcbiAgfVxuXG4gIGhhbmRsZUV2ZW50KGV2ZW50LCBjYWxsYmFjayl7XG4gICAgbGV0IGNhbGxiYWNrUmVmID0gKGN1c3RvbUV2ZW50LCBieXBhc3MpID0+IGJ5cGFzcyA/IGV2ZW50IDogY2FsbGJhY2soY3VzdG9tRXZlbnQuZGV0YWlsKVxuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKGBwaHg6JHtldmVudH1gLCBjYWxsYmFja1JlZilcbiAgICB0aGlzLl9fbGlzdGVuZXJzLmFkZChjYWxsYmFja1JlZilcbiAgICByZXR1cm4gY2FsbGJhY2tSZWZcbiAgfVxuXG4gIHJlbW92ZUhhbmRsZUV2ZW50KGNhbGxiYWNrUmVmKXtcbiAgICBsZXQgZXZlbnQgPSBjYWxsYmFja1JlZihudWxsLCB0cnVlKVxuICAgIHdpbmRvdy5yZW1vdmVFdmVudExpc3RlbmVyKGBwaHg6JHtldmVudH1gLCBjYWxsYmFja1JlZilcbiAgICB0aGlzLl9fbGlzdGVuZXJzLmRlbGV0ZShjYWxsYmFja1JlZilcbiAgfVxuXG4gIHVwbG9hZChuYW1lLCBmaWxlcyl7XG4gICAgcmV0dXJuIHRoaXMuX192aWV3LmRpc3BhdGNoVXBsb2FkcyhudWxsLCBuYW1lLCBmaWxlcylcbiAgfVxuXG4gIHVwbG9hZFRvKHBoeFRhcmdldCwgbmFtZSwgZmlsZXMpe1xuICAgIHJldHVybiB0aGlzLl9fdmlldy53aXRoaW5UYXJnZXRzKHBoeFRhcmdldCwgKHZpZXcsIHRhcmdldEN0eCkgPT4ge1xuICAgICAgdmlldy5kaXNwYXRjaFVwbG9hZHModGFyZ2V0Q3R4LCBuYW1lLCBmaWxlcylcbiAgICB9KVxuICB9XG5cbiAgX19jbGVhbnVwX18oKXtcbiAgICB0aGlzLl9fbGlzdGVuZXJzLmZvckVhY2goY2FsbGJhY2tSZWYgPT4gdGhpcy5yZW1vdmVIYW5kbGVFdmVudChjYWxsYmFja1JlZikpXG4gIH1cbn1cbiIsICJpbXBvcnQge1xuICBCRUZPUkVfVU5MT0FEX0xPQURFUl9USU1FT1VULFxuICBDSEVDS0FCTEVfSU5QVVRTLFxuICBDT05TRUNVVElWRV9SRUxPQURTLFxuICBQSFhfQVVUT19SRUNPVkVSLFxuICBQSFhfQ09NUE9ORU5ULFxuICBQSFhfQ09OTkVDVEVEX0NMQVNTLFxuICBQSFhfRElTQUJMRV9XSVRILFxuICBQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUsXG4gIFBIWF9ESVNBQkxFRCxcbiAgUEhYX0xPQURJTkdfQ0xBU1MsXG4gIFBIWF9FVkVOVF9DTEFTU0VTLFxuICBQSFhfRVJST1JfQ0xBU1MsXG4gIFBIWF9DTElFTlRfRVJST1JfQ0xBU1MsXG4gIFBIWF9TRVJWRVJfRVJST1JfQ0xBU1MsXG4gIFBIWF9GRUVEQkFDS19GT1IsXG4gIFBIWF9GRUVEQkFDS19HUk9VUCxcbiAgUEhYX0hBU19GT0NVU0VELFxuICBQSFhfSEFTX1NVQk1JVFRFRCxcbiAgUEhYX0hPT0ssXG4gIFBIWF9QQUdFX0xPQURJTkcsXG4gIFBIWF9QQVJFTlRfSUQsXG4gIFBIWF9QUk9HUkVTUyxcbiAgUEhYX1JFQURPTkxZLFxuICBQSFhfUkVGLFxuICBQSFhfUkVGX1NSQyxcbiAgUEhYX1JPT1RfSUQsXG4gIFBIWF9TRVNTSU9OLFxuICBQSFhfU1RBVElDLFxuICBQSFhfVFJBQ0tfU1RBVElDLFxuICBQSFhfVFJBQ0tfVVBMT0FEUyxcbiAgUEhYX1VQREFURSxcbiAgUEhYX1VQTE9BRF9SRUYsXG4gIFBIWF9WSUVXX1NFTEVDVE9SLFxuICBQSFhfTUFJTixcbiAgUEhYX01PVU5URUQsXG4gIFBVU0hfVElNRU9VVCxcbiAgUEhYX1ZJRVdQT1JUX1RPUCxcbiAgUEhYX1ZJRVdQT1JUX0JPVFRPTSxcbn0gZnJvbSBcIi4vY29uc3RhbnRzXCJcblxuaW1wb3J0IHtcbiAgY2xvbmUsXG4gIGNsb3Nlc3RQaHhCaW5kaW5nLFxuICBpc0VtcHR5LFxuICBpc0VxdWFsT2JqLFxuICBsb2dFcnJvcixcbiAgbWF5YmUsXG4gIGlzQ2lkLFxufSBmcm9tIFwiLi91dGlsc1wiXG5cbmltcG9ydCBCcm93c2VyIGZyb20gXCIuL2Jyb3dzZXJcIlxuaW1wb3J0IERPTSBmcm9tIFwiLi9kb21cIlxuaW1wb3J0IERPTVBhdGNoIGZyb20gXCIuL2RvbV9wYXRjaFwiXG5pbXBvcnQgTGl2ZVVwbG9hZGVyIGZyb20gXCIuL2xpdmVfdXBsb2FkZXJcIlxuaW1wb3J0IFJlbmRlcmVkIGZyb20gXCIuL3JlbmRlcmVkXCJcbmltcG9ydCBWaWV3SG9vayBmcm9tIFwiLi92aWV3X2hvb2tcIlxuaW1wb3J0IEpTIGZyb20gXCIuL2pzXCJcblxubGV0IHNlcmlhbGl6ZUZvcm0gPSAoZm9ybSwgbWV0YWRhdGEsIG9ubHlOYW1lcyA9IFtdKSA9PiB7XG4gIGNvbnN0IHtzdWJtaXR0ZXIsIC4uLm1ldGF9ID0gbWV0YWRhdGFcblxuICAvLyBXZSBtdXN0IGluamVjdCB0aGUgc3VibWl0dGVyIGluIHRoZSBvcmRlciB0aGF0IGl0IGV4aXN0cyBpbiB0aGUgRE9NXG4gIC8vIHJlbGVhdGl2ZSB0byBvdGhlciBpbnB1dHMuIEZvciBleGFtcGxlLCBmb3IgY2hlY2tib3ggZ3JvdXBzLCB0aGUgb3JkZXIgbXVzdCBiZSBtYWludGFpbmVkLlxuICBsZXQgaW5qZWN0ZWRFbGVtZW50XG4gIGlmKHN1Ym1pdHRlciAmJiBzdWJtaXR0ZXIubmFtZSl7XG4gICAgY29uc3QgaW5wdXQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwiaW5wdXRcIilcbiAgICBpbnB1dC50eXBlID0gXCJoaWRkZW5cIlxuICAgIC8vIHNldCB0aGUgZm9ybSBhdHRyaWJ1dGUgaWYgdGhlIHN1Ym1pdHRlciBoYXMgb25lO1xuICAgIC8vIHRoaXMgY2FuIGhhcHBlbiBpZiB0aGUgZWxlbWVudCBpcyBvdXRzaWRlIHRoZSBhY3R1YWwgZm9ybSBlbGVtZW50XG4gICAgY29uc3QgZm9ybUlkID0gc3VibWl0dGVyLmdldEF0dHJpYnV0ZShcImZvcm1cIilcbiAgICBpZihmb3JtSWQpe1xuICAgICAgaW5wdXQuc2V0QXR0cmlidXRlKFwiZm9ybVwiLCBmb3JtSWQpXG4gICAgfVxuICAgIGlucHV0Lm5hbWUgPSBzdWJtaXR0ZXIubmFtZVxuICAgIGlucHV0LnZhbHVlID0gc3VibWl0dGVyLnZhbHVlXG4gICAgc3VibWl0dGVyLnBhcmVudEVsZW1lbnQuaW5zZXJ0QmVmb3JlKGlucHV0LCBzdWJtaXR0ZXIpXG4gICAgaW5qZWN0ZWRFbGVtZW50ID0gaW5wdXRcbiAgfVxuXG4gIGNvbnN0IGZvcm1EYXRhID0gbmV3IEZvcm1EYXRhKGZvcm0pXG4gIGNvbnN0IHRvUmVtb3ZlID0gW11cblxuICBmb3JtRGF0YS5mb3JFYWNoKCh2YWwsIGtleSwgX2luZGV4KSA9PiB7XG4gICAgaWYodmFsIGluc3RhbmNlb2YgRmlsZSl7IHRvUmVtb3ZlLnB1c2goa2V5KSB9XG4gIH0pXG5cbiAgLy8gQ2xlYW51cCBhZnRlciBidWlsZGluZyBmaWxlRGF0YVxuICB0b1JlbW92ZS5mb3JFYWNoKGtleSA9PiBmb3JtRGF0YS5kZWxldGUoa2V5KSlcblxuICBjb25zdCBwYXJhbXMgPSBuZXcgVVJMU2VhcmNoUGFyYW1zKClcblxuICBmb3IobGV0IFtrZXksIHZhbF0gb2YgZm9ybURhdGEuZW50cmllcygpKXtcbiAgICBpZihvbmx5TmFtZXMubGVuZ3RoID09PSAwIHx8IG9ubHlOYW1lcy5pbmRleE9mKGtleSkgPj0gMCl7XG4gICAgICBwYXJhbXMuYXBwZW5kKGtleSwgdmFsKVxuICAgIH1cbiAgfVxuXG4gIC8vIHJlbW92ZSB0aGUgaW5qZWN0ZWQgZWxlbWVudCBhZ2FpblxuICAvLyAoaXQgd291bGQgYmUgcmVtb3ZlZCBieSB0aGUgbmV4dCBkb20gcGF0Y2ggYW55d2F5LCBidXQgdGhpcyBpcyBjbGVhbmVyKVxuICBpZihzdWJtaXR0ZXIgJiYgaW5qZWN0ZWRFbGVtZW50KXtcbiAgICBzdWJtaXR0ZXIucGFyZW50RWxlbWVudC5yZW1vdmVDaGlsZChpbmplY3RlZEVsZW1lbnQpXG4gIH1cblxuICBmb3IobGV0IG1ldGFLZXkgaW4gbWV0YSl7IHBhcmFtcy5hcHBlbmQobWV0YUtleSwgbWV0YVttZXRhS2V5XSkgfVxuXG4gIHJldHVybiBwYXJhbXMudG9TdHJpbmcoKVxufVxuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBWaWV3IHtcbiAgY29uc3RydWN0b3IoZWwsIGxpdmVTb2NrZXQsIHBhcmVudFZpZXcsIGZsYXNoLCBsaXZlUmVmZXJlcil7XG4gICAgdGhpcy5pc0RlYWQgPSBmYWxzZVxuICAgIHRoaXMubGl2ZVNvY2tldCA9IGxpdmVTb2NrZXRcbiAgICB0aGlzLmZsYXNoID0gZmxhc2hcbiAgICB0aGlzLnBhcmVudCA9IHBhcmVudFZpZXdcbiAgICB0aGlzLnJvb3QgPSBwYXJlbnRWaWV3ID8gcGFyZW50Vmlldy5yb290IDogdGhpc1xuICAgIHRoaXMuZWwgPSBlbFxuICAgIHRoaXMuaWQgPSB0aGlzLmVsLmlkXG4gICAgdGhpcy5yZWYgPSAwXG4gICAgdGhpcy5jaGlsZEpvaW5zID0gMFxuICAgIHRoaXMubG9hZGVyVGltZXIgPSBudWxsXG4gICAgdGhpcy5wZW5kaW5nRGlmZnMgPSBbXVxuICAgIHRoaXMucGVuZGluZ0Zvcm1zID0gbmV3IFNldCgpXG4gICAgdGhpcy5yZWRpcmVjdCA9IGZhbHNlXG4gICAgdGhpcy5ocmVmID0gbnVsbFxuICAgIHRoaXMuam9pbkNvdW50ID0gdGhpcy5wYXJlbnQgPyB0aGlzLnBhcmVudC5qb2luQ291bnQgLSAxIDogMFxuICAgIHRoaXMuam9pblBlbmRpbmcgPSB0cnVlXG4gICAgdGhpcy5kZXN0cm95ZWQgPSBmYWxzZVxuICAgIHRoaXMuam9pbkNhbGxiYWNrID0gZnVuY3Rpb24ob25Eb25lKXsgb25Eb25lICYmIG9uRG9uZSgpIH1cbiAgICB0aGlzLnN0b3BDYWxsYmFjayA9IGZ1bmN0aW9uKCl7IH1cbiAgICB0aGlzLnBlbmRpbmdKb2luT3BzID0gdGhpcy5wYXJlbnQgPyBudWxsIDogW11cbiAgICB0aGlzLnZpZXdIb29rcyA9IHt9XG4gICAgdGhpcy5mb3JtU3VibWl0cyA9IFtdXG4gICAgdGhpcy5jaGlsZHJlbiA9IHRoaXMucGFyZW50ID8gbnVsbCA6IHt9XG4gICAgdGhpcy5yb290LmNoaWxkcmVuW3RoaXMuaWRdID0ge31cbiAgICB0aGlzLmZvcm1zRm9yUmVjb3ZlcnkgPSB7fVxuICAgIHRoaXMuY2hhbm5lbCA9IHRoaXMubGl2ZVNvY2tldC5jaGFubmVsKGBsdjoke3RoaXMuaWR9YCwgKCkgPT4ge1xuICAgICAgbGV0IHVybCA9IHRoaXMuaHJlZiAmJiB0aGlzLmV4cGFuZFVSTCh0aGlzLmhyZWYpXG4gICAgICByZXR1cm4ge1xuICAgICAgICByZWRpcmVjdDogdGhpcy5yZWRpcmVjdCA/IHVybCA6IHVuZGVmaW5lZCxcbiAgICAgICAgdXJsOiB0aGlzLnJlZGlyZWN0ID8gdW5kZWZpbmVkIDogdXJsIHx8IHVuZGVmaW5lZCxcbiAgICAgICAgcGFyYW1zOiB0aGlzLmNvbm5lY3RQYXJhbXMobGl2ZVJlZmVyZXIpLFxuICAgICAgICBzZXNzaW9uOiB0aGlzLmdldFNlc3Npb24oKSxcbiAgICAgICAgc3RhdGljOiB0aGlzLmdldFN0YXRpYygpLFxuICAgICAgICBmbGFzaDogdGhpcy5mbGFzaCxcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgc2V0SHJlZihocmVmKXsgdGhpcy5ocmVmID0gaHJlZiB9XG5cbiAgc2V0UmVkaXJlY3QoaHJlZil7XG4gICAgdGhpcy5yZWRpcmVjdCA9IHRydWVcbiAgICB0aGlzLmhyZWYgPSBocmVmXG4gIH1cblxuICBpc01haW4oKXsgcmV0dXJuIHRoaXMuZWwuaGFzQXR0cmlidXRlKFBIWF9NQUlOKSB9XG5cbiAgY29ubmVjdFBhcmFtcyhsaXZlUmVmZXJlcil7XG4gICAgbGV0IHBhcmFtcyA9IHRoaXMubGl2ZVNvY2tldC5wYXJhbXModGhpcy5lbClcbiAgICBsZXQgbWFuaWZlc3QgPVxuICAgICAgRE9NLmFsbChkb2N1bWVudCwgYFske3RoaXMuYmluZGluZyhQSFhfVFJBQ0tfU1RBVElDKX1dYClcbiAgICAgICAgLm1hcChub2RlID0+IG5vZGUuc3JjIHx8IG5vZGUuaHJlZikuZmlsdGVyKHVybCA9PiB0eXBlb2YgKHVybCkgPT09IFwic3RyaW5nXCIpXG5cbiAgICBpZihtYW5pZmVzdC5sZW5ndGggPiAwKXsgcGFyYW1zW1wiX3RyYWNrX3N0YXRpY1wiXSA9IG1hbmlmZXN0IH1cbiAgICBwYXJhbXNbXCJfbW91bnRzXCJdID0gdGhpcy5qb2luQ291bnRcbiAgICBwYXJhbXNbXCJfbGl2ZV9yZWZlcmVyXCJdID0gbGl2ZVJlZmVyZXJcblxuICAgIHJldHVybiBwYXJhbXNcbiAgfVxuXG4gIGlzQ29ubmVjdGVkKCl7IHJldHVybiB0aGlzLmNoYW5uZWwuY2FuUHVzaCgpIH1cblxuICBnZXRTZXNzaW9uKCl7IHJldHVybiB0aGlzLmVsLmdldEF0dHJpYnV0ZShQSFhfU0VTU0lPTikgfVxuXG4gIGdldFN0YXRpYygpe1xuICAgIGxldCB2YWwgPSB0aGlzLmVsLmdldEF0dHJpYnV0ZShQSFhfU1RBVElDKVxuICAgIHJldHVybiB2YWwgPT09IFwiXCIgPyBudWxsIDogdmFsXG4gIH1cblxuICBkZXN0cm95KGNhbGxiYWNrID0gZnVuY3Rpb24gKCl7IH0pe1xuICAgIHRoaXMuZGVzdHJveUFsbENoaWxkcmVuKClcbiAgICB0aGlzLmRlc3Ryb3llZCA9IHRydWVcbiAgICBkZWxldGUgdGhpcy5yb290LmNoaWxkcmVuW3RoaXMuaWRdXG4gICAgaWYodGhpcy5wYXJlbnQpeyBkZWxldGUgdGhpcy5yb290LmNoaWxkcmVuW3RoaXMucGFyZW50LmlkXVt0aGlzLmlkXSB9XG4gICAgY2xlYXJUaW1lb3V0KHRoaXMubG9hZGVyVGltZXIpXG4gICAgbGV0IG9uRmluaXNoZWQgPSAoKSA9PiB7XG4gICAgICBjYWxsYmFjaygpXG4gICAgICBmb3IobGV0IGlkIGluIHRoaXMudmlld0hvb2tzKXtcbiAgICAgICAgdGhpcy5kZXN0cm95SG9vayh0aGlzLnZpZXdIb29rc1tpZF0pXG4gICAgICB9XG4gICAgfVxuXG4gICAgRE9NLm1hcmtQaHhDaGlsZERlc3Ryb3llZCh0aGlzLmVsKVxuXG4gICAgdGhpcy5sb2coXCJkZXN0cm95ZWRcIiwgKCkgPT4gW1widGhlIGNoaWxkIGhhcyBiZWVuIHJlbW92ZWQgZnJvbSB0aGUgcGFyZW50XCJdKVxuICAgIHRoaXMuY2hhbm5lbC5sZWF2ZSgpXG4gICAgICAucmVjZWl2ZShcIm9rXCIsIG9uRmluaXNoZWQpXG4gICAgICAucmVjZWl2ZShcImVycm9yXCIsIG9uRmluaXNoZWQpXG4gICAgICAucmVjZWl2ZShcInRpbWVvdXRcIiwgb25GaW5pc2hlZClcbiAgfVxuXG4gIHNldENvbnRhaW5lckNsYXNzZXMoLi4uY2xhc3Nlcyl7XG4gICAgdGhpcy5lbC5jbGFzc0xpc3QucmVtb3ZlKFxuICAgICAgUEhYX0NPTk5FQ1RFRF9DTEFTUyxcbiAgICAgIFBIWF9MT0FESU5HX0NMQVNTLFxuICAgICAgUEhYX0VSUk9SX0NMQVNTLFxuICAgICAgUEhYX0NMSUVOVF9FUlJPUl9DTEFTUyxcbiAgICAgIFBIWF9TRVJWRVJfRVJST1JfQ0xBU1NcbiAgICApXG4gICAgdGhpcy5lbC5jbGFzc0xpc3QuYWRkKC4uLmNsYXNzZXMpXG4gIH1cblxuICBzaG93TG9hZGVyKHRpbWVvdXQpe1xuICAgIGNsZWFyVGltZW91dCh0aGlzLmxvYWRlclRpbWVyKVxuICAgIGlmKHRpbWVvdXQpe1xuICAgICAgdGhpcy5sb2FkZXJUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gdGhpcy5zaG93TG9hZGVyKCksIHRpbWVvdXQpXG4gICAgfSBlbHNlIHtcbiAgICAgIGZvcihsZXQgaWQgaW4gdGhpcy52aWV3SG9va3MpeyB0aGlzLnZpZXdIb29rc1tpZF0uX19kaXNjb25uZWN0ZWQoKSB9XG4gICAgICB0aGlzLnNldENvbnRhaW5lckNsYXNzZXMoUEhYX0xPQURJTkdfQ0xBU1MpXG4gICAgfVxuICB9XG5cbiAgZXhlY0FsbChiaW5kaW5nKXtcbiAgICBET00uYWxsKHRoaXMuZWwsIGBbJHtiaW5kaW5nfV1gLCBlbCA9PiB0aGlzLmxpdmVTb2NrZXQuZXhlY0pTKGVsLCBlbC5nZXRBdHRyaWJ1dGUoYmluZGluZykpKVxuICB9XG5cbiAgaGlkZUxvYWRlcigpe1xuICAgIGNsZWFyVGltZW91dCh0aGlzLmxvYWRlclRpbWVyKVxuICAgIHRoaXMuc2V0Q29udGFpbmVyQ2xhc3NlcyhQSFhfQ09OTkVDVEVEX0NMQVNTKVxuICAgIHRoaXMuZXhlY0FsbCh0aGlzLmJpbmRpbmcoXCJjb25uZWN0ZWRcIikpXG4gIH1cblxuICB0cmlnZ2VyUmVjb25uZWN0ZWQoKXtcbiAgICBmb3IobGV0IGlkIGluIHRoaXMudmlld0hvb2tzKXsgdGhpcy52aWV3SG9va3NbaWRdLl9fcmVjb25uZWN0ZWQoKSB9XG4gIH1cblxuICBsb2coa2luZCwgbXNnQ2FsbGJhY2spe1xuICAgIHRoaXMubGl2ZVNvY2tldC5sb2codGhpcywga2luZCwgbXNnQ2FsbGJhY2spXG4gIH1cblxuICB0cmFuc2l0aW9uKHRpbWUsIG9uU3RhcnQsIG9uRG9uZSA9IGZ1bmN0aW9uKCl7fSl7XG4gICAgdGhpcy5saXZlU29ja2V0LnRyYW5zaXRpb24odGltZSwgb25TdGFydCwgb25Eb25lKVxuICB9XG5cbiAgLy8gY2FsbHMgdGhlIGNhbGxiYWNrIHdpdGggdGhlIHZpZXcgYW5kIHRhcmdldCBlbGVtZW50IGZvciB0aGUgZ2l2ZW4gcGh4VGFyZ2V0XG4gIC8vIHRhcmdldHMgY2FuIGJlOlxuICAvLyAgKiBhbiBlbGVtZW50IGl0c2VsZiwgdGhlbiBpdCBpcyBzaW1wbHkgcGFzc2VkIHRvIGxpdmVTb2NrZXQub3duZXI7XG4gIC8vICAqIGEgQ0lEIChDb21wb25lbnQgSUQpLCB0aGVuIHdlIGZpcnN0IHNlYXJjaCB0aGUgY29tcG9uZW50J3MgZWxlbWVudCBpbiB0aGUgRE9NXG4gIC8vICAqIGEgc2VsZWN0b3IsIHRoZW4gd2Ugc2VhcmNoIHRoZSBzZWxlY3RvciBpbiB0aGUgRE9NIGFuZCBjYWxsIHRoZSBjYWxsYmFja1xuICAvLyAgICBmb3IgZWFjaCBlbGVtZW50IGZvdW5kIHdpdGggdGhlIGNvcnJlc3BvbmRpbmcgb3duZXIgdmlld1xuICB3aXRoaW5UYXJnZXRzKHBoeFRhcmdldCwgY2FsbGJhY2ssIGRvbSA9IGRvY3VtZW50LCB2aWV3RWwpe1xuICAgIC8vIGluIHRoZSBmb3JtIHJlY292ZXJ5IGNhc2Ugd2Ugc2VhcmNoIGluIGEgdGVtcGxhdGUgZnJhZ21lbnQgaW5zdGVhZCBvZlxuICAgIC8vIHRoZSByZWFsIGRvbSwgdGhlcmVmb3JlIHdlIG9wdGlvbmFsbHkgcGFzcyBkb20gYW5kIHZpZXdFbFxuXG4gICAgaWYocGh4VGFyZ2V0IGluc3RhbmNlb2YgSFRNTEVsZW1lbnQgfHwgcGh4VGFyZ2V0IGluc3RhbmNlb2YgU1ZHRWxlbWVudCl7XG4gICAgICByZXR1cm4gdGhpcy5saXZlU29ja2V0Lm93bmVyKHBoeFRhcmdldCwgdmlldyA9PiBjYWxsYmFjayh2aWV3LCBwaHhUYXJnZXQpKVxuICAgIH1cblxuICAgIGlmKGlzQ2lkKHBoeFRhcmdldCkpe1xuICAgICAgbGV0IHRhcmdldHMgPSBET00uZmluZENvbXBvbmVudE5vZGVMaXN0KHZpZXdFbCB8fCB0aGlzLmVsLCBwaHhUYXJnZXQpXG4gICAgICBpZih0YXJnZXRzLmxlbmd0aCA9PT0gMCl7XG4gICAgICAgIGxvZ0Vycm9yKGBubyBjb21wb25lbnQgZm91bmQgbWF0Y2hpbmcgcGh4LXRhcmdldCBvZiAke3BoeFRhcmdldH1gKVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgY2FsbGJhY2sodGhpcywgcGFyc2VJbnQocGh4VGFyZ2V0KSlcbiAgICAgIH1cbiAgICB9IGVsc2Uge1xuICAgICAgbGV0IHRhcmdldHMgPSBBcnJheS5mcm9tKGRvbS5xdWVyeVNlbGVjdG9yQWxsKHBoeFRhcmdldCkpXG4gICAgICBpZih0YXJnZXRzLmxlbmd0aCA9PT0gMCl7IGxvZ0Vycm9yKGBub3RoaW5nIGZvdW5kIG1hdGNoaW5nIHRoZSBwaHgtdGFyZ2V0IHNlbGVjdG9yIFwiJHtwaHhUYXJnZXR9XCJgKSB9XG4gICAgICB0YXJnZXRzLmZvckVhY2godGFyZ2V0ID0+IHRoaXMubGl2ZVNvY2tldC5vd25lcih0YXJnZXQsIHZpZXcgPT4gY2FsbGJhY2sodmlldywgdGFyZ2V0KSkpXG4gICAgfVxuICB9XG5cbiAgYXBwbHlEaWZmKHR5cGUsIHJhd0RpZmYsIGNhbGxiYWNrKXtcbiAgICB0aGlzLmxvZyh0eXBlLCAoKSA9PiBbXCJcIiwgY2xvbmUocmF3RGlmZildKVxuICAgIGxldCB7ZGlmZiwgcmVwbHksIGV2ZW50cywgdGl0bGV9ID0gUmVuZGVyZWQuZXh0cmFjdChyYXdEaWZmKVxuICAgIGNhbGxiYWNrKHtkaWZmLCByZXBseSwgZXZlbnRzfSlcbiAgICBpZih0eXBlb2YgdGl0bGUgPT09IFwic3RyaW5nXCIpeyB3aW5kb3cucmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IERPTS5wdXRUaXRsZSh0aXRsZSkpIH1cbiAgfVxuXG4gIG9uSm9pbihyZXNwKXtcbiAgICBsZXQge3JlbmRlcmVkLCBjb250YWluZXIsIGxpdmV2aWV3X3ZlcnNpb259ID0gcmVzcFxuICAgIGlmKGNvbnRhaW5lcil7XG4gICAgICBsZXQgW3RhZywgYXR0cnNdID0gY29udGFpbmVyXG4gICAgICB0aGlzLmVsID0gRE9NLnJlcGxhY2VSb290Q29udGFpbmVyKHRoaXMuZWwsIHRhZywgYXR0cnMpXG4gICAgfVxuICAgIHRoaXMuY2hpbGRKb2lucyA9IDBcbiAgICB0aGlzLmpvaW5QZW5kaW5nID0gdHJ1ZVxuICAgIHRoaXMuZmxhc2ggPSBudWxsXG4gICAgaWYodGhpcy5yb290ID09PSB0aGlzKXtcbiAgICAgIHRoaXMuZm9ybXNGb3JSZWNvdmVyeSA9IHRoaXMuZ2V0Rm9ybXNGb3JSZWNvdmVyeSgpXG4gICAgfVxuXG4gICAgaWYobGl2ZXZpZXdfdmVyc2lvbiAhPT0gdGhpcy5saXZlU29ja2V0LnZlcnNpb24oKSl7XG4gICAgICBjb25zb2xlLmVycm9yKGBMaXZlVmlldyBhc3NldCB2ZXJzaW9uIG1pc21hdGNoLiBKYXZhU2NyaXB0IHZlcnNpb24gJHt0aGlzLmxpdmVTb2NrZXQudmVyc2lvbigpfSB2cy4gc2VydmVyICR7bGl2ZXZpZXdfdmVyc2lvbn0uIFRvIGF2b2lkIGlzc3VlcywgcGxlYXNlIGVuc3VyZSB0aGF0IHlvdXIgYXNzZXRzIHVzZSB0aGUgc2FtZSB2ZXJzaW9uIGFzIHRoZSBzZXJ2ZXIuYClcbiAgICB9XG5cbiAgICBCcm93c2VyLmRyb3BMb2NhbCh0aGlzLmxpdmVTb2NrZXQubG9jYWxTdG9yYWdlLCB3aW5kb3cubG9jYXRpb24ucGF0aG5hbWUsIENPTlNFQ1VUSVZFX1JFTE9BRFMpXG4gICAgdGhpcy5hcHBseURpZmYoXCJtb3VudFwiLCByZW5kZXJlZCwgKHtkaWZmLCBldmVudHN9KSA9PiB7XG4gICAgICB0aGlzLnJlbmRlcmVkID0gbmV3IFJlbmRlcmVkKHRoaXMuaWQsIGRpZmYpXG4gICAgICBsZXQgW2h0bWwsIHN0cmVhbXNdID0gdGhpcy5yZW5kZXJDb250YWluZXIobnVsbCwgXCJqb2luXCIpXG4gICAgICB0aGlzLmRyb3BQZW5kaW5nUmVmcygpXG4gICAgICB0aGlzLmpvaW5Db3VudCsrXG5cbiAgICAgIHRoaXMubWF5YmVSZWNvdmVyRm9ybXMoaHRtbCwgKCkgPT4ge1xuICAgICAgICB0aGlzLm9uSm9pbkNvbXBsZXRlKHJlc3AsIGh0bWwsIHN0cmVhbXMsIGV2ZW50cylcbiAgICAgIH0pXG4gICAgfSlcbiAgfVxuXG4gIGRyb3BQZW5kaW5nUmVmcygpe1xuICAgIERPTS5hbGwoZG9jdW1lbnQsIGBbJHtQSFhfUkVGX1NSQ309XCIke3RoaXMuaWR9XCJdWyR7UEhYX1JFRn1dYCwgZWwgPT4ge1xuICAgICAgZWwucmVtb3ZlQXR0cmlidXRlKFBIWF9SRUYpXG4gICAgICBlbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1JFRl9TUkMpXG4gICAgfSlcbiAgfVxuXG4gIG9uSm9pbkNvbXBsZXRlKHtsaXZlX3BhdGNofSwgaHRtbCwgc3RyZWFtcywgZXZlbnRzKXtcbiAgICAvLyBJbiBvcmRlciB0byBwcm92aWRlIGEgYmV0dGVyIGV4cGVyaWVuY2UsIHdlIHdhbnQgdG8gam9pblxuICAgIC8vIGFsbCBMaXZlVmlld3MgZmlyc3QgYW5kIG9ubHkgdGhlbiBhcHBseSB0aGVpciBwYXRjaGVzLlxuICAgIGlmKHRoaXMuam9pbkNvdW50ID4gMSB8fCAodGhpcy5wYXJlbnQgJiYgIXRoaXMucGFyZW50LmlzSm9pblBlbmRpbmcoKSkpe1xuICAgICAgcmV0dXJuIHRoaXMuYXBwbHlKb2luUGF0Y2gobGl2ZV9wYXRjaCwgaHRtbCwgc3RyZWFtcywgZXZlbnRzKVxuICAgIH1cblxuICAgIC8vIE9uZSBkb3duc2lkZSBvZiB0aGlzIGFwcHJvYWNoIGlzIHRoYXQgd2UgbmVlZCB0byBmaW5kIHBoeENoaWxkcmVuXG4gICAgLy8gaW4gdGhlIGh0bWwgZnJhZ21lbnQsIGluc3RlYWQgb2YgZGlyZWN0bHkgb24gdGhlIERPTS4gVGhlIGZyYWdtZW50XG4gICAgLy8gYWxzbyBkb2VzIG5vdCBpbmNsdWRlIFBIWF9TVEFUSUMsIHNvIHdlIG5lZWQgdG8gY29weSBpdCBvdmVyIGZyb21cbiAgICAvLyB0aGUgRE9NLlxuICAgIGxldCBuZXdDaGlsZHJlbiA9IERPTS5maW5kUGh4Q2hpbGRyZW5JbkZyYWdtZW50KGh0bWwsIHRoaXMuaWQpLmZpbHRlcih0b0VsID0+IHtcbiAgICAgIGxldCBmcm9tRWwgPSB0b0VsLmlkICYmIHRoaXMuZWwucXVlcnlTZWxlY3RvcihgW2lkPVwiJHt0b0VsLmlkfVwiXWApXG4gICAgICBsZXQgcGh4U3RhdGljID0gZnJvbUVsICYmIGZyb21FbC5nZXRBdHRyaWJ1dGUoUEhYX1NUQVRJQylcbiAgICAgIGlmKHBoeFN0YXRpYyl7IHRvRWwuc2V0QXR0cmlidXRlKFBIWF9TVEFUSUMsIHBoeFN0YXRpYykgfVxuICAgICAgLy8gc2V0IFBIWF9ST09UX0lEIHRvIHByZXZlbnQgZXZlbnRzIGZyb20gYmVpbmcgZGlzcGF0Y2hlZCB0byB0aGUgcm9vdCB2aWV3XG4gICAgICAvLyB3aGlsZSB0aGUgY2hpbGQgam9pbiBpcyBzdGlsbCBwZW5kaW5nXG4gICAgICBpZihmcm9tRWwpeyBmcm9tRWwuc2V0QXR0cmlidXRlKFBIWF9ST09UX0lELCB0aGlzLnJvb3QuaWQpIH1cbiAgICAgIHJldHVybiB0aGlzLmpvaW5DaGlsZCh0b0VsKVxuICAgIH0pXG5cbiAgICBpZihuZXdDaGlsZHJlbi5sZW5ndGggPT09IDApe1xuICAgICAgaWYodGhpcy5wYXJlbnQpe1xuICAgICAgICB0aGlzLnJvb3QucGVuZGluZ0pvaW5PcHMucHVzaChbdGhpcywgKCkgPT4gdGhpcy5hcHBseUpvaW5QYXRjaChsaXZlX3BhdGNoLCBodG1sLCBzdHJlYW1zLCBldmVudHMpXSlcbiAgICAgICAgdGhpcy5wYXJlbnQuYWNrSm9pbih0aGlzKVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdGhpcy5vbkFsbENoaWxkSm9pbnNDb21wbGV0ZSgpXG4gICAgICAgIHRoaXMuYXBwbHlKb2luUGF0Y2gobGl2ZV9wYXRjaCwgaHRtbCwgc3RyZWFtcywgZXZlbnRzKVxuICAgICAgfVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLnJvb3QucGVuZGluZ0pvaW5PcHMucHVzaChbdGhpcywgKCkgPT4gdGhpcy5hcHBseUpvaW5QYXRjaChsaXZlX3BhdGNoLCBodG1sLCBzdHJlYW1zLCBldmVudHMpXSlcbiAgICB9XG4gIH1cblxuICBhdHRhY2hUcnVlRG9jRWwoKXtcbiAgICB0aGlzLmVsID0gRE9NLmJ5SWQodGhpcy5pZClcbiAgICB0aGlzLmVsLnNldEF0dHJpYnV0ZShQSFhfUk9PVF9JRCwgdGhpcy5yb290LmlkKVxuICB9XG5cbiAgLy8gdGhpcyBpcyBpbnZva2VkIGZvciBkZWFkIGFuZCBsaXZlIHZpZXdzLCBzbyB3ZSBtdXN0IGZpbHRlciBieVxuICAvLyBieSBvd25lciB0byBlbnN1cmUgd2UgYXJlbid0IGR1cGxpY2F0aW5nIGhvb2tzIGFjcm9zcyBkaXNjb25uZWN0XG4gIC8vIGFuZCBjb25uZWN0ZWQgc3RhdGVzLiBUaGlzIGFsc28gaGFuZGxlcyBjYXNlcyB3aGVyZSBob29rcyBleGlzdFxuICAvLyBpbiBhIHJvb3QgbGF5b3V0IHdpdGggYSBMViBpbiB0aGUgYm9keVxuICBleGVjTmV3TW91bnRlZCgpe1xuICAgIGxldCBwaHhWaWV3cG9ydFRvcCA9IHRoaXMuYmluZGluZyhQSFhfVklFV1BPUlRfVE9QKVxuICAgIGxldCBwaHhWaWV3cG9ydEJvdHRvbSA9IHRoaXMuYmluZGluZyhQSFhfVklFV1BPUlRfQk9UVE9NKVxuICAgIERPTS5hbGwodGhpcy5lbCwgYFske3BoeFZpZXdwb3J0VG9wfV0sIFske3BoeFZpZXdwb3J0Qm90dG9tfV1gLCBob29rRWwgPT4ge1xuICAgICAgaWYodGhpcy5vd25zRWxlbWVudChob29rRWwpKXtcbiAgICAgICAgRE9NLm1heWJlQWRkUHJpdmF0ZUhvb2tzKGhvb2tFbCwgcGh4Vmlld3BvcnRUb3AsIHBoeFZpZXdwb3J0Qm90dG9tKVxuICAgICAgICB0aGlzLm1heWJlQWRkTmV3SG9vayhob29rRWwpXG4gICAgICB9XG4gICAgfSlcbiAgICBET00uYWxsKHRoaXMuZWwsIGBbJHt0aGlzLmJpbmRpbmcoUEhYX0hPT0spfV0sIFtkYXRhLXBoeC0ke1BIWF9IT09LfV1gLCBob29rRWwgPT4ge1xuICAgICAgaWYodGhpcy5vd25zRWxlbWVudChob29rRWwpKXtcbiAgICAgICAgdGhpcy5tYXliZUFkZE5ld0hvb2soaG9va0VsKVxuICAgICAgfVxuICAgIH0pXG4gICAgRE9NLmFsbCh0aGlzLmVsLCBgWyR7dGhpcy5iaW5kaW5nKFBIWF9NT1VOVEVEKX1dYCwgZWwgPT4ge1xuICAgICAgaWYodGhpcy5vd25zRWxlbWVudChlbCkpe1xuICAgICAgICB0aGlzLm1heWJlTW91bnRlZChlbClcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgYXBwbHlKb2luUGF0Y2gobGl2ZV9wYXRjaCwgaHRtbCwgc3RyZWFtcywgZXZlbnRzKXtcbiAgICB0aGlzLmF0dGFjaFRydWVEb2NFbCgpXG4gICAgbGV0IHBhdGNoID0gbmV3IERPTVBhdGNoKHRoaXMsIHRoaXMuZWwsIHRoaXMuaWQsIGh0bWwsIHN0cmVhbXMsIG51bGwpXG4gICAgcGF0Y2gubWFya1BydW5hYmxlQ29udGVudEZvclJlbW92YWwoKVxuICAgIHRoaXMucGVyZm9ybVBhdGNoKHBhdGNoLCBmYWxzZSwgdHJ1ZSlcbiAgICB0aGlzLmpvaW5OZXdDaGlsZHJlbigpXG4gICAgdGhpcy5leGVjTmV3TW91bnRlZCgpXG5cbiAgICB0aGlzLmpvaW5QZW5kaW5nID0gZmFsc2VcbiAgICB0aGlzLmxpdmVTb2NrZXQuZGlzcGF0Y2hFdmVudHMoZXZlbnRzKVxuICAgIHRoaXMuYXBwbHlQZW5kaW5nVXBkYXRlcygpXG5cbiAgICBpZihsaXZlX3BhdGNoKXtcbiAgICAgIGxldCB7a2luZCwgdG99ID0gbGl2ZV9wYXRjaFxuICAgICAgdGhpcy5saXZlU29ja2V0Lmhpc3RvcnlQYXRjaCh0bywga2luZClcbiAgICB9XG4gICAgdGhpcy5oaWRlTG9hZGVyKClcbiAgICBpZih0aGlzLmpvaW5Db3VudCA+IDEpeyB0aGlzLnRyaWdnZXJSZWNvbm5lY3RlZCgpIH1cbiAgICB0aGlzLnN0b3BDYWxsYmFjaygpXG4gIH1cblxuICB0cmlnZ2VyQmVmb3JlVXBkYXRlSG9vayhmcm9tRWwsIHRvRWwpe1xuICAgIHRoaXMubGl2ZVNvY2tldC50cmlnZ2VyRE9NKFwib25CZWZvcmVFbFVwZGF0ZWRcIiwgW2Zyb21FbCwgdG9FbF0pXG4gICAgbGV0IGhvb2sgPSB0aGlzLmdldEhvb2soZnJvbUVsKVxuICAgIGxldCBpc0lnbm9yZWQgPSBob29rICYmIERPTS5pc0lnbm9yZWQoZnJvbUVsLCB0aGlzLmJpbmRpbmcoUEhYX1VQREFURSkpXG4gICAgaWYoaG9vayAmJiAhZnJvbUVsLmlzRXF1YWxOb2RlKHRvRWwpICYmICEoaXNJZ25vcmVkICYmIGlzRXF1YWxPYmooZnJvbUVsLmRhdGFzZXQsIHRvRWwuZGF0YXNldCkpKXtcbiAgICAgIGhvb2suX19iZWZvcmVVcGRhdGUoKVxuICAgICAgcmV0dXJuIGhvb2tcbiAgICB9XG4gIH1cblxuICBtYXliZU1vdW50ZWQoZWwpe1xuICAgIGxldCBwaHhNb3VudGVkID0gZWwuZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhQSFhfTU9VTlRFRCkpXG4gICAgbGV0IGhhc0JlZW5JbnZva2VkID0gcGh4TW91bnRlZCAmJiBET00ucHJpdmF0ZShlbCwgXCJtb3VudGVkXCIpXG4gICAgaWYocGh4TW91bnRlZCAmJiAhaGFzQmVlbkludm9rZWQpe1xuICAgICAgdGhpcy5saXZlU29ja2V0LmV4ZWNKUyhlbCwgcGh4TW91bnRlZClcbiAgICAgIERPTS5wdXRQcml2YXRlKGVsLCBcIm1vdW50ZWRcIiwgdHJ1ZSlcbiAgICB9XG4gIH1cblxuICBtYXliZUFkZE5ld0hvb2soZWwsIGZvcmNlKXtcbiAgICBsZXQgbmV3SG9vayA9IHRoaXMuYWRkSG9vayhlbClcbiAgICBpZihuZXdIb29rKXsgbmV3SG9vay5fX21vdW50ZWQoKSB9XG4gIH1cblxuICBwZXJmb3JtUGF0Y2gocGF0Y2gsIHBydW5lQ2lkcywgaXNKb2luUGF0Y2ggPSBmYWxzZSl7XG4gICAgbGV0IHJlbW92ZWRFbHMgPSBbXVxuICAgIGxldCBwaHhDaGlsZHJlbkFkZGVkID0gZmFsc2VcbiAgICBsZXQgdXBkYXRlZEhvb2tJZHMgPSBuZXcgU2V0KClcblxuICAgIHBhdGNoLmFmdGVyKFwiYWRkZWRcIiwgZWwgPT4ge1xuICAgICAgdGhpcy5saXZlU29ja2V0LnRyaWdnZXJET00oXCJvbk5vZGVBZGRlZFwiLCBbZWxdKVxuICAgICAgbGV0IHBoeFZpZXdwb3J0VG9wID0gdGhpcy5iaW5kaW5nKFBIWF9WSUVXUE9SVF9UT1ApXG4gICAgICBsZXQgcGh4Vmlld3BvcnRCb3R0b20gPSB0aGlzLmJpbmRpbmcoUEhYX1ZJRVdQT1JUX0JPVFRPTSlcbiAgICAgIERPTS5tYXliZUFkZFByaXZhdGVIb29rcyhlbCwgcGh4Vmlld3BvcnRUb3AsIHBoeFZpZXdwb3J0Qm90dG9tKVxuICAgICAgdGhpcy5tYXliZUFkZE5ld0hvb2soZWwpXG4gICAgICBpZihlbC5nZXRBdHRyaWJ1dGUpeyB0aGlzLm1heWJlTW91bnRlZChlbCkgfVxuICAgIH0pXG5cbiAgICBwYXRjaC5hZnRlcihcInBoeENoaWxkQWRkZWRcIiwgZWwgPT4ge1xuICAgICAgaWYoRE9NLmlzUGh4U3RpY2t5KGVsKSl7XG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5qb2luUm9vdFZpZXdzKClcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHBoeENoaWxkcmVuQWRkZWQgPSB0cnVlXG4gICAgICB9XG4gICAgfSlcblxuICAgIHBhdGNoLmJlZm9yZShcInVwZGF0ZWRcIiwgKGZyb21FbCwgdG9FbCkgPT4ge1xuICAgICAgbGV0IGhvb2sgPSB0aGlzLnRyaWdnZXJCZWZvcmVVcGRhdGVIb29rKGZyb21FbCwgdG9FbClcbiAgICAgIGlmKGhvb2speyB1cGRhdGVkSG9va0lkcy5hZGQoZnJvbUVsLmlkKSB9XG4gICAgfSlcblxuICAgIHBhdGNoLmFmdGVyKFwidXBkYXRlZFwiLCBlbCA9PiB7XG4gICAgICBpZih1cGRhdGVkSG9va0lkcy5oYXMoZWwuaWQpKXsgdGhpcy5nZXRIb29rKGVsKS5fX3VwZGF0ZWQoKSB9XG4gICAgfSlcblxuICAgIHBhdGNoLmFmdGVyKFwiZGlzY2FyZGVkXCIsIChlbCkgPT4ge1xuICAgICAgaWYoZWwubm9kZVR5cGUgPT09IE5vZGUuRUxFTUVOVF9OT0RFKXsgcmVtb3ZlZEVscy5wdXNoKGVsKSB9XG4gICAgfSlcblxuICAgIHBhdGNoLmFmdGVyKFwidHJhbnNpdGlvbnNEaXNjYXJkZWRcIiwgZWxzID0+IHRoaXMuYWZ0ZXJFbGVtZW50c1JlbW92ZWQoZWxzLCBwcnVuZUNpZHMpKVxuICAgIHBhdGNoLnBlcmZvcm0oaXNKb2luUGF0Y2gpXG4gICAgdGhpcy5hZnRlckVsZW1lbnRzUmVtb3ZlZChyZW1vdmVkRWxzLCBwcnVuZUNpZHMpXG5cbiAgICByZXR1cm4gcGh4Q2hpbGRyZW5BZGRlZFxuICB9XG5cbiAgYWZ0ZXJFbGVtZW50c1JlbW92ZWQoZWxlbWVudHMsIHBydW5lQ2lkcyl7XG4gICAgbGV0IGRlc3Ryb3llZENJRHMgPSBbXVxuICAgIGVsZW1lbnRzLmZvckVhY2gocGFyZW50ID0+IHtcbiAgICAgIGxldCBjb21wb25lbnRzID0gRE9NLmFsbChwYXJlbnQsIGBbJHtQSFhfQ09NUE9ORU5UfV1gKVxuICAgICAgbGV0IGhvb2tzID0gRE9NLmFsbChwYXJlbnQsIGBbJHt0aGlzLmJpbmRpbmcoUEhYX0hPT0spfV1gKVxuICAgICAgY29tcG9uZW50cy5jb25jYXQocGFyZW50KS5mb3JFYWNoKGVsID0+IHtcbiAgICAgICAgbGV0IGNpZCA9IHRoaXMuY29tcG9uZW50SUQoZWwpXG4gICAgICAgIGlmKGlzQ2lkKGNpZCkgJiYgZGVzdHJveWVkQ0lEcy5pbmRleE9mKGNpZCkgPT09IC0xKXsgZGVzdHJveWVkQ0lEcy5wdXNoKGNpZCkgfVxuICAgICAgfSlcbiAgICAgIGhvb2tzLmNvbmNhdChwYXJlbnQpLmZvckVhY2goaG9va0VsID0+IHtcbiAgICAgICAgbGV0IGhvb2sgPSB0aGlzLmdldEhvb2soaG9va0VsKVxuICAgICAgICBob29rICYmIHRoaXMuZGVzdHJveUhvb2soaG9vaylcbiAgICAgIH0pXG4gICAgfSlcbiAgICAvLyBXZSBzaG91bGQgbm90IHBydW5lQ2lkcyBvbiBqb2lucy4gT3RoZXJ3aXNlLCBpbiBjYXNlIG9mXG4gICAgLy8gcmVqb2lucywgd2UgbWF5IG5vdGlmeSBjaWRzIHRoYXQgbm8gbG9uZ2VyIGJlbG9uZyB0byB0aGVcbiAgICAvLyBjdXJyZW50IExpdmVWaWV3IHRvIGJlIHJlbW92ZWQuXG4gICAgaWYocHJ1bmVDaWRzKXtcbiAgICAgIHRoaXMubWF5YmVQdXNoQ29tcG9uZW50c0Rlc3Ryb3llZChkZXN0cm95ZWRDSURzKVxuICAgIH1cbiAgfVxuXG4gIGpvaW5OZXdDaGlsZHJlbigpe1xuICAgIERPTS5maW5kUGh4Q2hpbGRyZW4odGhpcy5lbCwgdGhpcy5pZCkuZm9yRWFjaChlbCA9PiB0aGlzLmpvaW5DaGlsZChlbCkpXG4gIH1cblxuICBtYXliZVJlY292ZXJGb3JtcyhodG1sLCBjYWxsYmFjayl7XG4gICAgY29uc3QgcGh4Q2hhbmdlID0gdGhpcy5iaW5kaW5nKFwiY2hhbmdlXCIpXG4gICAgY29uc3Qgb2xkRm9ybXMgPSB0aGlzLnJvb3QuZm9ybXNGb3JSZWNvdmVyeVxuICAgIC8vIFNvIHdoeSBkbyB3ZSBjcmVhdGUgYSB0ZW1wbGF0ZSBlbGVtZW50IGhlcmU/XG4gICAgLy8gT25lIHdheSB0byByZWNvdmVyIGZvcm1zIHdvdWxkIGJlIHRvIGltbWVkaWF0ZWx5IGFwcGx5IHRoZSBtb3VudFxuICAgIC8vIHBhdGNoIGFuZCB0aGVuIGFmdGVyd2FyZHMgcmVjb3ZlciB0aGUgZm9ybXMuIEhvd2V2ZXIsIHRoaXMgd291bGRcbiAgICAvLyBjYXVzZSBhIGZsaWNrZXIsIGJlY2F1c2UgdGhlIG1vdW50IHBhdGNoIHdvdWxkIHJlbW92ZSB0aGUgZm9ybSBjb250ZW50XG4gICAgLy8gdW50aWwgaXQgaXMgcmVzdG9yZWQuIFRoZXJlZm9yZSBMViBkZWNpZGVkIHRvIGRvIGZvcm0gcmVjb3Zlcnkgd2l0aCB0aGVcbiAgICAvLyByYXcgSFRNTCBiZWZvcmUgaXQgaXMgYXBwbGllZCBhbmQgZGVsYXkgdGhlIG1vdW50IHBhdGNoIHVudGlsIHRoZSBmb3JtXG4gICAgLy8gcmVjb3ZlcnkgZXZlbnRzIGFyZSBkb25lLlxuICAgIGxldCB0ZW1wbGF0ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJ0ZW1wbGF0ZVwiKVxuICAgIHRlbXBsYXRlLmlubmVySFRNTCA9IGh0bWxcbiAgICAvLyBiZWNhdXNlIHdlIHdvcmsgd2l0aCBhIHRlbXBsYXRlIGVsZW1lbnQsIHdlIG11c3QgbWFudWFsbHkgY29weSB0aGUgYXR0cmlidXRlc1xuICAgIC8vIG90aGVyd2lzZSB0aGUgb3duZXIgLyB0YXJnZXQgaGVscGVycyBkb24ndCB3b3JrIHByb3Blcmx5XG4gICAgY29uc3Qgcm9vdEVsID0gdGVtcGxhdGUuY29udGVudC5maXJzdEVsZW1lbnRDaGlsZFxuICAgIHJvb3RFbC5pZCA9IHRoaXMuaWRcbiAgICByb290RWwuc2V0QXR0cmlidXRlKFBIWF9ST09UX0lELCB0aGlzLnJvb3QuaWQpXG4gICAgcm9vdEVsLnNldEF0dHJpYnV0ZShQSFhfU0VTU0lPTiwgdGhpcy5nZXRTZXNzaW9uKCkpXG4gICAgcm9vdEVsLnNldEF0dHJpYnV0ZShQSFhfU1RBVElDLCB0aGlzLmdldFN0YXRpYygpKVxuICAgIHJvb3RFbC5zZXRBdHRyaWJ1dGUoUEhYX1BBUkVOVF9JRCwgdGhpcy5wYXJlbnQgPyB0aGlzLnBhcmVudC5pZCA6IG51bGwpXG5cbiAgICAvLyB3ZSBnbyBvdmVyIGFsbCBmb3JtIGVsZW1lbnRzIGluIHRoZSBuZXcgSFRNTCBmb3IgdGhlIExWXG4gICAgLy8gYW5kIGxvb2sgZm9yIG9sZCBmb3JtcyBpbiB0aGUgYGZvcm1zRm9yUmVjb3ZlcnlgIG9iamVjdDtcbiAgICAvLyB0aGUgZm9ybXNGb3JSZWNvdmVyeSBjYW4gYWxzbyBjb250YWluIGZvcm1zIGZyb20gY2hpbGQgdmlld3NcbiAgICBjb25zdCBmb3Jtc1RvUmVjb3ZlciA9XG4gICAgICAvLyB3ZSBnbyBvdmVyIGFsbCBmb3JtcyBpbiB0aGUgbmV3IERPTTsgYmVjYXVzZSB0aGlzIGlzIG9ubHkgdGhlIEhUTUwgZm9yIHRoZSBjdXJyZW50XG4gICAgICAvLyB2aWV3LCB3ZSBjYW4gYmUgc3VyZSB0aGF0IGFsbCBmb3JtcyBhcmUgb3duZWQgYnkgdGhpcyB2aWV3OlxuICAgICAgRE9NLmFsbCh0ZW1wbGF0ZS5jb250ZW50LCBcImZvcm1cIilcbiAgICAgICAgLy8gb25seSByZWNvdmVyIGZvcm1zIHRoYXQgaGF2ZSBhbiBpZCBhbmQgYXJlIGluIHRoZSBvbGQgRE9NXG4gICAgICAgIC5maWx0ZXIobmV3Rm9ybSA9PiBuZXdGb3JtLmlkICYmIG9sZEZvcm1zW25ld0Zvcm0uaWRdKVxuICAgICAgICAvLyBhYmFuZG9uIGZvcm1zIHdlIGFscmVhZHkgdHJpZWQgdG8gcmVjb3ZlciB0byBwcmV2ZW50IGxvb3BpbmcgYSBmYWlsZWQgc3RhdGVcbiAgICAgICAgLmZpbHRlcihuZXdGb3JtID0+ICF0aGlzLnBlbmRpbmdGb3Jtcy5oYXMobmV3Rm9ybS5pZCkpXG4gICAgICAgIC8vIG9ubHkgcmVjb3ZlciBpZiB0aGUgZm9ybSBoYXMgdGhlIHNhbWUgcGh4LWNoYW5nZSB2YWx1ZVxuICAgICAgICAuZmlsdGVyKG5ld0Zvcm0gPT4gb2xkRm9ybXNbbmV3Rm9ybS5pZF0uZ2V0QXR0cmlidXRlKHBoeENoYW5nZSkgPT09IG5ld0Zvcm0uZ2V0QXR0cmlidXRlKHBoeENoYW5nZSkpXG4gICAgICAgIC5tYXAobmV3Rm9ybSA9PiB7XG4gICAgICAgICAgcmV0dXJuIFtvbGRGb3Jtc1tuZXdGb3JtLmlkXSwgbmV3Rm9ybV1cbiAgICAgICAgfSlcblxuICAgIGlmKGZvcm1zVG9SZWNvdmVyLmxlbmd0aCA9PT0gMCl7XG4gICAgICByZXR1cm4gY2FsbGJhY2soKVxuICAgIH1cblxuICAgIGZvcm1zVG9SZWNvdmVyLmZvckVhY2goKFtvbGRGb3JtLCBuZXdGb3JtXSwgaSkgPT4ge1xuICAgICAgdGhpcy5wZW5kaW5nRm9ybXMuYWRkKG5ld0Zvcm0uaWQpXG4gICAgICB0aGlzLnB1c2hGb3JtUmVjb3Zlcnkob2xkRm9ybSwgbmV3Rm9ybSwgdGVtcGxhdGUuY29udGVudCwgKCkgPT4ge1xuICAgICAgICB0aGlzLnBlbmRpbmdGb3Jtcy5kZWxldGUobmV3Rm9ybS5pZClcbiAgICAgICAgLy8gd2Ugb25seSBjYWxsIHRoZSBjYWxsYmFjayBvbmNlIGFsbCBmb3JtcyBoYXZlIGJlZW4gcmVjb3ZlcmVkXG4gICAgICAgIGlmKGkgPT09IGZvcm1zVG9SZWNvdmVyLmxlbmd0aCAtIDEpe1xuICAgICAgICAgIGNhbGxiYWNrKClcbiAgICAgICAgfVxuICAgICAgfSlcbiAgICB9KVxuICB9XG5cbiAgZ2V0Q2hpbGRCeUlkKGlkKXsgcmV0dXJuIHRoaXMucm9vdC5jaGlsZHJlblt0aGlzLmlkXVtpZF0gfVxuXG4gIGdldERlc2NlbmRlbnRCeUVsKGVsKXtcbiAgICBpZihlbC5pZCA9PT0gdGhpcy5pZCl7XG4gICAgICByZXR1cm4gdGhpc1xuICAgIH0gZWxzZSB7XG4gICAgICByZXR1cm4gdGhpcy5jaGlsZHJlbltlbC5nZXRBdHRyaWJ1dGUoUEhYX1BBUkVOVF9JRCldW2VsLmlkXVxuICAgIH1cbiAgfVxuXG4gIGRlc3Ryb3lEZXNjZW5kZW50KGlkKXtcbiAgICBmb3IobGV0IHBhcmVudElkIGluIHRoaXMucm9vdC5jaGlsZHJlbil7XG4gICAgICBmb3IobGV0IGNoaWxkSWQgaW4gdGhpcy5yb290LmNoaWxkcmVuW3BhcmVudElkXSl7XG4gICAgICAgIGlmKGNoaWxkSWQgPT09IGlkKXsgcmV0dXJuIHRoaXMucm9vdC5jaGlsZHJlbltwYXJlbnRJZF1bY2hpbGRJZF0uZGVzdHJveSgpIH1cbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICBqb2luQ2hpbGQoZWwpe1xuICAgIGxldCBjaGlsZCA9IHRoaXMuZ2V0Q2hpbGRCeUlkKGVsLmlkKVxuICAgIGlmKCFjaGlsZCl7XG4gICAgICBsZXQgdmlldyA9IG5ldyBWaWV3KGVsLCB0aGlzLmxpdmVTb2NrZXQsIHRoaXMpXG4gICAgICB0aGlzLnJvb3QuY2hpbGRyZW5bdGhpcy5pZF1bdmlldy5pZF0gPSB2aWV3XG4gICAgICB2aWV3LmpvaW4oKVxuICAgICAgdGhpcy5jaGlsZEpvaW5zKytcbiAgICAgIHJldHVybiB0cnVlXG4gICAgfVxuICB9XG5cbiAgaXNKb2luUGVuZGluZygpeyByZXR1cm4gdGhpcy5qb2luUGVuZGluZyB9XG5cbiAgYWNrSm9pbihfY2hpbGQpe1xuICAgIHRoaXMuY2hpbGRKb2lucy0tXG5cbiAgICBpZih0aGlzLmNoaWxkSm9pbnMgPT09IDApe1xuICAgICAgaWYodGhpcy5wYXJlbnQpe1xuICAgICAgICB0aGlzLnBhcmVudC5hY2tKb2luKHRoaXMpXG4gICAgICB9IGVsc2Uge1xuICAgICAgICB0aGlzLm9uQWxsQ2hpbGRKb2luc0NvbXBsZXRlKClcbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICBvbkFsbENoaWxkSm9pbnNDb21wbGV0ZSgpe1xuICAgIC8vIHdlIGNhbiBjbGVhciBwZW5kaW5nIGZvcm0gcmVjb3ZlcmllcyBub3cgdGhhdCB3ZSd2ZSBqb2luZWQuXG4gICAgLy8gVGhleSBlaXRoZXIgYWxsIHJlc29sdmVkIG9yIHdlcmUgYWJhbmRvbmVkXG4gICAgdGhpcy5wZW5kaW5nRm9ybXMuY2xlYXIoKVxuICAgIC8vIHdlIGNhbiBhbHNvIGNsZWFyIHRoZSBmb3Jtc0ZvclJlY292ZXJ5IG9iamVjdCB0byBub3Qga2VlcCBvbGQgZm9ybSBlbGVtZW50cyBhcm91bmRcbiAgICB0aGlzLmZvcm1zRm9yUmVjb3ZlcnkgPSB7fVxuICAgIHRoaXMuam9pbkNhbGxiYWNrKCgpID0+IHtcbiAgICAgIHRoaXMucGVuZGluZ0pvaW5PcHMuZm9yRWFjaCgoW3ZpZXcsIG9wXSkgPT4ge1xuICAgICAgICBpZighdmlldy5pc0Rlc3Ryb3llZCgpKXsgb3AoKSB9XG4gICAgICB9KVxuICAgICAgdGhpcy5wZW5kaW5nSm9pbk9wcyA9IFtdXG4gICAgfSlcbiAgfVxuXG4gIHVwZGF0ZShkaWZmLCBldmVudHMpe1xuICAgIGlmKHRoaXMuaXNKb2luUGVuZGluZygpIHx8ICh0aGlzLmxpdmVTb2NrZXQuaGFzUGVuZGluZ0xpbmsoKSAmJiB0aGlzLnJvb3QuaXNNYWluKCkpKXtcbiAgICAgIHJldHVybiB0aGlzLnBlbmRpbmdEaWZmcy5wdXNoKHtkaWZmLCBldmVudHN9KVxuICAgIH1cblxuICAgIHRoaXMucmVuZGVyZWQubWVyZ2VEaWZmKGRpZmYpXG4gICAgbGV0IHBoeENoaWxkcmVuQWRkZWQgPSBmYWxzZVxuXG4gICAgLy8gV2hlbiB0aGUgZGlmZiBvbmx5IGNvbnRhaW5zIGNvbXBvbmVudCBkaWZmcywgdGhlbiB3YWxrIGNvbXBvbmVudHNcbiAgICAvLyBhbmQgcGF0Y2ggb25seSB0aGUgcGFyZW50IGNvbXBvbmVudCBjb250YWluZXJzIGZvdW5kIGluIHRoZSBkaWZmLlxuICAgIC8vIE90aGVyd2lzZSwgcGF0Y2ggZW50aXJlIExWIGNvbnRhaW5lci5cbiAgICBpZih0aGlzLnJlbmRlcmVkLmlzQ29tcG9uZW50T25seURpZmYoZGlmZikpe1xuICAgICAgdGhpcy5saXZlU29ja2V0LnRpbWUoXCJjb21wb25lbnQgcGF0Y2ggY29tcGxldGVcIiwgKCkgPT4ge1xuICAgICAgICBsZXQgcGFyZW50Q2lkcyA9IERPTS5maW5kRXhpc3RpbmdQYXJlbnRDSURzKHRoaXMuZWwsIHRoaXMucmVuZGVyZWQuY29tcG9uZW50Q0lEcyhkaWZmKSlcbiAgICAgICAgcGFyZW50Q2lkcy5mb3JFYWNoKHBhcmVudENJRCA9PiB7XG4gICAgICAgICAgaWYodGhpcy5jb21wb25lbnRQYXRjaCh0aGlzLnJlbmRlcmVkLmdldENvbXBvbmVudChkaWZmLCBwYXJlbnRDSUQpLCBwYXJlbnRDSUQpKXsgcGh4Q2hpbGRyZW5BZGRlZCA9IHRydWUgfVxuICAgICAgICB9KVxuICAgICAgfSlcbiAgICB9IGVsc2UgaWYoIWlzRW1wdHkoZGlmZikpe1xuICAgICAgdGhpcy5saXZlU29ja2V0LnRpbWUoXCJmdWxsIHBhdGNoIGNvbXBsZXRlXCIsICgpID0+IHtcbiAgICAgICAgbGV0IFtodG1sLCBzdHJlYW1zXSA9IHRoaXMucmVuZGVyQ29udGFpbmVyKGRpZmYsIFwidXBkYXRlXCIpXG4gICAgICAgIGxldCBwYXRjaCA9IG5ldyBET01QYXRjaCh0aGlzLCB0aGlzLmVsLCB0aGlzLmlkLCBodG1sLCBzdHJlYW1zLCBudWxsKVxuICAgICAgICBwaHhDaGlsZHJlbkFkZGVkID0gdGhpcy5wZXJmb3JtUGF0Y2gocGF0Y2gsIHRydWUpXG4gICAgICB9KVxuICAgIH1cblxuICAgIHRoaXMubGl2ZVNvY2tldC5kaXNwYXRjaEV2ZW50cyhldmVudHMpXG4gICAgaWYocGh4Q2hpbGRyZW5BZGRlZCl7IHRoaXMuam9pbk5ld0NoaWxkcmVuKCkgfVxuICB9XG5cbiAgcmVuZGVyQ29udGFpbmVyKGRpZmYsIGtpbmQpe1xuICAgIHJldHVybiB0aGlzLmxpdmVTb2NrZXQudGltZShgdG9TdHJpbmcgZGlmZiAoJHtraW5kfSlgLCAoKSA9PiB7XG4gICAgICBsZXQgdGFnID0gdGhpcy5lbC50YWdOYW1lXG4gICAgICAvLyBEb24ndCBza2lwIGFueSBjb21wb25lbnQgaW4gdGhlIGRpZmYgbm9yIGFueSBtYXJrZWQgYXMgcHJ1bmVkXG4gICAgICAvLyAoYXMgdGhleSBtYXkgaGF2ZSBiZWVuIGFkZGVkIGJhY2spXG4gICAgICBsZXQgY2lkcyA9IGRpZmYgPyB0aGlzLnJlbmRlcmVkLmNvbXBvbmVudENJRHMoZGlmZikgOiBudWxsXG4gICAgICBsZXQgW2h0bWwsIHN0cmVhbXNdID0gdGhpcy5yZW5kZXJlZC50b1N0cmluZyhjaWRzKVxuICAgICAgcmV0dXJuIFtgPCR7dGFnfT4ke2h0bWx9PC8ke3RhZ30+YCwgc3RyZWFtc11cbiAgICB9KVxuICB9XG5cbiAgY29tcG9uZW50UGF0Y2goZGlmZiwgY2lkKXtcbiAgICBpZihpc0VtcHR5KGRpZmYpKSByZXR1cm4gZmFsc2VcbiAgICBsZXQgW2h0bWwsIHN0cmVhbXNdID0gdGhpcy5yZW5kZXJlZC5jb21wb25lbnRUb1N0cmluZyhjaWQpXG4gICAgbGV0IHBhdGNoID0gbmV3IERPTVBhdGNoKHRoaXMsIHRoaXMuZWwsIHRoaXMuaWQsIGh0bWwsIHN0cmVhbXMsIGNpZClcbiAgICBsZXQgY2hpbGRyZW5BZGRlZCA9IHRoaXMucGVyZm9ybVBhdGNoKHBhdGNoLCB0cnVlKVxuICAgIHJldHVybiBjaGlsZHJlbkFkZGVkXG4gIH1cblxuICBnZXRIb29rKGVsKXsgcmV0dXJuIHRoaXMudmlld0hvb2tzW1ZpZXdIb29rLmVsZW1lbnRJRChlbCldIH1cblxuICBhZGRIb29rKGVsKXtcbiAgICBpZihWaWV3SG9vay5lbGVtZW50SUQoZWwpIHx8ICFlbC5nZXRBdHRyaWJ1dGUpeyByZXR1cm4gfVxuICAgIGxldCBob29rTmFtZSA9IGVsLmdldEF0dHJpYnV0ZShgZGF0YS1waHgtJHtQSFhfSE9PS31gKSB8fCBlbC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9IT09LKSlcbiAgICBpZihob29rTmFtZSAmJiAhdGhpcy5vd25zRWxlbWVudChlbCkpeyByZXR1cm4gfVxuICAgIGxldCBjYWxsYmFja3MgPSB0aGlzLmxpdmVTb2NrZXQuZ2V0SG9va0NhbGxiYWNrcyhob29rTmFtZSlcblxuICAgIGlmKGNhbGxiYWNrcyl7XG4gICAgICBpZighZWwuaWQpeyBsb2dFcnJvcihgbm8gRE9NIElEIGZvciBob29rIFwiJHtob29rTmFtZX1cIi4gSG9va3MgcmVxdWlyZSBhIHVuaXF1ZSBJRCBvbiBlYWNoIGVsZW1lbnQuYCwgZWwpIH1cbiAgICAgIGxldCBob29rID0gbmV3IFZpZXdIb29rKHRoaXMsIGVsLCBjYWxsYmFja3MpXG4gICAgICB0aGlzLnZpZXdIb29rc1tWaWV3SG9vay5lbGVtZW50SUQoaG9vay5lbCldID0gaG9va1xuICAgICAgcmV0dXJuIGhvb2tcbiAgICB9IGVsc2UgaWYoaG9va05hbWUgIT09IG51bGwpe1xuICAgICAgbG9nRXJyb3IoYHVua25vd24gaG9vayBmb3VuZCBmb3IgXCIke2hvb2tOYW1lfVwiYCwgZWwpXG4gICAgfVxuICB9XG5cbiAgZGVzdHJveUhvb2soaG9vayl7XG4gICAgaG9vay5fX2Rlc3Ryb3llZCgpXG4gICAgaG9vay5fX2NsZWFudXBfXygpXG4gICAgZGVsZXRlIHRoaXMudmlld0hvb2tzW1ZpZXdIb29rLmVsZW1lbnRJRChob29rLmVsKV1cbiAgfVxuXG4gIGFwcGx5UGVuZGluZ1VwZGF0ZXMoKXtcbiAgICB0aGlzLnBlbmRpbmdEaWZmcy5mb3JFYWNoKCh7ZGlmZiwgZXZlbnRzfSkgPT4gdGhpcy51cGRhdGUoZGlmZiwgZXZlbnRzKSlcbiAgICB0aGlzLnBlbmRpbmdEaWZmcyA9IFtdXG4gICAgdGhpcy5lYWNoQ2hpbGQoY2hpbGQgPT4gY2hpbGQuYXBwbHlQZW5kaW5nVXBkYXRlcygpKVxuICB9XG5cbiAgZWFjaENoaWxkKGNhbGxiYWNrKXtcbiAgICBsZXQgY2hpbGRyZW4gPSB0aGlzLnJvb3QuY2hpbGRyZW5bdGhpcy5pZF0gfHwge31cbiAgICBmb3IobGV0IGlkIGluIGNoaWxkcmVuKXsgY2FsbGJhY2sodGhpcy5nZXRDaGlsZEJ5SWQoaWQpKSB9XG4gIH1cblxuICBvbkNoYW5uZWwoZXZlbnQsIGNiKXtcbiAgICB0aGlzLmxpdmVTb2NrZXQub25DaGFubmVsKHRoaXMuY2hhbm5lbCwgZXZlbnQsIHJlc3AgPT4ge1xuICAgICAgaWYodGhpcy5pc0pvaW5QZW5kaW5nKCkpe1xuICAgICAgICB0aGlzLnJvb3QucGVuZGluZ0pvaW5PcHMucHVzaChbdGhpcywgKCkgPT4gY2IocmVzcCldKVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgdGhpcy5saXZlU29ja2V0LnJlcXVlc3RET01VcGRhdGUoKCkgPT4gY2IocmVzcCkpXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIGJpbmRDaGFubmVsKCl7XG4gICAgLy8gVGhlIGRpZmYgZXZlbnQgc2hvdWxkIGJlIGhhbmRsZWQgYnkgdGhlIHJlZ3VsYXIgdXBkYXRlIG9wZXJhdGlvbnMuXG4gICAgLy8gQWxsIG90aGVyIG9wZXJhdGlvbnMgYXJlIHF1ZXVlZCB0byBiZSBhcHBsaWVkIG9ubHkgYWZ0ZXIgam9pbi5cbiAgICB0aGlzLmxpdmVTb2NrZXQub25DaGFubmVsKHRoaXMuY2hhbm5lbCwgXCJkaWZmXCIsIChyYXdEaWZmKSA9PiB7XG4gICAgICB0aGlzLmxpdmVTb2NrZXQucmVxdWVzdERPTVVwZGF0ZSgoKSA9PiB7XG4gICAgICAgIHRoaXMuYXBwbHlEaWZmKFwidXBkYXRlXCIsIHJhd0RpZmYsICh7ZGlmZiwgZXZlbnRzfSkgPT4gdGhpcy51cGRhdGUoZGlmZiwgZXZlbnRzKSlcbiAgICAgIH0pXG4gICAgfSlcbiAgICB0aGlzLm9uQ2hhbm5lbChcInJlZGlyZWN0XCIsICh7dG8sIGZsYXNofSkgPT4gdGhpcy5vblJlZGlyZWN0KHt0bywgZmxhc2h9KSlcbiAgICB0aGlzLm9uQ2hhbm5lbChcImxpdmVfcGF0Y2hcIiwgKHJlZGlyKSA9PiB0aGlzLm9uTGl2ZVBhdGNoKHJlZGlyKSlcbiAgICB0aGlzLm9uQ2hhbm5lbChcImxpdmVfcmVkaXJlY3RcIiwgKHJlZGlyKSA9PiB0aGlzLm9uTGl2ZVJlZGlyZWN0KHJlZGlyKSlcbiAgICB0aGlzLmNoYW5uZWwub25FcnJvcihyZWFzb24gPT4gdGhpcy5vbkVycm9yKHJlYXNvbikpXG4gICAgdGhpcy5jaGFubmVsLm9uQ2xvc2UocmVhc29uID0+IHRoaXMub25DbG9zZShyZWFzb24pKVxuICB9XG5cbiAgZGVzdHJveUFsbENoaWxkcmVuKCl7IHRoaXMuZWFjaENoaWxkKGNoaWxkID0+IGNoaWxkLmRlc3Ryb3koKSkgfVxuXG4gIG9uTGl2ZVJlZGlyZWN0KHJlZGlyKXtcbiAgICBsZXQge3RvLCBraW5kLCBmbGFzaH0gPSByZWRpclxuICAgIGxldCB1cmwgPSB0aGlzLmV4cGFuZFVSTCh0bylcbiAgICB0aGlzLmxpdmVTb2NrZXQuaGlzdG9yeVJlZGlyZWN0KHVybCwga2luZCwgZmxhc2gpXG4gIH1cblxuICBvbkxpdmVQYXRjaChyZWRpcil7XG4gICAgbGV0IHt0bywga2luZH0gPSByZWRpclxuICAgIHRoaXMuaHJlZiA9IHRoaXMuZXhwYW5kVVJMKHRvKVxuICAgIHRoaXMubGl2ZVNvY2tldC5oaXN0b3J5UGF0Y2godG8sIGtpbmQpXG4gIH1cblxuICBleHBhbmRVUkwodG8pe1xuICAgIHJldHVybiB0by5zdGFydHNXaXRoKFwiL1wiKSA/IGAke3dpbmRvdy5sb2NhdGlvbi5wcm90b2NvbH0vLyR7d2luZG93LmxvY2F0aW9uLmhvc3R9JHt0b31gIDogdG9cbiAgfVxuXG4gIG9uUmVkaXJlY3Qoe3RvLCBmbGFzaH0peyB0aGlzLmxpdmVTb2NrZXQucmVkaXJlY3QodG8sIGZsYXNoKSB9XG5cbiAgaXNEZXN0cm95ZWQoKXsgcmV0dXJuIHRoaXMuZGVzdHJveWVkIH1cblxuICBqb2luRGVhZCgpeyB0aGlzLmlzRGVhZCA9IHRydWUgfVxuXG4gIGpvaW4oY2FsbGJhY2spe1xuICAgIHRoaXMuc2hvd0xvYWRlcih0aGlzLmxpdmVTb2NrZXQubG9hZGVyVGltZW91dClcbiAgICB0aGlzLmJpbmRDaGFubmVsKClcbiAgICBpZih0aGlzLmlzTWFpbigpKXtcbiAgICAgIHRoaXMuc3RvcENhbGxiYWNrID0gdGhpcy5saXZlU29ja2V0LndpdGhQYWdlTG9hZGluZyh7dG86IHRoaXMuaHJlZiwga2luZDogXCJpbml0aWFsXCJ9KVxuICAgIH1cbiAgICB0aGlzLmpvaW5DYWxsYmFjayA9IChvbkRvbmUpID0+IHtcbiAgICAgIG9uRG9uZSA9IG9uRG9uZSB8fCBmdW5jdGlvbigpe31cbiAgICAgIGNhbGxiYWNrID8gY2FsbGJhY2sodGhpcy5qb2luQ291bnQsIG9uRG9uZSkgOiBvbkRvbmUoKVxuICAgIH1cbiAgICB0aGlzLmxpdmVTb2NrZXQud3JhcFB1c2godGhpcywge3RpbWVvdXQ6IGZhbHNlfSwgKCkgPT4ge1xuICAgICAgcmV0dXJuIHRoaXMuY2hhbm5lbC5qb2luKClcbiAgICAgICAgLnJlY2VpdmUoXCJva1wiLCBkYXRhID0+IHtcbiAgICAgICAgICBpZighdGhpcy5pc0Rlc3Ryb3llZCgpKXtcbiAgICAgICAgICAgIHRoaXMubGl2ZVNvY2tldC5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHRoaXMub25Kb2luKGRhdGEpKVxuICAgICAgICAgIH1cbiAgICAgICAgfSlcbiAgICAgICAgLnJlY2VpdmUoXCJlcnJvclwiLCByZXNwID0+ICF0aGlzLmlzRGVzdHJveWVkKCkgJiYgdGhpcy5vbkpvaW5FcnJvcihyZXNwKSlcbiAgICAgICAgLnJlY2VpdmUoXCJ0aW1lb3V0XCIsICgpID0+ICF0aGlzLmlzRGVzdHJveWVkKCkgJiYgdGhpcy5vbkpvaW5FcnJvcih7cmVhc29uOiBcInRpbWVvdXRcIn0pKVxuICAgIH0pXG4gIH1cblxuICBvbkpvaW5FcnJvcihyZXNwKXtcbiAgICBpZihyZXNwLnJlYXNvbiA9PT0gXCJyZWxvYWRcIil7XG4gICAgICB0aGlzLmxvZyhcImVycm9yXCIsICgpID0+IFtgZmFpbGVkIG1vdW50IHdpdGggJHtyZXNwLnN0YXR1c30uIEZhbGxpbmcgYmFjayB0byBwYWdlIHJlcXVlc3RgLCByZXNwXSlcbiAgICAgIGlmKHRoaXMuaXNNYWluKCkpeyB0aGlzLm9uUmVkaXJlY3Qoe3RvOiB0aGlzLmhyZWZ9KSB9XG4gICAgICByZXR1cm5cbiAgICB9IGVsc2UgaWYocmVzcC5yZWFzb24gPT09IFwidW5hdXRob3JpemVkXCIgfHwgcmVzcC5yZWFzb24gPT09IFwic3RhbGVcIil7XG4gICAgICB0aGlzLmxvZyhcImVycm9yXCIsICgpID0+IFtcInVuYXV0aG9yaXplZCBsaXZlX3JlZGlyZWN0LiBGYWxsaW5nIGJhY2sgdG8gcGFnZSByZXF1ZXN0XCIsIHJlc3BdKVxuICAgICAgaWYodGhpcy5pc01haW4oKSl7IHRoaXMub25SZWRpcmVjdCh7dG86IHRoaXMuaHJlZn0pIH1cbiAgICAgIHJldHVyblxuICAgIH1cbiAgICBpZihyZXNwLnJlZGlyZWN0IHx8IHJlc3AubGl2ZV9yZWRpcmVjdCl7XG4gICAgICB0aGlzLmpvaW5QZW5kaW5nID0gZmFsc2VcbiAgICAgIHRoaXMuY2hhbm5lbC5sZWF2ZSgpXG4gICAgfVxuICAgIGlmKHJlc3AucmVkaXJlY3QpeyByZXR1cm4gdGhpcy5vblJlZGlyZWN0KHJlc3AucmVkaXJlY3QpIH1cbiAgICBpZihyZXNwLmxpdmVfcmVkaXJlY3QpeyByZXR1cm4gdGhpcy5vbkxpdmVSZWRpcmVjdChyZXNwLmxpdmVfcmVkaXJlY3QpIH1cbiAgICB0aGlzLmRpc3BsYXlFcnJvcihbUEhYX0xPQURJTkdfQ0xBU1MsIFBIWF9FUlJPUl9DTEFTUywgUEhYX1NFUlZFUl9FUlJPUl9DTEFTU10pXG4gICAgdGhpcy5sb2coXCJlcnJvclwiLCAoKSA9PiBbXCJ1bmFibGUgdG8gam9pblwiLCByZXNwXSlcbiAgICBpZih0aGlzLmxpdmVTb2NrZXQuaXNDb25uZWN0ZWQoKSl7IHRoaXMubGl2ZVNvY2tldC5yZWxvYWRXaXRoSml0dGVyKHRoaXMpIH1cbiAgfVxuXG4gIG9uQ2xvc2UocmVhc29uKXtcbiAgICBpZih0aGlzLmlzRGVzdHJveWVkKCkpeyByZXR1cm4gfVxuICAgIGlmKHRoaXMubGl2ZVNvY2tldC5oYXNQZW5kaW5nTGluaygpICYmIHJlYXNvbiAhPT0gXCJsZWF2ZVwiKXtcbiAgICAgIHJldHVybiB0aGlzLmxpdmVTb2NrZXQucmVsb2FkV2l0aEppdHRlcih0aGlzKVxuICAgIH1cbiAgICB0aGlzLmRlc3Ryb3lBbGxDaGlsZHJlbigpXG4gICAgdGhpcy5saXZlU29ja2V0LmRyb3BBY3RpdmVFbGVtZW50KHRoaXMpXG4gICAgLy8gZG9jdW1lbnQuYWN0aXZlRWxlbWVudCBjYW4gYmUgbnVsbCBpbiBJbnRlcm5ldCBFeHBsb3JlciAxMVxuICAgIGlmKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpeyBkb2N1bWVudC5hY3RpdmVFbGVtZW50LmJsdXIoKSB9XG4gICAgaWYodGhpcy5saXZlU29ja2V0LmlzVW5sb2FkZWQoKSl7XG4gICAgICB0aGlzLnNob3dMb2FkZXIoQkVGT1JFX1VOTE9BRF9MT0FERVJfVElNRU9VVClcbiAgICB9XG4gIH1cblxuICBvbkVycm9yKHJlYXNvbil7XG4gICAgdGhpcy5vbkNsb3NlKHJlYXNvbilcbiAgICBpZih0aGlzLmxpdmVTb2NrZXQuaXNDb25uZWN0ZWQoKSl7IHRoaXMubG9nKFwiZXJyb3JcIiwgKCkgPT4gW1widmlldyBjcmFzaGVkXCIsIHJlYXNvbl0pIH1cbiAgICBpZighdGhpcy5saXZlU29ja2V0LmlzVW5sb2FkZWQoKSl7XG4gICAgICBpZih0aGlzLmxpdmVTb2NrZXQuaXNDb25uZWN0ZWQoKSl7XG4gICAgICAgIHRoaXMuZGlzcGxheUVycm9yKFtQSFhfTE9BRElOR19DTEFTUywgUEhYX0VSUk9SX0NMQVNTLCBQSFhfU0VSVkVSX0VSUk9SX0NMQVNTXSlcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHRoaXMuZGlzcGxheUVycm9yKFtQSFhfTE9BRElOR19DTEFTUywgUEhYX0VSUk9SX0NMQVNTLCBQSFhfQ0xJRU5UX0VSUk9SX0NMQVNTXSlcbiAgICAgIH1cbiAgICB9XG4gIH1cblxuICBkaXNwbGF5RXJyb3IoY2xhc3Nlcyl7XG4gICAgaWYodGhpcy5pc01haW4oKSl7IERPTS5kaXNwYXRjaEV2ZW50KHdpbmRvdywgXCJwaHg6cGFnZS1sb2FkaW5nLXN0YXJ0XCIsIHtkZXRhaWw6IHt0bzogdGhpcy5ocmVmLCBraW5kOiBcImVycm9yXCJ9fSkgfVxuICAgIHRoaXMuc2hvd0xvYWRlcigpXG4gICAgdGhpcy5zZXRDb250YWluZXJDbGFzc2VzKC4uLmNsYXNzZXMpXG4gICAgdGhpcy5leGVjQWxsKHRoaXMuYmluZGluZyhcImRpc2Nvbm5lY3RlZFwiKSlcbiAgfVxuXG4gIHB1c2hXaXRoUmVwbHkocmVmR2VuZXJhdG9yLCBldmVudCwgcGF5bG9hZCwgb25SZXBseSA9IGZ1bmN0aW9uICgpeyB9KXtcbiAgICBpZighdGhpcy5pc0Nvbm5lY3RlZCgpKXsgcmV0dXJuIH1cblxuICAgIGxldCBbcmVmLCBbZWxdLCBvcHRzXSA9IHJlZkdlbmVyYXRvciA/IHJlZkdlbmVyYXRvcigpIDogW251bGwsIFtdLCB7fV1cbiAgICBsZXQgb25Mb2FkaW5nRG9uZSA9IGZ1bmN0aW9uKCl7IH1cbiAgICBpZihvcHRzLnBhZ2VfbG9hZGluZyB8fCAoZWwgJiYgKGVsLmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoUEhYX1BBR0VfTE9BRElORykpICE9PSBudWxsKSkpe1xuICAgICAgb25Mb2FkaW5nRG9uZSA9IHRoaXMubGl2ZVNvY2tldC53aXRoUGFnZUxvYWRpbmcoe2tpbmQ6IFwiZWxlbWVudFwiLCB0YXJnZXQ6IGVsfSlcbiAgICB9XG5cbiAgICBpZih0eXBlb2YgKHBheWxvYWQuY2lkKSAhPT0gXCJudW1iZXJcIil7IGRlbGV0ZSBwYXlsb2FkLmNpZCB9XG4gICAgcmV0dXJuIChcbiAgICAgIHRoaXMubGl2ZVNvY2tldC53cmFwUHVzaCh0aGlzLCB7dGltZW91dDogdHJ1ZX0sICgpID0+IHtcbiAgICAgICAgcmV0dXJuIHRoaXMuY2hhbm5lbC5wdXNoKGV2ZW50LCBwYXlsb2FkLCBQVVNIX1RJTUVPVVQpLnJlY2VpdmUoXCJva1wiLCByZXNwID0+IHtcbiAgICAgICAgICBsZXQgZmluaXNoID0gKGhvb2tSZXBseSkgPT4ge1xuICAgICAgICAgICAgaWYocmVzcC5yZWRpcmVjdCl7IHRoaXMub25SZWRpcmVjdChyZXNwLnJlZGlyZWN0KSB9XG4gICAgICAgICAgICBpZihyZXNwLmxpdmVfcGF0Y2gpeyB0aGlzLm9uTGl2ZVBhdGNoKHJlc3AubGl2ZV9wYXRjaCkgfVxuICAgICAgICAgICAgaWYocmVzcC5saXZlX3JlZGlyZWN0KXsgdGhpcy5vbkxpdmVSZWRpcmVjdChyZXNwLmxpdmVfcmVkaXJlY3QpIH1cbiAgICAgICAgICAgIG9uTG9hZGluZ0RvbmUoKVxuICAgICAgICAgICAgb25SZXBseShyZXNwLCBob29rUmVwbHkpXG4gICAgICAgICAgfVxuICAgICAgICAgIGlmKHJlc3AuZGlmZil7XG4gICAgICAgICAgICB0aGlzLmxpdmVTb2NrZXQucmVxdWVzdERPTVVwZGF0ZSgoKSA9PiB7XG4gICAgICAgICAgICAgIHRoaXMuYXBwbHlEaWZmKFwidXBkYXRlXCIsIHJlc3AuZGlmZiwgKHtkaWZmLCByZXBseSwgZXZlbnRzfSkgPT4ge1xuICAgICAgICAgICAgICAgIGlmKHJlZiAhPT0gbnVsbCl7IHRoaXMudW5kb1JlZnMocmVmKSB9XG4gICAgICAgICAgICAgICAgdGhpcy51cGRhdGUoZGlmZiwgZXZlbnRzKVxuICAgICAgICAgICAgICAgIGZpbmlzaChyZXBseSlcbiAgICAgICAgICAgICAgfSlcbiAgICAgICAgICAgIH0pXG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGlmKHJlZiAhPT0gbnVsbCl7IHRoaXMudW5kb1JlZnMocmVmKSB9XG4gICAgICAgICAgICBmaW5pc2gobnVsbClcbiAgICAgICAgICB9XG4gICAgICAgIH0pXG4gICAgICB9KVxuICAgIClcbiAgfVxuXG4gIHVuZG9SZWZzKHJlZiwgb25seUVscyl7XG4gICAgb25seUVscyA9IG9ubHlFbHMgPyBuZXcgU2V0KG9ubHlFbHMpIDogbnVsbFxuICAgIGlmKCF0aGlzLmlzQ29ubmVjdGVkKCkpeyByZXR1cm4gfSAvLyBleGl0IGlmIGV4dGVybmFsIGZvcm0gdHJpZ2dlcmVkXG5cbiAgICBET00uYWxsKGRvY3VtZW50LCBgWyR7UEhYX1JFRl9TUkN9PVwiJHt0aGlzLmlkfVwiXVske1BIWF9SRUZ9PVwiJHtyZWZ9XCJdYCwgZWwgPT4ge1xuICAgICAgaWYob25seUVscyAmJiAhb25seUVscy5oYXMoZWwpKXsgcmV0dXJuIH1cblxuICAgICAgZWwuZGlzcGF0Y2hFdmVudChuZXcgQ3VzdG9tRXZlbnQoXCJwaHg6dW5sb2NrXCIsIHtidWJibGVzOiB0cnVlLCBjYW5jZWxhYmxlOiBmYWxzZX0pKVxuICAgICAgbGV0IGRpc2FibGVkVmFsID0gZWwuZ2V0QXR0cmlidXRlKFBIWF9ESVNBQkxFRClcbiAgICAgIGxldCByZWFkT25seVZhbCA9IGVsLmdldEF0dHJpYnV0ZShQSFhfUkVBRE9OTFkpXG4gICAgICAvLyByZW1vdmUgcmVmc1xuICAgICAgZWwucmVtb3ZlQXR0cmlidXRlKFBIWF9SRUYpXG4gICAgICBlbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1JFRl9TUkMpXG4gICAgICAvLyByZXN0b3JlIGlucHV0c1xuICAgICAgaWYocmVhZE9ubHlWYWwgIT09IG51bGwpe1xuICAgICAgICBlbC5yZWFkT25seSA9IHJlYWRPbmx5VmFsID09PSBcInRydWVcIiA/IHRydWUgOiBmYWxzZVxuICAgICAgICBlbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX1JFQURPTkxZKVxuICAgICAgfVxuICAgICAgaWYoZGlzYWJsZWRWYWwgIT09IG51bGwpe1xuICAgICAgICBlbC5kaXNhYmxlZCA9IGRpc2FibGVkVmFsID09PSBcInRydWVcIiA/IHRydWUgOiBmYWxzZVxuICAgICAgICBlbC5yZW1vdmVBdHRyaWJ1dGUoUEhYX0RJU0FCTEVEKVxuICAgICAgfVxuICAgICAgLy8gcmVtb3ZlIGNsYXNzZXNcbiAgICAgIFBIWF9FVkVOVF9DTEFTU0VTLmZvckVhY2goY2xhc3NOYW1lID0+IERPTS5yZW1vdmVDbGFzcyhlbCwgY2xhc3NOYW1lKSlcbiAgICAgIC8vIHJlc3RvcmUgZGlzYWJsZXNcbiAgICAgIGxldCBkaXNhYmxlUmVzdG9yZSA9IGVsLmdldEF0dHJpYnV0ZShQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUpXG4gICAgICBpZihkaXNhYmxlUmVzdG9yZSAhPT0gbnVsbCl7XG4gICAgICAgIGVsLmlubmVyVGV4dCA9IGRpc2FibGVSZXN0b3JlXG4gICAgICAgIGVsLnJlbW92ZUF0dHJpYnV0ZShQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUpXG4gICAgICB9XG4gICAgICBsZXQgdG9FbCA9IERPTS5wcml2YXRlKGVsLCBQSFhfUkVGKVxuICAgICAgaWYodG9FbCl7XG4gICAgICAgIGxldCBob29rID0gdGhpcy50cmlnZ2VyQmVmb3JlVXBkYXRlSG9vayhlbCwgdG9FbClcbiAgICAgICAgRE9NUGF0Y2gucGF0Y2hFbChlbCwgdG9FbCwgdGhpcy5saXZlU29ja2V0LmdldEFjdGl2ZUVsZW1lbnQoKSlcbiAgICAgICAgaWYoaG9vayl7IGhvb2suX191cGRhdGVkKCkgfVxuICAgICAgICBET00uZGVsZXRlUHJpdmF0ZShlbCwgUEhYX1JFRilcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgcHV0UmVmKGVsZW1lbnRzLCBldmVudCwgb3B0cyA9IHt9KXtcbiAgICBsZXQgbmV3UmVmID0gdGhpcy5yZWYrK1xuICAgIGxldCBkaXNhYmxlV2l0aCA9IHRoaXMuYmluZGluZyhQSFhfRElTQUJMRV9XSVRIKVxuICAgIGlmKG9wdHMubG9hZGluZyl7IGVsZW1lbnRzID0gZWxlbWVudHMuY29uY2F0KERPTS5hbGwoZG9jdW1lbnQsIG9wdHMubG9hZGluZykpfVxuXG4gICAgZm9yKGxldCBlbCBvZiBlbGVtZW50cyl7XG4gICAgICBlbC5zZXRBdHRyaWJ1dGUoUEhYX1JFRiwgbmV3UmVmKVxuICAgICAgZWwuc2V0QXR0cmlidXRlKFBIWF9SRUZfU1JDLCB0aGlzLmVsLmlkKVxuICAgICAgaWYob3B0cy5zdWJtaXR0ZXIgJiYgIShlbCA9PT0gb3B0cy5zdWJtaXR0ZXIgfHwgZWwgPT09IG9wdHMuZm9ybSkpeyBjb250aW51ZSB9XG5cbiAgICAgIGVsLmNsYXNzTGlzdC5hZGQoYHBoeC0ke2V2ZW50fS1sb2FkaW5nYClcbiAgICAgIGVsLmRpc3BhdGNoRXZlbnQobmV3IEN1c3RvbUV2ZW50KGBwaHg6JHtldmVudH0tbG9hZGluZ2AsIHtidWJibGVzOiB0cnVlLCBjYW5jZWxhYmxlOiBmYWxzZX0pKVxuICAgICAgbGV0IGRpc2FibGVUZXh0ID0gZWwuZ2V0QXR0cmlidXRlKGRpc2FibGVXaXRoKVxuICAgICAgaWYoZGlzYWJsZVRleHQgIT09IG51bGwpe1xuICAgICAgICBpZighZWwuZ2V0QXR0cmlidXRlKFBIWF9ESVNBQkxFX1dJVEhfUkVTVE9SRSkpe1xuICAgICAgICAgIGVsLnNldEF0dHJpYnV0ZShQSFhfRElTQUJMRV9XSVRIX1JFU1RPUkUsIGVsLmlubmVyVGV4dClcbiAgICAgICAgfVxuICAgICAgICBpZihkaXNhYmxlVGV4dCAhPT0gXCJcIil7IGVsLmlubmVyVGV4dCA9IGRpc2FibGVUZXh0IH1cbiAgICAgICAgLy8gUEhYX0RJU0FCTEVEIGNvdWxkIGhhdmUgYWxyZWFkeSBiZWVuIHNldCBpbiBkaXNhYmxlRm9ybVxuICAgICAgICBlbC5zZXRBdHRyaWJ1dGUoUEhYX0RJU0FCTEVELCBlbC5nZXRBdHRyaWJ1dGUoUEhYX0RJU0FCTEVEKSB8fCBlbC5kaXNhYmxlZClcbiAgICAgICAgZWwuc2V0QXR0cmlidXRlKFwiZGlzYWJsZWRcIiwgXCJcIilcbiAgICAgIH1cbiAgICB9XG4gICAgcmV0dXJuIFtuZXdSZWYsIGVsZW1lbnRzLCBvcHRzXVxuICB9XG5cbiAgY29tcG9uZW50SUQoZWwpe1xuICAgIGxldCBjaWQgPSBlbC5nZXRBdHRyaWJ1dGUgJiYgZWwuZ2V0QXR0cmlidXRlKFBIWF9DT01QT05FTlQpXG4gICAgcmV0dXJuIGNpZCA/IHBhcnNlSW50KGNpZCkgOiBudWxsXG4gIH1cblxuICB0YXJnZXRDb21wb25lbnRJRCh0YXJnZXQsIHRhcmdldEN0eCwgb3B0cyA9IHt9KXtcbiAgICBpZihpc0NpZCh0YXJnZXRDdHgpKXsgcmV0dXJuIHRhcmdldEN0eCB9XG5cbiAgICBsZXQgY2lkT3JTZWxlY3RvciA9IG9wdHMudGFyZ2V0IHx8IHRhcmdldC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFwidGFyZ2V0XCIpKVxuICAgIGlmKGlzQ2lkKGNpZE9yU2VsZWN0b3IpKXtcbiAgICAgIHJldHVybiBwYXJzZUludChjaWRPclNlbGVjdG9yKVxuICAgIH0gZWxzZSBpZih0YXJnZXRDdHggJiYgKGNpZE9yU2VsZWN0b3IgIT09IG51bGwgfHwgb3B0cy50YXJnZXQpKXtcbiAgICAgIHJldHVybiB0aGlzLmNsb3Nlc3RDb21wb25lbnRJRCh0YXJnZXRDdHgpXG4gICAgfSBlbHNlIHtcbiAgICAgIHJldHVybiBudWxsXG4gICAgfVxuICB9XG5cbiAgY2xvc2VzdENvbXBvbmVudElEKHRhcmdldEN0eCl7XG4gICAgaWYoaXNDaWQodGFyZ2V0Q3R4KSl7XG4gICAgICByZXR1cm4gdGFyZ2V0Q3R4XG4gICAgfSBlbHNlIGlmKHRhcmdldEN0eCl7XG4gICAgICByZXR1cm4gbWF5YmUodGFyZ2V0Q3R4LmNsb3Nlc3QoYFske1BIWF9DT01QT05FTlR9XWApLCBlbCA9PiB0aGlzLm93bnNFbGVtZW50KGVsKSAmJiB0aGlzLmNvbXBvbmVudElEKGVsKSlcbiAgICB9IGVsc2Uge1xuICAgICAgcmV0dXJuIG51bGxcbiAgICB9XG4gIH1cblxuICBwdXNoSG9va0V2ZW50KGVsLCB0YXJnZXRDdHgsIGV2ZW50LCBwYXlsb2FkLCBvblJlcGx5KXtcbiAgICBpZighdGhpcy5pc0Nvbm5lY3RlZCgpKXtcbiAgICAgIHRoaXMubG9nKFwiaG9va1wiLCAoKSA9PiBbXCJ1bmFibGUgdG8gcHVzaCBob29rIGV2ZW50LiBMaXZlVmlldyBub3QgY29ubmVjdGVkXCIsIGV2ZW50LCBwYXlsb2FkXSlcbiAgICAgIHJldHVybiBmYWxzZVxuICAgIH1cbiAgICBsZXQgW3JlZiwgZWxzLCBvcHRzXSA9IHRoaXMucHV0UmVmKFtlbF0sIFwiaG9va1wiKVxuICAgIHRoaXMucHVzaFdpdGhSZXBseSgoKSA9PiBbcmVmLCBlbHMsIG9wdHNdLCBcImV2ZW50XCIsIHtcbiAgICAgIHR5cGU6IFwiaG9va1wiLFxuICAgICAgZXZlbnQ6IGV2ZW50LFxuICAgICAgdmFsdWU6IHBheWxvYWQsXG4gICAgICBjaWQ6IHRoaXMuY2xvc2VzdENvbXBvbmVudElEKHRhcmdldEN0eClcbiAgICB9LCAocmVzcCwgcmVwbHkpID0+IG9uUmVwbHkocmVwbHksIHJlZikpXG5cbiAgICByZXR1cm4gcmVmXG4gIH1cblxuICBleHRyYWN0TWV0YShlbCwgbWV0YSwgdmFsdWUpe1xuICAgIGxldCBwcmVmaXggPSB0aGlzLmJpbmRpbmcoXCJ2YWx1ZS1cIilcbiAgICBmb3IobGV0IGkgPSAwOyBpIDwgZWwuYXR0cmlidXRlcy5sZW5ndGg7IGkrKyl7XG4gICAgICBpZighbWV0YSl7IG1ldGEgPSB7fSB9XG4gICAgICBsZXQgbmFtZSA9IGVsLmF0dHJpYnV0ZXNbaV0ubmFtZVxuICAgICAgaWYobmFtZS5zdGFydHNXaXRoKHByZWZpeCkpeyBtZXRhW25hbWUucmVwbGFjZShwcmVmaXgsIFwiXCIpXSA9IGVsLmdldEF0dHJpYnV0ZShuYW1lKSB9XG4gICAgfVxuICAgIGlmKGVsLnZhbHVlICE9PSB1bmRlZmluZWQgJiYgIShlbCBpbnN0YW5jZW9mIEhUTUxGb3JtRWxlbWVudCkpe1xuICAgICAgaWYoIW1ldGEpeyBtZXRhID0ge30gfVxuICAgICAgbWV0YS52YWx1ZSA9IGVsLnZhbHVlXG5cbiAgICAgIGlmKGVsLnRhZ05hbWUgPT09IFwiSU5QVVRcIiAmJiBDSEVDS0FCTEVfSU5QVVRTLmluZGV4T2YoZWwudHlwZSkgPj0gMCAmJiAhZWwuY2hlY2tlZCl7XG4gICAgICAgIGRlbGV0ZSBtZXRhLnZhbHVlXG4gICAgICB9XG4gICAgfVxuICAgIGlmKHZhbHVlKXtcbiAgICAgIGlmKCFtZXRhKXsgbWV0YSA9IHt9IH1cbiAgICAgIGZvcihsZXQga2V5IGluIHZhbHVlKXsgbWV0YVtrZXldID0gdmFsdWVba2V5XSB9XG4gICAgfVxuICAgIHJldHVybiBtZXRhXG4gIH1cblxuXG4gIHB1c2hFdmVudCh0eXBlLCBlbCwgdGFyZ2V0Q3R4LCBwaHhFdmVudCwgbWV0YSwgb3B0cyA9IHt9LCBvblJlcGx5KXtcbiAgICB0aGlzLnB1c2hXaXRoUmVwbHkoKCkgPT4gdGhpcy5wdXRSZWYoW2VsXSwgdHlwZSwgb3B0cyksIFwiZXZlbnRcIiwge1xuICAgICAgdHlwZTogdHlwZSxcbiAgICAgIGV2ZW50OiBwaHhFdmVudCxcbiAgICAgIHZhbHVlOiB0aGlzLmV4dHJhY3RNZXRhKGVsLCBtZXRhLCBvcHRzLnZhbHVlKSxcbiAgICAgIGNpZDogdGhpcy50YXJnZXRDb21wb25lbnRJRChlbCwgdGFyZ2V0Q3R4LCBvcHRzKVxuICAgIH0sIChyZXNwLCByZXBseSkgPT4gb25SZXBseSAmJiBvblJlcGx5KHJlcGx5KSlcbiAgfVxuXG4gIHB1c2hGaWxlUHJvZ3Jlc3MoZmlsZUVsLCBlbnRyeVJlZiwgcHJvZ3Jlc3MsIG9uUmVwbHkgPSBmdW5jdGlvbiAoKXsgfSl7XG4gICAgdGhpcy5saXZlU29ja2V0LndpdGhpbk93bmVycyhmaWxlRWwuZm9ybSwgKHZpZXcsIHRhcmdldEN0eCkgPT4ge1xuICAgICAgdmlldy5wdXNoV2l0aFJlcGx5KG51bGwsIFwicHJvZ3Jlc3NcIiwge1xuICAgICAgICBldmVudDogZmlsZUVsLmdldEF0dHJpYnV0ZSh2aWV3LmJpbmRpbmcoUEhYX1BST0dSRVNTKSksXG4gICAgICAgIHJlZjogZmlsZUVsLmdldEF0dHJpYnV0ZShQSFhfVVBMT0FEX1JFRiksXG4gICAgICAgIGVudHJ5X3JlZjogZW50cnlSZWYsXG4gICAgICAgIHByb2dyZXNzOiBwcm9ncmVzcyxcbiAgICAgICAgY2lkOiB2aWV3LnRhcmdldENvbXBvbmVudElEKGZpbGVFbC5mb3JtLCB0YXJnZXRDdHgpXG4gICAgICB9LCBvblJlcGx5KVxuICAgIH0pXG4gIH1cblxuICBwdXNoSW5wdXQoaW5wdXRFbCwgdGFyZ2V0Q3R4LCBmb3JjZUNpZCwgcGh4RXZlbnQsIG9wdHMsIGNhbGxiYWNrKXtcbiAgICBsZXQgdXBsb2Fkc1xuICAgIGxldCBjaWQgPSBpc0NpZChmb3JjZUNpZCkgPyBmb3JjZUNpZCA6IHRoaXMudGFyZ2V0Q29tcG9uZW50SUQoaW5wdXRFbC5mb3JtLCB0YXJnZXRDdHgsIG9wdHMpXG4gICAgbGV0IHJlZkdlbmVyYXRvciA9ICgpID0+IHRoaXMucHV0UmVmKFtpbnB1dEVsLCBpbnB1dEVsLmZvcm1dLCBcImNoYW5nZVwiLCBvcHRzKVxuICAgIGxldCBmb3JtRGF0YVxuICAgIGxldCBtZXRhICA9IHRoaXMuZXh0cmFjdE1ldGEoaW5wdXRFbC5mb3JtKVxuICAgIGlmKGlucHV0RWwgaW5zdGFuY2VvZiBIVE1MQnV0dG9uRWxlbWVudCl7IG1ldGEuc3VibWl0dGVyID0gaW5wdXRFbCB9XG4gICAgaWYoaW5wdXRFbC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFwiY2hhbmdlXCIpKSl7XG4gICAgICBmb3JtRGF0YSA9IHNlcmlhbGl6ZUZvcm0oaW5wdXRFbC5mb3JtLCB7X3RhcmdldDogb3B0cy5fdGFyZ2V0LCAuLi5tZXRhfSwgW2lucHV0RWwubmFtZV0pXG4gICAgfSBlbHNlIHtcbiAgICAgIGZvcm1EYXRhID0gc2VyaWFsaXplRm9ybShpbnB1dEVsLmZvcm0sIHtfdGFyZ2V0OiBvcHRzLl90YXJnZXQsIC4uLm1ldGF9KVxuICAgIH1cbiAgICBpZihET00uaXNVcGxvYWRJbnB1dChpbnB1dEVsKSAmJiBpbnB1dEVsLmZpbGVzICYmIGlucHV0RWwuZmlsZXMubGVuZ3RoID4gMCl7XG4gICAgICBMaXZlVXBsb2FkZXIudHJhY2tGaWxlcyhpbnB1dEVsLCBBcnJheS5mcm9tKGlucHV0RWwuZmlsZXMpKVxuICAgIH1cbiAgICB1cGxvYWRzID0gTGl2ZVVwbG9hZGVyLnNlcmlhbGl6ZVVwbG9hZHMoaW5wdXRFbClcblxuICAgIGxldCBldmVudCA9IHtcbiAgICAgIHR5cGU6IFwiZm9ybVwiLFxuICAgICAgZXZlbnQ6IHBoeEV2ZW50LFxuICAgICAgdmFsdWU6IGZvcm1EYXRhLFxuICAgICAgdXBsb2FkczogdXBsb2FkcyxcbiAgICAgIGNpZDogY2lkXG4gICAgfVxuICAgIHRoaXMucHVzaFdpdGhSZXBseShyZWZHZW5lcmF0b3IsIFwiZXZlbnRcIiwgZXZlbnQsIHJlc3AgPT4ge1xuICAgICAgRE9NLnNob3dFcnJvcihpbnB1dEVsLCB0aGlzLmxpdmVTb2NrZXQuYmluZGluZyhQSFhfRkVFREJBQ0tfRk9SKSwgdGhpcy5saXZlU29ja2V0LmJpbmRpbmcoUEhYX0ZFRURCQUNLX0dST1VQKSlcbiAgICAgIGlmKERPTS5pc1VwbG9hZElucHV0KGlucHV0RWwpICYmIERPTS5pc0F1dG9VcGxvYWQoaW5wdXRFbCkpe1xuICAgICAgICBpZihMaXZlVXBsb2FkZXIuZmlsZXNBd2FpdGluZ1ByZWZsaWdodChpbnB1dEVsKS5sZW5ndGggPiAwKXtcbiAgICAgICAgICBsZXQgW3JlZiwgX2Vsc10gPSByZWZHZW5lcmF0b3IoKVxuICAgICAgICAgIHRoaXMudW5kb1JlZnMocmVmLCBbaW5wdXRFbC5mb3JtXSlcbiAgICAgICAgICB0aGlzLnVwbG9hZEZpbGVzKGlucHV0RWwuZm9ybSwgdGFyZ2V0Q3R4LCByZWYsIGNpZCwgKF91cGxvYWRzKSA9PiB7XG4gICAgICAgICAgICBjYWxsYmFjayAmJiBjYWxsYmFjayhyZXNwKVxuICAgICAgICAgICAgdGhpcy50cmlnZ2VyQXdhaXRpbmdTdWJtaXQoaW5wdXRFbC5mb3JtKVxuICAgICAgICAgICAgdGhpcy51bmRvUmVmcyhyZWYpXG4gICAgICAgICAgfSlcbiAgICAgICAgfVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgY2FsbGJhY2sgJiYgY2FsbGJhY2socmVzcClcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgdHJpZ2dlckF3YWl0aW5nU3VibWl0KGZvcm1FbCl7XG4gICAgbGV0IGF3YWl0aW5nU3VibWl0ID0gdGhpcy5nZXRTY2hlZHVsZWRTdWJtaXQoZm9ybUVsKVxuICAgIGlmKGF3YWl0aW5nU3VibWl0KXtcbiAgICAgIGxldCBbX2VsLCBfcmVmLCBfb3B0cywgY2FsbGJhY2tdID0gYXdhaXRpbmdTdWJtaXRcbiAgICAgIHRoaXMuY2FuY2VsU3VibWl0KGZvcm1FbClcbiAgICAgIGNhbGxiYWNrKClcbiAgICB9XG4gIH1cblxuICBnZXRTY2hlZHVsZWRTdWJtaXQoZm9ybUVsKXtcbiAgICByZXR1cm4gdGhpcy5mb3JtU3VibWl0cy5maW5kKChbZWwsIF9yZWYsIF9vcHRzLCBfY2FsbGJhY2tdKSA9PiBlbC5pc1NhbWVOb2RlKGZvcm1FbCkpXG4gIH1cblxuICBzY2hlZHVsZVN1Ym1pdChmb3JtRWwsIHJlZiwgb3B0cywgY2FsbGJhY2spe1xuICAgIGlmKHRoaXMuZ2V0U2NoZWR1bGVkU3VibWl0KGZvcm1FbCkpeyByZXR1cm4gdHJ1ZSB9XG4gICAgdGhpcy5mb3JtU3VibWl0cy5wdXNoKFtmb3JtRWwsIHJlZiwgb3B0cywgY2FsbGJhY2tdKVxuICB9XG5cbiAgY2FuY2VsU3VibWl0KGZvcm1FbCl7XG4gICAgdGhpcy5mb3JtU3VibWl0cyA9IHRoaXMuZm9ybVN1Ym1pdHMuZmlsdGVyKChbZWwsIHJlZiwgX2NhbGxiYWNrXSkgPT4ge1xuICAgICAgaWYoZWwuaXNTYW1lTm9kZShmb3JtRWwpKXtcbiAgICAgICAgdGhpcy51bmRvUmVmcyhyZWYpXG4gICAgICAgIHJldHVybiBmYWxzZVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgcmV0dXJuIHRydWVcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgZGlzYWJsZUZvcm0oZm9ybUVsLCBvcHRzID0ge30pe1xuICAgIGxldCBmaWx0ZXJJZ25vcmVkID0gZWwgPT4ge1xuICAgICAgbGV0IHVzZXJJZ25vcmVkID0gY2xvc2VzdFBoeEJpbmRpbmcoZWwsIGAke3RoaXMuYmluZGluZyhQSFhfVVBEQVRFKX09aWdub3JlYCwgZWwuZm9ybSlcbiAgICAgIHJldHVybiAhKHVzZXJJZ25vcmVkIHx8IGNsb3Nlc3RQaHhCaW5kaW5nKGVsLCBcImRhdGEtcGh4LXVwZGF0ZT1pZ25vcmVcIiwgZWwuZm9ybSkpXG4gICAgfVxuICAgIGxldCBmaWx0ZXJEaXNhYmxlcyA9IGVsID0+IHtcbiAgICAgIHJldHVybiBlbC5oYXNBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9ESVNBQkxFX1dJVEgpKVxuICAgIH1cbiAgICBsZXQgZmlsdGVyQnV0dG9uID0gZWwgPT4gZWwudGFnTmFtZSA9PSBcIkJVVFRPTlwiXG5cbiAgICBsZXQgZmlsdGVySW5wdXQgPSBlbCA9PiBbXCJJTlBVVFwiLCBcIlRFWFRBUkVBXCIsIFwiU0VMRUNUXCJdLmluY2x1ZGVzKGVsLnRhZ05hbWUpXG5cbiAgICBsZXQgZm9ybUVsZW1lbnRzID0gQXJyYXkuZnJvbShmb3JtRWwuZWxlbWVudHMpXG4gICAgbGV0IGRpc2FibGVzID0gZm9ybUVsZW1lbnRzLmZpbHRlcihmaWx0ZXJEaXNhYmxlcylcbiAgICBsZXQgYnV0dG9ucyA9IGZvcm1FbGVtZW50cy5maWx0ZXIoZmlsdGVyQnV0dG9uKS5maWx0ZXIoZmlsdGVySWdub3JlZClcbiAgICBsZXQgaW5wdXRzID0gZm9ybUVsZW1lbnRzLmZpbHRlcihmaWx0ZXJJbnB1dCkuZmlsdGVyKGZpbHRlcklnbm9yZWQpXG5cbiAgICBidXR0b25zLmZvckVhY2goYnV0dG9uID0+IHtcbiAgICAgIGJ1dHRvbi5zZXRBdHRyaWJ1dGUoUEhYX0RJU0FCTEVELCBidXR0b24uZGlzYWJsZWQpXG4gICAgICBidXR0b24uZGlzYWJsZWQgPSB0cnVlXG4gICAgfSlcbiAgICBpbnB1dHMuZm9yRWFjaChpbnB1dCA9PiB7XG4gICAgICBpbnB1dC5zZXRBdHRyaWJ1dGUoUEhYX1JFQURPTkxZLCBpbnB1dC5yZWFkT25seSlcbiAgICAgIGlucHV0LnJlYWRPbmx5ID0gdHJ1ZVxuICAgICAgaWYoaW5wdXQuZmlsZXMpe1xuICAgICAgICBpbnB1dC5zZXRBdHRyaWJ1dGUoUEhYX0RJU0FCTEVELCBpbnB1dC5kaXNhYmxlZClcbiAgICAgICAgaW5wdXQuZGlzYWJsZWQgPSB0cnVlXG4gICAgICB9XG4gICAgfSlcbiAgICBmb3JtRWwuc2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhQSFhfUEFHRV9MT0FESU5HKSwgXCJcIilcbiAgICByZXR1cm4gdGhpcy5wdXRSZWYoW2Zvcm1FbF0uY29uY2F0KGRpc2FibGVzKS5jb25jYXQoYnV0dG9ucykuY29uY2F0KGlucHV0cyksIFwic3VibWl0XCIsIG9wdHMpXG4gIH1cblxuICBwdXNoRm9ybVN1Ym1pdChmb3JtRWwsIHRhcmdldEN0eCwgcGh4RXZlbnQsIHN1Ym1pdHRlciwgb3B0cywgb25SZXBseSl7XG4gICAgbGV0IHJlZkdlbmVyYXRvciA9ICgpID0+IHRoaXMuZGlzYWJsZUZvcm0oZm9ybUVsLCB7Li4ub3B0cywgZm9ybTogZm9ybUVsLCBzdWJtaXR0ZXI6IHN1Ym1pdHRlcn0pXG4gICAgbGV0IGNpZCA9IHRoaXMudGFyZ2V0Q29tcG9uZW50SUQoZm9ybUVsLCB0YXJnZXRDdHgpXG4gICAgaWYoTGl2ZVVwbG9hZGVyLmhhc1VwbG9hZHNJblByb2dyZXNzKGZvcm1FbCkpe1xuICAgICAgbGV0IFtyZWYsIF9lbHNdID0gcmVmR2VuZXJhdG9yKClcbiAgICAgIGxldCBwdXNoID0gKCkgPT4gdGhpcy5wdXNoRm9ybVN1Ym1pdChmb3JtRWwsIHRhcmdldEN0eCwgcGh4RXZlbnQsIHN1Ym1pdHRlciwgb3B0cywgb25SZXBseSlcbiAgICAgIHJldHVybiB0aGlzLnNjaGVkdWxlU3VibWl0KGZvcm1FbCwgcmVmLCBvcHRzLCBwdXNoKVxuICAgIH0gZWxzZSBpZihMaXZlVXBsb2FkZXIuaW5wdXRzQXdhaXRpbmdQcmVmbGlnaHQoZm9ybUVsKS5sZW5ndGggPiAwKXtcbiAgICAgIGxldCBbcmVmLCBlbHNdID0gcmVmR2VuZXJhdG9yKClcbiAgICAgIGxldCBwcm94eVJlZkdlbiA9ICgpID0+IFtyZWYsIGVscywgb3B0c11cbiAgICAgIHRoaXMudXBsb2FkRmlsZXMoZm9ybUVsLCB0YXJnZXRDdHgsIHJlZiwgY2lkLCAodXBsb2FkcykgPT4ge1xuICAgICAgICAvLyBpZiB3ZSBzdGlsbCBoYXZpbmcgcGVuZGluZyBwcmVmbGlnaHRzIGl0IG1lYW5zIHdlIGhhdmUgaW52YWxpZCBlbnRyaWVzXG4gICAgICAgIC8vIGFuZCB0aGUgcGh4LXN1Ym1pdCBjYW5ub3QgYmUgY29tcGxldGVkXG4gICAgICAgIGlmKExpdmVVcGxvYWRlci5pbnB1dHNBd2FpdGluZ1ByZWZsaWdodChmb3JtRWwpLmxlbmd0aCA+IDApe1xuICAgICAgICAgIHJldHVybiB0aGlzLnVuZG9SZWZzKHJlZilcbiAgICAgICAgfVxuICAgICAgICBsZXQgbWV0YSA9IHRoaXMuZXh0cmFjdE1ldGEoZm9ybUVsKVxuICAgICAgICBsZXQgZm9ybURhdGEgPSBzZXJpYWxpemVGb3JtKGZvcm1FbCwge3N1Ym1pdHRlciwgLi4ubWV0YX0pXG4gICAgICAgIHRoaXMucHVzaFdpdGhSZXBseShwcm94eVJlZkdlbiwgXCJldmVudFwiLCB7XG4gICAgICAgICAgdHlwZTogXCJmb3JtXCIsXG4gICAgICAgICAgZXZlbnQ6IHBoeEV2ZW50LFxuICAgICAgICAgIHZhbHVlOiBmb3JtRGF0YSxcbiAgICAgICAgICBjaWQ6IGNpZFxuICAgICAgICB9LCBvblJlcGx5KVxuICAgICAgfSlcbiAgICB9IGVsc2UgaWYoIShmb3JtRWwuaGFzQXR0cmlidXRlKFBIWF9SRUYpICYmIGZvcm1FbC5jbGFzc0xpc3QuY29udGFpbnMoXCJwaHgtc3VibWl0LWxvYWRpbmdcIikpKXtcbiAgICAgIGxldCBtZXRhID0gdGhpcy5leHRyYWN0TWV0YShmb3JtRWwpXG4gICAgICBsZXQgZm9ybURhdGEgPSBzZXJpYWxpemVGb3JtKGZvcm1FbCwge3N1Ym1pdHRlciwgLi4ubWV0YX0pXG4gICAgICB0aGlzLnB1c2hXaXRoUmVwbHkocmVmR2VuZXJhdG9yLCBcImV2ZW50XCIsIHtcbiAgICAgICAgdHlwZTogXCJmb3JtXCIsXG4gICAgICAgIGV2ZW50OiBwaHhFdmVudCxcbiAgICAgICAgdmFsdWU6IGZvcm1EYXRhLFxuICAgICAgICBjaWQ6IGNpZFxuICAgICAgfSwgb25SZXBseSlcbiAgICB9XG4gIH1cblxuICB1cGxvYWRGaWxlcyhmb3JtRWwsIHRhcmdldEN0eCwgcmVmLCBjaWQsIG9uQ29tcGxldGUpe1xuICAgIGxldCBqb2luQ291bnRBdFVwbG9hZCA9IHRoaXMuam9pbkNvdW50XG4gICAgbGV0IGlucHV0RWxzID0gTGl2ZVVwbG9hZGVyLmFjdGl2ZUZpbGVJbnB1dHMoZm9ybUVsKVxuICAgIGxldCBudW1GaWxlSW5wdXRzSW5Qcm9ncmVzcyA9IGlucHV0RWxzLmxlbmd0aFxuXG4gICAgLy8gZ2V0IGVhY2ggZmlsZSBpbnB1dFxuICAgIGlucHV0RWxzLmZvckVhY2goaW5wdXRFbCA9PiB7XG4gICAgICBsZXQgdXBsb2FkZXIgPSBuZXcgTGl2ZVVwbG9hZGVyKGlucHV0RWwsIHRoaXMsICgpID0+IHtcbiAgICAgICAgbnVtRmlsZUlucHV0c0luUHJvZ3Jlc3MtLVxuICAgICAgICBpZihudW1GaWxlSW5wdXRzSW5Qcm9ncmVzcyA9PT0gMCl7IG9uQ29tcGxldGUoKSB9XG4gICAgICB9KTtcblxuICAgICAgbGV0IGVudHJpZXMgPSB1cGxvYWRlci5lbnRyaWVzKCkubWFwKGVudHJ5ID0+IGVudHJ5LnRvUHJlZmxpZ2h0UGF5bG9hZCgpKVxuXG4gICAgICBpZihlbnRyaWVzLmxlbmd0aCA9PT0gMCkge1xuICAgICAgICBudW1GaWxlSW5wdXRzSW5Qcm9ncmVzcy0tXG4gICAgICAgIHJldHVyblxuICAgICAgfVxuXG4gICAgICBsZXQgcGF5bG9hZCA9IHtcbiAgICAgICAgcmVmOiBpbnB1dEVsLmdldEF0dHJpYnV0ZShQSFhfVVBMT0FEX1JFRiksXG4gICAgICAgIGVudHJpZXM6IGVudHJpZXMsXG4gICAgICAgIGNpZDogdGhpcy50YXJnZXRDb21wb25lbnRJRChpbnB1dEVsLmZvcm0sIHRhcmdldEN0eClcbiAgICAgIH1cblxuICAgICAgdGhpcy5sb2coXCJ1cGxvYWRcIiwgKCkgPT4gW1wic2VuZGluZyBwcmVmbGlnaHQgcmVxdWVzdFwiLCBwYXlsb2FkXSlcblxuICAgICAgdGhpcy5wdXNoV2l0aFJlcGx5KG51bGwsIFwiYWxsb3dfdXBsb2FkXCIsIHBheWxvYWQsIHJlc3AgPT4ge1xuICAgICAgICB0aGlzLmxvZyhcInVwbG9hZFwiLCAoKSA9PiBbXCJnb3QgcHJlZmxpZ2h0IHJlc3BvbnNlXCIsIHJlc3BdKVxuICAgICAgICAvLyB0aGUgcHJlZmxpZ2h0IHdpbGwgcmVqZWN0IGVudHJpZXMgYmV5b25kIHRoZSBtYXggZW50cmllc1xuICAgICAgICAvLyBzbyB3ZSBlcnJvciBhbmQgY2FuY2VsIGVudHJpZXMgb24gdGhlIGNsaWVudCB0aGF0IGFyZSBtaXNzaW5nIGZyb20gdGhlIHJlc3BvbnNlXG4gICAgICAgIHVwbG9hZGVyLmVudHJpZXMoKS5mb3JFYWNoKGVudHJ5ID0+IHtcbiAgICAgICAgICBpZihyZXNwLmVudHJpZXMgJiYgIXJlc3AuZW50cmllc1tlbnRyeS5yZWZdKXtcbiAgICAgICAgICAgIHRoaXMuaGFuZGxlRmFpbGVkRW50cnlQcmVmbGlnaHQoZW50cnkucmVmLCBcImZhaWxlZCBwcmVmbGlnaHRcIiwgdXBsb2FkZXIpXG4gICAgICAgICAgfVxuICAgICAgICB9KVxuICAgICAgICAvLyBmb3IgYXV0byB1cGxvYWRzLCB3ZSBtYXkgaGF2ZSBhbiBlbXB0eSBlbnRyaWVzIHJlc3BvbnNlIGZyb20gdGhlIHNlcnZlclxuICAgICAgICAvLyBmb3IgZm9ybSBzdWJtaXRzIHRoYXQgY29udGFpbiBpbnZhbGlkIGVudHJpZXNcbiAgICAgICAgaWYocmVzcC5lcnJvciB8fCBPYmplY3Qua2V5cyhyZXNwLmVudHJpZXMpLmxlbmd0aCA9PT0gMCl7XG4gICAgICAgICAgdGhpcy51bmRvUmVmcyhyZWYpXG4gICAgICAgICAgbGV0IGVycm9ycyA9IHJlc3AuZXJyb3IgfHwgW11cbiAgICAgICAgICBlcnJvcnMubWFwKChbZW50cnlfcmVmLCByZWFzb25dKSA9PiB7XG4gICAgICAgICAgICB0aGlzLmhhbmRsZUZhaWxlZEVudHJ5UHJlZmxpZ2h0KGVudHJ5X3JlZiwgcmVhc29uLCB1cGxvYWRlcilcbiAgICAgICAgICB9KVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIGxldCBvbkVycm9yID0gKGNhbGxiYWNrKSA9PiB7XG4gICAgICAgICAgICB0aGlzLmNoYW5uZWwub25FcnJvcigoKSA9PiB7XG4gICAgICAgICAgICAgIGlmKHRoaXMuam9pbkNvdW50ID09PSBqb2luQ291bnRBdFVwbG9hZCl7IGNhbGxiYWNrKCkgfVxuICAgICAgICAgICAgfSlcbiAgICAgICAgICB9XG4gICAgICAgICAgdXBsb2FkZXIuaW5pdEFkYXB0ZXJVcGxvYWQocmVzcCwgb25FcnJvciwgdGhpcy5saXZlU29ja2V0KVxuICAgICAgICB9XG4gICAgICB9KVxuICAgIH0pXG4gIH1cblxuICBoYW5kbGVGYWlsZWRFbnRyeVByZWZsaWdodCh1cGxvYWRSZWYsIHJlYXNvbiwgdXBsb2FkZXIpe1xuICAgIGlmKHVwbG9hZGVyLmlzQXV0b1VwbG9hZCgpKXtcbiAgICAgIC8vIHVwbG9hZFJlZiBtYXkgYmUgdG9wIGxldmVsIHVwbG9hZCBjb25maWcgcmVmIG9yIGVudHJ5IHJlZlxuICAgICAgbGV0IGVudHJ5ID0gdXBsb2FkZXIuZW50cmllcygpLmZpbmQoZW50cnkgPT4gZW50cnkucmVmID09PSB1cGxvYWRSZWYudG9TdHJpbmcoKSlcbiAgICAgIGlmKGVudHJ5KXsgZW50cnkuY2FuY2VsKCkgfVxuICAgIH0gZWxzZSB7XG4gICAgICB1cGxvYWRlci5lbnRyaWVzKCkubWFwKGVudHJ5ID0+IGVudHJ5LmNhbmNlbCgpKVxuICAgIH1cbiAgICB0aGlzLmxvZyhcInVwbG9hZFwiLCAoKSA9PiBbYGVycm9yIGZvciBlbnRyeSAke3VwbG9hZFJlZn1gLCByZWFzb25dKVxuICB9XG5cbiAgZGlzcGF0Y2hVcGxvYWRzKHRhcmdldEN0eCwgbmFtZSwgZmlsZXNPckJsb2JzKXtcbiAgICBsZXQgdGFyZ2V0RWxlbWVudCA9IHRoaXMudGFyZ2V0Q3R4RWxlbWVudCh0YXJnZXRDdHgpIHx8IHRoaXMuZWxcbiAgICBsZXQgaW5wdXRzID0gRE9NLmZpbmRVcGxvYWRJbnB1dHModGFyZ2V0RWxlbWVudCkuZmlsdGVyKGVsID0+IGVsLm5hbWUgPT09IG5hbWUpXG4gICAgaWYoaW5wdXRzLmxlbmd0aCA9PT0gMCl7IGxvZ0Vycm9yKGBubyBsaXZlIGZpbGUgaW5wdXRzIGZvdW5kIG1hdGNoaW5nIHRoZSBuYW1lIFwiJHtuYW1lfVwiYCkgfVxuICAgIGVsc2UgaWYoaW5wdXRzLmxlbmd0aCA+IDEpeyBsb2dFcnJvcihgZHVwbGljYXRlIGxpdmUgZmlsZSBpbnB1dHMgZm91bmQgbWF0Y2hpbmcgdGhlIG5hbWUgXCIke25hbWV9XCJgKSB9XG4gICAgZWxzZSB7IERPTS5kaXNwYXRjaEV2ZW50KGlucHV0c1swXSwgUEhYX1RSQUNLX1VQTE9BRFMsIHtkZXRhaWw6IHtmaWxlczogZmlsZXNPckJsb2JzfX0pIH1cbiAgfVxuXG4gIHRhcmdldEN0eEVsZW1lbnQodGFyZ2V0Q3R4KSB7XG4gICAgaWYoaXNDaWQodGFyZ2V0Q3R4KSl7XG4gICAgICBsZXQgW3RhcmdldF0gPSBET00uZmluZENvbXBvbmVudE5vZGVMaXN0KHRoaXMuZWwsIHRhcmdldEN0eClcbiAgICAgIHJldHVybiB0YXJnZXRcbiAgICB9IGVsc2UgaWYodGFyZ2V0Q3R4KSB7XG4gICAgICByZXR1cm4gdGFyZ2V0Q3R4XG4gICAgfSBlbHNlIHtcbiAgICAgIHJldHVybiBudWxsXG4gICAgfVxuICB9XG5cbiAgcHVzaEZvcm1SZWNvdmVyeShvbGRGb3JtLCBuZXdGb3JtLCB0ZW1wbGF0ZURvbSwgY2FsbGJhY2spe1xuICAgIC8vIHdlIGFyZSBvbmx5IHJlY292ZXJpbmcgZm9ybXMgaW5zaWRlIHRoZSBjdXJyZW50IHZpZXcsIHRoZXJlZm9yZSBpdCBpcyBzYWZlIHRvXG4gICAgLy8gc2tpcCB3aXRoaW5Pd25lcnMgaGVyZSBhbmQgYWx3YXlzIHVzZSB0aGlzIHdoZW4gcmVmZXJyaW5nIHRvIHRoZSB2aWV3XG4gICAgY29uc3QgcGh4Q2hhbmdlID0gdGhpcy5iaW5kaW5nKFwiY2hhbmdlXCIpXG4gICAgY29uc3QgcGh4VGFyZ2V0ID0gbmV3Rm9ybS5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFwidGFyZ2V0XCIpKSB8fCBuZXdGb3JtXG4gICAgY29uc3QgcGh4RXZlbnQgPSBuZXdGb3JtLmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoUEhYX0FVVE9fUkVDT1ZFUikpIHx8IG5ld0Zvcm0uZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhcImNoYW5nZVwiKSlcbiAgICBjb25zdCBpbnB1dHMgPSBBcnJheS5mcm9tKG9sZEZvcm0uZWxlbWVudHMpLmZpbHRlcihlbCA9PiBET00uaXNGb3JtSW5wdXQoZWwpICYmIGVsLm5hbWUgJiYgIWVsLmhhc0F0dHJpYnV0ZShwaHhDaGFuZ2UpKVxuICAgIGlmKGlucHV0cy5sZW5ndGggPT09IDApeyByZXR1cm4gfVxuXG4gICAgLy8gd2UgbXVzdCBjbGVhciB0cmFja2VkIHVwbG9hZHMgYmVmb3JlIHJlY292ZXJ5IGFzIHRoZXkgbm8gbG9uZ2VyIGhhdmUgdmFsaWQgcmVmc1xuICAgIGlucHV0cy5mb3JFYWNoKGlucHV0ID0+IGlucHV0Lmhhc0F0dHJpYnV0ZShQSFhfVVBMT0FEX1JFRikgJiYgTGl2ZVVwbG9hZGVyLmNsZWFyRmlsZXMoaW5wdXQpKVxuICAgIC8vIHB1c2hJbnB1dCBhc3N1bWVzIHRoYXQgdGhlcmUgaXMgYSBzb3VyY2UgZWxlbWVudCB0aGF0IGluaXRpYXRlZCB0aGUgY2hhbmdlO1xuICAgIC8vIGJlY2F1c2UgdGhpcyBpcyBub3QgdGhlIGNhc2Ugd2hlbiB3ZSByZWNvdmVyIGZvcm1zLCB3ZSBwcm92aWRlIHRoZSBmaXJzdCBpbnB1dCB3ZSBmaW5kXG4gICAgbGV0IGlucHV0ID0gaW5wdXRzLmZpbmQoZWwgPT4gZWwudHlwZSAhPT0gXCJoaWRkZW5cIikgfHwgaW5wdXRzWzBdXG5cbiAgICAvLyBpbiB0aGUgY2FzZSB0aGF0IHRoZXJlIGFyZSBtdWx0aXBsZSB0YXJnZXRzLCB3ZSBjb3VudCB0aGUgbnVtYmVyIG9mIHBlbmRpbmcgcmVjb3ZlcnkgZXZlbnRzXG4gICAgLy8gYW5kIG9ubHkgY2FsbCB0aGUgY2FsbGJhY2sgb25jZSBhbGwgZXZlbnRzIGhhdmUgYmVlbiBwcm9jZXNzZWRcbiAgICBsZXQgcGVuZGluZyA9IDBcbiAgICAvLyB3aXRoaW5UYXJnZXRzKHBoeFRhcmdldCwgY2FsbGJhY2ssIGRvbSwgdmlld0VsKVxuICAgIHRoaXMud2l0aGluVGFyZ2V0cyhwaHhUYXJnZXQsICh0YXJnZXRWaWV3LCB0YXJnZXRDdHgpID0+IHtcbiAgICAgIGNvbnN0IGNpZCA9IHRoaXMudGFyZ2V0Q29tcG9uZW50SUQobmV3Rm9ybSwgdGFyZ2V0Q3R4KVxuICAgICAgcGVuZGluZysrXG4gICAgICB0YXJnZXRWaWV3LnB1c2hJbnB1dChpbnB1dCwgdGFyZ2V0Q3R4LCBjaWQsIHBoeEV2ZW50LCB7X3RhcmdldDogaW5wdXQubmFtZX0sICgpID0+IHtcbiAgICAgICAgcGVuZGluZy0tXG4gICAgICAgIGlmKHBlbmRpbmcgPT09IDApeyBjYWxsYmFjaygpIH1cbiAgICAgIH0pXG4gICAgfSwgdGVtcGxhdGVEb20sIHRlbXBsYXRlRG9tKVxuICB9XG5cbiAgcHVzaExpbmtQYXRjaChocmVmLCB0YXJnZXRFbCwgY2FsbGJhY2spe1xuICAgIGxldCBsaW5rUmVmID0gdGhpcy5saXZlU29ja2V0LnNldFBlbmRpbmdMaW5rKGhyZWYpXG4gICAgbGV0IHJlZkdlbiA9IHRhcmdldEVsID8gKCkgPT4gdGhpcy5wdXRSZWYoW3RhcmdldEVsXSwgXCJjbGlja1wiKSA6IG51bGxcbiAgICBsZXQgZmFsbGJhY2sgPSAoKSA9PiB0aGlzLmxpdmVTb2NrZXQucmVkaXJlY3Qod2luZG93LmxvY2F0aW9uLmhyZWYpXG4gICAgbGV0IHVybCA9IGhyZWYuc3RhcnRzV2l0aChcIi9cIikgPyBgJHtsb2NhdGlvbi5wcm90b2NvbH0vLyR7bG9jYXRpb24uaG9zdH0ke2hyZWZ9YCA6IGhyZWZcblxuICAgIGxldCBwdXNoID0gdGhpcy5wdXNoV2l0aFJlcGx5KHJlZkdlbiwgXCJsaXZlX3BhdGNoXCIsIHt1cmx9LCByZXNwID0+IHtcbiAgICAgIHRoaXMubGl2ZVNvY2tldC5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgaWYocmVzcC5saW5rX3JlZGlyZWN0KXtcbiAgICAgICAgICB0aGlzLmxpdmVTb2NrZXQucmVwbGFjZU1haW4oaHJlZiwgbnVsbCwgY2FsbGJhY2ssIGxpbmtSZWYpXG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgaWYodGhpcy5saXZlU29ja2V0LmNvbW1pdFBlbmRpbmdMaW5rKGxpbmtSZWYpKXtcbiAgICAgICAgICAgIHRoaXMuaHJlZiA9IGhyZWZcbiAgICAgICAgICB9XG4gICAgICAgICAgdGhpcy5hcHBseVBlbmRpbmdVcGRhdGVzKClcbiAgICAgICAgICBjYWxsYmFjayAmJiBjYWxsYmFjayhsaW5rUmVmKVxuICAgICAgICB9XG4gICAgICB9KVxuICAgIH0pXG5cbiAgICBpZihwdXNoKXtcbiAgICAgIHB1c2gucmVjZWl2ZShcInRpbWVvdXRcIiwgZmFsbGJhY2spXG4gICAgfSBlbHNlIHtcbiAgICAgIGZhbGxiYWNrKClcbiAgICB9XG4gIH1cblxuICBnZXRGb3Jtc0ZvclJlY292ZXJ5KCl7XG4gICAgaWYodGhpcy5qb2luQ291bnQgPT09IDApeyByZXR1cm4ge30gfVxuXG4gICAgbGV0IHBoeENoYW5nZSA9IHRoaXMuYmluZGluZyhcImNoYW5nZVwiKVxuXG4gICAgcmV0dXJuIERPTS5hbGwodGhpcy5lbCwgYGZvcm1bJHtwaHhDaGFuZ2V9XWApXG4gICAgICAuZmlsdGVyKGZvcm0gPT4gZm9ybS5pZClcbiAgICAgIC5maWx0ZXIoZm9ybSA9PiBmb3JtLmVsZW1lbnRzLmxlbmd0aCA+IDApXG4gICAgICAuZmlsdGVyKGZvcm0gPT4gZm9ybS5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9BVVRPX1JFQ09WRVIpKSAhPT0gXCJpZ25vcmVcIilcbiAgICAgIC5tYXAoZm9ybSA9PiBmb3JtLmNsb25lTm9kZSh0cnVlKSlcbiAgICAgIC5yZWR1Y2UoKGFjYywgZm9ybSkgPT4ge1xuICAgICAgICBhY2NbZm9ybS5pZF0gPSBmb3JtXG4gICAgICAgIHJldHVybiBhY2NcbiAgICAgIH0sIHt9KVxuICB9XG5cbiAgbWF5YmVQdXNoQ29tcG9uZW50c0Rlc3Ryb3llZChkZXN0cm95ZWRDSURzKXtcbiAgICBsZXQgd2lsbERlc3Ryb3lDSURzID0gZGVzdHJveWVkQ0lEcy5maWx0ZXIoY2lkID0+IHtcbiAgICAgIHJldHVybiBET00uZmluZENvbXBvbmVudE5vZGVMaXN0KHRoaXMuZWwsIGNpZCkubGVuZ3RoID09PSAwXG4gICAgfSlcblxuICAgIGlmKHdpbGxEZXN0cm95Q0lEcy5sZW5ndGggPiAwKXtcbiAgICAgIC8vIHdlIG11c3QgcmVzZXQgdGhlIHJlbmRlciBjaGFuZ2UgdHJhY2tpbmcgZm9yIGNpZHMgdGhhdFxuICAgICAgLy8gY291bGQgYmUgYWRkZWQgYmFjayBmcm9tIHRoZSBzZXJ2ZXIgc28gd2UgZG9uJ3Qgc2tpcCB0aGVtXG4gICAgICB3aWxsRGVzdHJveUNJRHMuZm9yRWFjaChjaWQgPT4gdGhpcy5yZW5kZXJlZC5yZXNldFJlbmRlcihjaWQpKVxuXG4gICAgICB0aGlzLnB1c2hXaXRoUmVwbHkobnVsbCwgXCJjaWRzX3dpbGxfZGVzdHJveVwiLCB7Y2lkczogd2lsbERlc3Ryb3lDSURzfSwgKCkgPT4ge1xuICAgICAgICAvLyB3ZSBtdXN0IHdhaXQgZm9yIHBlbmRpbmcgdHJhbnNpdGlvbnMgdG8gY29tcGxldGUgYmVmb3JlIGRldGVybWluaW5nXG4gICAgICAgIC8vIGlmIHRoZSBjaWRzIHdlcmUgYWRkZWQgYmFjayB0byB0aGUgRE9NIGluIHRoZSBtZWFudGltZSAoIzMxMzkpXG4gICAgICAgIHRoaXMubGl2ZVNvY2tldC5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgICAvLyBTZWUgaWYgYW55IG9mIHRoZSBjaWRzIHdlIHdhbnRlZCB0byBkZXN0cm95IHdlcmUgYWRkZWQgYmFjayxcbiAgICAgICAgICAvLyBpZiB0aGV5IHdlcmUgYWRkZWQgYmFjaywgd2UgZG9uJ3QgYWN0dWFsbHkgZGVzdHJveSB0aGVtLlxuICAgICAgICAgIGxldCBjb21wbGV0ZWx5RGVzdHJveUNJRHMgPSB3aWxsRGVzdHJveUNJRHMuZmlsdGVyKGNpZCA9PiB7XG4gICAgICAgICAgICByZXR1cm4gRE9NLmZpbmRDb21wb25lbnROb2RlTGlzdCh0aGlzLmVsLCBjaWQpLmxlbmd0aCA9PT0gMFxuICAgICAgICAgIH0pXG4gIFxuICAgICAgICAgIGlmKGNvbXBsZXRlbHlEZXN0cm95Q0lEcy5sZW5ndGggPiAwKXtcbiAgICAgICAgICAgIHRoaXMucHVzaFdpdGhSZXBseShudWxsLCBcImNpZHNfZGVzdHJveWVkXCIsIHtjaWRzOiBjb21wbGV0ZWx5RGVzdHJveUNJRHN9LCAocmVzcCkgPT4ge1xuICAgICAgICAgICAgICB0aGlzLnJlbmRlcmVkLnBydW5lQ0lEcyhyZXNwLmNpZHMpXG4gICAgICAgICAgICB9KVxuICAgICAgICAgIH1cbiAgICAgICAgfSlcbiAgICAgIH0pXG4gICAgfVxuICB9XG5cbiAgb3duc0VsZW1lbnQoZWwpe1xuICAgIGxldCBwYXJlbnRWaWV3RWwgPSBlbC5jbG9zZXN0KFBIWF9WSUVXX1NFTEVDVE9SKVxuICAgIHJldHVybiBlbC5nZXRBdHRyaWJ1dGUoUEhYX1BBUkVOVF9JRCkgPT09IHRoaXMuaWQgfHxcbiAgICAgIChwYXJlbnRWaWV3RWwgJiYgcGFyZW50Vmlld0VsLmlkID09PSB0aGlzLmlkKSB8fFxuICAgICAgKCFwYXJlbnRWaWV3RWwgJiYgdGhpcy5pc0RlYWQpXG4gIH1cblxuICBzdWJtaXRGb3JtKGZvcm0sIHRhcmdldEN0eCwgcGh4RXZlbnQsIHN1Ym1pdHRlciwgb3B0cyA9IHt9KXtcbiAgICBET00ucHV0UHJpdmF0ZShmb3JtLCBQSFhfSEFTX1NVQk1JVFRFRCwgdHJ1ZSlcbiAgICBjb25zdCBwaHhGZWVkYmFja0ZvciA9IHRoaXMubGl2ZVNvY2tldC5iaW5kaW5nKFBIWF9GRUVEQkFDS19GT1IpXG4gICAgY29uc3QgcGh4RmVlZGJhY2tHcm91cCA9IHRoaXMubGl2ZVNvY2tldC5iaW5kaW5nKFBIWF9GRUVEQkFDS19HUk9VUClcbiAgICBjb25zdCBpbnB1dHMgPSBBcnJheS5mcm9tKGZvcm0uZWxlbWVudHMpXG4gICAgaW5wdXRzLmZvckVhY2goaW5wdXQgPT4gRE9NLnB1dFByaXZhdGUoaW5wdXQsIFBIWF9IQVNfU1VCTUlUVEVELCB0cnVlKSlcbiAgICB0aGlzLmxpdmVTb2NrZXQuYmx1ckFjdGl2ZUVsZW1lbnQodGhpcylcbiAgICB0aGlzLnB1c2hGb3JtU3VibWl0KGZvcm0sIHRhcmdldEN0eCwgcGh4RXZlbnQsIHN1Ym1pdHRlciwgb3B0cywgKCkgPT4ge1xuICAgICAgaW5wdXRzLmZvckVhY2goaW5wdXQgPT4gRE9NLnNob3dFcnJvcihpbnB1dCwgcGh4RmVlZGJhY2tGb3IsIHBoeEZlZWRiYWNrR3JvdXApKVxuICAgICAgdGhpcy5saXZlU29ja2V0LnJlc3RvcmVQcmV2aW91c2x5QWN0aXZlRm9jdXMoKVxuICAgIH0pXG4gIH1cblxuICBiaW5kaW5nKGtpbmQpeyByZXR1cm4gdGhpcy5saXZlU29ja2V0LmJpbmRpbmcoa2luZCkgfVxufVxuIiwgIi8qKiBJbml0aWFsaXplcyB0aGUgTGl2ZVNvY2tldFxuICpcbiAqXG4gKiBAcGFyYW0ge3N0cmluZ30gZW5kUG9pbnQgLSBUaGUgc3RyaW5nIFdlYlNvY2tldCBlbmRwb2ludCwgaWUsIGBcIndzczovL2V4YW1wbGUuY29tL2xpdmVcImAsXG4gKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYFwiL2xpdmVcImAgKGluaGVyaXRlZCBob3N0ICYgcHJvdG9jb2wpXG4gKiBAcGFyYW0ge1Bob2VuaXguU29ja2V0fSBzb2NrZXQgLSB0aGUgcmVxdWlyZWQgUGhvZW5peCBTb2NrZXQgY2xhc3MgaW1wb3J0ZWQgZnJvbSBcInBob2VuaXhcIi4gRm9yIGV4YW1wbGU6XG4gKlxuICogICAgIGltcG9ydCB7U29ja2V0fSBmcm9tIFwicGhvZW5peFwiXG4gKiAgICAgaW1wb3J0IHtMaXZlU29ja2V0fSBmcm9tIFwicGhvZW5peF9saXZlX3ZpZXdcIlxuICogICAgIGxldCBsaXZlU29ja2V0ID0gbmV3IExpdmVTb2NrZXQoXCIvbGl2ZVwiLCBTb2NrZXQsIHsuLi59KVxuICpcbiAqIEBwYXJhbSB7T2JqZWN0fSBbb3B0c10gLSBPcHRpb25hbCBjb25maWd1cmF0aW9uLiBPdXRzaWRlIG9mIGtleXMgbGlzdGVkIGJlbG93LCBhbGxcbiAqIGNvbmZpZ3VyYXRpb24gaXMgcGFzc2VkIGRpcmVjdGx5IHRvIHRoZSBQaG9lbml4IFNvY2tldCBjb25zdHJ1Y3Rvci5cbiAqIEBwYXJhbSB7T2JqZWN0fSBbb3B0cy5kZWZhdWx0c10gLSBUaGUgb3B0aW9uYWwgZGVmYXVsdHMgdG8gdXNlIGZvciB2YXJpb3VzIGJpbmRpbmdzLFxuICogc3VjaCBhcyBgcGh4LWRlYm91bmNlYC4gU3VwcG9ydHMgdGhlIGZvbGxvd2luZyBrZXlzOlxuICpcbiAqICAgLSBkZWJvdW5jZSAtIHRoZSBtaWxsaXNlY29uZCBwaHgtZGVib3VuY2UgdGltZS4gRGVmYXVsdHMgMzAwXG4gKiAgIC0gdGhyb3R0bGUgLSB0aGUgbWlsbGlzZWNvbmQgcGh4LXRocm90dGxlIHRpbWUuIERlZmF1bHRzIDMwMFxuICpcbiAqIEBwYXJhbSB7RnVuY3Rpb259IFtvcHRzLnBhcmFtc10gLSBUaGUgb3B0aW9uYWwgZnVuY3Rpb24gZm9yIHBhc3NpbmcgY29ubmVjdCBwYXJhbXMuXG4gKiBUaGUgZnVuY3Rpb24gcmVjZWl2ZXMgdGhlIGVsZW1lbnQgYXNzb2NpYXRlZCB3aXRoIGEgZ2l2ZW4gTGl2ZVZpZXcuIEZvciBleGFtcGxlOlxuICpcbiAqICAgICAoZWwpID0+IHt2aWV3OiBlbC5nZXRBdHRyaWJ1dGUoXCJkYXRhLW15LXZpZXctbmFtZVwiLCB0b2tlbjogd2luZG93Lm15VG9rZW59XG4gKlxuICogQHBhcmFtIHtzdHJpbmd9IFtvcHRzLmJpbmRpbmdQcmVmaXhdIC0gVGhlIG9wdGlvbmFsIHByZWZpeCB0byB1c2UgZm9yIGFsbCBwaHggRE9NIGFubm90YXRpb25zLlxuICogRGVmYXVsdHMgdG8gXCJwaHgtXCIuXG4gKiBAcGFyYW0ge09iamVjdH0gW29wdHMuaG9va3NdIC0gVGhlIG9wdGlvbmFsIG9iamVjdCBmb3IgcmVmZXJlbmNpbmcgTGl2ZVZpZXcgaG9vayBjYWxsYmFja3MuXG4gKiBAcGFyYW0ge09iamVjdH0gW29wdHMudXBsb2FkZXJzXSAtIFRoZSBvcHRpb25hbCBvYmplY3QgZm9yIHJlZmVyZW5jaW5nIExpdmVWaWV3IHVwbG9hZGVyIGNhbGxiYWNrcy5cbiAqIEBwYXJhbSB7aW50ZWdlcn0gW29wdHMubG9hZGVyVGltZW91dF0gLSBUaGUgb3B0aW9uYWwgZGVsYXkgaW4gbWlsbGlzZWNvbmRzIHRvIHdhaXQgYmVmb3JlIGFwcGx5XG4gKiBsb2FkaW5nIHN0YXRlcy5cbiAqIEBwYXJhbSB7aW50ZWdlcn0gW29wdHMubWF4UmVsb2Fkc10gLSBUaGUgbWF4aW11bSByZWxvYWRzIGJlZm9yZSBlbnRlcmluZyBmYWlsc2FmZSBtb2RlLlxuICogQHBhcmFtIHtpbnRlZ2VyfSBbb3B0cy5yZWxvYWRKaXR0ZXJNaW5dIC0gVGhlIG1pbmltdW0gdGltZSBiZXR3ZWVuIG5vcm1hbCByZWxvYWQgYXR0ZW1wdHMuXG4gKiBAcGFyYW0ge2ludGVnZXJ9IFtvcHRzLnJlbG9hZEppdHRlck1heF0gLSBUaGUgbWF4aW11bSB0aW1lIGJldHdlZW4gbm9ybWFsIHJlbG9hZCBhdHRlbXB0cy5cbiAqIEBwYXJhbSB7aW50ZWdlcn0gW29wdHMuZmFpbHNhZmVKaXR0ZXJdIC0gVGhlIHRpbWUgYmV0d2VlbiByZWxvYWQgYXR0ZW1wdHMgaW4gZmFpbHNhZmUgbW9kZS5cbiAqIEBwYXJhbSB7RnVuY3Rpb259IFtvcHRzLnZpZXdMb2dnZXJdIC0gVGhlIG9wdGlvbmFsIGZ1bmN0aW9uIHRvIGxvZyBkZWJ1ZyBpbmZvcm1hdGlvbi4gRm9yIGV4YW1wbGU6XG4gKlxuICogICAgICh2aWV3LCBraW5kLCBtc2csIG9iaikgPT4gY29uc29sZS5sb2coYCR7dmlldy5pZH0gJHtraW5kfTogJHttc2d9IC0gYCwgb2JqKVxuICpcbiAqIEBwYXJhbSB7T2JqZWN0fSBbb3B0cy5tZXRhZGF0YV0gLSBUaGUgb3B0aW9uYWwgb2JqZWN0IG1hcHBpbmcgZXZlbnQgbmFtZXMgdG8gZnVuY3Rpb25zIGZvclxuICogcG9wdWxhdGluZyBldmVudCBtZXRhZGF0YS4gRm9yIGV4YW1wbGU6XG4gKlxuICogICAgIG1ldGFkYXRhOiB7XG4gKiAgICAgICBjbGljazogKGUsIGVsKSA9PiB7XG4gKiAgICAgICAgIHJldHVybiB7XG4gKiAgICAgICAgICAgY3RybEtleTogZS5jdHJsS2V5LFxuICogICAgICAgICAgIG1ldGFLZXk6IGUubWV0YUtleSxcbiAqICAgICAgICAgICBkZXRhaWw6IGUuZGV0YWlsIHx8IDEsXG4gKiAgICAgICAgIH1cbiAqICAgICAgIH0sXG4gKiAgICAgICBrZXlkb3duOiAoZSwgZWwpID0+IHtcbiAqICAgICAgICAgcmV0dXJuIHtcbiAqICAgICAgICAgICBrZXk6IGUua2V5LFxuICogICAgICAgICAgIGN0cmxLZXk6IGUuY3RybEtleSxcbiAqICAgICAgICAgICBtZXRhS2V5OiBlLm1ldGFLZXksXG4gKiAgICAgICAgICAgc2hpZnRLZXk6IGUuc2hpZnRLZXlcbiAqICAgICAgICAgfVxuICogICAgICAgfVxuICogICAgIH1cbiAqIEBwYXJhbSB7T2JqZWN0fSBbb3B0cy5zZXNzaW9uU3RvcmFnZV0gLSBBbiBvcHRpb25hbCBTdG9yYWdlIGNvbXBhdGlibGUgb2JqZWN0XG4gKiBVc2VmdWwgd2hlbiBMaXZlVmlldyB3b24ndCBoYXZlIGFjY2VzcyB0byBgc2Vzc2lvblN0b3JhZ2VgLiAgRm9yIGV4YW1wbGUsIFRoaXMgY291bGRcbiAqIGhhcHBlbiBpZiBhIHNpdGUgbG9hZHMgYSBjcm9zcy1kb21haW4gTGl2ZVZpZXcgaW4gYW4gaWZyYW1lLiAgRXhhbXBsZSB1c2FnZTpcbiAqXG4gKiAgICAgY2xhc3MgSW5NZW1vcnlTdG9yYWdlIHtcbiAqICAgICAgIGNvbnN0cnVjdG9yKCkgeyB0aGlzLnN0b3JhZ2UgPSB7fSB9XG4gKiAgICAgICBnZXRJdGVtKGtleU5hbWUpIHsgcmV0dXJuIHRoaXMuc3RvcmFnZVtrZXlOYW1lXSB8fCBudWxsIH1cbiAqICAgICAgIHJlbW92ZUl0ZW0oa2V5TmFtZSkgeyBkZWxldGUgdGhpcy5zdG9yYWdlW2tleU5hbWVdIH1cbiAqICAgICAgIHNldEl0ZW0oa2V5TmFtZSwga2V5VmFsdWUpIHsgdGhpcy5zdG9yYWdlW2tleU5hbWVdID0ga2V5VmFsdWUgfVxuICogICAgIH1cbiAqXG4gKiBAcGFyYW0ge09iamVjdH0gW29wdHMubG9jYWxTdG9yYWdlXSAtIEFuIG9wdGlvbmFsIFN0b3JhZ2UgY29tcGF0aWJsZSBvYmplY3RcbiAqIFVzZWZ1bCBmb3Igd2hlbiBMaXZlVmlldyB3b24ndCBoYXZlIGFjY2VzcyB0byBgbG9jYWxTdG9yYWdlYC5cbiAqIFNlZSBgb3B0cy5zZXNzaW9uU3RvcmFnZWAgZm9yIGV4YW1wbGVzLlxuKi9cblxuaW1wb3J0IHtcbiAgQklORElOR19QUkVGSVgsXG4gIENPTlNFQ1VUSVZFX1JFTE9BRFMsXG4gIERFRkFVTFRTLFxuICBGQUlMU0FGRV9KSVRURVIsXG4gIExPQURFUl9USU1FT1VULFxuICBNQVhfUkVMT0FEUyxcbiAgUEhYX0RFQk9VTkNFLFxuICBQSFhfRFJPUF9UQVJHRVQsXG4gIFBIWF9IQVNfRk9DVVNFRCxcbiAgUEhYX0tFWSxcbiAgUEhYX0xJTktfU1RBVEUsXG4gIFBIWF9MSVZFX0xJTkssXG4gIFBIWF9MVl9ERUJVRyxcbiAgUEhYX0xWX0xBVEVOQ1lfU0lNLFxuICBQSFhfTFZfUFJPRklMRSxcbiAgUEhYX01BSU4sXG4gIFBIWF9QQVJFTlRfSUQsXG4gIFBIWF9WSUVXX1NFTEVDVE9SLFxuICBQSFhfUk9PVF9JRCxcbiAgUEhYX1RIUk9UVExFLFxuICBQSFhfVFJBQ0tfVVBMT0FEUyxcbiAgUEhYX1NFU1NJT04sXG4gIFBIWF9GRUVEQkFDS19GT1IsXG4gIFBIWF9GRUVEQkFDS19HUk9VUCxcbiAgUkVMT0FEX0pJVFRFUl9NSU4sXG4gIFJFTE9BRF9KSVRURVJfTUFYLFxuICBQSFhfUkVGLFxufSBmcm9tIFwiLi9jb25zdGFudHNcIlxuXG5pbXBvcnQge1xuICBjbG9uZSxcbiAgY2xvc2VzdFBoeEJpbmRpbmcsXG4gIGNsb3N1cmUsXG4gIGRlYnVnLFxuICBtYXliZVxufSBmcm9tIFwiLi91dGlsc1wiXG5cbmltcG9ydCBCcm93c2VyIGZyb20gXCIuL2Jyb3dzZXJcIlxuaW1wb3J0IERPTSBmcm9tIFwiLi9kb21cIlxuaW1wb3J0IEhvb2tzIGZyb20gXCIuL2hvb2tzXCJcbmltcG9ydCBMaXZlVXBsb2FkZXIgZnJvbSBcIi4vbGl2ZV91cGxvYWRlclwiXG5pbXBvcnQgVmlldyBmcm9tIFwiLi92aWV3XCJcbmltcG9ydCBKUyBmcm9tIFwiLi9qc1wiXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIExpdmVTb2NrZXQge1xuICBjb25zdHJ1Y3Rvcih1cmwsIHBoeFNvY2tldCwgb3B0cyA9IHt9KXtcbiAgICB0aGlzLnVubG9hZGVkID0gZmFsc2VcbiAgICBpZighcGh4U29ja2V0IHx8IHBoeFNvY2tldC5jb25zdHJ1Y3Rvci5uYW1lID09PSBcIk9iamVjdFwiKXtcbiAgICAgIHRocm93IG5ldyBFcnJvcihgXG4gICAgICBhIHBob2VuaXggU29ja2V0IG11c3QgYmUgcHJvdmlkZWQgYXMgdGhlIHNlY29uZCBhcmd1bWVudCB0byB0aGUgTGl2ZVNvY2tldCBjb25zdHJ1Y3Rvci4gRm9yIGV4YW1wbGU6XG5cbiAgICAgICAgICBpbXBvcnQge1NvY2tldH0gZnJvbSBcInBob2VuaXhcIlxuICAgICAgICAgIGltcG9ydCB7TGl2ZVNvY2tldH0gZnJvbSBcInBob2VuaXhfbGl2ZV92aWV3XCJcbiAgICAgICAgICBsZXQgbGl2ZVNvY2tldCA9IG5ldyBMaXZlU29ja2V0KFwiL2xpdmVcIiwgU29ja2V0LCB7Li4ufSlcbiAgICAgIGApXG4gICAgfVxuICAgIHRoaXMuc29ja2V0ID0gbmV3IHBoeFNvY2tldCh1cmwsIG9wdHMpXG4gICAgdGhpcy5iaW5kaW5nUHJlZml4ID0gb3B0cy5iaW5kaW5nUHJlZml4IHx8IEJJTkRJTkdfUFJFRklYXG4gICAgdGhpcy5vcHRzID0gb3B0c1xuICAgIHRoaXMucGFyYW1zID0gY2xvc3VyZShvcHRzLnBhcmFtcyB8fCB7fSlcbiAgICB0aGlzLnZpZXdMb2dnZXIgPSBvcHRzLnZpZXdMb2dnZXJcbiAgICB0aGlzLm1ldGFkYXRhQ2FsbGJhY2tzID0gb3B0cy5tZXRhZGF0YSB8fCB7fVxuICAgIHRoaXMuZGVmYXVsdHMgPSBPYmplY3QuYXNzaWduKGNsb25lKERFRkFVTFRTKSwgb3B0cy5kZWZhdWx0cyB8fCB7fSlcbiAgICB0aGlzLmFjdGl2ZUVsZW1lbnQgPSBudWxsXG4gICAgdGhpcy5wcmV2QWN0aXZlID0gbnVsbFxuICAgIHRoaXMuc2lsZW5jZWQgPSBmYWxzZVxuICAgIHRoaXMubWFpbiA9IG51bGxcbiAgICB0aGlzLm91dGdvaW5nTWFpbkVsID0gbnVsbFxuICAgIHRoaXMuY2xpY2tTdGFydGVkQXRUYXJnZXQgPSBudWxsXG4gICAgdGhpcy5saW5rUmVmID0gMVxuICAgIHRoaXMucm9vdHMgPSB7fVxuICAgIHRoaXMuaHJlZiA9IHdpbmRvdy5sb2NhdGlvbi5ocmVmXG4gICAgdGhpcy5wZW5kaW5nTGluayA9IG51bGxcbiAgICB0aGlzLmN1cnJlbnRMb2NhdGlvbiA9IGNsb25lKHdpbmRvdy5sb2NhdGlvbilcbiAgICB0aGlzLmhvb2tzID0gb3B0cy5ob29rcyB8fCB7fVxuICAgIHRoaXMudXBsb2FkZXJzID0gb3B0cy51cGxvYWRlcnMgfHwge31cbiAgICB0aGlzLmxvYWRlclRpbWVvdXQgPSBvcHRzLmxvYWRlclRpbWVvdXQgfHwgTE9BREVSX1RJTUVPVVRcbiAgICB0aGlzLnJlbG9hZFdpdGhKaXR0ZXJUaW1lciA9IG51bGxcbiAgICB0aGlzLm1heFJlbG9hZHMgPSBvcHRzLm1heFJlbG9hZHMgfHwgTUFYX1JFTE9BRFNcbiAgICB0aGlzLnJlbG9hZEppdHRlck1pbiA9IG9wdHMucmVsb2FkSml0dGVyTWluIHx8IFJFTE9BRF9KSVRURVJfTUlOXG4gICAgdGhpcy5yZWxvYWRKaXR0ZXJNYXggPSBvcHRzLnJlbG9hZEppdHRlck1heCB8fCBSRUxPQURfSklUVEVSX01BWFxuICAgIHRoaXMuZmFpbHNhZmVKaXR0ZXIgPSBvcHRzLmZhaWxzYWZlSml0dGVyIHx8IEZBSUxTQUZFX0pJVFRFUlxuICAgIHRoaXMubG9jYWxTdG9yYWdlID0gb3B0cy5sb2NhbFN0b3JhZ2UgfHwgd2luZG93LmxvY2FsU3RvcmFnZVxuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2UgPSBvcHRzLnNlc3Npb25TdG9yYWdlIHx8IHdpbmRvdy5zZXNzaW9uU3RvcmFnZVxuICAgIHRoaXMuYm91bmRUb3BMZXZlbEV2ZW50cyA9IGZhbHNlXG4gICAgdGhpcy5zZXJ2ZXJDbG9zZVJlZiA9IG51bGxcbiAgICB0aGlzLmRvbUNhbGxiYWNrcyA9IE9iamVjdC5hc3NpZ24oe1xuICAgICAgb25QYXRjaFN0YXJ0OiBjbG9zdXJlKCksXG4gICAgICBvblBhdGNoRW5kOiBjbG9zdXJlKCksXG4gICAgICBvbk5vZGVBZGRlZDogY2xvc3VyZSgpLFxuICAgICAgb25CZWZvcmVFbFVwZGF0ZWQ6IGNsb3N1cmUoKX0sXG4gICAgb3B0cy5kb20gfHwge30pXG4gICAgdGhpcy50cmFuc2l0aW9ucyA9IG5ldyBUcmFuc2l0aW9uU2V0KClcbiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihcInBhZ2VoaWRlXCIsIF9lID0+IHtcbiAgICAgIHRoaXMudW5sb2FkZWQgPSB0cnVlXG4gICAgfSlcbiAgICB0aGlzLnNvY2tldC5vbk9wZW4oKCkgPT4ge1xuICAgICAgaWYodGhpcy5pc1VubG9hZGVkKCkpe1xuICAgICAgICAvLyByZWxvYWQgcGFnZSBpZiBiZWluZyByZXN0b3JlZCBmcm9tIGJhY2svZm9yd2FyZCBjYWNoZSBhbmQgYnJvd3NlciBkb2VzIG5vdCBlbWl0IFwicGFnZXNob3dcIlxuICAgICAgICB3aW5kb3cubG9jYXRpb24ucmVsb2FkKClcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgLy8gcHVibGljXG5cbiAgdmVyc2lvbigpeyByZXR1cm4gTFZfVlNOIH1cblxuICBpc1Byb2ZpbGVFbmFibGVkKCl7IHJldHVybiB0aGlzLnNlc3Npb25TdG9yYWdlLmdldEl0ZW0oUEhYX0xWX1BST0ZJTEUpID09PSBcInRydWVcIiB9XG5cbiAgaXNEZWJ1Z0VuYWJsZWQoKXsgcmV0dXJuIHRoaXMuc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShQSFhfTFZfREVCVUcpID09PSBcInRydWVcIiB9XG5cbiAgaXNEZWJ1Z0Rpc2FibGVkKCl7IHJldHVybiB0aGlzLnNlc3Npb25TdG9yYWdlLmdldEl0ZW0oUEhYX0xWX0RFQlVHKSA9PT0gXCJmYWxzZVwiIH1cblxuICBlbmFibGVEZWJ1ZygpeyB0aGlzLnNlc3Npb25TdG9yYWdlLnNldEl0ZW0oUEhYX0xWX0RFQlVHLCBcInRydWVcIikgfVxuXG4gIGVuYWJsZVByb2ZpbGluZygpeyB0aGlzLnNlc3Npb25TdG9yYWdlLnNldEl0ZW0oUEhYX0xWX1BST0ZJTEUsIFwidHJ1ZVwiKSB9XG5cbiAgZGlzYWJsZURlYnVnKCl7IHRoaXMuc2Vzc2lvblN0b3JhZ2Uuc2V0SXRlbShQSFhfTFZfREVCVUcsIFwiZmFsc2VcIikgfVxuXG4gIGRpc2FibGVQcm9maWxpbmcoKXsgdGhpcy5zZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFBIWF9MVl9QUk9GSUxFKSB9XG5cbiAgZW5hYmxlTGF0ZW5jeVNpbSh1cHBlckJvdW5kTXMpe1xuICAgIHRoaXMuZW5hYmxlRGVidWcoKVxuICAgIGNvbnNvbGUubG9nKFwibGF0ZW5jeSBzaW11bGF0b3IgZW5hYmxlZCBmb3IgdGhlIGR1cmF0aW9uIG9mIHRoaXMgYnJvd3NlciBzZXNzaW9uLiBDYWxsIGRpc2FibGVMYXRlbmN5U2ltKCkgdG8gZGlzYWJsZVwiKVxuICAgIHRoaXMuc2Vzc2lvblN0b3JhZ2Uuc2V0SXRlbShQSFhfTFZfTEFURU5DWV9TSU0sIHVwcGVyQm91bmRNcylcbiAgfVxuXG4gIGRpc2FibGVMYXRlbmN5U2ltKCl7IHRoaXMuc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShQSFhfTFZfTEFURU5DWV9TSU0pIH1cblxuICBnZXRMYXRlbmN5U2ltKCl7XG4gICAgbGV0IHN0ciA9IHRoaXMuc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShQSFhfTFZfTEFURU5DWV9TSU0pXG4gICAgcmV0dXJuIHN0ciA/IHBhcnNlSW50KHN0cikgOiBudWxsXG4gIH1cblxuICBnZXRTb2NrZXQoKXsgcmV0dXJuIHRoaXMuc29ja2V0IH1cblxuICBjb25uZWN0KCl7XG4gICAgLy8gZW5hYmxlIGRlYnVnIGJ5IGRlZmF1bHQgaWYgb24gbG9jYWxob3N0IGFuZCBub3QgZXhwbGljaXRseSBkaXNhYmxlZFxuICAgIGlmKHdpbmRvdy5sb2NhdGlvbi5ob3N0bmFtZSA9PT0gXCJsb2NhbGhvc3RcIiAmJiAhdGhpcy5pc0RlYnVnRGlzYWJsZWQoKSl7IHRoaXMuZW5hYmxlRGVidWcoKSB9XG4gICAgbGV0IGRvQ29ubmVjdCA9ICgpID0+IHtcbiAgICAgIGlmKHRoaXMuam9pblJvb3RWaWV3cygpKXtcbiAgICAgICAgdGhpcy5iaW5kVG9wTGV2ZWxFdmVudHMoKVxuICAgICAgICB0aGlzLnNvY2tldC5jb25uZWN0KClcbiAgICAgIH0gZWxzZSBpZih0aGlzLm1haW4pe1xuICAgICAgICB0aGlzLnNvY2tldC5jb25uZWN0KClcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHRoaXMuYmluZFRvcExldmVsRXZlbnRzKHtkZWFkOiB0cnVlfSlcbiAgICAgIH1cbiAgICAgIHRoaXMuam9pbkRlYWRWaWV3KClcbiAgICB9XG4gICAgaWYoW1wiY29tcGxldGVcIiwgXCJsb2FkZWRcIiwgXCJpbnRlcmFjdGl2ZVwiXS5pbmRleE9mKGRvY3VtZW50LnJlYWR5U3RhdGUpID49IDApe1xuICAgICAgZG9Db25uZWN0KClcbiAgICB9IGVsc2Uge1xuICAgICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcihcIkRPTUNvbnRlbnRMb2FkZWRcIiwgKCkgPT4gZG9Db25uZWN0KCkpXG4gICAgfVxuICB9XG5cbiAgZGlzY29ubmVjdChjYWxsYmFjayl7XG4gICAgY2xlYXJUaW1lb3V0KHRoaXMucmVsb2FkV2l0aEppdHRlclRpbWVyKVxuICAgIC8vIHJlbW92ZSB0aGUgc29ja2V0IGNsb3NlIGxpc3RlbmVyIHRvIGF2b2lkIHRyeWluZyB0byBoYW5kbGVcbiAgICAvLyBhIHNlcnZlciBjbG9zZSBldmVudCB3aGVuIGl0IGlzIGFjdHVhbGx5IGNhdXNlZCBieSB1cyBkaXNjb25uZWN0aW5nXG4gICAgaWYodGhpcy5zZXJ2ZXJDbG9zZVJlZil7XG4gICAgICB0aGlzLnNvY2tldC5vZmYodGhpcy5zZXJ2ZXJDbG9zZVJlZilcbiAgICAgIHRoaXMuc2VydmVyQ2xvc2VSZWYgPSBudWxsXG4gICAgfVxuICAgIHRoaXMuc29ja2V0LmRpc2Nvbm5lY3QoY2FsbGJhY2spXG4gIH1cblxuICByZXBsYWNlVHJhbnNwb3J0KHRyYW5zcG9ydCl7XG4gICAgY2xlYXJUaW1lb3V0KHRoaXMucmVsb2FkV2l0aEppdHRlclRpbWVyKVxuICAgIHRoaXMuc29ja2V0LnJlcGxhY2VUcmFuc3BvcnQodHJhbnNwb3J0KVxuICAgIHRoaXMuY29ubmVjdCgpXG4gIH1cblxuICBleGVjSlMoZWwsIGVuY29kZWRKUywgZXZlbnRUeXBlID0gbnVsbCl7XG4gICAgdGhpcy5vd25lcihlbCwgdmlldyA9PiBKUy5leGVjKGV2ZW50VHlwZSwgZW5jb2RlZEpTLCB2aWV3LCBlbCkpXG4gIH1cblxuICAvLyBwcml2YXRlXG5cbiAgZXhlY0pTSG9va1B1c2goZWwsIHBoeEV2ZW50LCBkYXRhLCBjYWxsYmFjayl7XG4gICAgdGhpcy53aXRoaW5Pd25lcnMoZWwsIHZpZXcgPT4ge1xuICAgICAgSlMuZXhlYyhcImhvb2tcIiwgcGh4RXZlbnQsIHZpZXcsIGVsLCBbXCJwdXNoXCIsIHtkYXRhLCBjYWxsYmFja31dKVxuICAgIH0pXG4gIH1cblxuICB1bmxvYWQoKXtcbiAgICBpZih0aGlzLnVubG9hZGVkKXsgcmV0dXJuIH1cbiAgICBpZih0aGlzLm1haW4gJiYgdGhpcy5pc0Nvbm5lY3RlZCgpKXsgdGhpcy5sb2codGhpcy5tYWluLCBcInNvY2tldFwiLCAoKSA9PiBbXCJkaXNjb25uZWN0IGZvciBwYWdlIG5hdlwiXSkgfVxuICAgIHRoaXMudW5sb2FkZWQgPSB0cnVlXG4gICAgdGhpcy5kZXN0cm95QWxsVmlld3MoKVxuICAgIHRoaXMuZGlzY29ubmVjdCgpXG4gIH1cblxuICB0cmlnZ2VyRE9NKGtpbmQsIGFyZ3MpeyB0aGlzLmRvbUNhbGxiYWNrc1traW5kXSguLi5hcmdzKSB9XG5cbiAgdGltZShuYW1lLCBmdW5jKXtcbiAgICBpZighdGhpcy5pc1Byb2ZpbGVFbmFibGVkKCkgfHwgIWNvbnNvbGUudGltZSl7IHJldHVybiBmdW5jKCkgfVxuICAgIGNvbnNvbGUudGltZShuYW1lKVxuICAgIGxldCByZXN1bHQgPSBmdW5jKClcbiAgICBjb25zb2xlLnRpbWVFbmQobmFtZSlcbiAgICByZXR1cm4gcmVzdWx0XG4gIH1cblxuICBsb2codmlldywga2luZCwgbXNnQ2FsbGJhY2spe1xuICAgIGlmKHRoaXMudmlld0xvZ2dlcil7XG4gICAgICBsZXQgW21zZywgb2JqXSA9IG1zZ0NhbGxiYWNrKClcbiAgICAgIHRoaXMudmlld0xvZ2dlcih2aWV3LCBraW5kLCBtc2csIG9iailcbiAgICB9IGVsc2UgaWYodGhpcy5pc0RlYnVnRW5hYmxlZCgpKXtcbiAgICAgIGxldCBbbXNnLCBvYmpdID0gbXNnQ2FsbGJhY2soKVxuICAgICAgZGVidWcodmlldywga2luZCwgbXNnLCBvYmopXG4gICAgfVxuICB9XG5cbiAgcmVxdWVzdERPTVVwZGF0ZShjYWxsYmFjayl7XG4gICAgdGhpcy50cmFuc2l0aW9ucy5hZnRlcihjYWxsYmFjaylcbiAgfVxuXG4gIHRyYW5zaXRpb24odGltZSwgb25TdGFydCwgb25Eb25lID0gZnVuY3Rpb24oKXt9KXtcbiAgICB0aGlzLnRyYW5zaXRpb25zLmFkZFRyYW5zaXRpb24odGltZSwgb25TdGFydCwgb25Eb25lKVxuICB9XG5cbiAgb25DaGFubmVsKGNoYW5uZWwsIGV2ZW50LCBjYil7XG4gICAgY2hhbm5lbC5vbihldmVudCwgZGF0YSA9PiB7XG4gICAgICBsZXQgbGF0ZW5jeSA9IHRoaXMuZ2V0TGF0ZW5jeVNpbSgpXG4gICAgICBpZighbGF0ZW5jeSl7XG4gICAgICAgIGNiKGRhdGEpXG4gICAgICB9IGVsc2Uge1xuICAgICAgICBzZXRUaW1lb3V0KCgpID0+IGNiKGRhdGEpLCBsYXRlbmN5KVxuICAgICAgfVxuICAgIH0pXG4gIH1cblxuICB3cmFwUHVzaCh2aWV3LCBvcHRzLCBwdXNoKXtcbiAgICBsZXQgbGF0ZW5jeSA9IHRoaXMuZ2V0TGF0ZW5jeVNpbSgpXG4gICAgbGV0IG9sZEpvaW5Db3VudCA9IHZpZXcuam9pbkNvdW50XG4gICAgaWYoIWxhdGVuY3kpe1xuICAgICAgaWYodGhpcy5pc0Nvbm5lY3RlZCgpICYmIG9wdHMudGltZW91dCl7XG4gICAgICAgIHJldHVybiBwdXNoKCkucmVjZWl2ZShcInRpbWVvdXRcIiwgKCkgPT4ge1xuICAgICAgICAgIGlmKHZpZXcuam9pbkNvdW50ID09PSBvbGRKb2luQ291bnQgJiYgIXZpZXcuaXNEZXN0cm95ZWQoKSl7XG4gICAgICAgICAgICB0aGlzLnJlbG9hZFdpdGhKaXR0ZXIodmlldywgKCkgPT4ge1xuICAgICAgICAgICAgICB0aGlzLmxvZyh2aWV3LCBcInRpbWVvdXRcIiwgKCkgPT4gW1wicmVjZWl2ZWQgdGltZW91dCB3aGlsZSBjb21tdW5pY2F0aW5nIHdpdGggc2VydmVyLiBGYWxsaW5nIGJhY2sgdG8gaGFyZCByZWZyZXNoIGZvciByZWNvdmVyeVwiXSlcbiAgICAgICAgICAgIH0pXG4gICAgICAgICAgfVxuICAgICAgICB9KVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgcmV0dXJuIHB1c2goKVxuICAgICAgfVxuICAgIH1cblxuICAgIGxldCBmYWtlUHVzaCA9IHtcbiAgICAgIHJlY2VpdmVzOiBbXSxcbiAgICAgIHJlY2VpdmUoa2luZCwgY2IpeyB0aGlzLnJlY2VpdmVzLnB1c2goW2tpbmQsIGNiXSkgfVxuICAgIH1cbiAgICBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgIGlmKHZpZXcuaXNEZXN0cm95ZWQoKSl7IHJldHVybiB9XG4gICAgICBmYWtlUHVzaC5yZWNlaXZlcy5yZWR1Y2UoKGFjYywgW2tpbmQsIGNiXSkgPT4gYWNjLnJlY2VpdmUoa2luZCwgY2IpLCBwdXNoKCkpXG4gICAgfSwgbGF0ZW5jeSlcbiAgICByZXR1cm4gZmFrZVB1c2hcbiAgfVxuXG4gIHJlbG9hZFdpdGhKaXR0ZXIodmlldywgbG9nKXtcbiAgICBjbGVhclRpbWVvdXQodGhpcy5yZWxvYWRXaXRoSml0dGVyVGltZXIpXG4gICAgdGhpcy5kaXNjb25uZWN0KClcbiAgICBsZXQgbWluTXMgPSB0aGlzLnJlbG9hZEppdHRlck1pblxuICAgIGxldCBtYXhNcyA9IHRoaXMucmVsb2FkSml0dGVyTWF4XG4gICAgbGV0IGFmdGVyTXMgPSBNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkgKiAobWF4TXMgLSBtaW5NcyArIDEpKSArIG1pbk1zXG4gICAgbGV0IHRyaWVzID0gQnJvd3Nlci51cGRhdGVMb2NhbCh0aGlzLmxvY2FsU3RvcmFnZSwgd2luZG93LmxvY2F0aW9uLnBhdGhuYW1lLCBDT05TRUNVVElWRV9SRUxPQURTLCAwLCBjb3VudCA9PiBjb3VudCArIDEpXG4gICAgaWYodHJpZXMgPiB0aGlzLm1heFJlbG9hZHMpe1xuICAgICAgYWZ0ZXJNcyA9IHRoaXMuZmFpbHNhZmVKaXR0ZXJcbiAgICB9XG4gICAgdGhpcy5yZWxvYWRXaXRoSml0dGVyVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHtcbiAgICAgIC8vIGlmIHZpZXcgaGFzIHJlY292ZXJlZCwgc3VjaCBhcyB0cmFuc3BvcnQgcmVwbGFjZWQsIHRoZW4gY2FuY2VsXG4gICAgICBpZih2aWV3LmlzRGVzdHJveWVkKCkgfHwgdmlldy5pc0Nvbm5lY3RlZCgpKXsgcmV0dXJuIH1cbiAgICAgIHZpZXcuZGVzdHJveSgpXG4gICAgICBsb2cgPyBsb2coKSA6IHRoaXMubG9nKHZpZXcsIFwiam9pblwiLCAoKSA9PiBbYGVuY291bnRlcmVkICR7dHJpZXN9IGNvbnNlY3V0aXZlIHJlbG9hZHNgXSlcbiAgICAgIGlmKHRyaWVzID4gdGhpcy5tYXhSZWxvYWRzKXtcbiAgICAgICAgdGhpcy5sb2codmlldywgXCJqb2luXCIsICgpID0+IFtgZXhjZWVkZWQgJHt0aGlzLm1heFJlbG9hZHN9IGNvbnNlY3V0aXZlIHJlbG9hZHMuIEVudGVyaW5nIGZhaWxzYWZlIG1vZGVgXSlcbiAgICAgIH1cbiAgICAgIGlmKHRoaXMuaGFzUGVuZGluZ0xpbmsoKSl7XG4gICAgICAgIHdpbmRvdy5sb2NhdGlvbiA9IHRoaXMucGVuZGluZ0xpbmtcbiAgICAgIH0gZWxzZSB7XG4gICAgICAgIHdpbmRvdy5sb2NhdGlvbi5yZWxvYWQoKVxuICAgICAgfVxuICAgIH0sIGFmdGVyTXMpXG4gIH1cblxuICBnZXRIb29rQ2FsbGJhY2tzKG5hbWUpe1xuICAgIHJldHVybiBuYW1lICYmIG5hbWUuc3RhcnRzV2l0aChcIlBob2VuaXguXCIpID8gSG9va3NbbmFtZS5zcGxpdChcIi5cIilbMV1dIDogdGhpcy5ob29rc1tuYW1lXVxuICB9XG5cbiAgaXNVbmxvYWRlZCgpeyByZXR1cm4gdGhpcy51bmxvYWRlZCB9XG5cbiAgaXNDb25uZWN0ZWQoKXsgcmV0dXJuIHRoaXMuc29ja2V0LmlzQ29ubmVjdGVkKCkgfVxuXG4gIGdldEJpbmRpbmdQcmVmaXgoKXsgcmV0dXJuIHRoaXMuYmluZGluZ1ByZWZpeCB9XG5cbiAgYmluZGluZyhraW5kKXsgcmV0dXJuIGAke3RoaXMuZ2V0QmluZGluZ1ByZWZpeCgpfSR7a2luZH1gIH1cblxuICBjaGFubmVsKHRvcGljLCBwYXJhbXMpeyByZXR1cm4gdGhpcy5zb2NrZXQuY2hhbm5lbCh0b3BpYywgcGFyYW1zKSB9XG5cbiAgam9pbkRlYWRWaWV3KCl7XG4gICAgbGV0IGJvZHkgPSBkb2N1bWVudC5ib2R5XG4gICAgaWYoYm9keSAmJiAhdGhpcy5pc1BoeFZpZXcoYm9keSkgJiYgIXRoaXMuaXNQaHhWaWV3KGRvY3VtZW50LmZpcnN0RWxlbWVudENoaWxkKSl7XG4gICAgICBsZXQgdmlldyA9IHRoaXMubmV3Um9vdFZpZXcoYm9keSlcbiAgICAgIHZpZXcuc2V0SHJlZih0aGlzLmdldEhyZWYoKSlcbiAgICAgIHZpZXcuam9pbkRlYWQoKVxuICAgICAgaWYoIXRoaXMubWFpbil7IHRoaXMubWFpbiA9IHZpZXcgfVxuICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB2aWV3LmV4ZWNOZXdNb3VudGVkKCkpXG4gICAgfVxuICB9XG5cbiAgam9pblJvb3RWaWV3cygpe1xuICAgIGxldCByb290c0ZvdW5kID0gZmFsc2VcbiAgICBET00uYWxsKGRvY3VtZW50LCBgJHtQSFhfVklFV19TRUxFQ1RPUn06bm90KFske1BIWF9QQVJFTlRfSUR9XSlgLCByb290RWwgPT4ge1xuICAgICAgaWYoIXRoaXMuZ2V0Um9vdEJ5SWQocm9vdEVsLmlkKSl7XG4gICAgICAgIGxldCB2aWV3ID0gdGhpcy5uZXdSb290Vmlldyhyb290RWwpXG4gICAgICAgIHZpZXcuc2V0SHJlZih0aGlzLmdldEhyZWYoKSlcbiAgICAgICAgdmlldy5qb2luKClcbiAgICAgICAgaWYocm9vdEVsLmhhc0F0dHJpYnV0ZShQSFhfTUFJTikpeyB0aGlzLm1haW4gPSB2aWV3IH1cbiAgICAgIH1cbiAgICAgIHJvb3RzRm91bmQgPSB0cnVlXG4gICAgfSlcbiAgICByZXR1cm4gcm9vdHNGb3VuZFxuICB9XG5cbiAgcmVkaXJlY3QodG8sIGZsYXNoKXtcbiAgICB0aGlzLnVubG9hZCgpXG4gICAgQnJvd3Nlci5yZWRpcmVjdCh0bywgZmxhc2gpXG4gIH1cblxuICByZXBsYWNlTWFpbihocmVmLCBmbGFzaCwgY2FsbGJhY2sgPSBudWxsLCBsaW5rUmVmID0gdGhpcy5zZXRQZW5kaW5nTGluayhocmVmKSl7XG4gICAgbGV0IGxpdmVSZWZlcmVyID0gdGhpcy5jdXJyZW50TG9jYXRpb24uaHJlZlxuICAgIHRoaXMub3V0Z29pbmdNYWluRWwgPSB0aGlzLm91dGdvaW5nTWFpbkVsIHx8IHRoaXMubWFpbi5lbFxuICAgIGxldCBuZXdNYWluRWwgPSBET00uY2xvbmVOb2RlKHRoaXMub3V0Z29pbmdNYWluRWwsIFwiXCIpXG4gICAgdGhpcy5tYWluLnNob3dMb2FkZXIodGhpcy5sb2FkZXJUaW1lb3V0KVxuICAgIHRoaXMubWFpbi5kZXN0cm95KClcblxuICAgIHRoaXMubWFpbiA9IHRoaXMubmV3Um9vdFZpZXcobmV3TWFpbkVsLCBmbGFzaCwgbGl2ZVJlZmVyZXIpXG4gICAgdGhpcy5tYWluLnNldFJlZGlyZWN0KGhyZWYpXG4gICAgdGhpcy50cmFuc2l0aW9uUmVtb3ZlcyhudWxsLCB0cnVlKVxuICAgIHRoaXMubWFpbi5qb2luKChqb2luQ291bnQsIG9uRG9uZSkgPT4ge1xuICAgICAgaWYoam9pbkNvdW50ID09PSAxICYmIHRoaXMuY29tbWl0UGVuZGluZ0xpbmsobGlua1JlZikpe1xuICAgICAgICB0aGlzLnJlcXVlc3RET01VcGRhdGUoKCkgPT4ge1xuICAgICAgICAgIERPTS5maW5kUGh4U3RpY2t5KGRvY3VtZW50KS5mb3JFYWNoKGVsID0+IG5ld01haW5FbC5hcHBlbmRDaGlsZChlbCkpXG4gICAgICAgICAgdGhpcy5vdXRnb2luZ01haW5FbC5yZXBsYWNlV2l0aChuZXdNYWluRWwpXG4gICAgICAgICAgdGhpcy5vdXRnb2luZ01haW5FbCA9IG51bGxcbiAgICAgICAgICBjYWxsYmFjayAmJiBjYWxsYmFjayhsaW5rUmVmKVxuICAgICAgICAgIG9uRG9uZSgpXG4gICAgICAgIH0pXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIHRyYW5zaXRpb25SZW1vdmVzKGVsZW1lbnRzLCBza2lwU3RpY2t5KXtcbiAgICBsZXQgcmVtb3ZlQXR0ciA9IHRoaXMuYmluZGluZyhcInJlbW92ZVwiKVxuICAgIGVsZW1lbnRzID0gZWxlbWVudHMgfHwgRE9NLmFsbChkb2N1bWVudCwgYFske3JlbW92ZUF0dHJ9XWApXG5cbiAgICBpZihza2lwU3RpY2t5KXtcbiAgICAgIGNvbnN0IHN0aWNraWVzID0gRE9NLmZpbmRQaHhTdGlja3koZG9jdW1lbnQpIHx8IFtdXG4gICAgICBlbGVtZW50cyA9IGVsZW1lbnRzLmZpbHRlcihlbCA9PiAhRE9NLmlzQ2hpbGRPZkFueShlbCwgc3RpY2tpZXMpKVxuICAgIH1cbiAgICBlbGVtZW50cy5mb3JFYWNoKGVsID0+IHtcbiAgICAgIHRoaXMuZXhlY0pTKGVsLCBlbC5nZXRBdHRyaWJ1dGUocmVtb3ZlQXR0ciksIFwicmVtb3ZlXCIpXG4gICAgfSlcbiAgfVxuXG4gIGlzUGh4VmlldyhlbCl7IHJldHVybiBlbC5nZXRBdHRyaWJ1dGUgJiYgZWwuZ2V0QXR0cmlidXRlKFBIWF9TRVNTSU9OKSAhPT0gbnVsbCB9XG5cbiAgbmV3Um9vdFZpZXcoZWwsIGZsYXNoLCBsaXZlUmVmZXJlcil7XG4gICAgbGV0IHZpZXcgPSBuZXcgVmlldyhlbCwgdGhpcywgbnVsbCwgZmxhc2gsIGxpdmVSZWZlcmVyKVxuICAgIHRoaXMucm9vdHNbdmlldy5pZF0gPSB2aWV3XG4gICAgcmV0dXJuIHZpZXdcbiAgfVxuXG4gIG93bmVyKGNoaWxkRWwsIGNhbGxiYWNrKXtcbiAgICBsZXQgdmlldyA9IG1heWJlKGNoaWxkRWwuY2xvc2VzdChQSFhfVklFV19TRUxFQ1RPUiksIGVsID0+IHRoaXMuZ2V0Vmlld0J5RWwoZWwpKSB8fCB0aGlzLm1haW5cbiAgICBpZih2aWV3KXsgY2FsbGJhY2sodmlldykgfVxuICB9XG5cbiAgd2l0aGluT3duZXJzKGNoaWxkRWwsIGNhbGxiYWNrKXtcbiAgICB0aGlzLm93bmVyKGNoaWxkRWwsIHZpZXcgPT4gY2FsbGJhY2sodmlldywgY2hpbGRFbCkpXG4gIH1cblxuICBnZXRWaWV3QnlFbChlbCl7XG4gICAgbGV0IHJvb3RJZCA9IGVsLmdldEF0dHJpYnV0ZShQSFhfUk9PVF9JRClcbiAgICByZXR1cm4gbWF5YmUodGhpcy5nZXRSb290QnlJZChyb290SWQpLCByb290ID0+IHJvb3QuZ2V0RGVzY2VuZGVudEJ5RWwoZWwpKVxuICB9XG5cbiAgZ2V0Um9vdEJ5SWQoaWQpeyByZXR1cm4gdGhpcy5yb290c1tpZF0gfVxuXG4gIGRlc3Ryb3lBbGxWaWV3cygpe1xuICAgIGZvcihsZXQgaWQgaW4gdGhpcy5yb290cyl7XG4gICAgICB0aGlzLnJvb3RzW2lkXS5kZXN0cm95KClcbiAgICAgIGRlbGV0ZSB0aGlzLnJvb3RzW2lkXVxuICAgIH1cbiAgICB0aGlzLm1haW4gPSBudWxsXG4gIH1cblxuICBkZXN0cm95Vmlld0J5RWwoZWwpe1xuICAgIGxldCByb290ID0gdGhpcy5nZXRSb290QnlJZChlbC5nZXRBdHRyaWJ1dGUoUEhYX1JPT1RfSUQpKVxuICAgIGlmKHJvb3QgJiYgcm9vdC5pZCA9PT0gZWwuaWQpe1xuICAgICAgcm9vdC5kZXN0cm95KClcbiAgICAgIGRlbGV0ZSB0aGlzLnJvb3RzW3Jvb3QuaWRdXG4gICAgfSBlbHNlIGlmKHJvb3Qpe1xuICAgICAgcm9vdC5kZXN0cm95RGVzY2VuZGVudChlbC5pZClcbiAgICB9XG4gIH1cblxuICBzZXRBY3RpdmVFbGVtZW50KHRhcmdldCl7XG4gICAgaWYodGhpcy5hY3RpdmVFbGVtZW50ID09PSB0YXJnZXQpeyByZXR1cm4gfVxuICAgIHRoaXMuYWN0aXZlRWxlbWVudCA9IHRhcmdldFxuICAgIGxldCBjYW5jZWwgPSAoKSA9PiB7XG4gICAgICBpZih0YXJnZXQgPT09IHRoaXMuYWN0aXZlRWxlbWVudCl7IHRoaXMuYWN0aXZlRWxlbWVudCA9IG51bGwgfVxuICAgICAgdGFyZ2V0LnJlbW92ZUV2ZW50TGlzdGVuZXIoXCJtb3VzZXVwXCIsIHRoaXMpXG4gICAgICB0YXJnZXQucmVtb3ZlRXZlbnRMaXN0ZW5lcihcInRvdWNoZW5kXCIsIHRoaXMpXG4gICAgfVxuICAgIHRhcmdldC5hZGRFdmVudExpc3RlbmVyKFwibW91c2V1cFwiLCBjYW5jZWwpXG4gICAgdGFyZ2V0LmFkZEV2ZW50TGlzdGVuZXIoXCJ0b3VjaGVuZFwiLCBjYW5jZWwpXG4gIH1cblxuICBnZXRBY3RpdmVFbGVtZW50KCl7XG4gICAgaWYoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gZG9jdW1lbnQuYm9keSl7XG4gICAgICByZXR1cm4gdGhpcy5hY3RpdmVFbGVtZW50IHx8IGRvY3VtZW50LmFjdGl2ZUVsZW1lbnRcbiAgICB9IGVsc2Uge1xuICAgICAgLy8gZG9jdW1lbnQuYWN0aXZlRWxlbWVudCBjYW4gYmUgbnVsbCBpbiBJbnRlcm5ldCBFeHBsb3JlciAxMVxuICAgICAgcmV0dXJuIGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgfHwgZG9jdW1lbnQuYm9keVxuICAgIH1cbiAgfVxuXG4gIGRyb3BBY3RpdmVFbGVtZW50KHZpZXcpe1xuICAgIGlmKHRoaXMucHJldkFjdGl2ZSAmJiB2aWV3Lm93bnNFbGVtZW50KHRoaXMucHJldkFjdGl2ZSkpe1xuICAgICAgdGhpcy5wcmV2QWN0aXZlID0gbnVsbFxuICAgIH1cbiAgfVxuXG4gIHJlc3RvcmVQcmV2aW91c2x5QWN0aXZlRm9jdXMoKXtcbiAgICBpZih0aGlzLnByZXZBY3RpdmUgJiYgdGhpcy5wcmV2QWN0aXZlICE9PSBkb2N1bWVudC5ib2R5KXtcbiAgICAgIHRoaXMucHJldkFjdGl2ZS5mb2N1cygpXG4gICAgfVxuICB9XG5cbiAgYmx1ckFjdGl2ZUVsZW1lbnQoKXtcbiAgICB0aGlzLnByZXZBY3RpdmUgPSB0aGlzLmdldEFjdGl2ZUVsZW1lbnQoKVxuICAgIGlmKHRoaXMucHJldkFjdGl2ZSAhPT0gZG9jdW1lbnQuYm9keSl7IHRoaXMucHJldkFjdGl2ZS5ibHVyKCkgfVxuICB9XG5cbiAgYmluZFRvcExldmVsRXZlbnRzKHtkZWFkfSA9IHt9KXtcbiAgICBpZih0aGlzLmJvdW5kVG9wTGV2ZWxFdmVudHMpeyByZXR1cm4gfVxuXG4gICAgdGhpcy5ib3VuZFRvcExldmVsRXZlbnRzID0gdHJ1ZVxuICAgIC8vIGVudGVyIGZhaWxzYWZlIHJlbG9hZCBpZiBzZXJ2ZXIgaGFzIGdvbmUgYXdheSBpbnRlbnRpb25hbGx5LCBzdWNoIGFzIFwiZGlzY29ubmVjdFwiIGJyb2FkY2FzdFxuICAgIHRoaXMuc2VydmVyQ2xvc2VSZWYgPSB0aGlzLnNvY2tldC5vbkNsb3NlKGV2ZW50ID0+IHtcbiAgICAgIC8vIGZhaWxzYWZlIHJlbG9hZCBpZiBub3JtYWwgY2xvc3VyZSBhbmQgd2Ugc3RpbGwgaGF2ZSBhIG1haW4gTFZcbiAgICAgIGlmKGV2ZW50ICYmIGV2ZW50LmNvZGUgPT09IDEwMDAgJiYgdGhpcy5tYWluKXsgcmV0dXJuIHRoaXMucmVsb2FkV2l0aEppdHRlcih0aGlzLm1haW4pIH1cbiAgICB9KVxuICAgIGRvY3VtZW50LmJvZHkuYWRkRXZlbnRMaXN0ZW5lcihcImNsaWNrXCIsIGZ1bmN0aW9uICgpeyB9KSAvLyBlbnN1cmUgYWxsIGNsaWNrIGV2ZW50cyBidWJibGUgZm9yIG1vYmlsZSBTYWZhcmlcbiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihcInBhZ2VzaG93XCIsIGUgPT4ge1xuICAgICAgaWYoZS5wZXJzaXN0ZWQpeyAvLyByZWxvYWQgcGFnZSBpZiBiZWluZyByZXN0b3JlZCBmcm9tIGJhY2svZm9yd2FyZCBjYWNoZVxuICAgICAgICB0aGlzLmdldFNvY2tldCgpLmRpc2Nvbm5lY3QoKVxuICAgICAgICB0aGlzLndpdGhQYWdlTG9hZGluZyh7dG86IHdpbmRvdy5sb2NhdGlvbi5ocmVmLCBraW5kOiBcInJlZGlyZWN0XCJ9KVxuICAgICAgICB3aW5kb3cubG9jYXRpb24ucmVsb2FkKClcbiAgICAgIH1cbiAgICB9LCB0cnVlKVxuICAgIGlmKCFkZWFkKXsgdGhpcy5iaW5kTmF2KCkgfVxuICAgIHRoaXMuYmluZENsaWNrcygpXG4gICAgaWYoIWRlYWQpeyB0aGlzLmJpbmRGb3JtcygpIH1cbiAgICB0aGlzLmJpbmQoe2tleXVwOiBcImtleXVwXCIsIGtleWRvd246IFwia2V5ZG93blwifSwgKGUsIHR5cGUsIHZpZXcsIHRhcmdldEVsLCBwaHhFdmVudCwgcGh4VGFyZ2V0KSA9PiB7XG4gICAgICBsZXQgbWF0Y2hLZXkgPSB0YXJnZXRFbC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFBIWF9LRVkpKVxuICAgICAgbGV0IHByZXNzZWRLZXkgPSBlLmtleSAmJiBlLmtleS50b0xvd2VyQ2FzZSgpIC8vIGNocm9tZSBjbGlja2VkIGF1dG9jb21wbGV0ZXMgc2VuZCBhIGtleWRvd24gd2l0aG91dCBrZXlcbiAgICAgIGlmKG1hdGNoS2V5ICYmIG1hdGNoS2V5LnRvTG93ZXJDYXNlKCkgIT09IHByZXNzZWRLZXkpeyByZXR1cm4gfVxuXG4gICAgICBsZXQgZGF0YSA9IHtrZXk6IGUua2V5LCAuLi50aGlzLmV2ZW50TWV0YSh0eXBlLCBlLCB0YXJnZXRFbCl9XG4gICAgICBKUy5leGVjKHR5cGUsIHBoeEV2ZW50LCB2aWV3LCB0YXJnZXRFbCwgW1wicHVzaFwiLCB7ZGF0YX1dKVxuICAgIH0pXG4gICAgdGhpcy5iaW5kKHtibHVyOiBcImZvY3Vzb3V0XCIsIGZvY3VzOiBcImZvY3VzaW5cIn0sIChlLCB0eXBlLCB2aWV3LCB0YXJnZXRFbCwgcGh4RXZlbnQsIHBoeFRhcmdldCkgPT4ge1xuICAgICAgaWYoIXBoeFRhcmdldCl7XG4gICAgICAgIGxldCBkYXRhID0ge2tleTogZS5rZXksIC4uLnRoaXMuZXZlbnRNZXRhKHR5cGUsIGUsIHRhcmdldEVsKX1cbiAgICAgICAgSlMuZXhlYyh0eXBlLCBwaHhFdmVudCwgdmlldywgdGFyZ2V0RWwsIFtcInB1c2hcIiwge2RhdGF9XSlcbiAgICAgIH1cbiAgICB9KVxuICAgIHRoaXMuYmluZCh7Ymx1cjogXCJibHVyXCIsIGZvY3VzOiBcImZvY3VzXCJ9LCAoZSwgdHlwZSwgdmlldywgdGFyZ2V0RWwsIHBoeEV2ZW50LCBwaHhUYXJnZXQpID0+IHtcbiAgICAgIC8vIGJsdXIgYW5kIGZvY3VzIGFyZSB0cmlnZ2VyZWQgb24gZG9jdW1lbnQgYW5kIHdpbmRvdy4gRGlzY2FyZCBvbmUgdG8gYXZvaWQgZHVwc1xuICAgICAgaWYocGh4VGFyZ2V0ID09PSBcIndpbmRvd1wiKXtcbiAgICAgICAgbGV0IGRhdGEgPSB0aGlzLmV2ZW50TWV0YSh0eXBlLCBlLCB0YXJnZXRFbClcbiAgICAgICAgSlMuZXhlYyh0eXBlLCBwaHhFdmVudCwgdmlldywgdGFyZ2V0RWwsIFtcInB1c2hcIiwge2RhdGF9XSlcbiAgICAgIH1cbiAgICB9KVxuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwiZHJhZ292ZXJcIiwgZSA9PiBlLnByZXZlbnREZWZhdWx0KCkpXG4gICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoXCJkcm9wXCIsIGUgPT4ge1xuICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpXG4gICAgICBsZXQgZHJvcFRhcmdldElkID0gbWF5YmUoY2xvc2VzdFBoeEJpbmRpbmcoZS50YXJnZXQsIHRoaXMuYmluZGluZyhQSFhfRFJPUF9UQVJHRVQpKSwgdHJ1ZVRhcmdldCA9PiB7XG4gICAgICAgIHJldHVybiB0cnVlVGFyZ2V0LmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoUEhYX0RST1BfVEFSR0VUKSlcbiAgICAgIH0pXG4gICAgICBsZXQgZHJvcFRhcmdldCA9IGRyb3BUYXJnZXRJZCAmJiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChkcm9wVGFyZ2V0SWQpXG4gICAgICBsZXQgZmlsZXMgPSBBcnJheS5mcm9tKGUuZGF0YVRyYW5zZmVyLmZpbGVzIHx8IFtdKVxuICAgICAgaWYoIWRyb3BUYXJnZXQgfHwgZHJvcFRhcmdldC5kaXNhYmxlZCB8fCBmaWxlcy5sZW5ndGggPT09IDAgfHwgIShkcm9wVGFyZ2V0LmZpbGVzIGluc3RhbmNlb2YgRmlsZUxpc3QpKXsgcmV0dXJuIH1cblxuICAgICAgTGl2ZVVwbG9hZGVyLnRyYWNrRmlsZXMoZHJvcFRhcmdldCwgZmlsZXMsIGUuZGF0YVRyYW5zZmVyKVxuICAgICAgZHJvcFRhcmdldC5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudChcImlucHV0XCIsIHtidWJibGVzOiB0cnVlfSkpXG4gICAgfSlcbiAgICB0aGlzLm9uKFBIWF9UUkFDS19VUExPQURTLCBlID0+IHtcbiAgICAgIGxldCB1cGxvYWRUYXJnZXQgPSBlLnRhcmdldFxuICAgICAgaWYoIURPTS5pc1VwbG9hZElucHV0KHVwbG9hZFRhcmdldCkpeyByZXR1cm4gfVxuICAgICAgbGV0IGZpbGVzID0gQXJyYXkuZnJvbShlLmRldGFpbC5maWxlcyB8fCBbXSkuZmlsdGVyKGYgPT4gZiBpbnN0YW5jZW9mIEZpbGUgfHwgZiBpbnN0YW5jZW9mIEJsb2IpXG4gICAgICBMaXZlVXBsb2FkZXIudHJhY2tGaWxlcyh1cGxvYWRUYXJnZXQsIGZpbGVzKVxuICAgICAgdXBsb2FkVGFyZ2V0LmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwiaW5wdXRcIiwge2J1YmJsZXM6IHRydWV9KSlcbiAgICB9KVxuICB9XG5cbiAgZXZlbnRNZXRhKGV2ZW50TmFtZSwgZSwgdGFyZ2V0RWwpe1xuICAgIGxldCBjYWxsYmFjayA9IHRoaXMubWV0YWRhdGFDYWxsYmFja3NbZXZlbnROYW1lXVxuICAgIHJldHVybiBjYWxsYmFjayA/IGNhbGxiYWNrKGUsIHRhcmdldEVsKSA6IHt9XG4gIH1cblxuICBzZXRQZW5kaW5nTGluayhocmVmKXtcbiAgICB0aGlzLmxpbmtSZWYrK1xuICAgIHRoaXMucGVuZGluZ0xpbmsgPSBocmVmXG4gICAgcmV0dXJuIHRoaXMubGlua1JlZlxuICB9XG5cbiAgY29tbWl0UGVuZGluZ0xpbmsobGlua1JlZil7XG4gICAgaWYodGhpcy5saW5rUmVmICE9PSBsaW5rUmVmKXtcbiAgICAgIHJldHVybiBmYWxzZVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLmhyZWYgPSB0aGlzLnBlbmRpbmdMaW5rXG4gICAgICB0aGlzLnBlbmRpbmdMaW5rID0gbnVsbFxuICAgICAgcmV0dXJuIHRydWVcbiAgICB9XG4gIH1cblxuICBnZXRIcmVmKCl7IHJldHVybiB0aGlzLmhyZWYgfVxuXG4gIGhhc1BlbmRpbmdMaW5rKCl7IHJldHVybiAhIXRoaXMucGVuZGluZ0xpbmsgfVxuXG4gIGJpbmQoZXZlbnRzLCBjYWxsYmFjayl7XG4gICAgZm9yKGxldCBldmVudCBpbiBldmVudHMpe1xuICAgICAgbGV0IGJyb3dzZXJFdmVudE5hbWUgPSBldmVudHNbZXZlbnRdXG5cbiAgICAgIHRoaXMub24oYnJvd3NlckV2ZW50TmFtZSwgZSA9PiB7XG4gICAgICAgIGxldCBiaW5kaW5nID0gdGhpcy5iaW5kaW5nKGV2ZW50KVxuICAgICAgICBsZXQgd2luZG93QmluZGluZyA9IHRoaXMuYmluZGluZyhgd2luZG93LSR7ZXZlbnR9YClcbiAgICAgICAgbGV0IHRhcmdldFBoeEV2ZW50ID0gZS50YXJnZXQuZ2V0QXR0cmlidXRlICYmIGUudGFyZ2V0LmdldEF0dHJpYnV0ZShiaW5kaW5nKVxuICAgICAgICBpZih0YXJnZXRQaHhFdmVudCl7XG4gICAgICAgICAgdGhpcy5kZWJvdW5jZShlLnRhcmdldCwgZSwgYnJvd3NlckV2ZW50TmFtZSwgKCkgPT4ge1xuICAgICAgICAgICAgdGhpcy53aXRoaW5Pd25lcnMoZS50YXJnZXQsIHZpZXcgPT4ge1xuICAgICAgICAgICAgICBjYWxsYmFjayhlLCBldmVudCwgdmlldywgZS50YXJnZXQsIHRhcmdldFBoeEV2ZW50LCBudWxsKVxuICAgICAgICAgICAgfSlcbiAgICAgICAgICB9KVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIERPTS5hbGwoZG9jdW1lbnQsIGBbJHt3aW5kb3dCaW5kaW5nfV1gLCBlbCA9PiB7XG4gICAgICAgICAgICBsZXQgcGh4RXZlbnQgPSBlbC5nZXRBdHRyaWJ1dGUod2luZG93QmluZGluZylcbiAgICAgICAgICAgIHRoaXMuZGVib3VuY2UoZWwsIGUsIGJyb3dzZXJFdmVudE5hbWUsICgpID0+IHtcbiAgICAgICAgICAgICAgdGhpcy53aXRoaW5Pd25lcnMoZWwsIHZpZXcgPT4ge1xuICAgICAgICAgICAgICAgIGNhbGxiYWNrKGUsIGV2ZW50LCB2aWV3LCBlbCwgcGh4RXZlbnQsIFwid2luZG93XCIpXG4gICAgICAgICAgICAgIH0pXG4gICAgICAgICAgICB9KVxuICAgICAgICAgIH0pXG4gICAgICAgIH1cbiAgICAgIH0pXG4gICAgfVxuICB9XG5cbiAgYmluZENsaWNrcygpe1xuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwibW91c2Vkb3duXCIsIGUgPT4gdGhpcy5jbGlja1N0YXJ0ZWRBdFRhcmdldCA9IGUudGFyZ2V0KVxuICAgIHRoaXMuYmluZENsaWNrKFwiY2xpY2tcIiwgXCJjbGlja1wiKVxuICB9XG5cbiAgYmluZENsaWNrKGV2ZW50TmFtZSwgYmluZGluZ05hbWUpe1xuICAgIGxldCBjbGljayA9IHRoaXMuYmluZGluZyhiaW5kaW5nTmFtZSlcbiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihldmVudE5hbWUsIGUgPT4ge1xuICAgICAgbGV0IHRhcmdldCA9IG51bGxcbiAgICAgIC8vIGEgc3ludGhldGljIGNsaWNrIGV2ZW50IChkZXRhaWwgMCkgd2lsbCBub3QgaGF2ZSBjYXVzZWQgYSBtb3VzZWRvd24gZXZlbnQsXG4gICAgICAvLyB0aGVyZWZvcmUgdGhlIGNsaWNrU3RhcnRlZEF0VGFyZ2V0IGlzIHN0YWxlXG4gICAgICBpZihlLmRldGFpbCA9PT0gMCkgdGhpcy5jbGlja1N0YXJ0ZWRBdFRhcmdldCA9IGUudGFyZ2V0XG4gICAgICBsZXQgY2xpY2tTdGFydGVkQXRUYXJnZXQgPSB0aGlzLmNsaWNrU3RhcnRlZEF0VGFyZ2V0IHx8IGUudGFyZ2V0XG4gICAgICB0YXJnZXQgPSBjbG9zZXN0UGh4QmluZGluZyhjbGlja1N0YXJ0ZWRBdFRhcmdldCwgY2xpY2spXG4gICAgICB0aGlzLmRpc3BhdGNoQ2xpY2tBd2F5KGUsIGNsaWNrU3RhcnRlZEF0VGFyZ2V0KVxuICAgICAgdGhpcy5jbGlja1N0YXJ0ZWRBdFRhcmdldCA9IG51bGxcbiAgICAgIGxldCBwaHhFdmVudCA9IHRhcmdldCAmJiB0YXJnZXQuZ2V0QXR0cmlidXRlKGNsaWNrKVxuICAgICAgaWYoIXBoeEV2ZW50KXtcbiAgICAgICAgaWYoRE9NLmlzTmV3UGFnZUNsaWNrKGUsIHdpbmRvdy5sb2NhdGlvbikpeyB0aGlzLnVubG9hZCgpIH1cbiAgICAgICAgcmV0dXJuXG4gICAgICB9XG5cbiAgICAgIGlmKHRhcmdldC5nZXRBdHRyaWJ1dGUoXCJocmVmXCIpID09PSBcIiNcIil7IGUucHJldmVudERlZmF1bHQoKSB9XG5cbiAgICAgIC8vIG5vb3AgaWYgd2UgYXJlIGluIHRoZSBtaWRkbGUgb2YgYXdhaXRpbmcgYW4gYWNrIGZvciB0aGlzIGVsIGFscmVhZHlcbiAgICAgIGlmKHRhcmdldC5oYXNBdHRyaWJ1dGUoUEhYX1JFRikpeyByZXR1cm4gfVxuXG4gICAgICB0aGlzLmRlYm91bmNlKHRhcmdldCwgZSwgXCJjbGlja1wiLCAoKSA9PiB7XG4gICAgICAgIHRoaXMud2l0aGluT3duZXJzKHRhcmdldCwgdmlldyA9PiB7XG4gICAgICAgICAgSlMuZXhlYyhcImNsaWNrXCIsIHBoeEV2ZW50LCB2aWV3LCB0YXJnZXQsIFtcInB1c2hcIiwge2RhdGE6IHRoaXMuZXZlbnRNZXRhKFwiY2xpY2tcIiwgZSwgdGFyZ2V0KX1dKVxuICAgICAgICB9KVxuICAgICAgfSlcbiAgICB9LCBmYWxzZSlcbiAgfVxuXG4gIGRpc3BhdGNoQ2xpY2tBd2F5KGUsIGNsaWNrU3RhcnRlZEF0KXtcbiAgICBsZXQgcGh4Q2xpY2tBd2F5ID0gdGhpcy5iaW5kaW5nKFwiY2xpY2stYXdheVwiKVxuICAgIERPTS5hbGwoZG9jdW1lbnQsIGBbJHtwaHhDbGlja0F3YXl9XWAsIGVsID0+IHtcbiAgICAgIGlmKCEoZWwuaXNTYW1lTm9kZShjbGlja1N0YXJ0ZWRBdCkgfHwgZWwuY29udGFpbnMoY2xpY2tTdGFydGVkQXQpKSl7XG4gICAgICAgIHRoaXMud2l0aGluT3duZXJzKGVsLCB2aWV3ID0+IHtcbiAgICAgICAgICBsZXQgcGh4RXZlbnQgPSBlbC5nZXRBdHRyaWJ1dGUocGh4Q2xpY2tBd2F5KVxuICAgICAgICAgIGlmKEpTLmlzVmlzaWJsZShlbCkgJiYgSlMuaXNJblZpZXdwb3J0KGVsKSl7XG4gICAgICAgICAgICBKUy5leGVjKFwiY2xpY2tcIiwgcGh4RXZlbnQsIHZpZXcsIGVsLCBbXCJwdXNoXCIsIHtkYXRhOiB0aGlzLmV2ZW50TWV0YShcImNsaWNrXCIsIGUsIGUudGFyZ2V0KX1dKVxuICAgICAgICAgIH1cbiAgICAgICAgfSlcbiAgICAgIH1cbiAgICB9KVxuICB9XG5cbiAgYmluZE5hdigpe1xuICAgIGlmKCFCcm93c2VyLmNhblB1c2hTdGF0ZSgpKXsgcmV0dXJuIH1cbiAgICBpZihoaXN0b3J5LnNjcm9sbFJlc3RvcmF0aW9uKXsgaGlzdG9yeS5zY3JvbGxSZXN0b3JhdGlvbiA9IFwibWFudWFsXCIgfVxuICAgIGxldCBzY3JvbGxUaW1lciA9IG51bGxcbiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcihcInNjcm9sbFwiLCBfZSA9PiB7XG4gICAgICBjbGVhclRpbWVvdXQoc2Nyb2xsVGltZXIpXG4gICAgICBzY3JvbGxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4ge1xuICAgICAgICBCcm93c2VyLnVwZGF0ZUN1cnJlbnRTdGF0ZShzdGF0ZSA9PiBPYmplY3QuYXNzaWduKHN0YXRlLCB7c2Nyb2xsOiB3aW5kb3cuc2Nyb2xsWX0pKVxuICAgICAgfSwgMTAwKVxuICAgIH0pXG4gICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoXCJwb3BzdGF0ZVwiLCBldmVudCA9PiB7XG4gICAgICBpZighdGhpcy5yZWdpc3Rlck5ld0xvY2F0aW9uKHdpbmRvdy5sb2NhdGlvbikpeyByZXR1cm4gfVxuICAgICAgbGV0IHt0eXBlLCBpZCwgcm9vdCwgc2Nyb2xsfSA9IGV2ZW50LnN0YXRlIHx8IHt9XG4gICAgICBsZXQgaHJlZiA9IHdpbmRvdy5sb2NhdGlvbi5ocmVmXG5cbiAgICAgIERPTS5kaXNwYXRjaEV2ZW50KHdpbmRvdywgXCJwaHg6bmF2aWdhdGVcIiwge2RldGFpbDoge2hyZWYsIHBhdGNoOiB0eXBlID09PSBcInBhdGNoXCIsIHBvcDogdHJ1ZX19KVxuICAgICAgdGhpcy5yZXF1ZXN0RE9NVXBkYXRlKCgpID0+IHtcbiAgICAgICAgaWYodGhpcy5tYWluLmlzQ29ubmVjdGVkKCkgJiYgKHR5cGUgPT09IFwicGF0Y2hcIiAmJiBpZCA9PT0gdGhpcy5tYWluLmlkKSl7XG4gICAgICAgICAgdGhpcy5tYWluLnB1c2hMaW5rUGF0Y2goaHJlZiwgbnVsbCwgKCkgPT4ge1xuICAgICAgICAgICAgdGhpcy5tYXliZVNjcm9sbChzY3JvbGwpXG4gICAgICAgICAgfSlcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICB0aGlzLnJlcGxhY2VNYWluKGhyZWYsIG51bGwsICgpID0+IHtcbiAgICAgICAgICAgIGlmKHJvb3QpeyB0aGlzLnJlcGxhY2VSb290SGlzdG9yeSgpIH1cbiAgICAgICAgICAgIHRoaXMubWF5YmVTY3JvbGwoc2Nyb2xsKVxuICAgICAgICAgIH0pXG4gICAgICAgIH1cbiAgICAgIH0pXG4gICAgfSwgZmFsc2UpXG4gICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoXCJjbGlja1wiLCBlID0+IHtcbiAgICAgIGxldCB0YXJnZXQgPSBjbG9zZXN0UGh4QmluZGluZyhlLnRhcmdldCwgUEhYX0xJVkVfTElOSylcbiAgICAgIGxldCB0eXBlID0gdGFyZ2V0ICYmIHRhcmdldC5nZXRBdHRyaWJ1dGUoUEhYX0xJVkVfTElOSylcbiAgICAgIGlmKCF0eXBlIHx8ICF0aGlzLmlzQ29ubmVjdGVkKCkgfHwgIXRoaXMubWFpbiB8fCBET00ud2FudHNOZXdUYWIoZSkpeyByZXR1cm4gfVxuXG4gICAgICAvLyBXaGVuIHdyYXBwaW5nIGFuIFNWRyBlbGVtZW50IGluIGFuIGFuY2hvciB0YWcsIHRoZSBocmVmIGNhbiBiZSBhbiBTVkdBbmltYXRlZFN0cmluZ1xuICAgICAgbGV0IGhyZWYgPSB0YXJnZXQuaHJlZiBpbnN0YW5jZW9mIFNWR0FuaW1hdGVkU3RyaW5nID8gdGFyZ2V0LmhyZWYuYmFzZVZhbCA6IHRhcmdldC5ocmVmXG5cbiAgICAgIGxldCBsaW5rU3RhdGUgPSB0YXJnZXQuZ2V0QXR0cmlidXRlKFBIWF9MSU5LX1NUQVRFKVxuICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpXG4gICAgICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpIC8vIGRvIG5vdCBidWJibGUgY2xpY2sgdG8gcmVndWxhciBwaHgtY2xpY2sgYmluZGluZ3NcbiAgICAgIGlmKHRoaXMucGVuZGluZ0xpbmsgPT09IGhyZWYpeyByZXR1cm4gfVxuXG4gICAgICB0aGlzLnJlcXVlc3RET01VcGRhdGUoKCkgPT4ge1xuICAgICAgICBpZih0eXBlID09PSBcInBhdGNoXCIpe1xuICAgICAgICAgIHRoaXMucHVzaEhpc3RvcnlQYXRjaChocmVmLCBsaW5rU3RhdGUsIHRhcmdldClcbiAgICAgICAgfSBlbHNlIGlmKHR5cGUgPT09IFwicmVkaXJlY3RcIil7XG4gICAgICAgICAgdGhpcy5oaXN0b3J5UmVkaXJlY3QoaHJlZiwgbGlua1N0YXRlKVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIHRocm93IG5ldyBFcnJvcihgZXhwZWN0ZWQgJHtQSFhfTElWRV9MSU5LfSB0byBiZSBcInBhdGNoXCIgb3IgXCJyZWRpcmVjdFwiLCBnb3Q6ICR7dHlwZX1gKVxuICAgICAgICB9XG4gICAgICAgIGxldCBwaHhDbGljayA9IHRhcmdldC5nZXRBdHRyaWJ1dGUodGhpcy5iaW5kaW5nKFwiY2xpY2tcIikpXG4gICAgICAgIGlmKHBoeENsaWNrKXtcbiAgICAgICAgICB0aGlzLnJlcXVlc3RET01VcGRhdGUoKCkgPT4gdGhpcy5leGVjSlModGFyZ2V0LCBwaHhDbGljaywgXCJjbGlja1wiKSlcbiAgICAgICAgfVxuICAgICAgfSlcbiAgICB9LCBmYWxzZSlcbiAgfVxuXG4gIG1heWJlU2Nyb2xsKHNjcm9sbCl7XG4gICAgaWYodHlwZW9mKHNjcm9sbCkgPT09IFwibnVtYmVyXCIpe1xuICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHtcbiAgICAgICAgd2luZG93LnNjcm9sbFRvKDAsIHNjcm9sbClcbiAgICAgIH0pIC8vIHRoZSBib2R5IG5lZWRzIHRvIHJlbmRlciBiZWZvcmUgd2Ugc2Nyb2xsLlxuICAgIH1cbiAgfVxuXG4gIGRpc3BhdGNoRXZlbnQoZXZlbnQsIHBheWxvYWQgPSB7fSl7XG4gICAgRE9NLmRpc3BhdGNoRXZlbnQod2luZG93LCBgcGh4OiR7ZXZlbnR9YCwge2RldGFpbDogcGF5bG9hZH0pXG4gIH1cblxuICBkaXNwYXRjaEV2ZW50cyhldmVudHMpe1xuICAgIGV2ZW50cy5mb3JFYWNoKChbZXZlbnQsIHBheWxvYWRdKSA9PiB0aGlzLmRpc3BhdGNoRXZlbnQoZXZlbnQsIHBheWxvYWQpKVxuICB9XG5cbiAgd2l0aFBhZ2VMb2FkaW5nKGluZm8sIGNhbGxiYWNrKXtcbiAgICBET00uZGlzcGF0Y2hFdmVudCh3aW5kb3csIFwicGh4OnBhZ2UtbG9hZGluZy1zdGFydFwiLCB7ZGV0YWlsOiBpbmZvfSlcbiAgICBsZXQgZG9uZSA9ICgpID0+IERPTS5kaXNwYXRjaEV2ZW50KHdpbmRvdywgXCJwaHg6cGFnZS1sb2FkaW5nLXN0b3BcIiwge2RldGFpbDogaW5mb30pXG4gICAgcmV0dXJuIGNhbGxiYWNrID8gY2FsbGJhY2soZG9uZSkgOiBkb25lXG4gIH1cblxuICBwdXNoSGlzdG9yeVBhdGNoKGhyZWYsIGxpbmtTdGF0ZSwgdGFyZ2V0RWwpe1xuICAgIGlmKCF0aGlzLmlzQ29ubmVjdGVkKCkgfHwgIXRoaXMubWFpbi5pc01haW4oKSl7IHJldHVybiBCcm93c2VyLnJlZGlyZWN0KGhyZWYpIH1cblxuICAgIHRoaXMud2l0aFBhZ2VMb2FkaW5nKHt0bzogaHJlZiwga2luZDogXCJwYXRjaFwifSwgZG9uZSA9PiB7XG4gICAgICB0aGlzLm1haW4ucHVzaExpbmtQYXRjaChocmVmLCB0YXJnZXRFbCwgbGlua1JlZiA9PiB7XG4gICAgICAgIHRoaXMuaGlzdG9yeVBhdGNoKGhyZWYsIGxpbmtTdGF0ZSwgbGlua1JlZilcbiAgICAgICAgZG9uZSgpXG4gICAgICB9KVxuICAgIH0pXG4gIH1cblxuICBoaXN0b3J5UGF0Y2goaHJlZiwgbGlua1N0YXRlLCBsaW5rUmVmID0gdGhpcy5zZXRQZW5kaW5nTGluayhocmVmKSl7XG4gICAgaWYoIXRoaXMuY29tbWl0UGVuZGluZ0xpbmsobGlua1JlZikpeyByZXR1cm4gfVxuXG4gICAgQnJvd3Nlci5wdXNoU3RhdGUobGlua1N0YXRlLCB7dHlwZTogXCJwYXRjaFwiLCBpZDogdGhpcy5tYWluLmlkfSwgaHJlZilcbiAgICBET00uZGlzcGF0Y2hFdmVudCh3aW5kb3csIFwicGh4Om5hdmlnYXRlXCIsIHtkZXRhaWw6IHtwYXRjaDogdHJ1ZSwgaHJlZiwgcG9wOiBmYWxzZX19KVxuICAgIHRoaXMucmVnaXN0ZXJOZXdMb2NhdGlvbih3aW5kb3cubG9jYXRpb24pXG4gIH1cblxuICBoaXN0b3J5UmVkaXJlY3QoaHJlZiwgbGlua1N0YXRlLCBmbGFzaCl7XG4gICAgaWYoIXRoaXMuaXNDb25uZWN0ZWQoKSB8fCAhdGhpcy5tYWluLmlzTWFpbigpKXsgcmV0dXJuIEJyb3dzZXIucmVkaXJlY3QoaHJlZiwgZmxhc2gpIH1cblxuICAgIC8vIGNvbnZlcnQgdG8gZnVsbCBocmVmIGlmIG9ubHkgcGF0aCBwcmVmaXhcbiAgICBpZigvXlxcLyR8XlxcL1teXFwvXSsuKiQvLnRlc3QoaHJlZikpe1xuICAgICAgbGV0IHtwcm90b2NvbCwgaG9zdH0gPSB3aW5kb3cubG9jYXRpb25cbiAgICAgIGhyZWYgPSBgJHtwcm90b2NvbH0vLyR7aG9zdH0ke2hyZWZ9YFxuICAgIH1cbiAgICBsZXQgc2Nyb2xsID0gd2luZG93LnNjcm9sbFlcbiAgICB0aGlzLndpdGhQYWdlTG9hZGluZyh7dG86IGhyZWYsIGtpbmQ6IFwicmVkaXJlY3RcIn0sIGRvbmUgPT4ge1xuICAgICAgdGhpcy5yZXBsYWNlTWFpbihocmVmLCBmbGFzaCwgKGxpbmtSZWYpID0+IHtcbiAgICAgICAgaWYobGlua1JlZiA9PT0gdGhpcy5saW5rUmVmKXtcbiAgICAgICAgICBCcm93c2VyLnB1c2hTdGF0ZShsaW5rU3RhdGUsIHt0eXBlOiBcInJlZGlyZWN0XCIsIGlkOiB0aGlzLm1haW4uaWQsIHNjcm9sbDogc2Nyb2xsfSwgaHJlZilcbiAgICAgICAgICBET00uZGlzcGF0Y2hFdmVudCh3aW5kb3csIFwicGh4Om5hdmlnYXRlXCIsIHtkZXRhaWw6IHtocmVmLCBwYXRjaDogZmFsc2UsIHBvcDogZmFsc2V9fSlcbiAgICAgICAgICB0aGlzLnJlZ2lzdGVyTmV3TG9jYXRpb24od2luZG93LmxvY2F0aW9uKVxuICAgICAgICB9XG4gICAgICAgIGRvbmUoKVxuICAgICAgfSlcbiAgICB9KVxuICB9XG5cbiAgcmVwbGFjZVJvb3RIaXN0b3J5KCl7XG4gICAgQnJvd3Nlci5wdXNoU3RhdGUoXCJyZXBsYWNlXCIsIHtyb290OiB0cnVlLCB0eXBlOiBcInBhdGNoXCIsIGlkOiB0aGlzLm1haW4uaWR9KVxuICB9XG5cbiAgcmVnaXN0ZXJOZXdMb2NhdGlvbihuZXdMb2NhdGlvbil7XG4gICAgbGV0IHtwYXRobmFtZSwgc2VhcmNofSA9IHRoaXMuY3VycmVudExvY2F0aW9uXG4gICAgaWYocGF0aG5hbWUgKyBzZWFyY2ggPT09IG5ld0xvY2F0aW9uLnBhdGhuYW1lICsgbmV3TG9jYXRpb24uc2VhcmNoKXtcbiAgICAgIHJldHVybiBmYWxzZVxuICAgIH0gZWxzZSB7XG4gICAgICB0aGlzLmN1cnJlbnRMb2NhdGlvbiA9IGNsb25lKG5ld0xvY2F0aW9uKVxuICAgICAgcmV0dXJuIHRydWVcbiAgICB9XG4gIH1cblxuICBiaW5kRm9ybXMoKXtcbiAgICBsZXQgaXRlcmF0aW9ucyA9IDBcbiAgICBsZXQgZXh0ZXJuYWxGb3JtU3VibWl0dGVkID0gZmFsc2VcblxuICAgIC8vIGRpc2FibGUgZm9ybXMgb24gc3VibWl0IHRoYXQgdHJhY2sgcGh4LWNoYW5nZSBidXQgcGVyZm9ybSBleHRlcm5hbCBzdWJtaXRcbiAgICB0aGlzLm9uKFwic3VibWl0XCIsIGUgPT4ge1xuICAgICAgbGV0IHBoeFN1Ym1pdCA9IGUudGFyZ2V0LmdldEF0dHJpYnV0ZSh0aGlzLmJpbmRpbmcoXCJzdWJtaXRcIikpXG4gICAgICBsZXQgcGh4Q2hhbmdlID0gZS50YXJnZXQuZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhcImNoYW5nZVwiKSlcbiAgICAgIGlmKCFleHRlcm5hbEZvcm1TdWJtaXR0ZWQgJiYgcGh4Q2hhbmdlICYmICFwaHhTdWJtaXQpe1xuICAgICAgICBleHRlcm5hbEZvcm1TdWJtaXR0ZWQgPSB0cnVlXG4gICAgICAgIGUucHJldmVudERlZmF1bHQoKVxuICAgICAgICB0aGlzLndpdGhpbk93bmVycyhlLnRhcmdldCwgdmlldyA9PiB7XG4gICAgICAgICAgdmlldy5kaXNhYmxlRm9ybShlLnRhcmdldClcbiAgICAgICAgICAvLyBzYWZhcmkgbmVlZHMgbmV4dCB0aWNrXG4gICAgICAgICAgd2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7XG4gICAgICAgICAgICBpZihET00uaXNVbmxvYWRhYmxlRm9ybVN1Ym1pdChlKSl7IHRoaXMudW5sb2FkKCkgfVxuICAgICAgICAgICAgZS50YXJnZXQuc3VibWl0KClcbiAgICAgICAgICB9KVxuICAgICAgICB9KVxuICAgICAgfVxuICAgIH0sIHRydWUpXG5cbiAgICB0aGlzLm9uKFwic3VibWl0XCIsIGUgPT4ge1xuICAgICAgbGV0IHBoeEV2ZW50ID0gZS50YXJnZXQuZ2V0QXR0cmlidXRlKHRoaXMuYmluZGluZyhcInN1Ym1pdFwiKSlcbiAgICAgIGlmKCFwaHhFdmVudCl7XG4gICAgICAgIGlmKERPTS5pc1VubG9hZGFibGVGb3JtU3VibWl0KGUpKXsgdGhpcy51bmxvYWQoKSB9XG4gICAgICAgIHJldHVyblxuICAgICAgfVxuICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpXG4gICAgICBlLnRhcmdldC5kaXNhYmxlZCA9IHRydWVcbiAgICAgIHRoaXMud2l0aGluT3duZXJzKGUudGFyZ2V0LCB2aWV3ID0+IHtcbiAgICAgICAgSlMuZXhlYyhcInN1Ym1pdFwiLCBwaHhFdmVudCwgdmlldywgZS50YXJnZXQsIFtcInB1c2hcIiwge3N1Ym1pdHRlcjogZS5zdWJtaXR0ZXJ9XSlcbiAgICAgIH0pXG4gICAgfSwgZmFsc2UpXG5cbiAgICBmb3IobGV0IHR5cGUgb2YgW1wiY2hhbmdlXCIsIFwiaW5wdXRcIl0pe1xuICAgICAgdGhpcy5vbih0eXBlLCBlID0+IHtcbiAgICAgICAgbGV0IHBoeENoYW5nZSA9IHRoaXMuYmluZGluZyhcImNoYW5nZVwiKVxuICAgICAgICBsZXQgaW5wdXQgPSBlLnRhcmdldFxuICAgICAgICBsZXQgaW5wdXRFdmVudCA9IGlucHV0LmdldEF0dHJpYnV0ZShwaHhDaGFuZ2UpXG4gICAgICAgIGxldCBmb3JtRXZlbnQgPSBpbnB1dC5mb3JtICYmIGlucHV0LmZvcm0uZ2V0QXR0cmlidXRlKHBoeENoYW5nZSlcbiAgICAgICAgbGV0IHBoeEV2ZW50ID0gaW5wdXRFdmVudCB8fCBmb3JtRXZlbnRcbiAgICAgICAgaWYoIXBoeEV2ZW50KXsgcmV0dXJuIH1cbiAgICAgICAgaWYoaW5wdXQudHlwZSA9PT0gXCJudW1iZXJcIiAmJiBpbnB1dC52YWxpZGl0eSAmJiBpbnB1dC52YWxpZGl0eS5iYWRJbnB1dCl7IHJldHVybiB9XG5cbiAgICAgICAgbGV0IGRpc3BhdGNoZXIgPSBpbnB1dEV2ZW50ID8gaW5wdXQgOiBpbnB1dC5mb3JtXG4gICAgICAgIGxldCBjdXJyZW50SXRlcmF0aW9ucyA9IGl0ZXJhdGlvbnNcbiAgICAgICAgaXRlcmF0aW9ucysrXG4gICAgICAgIGxldCB7YXQ6IGF0LCB0eXBlOiBsYXN0VHlwZX0gPSBET00ucHJpdmF0ZShpbnB1dCwgXCJwcmV2LWl0ZXJhdGlvblwiKSB8fCB7fVxuICAgICAgICAvLyBCcm93c2VycyBzaG91bGQgYWx3YXlzIGZpcmUgYXQgbGVhc3Qgb25lIFwiaW5wdXRcIiBldmVudCBiZWZvcmUgZXZlcnkgXCJjaGFuZ2VcIlxuICAgICAgICAvLyBJZ25vcmUgXCJjaGFuZ2VcIiBldmVudHMsIHVubGVzcyB0aGVyZSB3YXMgbm8gcHJpb3IgXCJpbnB1dFwiIGV2ZW50LlxuICAgICAgICAvLyBUaGlzIGNvdWxkIGhhcHBlbiBpZiB1c2VyIGNvZGUgdHJpZ2dlcnMgYSBcImNoYW5nZVwiIGV2ZW50LCBvciBpZiB0aGUgYnJvd3NlciBpcyBub24tY29uZm9ybWluZy5cbiAgICAgICAgaWYoYXQgPT09IGN1cnJlbnRJdGVyYXRpb25zIC0gMSAmJiB0eXBlID09PSBcImNoYW5nZVwiICYmIGxhc3RUeXBlID09PSBcImlucHV0XCIpeyByZXR1cm4gfVxuXG4gICAgICAgIERPTS5wdXRQcml2YXRlKGlucHV0LCBcInByZXYtaXRlcmF0aW9uXCIsIHthdDogY3VycmVudEl0ZXJhdGlvbnMsIHR5cGU6IHR5cGV9KVxuXG4gICAgICAgIHRoaXMuZGVib3VuY2UoaW5wdXQsIGUsIHR5cGUsICgpID0+IHtcbiAgICAgICAgICB0aGlzLndpdGhpbk93bmVycyhkaXNwYXRjaGVyLCB2aWV3ID0+IHtcbiAgICAgICAgICAgIERPTS5wdXRQcml2YXRlKGlucHV0LCBQSFhfSEFTX0ZPQ1VTRUQsIHRydWUpXG4gICAgICAgICAgICBpZighRE9NLmlzVGV4dHVhbElucHV0KGlucHV0KSl7XG4gICAgICAgICAgICAgIHRoaXMuc2V0QWN0aXZlRWxlbWVudChpbnB1dClcbiAgICAgICAgICAgIH1cbiAgICAgICAgICAgIEpTLmV4ZWMoXCJjaGFuZ2VcIiwgcGh4RXZlbnQsIHZpZXcsIGlucHV0LCBbXCJwdXNoXCIsIHtfdGFyZ2V0OiBlLnRhcmdldC5uYW1lLCBkaXNwYXRjaGVyOiBkaXNwYXRjaGVyfV0pXG4gICAgICAgICAgfSlcbiAgICAgICAgfSlcbiAgICAgIH0sIGZhbHNlKVxuICAgIH1cbiAgICB0aGlzLm9uKFwicmVzZXRcIiwgKGUpID0+IHtcbiAgICAgIGxldCBmb3JtID0gZS50YXJnZXRcbiAgICAgIERPTS5yZXNldEZvcm0oZm9ybSwgdGhpcy5iaW5kaW5nKFBIWF9GRUVEQkFDS19GT1IpLCB0aGlzLmJpbmRpbmcoUEhYX0ZFRURCQUNLX0dST1VQKSlcbiAgICAgIGxldCBpbnB1dCA9IEFycmF5LmZyb20oZm9ybS5lbGVtZW50cykuZmluZChlbCA9PiBlbC50eXBlID09PSBcInJlc2V0XCIpXG4gICAgICBpZihpbnB1dCl7XG4gICAgICAgIC8vIHdhaXQgdW50aWwgbmV4dCB0aWNrIHRvIGdldCB1cGRhdGVkIGlucHV0IHZhbHVlXG4gICAgICAgIHdpbmRvdy5yZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgICAgIGlucHV0LmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KFwiaW5wdXRcIiwge2J1YmJsZXM6IHRydWUsIGNhbmNlbGFibGU6IGZhbHNlfSkpXG4gICAgICAgIH0pXG4gICAgICB9XG4gICAgfSlcbiAgfVxuXG4gIGRlYm91bmNlKGVsLCBldmVudCwgZXZlbnRUeXBlLCBjYWxsYmFjayl7XG4gICAgaWYoZXZlbnRUeXBlID09PSBcImJsdXJcIiB8fCBldmVudFR5cGUgPT09IFwiZm9jdXNvdXRcIil7IHJldHVybiBjYWxsYmFjaygpIH1cblxuICAgIGxldCBwaHhEZWJvdW5jZSA9IHRoaXMuYmluZGluZyhQSFhfREVCT1VOQ0UpXG4gICAgbGV0IHBoeFRocm90dGxlID0gdGhpcy5iaW5kaW5nKFBIWF9USFJPVFRMRSlcbiAgICBsZXQgZGVmYXVsdERlYm91bmNlID0gdGhpcy5kZWZhdWx0cy5kZWJvdW5jZS50b1N0cmluZygpXG4gICAgbGV0IGRlZmF1bHRUaHJvdHRsZSA9IHRoaXMuZGVmYXVsdHMudGhyb3R0bGUudG9TdHJpbmcoKVxuXG4gICAgdGhpcy53aXRoaW5Pd25lcnMoZWwsIHZpZXcgPT4ge1xuICAgICAgbGV0IGFzeW5jRmlsdGVyID0gKCkgPT4gIXZpZXcuaXNEZXN0cm95ZWQoKSAmJiBkb2N1bWVudC5ib2R5LmNvbnRhaW5zKGVsKVxuICAgICAgRE9NLmRlYm91bmNlKGVsLCBldmVudCwgcGh4RGVib3VuY2UsIGRlZmF1bHREZWJvdW5jZSwgcGh4VGhyb3R0bGUsIGRlZmF1bHRUaHJvdHRsZSwgYXN5bmNGaWx0ZXIsICgpID0+IHtcbiAgICAgICAgY2FsbGJhY2soKVxuICAgICAgfSlcbiAgICB9KVxuICB9XG5cbiAgc2lsZW5jZUV2ZW50cyhjYWxsYmFjayl7XG4gICAgdGhpcy5zaWxlbmNlZCA9IHRydWVcbiAgICBjYWxsYmFjaygpXG4gICAgdGhpcy5zaWxlbmNlZCA9IGZhbHNlXG4gIH1cblxuICBvbihldmVudCwgY2FsbGJhY2spe1xuICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKGV2ZW50LCBlID0+IHtcbiAgICAgIGlmKCF0aGlzLnNpbGVuY2VkKXsgY2FsbGJhY2soZSkgfVxuICAgIH0pXG4gIH1cbn1cblxuY2xhc3MgVHJhbnNpdGlvblNldCB7XG4gIGNvbnN0cnVjdG9yKCl7XG4gICAgdGhpcy50cmFuc2l0aW9ucyA9IG5ldyBTZXQoKVxuICAgIHRoaXMucGVuZGluZ09wcyA9IFtdXG4gIH1cblxuICByZXNldCgpe1xuICAgIHRoaXMudHJhbnNpdGlvbnMuZm9yRWFjaCh0aW1lciA9PiB7XG4gICAgICBjbGVhclRpbWVvdXQodGltZXIpXG4gICAgICB0aGlzLnRyYW5zaXRpb25zLmRlbGV0ZSh0aW1lcilcbiAgICB9KVxuICAgIHRoaXMuZmx1c2hQZW5kaW5nT3BzKClcbiAgfVxuXG4gIGFmdGVyKGNhbGxiYWNrKXtcbiAgICBpZih0aGlzLnNpemUoKSA9PT0gMCl7XG4gICAgICBjYWxsYmFjaygpXG4gICAgfSBlbHNlIHtcbiAgICAgIHRoaXMucHVzaFBlbmRpbmdPcChjYWxsYmFjaylcbiAgICB9XG4gIH1cblxuICBhZGRUcmFuc2l0aW9uKHRpbWUsIG9uU3RhcnQsIG9uRG9uZSl7XG4gICAgb25TdGFydCgpXG4gICAgbGV0IHRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7XG4gICAgICB0aGlzLnRyYW5zaXRpb25zLmRlbGV0ZSh0aW1lcilcbiAgICAgIG9uRG9uZSgpXG4gICAgICB0aGlzLmZsdXNoUGVuZGluZ09wcygpXG4gICAgfSwgdGltZSlcbiAgICB0aGlzLnRyYW5zaXRpb25zLmFkZCh0aW1lcilcbiAgfVxuXG4gIHB1c2hQZW5kaW5nT3Aob3ApeyB0aGlzLnBlbmRpbmdPcHMucHVzaChvcCkgfVxuXG4gIHNpemUoKXsgcmV0dXJuIHRoaXMudHJhbnNpdGlvbnMuc2l6ZSB9XG5cbiAgZmx1c2hQZW5kaW5nT3BzKCl7XG4gICAgaWYodGhpcy5zaXplKCkgPiAwKXsgcmV0dXJuIH1cbiAgICBsZXQgb3AgPSB0aGlzLnBlbmRpbmdPcHMuc2hpZnQoKVxuICAgIGlmKG9wKXtcbiAgICAgIG9wKClcbiAgICAgIHRoaXMuZmx1c2hQZW5kaW5nT3BzKClcbiAgICB9XG4gIH1cbn1cbiIsICIvLyBJbmNsdWRlIHBob2VuaXhfaHRtbCB0byBoYW5kbGUgbWV0aG9kPVBVVC9ERUxFVEUgaW4gZm9ybXMgYW5kIGJ1dHRvbnMuXG5pbXBvcnQgXCJwaG9lbml4X2h0bWxcIlxuLy8gRXN0YWJsaXNoIFBob2VuaXggU29ja2V0IGFuZCBMaXZlVmlldyBjb25maWd1cmF0aW9uLlxuaW1wb3J0IHtTb2NrZXR9IGZyb20gXCJwaG9lbml4XCJcbmltcG9ydCB7TGl2ZVNvY2tldH0gZnJvbSBcInBob2VuaXhfbGl2ZV92aWV3XCJcblxubGV0IGNzcmZUb2tlbiA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoXCJtZXRhW25hbWU9J2NzcmYtdG9rZW4nXVwiKS5nZXRBdHRyaWJ1dGUoXCJjb250ZW50XCIpXG5sZXQgbGl2ZVNvY2tldCA9IG5ldyBMaXZlU29ja2V0KFwiL2xpdmVcIiwgU29ja2V0LCB7XG4gIGxvbmdQb2xsRmFsbGJhY2tNczogMjUwMCxcbiAgcGFyYW1zOiB7X2NzcmZfdG9rZW46IGNzcmZUb2tlbn1cbn0pXG5cbi8vIGNvbm5lY3QgaWYgdGhlcmUgYXJlIGFueSBMaXZlVmlld3Mgb24gdGhlIHBhZ2VcbmxpdmVTb2NrZXQuY29ubmVjdCgpXG5cbi8vIGV4cG9zZSBsaXZlU29ja2V0IG9uIHdpbmRvdyBmb3Igd2ViIGNvbnNvbGUgZGVidWcgbG9ncyBhbmQgbGF0ZW5jeSBzaW11bGF0aW9uOlxuLy8gPj4gbGl2ZVNvY2tldC5lbmFibGVEZWJ1ZygpXG4vLyA+PiBsaXZlU29ja2V0LmVuYWJsZUxhdGVuY3lTaW0oMTAwMCkgIC8vIGVuYWJsZWQgZm9yIGR1cmF0aW9uIG9mIGJyb3dzZXIgc2Vzc2lvblxuLy8gPj4gbGl2ZVNvY2tldC5kaXNhYmxlTGF0ZW5jeVNpbSgpXG53aW5kb3cubGl2ZVNvY2tldCA9IGxpdmVTb2NrZXQiXSwKICAibWFwcGluZ3MiOiAiOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBRUEsR0FBQyxXQUFXO0FBQ1YsUUFBSSxnQkFBZ0IsaUJBQWlCO0FBRXJDLGFBQVMsbUJBQW1CO0FBQzFCLFVBQUksT0FBTyxPQUFPLGdCQUFnQjtBQUFZLGVBQU8sT0FBTztBQUU1RCxlQUFTQSxhQUFZLE9BQU8sUUFBUTtBQUNsQyxpQkFBUyxVQUFVLEVBQUMsU0FBUyxPQUFPLFlBQVksT0FBTyxRQUFRLE9BQVM7QUFDeEUsWUFBSSxNQUFNLFNBQVMsWUFBWSxhQUFhO0FBQzVDLFlBQUksZ0JBQWdCLE9BQU8sT0FBTyxTQUFTLE9BQU8sWUFBWSxPQUFPLE1BQU07QUFDM0UsZUFBTztBQUFBLE1BQ1Q7QUFDQSxNQUFBQSxhQUFZLFlBQVksT0FBTyxNQUFNO0FBQ3JDLGFBQU9BO0FBQUEsSUFDVDtBQUVBLGFBQVMsaUJBQWlCLE1BQU0sT0FBTztBQUNyQyxVQUFJLFFBQVEsU0FBUyxjQUFjLE9BQU87QUFDMUMsWUFBTSxPQUFPO0FBQ2IsWUFBTSxPQUFPO0FBQ2IsWUFBTSxRQUFRO0FBQ2QsYUFBTztBQUFB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QUFLLFNBQVMsRUFBQTtBQUN0RSxvQkFBSSxTQUFTLElBQUksT0FBTyxhQUFhLGlCQUFpQixhQUFhLGlCQUFpQixhQUFhLE1BQU07QUFDckcsbUJBQUE7UUFBQSxDQUFBO01BQUEsQ0FBQTtJQUFBO0lBS04sY0FBYyxVQUFTO0FBQ3JCLFdBQUssV0FBVztBQUNoQixlQUFBO0FBQ0EsV0FBSyxXQUFXO0lBQUE7SUFHbEIsR0FBRyxPQUFPLFVBQVM7QUFDakIsYUFBTyxpQkFBaUIsT0FBTyxDQUFBLE1BQUs7QUFDbEMsWUFBRyxDQUFDLEtBQUssVUFBUztBQUFFLG1CQUFTLENBQUE7UUFBQTtNQUFBLENBQUE7SUFBQTtFQUFBO0FBS25DLE1BQUEsZ0JBQUEsTUFBb0I7SUFDbEIsY0FBYTtBQUNYLFdBQUssY0FBYyxvQkFBSSxJQUFBO0FBQ3ZCLFdBQUssYUFBYSxDQUFBO0lBQUE7SUFHcEIsUUFBTztBQUNMLFdBQUssWUFBWSxRQUFRLENBQUEsVUFBUztBQUNoQyxxQkFBYSxLQUFBO0FBQ2IsYUFBSyxZQUFZLE9BQU8sS0FBQTtNQUFBLENBQUE7QUFFMUIsV0FBSyxnQkFBQTtJQUFBO0lBR1AsTUFBTSxVQUFTO0FBQ2IsVUFBRyxLQUFLLEtBQUEsTUFBVyxHQUFFO0FBQ25CLGlCQUFBO01BQUEsT0FDSztBQUNMLGFBQUssY0FBYyxRQUFBO01BQUE7SUFBQTtJQUl2QixjQUFjLE1BQU0sU0FBUyxRQUFPO0FBQ2xDLGNBQUE7QUFDQSxVQUFJLFFBQVEsV0FBVyxNQUFNO0FBQzNCLGFBQUssWUFBWSxPQUFPLEtBQUE7QUFDeEIsZUFBQTtBQUNBLGFBQUssZ0JBQUE7TUFBQSxHQUNKLElBQUE7QUFDSCxXQUFLLFlBQVksSUFBSSxLQUFBO0lBQUE7SUFHdkIsY0FBYyxJQUFHO0FBQUUsV0FBSyxXQUFXLEtBQUssRUFBQTtJQUFBO0lBRXhDLE9BQU07QUFBRSxhQUFPLEtBQUssWUFBWTtJQUFBO0lBRWhDLGtCQUFpQjtBQUNmLFVBQUcsS0FBSyxLQUFBLElBQVMsR0FBRTtBQUFFO01BQUE7QUFDckIsVUFBSSxLQUFLLEtBQUssV0FBVyxNQUFBO0FBQ3pCLFVBQUcsSUFBRztBQUNKLFdBQUE7QUFDQSxhQUFLLGdCQUFBO01BQUE7SUFBQTtFQUFBOzs7QUN0OEJYLE1BQUksWUFBWSxTQUFTLGNBQWMseUJBQXlCLEVBQUUsYUFBYSxTQUFTO0FBQ3hGLE1BQUksYUFBYSxJQUFJLFdBQVcsU0FBUyxRQUFRO0FBQUEsSUFDL0Msb0JBQW9CO0FBQUEsSUFDcEIsUUFBUSxFQUFDLGFBQWEsVUFBUztBQUFBLEVBQ2pDLENBQUM7QUFHRCxhQUFXLFFBQVE7QUFNbkIsU0FBTyxhQUFhOyIsCiAgIm5hbWVzIjogWyJDdXN0b21FdmVudCIsICJjbG9zdXJlIiwgImxpdmVTb2NrZXQiLCAiY2xvc3VyZSJdCn0K
