/* ActiveAnalytics session recorder.
 *
 * Plain ES2019 IIFE, zero dependencies, no build step. Serves as a lightweight
 * session-recording script: buffers DOM/interaction events client-side and
 * flushes them to the configured ingestion endpoint. See
 * tasks/hotjar-alternative-spec.md for the frozen event contract this file
 * must emit exactly.
 */
(function () {
  "use strict";

  var rawConfig = window.ActiveAnalyticsConfig || {};
  var ENDPOINT = rawConfig.endpoint;
  var SAMPLE_RATE = typeof rawConfig.sampleRate === "number" ? rawConfig.sampleRate : 1;
  var MASK_ALL_TEXT = !!rawConfig.maskAllText;
  var MASK_FIXED = "••••••••"; // 8 dots, fixed length

  // Bail silently: no endpoint configured, no MutationObserver support, or DNT.
  if (!ENDPOINT) return;
  if (!window.MutationObserver) return;
  if (navigator.doNotTrack === "1") return;

  // ------------------------------ Pageview beacon -----------------------------
  // Base analytics (page views, referrers, browsers, unique visitors) count
  // EVERY visitor, not only the ones sampled for full session recording. This
  // must fire before the sampling bail below, but after the DNT/observer/
  // endpoint bails above (DNT users are never counted at all).

  var PAGEVIEWS_ENDPOINT = ENDPOINT.replace(/\/events$/, "/pageviews");

  function sendPageviewBeacon() {
    try {
      var body = JSON.stringify({ url: location.href, referrer: document.referrer });

      if (navigator.sendBeacon) {
        var blob = new Blob([ body ], { type: "application/json" });
        if (navigator.sendBeacon(PAGEVIEWS_ENDPOINT, blob)) return;
      }

      fetch(PAGEVIEWS_ENDPOINT, {
        method: "POST",
        keepalive: true,
        headers: { "Content-Type": "application/json" },
        body: body
      });
    } catch (e) {
      // fire-and-forget: pageview tracking must never affect the host page
    }
  }

  // Patches history.pushState/replaceState + popstate to invoke `onNav` on
  // every SPA navigation. Shared by the unsampled (beacon-only) path below and
  // the full recorder's own navigation handling, so both stay in sync without
  // duplicating the patch.
  function patchHistoryWith(onNav) {
    var originalPushState = history.pushState;
    var originalReplaceState = history.replaceState;

    history.pushState = function () {
      var result = originalPushState.apply(history, arguments);
      onNav();
      return result;
    };

    history.replaceState = function () {
      var result = originalReplaceState.apply(history, arguments);
      onNav();
      return result;
    };

    window.addEventListener("popstate", onNav);
  }

  sendPageviewBeacon();

  var SESSION_KEY = "aa_session";

  function generateUuid() {
    if (window.crypto && typeof window.crypto.randomUUID === "function") {
      return window.crypto.randomUUID();
    }

    // Fallback RFC4122-ish v4 uuid for browsers without crypto.randomUUID.
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
      var r = (Math.random() * 16) | 0;
      var v = c === "x" ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  function loadSession() {
    var existing = null;

    try {
      var raw = sessionStorage.getItem(SESSION_KEY);
      if (raw) existing = JSON.parse(raw);
    } catch (e) {
      existing = null;
    }

    if (existing && typeof existing === "object" && existing.uuid) {
      return existing;
    }

    var created = {
      uuid: generateUuid(),
      startedAt: Date.now(),
      sampled: Math.random() < SAMPLE_RATE,
      seq: 0
    };

    try {
      sessionStorage.setItem(SESSION_KEY, JSON.stringify(created));
    } catch (e) {
      // ignore storage failures (private mode, quota, etc.)
    }

    return created;
  }

  var session = loadSession();

  // When this session was not selected for full session-recording sampling,
  // still track SPA navigations for base pageview analytics (the initial
  // beacon above already covered the first pageview), then bail out.
  if (!session.sampled) {
    patchHistoryWith(sendPageviewBeacon);
    return;
  }

  function persistSession() {
    try {
      sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
    } catch (e) {
      // ignore storage failures
    }
  }

  // ---- Hardening: guard every callback, disable after repeated failures ----

  var internalErrorCount = 0;
  var stopped = false;
  var observer = null;
  var flushTimer = null;

  function stopRecorder() {
    stopped = true;

    try {
      if (observer) observer.disconnect();
    } catch (e) {
      // ignore
    }

    try {
      if (flushTimer) clearInterval(flushTimer);
    } catch (e) {
      // ignore
    }
  }

  function guard(fn) {
    return function () {
      if (stopped) return undefined;

      try {
        return fn.apply(this, arguments);
      } catch (err) {
        internalErrorCount += 1;
        if (internalErrorCount >= 3) stopRecorder();
        return undefined;
      }
    };
  }

  // ---------------------------- Node id tracking ----------------------------

  var nodeIds = new WeakMap();
  var nextNodeId = 1;

  function idFor(node) {
    if (nodeIds.has(node)) return nodeIds.get(node);
    var id = nextNodeId++;
    nodeIds.set(node, id);
    return id;
  }

  // -------------------------------- Masking ---------------------------------

  function isFormTag(tagName) {
    return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT";
  }

  function isSensitiveInput(el) {
    if (el.tagName !== "INPUT") return false;

    var type = (el.getAttribute("type") || "text").toLowerCase();
    if (type === "password" || type === "email" || type === "tel") return true;

    var autocomplete = (el.getAttribute("autocomplete") || "").toLowerCase();
    return autocomplete.indexOf("cc-") !== -1;
  }

  // Whether this form control's value must be masked (fixed-length dots).
  function shouldMaskValue(el) {
    if (!isFormTag(el.tagName)) return false;
    if (isSensitiveInput(el)) return true;
    if (el.hasAttribute("data-aa-unmask")) return false;
    return true;
  }

  // Length-preserving text mask: every non-whitespace char becomes "*".
  function maskText(text) {
    return String(text).replace(/\S/g, "*");
  }

  // Walks up the DOM from `node` to determine whether text content should be
  // masked at this point, honoring the nearest data-aa-mask/data-aa-unmask
  // ancestor, defaulting to the global maskAllText config.
  function computeMaskedContext(node) {
    var el = node.nodeType === 1 ? node : node.parentElement;

    while (el) {
      if (el.hasAttribute && el.hasAttribute("data-aa-unmask")) return false;
      if (el.hasAttribute && el.hasAttribute("data-aa-mask")) return true;
      el = el.parentElement;
    }

    return MASK_ALL_TEXT;
  }

  // ------------------------------ Serialization ------------------------------

  function absoluteUrl(value) {
    try {
      return new URL(value, document.baseURI).href;
    } catch (e) {
      return value;
    }
  }

  function getLiveValue(el) {
    try {
      return el.value == null ? "" : String(el.value);
    } catch (e) {
      return "";
    }
  }

  function buildAttrs(node, formMasked, textMasked) {
    var attrs = {};
    var list = node.attributes;

    for (var i = 0; i < list.length; i++) {
      var attr = list[i];
      var name = attr.name;
      var value = attr.value;

      if (name === "href" || name === "src") {
        value = absoluteUrl(value);
      }

      attrs[name] = value;
    }

    if (isFormTag(node.tagName)) {
      attrs.value = formMasked ? MASK_FIXED : getLiveValue(node);

      if (node.tagName === "INPUT" && (node.type === "checkbox" || node.type === "radio")) {
        if (node.checked) {
          attrs.checked = "checked";
        } else {
          delete attrs.checked;
        }
      }
    }

    if ("placeholder" in attrs) {
      if (formMasked) {
        attrs.placeholder = MASK_FIXED;
      } else if (textMasked) {
        attrs.placeholder = maskText(attrs.placeholder);
      }
    }

    return attrs;
  }

  // Serializes a DOM node into the frozen { id, tag, attrs, children } /
  // { id, text } shape. `masked` is the inherited text-masking context from
  // the parent (before considering this node's own data-aa-mask/unmask).
  function serializeNode(node, masked) {
    var type = node.nodeType;

    if (type === 8) return null; // comment

    if (type === 3) {
      var text = node.nodeValue || "";
      return { id: idFor(node), text: masked ? maskText(text) : text };
    }

    if (type !== 1) return null; // only elements and text nodes are serialized

    var tagUpper = node.tagName;
    if (tagUpper === "SCRIPT" || tagUpper === "NOSCRIPT" || tagUpper === "TEMPLATE") return null;

    if (node.hasAttribute && node.hasAttribute("data-aa-block")) {
      var width = 0;
      var height = 0;

      try {
        var rect = node.getBoundingClientRect();
        width = Math.round(rect.width);
        height = Math.round(rect.height);
      } catch (e) {
        // ignore
      }

      return {
        id: idFor(node),
        tag: "div",
        attrs: { "data-aa-blocked": "", style: "width:" + width + "px;height:" + height + "px;" },
        children: []
      };
    }

    var childMasked = masked;
    if (node.hasAttribute("data-aa-unmask")) childMasked = false;
    else if (node.hasAttribute("data-aa-mask")) childMasked = true;

    var formMasked = isFormTag(tagUpper) && shouldMaskValue(node);
    var attrs = buildAttrs(node, formMasked, childMasked);
    var tag = tagUpper.toLowerCase();

    if (tagUpper === "IFRAME" || tagUpper === "CANVAS" || tagUpper === "VIDEO") {
      return { id: idFor(node), tag: tag, attrs: attrs, children: [] };
    }

    var children = [];
    var childNodes = node.childNodes;

    for (var i = 0; i < childNodes.length; i++) {
      var serialized = serializeNode(childNodes[i], childMasked);
      if (serialized) children.push(serialized);
    }

    return { id: idFor(node), tag: tag, attrs: attrs, children: children };
  }

  function takeSnapshot() {
    pushEvent("snapshot", {
      url: location.href,
      title: document.title,
      vw: window.innerWidth,
      vh: window.innerHeight,
      doc: serializeNode(document.documentElement, MASK_ALL_TEXT)
    });
  }

  // ------------------------------ Event buffer -------------------------------

  var buffer = [];

  function pushEvent(type, d) {
    if (stopped) return;

    buffer.push({ t: Date.now() - session.startedAt, e: type, d: d });

    if (buffer.length >= 100) flush(false);
  }

  function sendPayload(body, useBeacon) {
    try {
      if (useBeacon && navigator.sendBeacon) {
        var blob = new Blob([ body ], { type: "application/json" });
        if (navigator.sendBeacon(ENDPOINT, blob)) return;
      }
    } catch (e) {
      // fall through to fetch
    }

    try {
      fetch(ENDPOINT, {
        method: "POST",
        keepalive: true,
        headers: { "Content-Type": "application/json" },
        body: body
      });
    } catch (e) {
      // best effort; drop on failure
    }
  }

  function flush(useBeacon) {
    if (!buffer.length) return; // never send empty event arrays

    var events = buffer;
    buffer = [];

    var payload = { uuid: session.uuid, seq: session.seq };

    if (session.seq === 0) {
      payload.meta = {
        url: location.href,
        referrer: document.referrer,
        vw: window.innerWidth,
        vh: window.innerHeight
      };
    }

    payload.events = events;

    session.seq += 1;
    persistSession();

    sendPayload(JSON.stringify(payload), useBeacon);
  }

  // -------------------------------- Mutations --------------------------------

  function maskAttrValue(el, name, value) {
    if (value === null) return value;

    if (name === "href" || name === "src") return absoluteUrl(value);

    if (isFormTag(el.tagName) && shouldMaskValue(el) && (name === "value" || name === "placeholder")) {
      return MASK_FIXED;
    }

    if (name === "placeholder" && computeMaskedContext(el)) {
      return maskText(value);
    }

    return value;
  }

  function handleMutations(records) {
    var adds = [];
    var removes = [];
    var attrsOut = [];
    var texts = [];

    for (var r = 0; r < records.length; r++) {
      var rec = records[r];

      if (rec.type === "childList") {
        var parent = rec.target;

        // Unknown parents (never serialized) are skipped rather than
        // triggering a full re-snapshot, per the simplified spec allowance.
        if (!nodeIds.has(parent)) continue;

        var pid = idFor(parent);

        for (var i = 0; i < rec.removedNodes.length; i++) {
          var removedNode = rec.removedNodes[i];
          if (nodeIds.has(removedNode)) removes.push(idFor(removedNode));
        }

        for (var j = 0; j < rec.addedNodes.length; j++) {
          var addedNode = rec.addedNodes[j];
          var index = Array.prototype.indexOf.call(parent.childNodes, addedNode);
          var serialized = serializeNode(addedNode, computeMaskedContext(parent));
          if (serialized) adds.push({ p: pid, i: index, n: serialized });
        }
      } else if (rec.type === "attributes") {
        var target = rec.target;
        if (!nodeIds.has(target)) continue;

        var name = rec.attributeName;
        var value = target.getAttribute(name);
        if (value === null) continue; // attribute removal: skip (simplified handling)

        attrsOut.push({ id: idFor(target), name: name, value: maskAttrValue(target, name, value) });
      } else if (rec.type === "characterData") {
        var textNode = rec.target;
        if (!nodeIds.has(textNode)) continue;

        var masked = computeMaskedContext(textNode);
        var textValue = textNode.nodeValue || "";
        texts.push({ id: idFor(textNode), text: masked ? maskText(textValue) : textValue });
      }
    }

    if (!adds.length && !removes.length && !attrsOut.length && !texts.length) return;

    var d = {};
    if (adds.length) d.adds = adds;
    if (removes.length) d.removes = removes;
    if (attrsOut.length) d.attrs = attrsOut;
    if (texts.length) d.texts = texts;

    pushEvent("mutation", d);
  }

  function setupObserver() {
    observer = new MutationObserver(guard(handleMutations));
    observer.observe(document.documentElement, {
      childList: true,
      attributes: true,
      characterData: true,
      subtree: true
    });
  }

  // -------------------------------- Listeners --------------------------------

  function throttle(fn, wait) {
    var last = 0;
    var timer = null;

    return function () {
      var context = this;
      var args = arguments;
      var now = Date.now();
      var remaining = wait - (now - last);

      if (remaining <= 0) {
        last = now;
        fn.apply(context, args);
      } else if (!timer) {
        timer = setTimeout(function () {
          last = Date.now();
          timer = null;
          fn.apply(context, args);
        }, remaining);
      }
    };
  }

  function extractLabel(el) {
    if (!el || el.nodeType !== 1) return "";

    var raw = "";
    var innerText = (el.innerText != null ? el.innerText : el.textContent) || "";

    if (innerText.trim()) {
      raw = innerText.trim();
    } else if (isFormTag(el.tagName) && getLiveValue(el)) {
      raw = getLiveValue(el);
    } else {
      raw = el.getAttribute("aria-label") || "";
    }

    if (isFormTag(el.tagName) && shouldMaskValue(el)) {
      raw = MASK_FIXED;
    } else if (computeMaskedContext(el)) {
      raw = maskText(raw);
    }

    return raw.slice(0, 40);
  }

  function onClick(e) {
    var target = e.target;
    var id = target && target.nodeType === 1 ? idFor(target) : null;
    pushEvent("click", { x: e.clientX, y: e.clientY, id: id, label: extractLabel(target) });
  }

  // Mouse and touch movement share a single throttled emitter so they share
  // one 50ms rate limit rather than each getting their own budget.
  var emitMove = throttle(guard(function (x, y) {
    pushEvent("move", { x: x, y: y });
  }), 50);

  function onMouseMove(e) {
    emitMove(e.clientX, e.clientY);
  }

  function onTouchMove(e) {
    var touch = e.touches && e.touches[0];
    if (!touch) return;
    emitMove(touch.clientX, touch.clientY);
  }

  var onScroll = throttle(guard(function () {
    pushEvent("scroll", { x: window.scrollX, y: window.scrollY });
  }), 100);

  function onResize() {
    pushEvent("resize", { w: window.innerWidth, h: window.innerHeight });
  }

  function onInputOrChange(e) {
    var el = e.target;
    if (!el || !isFormTag(el.tagName)) return;

    var masked = shouldMaskValue(el);
    var d = { id: idFor(el), value: masked ? MASK_FIXED : getLiveValue(el) };

    if (el.tagName === "INPUT" && (el.type === "checkbox" || el.type === "radio")) {
      d.checked = !!el.checked;
    }

    pushEvent("input", d);
  }

  function onVisibilityChange() {
    var state = document.hidden ? "hidden" : "visible";
    pushEvent("visibility", { state: state });
    if (document.hidden) flush(true);
  }

  function onWindowError(e) {
    pushEvent("error", {
      message: String((e && e.message) || "").slice(0, 200),
      source: (e && e.filename) || "",
      line: (e && e.lineno) || 0
    });
  }

  function attachListeners() {
    window.addEventListener("mousemove", guard(onMouseMove));
    window.addEventListener("touchstart", guard(onTouchMove), { capture: true, passive: true });
    window.addEventListener("touchmove", guard(onTouchMove), { capture: true, passive: true });
    window.addEventListener("click", guard(onClick), true);
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", guard(onResize));
    window.addEventListener("input", guard(onInputOrChange), true);
    window.addEventListener("change", guard(onInputOrChange), true);
    document.addEventListener("visibilitychange", guard(onVisibilityChange));
    window.addEventListener("error", guard(onWindowError));
    window.addEventListener("pagehide", guard(function () {
      flush(true);
    }));
  }

  // ------------------------------ Navigation (SPA) ----------------------------

  var onNavigate = guard(function () {
    sendPageviewBeacon();
    pushEvent("nav", { url: location.href, title: document.title });
    takeSnapshot();
  });

  // ----------------------------------- Start -----------------------------------

  function start() {
    takeSnapshot();
    setupObserver();
    attachListeners();
    patchHistoryWith(onNavigate);
    flushTimer = setInterval(function () {
      flush(false);
    }, 5000);
  }

  try {
    start();
  } catch (e) {
    stopRecorder();
  }
})();
