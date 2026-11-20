(() => {
  const Kaka = window.Kaka;
  const {get, element, button, link, image, actionIcon, notify, message, pending, catalog, records} = Kaka;
  let filter = 'all';
  let visibleRooms = [];
  let detailID;
  let detailRequest = 0;
  let streaming;
  let pendingFrame;
  let previousFrame;
  let renderedFilter;
  const noteBuffer = new Map();

  function roomActivity(room) {
    if (room.bpm !== null) return room.bpm + ' BPM';
    if (room.viewers !== null) return room.viewers.toLocaleString('en-US') + (room.kind === 'live' ? ' watching' : ' in room');
    return '';
  }

  function track(room, control, showHost = true) {
    control.classList.add('track');
    const host = showHost && catalog.host(room.host);
    const identity = element('span', 'track-identity');
    const copy = element('span', 'track-copy');
    copy.append(element('strong', '', room.title), element('span', 'caption', host ? host.name + ' · ' + room.format : room.format));
    if (room.cover) {
      const media = element('span', 'track-media');
      media.append(catalog.image(room.cover, 'track-cover'));
      if (host) media.append(Kaka.creators.portrait(host, 'track-avatar'));
      identity.append(media);
    } else if (host) {
      identity.append(Kaka.creators.portrait(host, 'host-avatar'));
    }
    identity.append(copy);
    control.append(identity);
    const activity = roomActivity(room);
    if (activity) control.append(element('span', 'track-bpm', activity));
    return control;
  }

  function stopPreview() {
    leaveStream();
    detailID = undefined;
    detailRequest += 1;
  }

  function placeStream() {
    if (pendingFrame) return;
    pendingFrame = requestAnimationFrame(() => {
      pendingFrame = undefined;
      const viewport = window.visualViewport;
      const rect = streaming?.slot.getBoundingClientRect();
      const view = get('room').getBoundingClientRect();
      const frame = rect && rect.width > 0 && rect.height > 0 && rect.top >= view.top
        && rect.bottom <= view.bottom && Math.abs((viewport?.scale ?? 1) - 1) < .01
        && !document.hidden && !get('app').hasAttribute('aria-hidden')
        ? {x: rect.x, y: rect.y, width: rect.width, height: rect.height,
          viewportWidth: document.documentElement.clientWidth, viewportHeight: window.innerHeight}
        : null;
      const key = JSON.stringify(frame);
      if (key === previousFrame) return;
      previousFrame = key;
      records.call('media.frame', {frame}).then((shown) => {
        if (!shown && previousFrame === key) previousFrame = undefined;
      }).catch(() => {});
    });
  }

  async function leaveStream() {
    if (!streaming) return;
    const current = streaming;
    streaming = undefined;
    current.observe.disconnect();
    current.button.textContent = 'Watch live';
    message(current.status, 'Live room ready.');
    emitMedia(current, false);
    placeStream();
    try {
      await Kaka.service.request('leaveRoomMedia');
    } catch {
      // The native view also releases its active channel when a session ends.
    }
  }

  function emitMedia(current, joined) {
    window.dispatchEvent(new CustomEvent('kaka:room-media', {
      detail: {kind: 'live', roomID: current.roomID, joined},
    }));
  }

  function roomCard(room, banner = false) {
    const card = link('', 'room/' + room.id, 'stage-card');
    const media = element('div', 'stage-card-media');
    const cover = catalog.image(room.cover, 'stage-card-image');
    cover.decoding = 'async';
    if (!banner) cover.loading = 'lazy';
    media.append(cover);

    const copy = element('div', 'stage-card-copy');
    const byline = element('div', 'stage-card-byline');
    const host = catalog.host(room.host);
    const credit = host ? host.name + ' · ' + room.format : room.format;
    if (host) byline.append(Kaka.creators.portrait(host, 'stage-card-avatar'));
    byline.append(element('span', '', credit));
    copy.append(element('h3', 'stage-card-title', room.title), byline);
    card.append(media, copy);

    if (banner) {
      const arrow = element('span', 'stage-banner-arrow');
      arrow.append(image('action-forward.png', 'action-icon'));
      card.append(arrow);
    } else {
      const activity = roomActivity(room);
      if (activity) card.append(element('span', 'stage-card-tempo', activity));
    }
    return card;
  }

  function renderFeatured() {
    const featured = visibleRooms.filter((room) => room.cover)
      .sort((first, second) => (second.viewers ?? 0) - (first.viewers ?? 0)).slice(0, 3);
    get('stage-featured-list').replaceChildren(...featured.map((room) => roomCard(room, true)));
    get('stage-featured').hidden = !featured.length;
  }

  function matchesFilter(room) {
    return filter === 'all' || room.genre === filter;
  }

  function renderRooms(rebuild = false) {
    const state = catalog.status('live');
    const rooms = visibleRooms.filter(matchesFilter);
    const grid = get('stage-room-grid');
    if (rebuild || filter !== renderedFilter) {
      grid.replaceChildren(...rooms.map((room) => roomCard(room)));
      renderedFilter = filter;
    }
    grid.hidden = !rooms.length;
    get('stage-empty').hidden = Boolean(rooms.length);
    const empty = state.loading ? 'Loading live rooms…' : state.error
      || (filter === 'all' ? 'No one is live right now.' : 'No rooms in this category.');
    get('stage-empty-message').textContent = empty;
    get('stage-restore-rooms').hidden = !catalog.rooms('live').some((room) => matchesFilter(room) && records.isHidden(room.id));
    const status = get('stage-pagination');
    const next = get('stage-next');
    const failure = get('stage-load-error');
    const retryPage = Boolean(state.error && state.more && visibleRooms.length);
    status.hidden = !state.error && !state.more;
    message(failure, rooms.length ? state.error : '');
    next.disabled = state.loading;
    next.textContent = state.loading ? 'Loading…' : (state.error ? 'Try again' : 'More live rooms');
    next.onclick = () => catalog.refreshRooms('live', retryPage || (!state.error && state.more));
  }

  function init() {
    const controls = catalog.genres.map(([id, label]) => {
      const chip = button(label, () => {
        filter = id;
        controls.forEach((item) => item.setAttribute('aria-pressed', String(item === chip)));
        renderRooms();
      }, 'chip');
      chip.setAttribute('aria-controls', 'stage-room-grid');
      chip.setAttribute('aria-pressed', String(id === filter));
      return chip;
    });
    get('stage-filters').replaceChildren(...controls);
    const status = element('div', 'button-row');
    status.id = 'stage-pagination';
    const next = element('button', 'button secondary');
    next.type = 'button';
    next.id = 'stage-next';
    const failure = element('p', 'field-error');
    failure.id = 'stage-load-error';
    failure.setAttribute('role', 'status');
    status.append(next, failure);
    get('stage-empty').after(status);
    get('room').addEventListener('scroll', placeStream, {passive: true});
    window.addEventListener('kaka:geometry', () => {
      previousFrame = undefined;
      placeStream();
    });
    window.addEventListener('resize', placeStream);
    window.visualViewport?.addEventListener('resize', placeStream);
    window.visualViewport?.addEventListener('scroll', placeStream);
    const overlay = new MutationObserver(placeStream);
    overlay.observe(get('app'), {attributeFilter: ['aria-hidden']});
    window.addEventListener('kaka:pause', leaveStream);
    window.addEventListener('kaka:suspend', leaveStream);
    window.addEventListener('pagehide', leaveStream);
    document.addEventListener('visibilitychange', () => { if (document.hidden) leaveStream(); });
  }

  function renderFavorite(control, room) {
    const saved = records.current().favorites.includes(room.id);
    control.setAttribute('aria-pressed', String(saved));
    control.setAttribute('aria-label', saved ? 'Remove from saved rooms' : 'Save room');
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
    actionIcon(submit, 'action-check.png');
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

  function reportForm(currentRoom, onDismiss) {
    const form = element('form', 'report-form');
    const choices = element('fieldset');
    choices.append(element('legend', '', 'Why are you reporting this room?'));
    const options = element('div', 'chips');
    catalog.reportReasons.forEach(([code, reason]) => {
      const label = element('label', 'choice');
      const radio = element('input');
      radio.type = 'radio';
      radio.name = 'reason';
      radio.value = code;
      label.append(radio, element('span', '', reason));
      options.append(label);
    });
    choices.append(options);
    const error = element('p', 'field-error');
    error.hidden = true;
    error.setAttribute('role', 'status');
    const action = element('div', 'button-row');
    const submit = element('button', 'button secondary', 'Send report');
    submit.type = 'submit';
    action.append(submit, button('Cancel', onDismiss, 'button quiet'));
    form.append(choices, action, error);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const reason = new FormData(form).get('reason');
      if (!catalog.reportReasons.some(([code]) => code === reason)) {
        message(error, 'Choose a reason to continue.');
        return;
      }
      message(error);
      pending(submit, async () => {
        const room = currentRoom();
        const host = catalog.host(room.host);
        if (!host) throw new Error('This room has no reportable host.');
        await Kaka.service.request('reportUser', {
          castEmblem: host.serverID,
          habitatTag: room.serverID,
          reviewMode: reason,
        });
        if (!form.isConnected) return;
        form.reset();
        onDismiss();
        notify('Report submitted.');
      }, (failure) => message(error, failure.message));
    });
    return form;
  }

  function roomDetail(room) {
    if (detailID === room.id) return;
    leaveStream();
    detailID = room.id;
    const stamp = ++detailRequest;
    const root = get('room-detail');
    const back = link('Live rooms', 'stage', 'button quiet');
    const heading = element('h1', '', room.title);
    heading.id = 'room-title';
    heading.tabIndex = -1;
    const meta = element('p', 'caption', [room.format, roomActivity(room)].filter(Boolean).join(' · '));
    const scene = element('header', 'scene room-scene with-preview');
    const videoSlot = element('div', 'feature-screen');
    const cover = catalog.image(room.cover, 'feature-image');
    videoSlot.append(cover);
    scene.append(videoSlot);
    const details = element('div', 'scene-heading');
    const title = element('div', 'scene-title');
    title.append(heading, meta);
    details.append(title);
    const hostSlot = element('div');
    const host = catalog.host(room.host);
    if (host) hostSlot.append(Kaka.creators.hostLink(host, 'stage', 'Host'));
    details.append(hostSlot);
    scene.append(details);

    const brief = element('div', 'room-brief');
    const subject = element('h2', 'section-title');
    const description = element('p', 'caption');
    const availability = element('p', 'caption');
    availability.setAttribute('role', 'status');
    let currentRoom = room;
    const watch = button('Watch live', () => pending(watch, async () => {
      if (streaming?.slot === videoSlot) {
        await leaveStream();
        return;
      }
      const observe = new ResizeObserver(placeStream);
      const connection = {roomID: room.serverID, slot: videoSlot, button: watch, status: availability, observe};
      streaming = connection;
      observe.observe(videoSlot);
      watch.textContent = 'Connecting…';
      message(availability, 'Connecting to the live room…');
      placeStream();
      try {
        await Kaka.service.request('joinRoomMedia', {kind: 'live', roomID: room.serverID});
        if (streaming !== connection) return;
        watch.textContent = 'Leave stream';
        message(availability, 'Connected to the live room.');
        emitMedia(connection, true);
        placeStream();
      } catch (error) {
        if (streaming !== connection) return;
        streaming = undefined;
        observe.disconnect();
        placeStream();
        watch.textContent = 'Watch live';
        message(availability, error?.message || 'Live playback could not start.');
      }
    }), 'button primary');
    watch.hidden = true;
    function updateBrief(current) {
      message(subject, current.topic === current.title ? '' : current.topic);
      message(description, current.description);
      brief.hidden = subject.hidden && description.hidden;
    }
    brief.append(subject, description);
    updateBrief(room);
    const note = element('details', 'section-disclosure room-note');
    const noteToggle = element('summary', 'disclosure-summary');
    noteToggle.append(element('span', '', 'Rehearsal note'), image('action-forward.png', 'action-icon'));
    note.append(noteToggle, noteForm(room));

    const actions = element('div', 'button-row room-tools');
    const favorite = button('', () => pending(favorite, async () => {
      await records.update((state) => {
        const index = state.favorites.indexOf(room.id);
        if (index >= 0) state.favorites.splice(index, 1);
        else state.favorites.push(room.id);
      });
      notify(records.current().favorites.includes(room.id) ? 'Room saved.' : 'Room removed from saved rooms.');
    }));
    favorite.id = 'room-favorite';
    actionIcon(favorite, 'action-bookmark.png', 'Save room');
    renderFavorite(favorite, room);
    actions.append(
      watch,
      actionIcon(link('Voice rooms', 'voice', 'button secondary'), 'tab-voice.png'),
      actionIcon(button('', () => Kaka.notebook.useRoom(currentRoom)), 'action-edit.png', 'Write a verse'),
      favorite,
    );
    const hide = button('Hide room', () => pending(hide, async () => {
      await records.update((state) => {
        if (!state.reports.some((report) => report.roomID === room.id)) {
          state.reports.push({roomID: room.id, reason: 'Hidden by you', createdAt: Date.now()});
        }
      });
      if (location.hash === '#room/' + room.id) Kaka.go('stage', true);
      notify('Room hidden from your list.');
    }), 'button quiet');
    actions.append(hide);

    let report;
    const reportToggle = button('Report room', () => {
      report.hidden = !report.hidden;
      reportToggle.setAttribute('aria-expanded', String(!report.hidden));
      if (!report.hidden) report.querySelector('input').focus();
    }, 'button quiet');
    reportToggle.setAttribute('aria-expanded', 'false');
    reportToggle.hidden = !host;
    report = reportForm(() => currentRoom, () => {
      report.hidden = true;
      reportToggle.setAttribute('aria-expanded', 'false');
      reportToggle.focus();
    });
    report.hidden = true;

    const retry = button('Try again', loadDetails, 'button secondary');
    retry.hidden = true;
    root.replaceChildren(back, scene, availability, retry, actions, brief, note, reportToggle, report);
    loadDetails();

    async function loadDetails() {
      retry.hidden = true;
      message(availability, 'Loading the live room…');
      try {
        const fresh = await catalog.refreshLive(room);
        if (!fresh || stamp !== detailRequest) return;
        currentRoom = fresh;
        heading.textContent = fresh.title;
        meta.textContent = [fresh.format, roomActivity(fresh)].filter(Boolean).join(' · ');
        if (fresh.cover !== room.cover) videoSlot.replaceChildren(catalog.image(fresh.cover, 'feature-image'));
        const currentHost = catalog.host(fresh.host);
        if (currentHost) hostSlot.replaceChildren(Kaka.creators.hostLink(currentHost, 'stage', 'Host'));
        reportToggle.hidden = !currentHost;
        updateBrief(fresh);
        watch.hidden = false;
        message(availability, 'Live room ready.');
      } catch (error) {
        if (stamp !== detailRequest) return;
        message(availability, error?.message || 'The room could not load.');
        retry.hidden = false;
      }
    }
  }

  function refresh() {
    const rooms = catalog.rooms('live').filter((room) => !records.isHidden(room.id));
    const changed = rooms.length !== visibleRooms.length || rooms.some((room, index) => room !== visibleRooms[index]);
    if (changed) {
      visibleRooms = rooms;
      renderFeatured();
    }
    if (!rooms.some((room) => room.genre)) filter = 'all';
    get('stage-filters').hidden = !rooms.some((room) => room.genre);
    renderRooms(changed);
    const liveDetail = detailID && catalog.room(detailID);
    if (!liveDetail) return;
    if (records.isHidden(liveDetail.id)) {
      stopPreview();
    } else {
      renderFavorite(get('room-favorite'), liveDetail);
    }
  }

  function reset() {
    stopPreview();
    filter = 'all';
    renderedFilter = undefined;
    visibleRooms = [];
    detailID = undefined;
    noteBuffer.clear();
    get('room-detail').replaceChildren();
    renderFeatured();
    get('stage-room-grid').replaceChildren();
    Array.from(get('stage-filters').children).forEach((chip, index) =>
      chip.setAttribute('aria-pressed', String(index === 0)));
  }

  Kaka.stage = {init, refresh, reset, roomDetail, track, stopPreview, roomActivity};
})();
