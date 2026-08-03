(function () {
  "use strict";

  var CELL_RADIUS = 28;
  var BAND_HEIGHT = 25;
  var MARKER_THRESHOLDS = [ 0.75, 0.5, 0.25 ];

  // blue -> cyan -> lime -> yellow -> red
  var PALETTE = [
    { stop: 0, color: [ 33, 84, 219 ] },
    { stop: 0.25, color: [ 0, 200, 220 ] },
    { stop: 0.5, color: [ 70, 200, 60 ] },
    { stop: 0.75, color: [ 240, 210, 30 ] },
    { stop: 1, color: [ 220, 40, 40 ] }
  ];

  function clamp01(value) {
    return Math.max(0, Math.min(1, value));
  }

  function paletteColor(intensity) {
    intensity = clamp01(intensity);

    for (var i = 0; i < PALETTE.length - 1; i++) {
      var a = PALETTE[i];
      var b = PALETTE[i + 1];
      if (intensity >= a.stop && intensity <= b.stop) {
        var span = b.stop - a.stop || 1;
        var t = (intensity - a.stop) / span;
        return [
          Math.round(a.color[0] + (b.color[0] - a.color[0]) * t),
          Math.round(a.color[1] + (b.color[1] - a.color[1]) * t),
          Math.round(a.color[2] + (b.color[2] - a.color[2]) * t)
        ];
      }
    }

    return PALETTE[PALETTE.length - 1].color;
  }

  function rgbString(rgb, alpha) {
    return "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + "," + (alpha == null ? 1 : alpha) + ")";
  }

  function normalizePath(url) {
    if (!url) return "/";

    var withoutHash = String(url).split("#")[0];
    var withoutQuery = withoutHash.split("?")[0];
    var match = withoutQuery.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/]*(\/.*)?$/);
    var path = match ? match[1] : withoutQuery;

    return path || "/";
  }

  function fmtNumber(n) {
    n = n || 0;
    return typeof n.toLocaleString === "function" ? n.toLocaleString() : String(n);
  }

  function Heatmap(container, config) {
    this.container = container;
    this.config = config || {};
    this.viewportWidth = this.config.viewportWidth || 1280;
    this.viewportHeight = this.config.viewportHeight || 800;
    this.docHeight = this.viewportHeight;
    this.backdropReady = false;
    this.dataReady = false;
    this.overlayRendered = false;
    this.cellData = null;

    this.buildUi();
    this.loadBackdrop();
    this.loadData();
  }

  Heatmap.prototype.buildUi = function () {
    this.container.innerHTML = "";

    var root = document.createElement("div");
    root.className = "aa-heatmap";

    this.stageWrap = document.createElement("div");
    this.stageWrap.className = "aa-heatmap__stage-wrap";

    this.stage = document.createElement("div");
    this.stage.className = "aa-heatmap__stage";
    this.stage.style.width = this.viewportWidth + "px";
    this.stage.style.height = this.viewportHeight + "px";

    this.stageWrap.appendChild(this.stage);
    root.appendChild(this.stageWrap);

    this.legend = document.createElement("div");
    this.legend.className = "aa-heatmap__legend";
    root.appendChild(this.legend);

    this.note = document.createElement("p");
    this.note.className = "aa-heatmap__note";
    root.appendChild(this.note);

    this.container.appendChild(root);

    var self = this;
    window.addEventListener("resize", function () {
      self.updateScale();
    });
  };

  Heatmap.prototype.updateScale = function () {
    var containerWidth = this.stageWrap.clientWidth || this.viewportWidth;
    var scale = Math.min(1, containerWidth / this.viewportWidth);

    this.stage.style.transformOrigin = "top left";
    this.stage.style.transform = "scale(" + scale + ")";
    this.stageWrap.style.height = Math.round(this.docHeight * scale) + "px";
  };

  Heatmap.prototype.markBackdropReady = function () {
    this.updateScale();
    this.backdropReady = true;
    this.maybeRenderOverlay();
  };

  Heatmap.prototype.showPlaceholder = function (message) {
    var placeholder = document.createElement("div");
    placeholder.className = "aa-heatmap__placeholder";
    placeholder.textContent = message;
    placeholder.style.width = this.viewportWidth + "px";
    placeholder.style.height = this.viewportHeight + "px";
    this.stage.appendChild(placeholder);

    this.docHeight = this.viewportHeight;
    this.markBackdropReady();
  };

  Heatmap.prototype.loadBackdrop = function () {
    var self = this;

    if (!this.config.eventsUrl) {
      this.showPlaceholder("No snapshot available for this page.");
      return;
    }

    fetch(this.config.eventsUrl)
      .then(function (res) {
        return res.json();
      })
      .then(function (payload) {
        var events = payload.events || [];
        var targetPath = self.config.path;
        var snapshots = events.filter(function (evt) {
          return evt.e === "snapshot";
        });

        var match = null;
        for (var i = snapshots.length - 1; i >= 0; i--) {
          var d = snapshots[i].d || {};
          if (normalizePath(d.url) === targetPath) {
            match = snapshots[i];
            break;
          }
        }
        if (!match) match = snapshots[0];

        if (!match) {
          self.showPlaceholder("No snapshot available for this page.");
          return;
        }

        self.buildBackdrop(match);
      })
      .catch(function () {
        self.showPlaceholder("Failed to load snapshot.");
      });
  };

  Heatmap.prototype.buildBackdrop = function (snapshotEvent) {
    var d = snapshotEvent.d || {};

    var iframe = document.createElement("iframe");
    iframe.className = "aa-heatmap__iframe";
    iframe.setAttribute("sandbox", "allow-same-origin");

    var vw = d.vw || this.viewportWidth;
    var vh = d.vh || this.viewportHeight;
    this.viewportWidth = vw;

    iframe.width = vw;
    iframe.height = vh;
    iframe.style.width = vw + "px";
    iframe.style.height = vh + "px";

    this.stage.style.width = vw + "px";
    this.stage.style.height = vh + "px";
    this.stage.appendChild(iframe);

    var doc = iframe.contentDocument;
    if (doc && window.AADomBuilder && d.doc) {
      window.AADomBuilder.build(doc, d.doc);

      var docEl = doc.documentElement;
      var height = docEl ? Math.max(docEl.scrollHeight || 0, vh) : vh;
      this.docHeight = height || vh;
    } else {
      this.docHeight = vh;
    }

    this.stage.style.height = this.docHeight + "px";
    iframe.style.height = this.docHeight + "px";
    iframe.height = this.docHeight;

    this.markBackdropReady();
  };

  Heatmap.prototype.loadData = function () {
    var self = this;

    fetch(this.config.dataUrl)
      .then(function (res) {
        return res.json();
      })
      .then(function (data) {
        self.cellData = data;
        self.renderLegend(data);
        self.renderNote(data);
        self.dataReady = true;
        self.maybeRenderOverlay();
      })
      .catch(function () {
        self.note.textContent = "Failed to load heatmap data.";
      });
  };

  Heatmap.prototype.maybeRenderOverlay = function () {
    if (!this.backdropReady || !this.dataReady || this.overlayRendered) return;
    this.overlayRendered = true;

    if (this.cellData.kind === "scroll") {
      this.renderScroll(this.cellData);
    } else {
      this.renderPoints(this.cellData);
    }
  };

  Heatmap.prototype.renderLegend = function (data) {
    this.legend.innerHTML = "";

    var minLabel = document.createElement("span");
    minLabel.className = "aa-heatmap__legend-label";

    var bar = document.createElement("div");
    bar.className = "aa-heatmap__legend-bar";

    var maxLabel = document.createElement("span");
    maxLabel.className = "aa-heatmap__legend-label";

    if (data.kind === "scroll") {
      minLabel.textContent = "0%";
      maxLabel.textContent = "100%";
    } else {
      minLabel.textContent = "0";
      maxLabel.textContent = fmtNumber(data.max || 0);
    }

    this.legend.appendChild(minLabel);
    this.legend.appendChild(bar);
    this.legend.appendChild(maxLabel);
  };

  Heatmap.prototype.renderNote = function (data) {
    if (data.kind === "scroll") {
      this.note.textContent = fmtNumber(data.total || 0) + " pageviews recorded for this page and device.";
      return;
    }

    var totalPoints = (data.cells || []).reduce(function (sum, cell) {
      return sum + (cell[2] || 0);
    }, 0);

    this.note.textContent = fmtNumber(totalPoints) + " data points recorded (peak cell: " + fmtNumber(data.max || 0) + ").";
  };

  // ---- move / click rendering ----

  Heatmap.prototype.renderPoints = function (data) {
    var width = this.viewportWidth;
    var height = this.docHeight;
    var max = data.max || 0;

    var canvas = document.createElement("canvas");
    canvas.className = "aa-heatmap__overlay";
    canvas.width = width;
    canvas.height = height;
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    this.stage.appendChild(canvas);

    var ctx = canvas.getContext("2d");
    if (!ctx || max <= 0) return;

    (data.cells || []).forEach(function (cell) {
      var xBucket = cell[0];
      var yBucket = cell[1];
      var count = cell[2];

      var x = (xBucket + 0.5) / 50 * width;
      var y = yBucket * BAND_HEIGHT + BAND_HEIGHT / 2;
      var alpha = clamp01(count / max);

      var gradient = ctx.createRadialGradient(x, y, 0, x, y, CELL_RADIUS);
      gradient.addColorStop(0, "rgba(0,0,0," + alpha + ")");
      gradient.addColorStop(1, "rgba(0,0,0,0)");

      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(x, y, CELL_RADIUS, 0, Math.PI * 2);
      ctx.fill();
    });

    this.colorize(ctx, width, height);
  };

  Heatmap.prototype.colorize = function (ctx, width, height) {
    if (width <= 0 || height <= 0) return;

    var imageData;
    try {
      imageData = ctx.getImageData(0, 0, width, height);
    } catch (e) {
      return;
    }

    var pixels = imageData.data;
    for (var i = 0; i < pixels.length; i += 4) {
      var alpha = pixels[i + 3] / 255;
      if (alpha <= 0) continue;

      var rgb = paletteColor(alpha);
      pixels[i] = rgb[0];
      pixels[i + 1] = rgb[1];
      pixels[i + 2] = rgb[2];
      pixels[i + 3] = Math.round(clamp01(alpha + 0.25) * 200);
    }

    ctx.putImageData(imageData, 0, 0);
  };

  // ---- scroll rendering ----

  Heatmap.prototype.renderScroll = function (data) {
    var total = data.total || 0;
    var bands = (data.bands || []).slice().sort(function (a, b) {
      return a[0] - b[0];
    });

    var maxBucket = bands.length ? bands[bands.length - 1][0] : Math.max(0, Math.ceil(this.docHeight / BAND_HEIGHT) - 1);
    var bandCount = Math.max(maxBucket + 1, Math.ceil(this.docHeight / BAND_HEIGHT));

    var overlay = document.createElement("div");
    overlay.className = "aa-heatmap__overlay aa-heatmap__overlay--scroll";
    overlay.style.width = "100%";
    overlay.style.height = (bandCount * BAND_HEIGHT) + "px";

    var placed = {};
    var idx = 0;

    for (var i = 0; i < bandCount; i++) {
      while (idx < bands.length && bands[idx][0] < i) idx++;
      var reached = (idx < bands.length && bands[idx][0] >= i) ? bands[idx][1] : 0;
      var pct = total > 0 ? reached / total : 0;

      var band = document.createElement("div");
      band.className = "aa-heatmap__band";
      band.style.top = (i * BAND_HEIGHT) + "px";
      band.style.height = BAND_HEIGHT + "px";
      band.style.background = rgbString(paletteColor(pct), 0.45);
      overlay.appendChild(band);

      MARKER_THRESHOLDS.forEach(function (threshold) {
        if (!placed[threshold] && pct <= threshold) {
          placed[threshold] = true;

          var line = document.createElement("div");
          line.className = "aa-heatmap__marker-line";
          line.style.top = (i * BAND_HEIGHT) + "px";

          var label = document.createElement("span");
          label.className = "aa-heatmap__marker-label";
          label.textContent = Math.round(threshold * 100) + "% of users reach this point";
          line.appendChild(label);

          overlay.appendChild(line);
        }
      });
    }

    this.stage.appendChild(overlay);
  };

  function boot() {
    var config = window.ActiveAnalyticsHeatmap;
    if (!config) return;

    var container = document.getElementById("aa-heatmap");
    if (!container) return;

    new Heatmap(container, config);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
