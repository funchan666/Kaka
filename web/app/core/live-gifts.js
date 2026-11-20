(() => {
  const Kaka = window.Kaka;
  const {element, image, button, confirm, message} = Kaka;
  let shelf;

  function available(view) {
    return shelf === view && view.root.isConnected && view.root.open &&
      location.hash === '#room/' + view.roomID && !document.hidden;
  }

  function clear() {
    shelf?.root.remove();
    shelf = undefined;
  }

  function showBalance(view, balance) {
    message(view.balance, typeof balance === 'string' ? balance + ' diamonds available' : '');
  }

  function updateControls(view) {
    view.refresh.disabled = view.loading || view.sending;
    view.list.querySelectorAll('button').forEach((control) => {
      control.disabled = view.loading || view.sending || control.dataset.available !== 'true';
    });
  }

  function render(view, catalog) {
    view.host = catalog.host;
    showBalance(view, catalog.balance);
    const gifts = Array.isArray(catalog.gifts) ? catalog.gifts : [];
    if (!gifts.length) {
      view.list.replaceChildren(element('p', 'caption', 'No gifts are available in this room.'));
      return;
    }
    view.list.replaceChildren(...gifts.map((gift) => {
      const item = element('div', 'crate-list-row');
      const picture = Kaka.catalog.mediaURL(gift.image);
      if (picture) {
        const art = element('img', 'host-avatar');
        art.src = picture;
        art.alt = '';
        art.loading = 'lazy';
        art.referrerPolicy = 'no-referrer';
        item.append(art);
      }
      const name = element('div', 'track-copy');
      name.append(element('strong', '', gift.name), element('span', 'caption', gift.cost + ' diamonds'));
      const accept = button('Give', () => send(view, gift));
      accept.setAttribute('aria-label', 'Give ' + gift.name + ' for ' + gift.cost + ' diamonds');
      accept.dataset.available = String(gift.available);
      item.append(name, accept);
      return item;
    }));
  }

  async function load(view) {
    if (!available(view) || view.loading || view.sending) return;
    view.loading = true;
    view.list.replaceChildren();
    showBalance(view);
    message(view.feedback, 'Loading gifts…');
    updateControls(view);
    try {
      const response = await Kaka.service.request('gift.catalog', {roomID: view.roomID});
      if (!available(view)) return;
      render(view, response);
      message(view.feedback);
    } catch (error) {
      if (available(view)) message(view.feedback, error?.message || 'Couldn’t load gifts.');
    } finally {
      view.loading = false;
      updateControls(view);
    }
  }

  async function send(view, gift) {
    if (!available(view) || view.loading || view.sending || !gift.available) return;
    view.sending = true;
    updateControls(view);
    try {
      const agreed = await confirm({
        title: 'Send a gift?',
        description: 'Send one ' + gift.name + ' to ' + view.host + ' for ' + gift.cost + ' diamonds.',
        label: 'Send gift',
      });
      if (!agreed || !available(view)) return;

      view.list.replaceChildren();
      message(view.feedback, 'Sending gift…');
      const result = await Kaka.service.request('gift.send', {roomID: view.roomID, giftID: gift.id});
      if (!available(view)) return;
      showBalance(view, result.balance);
      const messages = {
        sent: 'Gift sent.',
        declined: 'The gift wasn’t sent.',
        uncertain: 'Delivery couldn’t be confirmed. Check your balance before sending again.',
      };
      message(view.feedback, messages[result.status] ?? messages.uncertain);
    } catch (error) {
      if (available(view)) message(view.feedback, error?.message || 'Delivery couldn’t be confirmed. Check your balance before sending again.');
    } finally {
      view.sending = false;
      updateControls(view);
    }
  }

  function mount(roomID) {
    if (shelf?.roomID === roomID && shelf.root.isConnected) return;
    clear();
    const tools = document.querySelector('#room .room-tools');
    if (!tools || location.hash !== '#room/' + roomID) return;
    const root = element('details', 'section-disclosure room-note');
    const toggle = element('summary', 'disclosure-summary');
    toggle.append(element('span', '', 'Gifts'), image('action-forward.png', 'action-icon'));
    const body = element('div', 'account-card profile-glass');
    const balance = element('p', 'caption');
    const feedback = element('p', 'caption');
    const list = element('div');
    const view = {root, roomID, balance, feedback, list};
    feedback.setAttribute('role', 'status');
    view.refresh = button('Refresh gifts', () => load(view), 'button quiet');
    body.append(balance, list, feedback, view.refresh);
    root.append(toggle, body);
    root.addEventListener('toggle', () => { if (root.open) load(view); });
    tools.after(root);
    shelf = view;
  }

  window.addEventListener('kaka:room-media', (event) => {
    const {kind, roomID, joined} = event.detail ?? {};
    if (kind !== 'live') return;
    const id = String(roomID);
    if (!/^[1-9][0-9]{0,18}$/.test(id)) return;
    if (joined) mount(id);
    else if (shelf?.roomID === id) clear();
  });
  window.addEventListener('hashchange', () => {
    if (shelf && location.hash !== '#room/' + shelf.roomID) clear();
  });
  window.addEventListener('kaka:suspend', clear);
  window.addEventListener('kaka:session-expired', clear);
})();
