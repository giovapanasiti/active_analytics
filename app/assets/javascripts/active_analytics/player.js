(function () {
  "use strict";

  var SKIP_GAP_MS = 4000;
  var SKIP_JUMP_MS = 500;
  var TICK_MS = 33;

  function fmtTime(ms) {
    var total = Math.max(0, Math.floor((ms || 0) / 1000));
    var minutes = Math.floor(total / 60);
    var seconds = total % 60;
    return minutes + ":" + (seconds < 10 ? "0" + seconds : seconds);
  }

  function Player(container, data, markers) {
    this.container = container;
    this.recording = data.recording || {};
    this.events = (data.events || []).slice().sort(function (a, b) {
      return (a.t || 0) - (b.t || 0);
    });
    this.markers = markers || [];
    this.duration = this.recording.duration_ms || (this.events.length ? this.events[this.events.length - 1].t : 0) || 0;

    this.speed = 1;
    this.playing = false;
    this.virtualTime = 0;
    this.cursorIndex = 0;
    this.skipPauses = false;
    this.idMap = {};
    this.doc = null;
    this.win = null;
    this.scale = 1;
    this.dragging = false;

    this.hasSnapshot = this.events.some(function (evt) {
      return evt.e === "snapshot";
    });

    this.buildUi();
    this.renderMarkers();
    this.updateStageSize();
    if (!this.hasSnapshot) this.showNoSnapshotNotice();
    this.seek(0);

    var self = this;
    this.timer = setInterval(function () {
      self.tick();
    }, TICK_MS);
  }

  Player.prototype.buildUi = function () {
    var container = this.container;
    container.innerHTML = "";

    var root = document.createElement("div");
    root.className = "aa-player";

    this.addressbar = document.createElement("div");
    this.addressbar.className = "aa-player__addressbar";
    this.addressbar.textContent = this.recording.first_url || "";
    root.appendChild(this.addressbar);

    this.stageWrap = document.createElement("div");
    this.stageWrap.className = "aa-player__stage-wrap";

    this.stage = document.createElement("div");
    this.stage.className = "aa-player__stage";

    this.iframe = document.createElement("iframe");
    this.iframe.className = "aa-player__iframe";
    this.iframe.setAttribute("sandbox", "allow-same-origin");
    this.stage.appendChild(this.iframe);

    this.cursor = document.createElement("div");
    this.cursor.className = "aa-player__cursor";
    this.stage.appendChild(this.cursor);

    this.stageWrap.appendChild(this.stage);
    root.appendChild(this.stageWrap);

    var controls = document.createElement("div");
    controls.className = "aa-player__controls";

    this.playButton = document.createElement("button");
    this.playButton.type = "button";
    this.playButton.textContent = "Play";
    var self1 = this;
    this.playButton.addEventListener("click", function () {
      if (self1.playing) {
        self1.pause();
      } else {
        self1.play();
      }
    });
    controls.appendChild(this.playButton);

    this.timeline = document.createElement("div");
    this.timeline.className = "aa-player__timeline";

    this.range = document.createElement("input");
    this.range.type = "range";
    this.range.min = "0";
    this.range.max = String(this.duration || 0);
    this.range.value = "0";
    var self2 = this;
    this.range.addEventListener("input", function () {
      self2.dragging = true;
      self2.pause();
      self2.seek(parseInt(self2.range.value, 10) || 0);
      self2.dragging = false;
    });
    this.timeline.appendChild(this.range);
    controls.appendChild(this.timeline);

    this.timeLabel = document.createElement("span");
    this.timeLabel.className = "aa-player__time";
    this.timeLabel.textContent = "0:00 / " + fmtTime(this.duration);
    controls.appendChild(this.timeLabel);

    this.speedButton = document.createElement("button");
    this.speedButton.type = "button";
    this.speedButton.className = "aa-player__speed";
    this.speedButton.textContent = "1x";
    var self3 = this;
    this.speedButton.addEventListener("click", function () {
      var speeds = [ 1, 2, 4 ];
      var idx = speeds.indexOf(self3.speed);
      self3.speed = speeds[(idx + 1) % speeds.length];
      self3.speedButton.textContent = self3.speed + "x";
    });
    controls.appendChild(this.speedButton);

    var skipLabel = document.createElement("label");
    this.skipCheckbox = document.createElement("input");
    this.skipCheckbox.type = "checkbox";
    var self4 = this;
    this.skipCheckbox.addEventListener("change", function () {
      self4.skipPauses = self4.skipCheckbox.checked;
    });
    skipLabel.appendChild(this.skipCheckbox);
    skipLabel.appendChild(document.createTextNode(" Skip pauses"));
    controls.appendChild(skipLabel);

    root.appendChild(controls);
    container.appendChild(root);

    var self5 = this;
    window.addEventListener("resize", function () {
      self5.updateStageSize();
    });
  };

  // No `snapshot` event was captured for this recording (e.g. an old
  // recording lost to the pre-fix 64KB keepalive cap). Render an explicit
  // notice on the blank stage; cursor/scroll events still play over it.
  Player.prototype.showNoSnapshotNotice = function () {
    var notice = document.createElement("div");
    notice.className = "aa-player__no-snapshot";
    notice.textContent = "No DOM snapshot was captured for this recording. " +
      "Movements are shown on a blank background.";
    this.stage.appendChild(notice);
  };

  Player.prototype.renderMarkers = function () {
    var duration = this.duration || 1;
    var self = this;
    this.markers.forEach(function (marker) {
      if (marker.ts_ms == null) return;
      var dot = document.createElement("div");
      dot.className = "aa-player__marker aa-player__marker--" + (marker.severity || "info");
      var pct = Math.max(0, Math.min(1, marker.ts_ms / duration)) * 100;
      dot.style.left = pct + "%";
      dot.title = marker.kind || "";
      dot.addEventListener("click", function () {
        self.pause();
        self.seek(marker.ts_ms);
      });
      self.timeline.appendChild(dot);
    });
  };

  Player.prototype.updateStageSize = function () {
    var vw = this.recording.viewport_width || 1280;
    var vh = this.recording.viewport_height || 800;
    var containerWidth = this.stageWrap.clientWidth || vw;

    this.scale = Math.min(1, containerWidth / vw);

    this.iframe.width = vw;
    this.iframe.height = vh;
    this.iframe.style.width = vw + "px";
    this.iframe.style.height = vh + "px";

    this.stage.style.width = vw + "px";
    this.stage.style.height = vh + "px";
    this.stage.style.transform = "scale(" + this.scale + ")";

    this.stageWrap.style.height = Math.round(vh * this.scale) + "px";
  };

  // ---- DOM rebuild ----

  Player.prototype.rebuildFromSnapshot = function (evt) {
    var d = evt.d || {};

    var doc = this.iframe.contentDocument;
    if (!doc) return;

    this.idMap = window.AADomBuilder.build(doc, d.doc);
    this.doc = doc;
    this.win = this.iframe.contentWindow;

    if (d.doc && d.vw && d.vh) {
      this.recording.viewport_width = d.vw;
      this.recording.viewport_height = d.vh;
      this.updateStageSize();
    }
  };

  // ---- event application ----

  Player.prototype.applyEvent = function (evt, fastForward) {
    try {
      var d = evt.d || {};
      switch (evt.e) {
        case "snapshot":
          this.rebuildFromSnapshot(evt);
          if (d.url) this.addressbar.textContent = d.url;
          break;
        case "mutation":
          this.applyMutation(d);
          break;
        case "input":
          this.applyInput(d);
          break;
        case "scroll":
          this.applyScroll(d);
          break;
        case "move":
          if (!fastForward) this.applyMove(d);
          break;
        case "click":
          if (!fastForward) this.applyClick(d);
          break;
        case "resize":
          this.applyResize(d);
          break;
        case "nav":
          this.applyNav(d);
          break;
        case "visibility":
          this.applyVisibility(d);
          break;
        default:
          break;
      }
    } catch (e) {
      // defensive: one bad event should never break playback
    }
  };

  Player.prototype.applyMutation = function (d) {
    var self = this;
    var doc = this.doc;
    if (!doc) return;

    (d.adds || []).forEach(function (add) {
      try {
        var parent = self.idMap[add.p];
        if (!parent) return;
        var el = window.AADomBuilder.buildNode(add.n, doc, self.idMap);
        if (!el) return;
        var ref = parent.childNodes[add.i] || null;
        parent.insertBefore(el, ref);
      } catch (e) {
        // ignore
      }
    });

    (d.removes || []).forEach(function (id) {
      try {
        var el = self.idMap[id];
        if (el && el.parentNode) el.parentNode.removeChild(el);
        delete self.idMap[id];
      } catch (e) {
        // ignore
      }
    });

    (d.attrs || []).forEach(function (attr) {
      try {
        var el = self.idMap[attr.id];
        if (!el || !el.setAttribute) return;
        if (attr.value === null || attr.value === undefined) {
          el.removeAttribute(attr.name);
        } else {
          el.setAttribute(attr.name, attr.value);
        }
      } catch (e) {
        // ignore
      }
    });

    (d.texts || []).forEach(function (t) {
      try {
        var node = self.idMap[t.id];
        if (node) node.textContent = t.text;
      } catch (e) {
        // ignore
      }
    });
  };

  Player.prototype.applyInput = function (d) {
    var el = this.idMap[d.id];
    if (!el) return;
    if (typeof d.value === "string") el.value = d.value;
    if (typeof d.checked === "boolean") el.checked = d.checked;
  };

  Player.prototype.applyScroll = function (d) {
    if (this.win && this.win.scrollTo) this.win.scrollTo(d.x || 0, d.y || 0);
  };

  Player.prototype.applyMove = function (d) {
    this.cursor.style.left = (d.x || 0) + "px";
    this.cursor.style.top = (d.y || 0) + "px";
  };

  Player.prototype.applyClick = function (d) {
    this.applyMove(d);
    this.spawnRipple(d.x || 0, d.y || 0);
  };

  Player.prototype.spawnRipple = function (x, y) {
    var ripple = document.createElement("div");
    ripple.className = "aa-player__ripple";
    ripple.style.left = x + "px";
    ripple.style.top = y + "px";
    this.stage.appendChild(ripple);
    setTimeout(function () {
      if (ripple.parentNode) ripple.parentNode.removeChild(ripple);
    }, 550);
  };

  Player.prototype.applyResize = function (d) {
    if (d.w) this.recording.viewport_width = d.w;
    if (d.h) this.recording.viewport_height = d.h;
    this.updateStageSize();
  };

  Player.prototype.applyNav = function (d) {
    if (d.url) this.addressbar.textContent = d.url;
  };

  Player.prototype.applyVisibility = function (d) {
    if (d.state === "hidden") {
      this.stage.classList.add("is-hidden");
    } else {
      this.stage.classList.remove("is-hidden");
    }
  };

  // ---- transport ----

  Player.prototype.play = function () {
    if (this.virtualTime >= this.duration) {
      this.seek(0);
    }
    this.playing = true;
    this.lastTick = Date.now();
    this.playButton.textContent = "Pause";
  };

  Player.prototype.pause = function () {
    this.playing = false;
    this.playButton.textContent = "Play";
  };

  Player.prototype.tick = function () {
    if (!this.playing) return;

    var now = Date.now();
    var elapsed = now - (this.lastTick || now);
    this.lastTick = now;

    var newTime = this.virtualTime + elapsed * this.speed;

    if (this.skipPauses && this.cursorIndex < this.events.length) {
      var nextT = this.events[this.cursorIndex].t || 0;
      if (nextT - this.virtualTime > SKIP_GAP_MS) {
        newTime = Math.max(newTime, nextT - SKIP_JUMP_MS);
      }
    }

    while (this.cursorIndex < this.events.length && (this.events[this.cursorIndex].t || 0) <= newTime) {
      this.applyEvent(this.events[this.cursorIndex], false);
      this.cursorIndex++;
    }

    this.virtualTime = Math.min(newTime, this.duration);
    this.updateTimeUi();

    if (this.virtualTime >= this.duration || this.cursorIndex >= this.events.length) {
      this.virtualTime = this.duration;
      this.updateTimeUi();
      this.pause();
    }
  };

  Player.prototype.seek = function (ms) {
    ms = Math.max(0, Math.min(ms, this.duration || 0));

    var snapIndex = -1;
    for (var i = 0; i < this.events.length; i++) {
      var t = this.events[i].t || 0;
      if (t > ms) break;
      if (this.events[i].e === "snapshot") snapIndex = i;
    }

    if (snapIndex === -1) {
      for (var j = 0; j < this.events.length; j++) {
        if (this.events[j].e === "snapshot") {
          snapIndex = j;
          break;
        }
      }
    }

    if (snapIndex === -1) {
      this.virtualTime = ms;
      this.updateTimeUi();
      return;
    }

    this.applyEvent(this.events[snapIndex], false);

    var idx = snapIndex + 1;
    while (idx < this.events.length && (this.events[idx].t || 0) <= ms) {
      this.applyEvent(this.events[idx], true);
      idx++;
    }

    this.cursorIndex = idx;
    this.virtualTime = ms;
    this.lastTick = Date.now();
    this.updateTimeUi();
  };

  Player.prototype.updateTimeUi = function () {
    this.timeLabel.textContent = fmtTime(this.virtualTime) + " / " + fmtTime(this.duration);
    if (!this.dragging) {
      this.range.value = String(Math.round(this.virtualTime));
    }
  };

  function boot() {
    var config = window.ActiveAnalyticsReplay;
    if (!config || !config.eventsUrl) return;

    var container = document.getElementById("aa-player");
    if (!container) return;

    fetch(config.eventsUrl)
      .then(function (res) {
        return res.json();
      })
      .then(function (data) {
        var player = new Player(container, data, config.markers || []);
        window.AAPlayer = {
          seek: function (ms) {
            player.seek(ms);
          }
        };
      })
      .catch(function () {
        container.textContent = "Failed to load replay data.";
      });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
