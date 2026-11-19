(() => {
  /** @typedef {'idle' | 'starting' | 'practicing'} PracticeStatus */
  const Kaka = window.Kaka;
  const {get, element, button, message, notify, catalog, records} = Kaka;
  let selectedID;
  let seatedID;
  let carried;
  let revealPractice = false;
  let audio;
  let interval;
  let generation = 0;
  const pendingBeats = new Set();

  function room() {
    return catalog.room(selectedID);
  }

  function refresh() {
    const available = catalog.rooms().filter((entry) => !records.isHidden(entry.id));
    if (!available.some((entry) => entry.id === selectedID)) {
      stop();
      selectedID = available[0]?.id;
      seatedID = undefined;
    }
    const selected = room();
    get('voice-rooms').replaceChildren(...available.map((entry) => {
      const row = button('', () => {
        if (selectedID === entry.id) return;
        stop();
        selectedID = entry.id;
        get('voice-rooms').querySelectorAll('button').forEach((control) => {
          control.setAttribute('aria-pressed', String(control === row));
        });
        describe(entry);
      }, 'track');
      row.setAttribute('aria-pressed', String(entry.id === selectedID));
      return Kaka.stage.track(entry, row);
    }));
    get('practice').hidden = !selected;
    get('voice-selector').hidden = !selected;
    get('voice-empty').hidden = Boolean(selected);
    if (selected) describe(selected);
  }

  function describe(entry) {
    const score = carried?.roomID === entry.id ? carried.score : null;
    const host = catalog.host(entry.host);
    get('practice-title').textContent = entry.title;
    get('practice-format').textContent = entry.format;
    get('practice-bpm').textContent = score ? score.bpm : entry.bpm;
    get('practice-prompt').textContent = entry.exercise;
    get('practice-host').replaceChildren(...(host ? [Kaka.creators.hostLink(host, 'voice', 'Host')] : []));
    get('practice-verse').hidden = !score;
    if (score) {
      get('practice-verse-title').textContent = 'Rehearsing · ' + score.topic;
      get('practice-verse-lines').replaceChildren(...score.lines.map((line) => element('li', '', line)));
    }
    renderSeat();
    message(get('practice-error'));
  }

  function renderSeat() {
    const occupied = Boolean(selectedID && seatedID === selectedID);
    const seat = get('practice-seat');
    seat.textContent = occupied ? 'Leave seat' : 'Take a seat';
    seat.setAttribute('aria-pressed', String(occupied));
    get('beat-toggle').disabled = !occupied;
  }

  function showBeat(step = -1) {
    Array.from(get('beats').children).forEach((item, index) => item.classList.toggle('active', index === step));
  }

  /** @param {PracticeStatus} state */
  function setControls(state) {
    const toggle = get('beat-toggle');
    toggle.setAttribute('aria-pressed', String(state !== 'idle'));
    toggle.textContent = {idle: 'Start the beat', starting: 'Cancel', practicing: 'Stop the beat'}[state];
  }

  function stop() {
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
    if (!selected || seatedID !== selectedID || audio) return;
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
        stop();
        return;
      }
      context.addEventListener('statechange', () => {
        if (token === generation && context.state !== 'running') stop();
      });
      setControls('practicing');
      const bpm = carried?.roomID === selected.id ? carried.score.bpm : selected.bpm;
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
        stop();
        message(error, 'The beat could not play. Try again.');
      }
    } finally {
      clearTimeout(timeout);
    }
  }

  function enter(id) {
    if (!records.isHidden(id) && catalog.room(id)) {
      if (selectedID !== id) stop();
      selectedID = id;
      seatedID = id;
      refresh();
      revealPractice = true;
      Kaka.go('voice');
    }
  }

  function carry(score) {
    const available = catalog.rooms().filter((entry) => !records.isHidden(entry.id));
    const target = available.find((entry) => entry.id === score.roomID)
      ?? available.find((entry) => entry.id === selectedID)
      ?? available[0];
    if (!target) {
      notify('Restore a room in Profile before rehearsing.');
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

  function showPractice() {
    if (!revealPractice) return;
    revealPractice = false;
    const panel = get('practice');
    const screen = get('voice');
    const top = panel.getBoundingClientRect().top - screen.getBoundingClientRect().top;
    if (top < 0 || top > screen.clientHeight / 2) screen.scrollTop += top - 16;
    const heading = get('practice-title');
    heading.tabIndex = -1;
    heading.focus({preventScroll: true});
  }

  function init() {
    get('beat-toggle').addEventListener('click', () => {
      if (audio) stop();
      else start();
    });
    get('practice-write').addEventListener('click', () => {
      const selected = room();
      if (selected) Kaka.notebook.useRoom(selected);
    });
    get('practice-seat').addEventListener('click', () => {
      if (!room()) return;
      if (seatedID === selectedID) {
        seatedID = undefined;
        stop();
      } else {
        seatedID = selectedID;
      }
      renderSeat();
    });
    get('practice-drop-verse').addEventListener('click', () => {
      stop();
      carried = undefined;
      if (room()) describe(room());
    });
    window.addEventListener('kaka:pause', stop);
    window.addEventListener('pagehide', stop);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) stop();
    });
  }

  function reset() {
    stop();
    selectedID = undefined;
    seatedID = undefined;
    carried = undefined;
    revealPractice = false;
    get('practice-verse-title').textContent = '';
    get('practice-verse-lines').replaceChildren();
  }

  Kaka.cypher = {init, refresh, reset, stop, enter, carry, showPractice};
})();
