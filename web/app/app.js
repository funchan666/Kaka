(() => {
  const Kaka = window.Kaka;
  const {get, catalog, records, account} = Kaka;
  const screens = ['stage', 'room', 'creator', 'voice', 'voice-room', 'notebook', 'crate'];
  const scrollPositions = new Map();
  let currentKey;
  let currentScreen;
  let initialized = false;
  let opening = false;
  let session;
  let sessionRevision = 0;

  function scrollArea(screen) {
    return screen === 'notebook' ? get('verse-thread') : get(screen);
  }

  function refresh() {
    Kaka.stage.refresh();
    Kaka.cypher.refresh();
    Kaka.creators.refresh();
    Kaka.crate.refresh();
    Kaka.notebook.refreshPrompts();
  }

  function route(moveFocus = true) {
    if (!get('boot').hidden) return;
    const raw = location.hash.slice(1);
    if (!session) {
      const page = account.pages.includes(raw) ? raw : 'welcome';
      if (raw && raw !== page) location.replace('#' + page);
      else account.show(page, moveFocus);
      return;
    }
    const [page, id, origin, extra] = raw.split('/');
    const selectedRoom = id && catalog.room(id);
    const room = page === 'room' && !origin && selectedRoom?.kind === 'live' && selectedRoom;
    const rehearsal = page === 'voice' && !origin && selectedRoom?.kind === 'voice' && selectedRoom;
    const creator = page === 'creator' && !extra && ['stage', 'voice', 'crate'].includes(origin) && catalog.host(id);
    let next = ['stage', 'notebook', 'crate'].includes(page) && !id ? page : 'stage';
    if (room && !records.isHidden(room.id)) next = 'room';
    if (page === 'voice') next = rehearsal && !records.isHidden(rehearsal.id) ? 'voice-room' : 'voice';
    if (creator) next = 'creator';
    let key = next;
    if (next === 'room') key += '/' + room.id;
    if (next === 'voice-room') key = 'voice/' + rehearsal.id;
    if (next === 'creator') key += '/' + creator.id + '/' + origin;
    if (raw !== key && raw !== '') {
      location.replace('#' + key);
      return;
    }

    const changed = currentKey !== key;
    if (changed && currentScreen) {
      scrollPositions.set(currentKey, scrollArea(currentScreen).scrollTop);
      if (['room', 'voice-room', 'creator'].includes(currentScreen)) Kaka.roomChat.close();
      if (currentScreen === 'voice-room') Kaka.cypher.stop();
      if (currentScreen === 'room') Kaka.stage.stopPreview();
      document.activeElement?.blur();
    }
    if (next === 'room') Kaka.stage.roomDetail(room);
    if (next === 'voice-room') Kaka.cypher.openRoom(rehearsal);
    if (next === 'creator') Kaka.creators.creatorDetail(creator, origin);
    for (const screen of screens) get(screen).hidden = screen !== next;
    let tab = next;
    if (next === 'creator') tab = origin;
    if (next === 'room') tab = 'stage';
    if (next === 'voice-room') tab = 'voice';
    get('app').dataset.tab = tab;
    document.querySelectorAll('[data-tab-link]').forEach((control) => {
      if (control.dataset.tabLink === tab) control.setAttribute('aria-current', 'page');
      else control.removeAttribute('aria-current');
    });
    currentKey = key;
    currentScreen = next;
    if (changed) {
      scrollArea(next).scrollTop = scrollPositions.get(key) ?? 0;
      if (moveFocus) get(next + '-title')?.focus({preventScroll: true});
    }
    if (next === 'notebook') Kaka.notebook.showResult();
  }

  Kaka.go = (target, replace = false) => {
    const hash = '#' + target;
    if (location.hash === hash) route();
    else if (replace) location.replace(hash);
    else location.hash = hash;
  };

  function resetWorkspace() {
    scrollPositions.clear();
    currentKey = undefined;
    currentScreen = undefined;
    Kaka.stage.reset();
    Kaka.cypher.reset();
    Kaka.creators.reset();
    Kaka.notebook.reset();
    Kaka.crate.reset();
    Kaka.commerce.reset();
    catalog.clear();
    get('toast').textContent = '';
  }

  function showOpeningError() {
    get('app').hidden = true;
    get('auth').hidden = true;
    get('boot').dataset.error = 'true';
    get('boot').hidden = false;
    get('boot-message').textContent = 'Couldn’t open your workspace.';
    get('boot-retry').hidden = false;
  }

  async function changeSession(next, target) {
    const revision = ++sessionRevision;
    try {
      if (next) await records.open(next);
      else records.close();
      if (revision !== sessionRevision) return;
      if (next?.token !== session?.token) resetWorkspace();
      session = next;
      Kaka.service.setSession(next);
      account.update(next);
      if (session) {
        const connection = get('service-status');
        connection.textContent = 'Connecting…';
        await Promise.all([catalog.load(next), Kaka.crate.loadProfile()]);
        if (revision !== sessionRevision) return;
        const unavailable = catalog.status('live').error && catalog.status('voice').error;
        connection.textContent = unavailable ? 'Rooms unavailable' : 'Online';
        refresh();
      }
      get('app').hidden = !session;
      get('auth').hidden = Boolean(session);
      get('boot').hidden = true;
      if (target) Kaka.go(target, true);
      else route(false);
    } catch {
      if (revision === sessionRevision) showOpeningError();
    }
  }

  async function start() {
    if (opening) return;
    opening = true;
    delete get('boot').dataset.error;
    get('boot-retry').hidden = true;
    get('boot-message').textContent = 'Loading…';
    try {
      if (!initialized) {
        Kaka.welcome.init();
        Kaka.stage.init();
        Kaka.cypher.init();
        Kaka.notebook.init();
        Kaka.crate.init();
        Kaka.commerce.init();
        account.init(changeSession);
        initialized = true;
        window.addEventListener('kaka:records', () => { if (session) refresh(); });
        window.addEventListener('kaka:catalog', () => { if (session) refresh(); });
        window.addEventListener('kaka:session-expired', () => {
          void changeSession(null, 'login');
          Kaka.message(get('login-error'), 'Your session ended. Please log in again.');
        });
        window.addEventListener('hashchange', () => route());
      }
      Kaka.viewport.update(await records.ready());
      await changeSession(await records.call('auth.session'));
    } catch {
      showOpeningError();
      records.ready().then(Kaka.viewport.update).catch(() => {});
    } finally {
      opening = false;
    }
  }

  get('boot-retry').addEventListener('click', start);
  start();
})();
