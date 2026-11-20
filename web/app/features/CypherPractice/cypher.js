(() => {
  /** @typedef {'idle' | 'starting' | 'practicing'} PracticeStatus */
  const Kaka = window.Kaka;
  const {get, element, link, button, image, message, notify, catalog, records} = Kaka;
  const filters = [['all', 'All rooms'], ['open', 'Open'], ['following', 'Following'], ['locked', 'Locked']];
  let filter = 'all';
  let visibleRooms = [];
  let displayedRooms = [];
  let selectedID;
  let connection;
  let carried;
  let audio;
  let interval;
  let generation = 0;
  const pendingBeats = new Set();
  let roomPassword;
  let seatPanel;
  let seatAction;
  let microphoneAction;
  let seatCaption;

  function room() {
    return catalog.room(selectedID);
  }

  function practiceTarget() {
    return room() ?? visibleRooms[0];
  }

  function tempo(entry) {
    return carried?.roomID === entry.id ? carried.score.bpm : entry.bpm;
  }

  function updateQuickPractice() {
    const target = practiceTarget();
    get('voice-quick').hidden = !target;
    if (target) {
      const bpm = tempo(target);
      get('voice-quick-room').textContent = [target.title, bpm && bpm + ' BPM'].filter(Boolean).join(' · ');
      const art = get('voice-quick-art');
      if (art.dataset.cover !== target.cover) {
        art.replaceChildren(catalog.image(target.cover, 'voice-quick-cover', 'voice.jpg'));
        art.dataset.cover = target.cover;
      }
    }
  }

  function roomCard(entry) {
    const card = link('', 'voice/' + entry.id, 'voice-room-card');
    const media = element('div', 'voice-room-media');
    const cover = catalog.image(entry.cover, 'voice-room-cover', 'voice.jpg');
    cover.loading = 'lazy';
    cover.decoding = 'async';
    cover.addEventListener('load', () => {
      if (!media.isConnected || !cover.naturalWidth || !cover.naturalHeight) return;
      const ratio = cover.naturalWidth / cover.naturalHeight;
      if (ratio >= .95 && ratio <= 1.05) return;
      const edge = cover.cloneNode(false);
      edge.className = 'voice-room-edge';
      media.prepend(edge);
    }, {once: true});
    media.append(cover);
    if (entry.locked) media.append(element('span', 'voice-room-lock', 'Locked'));
    const action = element('span', 'room-action-mark voice-listen-mark');
    action.setAttribute('aria-hidden', 'true');
    action.append(image('room-listen.png', 'room-action-image'));
    const copy = element('div', 'voice-room-copy');
    const hostName = catalog.host(entry.host)?.name.trim();
    const hostKey = hostName?.toLowerCase();
    const credit = hostKey && hostKey !== 'host' && hostKey !== entry.title.trim().toLowerCase() ? hostName : '';
    const activity = entry.bpm !== null || entry.viewers > 0 ? Kaka.stage.roomActivity(entry) : '';
    const caption = activity || credit;
    copy.append(element('h3', 'voice-room-name', entry.title));
    if (caption) copy.append(element('span', 'voice-room-meta', caption));
    card.append(media, copy, action);
    return card;
  }

  function matchesFilter(entry) {
    if (filter === 'following') return catalog.follows(entry.host);
    if (filter === 'open') return !entry.locked;
    if (filter === 'locked') return entry.locked;
    return true;
  }

  function renderLobby() {
    const rooms = visibleRooms.filter(matchesFilter);
    const hasLocked = visibleRooms.some((entry) => entry.locked);
    for (const chip of get('voice-filters').children) {
      const selected = chip.dataset.filter === filter;
      chip.hidden = chip.dataset.filter === 'locked' && !selected && !hasLocked;
      chip.setAttribute('aria-pressed', String(selected));
    }
    const grid = get('voice-rooms');
    if (rooms.length !== displayedRooms.length || rooms.some((entry, index) => entry !== displayedRooms[index])) {
      displayedRooms = rooms;
      grid.replaceChildren(...rooms.map(roomCard));
    }
    grid.hidden = !rooms.length;
    message(get('voice-room-count'), rooms.length ? rooms.length.toLocaleString('en-US') + (rooms.length === 1 ? ' room' : ' rooms') : '');
    const empty = get('voice-empty');
    empty.hidden = Boolean(rooms.length);
    const state = catalog.status('voice');
    const followingError = filter === 'following' ? catalog.followingError() : '';
    const emptyMessage = {
      all: 'No voice rooms are open.',
      open: 'No rooms without a password are open.',
      following: 'No voice rooms from hosts you follow.',
      locked: 'No password-protected rooms are available.',
    };
    empty.querySelector('p').textContent = state.loading ? 'Loading voice rooms…' : state.error || followingError || emptyMessage[filter];
    empty.querySelector('a').hidden = !catalog.rooms('voice').some((entry) => matchesFilter(entry) && records.isHidden(entry.id));
    const retry = get('voice-retry');
    retry.disabled = state.loading;
    retry.hidden = !state.error && !followingError;
    retry.onclick = () => !state.error && followingError ? catalog.refreshFollowing() : catalog.refreshRooms('voice');
  }

  function refresh() {
    const available = catalog.rooms('voice').filter((entry) => !records.isHidden(entry.id));
    if (selectedID && !available.some((entry) => entry.id === selectedID)) {
      const wasOpen = location.hash === '#' + resumeRoute();
      stop();
      selectedID = undefined;
      if (wasOpen) Kaka.go('voice', true);
    }
    visibleRooms = available;
    renderLobby();
    updateQuickPractice();
    const selected = room();
    if (selected && location.hash === '#' + resumeRoute()) describe(selected);
  }

  function openRoom(entry) {
    if (selectedID !== entry.id) {
      stop();
      message(get('practice-error'));
      roomPassword.value = '';
    }
    selectedID = entry.id;
    describe(entry);
    updateQuickPractice();
  }

  function resumeRoute() {
    return selectedID ? 'voice/' + selectedID : 'voice';
  }

  function describe(entry) {
    const score = carried?.roomID === entry.id ? carried.score : null;
    const host = catalog.host(entry.host);
    const cover = get('practice-cover');
    const art = catalog.mediaURL(entry.cover) || 'assets/images/voice.jpg';
    cover.hidden = false;
    if (cover.getAttribute('src') !== art) cover.src = art;
    get('voice-room-title').textContent = entry.title;
    get('practice-format').textContent = entry.format;
    get('practice-bpm').textContent = tempo(entry) ?? '';
    get('practice-bpm').parentElement.hidden = !tempo(entry);
    const prompt = get('practice-prompt');
    prompt.textContent = entry.exercise;
    prompt.closest('details').hidden = !entry.exercise;
    const hostSeat = get('practice-host');
    hostSeat.replaceChildren();
    hostSeat.hidden = !host;
    if (host) {
      const link = Kaka.creators.hostLink(host, 'voice', 'Host seat');
      link.classList.add('host-seat');
      hostSeat.append(link);
    }
    get('practice-verse').hidden = !score;
    if (score) {
      get('practice-verse-title').textContent = 'Rehearsing · ' + score.topic;
      get('practice-verse-lines').replaceChildren(...score.lines.map((line) => element('li', '', line)));
    }
    renderControls();
  }

  function renderControls() {
    const selected = room();
    const active = connection?.room.id === selected?.id ? connection : undefined;
    const seat = get('practice-seat');
    get('practice-seat-name').textContent = 'Room audio';
    get('practice-seat-action').textContent = active ? (active.joined ? 'Leave audio' : 'Connecting…') : 'Listen in';
    seat.setAttribute('aria-pressed', String(active?.joined === true));
    roomPassword.closest('label').hidden = !selected?.locked || active?.joined === true;
    const status = active?.seat;
    seatPanel.hidden = !active?.joined;
    seatCaption.hidden = !status?.queued && !status?.index;
    seatCaption.textContent = status?.queued ? 'Waiting for a seat' : (status?.index ? 'Mic seat ' + status.index : '');
    seatAction.textContent = status?.index ? 'Leave seat' : (status?.queued ? 'Seat requested' : 'Take a seat');
    seatAction.disabled = Boolean(active?.seatRequest || status?.queued);
    microphoneAction.textContent = status?.microphone ? 'Mute microphone' : 'Turn microphone on';
    microphoneAction.hidden = !status?.index;
    microphoneAction.disabled = Boolean(active?.seatRequest);
    microphoneAction.setAttribute('aria-pressed', String(status?.microphone === true));
    const canPlay = selected && tempo(selected) !== null && !active;
    get('beats').hidden = !canPlay;
    get('beat-status').hidden = !canPlay;
    get('beat-toggle').hidden = !canPlay;
    get('beat-toggle').disabled = !canPlay;
  }

  function showBeat(step = -1) {
    Array.from(get('beats').children).forEach((item, index) => item.classList.toggle('active', index === step));
  }

  /** @param {PracticeStatus} state */
  function setControls(state) {
    const toggle = get('beat-toggle');
    const running = state !== 'idle';
    toggle.setAttribute('aria-pressed', String(running));
    toggle.setAttribute('aria-label', {idle: 'Start the beat', starting: 'Cancel beat startup', practicing: 'Stop the beat'}[state]);
    get('beat-play-icon').hidden = running;
    get('beat-stop-icon').hidden = !running;
    get('practice').dataset.beatState = state;
    get('beat-status').textContent = {idle: 'Personal metronome', starting: 'Starting…', practicing: 'Metronome playing'}[state];
  }

  function stopBeat() {
    generation += 1;
    clearInterval(interval);
    interval = undefined;
    pendingBeats.forEach((timer) => clearTimeout(timer));
    pendingBeats.clear();
    if (audio) {
      const previous = audio;
      audio = undefined;
      previous.close().catch(() => {});
    }
    setControls('idle');
    showBeat();
  }

  function emitMedia(current, joined) {
    window.dispatchEvent(new CustomEvent('kaka:room-media', {
      detail: {kind: 'voice', roomID: current.room.serverID, joined},
    }));
  }

  async function leaveAudio() {
    if (!connection) return;
    const previous = connection;
    connection = undefined;
    clearInterval(previous.seatTimer);
    emitMedia(previous, false);
    renderControls();
    try {
      await Kaka.service.request('leaveRoomMedia');
    } catch {
      // Scene deactivation and session teardown also release the native channel.
    }
  }

  function stop() {
    stopBeat();
    void leaveAudio();
  }

  async function requestSeat(operation) {
    const current = connection;
    if (!current?.joined || current.seatRequest) return;
    const error = get('practice-error');
    const statusOnly = operation === 'voiceSeat.status';
    if (!statusOnly) message(error);
    current.seatRequest = !statusOnly;
    current.fetchingSeat = true;
    renderControls();
    try {
      const fields = {roomID: current.room.serverID};
      if (operation === 'voiceSeat.microphone') fields.enabled = !current.seat?.microphone;
      const seat = await Kaka.service.request(operation, fields);
      if (connection !== current) return;
      if (Number.isInteger(seat?.index) && seat.index >= 0
        && typeof seat.microphone === 'boolean' && typeof seat.queued === 'boolean') {
        current.seat = seat;
      }
    } catch (failure) {
      if (connection === current && !statusOnly) message(error, failure?.message || 'The mic seat could not be updated.');
    } finally {
      if (connection === current) {
        current.seatRequest = false;
        current.fetchingSeat = false;
        renderControls();
      }
    }
  }

  async function listen(seat) {
    const selected = room();
    if (!selected) return;
    const error = get('practice-error');
    message(error);
    if (connection) {
      await leaveAudio();
      return;
    }
    if (selected.locked && !roomPassword.value) {
      message(error, 'Enter the room password.');
      roomPassword.focus();
      return;
    }
    stopBeat();
    const current = {room: selected, joined: false};
    connection = current;
    const input = {kind: 'voice', roomID: selected.serverID};
    if (selected.locked) input.password = roomPassword.value;
    roomPassword.value = '';
    renderControls();
    try {
      await Kaka.service.request('joinRoomMedia', input);
      if (connection !== current) return;
      current.joined = true;
      emitMedia(current, true);
      void requestSeat('voiceSeat.status');
      current.seatTimer = setInterval(() => {
        if (connection === current && !current.fetchingSeat) void requestSeat('voiceSeat.status');
      }, 7_000);
    } catch (failure) {
      if (connection !== current) return;
      connection = undefined;
      message(error, failure?.message || 'Room audio could not connect.');
    }
    if (seat.isConnected) renderControls();
  }

  function scheduleClick(context, time, accented) {
    const wave = context.createOscillator();
    const volume = context.createGain();
    wave.type = 'sine';
    wave.frequency.value = accented ? 1220 : 800;
    volume.gain.setValueAtTime(.0001, time);
    volume.gain.exponentialRampToValueAtTime(accented ? .19 : .12, time + .003);
    volume.gain.exponentialRampToValueAtTime(.0001, time + .045);
    wave.connect(volume);
    volume.connect(context.destination);
    wave.start(time);
    wave.stop(time + .05);
    wave.onended = () => {
      wave.disconnect();
      volume.disconnect();
    };
  }

  async function start() {
    const selected = room();
    const bpm = selected && tempo(selected);
    if (!bpm || connection || audio) return;
    const token = ++generation;
    const toggle = get('beat-toggle');
    const error = get('practice-error');
    const Audio = window.AudioContext || window.webkitAudioContext;
    message(error);
    if (!Audio) {
      message(error, 'Beat playback is unavailable.');
      return;
    }
    let timeout;
    try {
      const context = new Audio();
      audio = context;
      setControls('starting');
      await Promise.race([
        context.resume(),
        new Promise((_, reject) => { timeout = setTimeout(reject, 2200); }),
      ]);
      if (token !== generation) return;
      if (toggle.closest('[hidden]')) {
        stopBeat();
        return;
      }
      context.addEventListener('statechange', () => {
        if (token === generation && context.state !== 'running') stopBeat();
      });
      setControls('practicing');
      const duration = 60 / bpm;
      let next = context.currentTime + .055;
      let beat = 0;
      const tick = () => {
        const now = context.currentTime;
        if (next < now - duration) {
          next = now + .035;
          beat = 0;
        }
        while (next < now + .11) {
          const step = beat % 4;
          scheduleClick(context, Math.max(now, next), step === 0);
          const timer = setTimeout(() => {
            pendingBeats.delete(timer);
            if (generation === token) showBeat(step);
          }, Math.max(0, (next - now) * 1000));
          pendingBeats.add(timer);
          beat += 1;
          next += duration;
        }
      };
      tick();
      interval = setInterval(tick, 35);
    } catch {
      if (generation === token) {
        stopBeat();
        message(error, 'The beat could not play. Try again.');
      }
    } finally {
      clearTimeout(timeout);
    }
  }

  function enter(id) {
    if (catalog.room(id)?.kind !== 'voice' || records.isHidden(id)) return;
    Kaka.go('voice/' + id);
  }

  function carry(score) {
    const target = visibleRooms.find((entry) => entry.id === score.roomID) ?? practiceTarget();
    if (!target) {
      notify('There’s no voice room available to rehearse in.');
      return;
    }
    const lines = score.bars.map((bar) => bar.text.trim());
    if (lines.some((line) => !line)) {
      notify('Fill in every bar before rehearsing.');
      return;
    }
    stop();
    carried = {roomID: target.id, score: {topic: score.topic, bpm: score.bpm, lines}};
    enter(target.id);
    notify('Verse ready to rehearse.');
  }

  function init() {
    get('voice-filters').replaceChildren(...filters.map(([id, label]) => {
      const chip = button(label, () => {
        filter = id;
        renderLobby();
      }, 'chip');
      chip.dataset.filter = id;
      chip.setAttribute('aria-controls', 'voice-rooms voice-empty');
      return chip;
    }));
    get('voice-quick').addEventListener('click', () => {
      const target = practiceTarget();
      if (target) enter(target.id);
    });
    get('beat-toggle').addEventListener('click', () => {
      if (audio) stopBeat();
      else start();
    });
    get('practice-write').addEventListener('click', () => {
      const selected = room();
      if (selected) Kaka.notebook.useRoom(selected);
    });
    const seat = get('practice-seat');
    seat.addEventListener('click', () => Kaka.pending(seat, () => listen(seat)));
    const passwordLabel = element('label', 'field', 'Room password');
    roomPassword = element('input');
    roomPassword.type = 'password';
    roomPassword.autocomplete = 'off';
    roomPassword.maxLength = 32;
    roomPassword.enterKeyHint = 'go';
    roomPassword.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return;
      event.preventDefault();
      roomPassword.blur();
      seat.click();
    });
    passwordLabel.append(roomPassword);
    passwordLabel.hidden = true;
    seat.closest('.practice-seats').before(passwordLabel);
    seatPanel = element('div', 'button-row practice-transport');
    seatPanel.hidden = true;
    seatCaption = element('p', 'caption');
    seatCaption.setAttribute('role', 'status');
    seatAction = button('Take a seat', () => {
      if (!connection?.fetchingSeat) void requestSeat(connection?.seat?.index ? 'voiceSeat.leave' : 'voiceSeat.take');
    });
    microphoneAction = button('Turn microphone on', () => {
      if (!connection?.fetchingSeat) void requestSeat('voiceSeat.microphone');
    });
    seatPanel.append(seatCaption, seatAction, microphoneAction);
    seat.closest('.practice-seats').after(seatPanel);
    const retry = element('button', 'button secondary', 'Try again');
    retry.type = 'button';
    retry.id = 'voice-retry';
    retry.hidden = true;
    get('voice-empty').append(retry);
    renderLobby();
    get('practice-drop-verse').addEventListener('click', () => {
      stopBeat();
      carried = undefined;
      if (room()) describe(room());
      updateQuickPractice();
    });
    window.addEventListener('kaka:pause', stop);
    window.addEventListener('kaka:suspend', stop);
    window.addEventListener('pagehide', stop);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) stop();
    });
  }

  function reset() {
    stop();
    filter = 'all';
    visibleRooms = [];
    renderLobby();
    selectedID = undefined;
    carried = undefined;
    get('voice-quick').hidden = true;
    const art = get('voice-quick-art');
    art.replaceChildren();
    delete art.dataset.cover;
    get('practice-verse-title').textContent = '';
    get('practice-verse-lines').replaceChildren();
  }

  Kaka.cypher = {init, refresh, reset, stop, openRoom, resumeRoute, enter, carry};
})();
