(() => {
  const Kaka = window.Kaka;
  const {get, element, button, link, image, actionIcon, message, notify, pending, confirm, records, catalog, lyrics, service} = Kaka;
  let profile;
  let profileRevision = 0;
  let supportReady = false;
  let supportLoading = false;

  async function loadProfile() {
    const revision = profileRevision;
    message(get('profile-status'));
    try {
      const value = await service.request('profile.read');
      if (revision !== profileRevision) return;
      const name = typeof value?.nickname === 'string' ? value.nickname.trim() : '';
      const bio = typeof value?.cipherSeal === 'string' ? value.cipherSeal : '';
      profile = {name: name || records.current().profile.name, bio, portrait: catalog.mediaURL(value?.cometGlyph)};
    } catch (error) {
      if (revision === profileRevision) message(get('profile-status'), error.message);
    }
  }

  async function loadSupport() {
    if (supportLoading) return;
    supportLoading = true;
    const revision = profileRevision;
    const retry = get('support-retry');
    const status = get('support-status');
    const questions = get('support-questions');
    message(status, 'Loading help topics…');
    retry.hidden = true;
    try {
      const value = await service.request('support.faq');
      if (revision !== profileRevision) return;
      const rows = [value, value?.gridBands, value?.records, value?.roster, value?.data].find(Array.isArray) ?? [];
      const entries = rows.filter((row) => typeof row?.anomalyHeader === 'string' && typeof row?.signalResponse === 'string');
      questions.replaceChildren(...entries.map((row) => {
        const item = element('details', 'section-disclosure');
        item.append(element('summary', 'disclosure-summary', row.anomalyHeader), element('p', 'caption', row.signalResponse));
        return item;
      }));
      message(status, entries.length ? '' : 'No help topics are available right now.');
      supportReady = true;
    } catch (error) {
      if (revision !== profileRevision) return;
      message(status, error.message);
      retry.hidden = false;
    } finally {
      if (revision === profileRevision) supportLoading = false;
    }
  }

  function collectionEntry(title, route) {
    const entry = link(title, route, 'collection-entry');
    entry.append(image('action-forward.png', 'action-icon'));
    return entry;
  }

  function renderScores(scores) {
    const list = get('crate-scores');
    list.replaceChildren();
    if (scores.length === 0) {
      list.append(collectionEntry('Write a verse', 'notebook'));
      return;
    }
    const ordered = scores.slice().sort((a, b) => b.updatedAt - a.updatedAt);
    ordered.forEach((score) => {
      const row = element('div', 'crate-list-row');
      const open = button('', () => Kaka.notebook.openSaved(score.id), 'track');
      const copy = element('span', 'track-copy');
      copy.append(
        element('strong', '', score.topic),
        element('span', 'caption', lyrics.styles[score.style].label + ' · ' + score.bpm + ' BPM · ' + score.bars.length + ' bars'),
      );
      open.append(copy);
      const remove = button('', () => pending(remove, async () => {
        const approved = await confirm({
          title: 'Delete this draft?',
          description: 'This will permanently remove “' + score.topic + '” from your drafts.',
          label: 'Delete draft',
        });
        if (!approved) return;
        await records.update((state) => { state.scores = state.scores.filter((item) => item.id !== score.id); });
        Kaka.notebook.onDeleted(score.id);
        get('crate-scores-title').focus({preventScroll: true});
        notify('Draft deleted.');
      }), 'button quiet danger');
      actionIcon(remove, 'action-delete.png', 'Delete draft ' + score.topic);
      row.append(open, remove);
      list.append(row);
    });
  }

  function renderRooms(state) {
    const list = get('crate-rooms');
    const hidden = get('crate-hidden');
    list.replaceChildren();
    hidden.replaceChildren();
    const saved = new Set([...state.favorites, ...state.notes.map((note) => note.roomID)]);
    for (const id of saved) {
      const room = catalog.room(id);
      if (!room || records.isHidden(id)) continue;
      const route = room.kind === 'voice' ? 'voice/' : 'room/';
      const line = Kaka.stage.track(room, link('', route + id, 'track'));
      const note = state.notes.find((item) => item.roomID === id);
      if (note) line.querySelector('.track-copy').append(element('span', 'caption', note.text));
      list.append(line);
    }
    const roomCount = list.childElementCount;
    if (roomCount === 0) list.append(collectionEntry('Find a room', 'stage'));

    for (const report of state.reports) {
      const room = catalog.room(report.roomID);
      const row = element('div', 'crate-list-row');
      row.append(element('p', 'track', room?.title ?? 'Unavailable room'));
      const restore = button('Restore', () => pending(restore, async () => {
        await records.update((data) => { data.reports = data.reports.filter((item) => item.roomID !== report.roomID); });
        get('crate-rooms-title').focus({preventScroll: true});
        notify('Room restored.');
      }), 'button quiet');
      restore.setAttribute('aria-label', 'Restore ' + (room?.title ?? 'room'));
      row.append(restore);
      hidden.append(row);
    }
    get('hidden-rooms').hidden = hidden.childElementCount === 0;
    return roomCount;
  }

  function refresh() {
    const state = records.current();
    get('artist-name').textContent = profile?.name ?? state.profile.name;
    const portrait = get('artist-portrait');
    portrait.referrerPolicy = 'no-referrer';
    const portraitURL = profile?.portrait || 'assets/images/member-mark.jpg';
    if (portrait.getAttribute('src') !== portraitURL) portrait.src = portraitURL;
    message(get('artist-bio'), profile?.bio ?? state.profile.bio);
    message(get('artist-style'), state.profile.style);
    renderScores(state.scores);
    const roomCount = renderRooms(state);
    message(get('crate-scores-count'), state.scores.length ? String(state.scores.length) : '');
    message(get('crate-rooms-count'), roomCount ? String(roomCount) : '');
    get('crate-library').dataset.compact = String(state.scores.length === 0 && roomCount === 0);
    const hosts = catalog.following();
    const people = hosts.length ? hosts : catalog.hosts().slice(0, 6);
    get('crate-people').hidden = people.length === 0;
    get('crate-creators-title').textContent = hosts.length ? 'Following' : 'Meet the hosts';
    get('crate-creators').replaceChildren(...people.map((host) => Kaka.creators.tile(host, 'crate')));
  }

  function init() {
    const form = get('artist-form');
    const edit = get('artist-edit');
    const error = get('artist-error');
    const submit = form.querySelector('button[type="submit"]');
    get('support-panel').addEventListener('toggle', (event) => {
      if (event.currentTarget.open && !supportReady) void loadSupport();
    });
    get('support-retry').addEventListener('click', loadSupport);
    get('artist-portrait').addEventListener('error', (event) => {
      const image = event.currentTarget;
      if (!image.src.startsWith('https://')) return;
      if (profile?.portrait === image.src) profile.portrait = '';
      image.src = 'assets/images/member-mark.jpg';
    });
    get('artist-photo').addEventListener('click', (event) => {
      const control = event.currentTarget;
      const revision = profileRevision;
      message(error);
      void pending(control, async () => {
        const response = await service.request('profile.avatar');
        if (revision !== profileRevision || !response) return;
        const portrait = catalog.mediaURL(response.portrait);
        if (!portrait) throw new Error('Couldn’t update the profile photo.');
        profile = {...profile, portrait};
        refresh();
        notify('Profile photo updated.');
      }, (failure) => {
        if (revision === profileRevision) message(error, failure.message);
      });
    });
    for (const id of ['crate-scores-title', 'crate-rooms-title']) get(id).tabIndex = -1;
    edit.setAttribute('aria-expanded', 'false');

    function close() {
      form.hidden = true;
      edit.setAttribute('aria-expanded', 'false');
      edit.focus({preventScroll: true});
    }

    edit.addEventListener('click', () => {
      if (!form.hidden) {
        close();
        return;
      }
      const saved = records.current().profile;
      form.elements.namedItem('name').value = profile?.name ?? saved.name;
      form.elements.namedItem('style').value = saved.style;
      form.elements.namedItem('bio').value = profile?.bio ?? saved.bio;
      message(error);
      form.hidden = false;
      edit.setAttribute('aria-expanded', 'true');
      form.elements.namedItem('name').focus();
    });

    get('artist-cancel').addEventListener('click', close);

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const fields = new FormData(form);
      const name = String(fields.get('name') ?? '').trim();
      if (!name) {
        message(error, 'Enter a stage name.');
        form.elements.namedItem('name').focus();
        return;
      }
      const changes = {
        name,
        style: String(fields.get('style') ?? '').trim(),
        bio: String(fields.get('bio') ?? '').trim(),
      };
      if (changes.bio.length > 120) {
        message(error, 'Use up to 120 characters for your bio.');
        form.elements.namedItem('bio').focus();
        return;
      }
      message(error);
      document.activeElement?.blur();
      const revision = profileRevision;
      pending(submit, async () => {
        await service.request('profile.update', {nickname: changes.name, cipherSeal: changes.bio});
        if (revision !== profileRevision) return;
        profile = {...profile, name: changes.name, bio: changes.bio};
        refresh();
        await records.update((state) => { state.profile = changes; });
        if (revision !== profileRevision) return;
        message(get('profile-status'));
        close();
        notify('Profile saved.');
      }, (failure) => message(error, failure.message));
    });
  }

  function reset() {
    profile = undefined;
    profileRevision += 1;
    supportReady = false;
    supportLoading = false;
    get('support-panel').open = false;
    get('support-questions').replaceChildren();
    get('support-retry').hidden = true;
    message(get('support-status'));
    message(get('profile-status'));
    const form = get('artist-form');
    form.reset();
    form.hidden = true;
    get('profile-account').open = false;
    get('artist-edit').setAttribute('aria-expanded', 'false');
    get('crate-people').hidden = true;
    delete get('crate-library').dataset.compact;
    for (const id of ['artist-name', 'crate-scores', 'crate-rooms', 'crate-creators', 'crate-hidden']) {
      get(id).replaceChildren();
    }
    for (const id of ['artist-bio', 'artist-style', 'artist-error', 'crate-scores-count', 'crate-rooms-count']) message(get(id));
  }

  Kaka.crate = {init, refresh, reset, loadProfile};
})();
