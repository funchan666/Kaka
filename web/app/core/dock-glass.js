(() => {
  const {get, records} = window.Kaka;
  const app = get('app');
  const navigation = app.querySelector('.tabbar');
  const dock = navigation.querySelector('.tabs-inner');
  const tabs = Array.from(dock.querySelectorAll('[data-tab-link]'), (link) => link.dataset.tabLink);
  let lastGeometry;
  let lastFrame = null;
  let lastTab = null;
  let request = 0;

  function canNavigate(tab) {
    return tabs.includes(tab) && !app.hidden && !app.hasAttribute('aria-hidden')
      && app.dataset.keyboard !== 'true' && !document.hidden;
  }

  function visibleFrame(geometry) {
    if (!geometry?.dockGlass || !canNavigate(app.dataset.tab)) return null;
    const viewport = window.visualViewport;
    if (viewport && (Math.abs(viewport.scale - 1) > .001
      || Math.abs(viewport.offsetLeft) > 1 || Math.abs(viewport.offsetTop) > 1)) return null;
    const viewportWidth = viewport?.width ?? window.innerWidth;
    const viewportHeight = viewport?.height ?? window.innerHeight;
    if (Math.abs(viewportWidth - geometry.width) > 1 || Math.abs(viewportHeight - geometry.height) > 1) return null;
    const {x, y, width, height} = dock.getBoundingClientRect();
    return {x, y, width, height, viewportWidth, viewportHeight};
  }

  async function sync(geometry) {
    const frame = visibleFrame(geometry);
    const key = frame && JSON.stringify(frame);
    const tab = frame ? app.dataset.tab : null;
    const moved = geometry !== lastGeometry || key !== lastFrame;
    if (!moved && tab === lastTab) return;

    const hadFrame = lastFrame !== null;
    lastGeometry = geometry;
    lastFrame = key;
    lastTab = tab;
    const current = ++request;
    if (moved) delete navigation.dataset.nativeGlass;
    if (!geometry?.dockGlass || (!frame && !hadFrame)) return;

    try {
      const shown = await records.call('dock.glass', {frame, tab});
      if (current !== request) return;
      if (shown === true && key === JSON.stringify(visibleFrame(geometry))) {
        navigation.dataset.nativeGlass = 'true';
      } else {
        delete navigation.dataset.nativeGlass;
      }
    } catch {
      if (current !== request) return;
      lastGeometry = undefined;
      delete navigation.dataset.nativeGlass;
    }
  }

  window.addEventListener('kaka:dock-select', ({detail: tab}) => {
    if (canNavigate(tab)) window.Kaka.go(tab);
  });
  window.Kaka.tabDock = {sync};
})();
