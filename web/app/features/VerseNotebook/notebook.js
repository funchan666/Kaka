(() => {
  const Kaka = window.Kaka;
  const {get, element, message, notify, pending, confirm, records, lyrics, uuid} = Kaka;
  let score;
  let saved;
  let sourceRoom;
  let reveal = false;
  const sections = {verse: 'Verse', hook: 'Hook'};
  const cues = {breathe: 'Breathe at the end', tight: 'Keep phrases short', 'pick-up': 'Enter on beat one'};

  function renderScore() {
    get('score').hidden = !score;
    if (!score) return;
    get('score-title').textContent = score.topic;
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
    if (!reveal || !score || get('notebook').hidden) return;
    reveal = false;
    const screen = get('notebook');
    const heading = get('score-title');
    heading.focus({preventScroll: true});
    const top = heading.getBoundingClientRect().top - screen.getBoundingClientRect().top;
    if (top > screen.clientHeight / 2 || top < 0) screen.scrollTop += top - 16;
  }

  function dirty() {
    return score && JSON.stringify(score) !== saved;
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
    const room = sourceRoom && Kaka.catalog.room(sourceRoom);
    message(get('verse-context'), room ? 'Topic and tempo from ' + room.title : '');
    message(get('verse-error'));
  }

  function useRoom(room) {
    fillForm({topic: room.topic, bpm: room.bpm, style: room.style, roomID: room.id, scheme: 'AABB'});
    reveal = false;
    get('notebook').scrollTop = 0;
    Kaka.go('notebook');
    requestAnimationFrame(() => { get('notebook').scrollTop = 0; });
  }

  async function openSaved(id) {
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
    if (score?.id !== id) {
      saved = JSON.stringify(found);
      score = JSON.parse(saved);
      renderScore();
    }
    fillForm(score);
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
    const save = get('score-save');
    get('score-practice').addEventListener('click', () => {
      if (score) Kaka.cypher.carry(score);
    });

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const fields = new FormData(form);
      const topic = String(fields.get('topic') ?? '').trim();
      const bpm = Number(fields.get('bpm'));
      if (!topic || topic.length > 32) {
        message(formError, 'Enter a topic of up to 32 characters.');
        get('verse-topic').focus();
        return;
      }
      if (!Number.isInteger(bpm) || bpm < 60 || bpm > 180) {
        message(formError, 'Enter a whole number between 60 and 180 BPM.');
        get('verse-bpm').focus();
        return;
      }
      message(formError);
      document.activeElement?.blur();
      pending(generate, async () => {
        if (dirty() && !await confirm({
          title: 'Generate a new verse?',
          description: 'A new verse will replace your unsaved changes.',
          label: 'Generate verse',
        })) return;
        score = await lyrics.provider.generate({
          topic, bpm, length: Number(fields.get('length')), scheme: fields.get('scheme'),
          style: fields.get('style'), roomID: sourceRoom ?? null,
        });
        saved = undefined;
        renderScore();
        reveal = true;
        showResult();
      }, (failure) => message(formError, failure.message));
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
    score = undefined;
    saved = undefined;
    sourceRoom = undefined;
    reveal = false;
    get('verse-form').reset();
    get('score').hidden = true;
    get('score-title').textContent = '';
    get('score-meta').textContent = '';
    get('score-bars').replaceChildren();
    for (const id of ['verse-context', 'verse-error', 'score-error']) message(get(id));
  }

  Kaka.notebook = {init, useRoom, openSaved, onDeleted, showResult, reset};
})();
