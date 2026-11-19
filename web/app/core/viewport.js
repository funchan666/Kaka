(() => {
  const {get} = window.Kaka;
  const root = document.documentElement;
  const dock = document.querySelector('.tabbar');
  const tabs = document.querySelector('.tabs-inner');
  const header = document.querySelector('.chrome-inner');
  let geometry;
  let pendingUpdate = false;

  function openSpan(start, end, obstructions) {
    let spans = [[start, end]];
    for (const {x, width} of obstructions) {
      spans = spans.flatMap(([left, right]) => {
        if (x >= right || x + width <= left) return [[left, right]];
        return [[left, x], [x + width, right]].filter(([a, b]) => b > a);
      });
    }
    return spans.reduce((current, span) => {
      if (!current || span[1] - span[0] > current[1] - current[0]) return span;
      return current;
    }, null);
  }

  function insetChrome(key, top, bottom, minimum, left, right) {
    const band = geometry.regions.filter((rect) => rect.y < bottom && rect.y + rect.height > top);
    const wide = band.filter((rect) => !rect.division && rect.width > (right - left) * 0.7);
    const offset = wide.reduce((amount, rect) => {
      const overlap = key === 'header' ? rect.y + rect.height - top : bottom - rect.y;
      return Math.max(amount, overlap);
    }, 0);
    const span = openSpan(left, right, band.filter((rect) => !wide.includes(rect)));
    const use = span && span[1] - span[0] >= minimum;
    setPixels(key + '-start', use ? span[0] - left : 0);
    setPixels(key + '-end', use ? right - span[1] : 0);
    setPixels(key + '-offset', offset);
  }

  function setPixels(key, value) {
    root.style.setProperty('--' + key, Math.max(0, Math.round(value)) + 'px');
  }

  function calculate() {
    const app = get('app');
    const visual = window.visualViewport;
    const focus = document.activeElement;
    const editing = focus?.matches('input:not([type="radio"]), textarea');
    const sameWidth = geometry && Math.abs(window.innerWidth - geometry.width) < 4;
    const layoutHeight = sameWidth ? Math.max(window.innerHeight, geometry.height) : window.innerHeight;
    const keyboard = Boolean(editing && visual && visual.scale === 1 && layoutHeight - visual.height > 70);
    root.dataset.keyboard = String(keyboard);
    app.dataset.keyboard = String(keyboard);
    if (keyboard) setPixels('visible-height', visual.height);
    else root.style.removeProperty('--visible-height');

    if (geometry && sameWidth) {
      const {width, height, left, right, top, bottom, regions} = geometry;
      const trailing = width - right;
      const center = height / 2;
      const dividing = regions.filter((rect) => rect.height > rect.width
        && rect.y <= center && rect.y + rect.height >= center);
      const content = openSpan(left, trailing, dividing);
      const usePane = content && content[1] - content[0] >= 192;
      setPixels('content-start', usePane ? content[0] - left : 0);
      setPixels('content-end', usePane ? trailing - content[1] : 0);
      const dockBottom = height - bottom;
      insetChrome('header', top, top + (header.offsetHeight || 58), 184, left, trailing);
      insetChrome('nav', dockBottom - (tabs.offsetHeight || 64), dockBottom, 208, left, trailing);
    } else {
      for (const key of ['content-start', 'content-end', 'header-start', 'header-end', 'header-offset', 'nav-start', 'nav-end', 'nav-offset']) {
        root.style.removeProperty('--' + key);
      }
    }
    setPixels('dock-space', keyboard ? 0 : dock.offsetHeight);

    if (keyboard) {
      const scroller = focus.closest('.screen');
      if (!scroller) return;
      requestAnimationFrame(() => {
        if (document.activeElement !== focus) return;
        const visibleBottom = Math.min(scroller.getBoundingClientRect().bottom, visual.height + visual.offsetTop);
        const overflow = focus.getBoundingClientRect().bottom - visibleBottom + 14;
        if (overflow > 0 && overflow < scroller.clientHeight) scroller.scrollTop += overflow;
      });
    }
  }

  function schedule() {
    if (pendingUpdate) return;
    pendingUpdate = true;
    requestAnimationFrame(() => {
      pendingUpdate = false;
      calculate();
    });
  }

  function update(snapshot) {
    if (!snapshot || !Number.isFinite(snapshot.width)) return;
    geometry = snapshot;
    root.dataset.reduceTransparency = String(snapshot.reduceTransparency === true);
    for (const edge of ['top', 'left', 'bottom', 'right']) setPixels('native-' + edge, snapshot[edge]);
    schedule();
  }

  window.addEventListener('kaka:geometry', (event) => update(event.detail));
  window.addEventListener('resize', schedule);
  window.visualViewport?.addEventListener('resize', schedule);
  const dockObserver = new ResizeObserver(schedule);
  dockObserver.observe(dock);
  document.addEventListener('focusin', schedule);
  document.addEventListener('focusout', schedule);
  document.addEventListener('click', (event) => {
    if (document.activeElement?.matches('input:not([type="radio"]), textarea')
      && !event.target.closest('input, textarea, button, a, label')) document.activeElement.blur();
  });

  window.Kaka.viewport = {update};
})();
