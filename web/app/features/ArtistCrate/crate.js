(() => {
  const Kaka = window.Kaka;
  const {get, element, button, link, message, notify, pending, confirm, records, catalog, lyrics} = Kaka;

  function renderScores(scores) {
    const list = get('crate-scores');
    list.replaceChildren();
    if (scores.length === 0) {
      const empty = element('p', 'empty', 'Save a verse from Verse Lab to find it here.');
      list.append(empty, link('Write a verse', 'notebook'));
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
      const remove = button('Delete', () => pending(remove, async () => {
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
      }), 'button quiet');
      remove.setAttribute('aria-label', 'Delete draft ' + score.topic);
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
      const line = Kaka.stage.track(room, link('', 'room/' + id, 'track'));
      const note = state.notes.find((item) => item.roomID === id);
      if (note) line.querySelector('.track-copy').append(element('span', 'caption', note.text));
      list.append(line);
    }
    if (!list.childElementCount) {
      list.append(element('p', 'empty', 'Save a room or write a rehearsal note to find it here.'), link('Browse rooms', 'stage'));
    }

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
  }

  function refresh() {
    const state = records.current();
    get('artist-name').textContent = state.profile.name;
    message(get('artist-bio'), state.profile.bio);
    message(get('artist-style'), state.profile.style);
    renderScores(state.scores);
    renderRooms(state);
    const hosts = state.following.map((id) => catalog.host(id)).filter(Boolean);
    const list = get('crate-creators');
    list.replaceChildren(...hosts.map((host) => Kaka.creators.hostLink(host, 'crate', 'Host')));
    if (hosts.length === 0) {
      list.append(element('p', 'empty', 'Tap a host in Live Rooms to follow their sessions.'));
    }
  }

  function init() {
    const form = get('artist-form');
    const edit = get('artist-edit');
    const error = get('artist-error');
    const submit = form.querySelector('button[type="submit"]');
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
      const {profile} = records.current();
      form.elements.namedItem('name').value = profile.name;
      form.elements.namedItem('style').value = profile.style;
      form.elements.namedItem('bio').value = profile.bio;
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
      const profile = {
        name,
        style: String(fields.get('style') ?? '').trim(),
        bio: String(fields.get('bio') ?? '').trim(),
      };
      message(error);
      document.activeElement?.blur();
      pending(submit, async () => {
        await records.update((state) => { state.profile = profile; });
        close();
        notify('Profile saved.');
      }, (failure) => message(error, failure.message));
    });
  }

  function reset() {
    const form = get('artist-form');
    form.reset();
    form.hidden = true;
    get('artist-edit').setAttribute('aria-expanded', 'false');
    for (const id of ['artist-name', 'crate-scores', 'crate-rooms', 'crate-creators', 'crate-hidden']) {
      get(id).replaceChildren();
    }
    for (const id of ['artist-bio', 'artist-style', 'artist-error']) message(get(id));
  }

  Kaka.crate = {init, refresh, reset};
})();
