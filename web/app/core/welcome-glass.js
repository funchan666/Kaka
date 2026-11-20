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
    const loading = get('login-loading');
    const decision = get('decision-overlay');
    const controls = {
      welcome: get('welcome-join'),
      login: get('login-form').querySelector('button[type="submit"]'),
      register: get('register-form').querySelector('button[type="submit"]'),
    };
    let lastControl;
    let lastGeometry;
    let lastFrame = null;
    let request = 0;
    let scheduled = false;

    function visibleFrame(snapshot, control) {
      const focus = document.activeElement;
      // Leave the original control visible whenever the viewport can move independently of UIKit.
      if (!snapshot?.welcomeGlass || !control || auth.hidden || document.hidden || !loading.hidden
        || !decision.hidden || control.disabled || focus === control
        || focus?.matches('input:not([type="checkbox"]), textarea')
        || scroll.scrollHeight > scroll.clientHeight + 1) return null;
      const viewport = window.visualViewport;
      if (viewport && (viewport.scale !== 1 || viewport.offsetLeft || viewport.offsetTop)) return null;
      const viewportWidth = viewport?.width ?? window.innerWidth;
      const viewportHeight = viewport?.height ?? window.innerHeight;
      if (Math.abs(viewportWidth - snapshot.width) > 1 || Math.abs(viewportHeight - snapshot.height) > 1) return null;
      const {x, y, width, height, right, bottom} = control.getBoundingClientRect();
      const visible = scroll.getBoundingClientRect();
      if (width < 44 || height < 44 || x < visible.left || y < visible.top
        || right > visible.right || bottom > visible.bottom) return null;
      return {x, y, width, height, viewportWidth, viewportHeight};
    }

    async function syncGlass(retry = false) {
      const page = auth.dataset.page;
      const control = controls[page];
      const snapshot = geometry;
      const frame = visibleFrame(snapshot, control);
      const key = frame && JSON.stringify({page, frame});
      if (!retry && snapshot === lastGeometry && key === lastFrame) return;
      const hadFrame = lastFrame !== null;
      lastGeometry = snapshot;
      lastFrame = key;
      const current = ++request;
      if (lastControl) delete lastControl.dataset.nativeGlass;
      lastControl = control;
      if (!snapshot?.welcomeGlass || (!frame && !hadFrame)) return;
      try {
        const shown = await records.call('auth.glass', {page, frame});
        if (shown === true && current === request && snapshot === geometry
          && page === auth.dataset.page && key === JSON.stringify({page, frame: visibleFrame(snapshot, control)})) {
          control.dataset.nativeGlass = 'true';
        } else if (shown === false && frame && !retry) {
          // A fragment update can reach WebKit after the DOM layout has settled.
          setTimeout(() => {
            if (current === request && snapshot === geometry) void syncGlass(true);
          }, 64);
        }
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
    routes.observe(loading, {attributeFilter: ['hidden']});
    routes.observe(decision, {attributeFilter: ['hidden']});
    const layout = new ResizeObserver(scheduleGlass);
    for (const node of [scroll, get('welcome-invite'), get('login'), get('register')]) layout.observe(node);
    for (const control of Object.values(controls)) {
      routes.observe(control, {attributeFilter: ['disabled']});
      layout.observe(control);
    }
    scroll.addEventListener('scroll', scheduleGlass, {passive: true});
    document.addEventListener('focusin', scheduleGlass);
    document.addEventListener('focusout', scheduleGlass);
    document.addEventListener('visibilitychange', scheduleGlass);
    window.visualViewport?.addEventListener('resize', scheduleGlass);
    window.visualViewport?.addEventListener('scroll', scheduleGlass);
    scheduleGlass();
  }

  function init() {
    if (!scheduleGlass) initGlass();
  }

  window.Kaka.welcome = {init, updateGeometry};
})();
