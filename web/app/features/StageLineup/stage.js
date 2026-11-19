(() => {
  const Kaka = window.Kaka;
  const {get, element, button, link, image, notify, message, pending, catalog, records} = Kaka;
  let filter = 'all';
  let detailID;
  const noteBuffer = new Map();

  function track(room, control, showHost = true) {
    control.classList.add('track');
    const host = showHost && catalog.host(room.host);
    const identity = element('span', 'track-identity');
    const copy = element('span', 'track-copy');
    copy.append(element('strong', '', room.title), element('span', 'caption', host ? host.name + ' · ' + room.format : room.format));
    if (host) identity.append(Kaka.creators.portrait(host, 'track-avatar'));
    identity.append(copy);
    control.append(identity, element('span', 'track-bpm', room.bpm + ' BPM'));
    return control;
  }

  function renderLineup() {
    const rooms = catalog.rooms().filter((room) =>
      !records.isHidden(room.id) && (filter === 'all' || room.genre === filter));
    const root = get('stage-lineup');
    root.replaceChildren();
    get('stage-more').hidden = true;
    get('stage-hosts').hidden = true;
    if (rooms.length === 0) {
      root.hidden = false;
      root.append(element('p', 'empty', 'No rooms in this category.'));
      return;
    }
    const hero = rooms.find((room) => room.cover);
    root.hidden = !hero;
    if (hero) {
      const poster = element('article', 'feature');
      const title = element('div');
      title.append(element('h2', '', hero.title));
      const host = catalog.host(hero.host);
      if (host) title.append(Kaka.creators.hostLink(host, 'stage', hero.format));
      const info = element('div', 'feature-text');
      info.append(title, link('View room', 'room/' + hero.id, 'button primary'));
      poster.append(
        image(hero.cover, 'feature-image', 'Two emcees trading bars on a basement stage'),
        element('span', 'tempo-badge', hero.bpm + ' BPM'),
        info,
      );
      root.append(poster);
    }
    const hosts = Array.from(new Set(rooms.map((room) => room.host))).map(catalog.host);
    if (hosts.length && filter === 'all') {
      get('stage-host-list').replaceChildren(...hosts.map((host) => {
        const entry = link('', 'creator/' + host.id + '/stage', 'host-tile');
        entry.append(
          Kaka.creators.portrait(host, 'host-tile-portrait'),
          element('strong', '', host.name),
          element('span', 'caption', host.style),
        );
        return entry;
      }));
      get('stage-hosts').hidden = false;
    }
    const remaining = rooms.filter((room) => room !== hero);
    const list = get('stage-more-list');
    list.replaceChildren();
    if (remaining.length) {
      get('more-rooms-title').textContent = hero ? 'More rooms' : 'Room lineup';
      remaining.forEach((room) => {
        const entry = link('', 'room/' + room.id, 'track');
        list.append(track(room, entry));
      });
      get('stage-more').hidden = false;
    }
  }

  function init() {
    const controls = catalog.genres.map(([id, label]) => {
      const chip = button(label, () => {
        filter = id;
        controls.forEach((item) => item.setAttribute('aria-pressed', String(item === chip)));
        renderLineup();
      }, 'chip');
      chip.setAttribute('aria-pressed', String(id === filter));
      return chip;
    });
    get('stage-filters').replaceChildren(...controls);
  }

  function favoriteLabel(room) {
    return records.current().favorites.includes(room.id) ? 'Remove from saved' : 'Save room';
  }

  function noteForm(room) {
    const form = element('form', 'note-form');
    const label = element('label', 'field', 'Rehearsal note');
    const field = element('textarea');
    field.placeholder = 'Jot down a bar or a rhyme to try';
    field.rows = 3;
    field.maxLength = 480;
    const persisted = records.current().notes.find((note) => note.roomID === room.id)?.text ?? '';
    field.value = noteBuffer.get(room.id) ?? persisted;
    field.addEventListener('input', () => noteBuffer.set(room.id, field.value));
    label.append(field);
    const submit = element('button', 'button secondary', 'Save note');
    submit.type = 'submit';
    const error = element('p', 'field-error');
    error.hidden = true;
    error.setAttribute('role', 'status');
    form.append(label, submit, error);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const raw = field.value;
      const text = raw.trim();
      field.blur();
      message(error);
      pending(submit, async () => {
        await records.update((state) => {
          state.notes = state.notes.filter((note) => note.roomID !== room.id);
          if (text) state.notes.push({roomID: room.id, text});
        });
        if (field.value === raw) {
          noteBuffer.delete(room.id);
          field.value = text;
        }
        notify(text ? 'Rehearsal note saved.' : 'Rehearsal note cleared.');
      }, (failure) => message(error, failure.message));
    });
    return form;
  }

  function reportForm(room, onDismiss) {
    const form = element('form', 'report-form');
    const choices = element('fieldset');
    choices.append(element('legend', '', 'Why are you hiding this room?'));
    const options = element('div', 'chips');
    catalog.reportReasons.forEach((reason) => {
      const label = element('label', 'choice');
      const radio = element('input');
      radio.type = 'radio';
      radio.name = 'reason';
      radio.value = reason;
      label.append(radio, element('span', '', reason));
      options.append(label);
    });
    choices.append(options);
    const error = element('p', 'field-error');
    error.hidden = true;
    error.setAttribute('role', 'status');
    const action = element('div', 'button-row');
    const submit = element('button', 'button secondary', 'Hide room');
    submit.type = 'submit';
    action.append(submit, button('Cancel', onDismiss, 'button quiet'));
    form.append(choices, element('p', 'caption', 'You can restore this room from Profile.'), action, error);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const reason = new FormData(form).get('reason');
      if (!catalog.reportReasons.includes(reason)) {
        message(error, 'Choose a reason to continue.');
        return;
      }
      message(error);
      pending(submit, async () => {
        await records.update((state) => {
          if (!state.reports.some((report) => report.roomID === room.id)) {
            state.reports.push({roomID: room.id, reason, createdAt: Date.now()});
          }
        });
        if (location.hash === '#room/' + room.id) Kaka.go('stage', true);
        notify('Room hidden.');
      }, (failure) => message(error, failure.message));
    });
    return form;
  }

  function roomDetail(room) {
    if (detailID === room.id) return;
    detailID = room.id;
    const root = get('room-detail');
    const back = link('Back to Live Rooms', 'stage', 'button quiet room-back');
    const heading = element('h1', '', room.title);
    heading.id = 'room-title';
    heading.tabIndex = -1;
    const meta = element('p', 'caption', room.format + ' · ' + room.bpm + ' BPM');
    const summary = element('p', 'room-summary', room.description);

    const actions = element('div', 'button-row room-tools');
    const favorite = button(favoriteLabel(room), () => pending(favorite, async () => {
      await records.update((state) => {
        const index = state.favorites.indexOf(room.id);
        if (index >= 0) state.favorites.splice(index, 1);
        else state.favorites.push(room.id);
      });
      notify(records.current().favorites.includes(room.id) ? 'Room saved.' : 'Room removed from saved rooms.');
    }));
    favorite.id = 'room-favorite';
    actions.append(
      button('Rehearse', () => Kaka.cypher.enter(room.id), 'button primary'),
      button('Write a verse', () => Kaka.notebook.useRoom(room)),
      favorite,
    );

    let report;
    const reportToggle = button('Hide or flag room', () => {
      report.hidden = !report.hidden;
      reportToggle.setAttribute('aria-expanded', String(!report.hidden));
      if (!report.hidden) report.querySelector('input').focus();
    }, 'button quiet');
    reportToggle.setAttribute('aria-expanded', 'false');
    report = reportForm(room, () => {
      report.hidden = true;
      reportToggle.setAttribute('aria-expanded', 'false');
      reportToggle.focus();
    });
    report.hidden = true;

    root.replaceChildren(back, heading, meta);
    if (room.cover) root.append(image(room.cover, 'room-art', 'Two emcees trading bars on a basement stage'));
    const host = catalog.host(room.host);
    if (host) root.append(Kaka.creators.hostLink(host, 'stage', 'Host'));
    root.append(summary, actions, noteForm(room), reportToggle, report);
  }

  function refresh() {
    renderLineup();
    const liveDetail = detailID && catalog.room(detailID);
    if (!liveDetail) return;
    if (records.isHidden(liveDetail.id)) detailID = undefined;
    else get('room-favorite').textContent = favoriteLabel(liveDetail);
  }

  function reset() {
    filter = 'all';
    detailID = undefined;
    noteBuffer.clear();
    get('room-detail').replaceChildren();
    Array.from(get('stage-filters').children).forEach((chip, index) =>
      chip.setAttribute('aria-pressed', String(index === 0)));
  }

  Kaka.stage = {init, refresh, reset, roomDetail, track};
})();
