(() => {
  const Kaka = window.Kaka;
  const {get, element, button, image, message, notify, pending, confirm, records, catalog, lyrics, uuid} = Kaka;
  let score;
  let saved;
  let sourceRoom;
  let reveal = false;
  let draftingTopic;
  let generation = 0;
  const sections = {verse: 'Verse', hook: 'Hook'};
  const cues = {breathe: 'Breathe at the end', tight: 'Keep phrases short', 'pick-up': 'Enter on beat one'};

  function updateConversation() {
    const topic = draftingTopic ?? score?.topic;
    get('verse-welcome').hidden = Boolean(topic);
    get('verse-exchange').hidden = !topic;
    const question = get('verse-message');
    question.disabled = Boolean(draftingTopic);
    question.setAttribute('aria-label', topic ? 'Reuse topic: ' + topic : 'Reuse topic');
    get('verse-message-text').textContent = topic ?? '';
    get('verse-generating').hidden = !draftingTopic;
    get('score').hidden = !score || Boolean(draftingTopic);
  }

  function renderScore() {
    updateConversation();
    if (!score) return;
    get('score-meta').textContent = [
      lyrics.styles[score.style].label, score.bpm + ' BPM', '4/4 time', score.bars.length + ' bars', score.scheme,
    ].join(' · ');
    const rows = [];
    let previous;
    for (const bar of score.bars) {
      if (bar.section !== previous) {
        rows.push(element('h3', 'bar-heading', sections[bar.section]));
        previous = bar.section;
      }
      const row = element('div', 'bar');
      const number = element('span', 'bar-index', String(bar.index).padStart(2, '0'));
      number.setAttribute('aria-hidden', 'true');
      const text = element('textarea');
      text.rows = 2;
      text.maxLength = 160;
      text.value = bar.text;
      text.setAttribute('aria-label', 'Lyrics for bar ' + bar.index);
      text.addEventListener('input', () => { bar.text = text.value; });
      row.append(number, text, element('p', 'caption', 'Rhyme · -' + bar.rhyme + ' · ' + (cues[bar.cue] ?? '')));
      rows.push(row);
    }
    get('score-bars').replaceChildren(...rows);
    message(get('score-error'));
  }

  function showResult() {
    if (!reveal || !score || draftingTopic || get('notebook').hidden) return;
    reveal = false;
    get('verse-thread').scrollTop = 0;
    get('score-title').focus({preventScroll: true});
  }

  function dirty() {
    return score && JSON.stringify(score) !== saved;
  }

  function syncPromptSelection() {
    for (const card of get('verse-prompts').children) {
      card.setAttribute('aria-pressed', String(card.dataset.room === sourceRoom));
    }
  }

  function refreshPrompts() {
    const choices = catalog.rooms().filter((room) => room.cover && !records.isHidden(room.id));
    const cards = choices.map((room) => {
      const host = catalog.host(room.host);
      const card = button('', () => loadRoomPrompt(room), 'prompt-card');
      card.dataset.room = room.id;
      card.setAttribute('aria-label', 'Use “' + room.topic + '”' + (host ? ' from ' + host.name : ''));
      const text = element('span', 'prompt-copy');
      text.append(element('strong', '', room.topic), element('span', 'caption', host?.name ?? room.title));
      card.append(catalog.image(host?.portrait ?? room.cover, 'prompt-portrait', 'notebook.jpg'), text);
      return card;
    });
    get('verse-prompts').replaceChildren(...cards);
    get('room-prompts').hidden = !cards.length;
    syncPromptSelection();
  }

  function updateSettingsSummary() {
    const bpm = get('verse-bpm').valueAsNumber;
    const bars = get('verse-form').querySelector('input[name="length"]:checked')?.value;
    const tempo = Number.isInteger(bpm) && bpm >= 60 && bpm <= 180 ? bpm + ' BPM' : 'Set tempo';
    get('verse-settings-meta').textContent = [tempo, bars && bars + ' bars'].filter(Boolean).join(' · ');
  }

  function fillForm(input) {
    get('verse-topic').value = input.topic;
    get('verse-bpm').value = input.bpm;
    const form = get('verse-form');
    for (const name of ['style', 'scheme', 'length']) {
      const value = name === 'length' ? String(input.bars?.length ?? 8) : input[name];
      for (const radio of form.querySelectorAll('input[name="' + name + '"]')) radio.checked = radio.value === value;
    }
    sourceRoom = input.roomID;
    const room = sourceRoom && catalog.room(sourceRoom);
    const credit = get('verse-context');
    credit.replaceChildren();
    credit.hidden = !room;
    if (room) {
      const host = catalog.host(room.host);
      if (host) credit.append(Kaka.creators.portrait(host, 'credit-avatar'));
      credit.append(element('span', '', room.title));
    }
    updateSettingsSummary();
    syncPromptSelection();
    message(get('verse-error'));
  }

  function loadRoomPrompt(room) {
    const tempo = get('verse-bpm');
    const bpm = room.bpm ?? (Number.isFinite(tempo.valueAsNumber) ? tempo.valueAsNumber : Number(tempo.defaultValue));
    const style = Object.prototype.hasOwnProperty.call(lyrics.styles, room.style) ? room.style : 'freestyle';
    fillForm({topic: room.topic.slice(0, 32), bpm, style, roomID: room.id, scheme: 'AABB'});
  }

  function useRoom(room) {
    loadRoomPrompt(room);
    reveal = false;
    get('verse-thread').scrollTop = 0;
    Kaka.go('notebook');
    requestAnimationFrame(() => { get('verse-thread').scrollTop = 0; });
  }

  async function openSaved(id) {
    const version = generation;
    const found = records.current().scores.find((item) => item.id === id);
    if (!found) {
      notify('This draft has been removed.');
      return;
    }
    if (dirty() && score.id !== id && !await confirm({
      title: 'Open another draft?',
      description: 'Opening another draft will discard your unsaved changes.',
      label: 'Open draft',
    })) return;
    if (version !== generation) return;
    generation += 1;
    draftingTopic = undefined;
    if (score?.id !== id) {
      saved = JSON.stringify(found);
      score = JSON.parse(saved);
    }
    renderScore();
    fillForm(score);
    get('verse-topic').value = '';
    reveal = true;
    Kaka.go('notebook');
    requestAnimationFrame(showResult);
  }

  function onDeleted(id) {
    if (score?.id !== id) return;
    if (dirty()) {
      score.id = uuid();
      score.createdAt = Date.now();
    } else {
      score = undefined;
    }
    saved = undefined;
    renderScore();
  }

  function init() {
    const form = get('verse-form');
    const formError = get('verse-error');
    const generate = form.querySelector('button[type="submit"]');
    const topicInput = get('verse-topic');
    const save = get('score-save');
    form.addEventListener('input', (event) => {
      message(formError);
      if (event.target.matches('#verse-bpm, input[name="length"]')) updateSettingsSummary();
    });
    get('score-practice').addEventListener('click', () => {
      if (score) Kaka.cypher.carry(score);
    });
    get('verse-message').addEventListener('click', () => {
      if (!score || draftingTopic) return;
      topicInput.value = score.topic;
      message(formError);
      topicInput.focus();
    });

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      if (generate.disabled) return;
      const fields = new FormData(form);
      const submittedTopic = topicInput.value;
      const topic = submittedTopic.trim();
      const bpm = Number(fields.get('bpm'));
      if (!topic || topic.length > 32) {
        message(formError, 'Enter a topic of up to 32 characters.');
        topicInput.focus();
        return;
      }
      if (!Number.isInteger(bpm) || bpm < 60 || bpm > 180) {
        message(formError, 'Enter a whole number between 60 and 180 BPM.');
        get('verse-settings').open = true;
        get('verse-bpm').focus();
        return;
      }
      message(formError);
      document.activeElement?.blur();
      const version = generation;
      const request = {
        topic, bpm, length: Number(fields.get('length')), scheme: fields.get('scheme'),
        style: fields.get('style'), roomID: sourceRoom ?? null,
      };
      pending(generate, async () => {
        if (dirty() && !await confirm({
          title: 'Generate a new verse?',
          description: 'A new verse will replace your unsaved changes.',
          label: 'Generate verse',
        })) return;
        if (version !== generation) return;
        get('verse-settings').open = false;
        draftingTopic = topic;
        updateConversation();
        get('verse-thread').scrollTop = 0;
        try {
          // Paint the generating state before applying the service response.
          const painted = new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          const [draft] = await Promise.all([lyrics.provider.generate(request), painted]);
          if (version !== generation) return;
          score = draft;
          saved = undefined;
          if (topicInput.value === submittedTopic) topicInput.value = '';
          renderScore();
          reveal = true;
        } finally {
          if (version === generation) {
            draftingTopic = undefined;
            updateConversation();
          }
        }
        showResult();
      }, (failure) => {
        if (version === generation) message(formError, failure.message);
      });
    });

    save.addEventListener('click', () => pending(save, async () => {
      const error = get('score-error');
      message(error);
      if (!score) return;
      const current = score;
      const serializedBefore = JSON.stringify(current);
      const copy = JSON.parse(serializedBefore);
      copy.bars.forEach((bar) => { bar.text = bar.text.trim(); });
      const empty = copy.bars.find((bar) => !bar.text);
      if (empty) {
        message(error, 'Add lyrics to bar ' + empty.index + '.');
        get('score-bars').querySelectorAll('textarea')[empty.index - 1].focus();
        return;
      }
      document.activeElement?.blur();
      copy.updatedAt = Date.now();
      await records.update((state) => {
        const index = state.scores.findIndex((item) => item.id === copy.id);
        if (index < 0 && state.scores.length >= 40) {
          throw new Error('Your drafts are full. Delete one to save another.');
        }
        if (index < 0) state.scores.push(copy);
        else state.scores[index] = copy;
      });
      if (score === current) {
        saved = JSON.stringify(copy);
        if (serializedBefore === JSON.stringify(score)) {
          score = copy;
          renderScore();
        }
      }
      notify('Verse saved to drafts.');
    }, (error) => message(get('score-error'), error.message)));
  }

  function reset() {
    generation += 1;
    draftingTopic = undefined;
    score = undefined;
    saved = undefined;
    sourceRoom = undefined;
    reveal = false;
    get('verse-form').reset();
    get('verse-settings').open = false;
    get('verse-prompts').replaceChildren();
    get('room-prompts').hidden = true;
    updateSettingsSummary();
    updateConversation();
    get('verse-thread').scrollTop = 0;
    get('score-meta').textContent = '';
    get('score-bars').replaceChildren();
    for (const id of ['verse-context', 'verse-error', 'score-error']) message(get(id));
  }

  Kaka.notebook = {init, useRoom, openSaved, onDeleted, showResult, refreshPrompts, reset};
})();
