// curtain bridge: forwards input to the Swift core and applies the HTML regions it returns.
// Meaning of keys lives in Swift (RBUI KeyMap); here only intercept-or-native is decided.
(() => {
  const root = document.getElementById('app');
  const post = (msg) => window.webkit.messageHandlers.curtain.postMessage(msg).then(apply).catch(() => {});
  let screen = null, skeleton = null;

  function syncMirror(input) {
    if (!input.matches?.("input.q, input.b, input.e")) return;
    const mirror = input.parentElement.querySelector(".mirror");
    if (!mirror) return;
    if (input.selectionStart === input.value.length && input.selectionEnd === input.value.length) {
      const ghost = mirror.querySelector('.ghost');
      const end = ghost ? ghost.getBoundingClientRect().left - mirror.getBoundingClientRect().left + mirror.scrollLeft : mirror.scrollWidth;
      mirror.scrollLeft = end - mirror.clientWidth;
    } else {
      mirror.scrollLeft = input.scrollLeft;
    }
  }

  function apply(u) {
    if (!u) return;
    if (u.skeleton != null && (u.screen !== screen || u.skeleton !== skeleton || !root.firstChild)) {
      root.innerHTML = u.skeleton; screen = u.screen; skeleton = u.skeleton;
    }
    else if (u.skeleton != null && root.firstElementChild) {
      const p = root.firstElementChild; p.style.animation = 'none'; void p.offsetHeight; p.style.animation = '';
    }
    for (const [name, html] of u.regions || []) {
      const el = root.querySelector(`[data-region="${name}"]`);
      if (el && el.innerHTML !== html) el.innerHTML = html;
    }
    for (const [field, value] of Object.entries(u.values || {})) {
      const el = field.startsWith("setting:") ? root.querySelector(`[data-setting="${field.slice(8)}"]`) : root.querySelector(`input.${field}`);
      if (el && el.value !== value) { el.value = value; if (el.type !== "number") el.setSelectionRange(value.length, value.length); }
    }
    const f = u.focus && root.querySelector(`input.${u.focus}`);
    if (f && document.activeElement !== f) {
      f.focus();
      if (!u.selectAll) f.setSelectionRange(f.value.length, f.value.length);
    }
    if (f && u.selectAll) f.select();
    if (window.__rbSnapshot) {
      root.querySelectorAll('.mirror .caret').forEach((caret) => caret.remove());
      const mirror = f?.parentElement.querySelector('.mirror');
      if (mirror && !u.selectAll) {
        const caret = document.createElement('span');
        caret.className = f.classList.contains('b') ? 'caret warn' : 'caret';
        const first = mirror.firstChild;
        if (first?.nodeType === Node.TEXT_NODE) first.after(caret);
        else mirror.prepend(caret);
      }
    }
    root.querySelectorAll("input.q, input.b, input.e").forEach(syncMirror);
    const sel = root.querySelector('.row.sel, .prow.sel'), list = root.querySelector('.list');
    if (sel && list) {
      const r = sel.getBoundingClientRect(), l = list.getBoundingClientRect();
      if (r.top < l.top) list.scrollTop -= l.top - r.top; else if (r.bottom > l.bottom) list.scrollTop += r.bottom - l.bottom;
    }
    // Shell: content size for the popover and a paint mark for latency measurement.
    requestAnimationFrame(() => {
      root.querySelectorAll("input.q, input.b, input.e").forEach(syncMirror);
      const box = root.querySelector('[data-root]');
      window.webkit.messageHandlers.shell.postMessage({ w: box ? box.offsetWidth : 0, h: box ? box.offsetHeight : 0, t: performance.now() });
    });
  }

  function intercept(e) {
    const mod = e.metaKey || e.ctrlKey, k = e.key, lk = k.toLowerCase(), el = e.target;
    if (screen === 'M01') {
      if (k === 'Enter' && !mod && !e.altKey && !e.shiftKey && el.matches('button[data-act="showDue"]')) return false;
      if (['ArrowUp', 'ArrowDown', 'Enter', 'Tab', 'Escape'].includes(k)) return true;
      if (['ArrowLeft', 'ArrowRight'].includes(k) && !mod && !e.altKey && !e.shiftKey && el.classList.contains('q') && el.value === '') return true;
      if (k === 'Backspace') return mod || (el.classList.contains('q') && el.value === '');
      if (mod && !e.shiftKey && lk === 'c') return !(el.selectionStart !== undefined && el.selectionStart !== el.selectionEnd);
      return (e.metaKey && (['/', '?'].includes(k) || (e.shiftKey && e.code === 'Digit7'))) ||
        (mod && (['p', 'd', 'g', 's', 'z', 't', ','].includes(lk) || (e.shiftKey && lk === 'w')));
    }
    if (screen === 'M01-S1') return k === 'Enter' || k === 'Escape' || (mod && lk === 'z');
    if (screen === 'M00') return (k === 'Enter' && !el.closest('button')) || k === 'Escape' || (mod && (lk === ',' || lk === 't'));
    if (screen === 'M02') return !!root.querySelector('.kc.rec');
    return false;
  }

  document.addEventListener('keydown', (e) => {
    if (e.isComposing || !intercept(e)) return;
    e.preventDefault();
    const el = e.target, field = el.classList ? ['q', 'e', 'b', 'p'].find((c) => el.classList.contains(c)) || null : null;
    post({ t: 'key', key: e.key, code: e.code, meta: e.metaKey, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, field,
      fieldEmpty: !el.value, hasSelection: el.selectionStart !== undefined && el.selectionStart !== el.selectionEnd });
  });
  root.addEventListener('input', (e) => {
    syncMirror(e.target);
    const el = e.target, field = ['q', 'e', 'b', 'p'].find((c) => el.classList.contains(c));
    if (field && !e.isComposing) post({ t: 'text', field, value: el.value });
  });
  for (const event of ['keyup', 'click', 'select']) {
    root.addEventListener(event, (e) => syncMirror(e.target), true);
  }
  root.addEventListener('compositionend', (e) => {
    const el = e.target, field = ['q', 'e', 'b', 'p'].find((c) => el.classList.contains(c));
    if (field) post({ t: 'text', field, value: el.value });
  });
  root.addEventListener('change', (e) => {
    if (e.target.dataset.setting) post({ t: 'setting', path: e.target.dataset.setting, value: e.target.value });
  });
  root.addEventListener('click', (e) => {
    const a = e.target.closest('[data-act]');
    if (a) { post({ t: 'action', name: a.dataset.act, arg: a.dataset.arg || null }); return; }
    const r = e.target.closest('[data-sel]');
    if (r) post({ t: 'select', id: r.dataset.sel });
  });
  root.addEventListener('dblclick', (e) => {
    const r = e.target.closest('[data-sel]');
    if (r) post({ t: 'dbl', id: r.dataset.sel });
  });

  window.curtain = { apply };
  post({ t: 'ready' });
})();
