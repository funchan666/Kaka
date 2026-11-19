(() => {
  const Kaka = window.Kaka;
  const {get, element, link, image, button, pending, notify, catalog, records} = Kaka;
  const returnRoutes = {stage: 'Back to Live Rooms', voice: 'Back to Voice Rooms', crate: 'Back to Profile'};
  let activeKey;
  let activeHost;

  function portrait(host, className = 'host-avatar') {
    return image(host.portrait, className);
  }

  function hostLink(host, source, label = 'Host') {
    const entry = link('', 'creator/' + host.id + '/' + source, 'host-link');
    const details = element('span', 'host-label');
    details.append(element('strong', '', host.name), element('span', 'caption', label));
    entry.append(portrait(host), details);
    entry.setAttribute('aria-label', 'View ' + host.name);
    return entry;
  }

  function updateFollow() {
    const control = get('creator-follow');
    if (!control || !activeHost) return;
    const following = records.current().following.includes(activeHost.id);
    control.textContent = following ? 'Unfollow' : 'Follow';
    control.setAttribute('aria-pressed', String(following));
  }

  function creatorDetail(host, origin) {
    const key = host.id + '/' + origin;
    if (key === activeKey) {
      updateFollow();
      updatePrograms(host);
      return;
    }
    activeKey = key;
    activeHost = host;
    const root = get('creator-detail');
    const back = link(returnRoutes[origin], origin, 'button quiet room-back');
    const card = element('div', 'creator-head');
    const profile = element('div', 'creator-identity');
    const title = element('h1', '', host.name);
    title.id = 'creator-title';
    title.tabIndex = -1;
    profile.append(title, element('p', 'caption', host.style));
    card.append(portrait(host, 'creator-portrait'), profile);

    const follow = button('Follow', () => pending(follow, async () => {
      await records.update((state) => {
        const current = state.following.indexOf(host.id);
        if (current >= 0) state.following.splice(current, 1);
        else state.following.push(host.id);
      });
      notify(records.current().following.includes(host.id) ? 'Added to Following.' : 'Removed from Following.');
    }), 'button primary');
    follow.id = 'creator-follow';
    const intro = element('p', 'room-summary', host.bio);
    const programs = element('div');
    programs.id = 'creator-programs';
    const programHeading = element('h2', 'section-title', 'Hosted rooms');
    root.replaceChildren(back, card, intro, follow, programHeading, programs);
    programHeading.classList.add('program-heading');
    updateFollow();
    updatePrograms(host);
  }

  function updatePrograms(host) {
    const programs = get('creator-programs');
    if (!programs) return;
    const rooms = catalog.rooms().filter((room) => room.host === host.id && !records.isHidden(room.id));
    programs.replaceChildren(...rooms.map((room) => Kaka.stage.track(room, link('', 'room/' + room.id, 'track'), false)));
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

  Kaka.creators = {portrait, hostLink, creatorDetail, refresh, reset};
})();
