(() => {
  const {get, records} = window.Kaka;
  let geometry;
  let scheduleGlass;

  function updateGeometry(snapshot) {
    geometry = snapshot;
    scheduleGlass?.();
  }

  function initGlass() {
    const auth = get('auth');
    const scroll = get('auth-scroll');
    const join = get('welcome-join');
    let lastGeometry;
    let lastFrame = null;
    let request = 0;
    let scheduled = false;

    function visibleFrame(snapshot) {
      // Leave the link in the scrolling page when the viewport can move independently of UIKit.
      if (!snapshot?.welcomeGlass || auth.hidden || auth.dataset.page !== 'welcome'
        || document.activeElement === join || scroll.scrollHeight > scroll.clientHeight + 1) return null;
      const viewport = window.visualViewport;
      if (viewport && (viewport.scale !== 1 || viewport.offsetLeft || viewport.offsetTop)) return null;
      const viewportWidth = viewport?.width ?? window.innerWidth;
      const viewportHeight = viewport?.height ?? window.innerHeight;
      if (Math.abs(viewportWidth - snapshot.width) > 1 || Math.abs(viewportHeight - snapshot.height) > 1) return null;
      const {x, y, width, height, right, bottom} = join.getBoundingClientRect();
      const visible = scroll.getBoundingClientRect();
      if (width < 44 || height < 44 || x < visible.left || y < visible.top
        || right > visible.right || bottom > visible.bottom) return null;
      return {x, y, width, height, viewportWidth, viewportHeight};
    }

    async function syncGlass() {
      const snapshot = geometry;
      const frame = visibleFrame(snapshot);
      const key = frame && JSON.stringify(frame);
      if (snapshot === lastGeometry && key === lastFrame) return;
      const hadFrame = lastFrame !== null;
      lastGeometry = snapshot;
      lastFrame = key;
      const current = ++request;
      delete join.dataset.nativeGlass;
      if (!snapshot?.welcomeGlass || (!frame && !hadFrame)) return;
      try {
        const shown = await records.call('welcome.glass', {frame});
        if (shown === true && current === request && snapshot === geometry
          && key === JSON.stringify(visibleFrame(snapshot))) join.dataset.nativeGlass = 'true';
      } catch {
        if (current === request) lastGeometry = undefined;
      }
    }

    scheduleGlass = () => {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        void syncGlass();
      });
    };
    const routes = new MutationObserver(scheduleGlass);
    routes.observe(auth, {attributeFilter: ['hidden', 'data-page']});
    const layout = new ResizeObserver(scheduleGlass);
    for (const node of [scroll, get('welcome-invite'), join]) layout.observe(node);
    scroll.addEventListener('scroll', scheduleGlass, {passive: true});
    join.addEventListener('focus', scheduleGlass);
    join.addEventListener('blur', scheduleGlass);
    window.visualViewport?.addEventListener('resize', scheduleGlass);
    window.visualViewport?.addEventListener('scroll', scheduleGlass);
    scheduleGlass();
  }

  function init() {
    if (!scheduleGlass) initGlass();
  }

  window.Kaka.welcome = {init, updateGeometry};
})();
