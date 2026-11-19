(() => {
  const Kaka = window.Kaka;
  const {get, catalog, records, account} = Kaka;
  const screens = ['stage', 'room', 'creator', 'voice', 'notebook', 'crate'];
  const scrollPositions = new Map();
  let currentKey;
  let currentScreen;
  let initialized = false;
  let opening = false;
  let session;

  function refresh() {
    Kaka.stage.refresh();
    Kaka.cypher.refresh();
    Kaka.creators.refresh();
    Kaka.crate.refresh();
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
    const room = page === 'room' && !origin && catalog.room(id);
    const creator = page === 'creator' && !extra && ['stage', 'voice', 'crate'].includes(origin) && catalog.host(id);
    let next = ['stage', 'voice', 'notebook', 'crate'].includes(page) && !id ? page : 'stage';
    if (room && !records.isHidden(room.id)) next = 'room';
    if (creator) next = 'creator';
    let key = next;
    if (next === 'room') key += '/' + room.id;
    if (next === 'creator') key += '/' + creator.id + '/' + origin;
    if (raw !== key && raw !== '') {
      location.replace('#' + key);
      return;
    }

    const changed = currentKey !== key;
    if (changed && currentScreen) {
      scrollPositions.set(currentKey, get(currentScreen).scrollTop);
      if (currentScreen === 'voice') Kaka.cypher.stop();
      document.activeElement?.blur();
    }
    if (next === 'room') Kaka.stage.roomDetail(room);
    if (next === 'creator') Kaka.creators.creatorDetail(creator, origin);
    for (const screen of screens) get(screen).hidden = screen !== next;
    const tab = next === 'creator' ? origin : (next === 'room' ? 'stage' : next);
    get('app').dataset.tab = tab;
    document.querySelectorAll('[data-tab-link]').forEach((control) => {
      if (control.dataset.tabLink === tab) control.setAttribute('aria-current', 'page');
      else control.removeAttribute('aria-current');
    });
    currentKey = key;
    currentScreen = next;
    if (changed) {
      get(next).scrollTop = scrollPositions.get(key) ?? 0;
      if (moveFocus) get(next + '-title')?.focus({preventScroll: true});
    }
    if (next === 'notebook') Kaka.notebook.showResult();
    if (next === 'voice') Kaka.cypher.showPractice();
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
    get('toast').textContent = '';
  }

  function showOpeningError() {
    get('app').hidden = true;
    get('auth').hidden = true;
    get('boot').hidden = false;
    get('boot-message').textContent = 'Couldn’t open your workspace.';
    get('boot-retry').hidden = false;
  }

  async function changeSession(next, target) {
    try {
      if (next) await records.open(next);
      else records.close();
      if (next?.token !== session?.token) resetWorkspace();
      session = next;
      account.update(next);
      if (session) refresh();
      get('app').hidden = !session;
      get('auth').hidden = Boolean(session);
      get('boot').hidden = true;
      if (target) Kaka.go(target, true);
      else route(false);
    } catch {
      showOpeningError();
    }
  }

  async function start() {
    if (opening) return;
    opening = true;
    get('boot-retry').hidden = true;
    get('boot-message').textContent = 'Loading…';
    try {
      if (!initialized) {
        Kaka.welcome.init();
        Kaka.stage.init();
        Kaka.cypher.init();
        Kaka.notebook.init();
        Kaka.crate.init();
        account.init(changeSession);
        initialized = true;
        window.addEventListener('kaka:records', () => { if (session) refresh(); });
        window.addEventListener('hashchange', () => route());
      }
      await changeSession(await records.call('auth.session'));
      Kaka.viewport.update(await records.ready());
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
