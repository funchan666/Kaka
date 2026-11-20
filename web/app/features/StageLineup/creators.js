(() => {
  const Kaka = window.Kaka;
  const {get, element, link, button, actionIcon, pending, notify, message, catalog, records, service} = Kaka;
  const returnRoutes = {stage: 'Back to Live Rooms', voice: 'Back to Voice Rooms', crate: 'Back to Profile'};
  let activeKey;
  let activeHost;

  function portrait(host, className = 'host-avatar') {
    return catalog.image(host.portrait, className, 'member-mark.jpg');
  }

  function hostLink(host, source, label = 'Host') {
    const entry = link('', 'creator/' + host.id + '/' + source, 'host-link');
    const details = element('span', 'host-label');
    details.append(element('strong', '', host.name), element('span', 'caption', label));
    entry.append(portrait(host), details);
    entry.setAttribute('aria-label', 'View ' + host.name);
    return entry;
  }

  function tile(host, source) {
    const entry = link('', 'creator/' + host.id + '/' + source, 'host-tile');
    const following = catalog.follows(host.id);
    entry.dataset.following = String(following);
    entry.setAttribute('aria-label', 'View ' + host.name + (following ? ', following' : ''));
    entry.append(portrait(host, 'host-tile-portrait'), element('strong', '', host.name));
    return entry;
  }

  function updateFollow() {
    const control = get('creator-follow');
    if (!control || !activeHost) return;
    const following = catalog.follows(activeHost.id);
    control.textContent = following ? 'Unfollow' : 'Follow';
    control.setAttribute('aria-pressed', String(following));
  }

  function creatorDetail(host, origin) {
    const destination = origin === 'voice' ? Kaka.cypher.resumeRoute() : origin;
    const key = host.id + '/' + destination;
    if (key === activeKey) {
      updateFollow();
      updatePrograms(host);
      return;
    }
    activeKey = key;
    activeHost = host;
    const root = get('creator-detail');
    const backLabel = destination === origin ? returnRoutes[origin] : 'Back to rehearsal';
    const back = actionIcon(link('', destination, 'button quiet room-back'), 'action-forward.png', backLabel);
    const card = element('header', 'scene creator-scene');
    const profile = element('div', 'creator-identity');
    const title = element('h1', '', host.name);
    title.id = 'creator-title';
    title.tabIndex = -1;
    const style = element('p', 'caption');
    message(style, host.style);
    profile.append(title, style);

    const follow = button('Follow', () => pending(follow, async () => {
      const following = await catalog.toggleFollow(host);
      if (!follow.isConnected || following === undefined) return;
      notify(following ? 'Added to Following.' : 'Removed from Following.');
    }), 'button primary');
    follow.id = 'creator-follow';
    const identity = element('div', 'scene-heading');
    identity.append(profile, follow);
    const artwork = portrait(host, 'scene-art');
    card.append(artwork, back, identity);
    const intro = element('p', 'room-summary');
    message(intro, host.bio);
    const feedback = element('p', 'field-error');
    feedback.setAttribute('role', 'status');
    feedback.hidden = true;
    const retry = button('Try again', loadProfile, 'button secondary');
    retry.hidden = true;
    let blocked;
    const block = button('Block', () => pending(block, async () => {
      if (blocked === undefined) {
        await loadBlockStatus();
        return;
      }
      const next = !blocked;
      if (next && !await Kaka.confirm({
        title: 'Block ' + activeHost.name + '?',
        description: 'Their messages will be hidden in room chat.',
        label: 'Block user',
      })) return;
      await service.request('creator.block', {userID: host.serverID, blocked: next});
      if (!block.isConnected) return;
      applyBlocked(next);
      notify(next ? 'User blocked.' : 'User unblocked.');
    }), 'button secondary');
    block.hidden = true;
    const chat = button('Message', () => {
      const view = get('creator').querySelector('[data-room-chat="direct"]');
      if (!view.hidden) {
        Kaka.roomChat.close();
      } else {
        void Kaka.roomChat.open('direct', host.serverID);
        view.scrollIntoView({block: 'nearest'});
      }
    }, 'button secondary');
    const actions = element('div', 'button-row');
    actions.append(chat, block);
    const programs = element('div');
    programs.id = 'creator-programs';
    const programHeading = element('h2', 'section-title', 'Hosted rooms');
    root.replaceChildren(card, intro, feedback, retry, actions, programHeading, programs);
    programHeading.classList.add('program-heading');
    updateFollow();
    updatePrograms(host);
    loadProfile();
    loadBlockStatus();

    function applyBlocked(value) {
      blocked = value;
      block.textContent = value ? 'Unblock' : 'Block';
      block.setAttribute('aria-pressed', String(value));
      follow.hidden = value;
      chat.hidden = value;
      if (value) Kaka.roomChat.close();
    }

    async function loadBlockStatus() {
      try {
        const value = await service.request('creator.blocked', {userID: host.serverID});
        if (!block.isConnected || typeof value !== 'boolean') return;
        applyBlocked(value);
        block.hidden = false;
      } catch {
        if (!block.isConnected) return;
        block.textContent = 'Retry block settings';
        block.hidden = false;
      }
    }

    async function loadProfile() {
      retry.hidden = true;
      message(feedback);
      try {
        const current = await catalog.refreshHost(host);
        if (!current || !card.isConnected) return;
        activeHost = current;
        title.textContent = current.name;
        message(intro, current.bio);
        message(style, current.style);
        if (current.portrait !== host.portrait) artwork.replaceWith(portrait(current, 'scene-art'));
      } catch (error) {
        if (!card.isConnected) return;
        message(feedback, error?.message || 'Host profile could not load.');
        retry.hidden = false;
      }
    }
  }

  function updatePrograms(host) {
    const programs = get('creator-programs');
    if (!programs) return;
    const rooms = catalog.rooms().filter((room) => room.host === host.id && !records.isHidden(room.id));
    programs.replaceChildren(...rooms.map((room) =>
      Kaka.stage.track(room, link('', (room.kind === 'voice' ? 'voice/' : 'room/') + room.id, 'track'), false)));
    if (rooms.length === 0) programs.append(element('p', 'empty', 'No rooms to show.'));
  }

  function refresh() {
    if (!activeHost) return;
    updateFollow();
    updatePrograms(activeHost);
  }

  function reset() {
    activeHost = undefined;
    activeKey = undefined;
    get('creator-detail').replaceChildren();
  }

  Kaka.creators = {portrait, hostLink, tile, creatorDetail, refresh, reset};
})();
