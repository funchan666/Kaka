(() => {
  const Kaka = window.Kaka;
  const {element, message, uuid} = Kaka;
  const views = new Map();
  let active;

  function request(visit, command, fields = {}) {
    const service = visit.kind === 'direct' ? 'directChat' : 'roomChat';
    return Kaka.service.request(service + '.' + command, {...visit.input, ...fields});
  }

  function render(visit, snapshot) {
    if (active !== visit) return;
    if (snapshot.revision < visit.revision) return;
    visit.connected = snapshot.connected === true;
    visit.canSend = visit.connected && snapshot.canSend !== false && !snapshot.blocked;
    visit.view.field.disabled = !visit.canSend;
    visit.view.send.disabled = !visit.canSend || visit.sending;
    if (snapshot.revision !== visit.revision) {
      visit.revision = snapshot.revision;
      const {rows} = visit.view;
      const follow = rows.scrollHeight - rows.scrollTop - rows.clientHeight < 24;
      const entries = (snapshot.messages ?? []).slice(-50);
      const retained = new Set(entries.map((entry) => entry.id));
      const existing = new Map(Array.from(rows.children, (row) => [row.dataset.message, row]));
      for (const [id, row] of existing) {
        if (!retained.has(id)) row.remove();
      }
      let cursor = rows.firstElementChild;
      for (const entry of entries) {
        const row = existing.get(entry.id) ?? element('p', 'room-chat-line');
        if (!row.dataset.message) {
          row.dataset.message = entry.id;
          row.append(element('strong', '', entry.own ? 'You' : entry.name), element('span', '', entry.text));
        }
        if (row !== cursor) rows.insertBefore(row, cursor);
        cursor = row.nextElementSibling;
      }
      if (follow) rows.scrollTop = rows.scrollHeight;
    }
    message(visit.view.status, visit.error || (!visit.connected ? 'Connecting to chat…' :
      !visit.canSend ? 'Messaging is unavailable for this conversation.' :
      visit.view.rows.childElementCount === 0 ? 'Start the conversation.' : ''));
  }

  function report(visit, error) {
    if (active === visit) message(visit.view.status, error.message);
  }

  function watch(visit) {
    if (active !== visit || document.hidden) return;
    clearTimeout(visit.poll);
    visit.poll = setTimeout(async () => {
      if (active !== visit || document.hidden) return;
      try {
        render(visit, await request(visit, 'snapshot'));
        watch(visit);
      } catch (error) {
        if (active !== visit) return;
        visit.failed = true;
        visit.connected = false;
        visit.view.field.disabled = true;
        visit.view.send.disabled = true;
        report(visit, error);
      }
    }, 2000);
  }

  function close() {
    const previous = active;
    if (!previous) return;
    active = undefined;
    clearTimeout(previous.poll);
    previous.view.root.hidden = true;
    request(previous, 'close').catch(() => {});
  }

  async function open(kind, identifier) {
    const serverID = String(identifier ?? '');
    if (!/^[1-9][0-9]{0,18}$/.test(serverID) || !views.has(kind)) return;
    if (active?.kind === kind && active.serverID === serverID && !active.failed) return;
    if (kind === 'direct' && !Number.isSafeInteger(Number(serverID))) return;
    close();
    const view = views.get(kind);
    const input = kind === 'direct' ? {userID: Number(serverID), visit: uuid()} : {kind, serverID, visit: uuid()};
    const visit = {view, kind, serverID, input, connected: false};
    active = visit;
    view.root.hidden = false;
    view.rows.replaceChildren();
    view.field.value = '';
    view.field.disabled = true;
    view.send.disabled = true;
    message(view.status, 'Connecting to chat…');
    try {
      render(visit, await request(visit, 'open'));
      watch(visit);
    } catch (error) {
      visit.failed = true;
      report(visit, error);
    }
  }

  for (const root of document.querySelectorAll('[data-room-chat]')) {
    const form = root.querySelector('form');
    const view = {
      root,
      field: form.elements.namedItem('text'),
      rows: root.querySelector('[data-room-chat-rows]'),
      status: root.querySelector('[data-room-chat-status]'),
      send: form.querySelector('[type="submit"]'),
    };
    views.set(root.dataset.roomChat, view);
    view.field.addEventListener('input', () => {
      if (active?.view === view) active.error = undefined;
    });
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const visit = active;
      const draft = view.field.value;
      const text = draft.trim();
      if (visit?.view !== view || !visit.canSend || visit.sending || !text) return;
      visit.sending = true;
      visit.error = undefined;
      view.send.disabled = true;
      try {
        const snapshot = await request(visit, 'send', {text});
        if (active !== visit) return;
        if (view.field.value === draft) view.field.value = '';
        render(visit, snapshot);
      } catch (error) {
        visit.error = error.message;
        report(visit, error);
      } finally {
        visit.sending = false;
        if (active === visit) view.send.disabled = !visit.canSend;
      }
    });
  }

  window.addEventListener('kaka:room-media', (event) => {
    const {kind, roomID, joined} = event.detail;
    if (joined) open(kind, roomID);
    else if (active?.kind === kind && active.serverID === String(roomID)) close();
  });
  window.addEventListener('kaka:pause', close);
  window.addEventListener('kaka:session-expired', close);
  document.addEventListener('visibilitychange', () => { if (active && !active.failed) watch(active); });
  Kaka.roomChat = {open, close};
})();
