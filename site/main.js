/* varde — landing page interactions
   Vanilla JS, no dependencies. Progressive enhancement only. */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------------------------------------------------------------
     Copy to clipboard
     Each .btn-copy has data-target -> id of element whose textContent
     is copied. Shows a "Copied" affordance, with execCommand fallback.
     --------------------------------------------------------------- */
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      try {
        var ok = document.execCommand("copy");
        document.body.removeChild(ta);
        ok ? resolve() : reject();
      } catch (e) {
        document.body.removeChild(ta);
        reject(e);
      }
    });
  }

  document.querySelectorAll(".btn-copy").forEach(function (btn) {
    var labelEl = btn.querySelector(".btn-copy__text");
    var defaultLabel = labelEl ? labelEl.textContent : "";
    var timer;

    btn.addEventListener("click", function () {
      var target = document.getElementById(btn.getAttribute("data-target"));
      if (!target) return;
      var text = target.textContent.replace(/ /g, " ").trimEnd();

      copyText(text).then(function () {
        btn.classList.add("is-copied");
        if (labelEl) labelEl.textContent = "Copied";
        btn.setAttribute("aria-label", "Copied to clipboard");
        clearTimeout(timer);
        timer = setTimeout(function () {
          btn.classList.remove("is-copied");
          if (labelEl) labelEl.textContent = defaultLabel;
        }, 1700);
      }).catch(function () {
        if (labelEl) labelEl.textContent = "Press Ctrl+C";
        clearTimeout(timer);
        timer = setTimeout(function () {
          if (labelEl) labelEl.textContent = defaultLabel;
        }, 1700);
      });
    });
  });

  /* ---------------------------------------------------------------
     Tabs (WAI-ARIA tabs pattern) for the Usage section
     --------------------------------------------------------------- */
  var tablist = document.querySelector('[role="tablist"]');
  if (tablist) {
    var tabs = Array.prototype.slice.call(tablist.querySelectorAll('[role="tab"]'));

    function selectTab(tab, setFocus) {
      tabs.forEach(function (t) {
        var selected = t === tab;
        t.setAttribute("aria-selected", selected ? "true" : "false");
        t.setAttribute("tabindex", selected ? "0" : "-1");
        t.classList.toggle("is-active", selected);
        var panel = document.getElementById(t.getAttribute("aria-controls"));
        if (panel) panel.hidden = !selected;
      });
      if (setFocus) tab.focus();
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () { selectTab(tab, false); });
      tab.addEventListener("keydown", function (e) {
        var idx = i;
        switch (e.key) {
          case "ArrowRight": case "ArrowDown": idx = (i + 1) % tabs.length; break;
          case "ArrowLeft":  case "ArrowUp":   idx = (i - 1 + tabs.length) % tabs.length; break;
          case "Home": idx = 0; break;
          case "End":  idx = tabs.length - 1; break;
          default: return;
        }
        e.preventDefault();
        selectTab(tabs[idx], true);
      });
    });
  }

  /* ---------------------------------------------------------------
     Scroll reveal. Honours reduced-motion (reveal immediately).
     --------------------------------------------------------------- */
  var reveals = Array.prototype.slice.call(document.querySelectorAll(".reveal"));

  // stagger index within a shared grid/flex parent
  reveals.forEach(function (el) {
    var sibs = Array.prototype.slice.call(el.parentElement.children).filter(function (c) {
      return c.classList && c.classList.contains("reveal");
    });
    el.style.setProperty("--i", sibs.indexOf(el));
  });

  if (reduceMotion || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
    reveals.forEach(function (el) { io.observe(el); });
  }
})();
