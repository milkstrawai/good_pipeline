/* GoodPipeline dashboard — dependency-free browser behavior, no build step. */
(function () {
  "use strict";

  var SWAP_REGIONS = ["gp-kpi", "gp-filters", "gp-table"];
  var MIN_SCALE = 0.5;
  var MAX_SCALE = 4;
  var ZOOM_STEP = 0.25;
  var searchTimer = null;
  var navSequence = 0;
  var navController = null;
  var latestRequestedUrl = window.location.href;
  var viewportStates = new WeakMap();
  var renderTokens = new WeakMap();
  var renderSequence = 0;
  var mermaidId = 0;
  var mermaidBusy = false;
  var queuedRender = null;

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.content : "";
  }

  function replaceContents(target, source) {
    while (target.firstChild) target.removeChild(target.firstChild);
    Array.from(source.childNodes).forEach(function (child) {
      target.appendChild(child.cloneNode(true));
    });
  }

  function syncSearchFromUrl() {
    var input = document.querySelector("form[data-gp-search-form] input[name=q]");
    if (!input || document.activeElement === input) return;
    var value = new URL(window.location.href).searchParams.get("q") || "";
    if (input.value !== value) input.value = value;
  }

  function setLoading(loading) {
    SWAP_REGIONS.forEach(function (id) {
      var region = document.getElementById(id);
      if (region) region.classList.toggle("is-loading", loading);
    });
  }

  async function partialNav(url, options) {
    options = options || {};
    url = new URL(url, window.location.origin).toString();
    latestRequestedUrl = url;
    var targets = SWAP_REGIONS.map(function (id) { return document.getElementById(id); });
    if (targets.some(function (node) { return !node; })) {
      window.location.href = url;
      return;
    }

    var sequence = ++navSequence;
    if (navController) navController.abort();
    navController = new AbortController();
    var controller = navController;
    if (!options.silent) setLoading(true);

    try {
      var response = await fetch(url, {
        method: "GET",
        signal: controller.signal,
        credentials: "same-origin",
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest",
          "X-GoodPipeline-Partial": "true"
        }
      });
      if (!response.ok) throw new Error("HTTP " + response.status + " " + response.statusText);
      var html = await response.text();
      if (controller.signal.aborted || sequence !== navSequence) return;

      var doc = new DOMParser().parseFromString(html, "text/html");
      var sources = SWAP_REGIONS.map(function (id) { return doc.getElementById(id); });
      if (sources.some(function (node) { return !node; })) throw new Error("partial response is missing a dashboard region");

      targets.forEach(function (target, index) { replaceContents(target, sources[index]); });
      if (options.history === "replace") history.replaceState({}, "", url);
      if (options.history !== "replace" && options.history !== "none") history.pushState({}, "", url);
      syncSearchFromUrl();
      initializeDynamicContent();
    } catch (error) {
      if (error && error.name === "AbortError") return;
      if (sequence !== navSequence) return;
      console.error("[good_pipeline] partial navigation failed", error);
      window.location.href = url;
    } finally {
      if (sequence === navSequence) setLoading(false);
    }
  }

  function searchUrl(form) {
    var url = new URL(form.action || window.location.href, window.location.origin);
    var params = new URL(latestRequestedUrl, window.location.origin).searchParams;
    params.delete("q");
    params.delete("page");
    params.delete("expanded");
    var data = new FormData(form);
    var query = String(data.get("q") || "").trim();
    if (query) params.set("q", query);
    url.search = params.toString();
    return url.toString();
  }

  function segmentUrl(link) {
    var url = new URL(latestRequestedUrl, window.location.origin);
    var key = link.getAttribute("data-gp-segment");
    var value = link.getAttribute("data-gp-segment-value");
    if (key && value) url.searchParams.set(key, value);
    url.searchParams.delete("page");
    url.searchParams.delete("expanded");

    var input = document.querySelector("form[data-gp-search-form] input[name=q]");
    if (input) {
      var query = input.value.trim();
      if (query) url.searchParams.set("q", query);
      else url.searchParams.delete("q");
    }
    return url.toString();
  }

  var COPY_ICON = '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8l3 3 7-7"></path></svg>';

  function announce(message) {
    var region = document.getElementById("gp-aria-live");
    if (!region) return;
    region.textContent = "";
    requestAnimationFrame(function () { region.textContent = message; });
  }

  function flashCopied(button) {
    var original = button.innerHTML;
    var label = button.getAttribute("data-gp-copy-label") || "text";
    button.innerHTML = COPY_ICON;
    announce("Copied " + label);
    if (button._gpCopyTimer) clearTimeout(button._gpCopyTimer);
    button._gpCopyTimer = setTimeout(function () {
      if (button.isConnected) button.innerHTML = original;
    }, 1100);
  }

  function fallbackCopy(value) {
    var area = document.createElement("textarea");
    area.value = value;
    area.setAttribute("readonly", "");
    area.setAttribute("aria-hidden", "true");
    area.style.position = "fixed";
    area.style.left = "-9999px";
    area.style.top = "0";
    document.body.appendChild(area);
    area.select();
    area.setSelectionRange(0, value.length);
    var copied = false;
    try { copied = document.execCommand("copy"); } catch (_error) { copied = false; }
    area.remove();
    return copied;
  }

  function copyValue(button) {
    var value = button.getAttribute("data-gp-copy");
    if (value == null) return;
    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      navigator.clipboard.writeText(value).then(function () {
        flashCopied(button);
      }).catch(function () {
        if (fallbackCopy(value)) flashCopied(button);
        else announce("Copy failed");
      });
    } else if (fallbackCopy(value)) {
      flashCopied(button);
    } else {
      announce("Copy failed");
    }
  }

  function currentTheme() {
    return document.documentElement.getAttribute("data-gp-theme") === "light" ? "light" : "dark";
  }

  function updateThemeButtons(theme) {
    document.querySelectorAll("[data-gp-theme-toggle]").forEach(function (button) {
      button.textContent = theme === "dark" ? "◐" : "◑";
    });
  }

  function setTheme(theme) {
    document.documentElement.setAttribute("data-gp-theme", theme);
    updateThemeButtons(theme);
    renderVisibleDiagrams(true);
  }

  function toggleTheme() {
    var previous = currentTheme();
    var next = previous === "dark" ? "light" : "dark";
    setTheme(next);
    var meta = document.querySelector('meta[name="good-pipeline-theme-url"]');
    var url = meta ? meta.content : "theme";
    fetch(url, {
      method: "PATCH",
      credentials: "same-origin",
      headers: { "Accept": "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
      body: JSON.stringify({ theme: next })
    }).then(function (response) {
      if (!response.ok) throw new Error("HTTP " + response.status);
    }).catch(function (error) {
      setTheme(previous);
      console.warn("[good_pipeline] theme persistence failed", error);
    });
  }

  function graphFrom(container) {
    var value = container.getAttribute("data-graph") || "";
    try {
      var parsed = JSON.parse(value);
      return parsed && typeof parsed === "object" ? String(parsed.graph || "") : String(parsed || "");
    } catch (_error) {
      return value;
    }
  }

  function diagramPalette(theme) {
    if (theme === "light") {
      return { bg:"#f5f6f8",node:"#eef0f4",text:"#0f1216",border:"#cdd2da",line:"#8a92a0",success:"#2f8a52",running:"#2563d4",failed:"#c43a3a",halted:"#b16a1f",skipped:"#6b7384",branch:"#b16a1f",terminal:"#1a1d22",terminalText:"#ffffff" };
    }
    return { bg:"#0c0d10",node:"#1a1e24",text:"#e6e9ef",border:"#2a2f38",line:"#5d6573",success:"#4ea36b",running:"#6694e8",failed:"#d96565",halted:"#c98a3f",skipped:"#6b7384",branch:"#c98a3f",terminal:"#d6deea",terminalText:"#0c0d10" };
  }

  function graphClasses(palette) {
    return [
      "  classDef step fill:" + palette.node + ",color:" + palette.text + ",stroke:" + palette.border,
      "  classDef pending fill:" + palette.node + ",color:" + palette.skipped + ",stroke:" + palette.skipped,
      "  classDef running fill:" + palette.running + ",color:#fff,stroke:" + palette.running,
      "  classDef enqueued fill:" + palette.running + ",color:#fff,stroke:" + palette.running,
      "  classDef succeeded fill:" + palette.success + ",color:#fff,stroke:" + palette.success,
      "  classDef failed fill:" + palette.failed + ",color:#fff,stroke:" + palette.failed,
      "  classDef halted fill:" + palette.halted + ",color:#fff,stroke:" + palette.halted,
      "  classDef canceled fill:" + palette.node + ",color:" + palette.skipped + ",stroke:" + palette.skipped,
      "  classDef skipped fill:" + palette.node + ",color:" + palette.skipped + ",stroke:" + palette.skipped,
      "  classDef skipped_by_branch fill:" + palette.node + ",color:" + palette.skipped + ",stroke:" + palette.skipped,
      "  classDef branch fill:" + palette.branch + ",color:#fff,stroke:" + palette.branch,
      "  classDef terminal fill:" + palette.terminal + ",color:" + palette.terminalText + ",stroke:" + palette.terminal
    ].join("\n");
  }

  function diagramIsVisible(container) {
    var definition = container.closest(".gp-definition-panel");
    if (definition && !definition.classList.contains("is-active")) return false;
    var panel = container.closest(".gp-graph-panel");
    return !panel || !panel.hidden;
  }

  function diagramError(container, message) {
    var canvas = container.querySelector(".gp-diagram-canvas");
    if (!canvas) return;
    while (canvas.firstChild) canvas.removeChild(canvas.firstChild);
    var error = document.createElement("div");
    error.className = "gp-diagram-error";
    error.setAttribute("role", "alert");
    error.textContent = message;
    canvas.appendChild(error);
  }

  async function performRender(task) {
    var container = task.container;
    if (!container.isConnected || !diagramIsVisible(container)) return;
    if (!window.mermaid || typeof window.mermaid.render !== "function") {
      diagramError(container, "The diagram renderer could not be loaded.");
      return;
    }
    var graph = graphFrom(container);
    if (!graph) {
      diagramError(container, "No graph definition is available.");
      return;
    }
    var edgeCount = Number(container.getAttribute("data-edge-count") || 0);
    if (edgeCount > 1000) {
      diagramError(container, "Full graph disabled: " + edgeCount + " edges exceeds Mermaid's 1,000-edge safety limit.");
      return;
    }
    var theme = currentTheme();
    var palette = diagramPalette(theme);
    var definition = graph + "\n" + graphClasses(palette);
    window.mermaid.initialize({
      startOnLoad:false,
      securityLevel:"strict",
      theme:"base",
      maxEdges:1000,
      themeVariables:{ background:"transparent",primaryColor:palette.node,primaryTextColor:palette.text,primaryBorderColor:palette.border,lineColor:palette.line,fontFamily:"JetBrains Mono, monospace",fontSize:"11px",edgeLabelBackground:palette.bg },
      flowchart:{ curve:"basis",nodeSpacing:26,rankSpacing:38,useMaxWidth:false }
    });
    var result = await window.mermaid.render("gp-dag-" + (++mermaidId), definition);
    if (!container.isConnected || renderTokens.get(container) !== task.token) return;
    var canvas = container.querySelector(".gp-diagram-canvas");
    if (!canvas) return;
    canvas.innerHTML = result.svg;
    var svg = canvas.querySelector("svg");
    if (svg) { svg.style.maxWidth = "100%"; svg.style.height = "auto"; }
    container.setAttribute("data-rendered-theme", theme);
  }

  function drainRenderQueue() {
    if (mermaidBusy || !queuedRender) return;
    var task = queuedRender;
    queuedRender = null;
    mermaidBusy = true;
    performRender(task).catch(function (error) {
      if (task.container.isConnected && renderTokens.get(task.container) === task.token) {
        diagramError(task.container, "Diagram render failed: " + (error && error.message ? error.message : "unknown error"));
      }
    }).finally(function () {
      mermaidBusy = false;
      drainRenderQueue();
    });
  }

  function requestDiagramRender(container, force) {
    if (!container || !diagramIsVisible(container)) return;
    if (!force && container.getAttribute("data-rendered-theme") === currentTheme() && container.querySelector("svg")) return;
    var token = ++renderSequence;
    renderTokens.set(container, token);
    queuedRender = { container:container, token:token };
    drainRenderQueue();
  }

  function renderVisibleDiagrams(force) {
    var diagrams = Array.from(document.querySelectorAll(".gp-diagram-container[data-graph]"));
    // Each screen has one visible graph. Iteration order still makes the newest
    // visible request win if host markup accidentally exposes more than one.
    diagrams.forEach(function (container) {
      if (diagramIsVisible(container)) requestDiagramRender(container, force);
    });
  }

  function viewportState(container) {
    if (!viewportStates.has(container)) viewportStates.set(container, { scale:1, panX:0, panY:0 });
    return viewportStates.get(container);
  }

  function applyViewport(container) {
    var state = viewportState(container);
    var canvas = container.querySelector(".gp-diagram-canvas");
    if (canvas) canvas.style.transform = "translate(" + state.panX + "px," + state.panY + "px) scale(" + state.scale + ")";
  }

  function resetViewport(container) {
    if (!container) return;
    viewportStates.set(container, { scale:1, panX:0, panY:0 });
    applyViewport(container);
  }

  function zoomViewport(container, delta, centerX, centerY) {
    var state = viewportState(container);
    var oldScale = state.scale;
    var next = Math.max(MIN_SCALE, Math.min(MAX_SCALE, oldScale + delta));
    if (next === oldScale) return;
    var ratio = next / oldScale;
    state.panX = centerX - (centerX - state.panX) * ratio;
    state.panY = centerY - (centerY - state.panY) * ratio;
    state.scale = next;
    applyViewport(container);
  }

  function bindViewport(viewport) {
    if (viewport.dataset.gpViewportBound === "true") return;
    viewport.dataset.gpViewportBound = "true";
    viewport.addEventListener("wheel", function (event) {
      event.preventDefault();
      var container = viewport.closest(".gp-diagram-container");
      var rect = viewport.getBoundingClientRect();
      zoomViewport(container, event.deltaY < 0 ? ZOOM_STEP : -ZOOM_STEP, event.clientX - rect.left, event.clientY - rect.top);
    }, { passive:false });
    viewport.addEventListener("pointerdown", function (event) {
      if (event.button !== 0) return;
      var container = viewport.closest(".gp-diagram-container");
      var canvas = container.querySelector(".gp-diagram-canvas");
      var state = viewportState(container);
      var startX = event.clientX - state.panX;
      var startY = event.clientY - state.panY;
      if (canvas) canvas.classList.add("is-dragging");
      viewport.setPointerCapture(event.pointerId);
      function move(moveEvent) {
        state.panX = moveEvent.clientX - startX;
        state.panY = moveEvent.clientY - startY;
        applyViewport(container);
      }
      function up() {
        if (canvas) canvas.classList.remove("is-dragging");
        viewport.removeEventListener("pointermove", move);
        viewport.removeEventListener("pointerup", up);
        viewport.removeEventListener("pointercancel", up);
      }
      viewport.addEventListener("pointermove", move);
      viewport.addEventListener("pointerup", up);
      viewport.addEventListener("pointercancel", up);
    });
  }

  function initializeDynamicContent() {
    document.querySelectorAll(".gp-diagram-viewport").forEach(bindViewport);
    renderVisibleDiagrams(false);
  }

  function switchDefinition(button) {
    var targetId = button.getAttribute("data-gp-definition-target");
    var panel = document.getElementById(targetId);
    if (!panel) return;
    document.querySelectorAll(".gp-definition-item").forEach(function (item) {
      var active = item === button;
      item.classList.toggle("is-active", active);
      item.setAttribute("aria-selected", active ? "true" : "false");
    });
    document.querySelectorAll(".gp-definition-panel").forEach(function (item) { item.classList.toggle("is-active", item === panel); });
    var crumb = document.querySelector("[data-gp-active-crumb]");
    var meta = document.querySelector("[data-gp-active-meta]");
    if (crumb) crumb.textContent = button.getAttribute("data-gp-definition-name") || "";
    if (meta) meta.textContent = button.getAttribute("data-gp-definition-meta") || "";
    var diagram = panel.querySelector(".gp-diagram-container");
    resetViewport(diagram);
    requestDiagramRender(diagram, false);
  }

  function toggleGraph(button) {
    var card = button.closest(".gp-card");
    if (!card) return;
    var graphPanel = card.querySelector(".gp-graph-panel");
    var stagePanel = card.querySelector(".gp-stage-panel");
    if (!graphPanel || !stagePanel) return;
    var showGraph = graphPanel.hidden;
    graphPanel.hidden = !showGraph;
    stagePanel.hidden = showGraph;
    button.textContent = showGraph ? "stage view" : "render full graph";
    button.setAttribute("aria-pressed", showGraph ? "true" : "false");
    var diagram = graphPanel.querySelector(".gp-diagram-container");
    resetViewport(diagram);
    if (showGraph) requestDiagramRender(diagram, false);
  }

  document.addEventListener("click", function (event) {
    var copy = event.target.closest("[data-gp-copy]");
    if (copy) { event.preventDefault(); event.stopPropagation(); copyValue(copy); return; }

    var theme = event.target.closest("[data-gp-theme-toggle]");
    if (theme) { event.preventDefault(); toggleTheme(); return; }

    var definition = event.target.closest("[data-gp-definition-target]");
    if (definition) { event.preventDefault(); switchDefinition(definition); return; }

    var graphToggle = event.target.closest("[data-gp-graph-toggle]");
    if (graphToggle && !graphToggle.disabled) { event.preventDefault(); toggleGraph(graphToggle); return; }

    var diagramAction = event.target.closest("[data-gp-diagram-action]");
    if (diagramAction) {
      event.preventDefault();
      var container = diagramAction.closest(".gp-diagram-container");
      if (!container) {
        var diagramCard = diagramAction.closest(".gp-card");
        container = diagramCard && diagramCard.querySelector(".gp-diagram-container");
      }
      var viewport = container && container.querySelector(".gp-diagram-viewport");
      var action = diagramAction.getAttribute("data-gp-diagram-action");
      if (action === "reset") resetViewport(container);
      if ((action === "in" || action === "out") && viewport) {
        var rect = viewport.getBoundingClientRect();
        zoomViewport(container, action === "in" ? ZOOM_STEP : -ZOOM_STEP, rect.width / 2, rect.height / 2);
      }
      if (action === "fullscreen" && container) {
        var fullscreenTarget = container.closest(".gp-card") || container;
        if (document.fullscreenElement === fullscreenTarget) document.exitFullscreen();
        else if (fullscreenTarget.requestFullscreen) fullscreenTarget.requestFullscreen();
      }
      return;
    }

    var partial = event.target.closest("a[data-gp-partial-link]");
    if (partial) {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || partial.target === "_blank") return;
      event.preventDefault();
      var href = partial.href;
      if (partial.hasAttribute("data-gp-segment")) {
        if (searchTimer) { clearTimeout(searchTimer); searchTimer = null; }
        href = segmentUrl(partial);
      }
      partialNav(href, { history:"push" });
      return;
    }

    var row = event.target.closest("tr[data-gp-expand-url]");
    if (row && !event.target.closest("a,button,input,select,textarea")) {
      partialNav(row.getAttribute("data-gp-expand-url"), { history:"push" });
      return;
    }
  });

  document.addEventListener("input", function (event) {
    var form = event.target.closest("form[data-gp-search-form]");
    if (!form) return;
    if (searchTimer) clearTimeout(searchTimer);
    searchTimer = setTimeout(function () {
      partialNav(searchUrl(form), { history:"replace", silent:true });
    }, 300);
  });

  document.addEventListener("submit", function (event) {
    var confirmable = event.target.closest("form[data-gp-confirm]");
    if (confirmable) {
      var message = confirmable.getAttribute("data-gp-confirm");
      if (message && !window.confirm(message)) event.preventDefault();
      return;
    }

    var form = event.target.closest("form[data-gp-search-form]");
    if (!form) return;
    event.preventDefault();
    if (searchTimer) { clearTimeout(searchTimer); searchTimer = null; }
    partialNav(searchUrl(form), { history:"push" });
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      var collapse = document.querySelector("[data-collapse-expand]");
      if (collapse) { event.preventDefault(); collapse.click(); }
      return;
    }
    if (event.target.matches("input,textarea,select") || event.target.isContentEditable) return;
    if (event.key === "/") {
      var search = document.querySelector("form[data-gp-search-form] input[type=search]");
      if (search) { event.preventDefault(); search.focus(); }
    }
  });

  window.addEventListener("popstate", function () {
    latestRequestedUrl = window.location.href;
    partialNav(window.location.href, { history:"none", silent:true });
  });

  initializeDynamicContent();
})();
