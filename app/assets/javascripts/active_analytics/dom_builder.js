(function () {
  "use strict";

  // Pure snapshot -> DOM builder shared by the player and the heatmap backdrop.
  // No player state is read or written here; callers own idMap bookkeeping.

  var SKIPPED_TAGS = { script: true, noscript: true, template: true };

  function buildNode(node, doc, idMap) {
    if (!node) return null;

    if (Object.prototype.hasOwnProperty.call(node, "text")) {
      var textNode = doc.createTextNode(node.text == null ? "" : node.text);
      if (node.id != null && idMap) idMap[node.id] = textNode;
      return textNode;
    }

    if (!node.tag) return null;
    var tag = String(node.tag).toLowerCase();
    if (SKIPPED_TAGS[tag]) return null;

    var el;
    try {
      el = doc.createElement(tag);
    } catch (e) {
      return null;
    }

    if (node.id != null && idMap) idMap[node.id] = el;

    var attrs = node.attrs || {};
    Object.keys(attrs).forEach(function (name) {
      try {
        el.setAttribute(name, attrs[name]);
      } catch (e) {
        // ignore invalid attribute
      }
    });

    buildChildren(node.children, el, doc, idMap);

    return el;
  }

  function buildChildren(children, parentEl, doc, idMap) {
    if (!children || !parentEl) return;
    children.forEach(function (node) {
      var el = buildNode(node, doc, idMap);
      if (el) parentEl.appendChild(el);
    });
  }

  // Rebuilds an iframe document from a serialized snapshot root node (the
  // `d.doc` payload of a `snapshot` event) and returns the id -> element map.
  function build(iframeDoc, snapshotNode) {
    var idMap = {};
    if (!iframeDoc) return idMap;

    iframeDoc.open();
    iframeDoc.write("<!DOCTYPE html><html><head></head><body></body></html>");
    iframeDoc.close();

    if (!snapshotNode) return idMap;

    if (snapshotNode.id != null) idMap[snapshotNode.id] = iframeDoc.documentElement;

    var children = snapshotNode.children || [];
    children.forEach(function (child) {
      if (!child || !child.tag) return;
      var tag = String(child.tag).toLowerCase();
      if (tag === "head") {
        if (child.id != null) idMap[child.id] = iframeDoc.head;
        buildChildren(child.children, iframeDoc.head, iframeDoc, idMap);
      } else if (tag === "body") {
        if (child.id != null) idMap[child.id] = iframeDoc.body;
        buildChildren(child.children, iframeDoc.body, iframeDoc, idMap);
      }
    });

    return idMap;
  }

  window.AADomBuilder = {
    build: build,
    buildNode: buildNode
  };
})();
