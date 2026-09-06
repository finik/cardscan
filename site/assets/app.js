/* The Deck Vault — typeahead search + Cover Flow carousel. No framework. */
(function () {
  "use strict";

  // ---- Index: typeahead combobox (names + tags) ------------------------
  var q = document.getElementById("q");
  if (q) {
    var ac = document.getElementById("ac");
    var decks = window.__DECKS__ || [];
    var grid = document.getElementById("grid");
    var empty = document.getElementById("empty");
    var emptyQ = document.getElementById("empty-q");
    var filterBar = document.getElementById("filter");
    var filterChip = document.getElementById("filter-chip");
    var cards = Array.prototype.slice.call(grid.querySelectorAll(".deck-card"));

    var options = []; // parallel to rendered .ac-item nodes
    var active = -1;

    var tagCounts = {};
    decks.forEach(function (d) {
      (d.tags || []).forEach(function (t) { tagCounts[t] = (tagCounts[t] || 0) + 1; });
    });
    var allTags = Object.keys(tagCounts).sort();

    var lower = function (s) { return String(s).toLowerCase(); };
    var esc = function (s) {
      return String(s).replace(/[&<>"]/g, function (c) {
        return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
      });
    };
    var hl = function (s, term) {
      var i = lower(s).indexOf(lower(term));
      if (i < 0 || !term) return esc(s);
      return esc(s.slice(0, i)) + "<mark>" + esc(s.slice(i, i + term.length)) +
        "</mark>" + esc(s.slice(i + term.length));
    };

    var closeAc = function () {
      ac.hidden = true;
      ac.innerHTML = "";
      options = [];
      active = -1;
      q.setAttribute("aria-expanded", "false");
    };

    var applyTag = function (tag) {
      var t = lower(tag);
      var shown = 0;
      cards.forEach(function (c) {
        var hit = c.dataset.tags.split(" ").indexOf(t) !== -1;
        c.hidden = !hit;
        if (hit) shown++;
      });
      filterChip.textContent = "#" + tag;
      filterBar.hidden = false;
      empty.hidden = shown !== 0;
      if (emptyQ) emptyQ.textContent = tag;
      q.value = "";
      closeAc();
      q.blur();
      window.scrollTo({ top: 0, behavior: "smooth" });
    };

    var clearFilter = function () {
      cards.forEach(function (c) { c.hidden = false; });
      filterBar.hidden = true;
      empty.hidden = true;
    };
    document.getElementById("filter-clear").addEventListener("click", clearFilter);

    var choose = function (i) {
      var o = options[i];
      if (!o) return;
      if (o.type === "deck") location.href = o.href;
      else applyTag(o.tag);
    };

    var setActive = function (i) {
      var prev = ac.querySelector(".ac-item.active");
      if (prev) prev.classList.remove("active");
      active = i;
      if (i < 0) return;
      var el = ac.querySelector('.ac-item[data-i="' + i + '"]');
      if (el) { el.classList.add("active"); el.scrollIntoView({ block: "nearest" }); }
    };

    var render = function (term) {
      options = [];
      active = -1;
      if (!term) { closeAc(); return; }
      var t = lower(term);
      var deckHits = decks.filter(function (d) { return lower(d.name).indexOf(t) !== -1; }).slice(0, 6);
      var tagHits = allTags.filter(function (tg) { return lower(tg).indexOf(t) !== -1; }).slice(0, 5);

      if (!deckHits.length && !tagHits.length) {
        ac.innerHTML = '<li class="ac-empty" aria-disabled="true">No matches</li>';
        ac.hidden = false;
        q.setAttribute("aria-expanded", "true");
        return;
      }
      var html = "";
      if (deckHits.length) {
        html += '<li class="ac-group" role="presentation">Decks</li>';
        deckHits.forEach(function (d) {
          options.push({ type: "deck", href: d.href });
          var cov = d.cover ? '<img src="' + esc(d.cover) + '" alt="">' : "";
          html += '<li class="ac-item ac-deck" role="option" data-i="' + (options.length - 1) + '">' +
            '<span class="ac-thumb">' + cov + '</span>' +
            '<span class="ac-text"><span class="ac-name">' + hl(d.name, term) + '</span>' +
            (d.sub ? '<span class="ac-sub">' + esc(d.sub) + '</span>' : "") +
            '</span></li>';
        });
      }
      if (tagHits.length) {
        html += '<li class="ac-group" role="presentation">Tags</li>';
        tagHits.forEach(function (tg) {
          options.push({ type: "tag", tag: tg });
          html += '<li class="ac-item ac-tag" role="option" data-i="' + (options.length - 1) + '">' +
            '<span class="ac-hash">#</span><span class="ac-tagname">' + hl(tg, term) + '</span>' +
            '<span class="ac-count">' + tagCounts[tg] + '</span></li>';
        });
      }
      ac.innerHTML = html;
      ac.hidden = false;
      q.setAttribute("aria-expanded", "true");
    };

    q.addEventListener("input", function () { render(q.value.trim()); });
    q.addEventListener("keydown", function (ev) {
      if (ac.hidden) return;
      if (ev.key === "ArrowDown") { ev.preventDefault(); setActive(Math.min(active + 1, options.length - 1)); }
      else if (ev.key === "ArrowUp") { ev.preventDefault(); setActive(Math.max(active - 1, 0)); }
      else if (ev.key === "Enter") { ev.preventDefault(); choose(active >= 0 ? active : 0); }
      else if (ev.key === "Escape") { closeAc(); }
    });
    // mousedown (not click) so it fires before the input blur closes the list.
    ac.addEventListener("mousedown", function (ev) {
      var li = ev.target.closest(".ac-item");
      if (!li) return;
      ev.preventDefault();
      choose(parseInt(li.dataset.i, 10));
    });
    ac.addEventListener("mousemove", function (ev) {
      var li = ev.target.closest(".ac-item");
      if (li) setActive(parseInt(li.dataset.i, 10));
    });
    document.addEventListener("click", function (ev) {
      if (!ev.target.closest(".search")) closeAc();
    });

    // Deep links: ?tag=foil filters; ?q=vik seeds the box.
    var params = new URLSearchParams(location.search);
    if (params.get("tag")) applyTag(params.get("tag"));
    else if (params.get("q")) { q.value = params.get("q"); render(q.value.trim()); }

    // ---- Sort control (remembers choice) ----
    var sortSel = document.getElementById("sort");
    if (sortSel) {
      var applySort = function (mode) {
        cards.slice().sort(function (a, b) {
          if (mode === "name-asc") return a.dataset.name.localeCompare(b.dataset.name);
          if (mode === "name-desc") return b.dataset.name.localeCompare(a.dataset.name);
          var ta = +a.dataset.added, tb = +b.dataset.added;
          return mode === "added-asc" ? ta - tb : tb - ta;
        }).forEach(function (c) { grid.appendChild(c); });
      };
      var saved = null;
      try { saved = localStorage.getItem("deckSort"); } catch (e) { /* private mode */ }
      if (saved && saved !== sortSel.value) { sortSel.value = saved; applySort(saved); }
      sortSel.addEventListener("change", function () {
        applySort(sortSel.value);
        try { localStorage.setItem("deckSort", sortSel.value); } catch (e) { /* ignore */ }
      });
    }
  }

  // ---- Deck page: parallax on the card-back background -----------------
  var bg = document.querySelector(".deck-bg");
  if (bg && !(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches)) {
    var bgTicking = false;
    var bgUpdate = function () {
      bg.style.backgroundPositionY = "calc(50% - " + ((window.scrollY || 0) * 0.18) + "px)";
      bgTicking = false;
    };
    window.addEventListener("scroll", function () {
      if (!bgTicking) { bgTicking = true; requestAnimationFrame(bgUpdate); }
    }, { passive: true });
    bgUpdate();
  }

  // ---- Deck page: Cover Flow lightbox ----------------------------------
  var slides = window.__SLIDES__;
  if (!slides || !slides.length) return;

  var VIS = 5;
  var lb = document.getElementById("lightbox");
  var track = document.getElementById("cf-track");
  var cap = lb.querySelector(".cf-label");
  var cur = 0;
  var els = [];

  slides.forEach(function (s, i) {
    var d = document.createElement("div");
    d.className = "cf-slide";
    var img = document.createElement("img");
    img.alt = s.label;
    img.dataset.src = s.src;
    d.appendChild(img);
    d.addEventListener("click", function (ev) {
      ev.stopPropagation();
      if (i !== cur) show(i); // click a side card to bring it to front
    });
    track.appendChild(d);
    els.push(d);
  });

  var ensureLoaded = function (i) {
    var img = els[i] && els[i].firstChild;
    if (img && !img.src && img.dataset.src) img.src = img.dataset.src;
  };

  var layout = function () {
    var w = els[cur].offsetWidth || 280;
    for (var i = 0; i < els.length; i++) {
      var d = i - cur;
      var ad = Math.abs(d);
      var el = els[i];
      if (ad > VIS) {
        el.style.opacity = "0";
        el.style.pointerEvents = "none";
        el.style.transform = "translate(-50%, -50%) translateX(" + (d < 0 ? -1 : 1) * w * 2 + "px)";
        continue;
      }
      ensureLoaded(i);
      el.style.opacity = "1";
      el.style.pointerEvents = "auto";
      el.style.zIndex = String(100 - ad);
      if (d === 0) {
        el.style.transform = "translate(-50%, -50%) translateZ(60px) rotateY(0deg) scale(1.04)";
      } else {
        var sign = d < 0 ? -1 : 1;
        var x = sign * (w * 0.62 + (ad - 1) * w * 0.22);
        var z = -(w * 0.5 + (ad - 1) * w * 0.16);
        var ry = -sign * 55;
        el.style.transform =
          "translate(-50%, -50%) translateX(" + x + "px) translateZ(" + z + "px) rotateY(" + ry + "deg)";
      }
    }
  };

  var show = function (i) {
    cur = (i + slides.length) % slides.length;
    cap.textContent = slides[cur].label;
    layout();
  };
  var open = function (i) {
    lb.hidden = false;
    document.body.style.overflow = "hidden";
    show(i);
    requestAnimationFrame(layout);
  };
  var close = function () {
    lb.hidden = true;
    document.body.style.overflow = "";
  };

  document.addEventListener("click", function (ev) {
    var t = ev.target.closest("[data-idx]");
    if (t) { ev.preventDefault(); open(parseInt(t.dataset.idx, 10)); }
  });

  lb.querySelector(".lb-close").addEventListener("click", close);
  var stage = lb.querySelector(".cf-stage");
  // Clicking a specific side card jumps to it (per-slide handler). Clicking the
  // empty space to either side steps one card that way. Only ✕ / Esc close.
  stage.addEventListener("click", function (ev) {
    if (ev.target.closest(".cf-slide")) return;
    var rect = stage.getBoundingClientRect();
    show(cur + (ev.clientX < rect.left + rect.width / 2 ? -1 : 1));
  });

  document.addEventListener("keydown", function (ev) {
    if (lb.hidden) return;
    if (ev.key === "Escape") close();
    else if (ev.key === "ArrowRight") show(cur + 1);
    else if (ev.key === "ArrowLeft") show(cur - 1);
  });

  // Mouse-wheel / trackpad scroll (either axis) flips cards, speed-proportional.
  var wheelAcc = 0;
  stage.addEventListener("wheel", function (ev) {
    ev.preventDefault();
    var delta = Math.abs(ev.deltaY) >= Math.abs(ev.deltaX) ? ev.deltaY : ev.deltaX;
    wheelAcc += delta;
    var step = Math.trunc(wheelAcc / 40);
    if (step) {
      wheelAcc -= step * 40;
      show(cur + Math.max(-4, Math.min(4, step)));
    }
  }, { passive: false });

  // Swipe: distance maps to number of cards, so a fast flick scrolls far.
  var x0 = null;
  stage.addEventListener("touchstart", function (ev) { x0 = ev.touches[0].clientX; }, { passive: true });
  stage.addEventListener("touchend", function (ev) {
    if (x0 === null) return;
    var dx = ev.changedTouches[0].clientX - x0;
    var w = (els[cur].offsetWidth || 280) * 0.6;
    var step = Math.round(dx / w);
    if (Math.abs(dx) > 30 && step) show(cur - step); // swipe left → forward
    x0 = null;
  }, { passive: true });

  window.addEventListener("resize", function () { if (!lb.hidden) layout(); });
})();
