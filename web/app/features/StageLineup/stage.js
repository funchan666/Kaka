(() => {
  const Kaka = window.Kaka;
  const {get, element, button, link, image, actionIcon, notify, message, pending, catalog, records} = Kaka;
  const genres = catalog.genres.filter(([id]) => id !== 'all');
  const filters = [['all', 'All live'], ['following', 'Following'], ['watched', 'Most watched'], ...genres];
  let filter = 'all';
  let visibleRooms = [];
  let spotlight = [];
  let detailID;
  let detailRequest = 0;
  let streaming;
  let pendingFrame;
  let previousFrame;
  let renderedRooms = [];
  const noteBuffer = new Map();

  function roomActivity(room) {
    if (room.bpm !== null) return room.bpm + ' BPM';
    if (room.viewers !== null) return room.viewers.toLocaleString('en-US') + (room.kind === 'live' ? ' watching' : ' in room');
    return '';
  }

  function liveRoomCaption(room) {
    const activity = room.bpm !== null || room.viewers > 0 ? roomActivity(room) : '';
    return [room.format, activity].filter(Boolean).join(' · ');
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
    current.button.hidden = false;
    setWatchAction(current.button, 'Watch live');
    liveStatus(current.slot, current.status, 'idle');
    if (current.joined) emitMedia(current, false);
    placeStream();
    try {
      await Kaka.service.request('leaveRoomMedia');
    } catch {
      // The native host also releases media on session or scene teardown.
    }
  }

  function emitMedia(current, joined) {
    window.dispatchEvent(new CustomEvent('kaka:room-media', {
      detail: {kind: 'live', roomID: current.roomID, joined},
    }));
  }

  function liveStatus(slot, status, state, text) {
    slot.dataset.liveState = state;
    status.dataset.liveState = state;
    message(status, text);
  }

  function setWatchAction(control, title, icon = 'room-watch.png') {
    control.textContent = title;
    actionIcon(control, icon);
  }

  function roomCard(room, featured = false) {
    const card = link('', 'room/' + room.id, 'stage-card' + (featured ? ' stage-pick' : ''));
    const host = catalog.host(room.host);
    const media = element('div', 'stage-card-media');
    const cover = catalog.image(room.cover || host?.portrait, 'stage-card-image', featured ? 'live-deck.jpg' : 'stage.jpg');
    cover.decoding = 'async';
    if (!featured) cover.loading = 'lazy';
    media.append(cover);
    const entry = element('span', 'room-action-mark stage-watch-mark');
    entry.setAttribute('aria-hidden', 'true');
    entry.append(image('room-watch.png', 'room-action-image'));

    const showHost = host && host.name.trim().toLowerCase() !== room.title.trim().toLowerCase();
    const copy = element('div', 'stage-card-copy');
    const labels = element('div', 'stage-card-labels');
    labels.append(element('h3', 'stage-card-title', room.title));
    if (!featured && showHost) labels.append(element('span', 'stage-card-host', host.name));
    copy.append(labels);
    if (featured) {
      copy.append(entry);
    } else {
      const status = element('span', 'stage-card-status', 'Live');
      if (room.viewers > 0) status.append(element('span', 'stage-card-viewers', ' ' + room.viewers.toLocaleString('en-US') + ' watching'));
      media.append(status, entry);
    }
    card.append(media, copy);
    return card;
  }

  function renderFeatured() {
    const picks = visibleRooms.length >= 4 ? visibleRooms.filter((room) => room.cover)
      .sort((first, second) => (second.viewers ?? 0) - (first.viewers ?? 0))
      .slice(0, Math.min(3, visibleRooms.length - 2)) : [];
    spotlight = picks.length >= 2 ? picks : [];
    const list = get('stage-featured-list');
    list.replaceChildren(...spotlight.map((room) => roomCard(room, true)));
  }

  function matchesFilter(room) {
    if (filter === 'all') return true;
    if (filter === 'following') return catalog.follows(room.host);
    if (filter === 'watched') return room.viewers > 0;
    return room.genre === filter;
  }

  function renderRooms() {
    const state = catalog.status('live');
    const showSpotlight = filter === 'all' && spotlight.length > 0;
    get('stage-featured').hidden = !showSpotlight;
    const rooms = visibleRooms.filter((room) => matchesFilter(room) && (!showSpotlight || !spotlight.includes(room)));
    if (filter === 'watched') rooms.sort((first, second) => second.viewers - first.viewers);
    const filterBar = get('stage-filters');
    for (const chip of filterBar.children) {
      const id = chip.dataset.filter;
      chip.hidden = id !== filter && genres.some(([key]) => key === id) && !visibleRooms.some((room) => room.genre === id);
      chip.setAttribute('aria-pressed', String(id === filter));
    }
    get('stage-rooms-title').textContent = showSpotlight ? 'More live rooms' : 'Live now';
    message(get('stage-room-count'), rooms.length ? rooms.length.toLocaleString('en-US') + (rooms.length === 1 ? ' room' : ' rooms') : '');
    const grid = get('stage-room-grid');
    if (rooms.length !== renderedRooms.length || rooms.some((room, index) => room !== renderedRooms[index])) {
      grid.replaceChildren(...rooms.map((room) => roomCard(room)));
      renderedRooms = rooms;
    }
    grid.hidden = !rooms.length;
    get('stage-empty').hidden = Boolean(rooms.length);
    const emptyMessage = {
      all: 'No one is live right now.',
      following: 'No live rooms from hosts you follow in this list.',
      watched: 'No rooms with viewers in this list.',
    };
    const followingError = filter === 'following' ? catalog.followingError() : '';
    const empty = state.loading ? 'Loading live rooms…' : state.error || followingError
      || emptyMessage[filter] || 'No rooms in this category.';
    get('stage-empty-message').textContent = empty;
    get('stage-restore-rooms').hidden = !catalog.rooms('live').some((room) => matchesFilter(room) && records.isHidden(room.id));
    const status = get('stage-pagination');
    const next = get('stage-next');
    const failure = get('stage-load-error');
    const retryPage = Boolean(state.error && state.more && visibleRooms.length);
    status.hidden = !state.error && !state.more && !followingError;
    message(failure, rooms.length ? state.error || followingError : '');
    next.disabled = state.loading;
    next.textContent = state.loading ? 'Loading…' : (state.error || followingError ? 'Try again' : 'Load more rooms');
    next.onclick = () => followingError && !state.error
      ? pending(next, () => catalog.refreshFollowing()) : catalog.refreshRooms('live', retryPage || (!state.error && state.more));
  }

  function init() {
    const controls = filters.map(([id, label]) => {
      const chip = button(label, () => {
        filter = id;
        renderRooms();
      }, 'chip');
      chip.dataset.filter = id;
      chip.setAttribute('aria-controls', 'stage-room-grid stage-featured');
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
    renderRooms();
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
    const back = actionIcon(link('', 'stage', 'button quiet room-heading-back'), 'action-forward.png', 'Back to Live Rooms');
    const heading = element('h1', '', room.title);
    heading.id = 'room-title';
    heading.tabIndex = -1;
    const meta = element('p', 'caption', liveRoomCaption(room));
    const scene = element('section', 'scene room-scene with-preview');
    const videoSlot = element('div', 'feature-screen');
    const cover = catalog.image(room.cover, 'feature-image');
    videoSlot.append(cover);
    const header = element('header', 'live-room-heading');
    const title = element('div', 'scene-title');
    title.append(heading, meta);
    const hostSlot = element('div', 'live-room-host');
    const host = catalog.host(room.host);
    if (host) hostSlot.append(Kaka.creators.hostLink(host, 'stage', 'View host'));
    hostSlot.hidden = !host;
    header.append(back, title, hostSlot);
    scene.append(header, videoSlot);

    const brief = element('div', 'room-brief');
    const subject = element('h2', 'section-title');
    const description = element('p', 'caption');
    const availability = element('p', 'caption live-room-status');
    availability.setAttribute('role', 'status');
    let currentRoom = room;
    const isCurrentRoom = () => stamp === detailRequest && location.hash === '#room/' + room.id;
    const watch = button('Watch live', () => pending(watch, async () => {
      if (streaming?.slot === videoSlot) {
        await leaveStream();
        return;
      }
      await joinStream();
    }), 'button primary live-room-connection');
    setWatchAction(watch, 'Watch live');
    watch.hidden = true;

    async function joinStream() {
      if (streaming || !isCurrentRoom()) return;
      if (document.hidden) {
        watch.hidden = false;
        liveStatus(videoSlot, availability, 'idle');
        return;
      }
      const observe = new ResizeObserver(placeStream);
      const connection = {roomID: room.serverID, slot: videoSlot, button: watch, status: availability, observe};
      streaming = connection;
      observe.observe(videoSlot);
      watch.hidden = true;
      liveStatus(videoSlot, availability, 'connecting', 'Connecting to the live room…');
      previousFrame = undefined;
      placeStream();
      try {
        await Kaka.service.request('joinRoomMedia', {kind: 'live', roomID: room.serverID});
        if (streaming !== connection) return;
        if (!isCurrentRoom() || document.hidden) {
          void leaveStream();
          return;
        }
        connection.joined = true;
        watch.hidden = false;
        setWatchAction(watch, 'Stop watching', 'action-stop.png');
        liveStatus(videoSlot, availability, 'joined');
        emitMedia(connection, true);
        placeStream();
      } catch (error) {
        if (streaming !== connection) return;
        streaming = undefined;
        observe.disconnect();
        placeStream();
        watch.hidden = false;
        setWatchAction(watch, 'Retry live');
        liveStatus(videoSlot, availability, 'error', error?.message || 'Live playback could not start.');
      }
    }

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
      actionIcon(link('', 'voice', 'button secondary room-tool-key'), 'room-listen.png', 'Voice rooms'),
      actionIcon(button('', () => Kaka.notebook.useRoom(currentRoom), 'button secondary room-tool-key'), 'room-write.png', 'Write a verse'),
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

    const retry = button('Try again', () => pending(retry, loadDetails), 'button secondary');
    retry.hidden = true;
    const safety = element('div', 'button-row room-safety');
    safety.append(hide, reportToggle);
    root.replaceChildren(scene, availability, retry, actions, brief, note, safety, report);
    loadDetails();

    async function loadDetails() {
      retry.hidden = true;
      liveStatus(videoSlot, availability, 'connecting', 'Loading the live room…');
      try {
        const fresh = await catalog.refreshLive(room);
        if (!fresh || !isCurrentRoom()) return;
        currentRoom = fresh;
        heading.textContent = fresh.title;
        meta.textContent = liveRoomCaption(fresh);
        if (!room.cover && fresh.cover) videoSlot.replaceChildren(catalog.image(fresh.cover, 'feature-image'));
        const currentHost = catalog.host(fresh.host);
        hostSlot.replaceChildren();
        if (currentHost) hostSlot.append(Kaka.creators.hostLink(currentHost, 'stage', 'View host'));
        hostSlot.hidden = !currentHost;
        reportToggle.hidden = !currentHost;
        updateBrief(fresh);
      } catch (error) {
        if (!isCurrentRoom()) return;
        liveStatus(videoSlot, availability, 'error', error?.message || 'The room could not load.');
        retry.hidden = false;
        return;
      }
      await joinStream();
    }
  }

  function refresh() {
    const rooms = catalog.rooms('live').filter((room) => !records.isHidden(room.id));
    const changed = rooms.length !== visibleRooms.length || rooms.some((room, index) => room !== visibleRooms[index]);
    if (changed) {
      visibleRooms = rooms;
      renderFeatured();
    }
    renderRooms();
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
    renderedRooms = [];
    visibleRooms = [];
    detailID = undefined;
    noteBuffer.clear();
    get('room-detail').replaceChildren();
    renderFeatured();
    get('stage-room-grid').replaceChildren();
    renderRooms();
  }

  Kaka.stage = {init, refresh, reset, roomDetail, track, stopPreview, roomActivity};
})();
